//! One producer and one consumer exchange values through a bounded ring.
//! The event port supplies latched doorbells; queue state is authoritative.
//! Reserve one event bit on each endpoint and keep both endpoints and their
//! queue alive until neither owner can access them. No MPMC or close protocol.

pub fn SpscChannel(comptime Ring: type, comptime Events: type) type {
    return struct {
        const Self = @This();
        pub const SendResult = union(enum) {
            sent,
            full,
            // Ownership has transferred to the queue. Retrying this item
            // would duplicate it; notification failure cannot roll it back.
            published_unnotified: i32,
            wait_failed: i32,
        };
        pub const ReceiveResult = union(enum) {
            item: struct { value: Ring.Item, space_notification: i32 },
            empty,
            wait_failed: i32,
        };

        ring: Ring,
        events: Events,
        producer: Events.Handle,
        consumer: Events.Handle,
        readable: u32,
        writable: u32,

        pub fn init(events: Events, producer: Events.Handle, consumer: Events.Handle, readable: u32, writable: u32) ?Self {
            if (!singleBit(readable) or !singleBit(writable)) return null;
            return .{
                .ring = Ring.init(),
                .events = events,
                .producer = producer,
                .consumer = consumer,
                .readable = readable,
                .writable = writable,
            };
        }

        fn singleBit(bits: u32) bool {
            return bits != 0 and bits & (bits - 1) == 0;
        }

        /// Producer-only. Publish before notifying, even if the peer already
        /// appears runnable. Snapshot-based notification suppression is racy.
        pub fn trySend(self: *Self, item: Ring.Item) SendResult {
            if (!self.ring.tryPush(item)) return .full;
            const status = self.events.post(self.consumer, self.readable);
            return if (status == 0) .sent else .{ .published_unnotified = status };
        }

        /// Producer-only. A stale space event may cause one more queue check;
        /// it is not permission to overwrite a full queue.
        pub fn send(self: *Self, item: Ring.Item) SendResult {
            while (true) {
                const result = self.trySend(item);
                switch (result) {
                    .full => switch (self.events.wait(self.writable)) {
                        .received => {},
                        .failed => |code| return .{ .wait_failed = code },
                    },
                    else => return result,
                }
            }
        }

        /// Consumer-only. The value remains valid even if notifying the
        /// producer fails; it was copied before releasing the slot.
        pub fn tryReceive(self: *Self) ReceiveResult {
            const item = self.ring.tryPop() orelse return .empty;
            return .{ .item = .{
                .value = item,
                .space_notification = self.events.post(self.producer, self.writable),
            } };
        }

        /// Consumer-only. Recheck the queue after every doorbell, including
        /// preposted/stale events. Data may arrive in the check-to-wait gap.
        pub fn receive(self: *Self) ReceiveResult {
            while (true) {
                const result = self.tryReceive();
                switch (result) {
                    .empty => switch (self.events.wait(self.readable)) {
                        .received => {},
                        .failed => |code| return .{ .wait_failed = code },
                    },
                    else => return result,
                }
            }
        }
    };
}
