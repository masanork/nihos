const std = @import("std");
const api = @import("memory_broker.zig");
const P = api.page_bytes;
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const expectError = std.testing.expectError;
fn policy(group: api.Group, internal: u32, external: u32) api.Policy {
    var config = api.Policy{};
    config.groups[@backingInt(group)] = .{ .internal = internal, .external = external };
    return config;
}

test "broker rejects overlapping domains and oversubscribed capacity" {
    var memory: [8 * P]u8 align(P) = @splat(0);
    const B = api.Broker(8, 8, 8, 4, 4);
    const internal = [_]api.pages.Region{.{ .memory = &memory }};
    var invalid: B = .{};
    try expect(!invalid.init(&internal, &internal, .{}));
    var config = policy(.kernel, 8 * P, 0);
    config.floor.internal = 1;
    try expect(!invalid.init(&internal, &.{}, config));
    try expect(!invalid.init(&.{}, &.{}, .{}));
    config = policy(.kernel, 7 * P, 0);
    config.floor.internal = P;
    var broker: B = .{};
    try expect(broker.init(&internal, &.{}, config));
    const owner = try broker.open(.kernel, .{ .internal = 7 * P });
    try expectError(error.Unavailable, broker.alloc(owner, .external, 1, 1));
    const lease = try broker.alloc(owner, .internal, 7 * P, P);
    try equal(@as(u32, P), broker.stats(.internal).free);
    try expectError(error.Quota, broker.alloc(owner, .internal, 1, 1));
    try broker.free(owner, lease);
    try equal(@as(u32, 8 * P), broker.stats(.internal).free);
}

test "admission credit stays reserved until close completes and old owners stay dead" {
    var memory: [4 * P]u8 align(P) = @splat(0);
    const B = api.Broker(4, 1, 4, 2, 4);
    var broker: B = .{};
    try expect(broker.init(&.{.{ .memory = &memory }}, &.{}, policy(.ime, 4 * P, 0)));
    const first = try broker.open(.ime, .{ .internal = 3 * P });
    try expectError(error.Quota, broker.open(.ime, .{ .internal = 2 * P }));
    try broker.beginClose(first);
    try expectError(error.Closing, broker.alloc(first, .internal, 1, 1));
    try expectError(error.Quota, broker.open(.ime, .{ .internal = 2 * P }));
    try equal(api.Reclaim.complete, try broker.reclaimOne(first));
    const replacement = try broker.open(.ime, .{ .internal = 4 * P });
    try equal(first.slot, replacement.slot);
    try expect(first.ticket != replacement.ticket);
    try expectError(error.Inactive, broker.alloc(first, .internal, 1, 1));
    try expectError(error.Inactive, broker.beginClose(first));
}

test "charged pages and padding are zeroed without reviving modified or stale leases" {
    var memory: [4 * P]u8 align(P) = @splat(0xa5);
    var broker: api.Broker(4, 1, 8, 4, 4) = .{};
    try expect(broker.init(&.{.{ .memory = &memory }}, &.{}, policy(.kernel, 4 * P, 0)));
    const a = try broker.open(.kernel, .{ .internal = 3 * P });
    const b = try broker.open(.kernel, .{ .internal = P });
    const first = try broker.alloc(a, .internal, 1, 1);
    try equal(@as(u32, P), first.charged);
    for (memory[0..P]) |byte| try equal(@as(u8, 0), byte);
    @memset(memory[0..P], 0xa5);
    try expectError(error.WrongOwner, broker.free(b, first));
    var changed = first;
    changed.bytes = changed.bytes[0..0];
    try expectError(error.InvalidLease, broker.free(a, changed));
    changed = first;
    changed.domain = .external;
    try expectError(error.InvalidLease, broker.free(a, changed));
    try broker.free(a, first);
    const next = try broker.alloc(a, .internal, P, 64);
    try equal(first.bytes.ptr, next.bytes.ptr);
    for (next.bytes) |byte| try equal(@as(u8, 0), byte);
    try expectError(error.InvalidLease, broker.free(a, first));
    const large = try broker.alloc(a, .internal, P + 1, 64);
    try equal(@as(u32, 2 * P), large.charged);
    try equal(@as(u32, 3 * P), (try broker.ownerStats(a)).used.internal);
    try broker.free(a, next);
    try broker.free(a, large);
}

