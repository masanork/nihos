//! OS-owned, synchronous sample session. One serialized foreground caller;
//! callbacks may not retain a frame or asynchronously reenter this object.
const builtin = @import("builtin");
pub const text_section = if (builtin.cpu.arch == .riscv32 and builtin.os.tag == .freestanding)
    ".flash.text.rust_app"
else if (builtin.os.tag == .macos)
    "__TEXT,__text"
else
    ".text";
const std = @import("std");
pub const width = 160;
pub const height = 80;
pub const stride = width * 2;
pub const frame_bytes = stride * height;
pub const lease_bytes = 32 * 1024;
const guard = 16;
pub const State = enum(u32) { idle, running, stopped, failed };
pub const Hooks = extern struct {
    context: ?*anyopaque,
    acquire: *const fn (?*anyopaque, *?[*]u8, *u32) callconv(.c) i32,
    open: *const fn (?*anyopaque) callconv(.c) i32,
    render: *const fn (?*anyopaque, u32, [*]u8, u32) callconv(.c) i32,
    present: *const fn (?*anyopaque, [*]const u8, u32) callconv(.c) i32,
    close: *const fn (?*anyopaque) callconv(.c) i32,
    release: *const fn (?*anyopaque, [*]u8, u32) callconv(.c) i32,
};
pub const Session = extern struct {
    hooks: Hooks,
    storage: ?[*]u8 = null,
    capacity: u32 = 0,
    state: State = .idle,
    selected: u32 = 0,
    frames: u32 = 0,
    last_error: i32 = 0,
    busy: u32 = 0,
    opened: u32 = 0,

    fn guardsIntact(self: *const Session) bool {
        const p = self.storage orelse return false;
        return std.mem.allEqual(u8, p[0..guard], 0xa5) and
            std.mem.allEqual(u8, p[guard + frame_bytes .. guard + frame_bytes + guard], 0xa5);
    }
    noinline fn finish(self: *Session, reason: i32) linksection(text_section) i32 {
        // Revoke first. No callback may draw through this session from here.
        self.state = if (reason == 0) .stopped else .failed;
        var result = reason;
        if (self.opened != 0) {
            self.opened = 0;
            const status = self.hooks.close(self.hooks.context);
            if (result == 0) result = status;
        }
        if (self.storage) |bytes| {
            if (self.capacity == lease_bytes and !self.guardsIntact() and result == 0) result = -7;
            @memset(bytes[0..self.capacity], 0);
            self.storage = null;
            const capacity = self.capacity;
            self.capacity = 0;
            const status = self.hooks.release(self.hooks.context, bytes, capacity);
            if (result == 0) result = status;
        }
        self.last_error = result;
        if (result != 0) self.state = .failed;
        return result;
    }
    noinline fn draw(self: *Session, selected: u32) linksection(text_section) i32 {
        const bytes = self.storage orelse return self.finish(-5);
        const rendered = self.hooks.render(self.hooks.context, selected, bytes + guard, frame_bytes);
        if (rendered != 0) return self.finish(rendered);
        if (!self.guardsIntact()) return self.finish(-7);
        const presented = self.hooks.present(self.hooks.context, bytes + guard, frame_bytes);
        if (presented != 0) return self.finish(presented);
        self.selected = selected;
        self.frames += 1;
        return 0;
    }
};

export fn nih_app_session_start(self: *Session) linksection(text_section) callconv(.c) i32 {
    if (self.busy != 0 or self.state == .running) return -3;
    self.busy = 1;
    defer self.busy = 0;
    self.selected = 0;
    self.frames = 0;
    self.last_error = 0;
    const acquired = self.hooks.acquire(self.hooks.context, &self.storage, &self.capacity);
    if (acquired != 0) return self.finish(acquired);
    if (self.storage == null or self.capacity != lease_bytes) return self.finish(-1);
    @memset(self.storage.?[0..self.capacity], 0xa5);
    self.opened = 1; // close also owns partial-open cleanup.
    const opened = self.hooks.open(self.hooks.context);
    if (opened != 0) return self.finish(opened);
    self.state = .running;
    return self.draw(0);
}
export fn nih_app_session_input(self: *Session, byte: u32) linksection(text_section) callconv(.c) i32 {
    if (self.busy != 0) return -3;
    if (self.state != .running) return -5;
    if (byte != '0' and byte != '1' and byte != 'q') return -1;
    self.busy = 1;
    defer self.busy = 0;
    if (byte == 'q') return self.finish(0);
    if (self.frames == std.math.maxInt(u32)) return self.finish(-1);
    return self.draw(byte - '0');
}
export fn nih_app_session_cancel(self: *Session) linksection(text_section) callconv(.c) i32 {
    if (self.busy != 0) return -3;
    self.busy = 1;
    defer self.busy = 0;
    if (self.state != .running) return self.last_error;
    return self.finish(0);
}

pub const start = nih_app_session_start;
pub const input = nih_app_session_input;
pub const cancel = nih_app_session_cancel;
