//! Experimental exclusive Hosted UDP stream owner. No normal-boot integration.
const std = @import("std");
const hosted = @import("hosted.zig");
const split = @import("hosted_network_split.zig");
const sock = @import("hosted_udp_socket.zig");
const lease = @import("hosted_udp_lease.zig");
const sender = @import("hosted_udp_sender.zig");

pub const Send = enum { idle, pending, sent };
pub const Progress = struct { frames: u16 = 0, accepted: u16 = 0, dropped: u16 = 0, invalid: u16 = 0, send: Send = .idle };

/// Holds the sole decoder and serializes access to the supplied stream and
/// split state. The caller owns ARP, control handling, transport reset, DMA
/// quiescence, monotonic time and all synchronization with other producers.
/// Inputs are borrowed only during callbacks; output datagrams are copied.
pub const Owner = struct {
    socket: sock.Socket = .{},
    decoder: hosted.Decoder = .{},
    rx: [512]u8 = @splat(0),
    last_now: u64 = 0,
    retired: bool = false,

    pub fn bind(self: *Owner, state: *split.State, mac: [6]u8, port: u16, routed: lease.PortRange) !sock.Handle {
        if (self.retired) return error.Retired;
        return self.socket.bind(state, mac, port, routed);
    }

    /// Processes at most one RX chunk. The handler must synchronously apply
    /// control and station events, invalidate the split state on link loss,
    /// and never retain frame data or reenter this owner. Station frames are
    /// also passed to it before UDP demultiplexing. A full receive slot drops
    /// only that UDP datagram and records the loss in this turn's progress.
    /// A fresh peer INIT, malformed stream or callback/transport failure
    /// retires the socket and stream; the caller must reset and quiesce DMA.
    pub fn step(self: *Owner, handle: sock.Handle, stream: anytype, handler: anytype, now: u64) !Progress {
        if (self.retired) return error.Retired;
        const active = self.socket.current != null and std.meta.eql(self.socket.current.?, handle);
        self.socket.check(handle) catch |err| {
            // A stray old handle must not invalidate a new socket's stream.
            if (active) {
                self.retired = true;
                stream.invalidate();
            }
            return err;
        };
        const bound = self.socket.sender.?.binding;
        const state = self.socket.sender.?.state;
        errdefer {
            // A stream reset invalidates every handle on this address epoch.
            // Never revoke a newer address acquired by another owner turn.
            if (bound.check(state)) |_| {
                _ = state.invalidate();
            } else |_| {}
            self.retired = true;
            self.socket.invalidate();
            stream.invalidate();
        }
        if (now < self.last_now) return error.Deadline;
        self.last_now = now;
        if (self.decoder.poisoned) return error.Malformed;
        if (self.socket.sender) |*outbound| {
            // Match Sender.step: a timed-out queued send must retire before
            // any further transport reads or control callbacks.
            if (outbound.phase == .queued and (now < outbound.last_now or now >= outbound.deadline)) {
                _ = try self.socket.pollSend(handle, stream, now, &self.decoder, false);
                unreachable;
            }
        }
        const n = try stream.receive(&self.rx);
        if (n > self.rx.len) return error.InvalidBuffer;
        var progress: Progress = .{};
        for (self.rx[0..n]) |byte| if (try self.decoder.push(byte)) |frame| {
            progress.frames +|= 1;
            if (frame.interface == 5) return error.Stale;
            try handler.receive(frame, now);
            try self.socket.check(handle);
            if (frame.interface == hosted.station_interface) {
                const accepted = self.socket.receive(handle, frame) catch |err| switch (err) {
                    error.ReceiveFull => blk: {
                        progress.dropped +|= 1;
                        break :blk false;
                    },
                    error.Truncated, error.Malformed, error.Checksum, error.TooLarge, error.InvalidPort => blk: {
                        progress.invalid +|= 1;
                        break :blk false;
                    },
                    else => return err,
                };
                if (accepted) progress.accepted +|= 1;
            }
        };
        const pending = if (self.socket.sender) |*value| value.phase == .queued else return error.StaleHandle;
        if (pending) {
            const outcome = try self.socket.pollSend(handle, stream, now, &self.decoder, n == 0);
            progress.send = if (outcome == sender.Outcome.sent) .sent else .pending;
        }
        return progress;
    }
};
