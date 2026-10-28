//! CPU0-owned opt-in UART1 fixture. Internal loopback is not wire evidence.
const options = @import("native_options");
const transport = @import("half_duplex");
extern fn nih_rs485_open(u32) callconv(.c) bool;
extern fn nih_rs485_direction(bool) callconv(.c) bool;
extern fn nih_rs485_errors() callconv(.c) u32;
extern fn nih_rs485_writable() callconv(.c) bool;
extern fn nih_rs485_readable() callconv(.c) bool;
extern fn nih_rs485_tx_idle() callconv(.c) bool;
extern fn nih_rs485_write(u8) callconv(.c) bool;
extern fn nih_rs485_read() callconv(.c) u32;
extern fn nih_rs485_close() callconv(.c) bool;
extern fn nih_rs485_dir_low() callconv(.c) bool;
extern fn nih_rs485_closed() callconv(.c) bool;
const Hardware = struct {
    pub fn open(_: *@This()) !void {
        if (!nih_rs485_open(options.rs485_mode)) return error.Hardware;
    }
    pub fn direction(_: *@This(), tx: bool) !void {
        if (!nih_rs485_direction(tx)) return error.Hardware;
    }
    pub fn errors(_: *@This()) u32 {
        return nih_rs485_errors();
    }
    pub fn writable(_: *@This()) bool {
        return nih_rs485_writable();
    }
    pub fn readable(_: *@This()) bool {
        return nih_rs485_readable();
    }
    pub fn txIdle(_: *@This()) bool {
        return nih_rs485_tx_idle();
    }
    pub fn write(_: *@This(), byte: u8) !void {
        if (!nih_rs485_write(byte)) return error.Hardware;
    }
    pub fn read(_: *@This()) !u8 {
        const byte = nih_rs485_read();
        if (byte > 255) return error.Hardware;
        return @intCast(byte);
    }
    pub fn close(_: *@This()) !void {
        if (!nih_rs485_close()) return error.Hardware;
    }
    pub fn directionLow(_: *@This()) bool {
        return nih_rs485_dir_low();
    }
    pub fn closed(_: *@This()) bool {
        return nih_rs485_closed();
    }
};
var exchange = transport.Exchange(Hardware){ .hardware = .{} };
pub fn request() bool {
    const data = transport.frame(false);
    const reply = transport.frame(options.rs485_mode == 2);
    exchange.request(&data, &reply) catch return false;
    return true;
}
pub fn poll(clock: anytype) void {
    exchange.poll(clock);
}
pub fn snapshot() transport.Report {
    return exchange.report;
}

pub const Diagnostic = extern struct { stage: u32, a: u32, b: u32, c: u32 };
extern fn nih_rs485_diagnostic(*Diagnostic) callconv(.c) void;
pub fn diagnostic() Diagnostic {
    // SAFETY: the C ABI fills all four diagnostic words before this value is read.
    var value: Diagnostic = undefined;
    nih_rs485_diagnostic(&value);
    return value;
}
