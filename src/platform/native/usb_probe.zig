//! Opt-in boot probe: exclusive CPU0, bounded polled USB / PIN-free JPKI.
const options = @import("native_options");
const ccid = @import("ccid");
const jpki = @import("jpki");
const usb = @import("usb_host");
const descriptors = @import("usb_descriptors");
const i2c = @import("boot_i2c");
const timer_group = @import("timer_group");
extern fn nih_usb_i2c_init() callconv(.c) void;
extern fn nih_usb_pin_release(u32, bool) callconv(.c) void;
extern fn nih_usb_pin_level(u32) callconv(.c) bool;
extern fn nih_usb_phy_init() callconv(.c) void;
extern fn nih_usb_phy_stop() callconv(.c) void;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
extern fn nih_rom_cache_invalidate(u32, u32, u32) callconv(.c) i32;
var dma_data: [512]u8 align(64) = @splat(0);
var dma_qtd: [16]u32 align(512) = @splat(0);
pub var card_report = jpki.Report{};
const Session = struct {
    controller: *usb.Controller(Bus),
    input: *usb.Pipe,
    output: *usb.Pipe,
    sequence: u8 = 3,
    pub fn exchange(self: *@This(), kind: u8, payload: []const u8, expected: u8, response_buffer: []u8) !ccid.Response {
        if (!jpki.ccidAllowed(kind, payload)) return error.Denied;
        var send: [512]u8 = @splat(0);
        const sequence = self.sequence;
        self.sequence +%= 1;
        const frame = try ccid.request(&send, kind, sequence, payload);
        if (try self.controller.stage(self.output, false, false, frame) != frame.len) return error.Transfer;
        for (0..4) |_| {
            const length = try self.controller.stage(self.input, true, false, response_buffer);
            const response = try ccid.response(response_buffer[0..length], expected, sequence);
            if (response.status != 2) return response;
        }
        return error.ExtensionLimit;
    }
    pub fn apdu(self: *@This(), command: []const u8, response_buffer: []u8) ![]const u8 {
        if (!jpki.allowed(command)) {
            card_report.rejected += 1;
            return error.Denied;
        }
        const response = try self.exchange(0x6f, command, 0x80, response_buffer);
        if (response.status != 0 or response.state != 0) return error.Failed;
        return response.payload;
    }
};

pub const Report = struct {
    status: u32 = 0,
    stage: u32 = 0,
    error_code: u32 = 0,
    core_id: u32 = 0,
    port: u32 = 0,
    speed: u32 = 0,
    vid: u32 = 0,
    pid: u32 = 0,
    config_bytes: u32 = 0,
    interfaces: u32 = 0,
    ccid: u32 = 0,
    bulk_in: u32 = 0,
    bulk_out: u32 = 0,
    interrupt_in: u32 = 0,
    max_message: u32 = 0,
    transfers: u32 = 0,
    slot_queries: u32 = 0,
    card_state: u32 = 0,
    last_irq: u32 = 0,
    last_descriptor: u32 = 0,
    dma_stopped: u32 = 0,
};

const Bus = struct {
    clock: timer_group.Timer,
    pub fn read(_: Bus, offset: usize) u32 {
        return @as(*volatile u32, @ptrFromInt(usb.base + offset)).*;
    }
    pub fn write(_: Bus, offset: usize, value: u32) void {
        @as(*volatile u32, @ptrFromInt(usb.base + offset)).* = value;
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
    }
    pub fn release(_: Bus, pin: u32, high: bool) void {
        nih_usb_pin_release(pin, high);
    }
    pub fn level(_: Bus, pin: u32) bool {
        return nih_usb_pin_level(pin);
    }
    pub fn delay(self: Bus, microseconds: u32) bool {
        const started = self.clock.counter() orelse return false;
        for (0..100_000_000) |_| {
            const now = self.clock.counter() orelse return false;
            if (now - started >= microseconds) return true;
        }
        return false;
    }
    pub fn prepare(_: Bus, bytes: []u8, span: usize, input: bool, is_setup: bool) usb.Error!u32 {
        dma_data = @splat(0);
        if (!input) @memcpy(dma_data[0..bytes.len], bytes);
        dma_qtd = @splat(0);
        dma_qtd[0] = @as(u32, @intCast(span)) | (1 << 31) | (1 << 26) | (1 << 25) |
            (if (is_setup) @as(u32, 1 << 24) else 0);
        dma_qtd[1] = @intFromPtr(&dma_data);
        if (nih_rom_cache_writeback(1 << 4, @intFromPtr(&dma_data), 512) != 0 or
            nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_data), 512) != 0 or
            nih_rom_cache_writeback(1 << 4, @intFromPtr(&dma_qtd), 64) != 0) return error.Cache;
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        return @intFromPtr(&dma_qtd);
    }
    pub fn finish(_: Bus, bytes: []u8, span: usize, input: bool) usb.Error!u32 {
        asm volatile ("fence iorw, iorw" ::: .{ .memory = true });
        if (nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_qtd), 64) != 0 or
            nih_rom_cache_invalidate(1 << 4, @intFromPtr(&dma_data), 512) != 0) return error.Cache;
        const word = @as(*volatile u32, &dma_qtd[0]).*;
        const actual = try usb.descriptorStatus(word, span);
        if (actual > bytes.len) return error.Transfer;
        if (input) for (bytes[0..actual], 0..) |*byte, index| {
            byte.* = @as(*volatile u8, &dma_data[index]).*;
        };
        return word;
    }
};

