//! Serialized admission and page-parent ownership for one running kernel.
//! Caller owns region registration, synchronization and owner quiescence.
//! Handles are instance-scoped ownership checks, not access capabilities.
const std = @import("std");
pub const pages = @import("page_pool.zig");
pub const page_bytes = 4096;
pub const Domain = enum { internal, external };
pub const Group = enum { kernel, vfs, store, sqlite, network, ble, ime, vm, display, editor, sensor_audio };
pub const group_count = std.enums.values(Group).len;
pub const Limits = struct {
    internal: u32 = 0,
    external: u32 = 0,
    pub fn get(self: Limits, domain: Domain) u32 {
        return if (domain == .internal) self.internal else self.external;
    }
    fn add(self: *Limits, domain: Domain, bytes: u32) void {
        if (domain == .internal) self.internal += bytes else self.external += bytes;
    }
    fn subtract(self: *Limits, domain: Domain, bytes: u32) void {
        if (domain == .internal) self.internal -= bytes else self.external -= bytes;
    }
};
pub const Policy = struct {
    floor: Limits = .{},
    groups: [group_count]Limits = @splat(.{}),
    owner_limits: [group_count]u16 = @splat(std.math.maxInt(u16)),
};
pub const Owner = struct { slot: u16, ticket: u64, instance: usize };
pub const Lease = struct { slot: u16, ticket: u64, owner: Owner, domain: Domain, bytes: []u8, charged: u32 };
pub const Pin = struct { slot: u16, ticket: u64, instance: usize };
pub const Borrow = struct { token: Pin, bytes: []u8 };
pub const Reclaim = enum { released, waiting, complete };
pub const Error = pages.Error || error{ Inactive, Closing, Quota, Reserve, Unavailable, Busy, InvalidPin };
pub const Stats = struct { capacity: u32, free: u32, largest: u32, used: u32, peak: u32, floor: u32 };
pub const OwnerStats = struct { limit: Limits, used: Limits, closing: bool };
pub const GroupStats = struct { limit: Limits, admitted: Limits, used: Limits, owners: u16 };

