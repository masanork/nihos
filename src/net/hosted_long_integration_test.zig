const std = @import("std");
const dma = @import("hosted_long_dma.zig");
const guard = @import("hosted_long_dma_guard.zig");
const sender = @import("hosted_long_sender.zig");
const sd = @import("../soc/esp32p4/sdio.zig");
const split = @import("hosted_network_split.zig");
const lease = @import("hosted_udp_lease.zig");
const udp_sender = @import("hosted_udp_sender.zig");
const hosted = @import("hosted.zig");
const bus_adapter = @import("hosted_dma_bus.zig");

const Failure = enum { none, data_cache, desc_cache, timeout, stop_timeout, invalidate, owned, desc_error };
const Backend = struct {
    failure: Failure = .none,
    writebacks: usize = 0,
    invalidations: usize = 0,
    pub fn address(_: *@This(), ptr: anytype) ?u32 {
        if (@intFromPtr(ptr) % 64 != 0) return null;
        return 0x4ff10000;
    }
    pub fn writeback(self: *@This(), _: usize, _: usize) bool {
        self.writebacks += 1;
        return !((self.failure == .data_cache and self.writebacks == 1) or
            (self.failure == .desc_cache and self.writebacks == 2));
    }
    pub fn invalidate(self: *@This(), _: usize, _: usize) bool {
        self.invalidations += 1;
        return self.failure != .invalidate;
    }
    pub fn fence(_: *@This()) void {}
};

const Io = struct {
    regs: [64]u32 = @splat(0),
    buffer: dma.Buffer = .{},
    backend: Backend = .{},
    stops: usize = 0,
    transfers: usize = 0,
    finishes: usize = 0,
    complete_adapter: bool = false,
    pub fn read(self: *@This(), address: usize) u32 {
        return switch (address) {
            sd.regs.ctrl => if (self.backend.failure == .stop_timeout and self.stops > 0) 4 else 0,
            sd.regs.command, sd.regs.dma_mode, sd.regs.dma_status => 0,
            sd.regs.interrupts => (1 << 2) | (if (self.backend.failure == .timeout or self.backend.failure == .stop_timeout) @as(u32, 0) else 1 << 3),
            else => self.regs[address / 4],
        };
    }
    pub fn write(self: *@This(), address: usize, value: u32) void {
        self.regs[address / 4] = value;
        if (address == sd.regs.command and value & 63 == 53) {
            self.transfers += 1;
            if (self.complete_adapter and self.backend.failure != .owned and
                self.backend.failure != .timeout and self.backend.failure != .stop_timeout)
            {
                self.buffer.descriptor[0] &= ~(@as(u32, 1) << 31);
                if (self.backend.failure == .desc_error) self.buffer.descriptor[0] |= @as(u32, 1) << 30;
            }
        }
        if (address == sd.regs.dma_mode and value == 0) self.stops += 1;
    }
    pub fn delay(_: *@This(), _: u32) void {}
    pub fn prepareDma(self: *@This(), writing: bool, source: []const u8, length: usize) ?u32 {
        if (!writing or source.len != length) return null;
        return self.buffer.prepare(source, &self.backend);
    }
    pub fn finishDma(self: *@This(), writing: bool, destination: []u8) bool {
        self.finishes += 1;
        if (!writing or destination.len != 0 or self.stops == 0) return false;
        if (self.backend.failure != .owned) self.buffer.descriptor[0] &= ~(@as(u32, 1) << 31);
        if (self.backend.failure == .desc_error) self.buffer.descriptor[0] |= @as(u32, 1) << 30;
        return self.buffer.finish(&self.backend);
    }
};