fn enumerate(controller: *usb.Controller(Bus), report: *Report) !void {
    report.stage = 2;
    try controller.initialize();
    report.speed = controller.speed;
    var control = usb.Pipe{ .address = 0 };
    if (controller.speed == 0) control.packet = 64;
    var header: [8]u8 = @splat(0);
    report.stage = 3;
    if (try controller.control(&control, usb.setup(0x80, 6, 0x0100, 0, 8), &header) != 8 or
        header[0] != 18 or header[1] != 1) return error.Malformed;
    if (header[7] != 8 and header[7] != 16 and header[7] != 32 and header[7] != 64) return error.Unsupported;
    control.packet = header[7];
    _ = try controller.control(&control, usb.setup(0, 5, 1, 0, 0), &.{});
    if (!controller.io.delay(10_000)) return error.Timeout;
    control.address = 1;
    var device: [18]u8 = @splat(0);
    report.stage = 4;
    if (try controller.control(&control, usb.setup(0x80, 6, 0x0100, 0, 18), &device) != 18) return error.Malformed;
    const identity = try descriptors.device(&device);
    if (identity.packet != control.packet) return error.Malformed;
    report.vid = identity.vid;
    report.pid = identity.pid;
    var config: [512]u8 = @splat(0);
    report.stage = 5;
    if (try controller.control(&control, usb.setup(0x80, 6, 0x0200, 0, 9), config[0..9]) != 9 or
        config[0] != 9 or config[1] != 2) return error.Malformed;
    const length = descriptors.le16(config[2..4]);
    if (length < 9 or length > config.len) return error.Unsupported;
    if (try controller.control(&control, usb.setup(0x80, 6, 0x0200, 0, length), config[0..length]) != length) return error.Malformed;
    const selected = try descriptors.configuration(config[0..length]);
    report.config_bytes = length;
    report.interfaces = selected.interfaces;
    report.ccid = @intFromBool(selected.ccid);
    report.bulk_in = selected.bulk_in;
    report.bulk_out = selected.bulk_out;
    report.interrupt_in = selected.interrupt_in;
    report.max_message = selected.max_message;
    report.stage = 6;
    _ = try controller.control(&control, usb.setup(0, 9, selected.value, 0, 0), &.{});
    if (!selected.ccid) return;
    if (!controller.io.delay(if (options.jpki) 2_000_000 else 20_000)) return error.Timeout;
    var input = usb.Pipe{ .address = 1, .endpoint = @truncate(selected.bulk_in), .packet = selected.in_packet, .kind = 2 };
    var output = usb.Pipe{ .address = 1, .endpoint = @truncate(selected.bulk_out), .packet = selected.out_packet, .kind = 2 };
    report.stage = 7;
    for (0..3) |sequence| {
        var request = descriptors.slotRequest(@intCast(sequence));
        if (try controller.stage(&output, false, false, &request) != request.len) return error.Transfer;
        var response: [64]u8 = @splat(0);
        const actual = try controller.stage(&input, true, false, &response);
        report.card_state = try descriptors.slotStatus(response[0..actual], @intCast(sequence));
        report.slot_queries += 1;
    }
    report.stage = 8;
    if (options.jpki) {
        // Keep the baseline USB receipt independent from the card diagnostic.
        report.transfers = controller.transfers;
        report.last_irq = controller.last_irq;
        report.last_descriptor = controller.last_descriptor;
        card_report.status = 2;
        var session = Session{ .controller = controller, .input = &input, .output = &output };
        jpki.probe(&session, &card_report) catch |err| {
            card_report.error_code = switch (err) {
                error.Timeout => 1,
                error.Status => 2,
                error.Failed => 3,
                error.Malformed => 4,
                error.CounterChanged => 5,
                error.Blocked => 6,
                error.Denied => 7,
                else => 8,
            };
        };
    }
}

pub noinline fn run(clock: timer_group.Timer) Report {
    var report = Report{ .status = 2, .stage = 1 };
    clock.start();
    clock.disarm();
    defer clock.stop();
    const io = Bus{ .clock = clock };
    nih_usb_i2c_init();
    var bus = i2c.Master(Bus){ .pins = io };
    i2c.usbPowerCycle(&bus) catch {
        report.error_code = 1;
        return report;
    };
    nih_usb_phy_init();
    report.core_id = io.read(usb.regs.identity);
    var controller = usb.Controller(Bus){ .io = io };
    enumerate(&controller, &report) catch |err| {
        report.error_code = switch (err) {
            error.Timeout => 2,
            error.Disconnected => 3,
            error.Overcurrent => 4,
            error.Unsupported => 5,
            error.Stall => 6,
            error.Cache => 7,
            error.Malformed => 8,
            else => 9,
        };
    };
    if (!options.jpki or report.transfers == 0) {
        report.transfers = controller.transfers;
        report.last_irq = controller.last_irq;
        report.last_descriptor = controller.last_descriptor;
    }
    report.port = io.read(usb.regs.port);
    // Always stop/reset DMA, including timeout or a poisoned channel.
    nih_usb_phy_stop();
    report.dma_stopped = 1;
    if (report.error_code == 0) report.status = 1;
    return report;
}
