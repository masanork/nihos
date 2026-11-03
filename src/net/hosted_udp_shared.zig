//! Experimental UDP adapter for a network owner that already owns the
//! Hosted decoder, station/control processing, and shared transport.
const std = @import("std");
const hosted = @import("hosted.zig");
const split = @import("hosted_network_split.zig");
const sock = @import("hosted_udp_socket.zig");
const lease = @import("hosted_udp_lease.zig");
const sender = @import("hosted_udp_sender.zig");

pub const Receive = enum { unrelated, accepted, dropped, invalid };
pub const Send = enum { idle, pending, sent };

/// A single owner serializes all producers, shared decoder, callbacks and I/O.
/// This object does not retain a decoder, arbitrate in-flight DMA or resolve
/// ARP. Address State and transport must remain valid for the socket lifetime.
pub const Shared = struct {
    socket: sock.Socket = .{},
    retired: bool = false,

    pub fn bind(self: *Shared, state: *split.State, mac: [6]u8, port: u16, routed: lease.PortRange) !sock.Handle {
        if (self.retired) return error.Retired;
        return self.socket.bind(state, mac, port, routed);
    }

    /// Call only after the shared owner has processed the exact frame and all
    /// related control events. On overflow the old datagram stays queued and
    /// `dropped` must be accounted by the caller. Borrowed frame data is copied.
    pub fn receiveProcessed(self: *Shared, handle: sock.Handle, frame: hosted.Frame) !Receive {
        if (self.retired) return error.Retired;
        const active = self.socket.current != null and std.meta.eql(self.socket.current.?, handle);
        self.socket.check(handle) catch |err| {
            // No stream is available here. A current stale lease retires this
            // adapter; the shared owner must invalidate and recover transport.
            if (active) self.retired = true;
            return err;
        };
        if (frame.interface != hosted.station_interface) {
            return .unrelated;
        }
        const accepted = self.socket.receive(handle, frame) catch |err| switch (err) {
            error.ReceiveFull => return .dropped,
            error.Truncated, error.Malformed, error.Checksum, error.TooLarge, error.InvalidPort => return .invalid,
            else => return err,
        };
        return if (accepted) .accepted else .unrelated;
    }

    /// The caller supplies a true drained flag only after an empty read and
    /// after all prior decoded control events were applied. Station or other
    /// producers take priority when indicated; a queued UDP frame is still
    /// checked for its deadline but no write is attempted. Expiration cancels
    /// an unsent socket without retiring the shared stream. A zero-credit
    /// attempt starts no transfer and allows other producers to run. A partial
    /// or failed write retires the stream; recovery and DMA quiescence remain
    /// the caller's duty. A stale old handle cannot retire a newer stream.
    pub fn poll(self: *Shared, handle: sock.Handle, stream: anytype, decoder: *const hosted.Decoder, now: u64, drained: bool, station_pending: bool, other_pending: bool) !Send {
        if (self.retired) return error.Retired;
        const active = self.socket.current != null and std.meta.eql(self.socket.current.?, handle);
        self.socket.check(handle) catch |err| {
            if (active) {
                self.retired = true;
                stream.invalidate();
            }
            return err;
        };
        const active_sender = if (self.socket.sender) |*value| value else return error.StaleHandle;
        if (decoder.poisoned) {
            const bound = active_sender.binding;
            const state = active_sender.state;
            if (bound.check(state)) |_| {
                _ = state.invalidate();
            } else |_| {}
            self.socket.invalidate();
            self.retired = true;
            stream.invalidate();
            return error.Malformed;
        }
        const pending = active_sender.phase == .queued;
        if (!pending) return .idle;
        if (now < active_sender.last_now or now >= active_sender.deadline) {
            // A queued sender has only seen zero writes or no poll at all.
            // Closing it is safe without disrupting other shared producers.
            try self.socket.close(handle);
            return error.Deadline;
        }
        const allowed = drained and !station_pending and !other_pending;
        const bound = self.socket.sender.?.binding;
        const state = self.socket.sender.?.state;
        const outcome = self.socket.pollSend(handle, stream, now, decoder, allowed) catch |err| {
            // Retiring this stream must revoke its old address epoch, but not
            // destroy a newer address installed by the shared owner.
            if (bound.check(state)) |_| {
                _ = state.invalidate();
            } else |_| {}
            self.retired = true;
            return err;
        };
        return if (outcome == sender.Outcome.sent) .sent else .pending;
    }
};