const AdaptedBus = bus_adapter.Bus(*Io, Backend);
const AdaptedHost = struct {
    pub const TransportError = sd.Error;
    controller: sd.Controller(*AdaptedBus),
    credits: u32 = 1,
    pub fn readWord(self: *@This(), address: u32) TransportError!u32 {
        if (address == @import("c6_sdio.zig").length_register) return 0;
        return self.credits << 16;
    }
    pub fn writeWord(self: *@This(), address: u32, value: u32) TransportError!void {
        try self.controller.writeWord(address, value);
    }
    pub fn readBytes(self: *@This(), address: u32, destination: []u8) TransportError!void {
        try self.controller.readBytes(address, destination);
    }
    pub fn writeBytes(self: *@This(), address: u32, bytes: []const u8) TransportError!void {
        try self.controller.writeBytes(address, bytes);
    }
    pub fn writeBlocks(self: *@This(), address: u32, bytes: []const u8) TransportError!void {
        try self.controller.writeBlocks(address, bytes);
    }
};
const Host = struct {
    pub const TransportError = sd.Error;
    controller: sd.Controller(*Io),
    credits: u32 = 1,
    pub fn readWord(self: *@This(), address: u32) TransportError!u32 {
        if (address == @import("c6_sdio.zig").length_register) return 0;
        return self.credits << 16;
    }
    pub fn writeWord(self: *@This(), address: u32, value: u32) TransportError!void {
        try self.controller.writeWord(address, value);
    }
    pub fn readBytes(self: *@This(), address: u32, destination: []u8) TransportError!void {
        try self.controller.readBytes(address, destination);
    }
    pub fn writeBytes(self: *@This(), address: u32, bytes: []const u8) TransportError!void {
        try self.controller.writeBytes(address, bytes);
    }
    pub fn writeBlocks(self: *@This(), address: u32, bytes: []const u8) TransportError!void {
        try self.controller.writeBlocks(address, bytes);
    }
};

test "sender controller and DMA buffer complete one padded transaction" {
    var io: Io = .{};
    var host: Host = .{ .controller = .{ .io = &io, .prepared = true, .selected = true, .four_bit = true, .poll_limit = 2 } };
    var guarded: guard.Guard(Host) = .{ .host = &host, .buffer = &io.buffer };
    var stream = sender.ProfileStream(@TypeOf(guarded), 64){ .host = &guarded };
    var tx = sender.Sender(@TypeOf(guarded), 64){ .stream = &stream };
    const packet: [1254]u8 = @splat(0x5a);
    try std.testing.expectEqual(@as(usize, packet.len), try tx.send(&packet));
    try std.testing.expectEqual(@as(u32, 1), stream.sent_buffers);
    try std.testing.expectEqual(@as(usize, 1), io.transfers);
    try std.testing.expectEqual(@as(usize, 1), io.finishes);
    try std.testing.expectEqual(@as(usize, 1), io.stops);
    try std.testing.expectEqual(dma.State.idle, io.buffer.state);
    try std.testing.expectEqual(@as(u32, 1536), io.buffer.descriptor[1]);
    try std.testing.expectEqualSlices(u8, &packet, io.buffer.data[0..packet.len]);
    try std.testing.expect(std.mem.allEqual(u8, io.buffer.data[packet.len..], 0));
    try std.testing.expectEqual(@as(usize, 2), io.backend.writebacks);
    try std.testing.expectEqual(@as(usize, 1), io.backend.invalidations);
    host.credits = 2;
    const shorter: [513]u8 = @splat(0x37);
    try std.testing.expectEqual(@as(usize, shorter.len), try tx.send(&shorter));
    try std.testing.expectEqual(@as(u32, 2), stream.sent_buffers);
    try std.testing.expectEqual(@as(u32, 1024), io.buffer.descriptor[1]);
    try std.testing.expectEqualSlices(u8, &shorter, io.buffer.data[0..shorter.len]);
    try std.testing.expect(std.mem.allEqual(u8, io.buffer.data[shorter.len..], 0));
    try std.testing.expectEqual(dma.State.idle, io.buffer.state);
}

const Dispatch = struct {
    pub fn receive(_: *@This(), _: hosted.Frame, _: u64) error{DispatchFailed}!void {}
};