test "fragmentation failures leave owner and group charges unchanged" {
    var memory: [8 * P]u8 align(P) = @splat(0);
    var broker: api.Broker(8, 1, 8, 2, 4) = .{};
    try expect(broker.init(&.{.{ .memory = &memory }}, &.{}, policy(.vm, 8 * P, 0)));
    const owner = try broker.open(.vm, .{ .internal = 8 * P });
    var leases: [4]api.Lease = undefined;
    for (&leases) |*lease| lease.* = try broker.alloc(owner, .internal, 2 * P, P);
    try broker.free(owner, leases[0]);
    try broker.free(owner, leases[2]);
    const before = broker.stats(.internal);
    try equal(@as(u32, 4 * P), before.free);
    try equal(@as(u32, 2 * P), before.largest);
    try expectError(error.OutOfMemory, broker.alloc(owner, .internal, 3 * P, 1));
    try equal(before, broker.stats(.internal));
    try equal(@as(u32, 4 * P), (try broker.ownerStats(owner)).used.internal);
    try equal(@as(u32, 4 * P), broker.charged[@backingInt(api.Group.vm)].internal);
}

test "separate pins prevent premature reaping and consume completion tokens once" {
    var memory: [4 * P]u8 align(P) = @splat(0);
    var config = policy(.network, 4 * P, 0);
    config.owner_limits[@backingInt(api.Group.network)] = 1;
    var broker: api.Broker(4, 1, 4, 2, 4) = .{};
    try expect(broker.init(&.{.{ .memory = &memory }}, &.{}, config));
    const owner = try broker.open(.network, .{ .internal = 4 * P });
    const buffer = try broker.alloc(owner, .internal, P, 64);
    const other = try broker.alloc(owner, .internal, P, 64);
    const first = try broker.pin(owner, buffer);
    const second = try broker.pin(owner, buffer);
    try expectError(error.Busy, broker.free(owner, buffer));
    try expectError(error.Busy, broker.reclaimOne(owner));
    try broker.beginClose(owner);
    try expectError(error.Closing, broker.pin(owner, other));
    try equal(api.Reclaim.released, try broker.reclaimOne(owner));
    try equal(api.Reclaim.waiting, try broker.reclaimOne(owner));
    try expectError(error.Quota, broker.open(.network, .{ .internal = P }));
    try broker.unpin(first.token);
    try expectError(error.InvalidPin, broker.unpin(first.token));
    try equal(api.Reclaim.waiting, try broker.reclaimOne(owner));
    try broker.unpin(second.token);
    try equal(api.Reclaim.released, try broker.reclaimOne(owner));
    try equal(api.Reclaim.complete, try broker.reclaimOne(owner));
    try equal(@as(u32, 4 * P), broker.stats(.internal).free);
    const replacement = try broker.open(.network, .{ .internal = 4 * P });
    const fresh = try broker.alloc(replacement, .internal, P, 64);
    const new_pin = try broker.pin(replacement, fresh);
    try equal(first.token.slot, new_pin.token.slot);
    try expectError(error.InvalidPin, broker.unpin(first.token));
    try expectError(error.Busy, broker.free(replacement, fresh));
    try broker.unpin(new_pin.token);
    try broker.free(replacement, fresh);
}

test "bounded owner lease and pin metadata fail without leaking admission or backing" {
    var memory: [4 * P]u8 align(P) = @splat(0);
    var broker: api.Broker(4, 1, 1, 1, 1) = .{};
    try expect(broker.init(&.{.{ .memory = &memory }}, &.{}, policy(.kernel, 4 * P, 0)));
    const owner = try broker.open(.kernel, .{ .internal = 3 * P });
    try expectError(error.Full, broker.open(.kernel, .{ .internal = P }));
    try equal(@as(u32, 3 * P), broker.admitted[@backingInt(api.Group.kernel)].internal);
    const lease = try broker.alloc(owner, .internal, P, P);
    try expectError(error.Full, broker.alloc(owner, .internal, P, P));
    try equal(@as(u32, 3 * P), broker.stats(.internal).free);
    const pin = try broker.pin(owner, lease);
    try expectError(error.Full, broker.pin(owner, lease));
    try broker.unpin(pin.token);
    try broker.free(owner, lease);
    try equal(@as(u32, 4 * P), broker.stats(.internal).free);
}

