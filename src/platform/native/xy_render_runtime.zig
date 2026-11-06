//! CPU0-only foreground render owner. One retained PSRAM lease and guarded stack.
const std = @import("std");
const console = @import("text_console");
const tasks = @import("native_tasks");
const options = @import("native_options");
const experimental_tcp = @hasDecl(options, "experimental_tcp") and options.experimental_tcp;
const memory = tasks.memory;
const protocol = console.xy_render_protocol;
pub const section = console.scratch.scheme.code_section;
const stack_bytes = memory.stacks.foreground_bytes;
const frame_bytes = 1280 * 720 * 2;
var lease: ?memory.reusable.Allocation = null;
var workspace_bytes: usize = 0;
pub var frames: u32 = 0;
pub var stack_used: u32 = 0;
pub var failed: u32 = 0;
pub var published_bytes: u32 = 0;
pub var backing_payload: u32 = 0;
pub var backing_reserved: u32 = 0;
extern fn nih_xy_render_learning(bytes: [*]u8) callconv(.c) *console.scratch.LearningSession;
extern fn nih_native_task_failed() callconv(.c) noreturn;
extern fn nih_xy_render_bytes() callconv(.c) usize;
extern fn nih_xy_render_init([*]u8, usize) callconv(.c) bool;
extern fn nih_xy_render_call(*const protocol.Request, usize, u32) callconv(.c) bool;
extern fn nih_xy_render_terminal_call(*const protocol.Request, *const protocol.TerminalView, usize, u32) callconv(.c) bool;
const label_0 linksection(console.scratch.scheme.data_section) = ": ".*;
const label_1 linksection(console.scratch.scheme.data_section) = "Scheme error: ".*;
const label_2 linksection(console.scratch.scheme.data_section) = "Scheme: ".*;
const label_3 linksection(console.scratch.scheme.data_section) = "xy / *help*".*;
const label_4 linksection(console.scratch.scheme.data_section) = "xy / *scratch* [RAM]".*;
const label_5 linksection(console.scratch.scheme.data_section) = "xy / system [read-only]".*;
const label_6 linksection(console.scratch.scheme.data_section) = "SSH / ".*;
pub noinline fn draw(model: *console.scratch.Model, frame: []u8) linksection(section) bool {
    if (frame.len != frame_bytes) return false;
    if (lease == null) {
        workspace_bytes = std.mem.alignForward(usize, nih_xy_render_bytes(), 64);
        if (workspace_bytes > 2 * 1024 * 1024) return false;
        const before = memory.reusable.localUsage() orelse return false;
        const allocation = memory.allocExternal(workspace_bytes + stack_bytes + frame_bytes, 64) catch return false;
        const after = memory.reusable.localUsage() orelse return false;
        backing_payload = @intCast(allocation.bytes.len);
        backing_reserved = before.free - after.free;
        if (!nih_xy_render_init(allocation.bytes.ptr, workspace_bytes)) {
            memory.freeExternal(allocation) catch return false;
            return false;
        }
        lease = allocation;
        @memset(allocation.bytes[workspace_bytes..][0..stack_bytes], 0xa5);
    }
    const bytes = lease.?.bytes;
    model.learning = nih_xy_render_learning(bytes.ptr);
    const stack = bytes[workspace_bytes..][0..stack_bytes];
    const completed = bytes[workspace_bytes + stack_bytes ..][0..frame_bytes];
    var status: [384]u8 = @splat(0);
    var length: usize = 0;
    const terminal_mode = experimental_tcp and model.terminal != null;
    const prefix = if (terminal_mode) &label_6 else if (model.mode == .system) &label_5 else if (model.mode == .help) &label_3 else if (model.mode == .command) &label_0 else if (model.status == .scheme_error) &label_1 else if (model.status == .scheme_result) &label_2 else &label_4;
    @memcpy(status[0..prefix.len], prefix);
    length = prefix.len;
    const reply = if (terminal_mode) model.statusText() else if (model.mode == .system) "" else if (model.mode == .command) model.command[0..model.command_length] else if (model.status == .scheme_error or model.status == .scheme_result) model.reply[0..model.reply_length] else model.statusText();
    @memcpy(status[length..][0..reply.len], reply);
    length += reply.len;
    // Display the uncommitted SKK reading or selected candidate in the
    // status line until the document renderer supports inline preedit.
    if (!terminal_mode and model.mode == .edit and model.doc.preedit.len != 0) {
        const preedit = model.doc.preedit.slice();
        length = @min(preedit.len, status.len);
        @memcpy(status[0..length], preedit[0..length]);
    }
    var text: []const u8 = if (model.mode == .help) &console.scratch.help_text else if (model.mode == .system) model.snapshot.slice() else model.doc.slice();
    if (model.mode == .system) {
        var row: usize = 0;
        var offset: usize = 0;
        while (offset < text.len and row < model.snapshot.top_row) : (offset += 1) if (text[offset] == '\n') {
            row += 1;
        };
        text = text[offset..];
    }
    const annotated = model.mode != .help and model.mode != .system;
    var request = protocol.Request{ .learning = model.learning, .navigation = if (model.nav.screen != .document) &model.nav else null, .workspace = bytes.ptr, .frame = completed.ptr, .frame_length = completed.len, .config = &model.vm.view, .text = text.ptr, .text_length = text.len, .cursor = if (model.mode == .help or model.mode == .system) 0 else model.doc.cursor, .status = &status, .status_length = length, .show_cursor = if (model.mode == .edit or model.mode == .command) 1 else 0, .reserved_bottom_px = if (model.softKeyboardVisible()) @intCast(console.scratch.soft_keyboard.geometry(model.touchOrientation()).keyboardHeight()) else 0, .portrait = @intFromBool(model.portrait_touch), .keyboard = if (!model.softKeyboardVisible()) 0 else if (model.soft_keyboard_state.symbols) (if (model.soft_keyboard_state.shift) 4 else 3) else if (model.soft_keyboard_state.shift) 2 else 1, .ruby_text = &model.doc.ruby_arena, .ruby_text_length = if (annotated) model.doc.ruby_bytes_used else 0, .ruby_spans = &model.doc.ruby_spans, .ruby_count = if (annotated) model.doc.ruby_count else 0 };
    // The snapshot only borrows public text and a secret length, never seed bytes.
    // SAFETY: the producer remains stable for this foreground draw.
    var private_view: protocol.PrivateInputView = undefined;
    if (experimental_tcp and model.private_input != null) {
        if (!model.privateInputSnapshot(&private_view)) return false;
        request.private_input = &private_view;
    }
    // SAFETY: a successful snapshot initializes this descriptor, and the
    // CPU0-owned producer keeps its cells stable until the draw returns.
    var terminal_view: protocol.TerminalView = undefined;
    const terminal_active = if (terminal_mode) blk: {
        if (!model.terminalSnapshot(&terminal_view)) return false;
        break :blk true;
    } else false;
    const previous = asm volatile ("csrrci %[v], mstatus, 8"
        : [v] "=r" (-> u32),
        :
        : .{ .memory = true });
    if (!memory.stacks.beginForeground(stack)) {
        if (previous & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
        return false;
    }
    const original = tasks.beginForegroundStack(@intCast(@intFromPtr(stack.ptr) + 256), @intCast(@intFromPtr(stack.ptr) + stack.len)) orelse {
        memory.stacks.endForeground();
        if (previous & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
        return false;
    };
    const ok = if (terminal_active)
        nih_xy_render_terminal_call(&request, &terminal_view, @intFromPtr(stack.ptr) + stack.len, previous & 8)
    else
        nih_xy_render_call(&request, @intFromPtr(stack.ptr) + stack.len, previous & 8);
    // The bridge returned on the boot SP with MIE clear. Restore the scheduler
    // image before another timer can capture that original stack.
    if (!tasks.endForegroundStack(original)) nih_native_task_failed();
    memory.stacks.endForeground();
    if (previous & 8 != 0) asm volatile ("csrsi mstatus, 8" ::: .{ .memory = true });
    var first: usize = 0;
    while (first < stack.len and stack[first] == 0xa5) : (first += 1) {}
    stack_used = @max(stack_used, @as(u32, @intCast(stack.len - first)));
    if (!ok or first < 256 or !memory.stacks.bootGuardsIntact(0)) {
        failed +%= 1;
        return false;
    }
    const publication = console.xy_presentation.publish(completed, frame) catch return false;
    published_bytes = @intCast(publication.bytes);
    frames +%= 1;
    return true;
}
