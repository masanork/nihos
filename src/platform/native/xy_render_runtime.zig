//! CPU0-only foreground render owner. One retained PSRAM lease and guarded stack.
const std = @import("std");
const console = @import("text_console");
const memory = @import("native_tasks").memory;
const protocol = console.xy_render_protocol;
pub const section = console.scratch.scheme.code_section;
const stack_bytes = 128 * 1024;
var lease: ?memory.reusable.Allocation = null;
var workspace_bytes: usize = 0;
pub var frames: u32 = 0;
pub var stack_used: u32 = 0;
pub var failed: u32 = 0;
extern fn nih_xy_render_bytes() callconv(.c) usize;
extern fn nih_xy_render_init([*]u8, usize) callconv(.c) bool;
extern fn nih_xy_render_call(*const protocol.Request, usize) callconv(.c) bool;
const label_0 linksection(console.scratch.scheme.data_section) = ": ".*;
const label_1 linksection(console.scratch.scheme.data_section) = "Scheme error: ".*;
const label_2 linksection(console.scratch.scheme.data_section) = "Scheme: ".*;
const label_3 linksection(console.scratch.scheme.data_section) = "xy / *help*".*;
const label_4 linksection(console.scratch.scheme.data_section) = "xy / *scratch* [RAM]".*;
const label_5 linksection(console.scratch.scheme.data_section) = "xy / system [read-only]".*;
pub noinline fn draw(model: *console.scratch.Model, frame: []u8) linksection(section) bool {
    if (lease == null) {
        workspace_bytes = std.mem.alignForward(usize, nih_xy_render_bytes(), 64);
        if (workspace_bytes > 2 * 1024 * 1024) return false;
        const allocation = memory.allocExternal(workspace_bytes + stack_bytes, 64) catch return false;
        if (!nih_xy_render_init(allocation.bytes.ptr, workspace_bytes)) {
            memory.freeExternal(allocation) catch return false;
            return false;
        }
        lease = allocation;
        @memset(allocation.bytes[workspace_bytes..][0..stack_bytes], 0xa5);
    }
    const bytes = lease.?.bytes;
    const stack = bytes[workspace_bytes..][0..stack_bytes];
    var status: [384]u8 = @splat(0);
    var length: usize = 0;
    const prefix = if (model.mode == .system) &label_5 else if (model.mode == .help) &label_3 else if (model.mode == .command) &label_0 else if (model.status == .scheme_error) &label_1 else if (model.status == .scheme_result) &label_2 else &label_4;
    @memcpy(status[0..prefix.len], prefix);
    length = prefix.len;
    const reply = if (model.mode == .system) "" else if (model.mode == .command) model.command[0..model.command_length] else if (model.status == .scheme_error or model.status == .scheme_result) model.reply[0..model.reply_length] else model.statusText();
    @memcpy(status[length..][0..reply.len], reply);
    length += reply.len;
    var text: []const u8 = if (model.mode == .help) &console.scratch.help_text else if (model.mode == .system) model.snapshot.slice() else model.doc.slice();
    if (model.mode == .system) {
        var row: usize = 0;
        var offset: usize = 0;
        while (offset < text.len and row < model.snapshot.top_row) : (offset += 1) if (text[offset] == '\n') {
            row += 1;
        };
        text = text[offset..];
    }
    const request = protocol.Request{ .workspace = bytes.ptr, .frame = frame.ptr, .frame_length = frame.len, .config = &model.vm.view, .text = text.ptr, .text_length = text.len, .cursor = if (model.mode == .help or model.mode == .system) 0 else model.doc.cursor, .status = &status, .status_length = length, .show_cursor = if (model.mode == .edit or model.mode == .command) 1 else 0 };
    if (!memory.stacks.beginForeground(stack)) return false;
    defer memory.stacks.endForeground();
    const ok = nih_xy_render_call(&request, @intFromPtr(stack.ptr) + stack.len);
    var first: usize = 0;
    while (first < stack.len and stack[first] == 0xa5) : (first += 1) {}
    stack_used = @max(stack_used, @as(u32, @intCast(stack.len - first)));
    if (!ok or first < 256 or !memory.stacks.bootGuardsIntact(0)) {
        failed +%= 1;
        return false;
    }
    frames +%= 1;
    return true;
}