const ForwardHost = struct {
    pub const TransportError = error{Failed};
    operations: u32 = 0,
    fail: bool = false,
    pub fn readWord(self: *@This(), _: u32) TransportError!u32 {
        self.operations += 1;
        if (self.fail) return error.Failed;
        return 42;
    }
    pub fn writeWord(self: *@This(), _: u32, _: u32) TransportError!void {
        self.operations += 1;
        if (self.fail) return error.Failed;
    }
    pub fn readBytes(self: *@This(), _: u32, data: []u8) TransportError!void {
        self.operations += 1;
        if (self.fail) return error.Failed;
        @memset(data, 0x5a);
    }
    pub fn writeBytes(self: *@This(), _: u32, _: []const u8) TransportError!void {
        self.operations += 1;
        if (self.fail) return error.Failed;
    }
};

test "DMA guard forwards shared short and receive operations" {
    var buffer: dma.Buffer = .{};
    var host: ForwardHost = .{};
    var guarded: guard.Guard(ForwardHost) = .{ .host = &host, .buffer = &buffer };
    try std.testing.expectEqual(@as(u32, 42), try guarded.readWord(1));
    try guarded.writeWord(2, 3);
    var bytes: [4]u8 = undefined;
    try guarded.readBytes(4, &bytes);
    try std.testing.expect(std.mem.allEqual(u8, &bytes, 0x5a));
    try guarded.writeBytes(5, &bytes);
    try std.testing.expectEqual(@as(u32, 4), host.operations);
    try std.testing.expectEqual(dma.State.idle, buffer.state);
    host.fail = true;
    try std.testing.expectError(error.Failed, guarded.readBytes(4, &bytes));
    try std.testing.expectError(error.Failed, guarded.writeBytes(5, &bytes));
    try std.testing.expectEqual(dma.State.idle, buffer.state);
}

test "UDP owner uses guarded controller and quarantines failed DMA" {
    for (0..2) |case| {
        var io: Io = .{ .backend = .{ .failure = if (case == 0) .none else .invalidate } };
        var host: Host = .{ .controller = .{ .io = &io, .prepared = true, .selected = true, .four_bit = true, .poll_limit = 2 } };
        var guarded: guard.Guard(Host) = .{ .host = &host, .buffer = &io.buffer };
        var stream: sender.ProfileStream(@TypeOf(guarded), 64) = .{ .host = &guarded };
        var state: split.State = .{ .generation = 7, .address = .{ .ip = 0xc0000201, .mask = 0xffffff00, .gateway = 0xc00002fe, .dns = 0xc00002fe } };
        const binding = try lease.Lease.open(&state, .{ 2, 0, 0, 0, 0, 1 }, 49152, .{ .first = 49152, .last = 61439 });
        var tx = try udp_sender.Sender.init(&state, binding);
        const destination = @import("udp_ipv4.zig").Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 2 }, .ip = .{ 192, 0, 2, 2 }, .port = 443 };
        const payload: [1200]u8 = @splat(0x5a);
        try tx.enqueue(destination, &payload, 1, 1, 50);
        var decoder: hosted.Decoder = .{};
        var dispatch: Dispatch = .{};
        var rx: [512]u8 = undefined;
        if (case == 0) {
            try std.testing.expectEqual(udp_sender.Outcome.sent, try tx.step(&stream, &decoder, &dispatch, &rx, 2));
            try std.testing.expectEqual(dma.State.idle, io.buffer.state);
            try std.testing.expectEqual(@as(u32, 1536), io.buffer.descriptor[1]);
            const packet = try @import("udp_ipv4.zig").decode(io.buffer.data[12..1254]);
            try std.testing.expectEqualSlices(u8, &payload, packet.payload);
            try std.testing.expect(std.mem.allEqual(u8, io.buffer.data[1254..], 0));
        } else {
            try std.testing.expectError(error.Dma, tx.step(&stream, &decoder, &dispatch, &rx, 2));
            try std.testing.expectEqual(dma.State.retired, io.buffer.state);
            try std.testing.expect(stream.faulted and state.address == null);
            try std.testing.expectError(error.Retired, tx.step(&stream, &decoder, &dispatch, &rx, 3));
            try std.testing.expectEqual(@as(usize, 1), io.transfers);
        }
    }
}

