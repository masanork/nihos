//! Serialized, allocation-free VFS contract core. Call only from one owner.
//! Backend instances and their filesystem identities outlive every mounted
//! reference. No scheduler, device, durable-replace, or SQLite adapter here.
const std = @import("std");
pub const io = @import("io_leases.zig");

pub const Error = error{
    StaleHandle,
    PermissionDenied,
    ReadOnly,
    Unsupported,
    InvalidName,
    TooLarge,
    NoHandles,
    Busy,
    NotFound,
    IoError,
    Corrupt,
    RecoveryRequired,
    BackendContract,
} || io.Error;

pub const Principal = u32;
// Development profile at codex/storage-plan-tab5-budget, 67c991b.
// Public I/O quantum is distinct from the future 16 KiB SD DMA ceiling.
pub const standard_limits = struct {
    pub const mounts = 8;
    pub const open_objects = 32;
    pub const file_handles = 16;
    pub const io_bytes = 4096;
    pub const path_buffer_bytes = 512;
    pub const path_bytes = path_buffer_bytes - 1; // Reserve a terminating NUL.
};
pub const Rights = struct {
    read: bool = false,
    write: bool = false,

    fn contains(self: Rights, other: Rights) bool {
        return (!other.read or self.read) and (!other.write or self.write);
    }
};
pub const Capabilities = struct {
    read_at: bool = true,
    write_at: bool = false,
    sync_file: bool = false,
    sync_volume: bool = false,
    max_file_size: u64 = std.math.maxInt(u64),
    max_transfer: usize = standard_limits.io_bytes,
    max_path_bytes: usize = standard_limits.path_bytes,
};
pub const Policy = struct { writable: bool = false };
pub const Handle = struct { slot: u16, generation: u64 };
pub const Mount = struct { slot: u16, generation: u64 };
pub const Failure = enum { no_space, io_error, corrupt, removed, timed_out, outcome_unknown };
pub const Transfer = struct {
    transferred: usize = 0,
    eof: bool = false,
    failure: ?Failure = null,
};
pub const State = enum { mounted, removed, faulted };
pub const MountInfo = struct { capabilities: Capabilities, policy: Policy, state: State };

