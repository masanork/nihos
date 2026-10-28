//! Resident stop mailbox. One owner issues tickets; other harts/IRQs publish
//! only a reason for that exact operation. No allocation, MMIO or u64 atomics.
const std = @import("std");
pub const Reason = enum { none, cancelled, removed };
pub const Signal = struct {
    word: std.atomic.Value(u32) = .init(0),
    removed: std.atomic.Value(bool) = .init(false),
    next_ticket: u32 = 1,
    pub const Control = struct {
        signal: *Signal,
        ticket: u32,
        pub inline fn stopReason(self: @This()) Reason {
            if (self.signal.removed.load(.acquire)) return .removed;
            const value = self.signal.word.load(.acquire);
            return if (value >> 2 != self.ticket) .removed else decode(value);
        }
        pub inline fn finishReason(self: @This()) Reason {
            var old = self.signal.word.load(.acquire);
            while (old >> 2 == self.ticket) {
                if (self.signal.word.cmpxchgWeak(old, 0, .acq_rel, .acquire)) |actual| old = actual else return if (self.signal.removed.load(.acquire)) .removed else decode(old);
            }
            return .removed; // A stale completion cannot close a newer ticket.
        }
    };
    pub fn begin(self: *@This()) ?Control {
        if (self.removed.load(.acquire) or self.word.load(.acquire) != 0 or self.next_ticket >= 1 << 30) return null;
        const ticket = self.next_ticket;
        self.next_ticket += 1; // No wrap, even after completion.
        self.word.store(ticket << 2, .release);
        return .{ .signal = self, .ticket = ticket };
    }
    pub inline fn active(self: *const @This()) u32 {
        return self.word.load(.acquire) >> 2;
    }
    /// Physical removal is sticky even between requests. Remount/reinsertion
    /// needs a fresh owner/controller session, never an IRQ-side reset.
    pub inline fn remove(self: *@This()) void {
        self.removed.store(true, .release);
        _ = self.stop(self.active(), 2);
    }
    pub inline fn stop(self: *@This(), ticket: u32, reason: u32) bool {
        if (ticket == 0 or ticket >= 1 << 30 or (reason != 1 and reason != 2)) return false;
        var old = self.word.load(.acquire);
        while (old >> 2 == ticket) {
            const desired = (ticket << 2) | @max(old & 3, reason);
            if (self.word.cmpxchgWeak(old, desired, .acq_rel, .acquire)) |actual| old = actual else return true;
        }
        return false;
    }
};
/// Ordinary-owner adapter: sample a captured upstream cancellation source and
/// publish only to this exact device ticket. Source.cancelled() must read only
/// resident words in native use. A stale adapter cannot stop a newer transfer.
/// Device stop/fence/descriptor/cache cleanup still belongs to the controller.
pub fn CancelRelay(comptime Source: type) type {
    return struct {
        target: Signal.Control,
        source: Source,
        inline fn forward(self: @This()) void {
            if (self.source.cancelled()) _ = self.target.signal.stop(self.target.ticket, 1);
        }
        pub inline fn stopReason(self: @This()) Reason {
            self.forward();
            return self.target.stopReason();
        }
        pub inline fn finishReason(self: @This()) Reason {
            self.forward();
            return self.target.finishReason();
        }
    };
}
inline fn decode(value: u32) Reason {
    return switch (value & 3) {
        0 => .none,
        1 => .cancelled,
        else => .removed,
    };
}
test "exact stop tickets reject stale cancellation and late completion" {
    var signal = Signal{};
    const first = signal.begin().?;
    try std.testing.expect(signal.begin() == null);
    try std.testing.expect(signal.stop(first.ticket, 1));
    try std.testing.expectEqual(Reason.cancelled, first.stopReason());
    try std.testing.expect(signal.stop(first.ticket, 2));
    try std.testing.expect(signal.stop(first.ticket, 1));
    try std.testing.expectEqual(Reason.removed, first.finishReason());
    const second = signal.begin().?;
    try std.testing.expect(!signal.stop(first.ticket, 2));
    try std.testing.expectEqual(Reason.removed, first.finishReason());
    try std.testing.expectEqual(second.ticket, signal.active());
    try std.testing.expectEqual(Reason.none, second.finishReason());
    try std.testing.expect(!signal.stop(second.ticket, 1));
}
test "invalid stop reasons and ticket exhaustion fail closed" {
    var signal = Signal{};
    try std.testing.expect(!signal.stop(0, 1));
    const control = signal.begin().?;
    try std.testing.expect(!signal.stop(control.ticket, 0));
    try std.testing.expect(!signal.stop(control.ticket, 3));
    _ = control.finishReason();
    signal.next_ticket = 1 << 30;
    try std.testing.expect(signal.begin() == null);
}
test "removal between transfers prevents issuing a new operation" {
    var signal = Signal{};
    const control = signal.begin().?;
    signal.remove();
    try std.testing.expectEqual(Reason.removed, control.stopReason());
    try std.testing.expectEqual(Reason.removed, control.finishReason());
    try std.testing.expect(signal.begin() == null);
    var idle_signal = Signal{};
    idle_signal.remove();
    try std.testing.expect(idle_signal.begin() == null);
}

test "late relay cannot stop or finish a reused device ticket" {
    const Source = struct {
        pub fn cancelled(_: @This()) bool {
            return true;
        }
    };
    var signal = Signal{};
    const first = signal.begin().?;
    try std.testing.expectEqual(Reason.none, first.finishReason());
    const next = signal.begin().?;
    const old = CancelRelay(Source){ .target = first, .source = .{} };
    try std.testing.expectEqual(Reason.removed, old.stopReason());
    try std.testing.expectEqual(Reason.removed, old.finishReason());
    try std.testing.expectEqual(next.ticket, signal.active());
    try std.testing.expectEqual(Reason.none, next.finishReason());
}

test "relay samples cancellation at completion and preserves removal priority" {
    const Source = struct {
        pub fn cancelled(_: @This()) bool {
            return true;
        }
    };
    var signal = Signal{};
    const first = CancelRelay(Source){ .target = signal.begin().?, .source = .{} };
    try std.testing.expectEqual(Reason.cancelled, first.finishReason());
    const next = CancelRelay(Source){ .target = signal.begin().?, .source = .{} };
    signal.remove();
    try std.testing.expectEqual(Reason.removed, next.stopReason());
    try std.testing.expectEqual(Reason.removed, next.finishReason());
    try std.testing.expect(signal.begin() == null);
}