test "UDP owner composes the long DMA bus adapter and retains timed-out storage" {
    for (0..3) |case| {
        const failure: Failure = switch (case) {
            0 => .none,
            1 => .timeout,
            else => .stop_timeout,
        };
        var io: Io = .{ .complete_adapter = true, .backend = .{ .failure = failure } };
        var bus: AdaptedBus = .{ .short = &io, .buffer = &io.buffer, .cache = .{ .failure = io.backend.failure } };
        var host: AdaptedHost = .{ .controller = .{ .io = &bus, .prepared = true, .selected = true, .four_bit = true, .poll_limit = 2 } };
        var guarded: guard.Guard(AdaptedHost) = .{ .host = &host, .buffer = &io.buffer };
        var stream: sender.ProfileStream(@TypeOf(guarded), 64) = .{ .host = &guarded };
        var state: split.State = .{ .generation = 7, .address = .{ .ip = 0xc0000201, .mask = 0xffffff00, .gateway = 0xc00002fe, .dns = 0xc00002fe } };
        const binding = try lease.Lease.open(&state, .{ 2, 0, 0, 0, 0, 1 }, 49152, .{ .first = 49152, .last = 61439 });
        var tx = try udp_sender.Sender.init(&state, binding);
        const destination = @import("udp_ipv4.zig").Endpoint{ .mac = .{ 2, 0, 0, 0, 0, 2 }, .ip = .{ 192, 0, 2, 2 }, .port = 443 };
        const payload: [1200]u8 = @splat(0x5a);
        try tx.enqueue(destination, &payload, 1, 1, 50);
        var decoder: hosted.Decoder = .{};
        var dispatch: Dispatch = .{};
        var rx: [512]u8 = undefined;
        if (case == 0) {
            try std.testing.expectEqual(udp_sender.Outcome.sent, try tx.step(&stream, &decoder, &dispatch, &rx, 2));
            try std.testing.expectEqual(bus_adapter.Active.none, bus.active);
            try std.testing.expectEqual(dma.State.idle, io.buffer.state);
            try std.testing.expectEqualSlices(u8, &payload, (try @import("udp_ipv4.zig").decode(io.buffer.data[12..1254])).payload);
            try std.testing.expect(std.mem.allEqual(u8, io.buffer.data[1254..], 0));
        } else {
            try std.testing.expectError(error.Timeout, tx.step(&stream, &decoder, &dispatch, &rx, 2));
            try std.testing.expectEqual(bus_adapter.Active.long, bus.active);
            try std.testing.expectEqual(dma.State.retired, io.buffer.state);
            try std.testing.expect(stream.faulted and state.address == null);
            try std.testing.expectEqual(case == 2, host.controller.cleanup_failed);
            try std.testing.expectError(error.Retired, tx.step(&stream, &decoder, &dispatch, &rx, 3));
            try std.testing.expectEqual(@as(usize, 1), io.transfers);
        }
    }
}

