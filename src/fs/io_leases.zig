//! Owner-serialized request leases. Cancellation is a request to stop, never
//! proof that a device has stopped touching memory. No MMIO or allocator here.
const std = @import("std");
pub const Error = error{ StaleHandle, PermissionDenied, Busy, InvalidState, InvalidArgument, NoHandles };
pub const Reference = struct { slot: u16, generation: u64 };
pub const Handle = struct { slot: u16, generation: u64 };
pub const Fence = struct {
    device_idle: bool = false,
    descriptors_released: bool = false,
    cache_handed_back: bool = false,
    fn quiescent(self: Fence) bool {
        return self.device_idle and self.descriptors_released and self.cache_handed_back;
    }
};
pub const Outcome = enum { completed, cancelled, removed, failed };
pub const Completion = struct { mount: Reference, file: Reference, buffer_lease: u64, outcome: Outcome };
pub const Stage = enum { queued, active, stopping, terminal };

pub fn IoLeases(comptime capacity: usize) type {
    if (capacity == 0 or capacity > std.math.maxInt(u16)) @compileError("invalid I/O lease capacity");
    return struct {
        const Self = @This();
        const Request = struct {
            principal: u32,
            mount: Reference,
            file: Reference,
            buffer_lease: u64,
            stage: Stage = .queued,
            cancelled: bool = false,
            removed: bool = false,
            outcome: Outcome = .completed,
        };
        const Slot = struct { generation: u64 = 1, retired: bool = false, request: ?Request = null };
        slots: [capacity]Slot = @splat(.{}),

        pub fn retain(self: *Self, principal: u32, mount: Reference, file: Reference, buffer_lease: u64) Error!Handle {
            if (buffer_lease == 0) return error.InvalidArgument;
            for (self.slots) |slot| {
                if (slot.request) |request| {
                    if (request.buffer_lease == buffer_lease) return error.Busy;
                }
            }
            for (&self.slots, 0..) |*slot, index| {
                if (slot.request == null and !slot.retired) {
                    slot.request = .{ .principal = principal, .mount = mount, .file = file, .buffer_lease = buffer_lease };
                    return .{ .slot = @intCast(index), .generation = slot.generation };
                }
            }
            return error.NoHandles;
        }

        /// Trusted driver owner. Initial service serializes all transfers,
        /// including mounts that might share one physical controller.
        pub fn start(self: *Self, handle: Handle) Error!void {
            const request = try self.get(handle);
            if (request.stage != .queued) return error.InvalidState;
            if (self.deviceBusy()) return error.Busy;
            request.stage = .active;
        }

        pub fn cancel(self: *Self, principal: u32, handle: Handle) Error!void {
            const request = try self.get(handle);
            if (request.principal != principal) return error.PermissionDenied;
            if (request.stage == .terminal) return;
            request.cancelled = true;
            if (request.stage == .queued) {
                request.stage = .terminal;
                request.outcome = .cancelled;
            } else request.stage = .stopping;
        }

        pub fn removeMount(self: *Self, mount: Reference) void {
            for (&self.slots) |*slot| {
                if (slot.request) |*request| {
                    if (!same(request.mount, mount) or request.stage == .terminal) continue;
                    request.removed = true;
                    if (request.stage == .queued) {
                        request.stage = .terminal;
                        request.outcome = .removed;
                    } else request.stage = .stopping;
                }
            }
        }

        /// Driver must establish all three facts for this exact operation.
        /// Late/double completions cannot release a reused request slot.
        pub fn finish(self: *Self, handle: Handle, successful: bool, fence: Fence) Error!void {
            const request = try self.get(handle);
            if (request.stage != .active and request.stage != .stopping) return error.InvalidState;
            if (!fence.quiescent()) return error.Busy;
            request.outcome = if (request.removed) .removed else if (request.cancelled) .cancelled else if (successful) .completed else .failed;
            request.stage = .terminal;
        }

        pub fn stopRequired(self: *Self, handle: Handle) Error!bool {
            return (try self.get(handle)).stage == .stopping;
        }

        pub fn mountOf(self: *Self, handle: Handle) Error!Reference {
            return (try self.get(handle)).mount;
        }

        pub fn terminalOutcome(self: *Self, handle: Handle) Error!Outcome {
            const request = try self.get(handle);
            if (request.stage != .terminal) return error.Busy;
            return request.outcome;
        }

        pub fn take(self: *Self, principal: u32, handle: Handle) Error!Completion {
            const request = try self.get(handle);
            if (request.principal != principal) return error.PermissionDenied;
            return self.discard(handle);
        }

        /// Trusted owner cleanup after client death, still only after quiescence.
        pub fn discard(self: *Self, handle: Handle) Error!Completion {
            const request = (try self.get(handle)).*;
            if (request.stage != .terminal) return error.Busy;
            const result = Completion{ .mount = request.mount, .file = request.file, .buffer_lease = request.buffer_lease, .outcome = request.outcome };
            const slot = &self.slots[handle.slot];
            slot.request = null;
            if (slot.generation == std.math.maxInt(u64)) slot.retired = true else slot.generation += 1;
            return result;
        }

        pub fn holdsFile(self: *const Self, file: Reference) bool {
            for (self.slots) |slot| {
                if (slot.request) |request| {
                    if (same(request.file, file)) return true;
                }
            }
            return false;
        }

        pub fn holdsMount(self: *const Self, mount: Reference) bool {
            for (self.slots) |slot| {
                if (slot.request) |request| {
                    if (same(request.mount, mount)) return true;
                }
            }
            return false;
        }

        pub fn deviceBusy(self: *const Self) bool {
            for (self.slots) |slot| {
                if (slot.request) |request| {
                    if (request.stage == .active or request.stage == .stopping) return true;
                }
            }
            return false;
        }

        fn get(self: *Self, handle: Handle) Error!*Request {
            if (handle.slot >= capacity) return error.StaleHandle;
            const slot = &self.slots[handle.slot];
            if (slot.generation != handle.generation) return error.StaleHandle;
            if (slot.request) |*request| return request;
            return error.StaleHandle;
        }
    };
}

fn same(a: Reference, b: Reference) bool {
    return a.slot == b.slot and a.generation == b.generation;
}
