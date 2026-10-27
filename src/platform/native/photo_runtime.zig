//! Private CPU0 external-memory lease and isolated decode stack, one card job.
const std = @import("std");
const card = @import("card");
const memory = @import("native_tasks").memory;
const heap = memory.reusable;
const bytes = 4 * 1024 * 1024 - 128;
var lease: ?heap.Allocation = null;
pub const Report = struct { selftest: u32 = 0, decoded: u32 = 0, error_code: u32 = 0, stack_used: u32 = 0, arena_bytes: u32 = 0, surface_sw: u32 = 0, surface_counter: u32 = 255, erased: u32 = 0, crypto_selftest: u32 = 0, crypto_stack: u32 = 0 };
pub var report = Report{};
extern fn nih_photo_call([*]const u8, usize, [*]u8, usize, [*]u8, usize) callconv(.c) c_int;
extern fn nih_card_crypto_call(?*const card.LicenseCrypto.Request, usize) callconv(.c) c_int;
extern fn nih_rom_cache_writeback(u32, u32, u32) callconv(.c) i32;
pub fn raw() []u8 {
    return lease.?.bytes[0..card.Surface.capacity];
}
pub fn pixels() []u8 {
    return lease.?.bytes[32768..][0..card.ResultScreen.portrait_bytes];
}
fn scratch() []u8 {
    return lease.?.bytes[57344..];
}
fn stack() []u8 {
    return @as([*]u8, @ptrFromInt(0x4ff68000))[0..12288];
}
pub noinline fn cryptoExecute(request: ?*const card.LicenseCrypto.Request) linksection(".flash.photo") !bool {
    if (lease == null) return error.CryptoNotReady;
    const private_stack = lease.?.bytes[bytes - 65536 ..];
    @memset(private_stack, 0xa5);
    const status = nih_card_crypto_call(request, @intFromPtr(private_stack.ptr) + private_stack.len);
    var first: usize = 128;
    while (first < private_stack.len and private_stack[first] == 0xa5) : (first += 1) {}
    report.crypto_stack = @max(report.crypto_stack, @as(u32, @intCast(private_stack.len - first)));
    var intact = true;
    for (private_stack[0..128]) |byte| if (byte != 0xa5) {
        intact = false;
    };
    std.crypto.secureZero(u8, private_stack);
    if (!intact) return error.CryptoStack;
    if (request == null and status == 0) report.crypto_selftest = 1;
    return status == 0;
}
noinline fn execute(encoded: []const u8) linksection(".flash.photo") bool {
    @memset(stack(), 0xa5);
    const work = scratch();
    const status = nih_photo_call(encoded.ptr, encoded.len, pixels().ptr, pixels().len, work.ptr, work.len);
    var first: usize = 64;
    while (first < stack().len and stack()[first] == 0xa5) : (first += 1) {}
    report.stack_used = @max(report.stack_used, @as(u32, @intCast(stack().len - first)));
    var intact = true;
    for (stack()[0..64]) |byte| if (byte != 0xa5) {
        intact = false;
    };
    std.crypto.secureZero(u8, stack());
    std.crypto.secureZero(u8, work);
    report.error_code = @intCast(status);
    return status == 0 and intact;
}
pub noinline fn prepare() linksection(".flash.text.card") !void {
    if (lease != null) return error.PhotoBusy;
    report = .{};
    // CPU0 is still the live bootstrap task after scheduler qualification.
    // Register the lease with that existing owner; never forge a generation
    // or close its task ledger while the foreground is running.
    errdefer {
        if (!close()) report.error_code = 10;
    }
    lease = try memory.allocExternal(bytes, 64);
    report.arena_bytes = @intCast(lease.?.bytes.len);
    if (!execute(&card.PhotoFixture.encoded)) return error.PhotoSelfTest;
    var hash: u32 = 2166136261;
    for (pixels()) |byte| hash = (hash ^ byte) *% 16777619;
    if (hash != card.PhotoFixture.expected) return error.PhotoReference;
    report.selftest = 1;
    std.crypto.secureZero(u8, raw());
}
pub noinline fn decode(encoded: []const u8) linksection(".flash.text.card") ?[]const u8 {
    if (lease == null or report.selftest != 1 or !execute(encoded)) return null;
    report.decoded = 1;
    return pixels();
}
pub noinline fn close() linksection(".flash.text.card") bool {
    var clean = true;
    if (lease) |allocation| {
        std.crypto.secureZero(u8, allocation.bytes);
        if (nih_rom_cache_writeback((1 << 4) | (1 << 5), @intFromPtr(allocation.bytes.ptr), @intCast(allocation.bytes.len)) != 0) {
            report.erased = 0;
            return false;
        }
        memory.freeExternal(allocation) catch {
            clean = false;
        };
        lease = null;
    }
    report.erased = @intFromBool(clean);
    return clean;
}