test "ticket exhaustion closes new admission while release and cleanup remain possible" {
    var memory: [4 * P]u8 align(P) = @splat(0);
    var broker: api.Broker(4, 1, 4, 2, 2) = .{};
    try expect(broker.init(&.{.{ .memory = &memory }}, &.{}, policy(.kernel, 4 * P, 0)));
    const owner = try broker.open(.kernel, .{ .internal = 2 * P });
    const lease = try broker.alloc(owner, .internal, P, P);
    const borrow = try broker.pin(owner, lease);
    broker.serial = std.math.maxInt(u64);
    try expectError(error.SerialExhausted, broker.open(.kernel, .{ .internal = P }));
    try expectError(error.SerialExhausted, broker.alloc(owner, .internal, P, P));
    try expectError(error.SerialExhausted, broker.pin(owner, lease));
    try broker.beginClose(owner);
    try broker.unpin(borrow.token);
    try equal(api.Reclaim.released, try broker.reclaimOne(owner));
    try equal(api.Reclaim.complete, try broker.reclaimOne(owner));
    try equal(@as(u32, 4 * P), broker.stats(.internal).free);
}

test "largest free extent never combines separate registered regions" {
    var memory: [12 * P]u8 align(P) = @splat(0);
    var broker: api.Broker(8, 1, 8, 2, 2) = .{};
    try expect(broker.init(&.{ .{ .memory = memory[0 .. 4 * P] }, .{ .memory = memory[8 * P ..] } }, &.{}, policy(.vm, 8 * P, 0)));
    const owner = try broker.open(.vm, .{ .internal = 8 * P });
    try equal(@as(u32, 8 * P), broker.stats(.internal).free);
    try equal(@as(u32, 4 * P), broker.stats(.internal).largest);
    try expectError(error.OutOfMemory, broker.alloc(owner, .internal, 5 * P, P));
    try equal(@as(u32, 0), (try broker.ownerStats(owner)).used.internal);
}

test "development policy admits exact four and eight MiB parents with all reserves intact" {
    const dev = @import("development_memory.zig");
    // SAFETY: registration does not read payload, and allocation clears pages.
    var internal: [dev.internal_bytes]u8 align(P) = undefined;
    const external = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(P), dev.external_bytes);
    defer std.testing.allocator.free(external);
    var broker: dev.Manager = .{};
    try expect(broker.init(&.{ .{ .memory = internal[0 .. 48 * 1024] }, .{ .memory = internal[48 * 1024 ..] } }, &.{ .{ .memory = external[0 .. 15 * 1024 * 1024] }, .{ .memory = external[15 * 1024 * 1024 ..] } }, dev.policy));
    try expect(@sizeOf(dev.Manager) <= dev.metadata_reserve_bytes);
    try equal(@as(u32, dev.internal_backing_bytes), dev.internal_bytes + dev.metadata_reserve_bytes);
    const owner = try broker.open(.vm, .{ .external = 8 * 1024 * 1024 });
    try expectError(error.Quota, broker.open(.vm, .{ .external = P }));
    const ime = try broker.open(.ime, .{ .internal = 8192, .external = 2 * 1024 * 1024 });
    const network = try broker.open(.network, .{ .internal = 65536, .external = 3 * 1024 * 1024 });
    const ime_internal = try broker.alloc(ime, .internal, 4097, 64);
    const net_internal = try broker.alloc(network, .internal, 65536, 64);
    const cache = try broker.alloc(ime, .external, 2 * 1024 * 1024, 64);
    const packets = try broker.alloc(network, .external, 3 * 1024 * 1024, 64);
    for ([_]u32{ 4 * 1024 * 1024, 8 * 1024 * 1024 }) |length| {
        const lease = try broker.alloc(owner, .external, length, 64);
        try equal(length, lease.charged);
        try expect(broker.stats(.internal).free >= 64 * 1024);
        try expect(broker.stats(.external).free >= 17 * 1024 * 1024 / 2);
        for (lease.bytes) |byte| try equal(@as(u8, 0), byte);
        @memset(lease.bytes, 0x5a);
        try broker.free(owner, lease);
    }
    try broker.free(ime, ime_internal);
    try broker.free(network, net_internal);
    try broker.free(ime, cache);
    try broker.free(network, packets);
    try equal(@as(u32, dev.internal_bytes), broker.stats(.internal).free);
    try equal(@as(u32, dev.external_bytes), broker.stats(.external).free);
    try equal(@as(u32, 13 * 1024 * 1024), broker.stats(.external).peak);
}

