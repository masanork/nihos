//! One copied item in caller-owned storage. Only cursors/pointer stay resident.
//! One producer and one consumer, with the same publication order as SpscRing.
//! Bind before admitting either endpoint. Storage must outlive both endpoints;
//! detach requires external proof that neither endpoint can access it again.
const std = @import("std");

pub fn SpscMailbox(comptime T: type) type {
    return struct {
        const Self = @This();
        pub const Item = T;
        write: std.atomic.Value(usize) align(128) = .init(0),
        read: std.atomic.Value(usize) align(128) = .init(0),
        storage: ?*T = null,
        admitted: bool = false,

        pub fn init() Self {
            return .{};
        }

        /// Owner-only, once, before publication of the endpoints. Does not read
        /// uninitialized payload storage; the first push initializes it. Payload
        /// storage must not overlap this mailbox metadata.
        pub fn bindStorage(self: *Self, storage: *T) bool {
            if (self.admitted) return false;
            const owner = @intFromPtr(self);
            const payload = @intFromPtr(storage);
            if (if (owner <= payload) payload - owner < @sizeOf(Self) else owner - payload < @sizeOf(T)) return false;
            self.storage = storage;
            self.admitted = true;
            return true;
        }

        pub fn tryPush(self: *Self, item: T) bool {
            const storage = self.storage orelse return false;
            const write = self.write.load(.monotonic);
            if (write != self.read.load(.acquire)) return false;
            storage.* = item;
            self.write.store(write +% 1, .release);
            return true;
        }

        pub fn tryPop(self: *Self) ?T {
            const storage = self.storage orelse return null;
            const read = self.read.load(.monotonic);
            if (read == self.write.load(.acquire)) return null;
            const item = storage.*;
            self.read.store(read +% 1, .release);
            return item;
        }

        pub fn countApprox(self: *const Self) usize {
            while (true) {
                const before = self.read.load(.acquire);
                const write = self.write.load(.acquire);
                if (before == self.read.load(.acquire)) return write -% before;
            }
        }

        /// Owner-only AFTER both endpoints are quiescent (e.g. terminal ACK,
        /// worker reap and no further submissions). Empty alone is insufficient.
        /// A detached mailbox cannot be rebound, pushed or popped. Cursors can
        /// still be inspected without touching the retired payload.
        pub fn detachAfterQuiescence(self: *Self) ?*T {
            if (self.countApprox() != 0) return null;
            const storage = self.storage orelse return null;
            self.storage = null;
            return storage;
        }
    };
}