pub fn Broker(comptime internal_pages: usize, comptime external_pages: usize, comptime lease_limit: usize, comptime owner_limit: usize, comptime pin_limit: usize) type {
    if (lease_limit == 0 or lease_limit > 65536 or owner_limit == 0 or owner_limit > 65535 or pin_limit == 0 or pin_limit > 65536)
        @compileError("invalid broker metadata capacity");
    return struct {
        const Self = @This();
        const Internal = pages.Pool(page_bytes, internal_pages, lease_limit);
        const External = pages.Pool(page_bytes, external_pages, lease_limit);
        const Account = struct { key: Owner, group: Group, limit: Limits, used: Limits = .{}, closing: bool = false };
        const Entry = struct { lease: Lease, backing: pages.Lease, pins: u16 = 0 };
        const Held = struct { token: Pin, lease_slot: u16 };
        internal: ?Internal = null,
        external: ?External = null,
        policy: Policy = .{},
        ready: bool = false,
        home: usize = 0,
        owners: [owner_limit]?Account = @splat(null),
        leases: [lease_limit]?Entry = @splat(null),
        pins: [pin_limit]?Held = @splat(null),
        admitted: [group_count]Limits = @splat(.{}),
        charged: [group_count]Limits = @splat(.{}),
        owner_counts: [group_count]u16 = @splat(0),
        peak: Limits = .{},
        serial: u64 = 0,

        /// Regions must be exclusively transferred from any former allocator.
        /// Do not reinitialize while old handles or borrowed pointers survive.
        pub fn init(self: *Self, internal: []const pages.Region, external: []const pages.Region, policy: Policy) bool {
            if (self.ready) return false;
            self.* = .{ .policy = policy };
            self.home = @intFromPtr(self);
            if (internal.len != 0) {
                self.internal = Internal.init(internal);
                if (self.internal == null) return false;
            }
            if (external.len != 0) {
                self.external = External.init(external);
                if (self.external == null) return false;
            }
            if (self.internal == null and self.external == null) return false;
            for ([_][]const pages.Region{ internal, external }) |regions| for (regions) |region| {
                if (@intFromPtr(region.memory.ptr) < @intFromPtr(self) + @sizeOf(Self) and
                    @intFromPtr(self) < @intFromPtr(region.memory.ptr) + region.memory.len) return false;
            };
            for (internal) |a| for (external) |b| {
                if (@intFromPtr(a.memory.ptr) < @intFromPtr(b.memory.ptr) + b.memory.len and
                    @intFromPtr(b.memory.ptr) < @intFromPtr(a.memory.ptr) + a.memory.len) return false;
            };
            for ([_]Domain{ .internal, .external }) |domain| {
                var reserved: u64 = policy.floor.get(domain);
                for (policy.groups) |group| reserved += group.get(domain);
                if (reserved > self.capacity(domain)) return false;
            }
            self.ready = true;
            return true;
        }

        fn sameOwner(a: Owner, b: Owner) bool {
            return a.slot == b.slot and a.ticket == b.ticket and a.instance == b.instance;
        }
        fn initialized(self: *const Self) bool {
            return self.ready and self.home == @intFromPtr(self);
        }
        fn account(self: *Self, key: Owner) Error!*Account {
            if (!self.initialized() or key.slot >= owner_limit or key.ticket == 0) return error.Inactive;
            const entry = &(self.owners[key.slot] orelse return error.Inactive);
            if (!sameOwner(entry.key, key)) return error.Inactive;
            return &self.owners[key.slot].?;
        }
        fn availableTicket(self: *const Self) Error!void {
            if (self.serial == std.math.maxInt(u64)) return error.SerialExhausted;
        }
        fn ticket(self: *Self) u64 {
            self.serial += 1;
            return self.serial;
        }
        pub fn open(self: *Self, group: Group, limit: Limits) Error!Owner {
            if (!self.initialized()) return error.Inactive;
            if (limit.internal == 0 and limit.external == 0) return error.InvalidRequest;
            const index = @backingInt(group);
            if (self.owner_counts[index] >= self.policy.owner_limits[index]) return error.Quota;
            for ([_]Domain{ .internal, .external }) |domain| {
                if (limit.get(domain) > self.policy.groups[index].get(domain) - self.admitted[index].get(domain)) return error.Quota;
            }
            const slot = for (self.owners, 0..) |entry, i| {
                if (entry == null) break i;
            } else return error.Full;
            try self.availableTicket();
            const key = Owner{ .slot = @intCast(slot), .ticket = self.ticket(), .instance = self.home };
            self.owners[slot] = .{ .key = key, .group = group, .limit = limit };
            self.owner_counts[index] += 1;
            self.admitted[index].add(.internal, limit.internal);
            self.admitted[index].add(.external, limit.external);
            return key;
        }

        /// Page parents are zeroed, including padding, before publication.
        /// Large clears run in ordinary service context, never in an IRQ.
        pub fn alloc(self: *Self, owner: Owner, domain: Domain, length: usize, alignment: usize) Error!Lease {
            const who = try self.account(owner);
            if (who.closing) return error.Closing;
            if (length == 0 or length > std.math.maxInt(u32) or alignment == 0 or alignment > page_bytes or alignment & (alignment - 1) != 0)
                return error.InvalidRequest;
            const charged64 = (@as(u64, @intCast(length)) + page_bytes - 1) / page_bytes * page_bytes;
            if (charged64 > std.math.maxInt(u32)) return error.InvalidRequest;
            const bytes: u32 = @intCast(charged64);
            const capacity_bytes = self.capacity(domain);
            const free_bytes = self.remaining(domain);
            if (capacity_bytes == 0) return error.Unavailable;
            if (bytes > who.limit.get(domain) - who.used.get(domain)) return error.Quota;
            if (bytes > free_bytes - self.policy.floor.get(domain)) return error.Reserve;
            const slot = for (self.leases, 0..) |entry, i| {
                if (entry == null) break i;
            } else return error.Full;
            try self.availableTicket();
            const id: u32 = @as(u32, owner.slot) + 1;
            const backing = switch (domain) {
                .internal => try self.internal.?.alloc(id, length, alignment),
                .external => try self.external.?.alloc(id, length, alignment),
            };
            const lease = Lease{ .slot = @intCast(slot), .ticket = self.ticket(), .owner = owner, .domain = domain, .bytes = backing.bytes, .charged = backing.charged };
            @memset(@as([*]u8, backing.bytes.ptr)[0..backing.charged], 0);
            self.leases[slot] = .{ .lease = lease, .backing = backing };
            who.used.add(domain, bytes);
            self.charged[@backingInt(who.group)].add(domain, bytes);
            const used = capacity_bytes - free_bytes + bytes;
            if (used > self.peak.get(domain)) {
                if (domain == .internal) self.peak.internal = used else self.peak.external = used;
            }
            return lease;
        }

        fn leaseEntry(self: *Self, owner: Owner, lease: Lease) Error!*Entry {
            if (!sameOwner(owner, lease.owner)) return error.WrongOwner;
            if (lease.slot >= lease_limit) return error.InvalidLease;
            const candidate = &(self.leases[lease.slot] orelse return error.InvalidLease);
            const canonical = candidate.lease;
            if (!sameOwner(owner, canonical.owner)) return error.WrongOwner;
            if (lease.ticket != canonical.ticket or lease.domain != canonical.domain or lease.charged != canonical.charged or
                lease.bytes.ptr != canonical.bytes.ptr or lease.bytes.len != canonical.bytes.len) return error.InvalidLease;
            return &self.leases[lease.slot].?;
        }
        fn release(self: *Self, who: *Account, allocation: *Entry) Error!void {
            if (allocation.pins != 0) return error.Busy;
            const lease = allocation.lease;
            switch (lease.domain) {
                .internal => try self.internal.?.free(@as(u32, who.key.slot) + 1, allocation.backing),
                .external => try self.external.?.free(@as(u32, who.key.slot) + 1, allocation.backing),
            }
            who.used.subtract(lease.domain, lease.charged);
            self.charged[@backingInt(who.group)].subtract(lease.domain, lease.charged);
            self.leases[lease.slot] = null;
        }
        pub fn free(self: *Self, owner: Owner, lease: Lease) Error!void {
            const who = try self.account(owner);
            if (who.closing) return error.Closing;
            try self.release(who, try self.leaseEntry(owner, lease));
        }

        /// Pin before handing a pointer to DMA or another asynchronous actor.
        pub fn pin(self: *Self, owner: Owner, lease: Lease) Error!Borrow {
            const who = try self.account(owner);
            if (who.closing) return error.Closing;
            const allocation = try self.leaseEntry(owner, lease);
            if (allocation.pins == std.math.maxInt(u16)) return error.Full;
            const slot = for (self.pins, 0..) |held, i| {
                if (held == null) break i;
            } else return error.Full;
            try self.availableTicket();
            const token = Pin{ .slot = @intCast(slot), .ticket = self.ticket(), .instance = self.home };
            self.pins[slot] = .{ .token = token, .lease_slot = lease.slot };
            allocation.pins += 1;
            return .{ .token = token, .bytes = allocation.lease.bytes };
        }
        /// Completion/cancellation must establish that the borrower is done.
        /// Tokens are consumed once, including while an owner is closing.
        pub fn unpin(self: *Self, token: Pin) Error!void {
            if (!self.initialized() or token.instance != self.home or token.slot >= pin_limit or token.ticket == 0) return error.InvalidPin;
            const held = self.pins[token.slot] orelse return error.InvalidPin;
            if (held.token.ticket != token.ticket) return error.InvalidPin;
            self.leases[held.lease_slot].?.pins -= 1;
            self.pins[token.slot] = null;
        }

        /// Caller first stops all tasks that own this application/service.
        /// A single sibling task's exit does not authorize this operation.
        pub fn beginClose(self: *Self, owner: Owner) Error!void {
            (try self.account(owner)).closing = true;
        }
        /// Reclaim at most one unpinned parent per call, outside IRQ context.
        /// Pinned parents retain both backing memory and admission credit.
        pub fn reclaimOne(self: *Self, owner: Owner) Error!Reclaim {
            const who = try self.account(owner);
            if (!who.closing) return error.Busy;
            var waiting = false;
            for (&self.leases) |*maybe| {
                const allocation = if (maybe.*) |*value| value else continue;
                if (!sameOwner(owner, allocation.lease.owner)) continue;
                if (allocation.pins != 0) {
                    waiting = true;
                    continue;
                }
                try self.release(who, allocation);
                return .released;
            }
            if (waiting) return .waiting;
            const index = @backingInt(who.group);
            self.admitted[index].subtract(.internal, who.limit.internal);
            self.admitted[index].subtract(.external, who.limit.external);
            self.owner_counts[index] -= 1;
            self.owners[owner.slot] = null;
            return .complete;
        }
        pub fn ownerStats(self: *Self, owner: Owner) Error!OwnerStats {
            const who = try self.account(owner);
            return .{ .limit = who.limit, .used = who.used, .closing = who.closing };
        }
        pub fn groupStats(self: *const Self, group: Group) GroupStats {
            if (!self.initialized()) return .{ .limit = .{}, .admitted = .{}, .used = .{}, .owners = 0 };
            const index = @backingInt(group);
            return .{ .limit = self.policy.groups[index], .admitted = self.admitted[index], .used = self.charged[index], .owners = self.owner_counts[index] };
        }
        fn capacity(self: *const Self, domain: Domain) u32 {
            return switch (domain) {
                .internal => if (self.internal) |*pool| pool.capacity() else 0,
                .external => if (self.external) |*pool| pool.capacity() else 0,
            };
        }
        fn remaining(self: *const Self, domain: Domain) u32 {
            return switch (domain) {
                .internal => if (self.internal) |*pool| pool.remaining() else 0,
                .external => if (self.external) |*pool| pool.remaining() else 0,
            };
        }
        pub fn stats(self: *const Self, domain: Domain) Stats {
            if (!self.initialized()) return .{ .capacity = 0, .free = 0, .largest = 0, .used = 0, .peak = 0, .floor = 0 };
            const capacity_bytes = self.capacity(domain);
            const free_bytes = self.remaining(domain);
            const largest = switch (domain) {
                .internal => if (self.internal) |*pool| pool.largestFree() else 0,
                .external => if (self.external) |*pool| pool.largestFree() else 0,
            };
            return .{ .capacity = capacity_bytes, .free = free_bytes, .largest = largest, .used = capacity_bytes - free_bytes, .peak = self.peak.get(domain), .floor = self.policy.floor.get(domain) };
        }
    };
}