test "every service can reach its full backing quota without spending either floor" {
    const dev = @import("development_memory.zig");
    // SAFETY: every payload is initialized by the broker before publication.
    var internal: [dev.internal_bytes]u8 align(P) = undefined;
    const external = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(P), dev.external_bytes);
    defer std.testing.allocator.free(external);
    var broker: dev.Manager = .{};
    try expect(broker.init(&.{ .{ .memory = internal[0 .. 48 * 1024] }, .{ .memory = internal[48 * 1024 ..] } }, &.{.{ .memory = external }}, dev.policy));
    var owners: [api.group_count]api.Owner = undefined;
    for (std.enums.values(api.Group), 0..) |group, index| {
        const limit = dev.policy.groups[index];
        owners[index] = try broker.open(group, limit);
        if (limit.internal != 0) _ = try broker.alloc(owners[index], .internal, limit.internal, 64);
        if (limit.external != 0) _ = try broker.alloc(owners[index], .external, limit.external, 64);
    }
    try equal(dev.policy.floor.internal, broker.stats(.internal).free);
    try equal(dev.policy.floor.external, broker.stats(.external).free);
    for (owners) |owner| {
        try broker.beginClose(owner);
        while (try broker.reclaimOne(owner) != .complete) {}
    }
    try equal(@as(u32, dev.internal_bytes), broker.stats(.internal).free);
    try equal(@as(u32, dev.external_bytes), broker.stats(.external).free);
    for (std.enums.values(api.Group)) |group| {
        const status = broker.groupStats(group);
        try equal(api.Limits{}, status.admitted);
        try equal(api.Limits{}, status.used);
        try equal(@as(u16, 0), status.owners);
    }
}

test "metadata cannot alias payload and a copied or reinitialized broker fails closed" {
    var memory: [8 * P]u8 align(P) = @splat(0);
    const B = api.Broker(8, 1, 4, 2, 2);
    const alias: *B = @ptrCast(@alignCast(&memory));
    alias.* = .{};
    try expect(!alias.init(&.{.{ .memory = &memory }}, &.{}, policy(.kernel, 4 * P, 0)));
    try expectError(error.Inactive, alias.open(.kernel, .{ .internal = P }));
    var broker: B = .{};
    try expect(broker.init(&.{.{ .memory = &memory }}, &.{}, policy(.kernel, 4 * P, 0)));
    const owner = try broker.open(.kernel, .{ .internal = 4 * P });
    const lease = try broker.alloc(owner, .internal, P, 64);
    try expect(!broker.init(&.{.{ .memory = &memory }}, &.{}, .{}));
    var copy = broker;
    try expectError(error.Inactive, copy.alloc(owner, .internal, P, 64));
    try expectError(error.Inactive, copy.free(owner, lease));
    try broker.free(owner, lease);
}

