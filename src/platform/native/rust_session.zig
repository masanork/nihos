//! One foreground Rust sample session, using a private OS-owned PSRAM lease.
pub const text_section = ".flash.text.rust_app";
const app = @import("app_session");
const memory = @import("native_tasks").memory;
extern fn nih_rust_app_frame(u32) callconv(.c) i32;
extern fn nih_app_probe_attach([*]u8, u32, u32, u32, u32) callconv(.c) i32;
extern fn nih_app_probe_detach() callconv(.c) void;
var allocation: ?memory.reusable.Allocation = null;
var presenter: ?*const fn ([*]const u8, u32) callconv(.c) i32 = null;
var owner: app.Session = .{ .hooks = .{
    .context = null,
    .acquire = acquire,
    .open = open,
    .render = render,
    .present = present,
    .close = close,
    .release = release,
} };
fn acquire(_: ?*anyopaque, bytes: *?[*]u8, len: *u32) linksection(text_section) callconv(.c) i32 {
    if (allocation != null) return -3;
    const lease = memory.allocExternal(app.lease_bytes, 64) catch return -4;
    allocation = lease;
    bytes.* = lease.bytes.ptr;
    len.* = @intCast(lease.bytes.len);
    return 0;
}
fn open(_: ?*anyopaque) linksection(text_section) callconv(.c) i32 {
    return 0;
}
fn render(_: ?*anyopaque, selected: u32, bytes: [*]u8, len: u32) linksection(text_section) callconv(.c) i32 {
    const attached = nih_app_probe_attach(bytes, len, app.width, app.height, app.stride);
    if (attached != 0) return attached;
    defer nih_app_probe_detach();
    return nih_rust_app_frame(selected);
}
fn present(_: ?*anyopaque, bytes: [*]const u8, len: u32) linksection(text_section) callconv(.c) i32 {
    return (presenter orelse return -5)(bytes, len);
}
fn close(_: ?*anyopaque) linksection(text_section) callconv(.c) i32 {
    return 0; // render always detaches, including an application error.
}
fn release(_: ?*anyopaque, bytes: [*]u8, len: u32) linksection(text_section) callconv(.c) i32 {
    const lease = allocation orelse return -5;
    if (lease.bytes.ptr != bytes or lease.bytes.len != len) return -1;
    memory.freeExternal(lease) catch return -4;
    allocation = null;
    return 0;
}
pub fn start(callback: *const fn ([*]const u8, u32) callconv(.c) i32) linksection(text_section) i32 {
    if (owner.state == .running or owner.busy != 0) return -3;
    presenter = callback;
    const status = app.start(&owner);
    if (status != 0) presenter = null;
    return status;
}
pub fn input(byte: u32) linksection(text_section) i32 {
    const status = app.input(&owner, byte);
    if (owner.state != .running) presenter = null;
    return status;
}
pub fn cancel() linksection(text_section) i32 {
    const status = app.cancel(&owner);
    if (owner.state != .running) presenter = null;
    return status;
}
pub fn active() bool {
    return owner.state == .running;
}
pub fn frames() u32 {
    return owner.frames;
}