/// The backend resolves an existing relative name beneath its supplied root,
/// with no symlink or drive-prefix escape, into a stable file identity. Its
/// `open(identity, rights)` follows only that identity, not the original name.
/// Both calls run under the same owner; external writers are prohibited.
/// All callbacks are synchronous and must cease accessing passed buffers
/// before returning, including on timeout. Async/DMA lease handling belongs
/// in the later storage service, not in this contract core.
/// Required methods: lookupBeneath, open, close, readAt, writeAt, syncFile,
/// syncVolume. See vfs_test.zig for a fault-injectable backend example.
pub fn Vfs(comptime Backend: type, comptime mount_limit: usize, comptime handle_limit: usize) type {
    if (mount_limit == 0 or mount_limit > std.math.maxInt(u16) or
        handle_limit == 0 or handle_limit > std.math.maxInt(u16))
        @compileError("VFS table limits must fit a nonzero u16");
    return struct {
        const Self = @This();
        const Binding = struct {
            backend: *Backend,
            root: u64,
            capabilities: Capabilities,
            policy: Policy,
            state: State = .mounted,
        };
        const Resource = struct {
            mount: Mount,
            principal: Principal,
            rights: Rights,
            object: union(enum) { root: u64, file: struct { identity: u64, token: u64 } },
        };
        const MountSlot = struct { generation: u64 = 1, retired: bool = false, binding: ?Binding = null };
        const Slot = struct { generation: u64 = 1, retired: bool = false, resource: ?Resource = null };
        mounts: [mount_limit]MountSlot = @splat(.{}),
        handles: [handle_limit]Slot = @splat(.{}),
        requests: io.IoLeases(16) = .{},

        // Table mutations are trusted owner operations, not client syscalls.
        pub fn mount(self: *Self, backend: *Backend, root: u64, caps: Capabilities, policy: Policy) Error!Mount {
            if (caps.max_transfer == 0 or caps.max_transfer > standard_limits.io_bytes or
                caps.max_path_bytes == 0 or caps.max_path_bytes > standard_limits.path_bytes) return error.TooLarge;
            if (policy.writable and !caps.write_at) return error.Unsupported;
            for (&self.mounts) |slot| {
                if (slot.binding) |binding| {
                    if (binding.backend == backend) return error.Busy;
                }
            }
            for (&self.mounts, 0..) |*slot, index| {
                if (slot.binding == null and !slot.retired) {
                    slot.binding = .{ .backend = backend, .root = root, .capabilities = caps, .policy = policy };
                    return .{ .slot = @intCast(index), .generation = slot.generation };
                }
            }
            return error.NoHandles;
        }

        pub fn queryMount(self: *Self, handle: Mount) Error!MountInfo {
            const binding = try self.getMount(handle);
            return .{ .capabilities = binding.capabilities, .policy = binding.policy, .state = binding.state };
        }

        /// Owner grants a root; clients cannot supply rights or a backend root
        /// when making subsequent file requests. Root and file slots share a
        /// bounded table and are always checked against the caller principal.
        pub fn grantRoot(self: *Self, handle: Mount, principal: Principal, rights: Rights) Error!Handle {
            const binding = try self.activeMount(handle);
            try checkRights(binding.*, rights);
            const index = try self.freeSlot();
            self.handles[index].resource = .{
                .mount = handle,
                .principal = principal,
                .rights = rights,
                .object = .{ .root = binding.root },
            };
            return self.token(index);
        }

        /// Existing files only. Creation and namespace mutation are later gates.
        pub fn openAt(self: *Self, principal: Principal, root: Handle, path: []const u8, rights: Rights) Error!Handle {
            const parent = (try self.getResource(principal, root)).*;
            const directory = switch (parent.object) {
                .root => |value| value,
                .file => return error.PermissionDenied,
            };
            if (!parent.rights.contains(rights)) return error.PermissionDenied;
            const binding = try self.activeMount(parent.mount);
            if (self.requests.deviceBusy()) return error.Busy;
            try checkRights(binding.*, rights);
            try validatePath(path, binding.capabilities.max_path_bytes);
            const index = try self.freeSlot(); // Check capacity before any backend call; no re-entry is allowed.
            var file_count: usize = 0;
            for (&self.handles) |slot| {
                if (slot.resource) |resource| {
                    if (resource.object == .file) file_count += 1;
                }
            }
            if (file_count >= standard_limits.file_handles) return error.NoHandles;
            const identity = binding.backend.lookupBeneath(directory, path) catch |err| {
                observeError(binding, err);
                return err;
            };
            for (&self.handles) |slot| {
                const resource = slot.resource orelse continue;
                if (!sameMount(resource.mount, parent.mount)) continue;
                switch (resource.object) {
                    .root => {},
                    .file => |file| {
                        if (file.identity == identity and (rights.write or resource.rights.write)) return error.Busy;
                    },
                }
            }
            const backend_token = binding.backend.open(identity, rights) catch |err| {
                observeError(binding, err);
                return err;
            };
            self.handles[index].resource = .{
                .mount = parent.mount,
                .principal = principal,
                .rights = rights,
                .object = .{ .file = .{ .identity = identity, .token = backend_token } },
            };
            return self.token(index);
        }

        pub fn readAt(self: *Self, principal: Principal, handle: Handle, offset: u64, buffer: []u8) Error!Transfer {
            const resource = (try self.getResource(principal, handle)).*;
            const file = switch (resource.object) {
                .root => return error.PermissionDenied,
                .file => |value| value,
            };
            if (!resource.rights.read) return error.PermissionDenied;
            const binding = try self.activeMount(resource.mount);
            if (self.requests.deviceBusy()) return error.Busy;
            if (!binding.capabilities.read_at) return error.Unsupported;
            try checkRange(binding.capabilities, offset, buffer.len);
            const result = binding.backend.readAt(file.token, offset, buffer);
            try observe(binding, result, buffer.len, false);
            if (binding.state == .removed) self.requests.removeMount(reference(resource.mount));
            return result;
        }

        pub fn writeAt(self: *Self, principal: Principal, handle: Handle, offset: u64, buffer: []const u8) Error!Transfer {
            const resource = (try self.getResource(principal, handle)).*;
            const file = switch (resource.object) {
                .root => return error.PermissionDenied,
                .file => |value| value,
            };
            if (!resource.rights.write) return error.PermissionDenied;
            const binding = try self.activeMount(resource.mount);
            if (self.requests.deviceBusy()) return error.Busy;
            try checkRights(binding.*, .{ .write = true });
            try checkRange(binding.capabilities, offset, buffer.len);
            var result = binding.backend.writeAt(file.token, offset, buffer);
            // Once submitted, a timeout does not establish no side effects.
            if (result.failure == .timed_out) result.failure = .outcome_unknown;
            try observe(binding, result, buffer.len, true);
            if (binding.state == .removed) self.requests.removeMount(reference(resource.mount));
            return result;
        }

        pub fn syncFile(self: *Self, principal: Principal, handle: Handle) Error!void {
            const resource = (try self.getResource(principal, handle)).*;
            const file = switch (resource.object) {
                .root => return error.PermissionDenied,
                .file => |value| value,
            };
            if (!resource.rights.write) return error.PermissionDenied;
            const binding = try self.activeMount(resource.mount);
            if (self.requests.deviceBusy()) return error.Busy;
            if (!binding.capabilities.sync_file) return error.Unsupported;
            binding.backend.syncFile(file.token) catch |err| {
                binding.state = .faulted;
                return err;
            };
        }

        /// Live I/O returns Busy without revoking the handle. Once drained,
        /// close revokes it even on backend failure. A removed backend is not
        /// called; its owner must discard its remaining tokens at teardown.
        pub fn close(self: *Self, principal: Principal, handle: Handle) Error!void {
            const resource = (try self.getResource(principal, handle)).*;
            const binding = try self.getMount(resource.mount);
            if (self.requests.holdsFile(reference(handle))) return error.Busy;
            if (resource.object == .file and self.requests.deviceBusy()) return error.Busy;
            revoke(&self.handles[handle.slot]);
            switch (resource.object) {
                .root => {},
                .file => |file| {
                    if (binding.state == .removed) return;
                    binding.backend.close(file.token) catch |err| {
                        binding.state = .faulted;
                        return err;
                    };
                },
            }
        }

        /// Ordinary unmount never revokes live handles or claims clean success
        /// after an unsupported or failed volume-wide data/metadata flush.
        pub fn unmount(self: *Self, handle: Mount) Error!void {
            const binding = try self.activeMount(handle);
            if (self.requests.holdsMount(reference(handle)) or self.requests.deviceBusy()) return error.Busy;
            for (&self.handles) |slot| {
                if (slot.resource) |resource| {
                    if (sameMount(resource.mount, handle)) return error.Busy;
                }
            }
            if (binding.policy.writable) {
                if (!binding.capabilities.sync_volume) return error.Unsupported;
                binding.backend.syncVolume(binding.root) catch |err| {
                    binding.state = .faulted;
                    return err;
                };
            }
            retireMount(&self.mounts[handle.slot]);
        }

        /// Surprise removal stops future I/O immediately. It does not itself
        /// free backend resources or establish device/DMA quiescence.
        pub fn markRemoved(self: *Self, handle: Mount) Error!void {
            (try self.getMount(handle)).state = .removed;
            self.requests.removeMount(reference(handle));
        }

        /// Trusted teardown only: rejects retained I/O including unconsumed
        /// completions. Caller must also stop any out-of-registry device work.
        /// Revokes all references without calling the old backend. The caller
        /// must then destroy its mount-local open tokens before reusing it.
        pub fn detachQuiescent(self: *Self, handle: Mount) Error!void {
            _ = try self.getMount(handle);
            if (self.requests.holdsMount(reference(handle)) or self.requests.deviceBusy()) return error.Busy;
            for (&self.handles) |*slot| {
                if (slot.resource) |resource| {
                    if (sameMount(resource.mount, handle)) revoke(slot);
                }
            }
            retireMount(&self.mounts[handle.slot]);
        }

        /// Retain a trusted allocator's generation-bearing buffer lease until
        /// exactly one terminal completion is consumed. This does not start DMA.
        pub fn retainRead(self: *Self, principal: Principal, handle: Handle, buffer_lease: u64) Error!io.Handle {
            const resource = (try self.getResource(principal, handle)).*;
            if (resource.object != .file or !resource.rights.read) return error.PermissionDenied;
            _ = try self.activeMount(resource.mount);
            return self.requests.retain(principal, reference(resource.mount), reference(handle), buffer_lease);
        }

        pub fn startRead(self: *Self, request: io.Handle) Error!void {
            const mount_ref = try self.requests.mountOf(request);
            _ = try self.activeMount(.{ .slot = mount_ref.slot, .generation = mount_ref.generation });
            try self.requests.start(request);
        }

        pub fn cancelRead(self: *Self, principal: Principal, request: io.Handle) Error!void {
            try self.requests.cancel(principal, request);
        }

        pub fn readStopRequired(self: *Self, request: io.Handle) Error!bool {
            return self.requests.stopRequired(request);
        }

        /// Trusted driver owner supplies the fence after stop/reset, descriptor
        /// ownership and cache maintenance have actually completed.
        pub fn finishRead(self: *Self, request: io.Handle, successful: bool, fence: io.Fence) Error!void {
            const mount_ref = try self.requests.mountOf(request);
            const binding = try self.getMount(.{ .slot = mount_ref.slot, .generation = mount_ref.generation });
            try self.requests.finish(request, successful, fence);
            if (try self.requests.terminalOutcome(request) == .failed and binding.state == .mounted) binding.state = .faulted;
        }

        pub fn takeRead(self: *Self, principal: Principal, request: io.Handle) Error!io.Completion {
            return self.requests.take(principal, request);
        }

        pub fn discardRead(self: *Self, request: io.Handle) Error!io.Completion {
            return self.requests.discard(request);
        }

        fn getMount(self: *Self, handle: Mount) Error!*Binding {
            if (handle.slot >= mount_limit) return error.StaleHandle;
            const slot = &self.mounts[handle.slot];
            if (slot.generation != handle.generation) return error.StaleHandle;
            if (slot.binding) |*binding| return binding;
            return error.StaleHandle;
        }

        fn activeMount(self: *Self, handle: Mount) Error!*Binding {
            const binding = try self.getMount(handle);
            switch (binding.state) {
                .mounted => return binding,
                .removed => return error.StaleHandle,
                .faulted => return error.RecoveryRequired,
            }
        }

        fn getResource(self: *Self, principal: Principal, handle: Handle) Error!*Resource {
            if (handle.slot >= handle_limit) return error.StaleHandle;
            const slot = &self.handles[handle.slot];
            if (slot.generation != handle.generation) return error.StaleHandle;
            const resource = if (slot.resource) |*value| value else return error.StaleHandle;
            if (resource.principal != principal) return error.PermissionDenied;
            return resource;
        }

        fn freeSlot(self: *Self) Error!usize {
            for (&self.handles, 0..) |slot, index| {
                if (slot.resource == null and !slot.retired) return index;
            }
            return error.NoHandles;
        }

        fn token(self: *Self, index: usize) Handle {
            return .{ .slot = @intCast(index), .generation = self.handles[index].generation };
        }

        fn observeError(binding: *Binding, err: Error) void {
            switch (err) {
                error.Corrupt, error.IoError, error.RecoveryRequired, error.BackendContract => binding.state = .faulted,
                else => {},
            }
        }

        fn observe(binding: *Binding, result: Transfer, amount: usize, writing: bool) Error!void {
            if (result.transferred > amount or (writing and result.eof)) {
                binding.state = .faulted;
                return error.BackendContract;
            }
            if (result.failure) |failure| {
                switch (failure) {
                    .removed => binding.state = .removed,
                    .io_error, .corrupt, .outcome_unknown => binding.state = .faulted,
                    .timed_out => binding.state = .faulted,
                    .no_space => {},
                }
            }
        }

        fn revoke(slot: *Slot) void {
            slot.resource = null;
            if (slot.generation == std.math.maxInt(u64)) slot.retired = true else slot.generation += 1;
        }

        fn retireMount(slot: *MountSlot) void {
            slot.binding = null;
            if (slot.generation == std.math.maxInt(u64)) slot.retired = true else slot.generation += 1;
        }
    };
}

fn sameMount(a: Mount, b: Mount) bool {
    return a.slot == b.slot and a.generation == b.generation;
}

fn reference(handle: anytype) io.Reference {
    return .{ .slot = handle.slot, .generation = handle.generation };
}

fn checkRights(binding: anytype, rights: Rights) Error!void {
    if (!rights.read and !rights.write) return error.PermissionDenied;
    if (rights.read and !binding.capabilities.read_at) return error.Unsupported;
    if (rights.write) {
        if (!binding.policy.writable) return error.ReadOnly;
        if (!binding.capabilities.write_at) return error.Unsupported;
    }
}

fn checkRange(caps: Capabilities, offset: u64, amount: usize) Error!void {
    if (amount > caps.max_transfer or offset > caps.max_file_size or
        amount > caps.max_file_size - offset) return error.TooLarge;
}

fn validatePath(path: []const u8, limit: usize) Error!void {
    if (path.len == 0) return error.InvalidName;
    if (path.len > limit) return error.TooLarge;
    if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidName;
    if (std.mem.indexOfAny(u8, path, "\x00\\:")) |_| return error.InvalidName;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidName;
    }
}