test "mixed domain churn preserves all live payloads charges and reserve floors" {
    var internal: [16 * P]u8 align(P) = @splat(0);
    var external: [32 * P]u8 align(P) = @splat(0);
    var config = policy(.kernel, 6 * P, 12 * P);
    config.groups[@backingInt(api.Group.ime)] = .{ .internal = 6 * P, .external = 12 * P };
    config.floor = .{ .internal = 4 * P, .external = 8 * P };
    var broker: api.Broker(16, 32, 16, 4, 4) = .{};
    try expect(broker.init(&.{.{ .memory = &internal }}, &.{.{ .memory = &external }}, config));
    const owners = [_]api.Owner{ try broker.open(.kernel, .{ .internal = 6 * P, .external = 12 * P }), try broker.open(.ime, .{ .internal = 6 * P, .external = 12 * P }) };
    var live: [16]?api.Lease = @splat(null);
    var state: u32 = 473;
    for (0..2000) |_| {
        state = state *% 1664525 +% 1013904223;
        const slot = (state >> 8) % live.len;
        if (live[slot]) |lease| {
            try broker.free(lease.owner, lease);
            live[slot] = null;
        } else {
            const owner = owners[(state >> 20) % owners.len];
            const domain: api.Domain = if (state & 0x40000000 == 0) .internal else .external;
            const length = (state >> 16) % (2 * P) + 1;
            const before = broker.stats(domain);
            if (broker.alloc(owner, domain, length, 64)) |lease| {
                live[slot] = lease;
                @memset(lease.bytes, @as(u8, @intCast(slot + 1)));
            } else |err| {
                try expect(err == error.Quota or err == error.OutOfMemory or err == error.Full);
                try equal(before, broker.stats(domain));
            }
        }
        var used = [_]api.Limits{ .{}, .{} };
        for (live, 0..) |maybe, i| if (maybe) |lease| {
            try equal(@as(u8, @intCast(i + 1)), lease.bytes[0]);
            try equal(@as(u8, @intCast(i + 1)), lease.bytes[lease.bytes.len - 1]);
            const index: usize = if (lease.owner.slot == owners[0].slot) 0 else 1;
            if (lease.domain == .internal) used[index].internal += lease.charged else used[index].external += lease.charged;
        };
        for (owners, used) |owner, charge| try equal(charge, (try broker.ownerStats(owner)).used);
        try expect(broker.stats(.internal).free >= config.floor.internal);
        try expect(broker.stats(.external).free >= config.floor.external);
    }
    for (owners) |owner| {
        try broker.beginClose(owner);
        while (try broker.reclaimOne(owner) != .complete) {}
    }
    try equal(@as(u32, internal.len), broker.stats(.internal).free);
    try equal(@as(u32, external.len), broker.stats(.external).free);
}

test "identical slot tickets in different brokers do not authorize foreign operations" {
    var left: [4 * P]u8 align(P) = @splat(0);
    var right: [4 * P]u8 align(P) = @splat(0);
    const B = api.Broker(4, 1, 4, 2, 2);
    var a: B = .{};
    var b: B = .{};
    const config = policy(.kernel, 4 * P, 0);
    try expect(a.init(&.{.{ .memory = &left }}, &.{}, config));
    try expect(b.init(&.{.{ .memory = &right }}, &.{}, config));
    const owner_a = try a.open(.kernel, .{ .internal = 4 * P });
    const owner_b = try b.open(.kernel, .{ .internal = 4 * P });
    try equal(owner_a.slot, owner_b.slot);
    try equal(owner_a.ticket, owner_b.ticket);
    try expectError(error.Inactive, b.alloc(owner_a, .internal, P, 64));
    const lease_a = try a.alloc(owner_a, .internal, P, 64);
    const lease_b = try b.alloc(owner_b, .internal, P, 64);
    const pin_a = try a.pin(owner_a, lease_a);
    const pin_b = try b.pin(owner_b, lease_b);
    try equal(pin_a.token.ticket, pin_b.token.ticket);
    try expectError(error.InvalidPin, b.unpin(pin_a.token));
    try expectError(error.Busy, b.free(owner_b, lease_b));
    try a.unpin(pin_a.token);
    try b.unpin(pin_b.token);
    try a.free(owner_a, lease_a);
    try b.free(owner_b, lease_b);
}
