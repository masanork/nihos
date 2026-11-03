//! Bounded, single-owner Hosted UDP socket experiment. Not a runtime API.
//! The network owner serializes every call, stream access and control event.
const std = @import("std");
const split = @import("hosted_network_split.zig");
const hosted = @import("hosted.zig");
const lease_mod = @import("hosted_udp_lease.zig");
const frame = @import("hosted_udp_frame.zig");
const wire = @import("udp_ipv4.zig");
const tx = @import("hosted_udp_sender.zig");

pub const Handle = struct { generation: u64, id: u64 };
pub const Error = tx.Error || error{ StaleHandle, IdExhausted, ReceiveFull, BufferTooSmall };
pub const Received = struct { source: wire.Endpoint, bytes: usize };

/// One bound port, one pending transmit, and one copied receive datagram.
/// An address snapshot or generation change revokes the handle. This object
/// does not allocate a port, resolve ARP, authenticate a peer, schedule I/O,
/// or establish hardware quiescence. The supplied State must outlive it.
pub const Socket = struct {
    current: ?Handle = null,
    next_id: u64 = 0,
    sender: ?tx.Sender = null,
    send_limit: usize = 0,
    received: bool = false,
    source: wire.Endpoint = .{ .mac = @splat(0), .ip = @splat(0), .port = 0 },
    rx: [frame.max_payload]u8 = @splat(0),
    rx_len: usize = 0,

    pub fn bind(self: *Socket, state: *split.State, mac: [6]u8, port: u16, routed: lease_mod.PortRange) Error!Handle {
        return self.bindLimited(state, mac, port, routed, frame.max_payload);
    }

    /// Set the transport's payload limit at bind time. The caller must choose
    /// a limit justified by its actual SDIO/DMA provider and peer profile.
    pub fn bindLimited(self: *Socket, state: *split.State, mac: [6]u8, port: u16, routed: lease_mod.PortRange, max_payload: usize) Error!Handle {
        if (self.current != null) return error.Busy;
        if (self.next_id == std.math.maxInt(u64)) return error.IdExhausted;
        if (max_payload > frame.max_payload) return error.InvalidBinding;
        const bound = try lease_mod.Lease.open(state, mac, port, routed);
        self.sender = try tx.Sender.init(state, bound);
        self.send_limit = max_payload;
        self.next_id += 1;
        const handle = Handle{ .generation = bound.generation, .id = self.next_id };
        self.current = handle;
        return handle;
    }

    /// Caller resolves and validates next-hop ownership separately. Payload is
    /// copied; one queued packet provides bounded backpressure.
    pub fn sendTo(self: *Socket, handle: Handle, peer: wire.Endpoint, bytes: []const u8, sequence: u16, now: u64, deadline: u64) Error!void {
        const sender = try self.get(handle);
        if (bytes.len > self.send_limit) return error.TooLarge;
        try sender.enqueue(peer, bytes, sequence, now, deadline);
    }

    /// Caller has drained the shared stream and applied all Hosted control
    /// events. An empty read and complete decoder are required to transmit.
    /// A transport error or ambiguous write retires this socket; the shared
    /// transport's recovery and DMA quiescence remain the owner's duty.
    pub fn pollSend(self: *Socket, handle: Handle, stream: anytype, now: u64, decoder: *const hosted.Decoder, drained: bool) !tx.Outcome {
        // Only the current handle may retire the transport; a stray old handle
        // must not disrupt a later socket on the same owner.
        if (self.current != null and std.meta.eql(self.current.?, handle)) {
            if (self.sender) |*active| active.binding.check(active.state) catch {
                stream.invalidate();
                self.retire();
                return error.StaleHandle;
            };
        }
        const sender = try self.get(handle);
        if (sender.phase != .queued) return error.Busy;
        return sender.poll(stream, now, decoder, drained) catch |err| {
            self.retire();
            return err;
        };
    }

    /// On ReceiveFull the caller must account for loss or hold the incoming
    /// frame in its own bounded queue; the prior datagram is not overwritten.
    /// Unrelated frames return false. Malformed UDP is reported to the owner.
    pub fn receive(self: *Socket, handle: Handle, incoming: hosted.Frame) Error!bool {
        const sender = try self.get(handle);
        const datagram = sender.binding.receive(sender.state, incoming) catch |err| switch (err) {
            error.Unsupported => return false,
            else => return err,
        } orelse return false;
        if (self.received) return error.ReceiveFull;
        if (datagram.payload.len > self.rx.len) return error.TooLarge;
        @memcpy(self.rx[0..datagram.payload.len], datagram.payload);
        self.rx_len = datagram.payload.len;
        self.source = datagram.source;
        self.received = true;
        return true;
    }

    /// Null means no datagram. Zero bytes in a non-null result is a valid UDP
    /// datagram. An undersized output leaves the datagram queued for retry.
    pub fn read(self: *Socket, handle: Handle, out: []u8) Error!?Received {
        _ = try self.get(handle);
        if (!self.received) return null;
        if (out.len < self.rx_len) return error.BufferTooSmall;
        @memcpy(out[0..self.rx_len], self.rx[0..self.rx_len]);
        const result = Received{ .source = self.source, .bytes = self.rx_len };
        std.crypto.secureZero(u8, self.rx[0..self.rx_len]);
        self.rx_len = 0;
        self.received = false;
        return result;
    }

    /// Serialized close discards one queued unsent TX and pending RX; it must
    /// not run concurrently with pollSend or a hardware DMA operation.
    pub fn close(self: *Socket, handle: Handle) Error!void {
        const sender = try self.get(handle);
        if (sender.phase == .queued) try sender.cancel();
        self.retire();
    }
    /// Revalidate without consuming a datagram or mutating the transport.
    pub fn check(self: *Socket, handle: Handle) Error!void {
        _ = try self.get(handle);
    }
    pub fn invalidate(self: *Socket) void {
        self.retire();
    }
    fn get(self: *Socket, handle: Handle) Error!*tx.Sender {
        if (self.current == null or !std.meta.eql(self.current.?, handle)) return error.StaleHandle;
        const sender = if (self.sender) |*value| value else return error.StaleHandle;
        sender.binding.check(sender.state) catch {
            self.retire();
            return error.StaleHandle;
        };
        return sender;
    }
    fn retire(self: *Socket) void {
        if (self.sender) |*value| {
            std.crypto.secureZero(u8, &value.packet);
            std.crypto.secureZero(u8, &value.padding);
        }
        std.crypto.secureZero(u8, &self.rx);
        self.sender = null;
        self.current = null;
        self.received = false;
        self.rx_len = 0;
        self.send_limit = 0;
    }
};