test "controller failures quarantine actual buffer and prevent credit consumption or replay" {
    const failures = [_]Failure{ .data_cache, .desc_cache, .timeout, .stop_timeout, .invalidate, .owned, .desc_error };
    for (failures) |failure| {
        var io: Io = .{ .backend = .{ .failure = failure } };
        var host: Host = .{ .controller = .{ .io = &io, .prepared = true, .selected = true, .four_bit = true, .poll_limit = 2 } };
        var guarded: guard.Guard(Host) = .{ .host = &host, .buffer = &io.buffer };
        var stream = sender.ProfileStream(@TypeOf(guarded), 64){ .host = &guarded };
        var tx = sender.Sender(@TypeOf(guarded), 64){ .stream = &stream };
        const packet: [1254]u8 = @splat(0x5a);
        const expected: anyerror = if (failure == .timeout or failure == .stop_timeout) error.Timeout else error.Dma;
        try std.testing.expectError(expected, tx.send(&packet));
        try std.testing.expectEqual(dma.State.retired, io.buffer.state);
        try std.testing.expect(host.controller.faulted and stream.faulted);
        try std.testing.expectEqual(failure == .stop_timeout, host.controller.cleanup_failed);
        try std.testing.expectEqual(@as(u32, 0), stream.sent_buffers);
        if (failure == .timeout or failure == .stop_timeout) try std.testing.expectEqual(@as(usize, 0), io.finishes);
        if (failure == .timeout or failure == .stop_timeout) try std.testing.expectEqual(@as(usize, 0), io.backend.invalidations);
        const transfers = io.transfers;
        try std.testing.expectError(error.Retired, tx.send(&packet));
        try std.testing.expectEqual(transfers, io.transfers);
        try std.testing.expectEqual(@as(?u32, null), io.buffer.prepare(tx.buffer[0..1536], &io.backend));
    }
}

const SharedIo = struct {
    pub const shared_host = true;
    const Lease = struct { serial: u32 = 1, generation: u32 = 1, slot: u32 = 1 };
    lease: Lease = .{},
    inner: *Io,
    releases: usize = 0,

    pub fn ownsSlot(self: *const @This(), slot: u32) bool {
        return slot == 1 and self.lease.slot == slot and self.lease.serial != 0;
    }
    pub fn read(self: *@This(), address: usize) u32 {
        return self.inner.read(address);
    }
    pub fn write(self: *@This(), address: usize, value: u32) void {
        self.inner.write(address, value);
    }
    pub fn delay(self: *@This(), us: u32) void {
        self.inner.delay(us);
    }
    pub fn fourBitPins(self: *@This()) void {
        self.inner.fourBitPins();
    }
    pub fn prepareDma(self: *@This(), writing: bool, bytes: []const u8, len: usize) ?u32 {
        return self.inner.prepareDma(writing, bytes, len);
    }
    pub fn finishDma(self: *@This(), writing: bool, out: []u8) bool {
        return self.inner.finishDma(writing, out);
    }
    pub fn releaseDma(self: *@This()) bool {
        self.releases += 1;
        return true;
    }
};

test "shared controller completes or quarantines long DMA before detach" {
    for ([_]bool{ false, true }) |timed_out| {
        var io: Io = .{ .backend = .{ .failure = if (timed_out) .timeout else .none }, .complete_adapter = true };
        var short: SharedIo = .{ .inner = &io };
        var bus: bus_adapter.Bus(*SharedIo, Backend) = .{ .short = &short, .buffer = &io.buffer, .cache = .{ .failure = if (timed_out) .timeout else .none } };
        var controller: sd.Controller(@TypeOf(&bus)) = .{ .io = &bus, .prepared = true, .selected = true, .four_bit = true, .poll_limit = 2 };
        const bytes: [1536]u8 = @splat(0x5a);
        if (timed_out) {
            try std.testing.expectError(error.Timeout, controller.writeBlocks(0x1000, &bytes));
            try std.testing.expect(controller.faulted and controller.cleanup_failed);
            try std.testing.expectEqual(bus_adapter.Active.retired, bus.active);
            try std.testing.expectEqual(dma.State.retired, io.buffer.state);
            try std.testing.expectEqual(@as(usize, 0), short.releases);
            try std.testing.expectEqual(@as(usize, 0), bus.cache.invalidations);
            try std.testing.expectError(error.Retired, controller.writeBlocks(0x1000, &bytes));
        } else {
            try controller.writeBlocks(0x1000, &bytes);
            try std.testing.expectEqual(bus_adapter.Active.none, bus.active);
            try std.testing.expectEqual(dma.State.idle, io.buffer.state);
            try std.testing.expectEqual(@as(usize, 1), short.releases);
            try std.testing.expectEqual(@as(usize, 1), bus.cache.invalidations);
        }
        try std.testing.expectEqual(@as(usize, 1), io.transfers);
    }
}
