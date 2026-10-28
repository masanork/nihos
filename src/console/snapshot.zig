//! Build a read-only boot snapshot. Input transport and glyph files are separate.
const stages = @import("../diagnostics/boot_state.zig");
pub const header_rows = 7;
pub noinline fn fill(grid: anytype, model: *const stages.Model, spans: [2][]const u8, dropped: u64) void {
    if (@TypeOf(grid.*).height <= header_rows) @compileError("snapshot needs header and body rows");
    @memset(&grid.cells, ' ');
    grid.x = 0;
    grid.y = 0;
    grid.wrap_pending = false;
    _ = grid.setScrollTop(header_rows);
    for (0..header_rows) |_| grid.write("\n");
    for (spans) |part| grid.write(part);
    refreshHeader(grid, model, dropped);
}
pub noinline fn refreshHeader(grid: anytype, model: *const stages.Model, dropped: u64) void {
    const x = grid.x;
    const y = grid.y;
    const wrap = grid.wrap_pending;
    defer {
        grid.x = x;
        grid.y = y;
        grid.wrap_pending = wrap;
    }
    // Scroll only affects the body; restore the fixed header afterwards.
    @memset(grid.cells[0 .. @TypeOf(grid.*).width * header_rows], ' ');
    grid.x = 0;
    grid.y = 0;
    grid.wrap_pending = false;
    grid.write("nihos / boot diagnostic snapshot");
    if (model.failure_latched) grid.write(" [FAILED]");
    grid.write("\nlast: ");
    grid.write(if (model.last_complete) |stage| @tagName(stage) else "none");
    grid.write("   active: ");
    grid.write(if (model.active) |stage| @tagName(stage) else "none");
    grid.write("   input: ");
    grid.write(if (!model.input_available) "not initialized" else switch (model.input_sources) {
        1 => "serial",
        2 => "keyboard",
        3 => "keyboard+serial",
        17 => "serial+touch",
        19 => "keyboard+serial+touch",
        else => "available",
    });
    if (model.atSafeCheckpoint()) grid.write(" [PAUSED]");
    grid.write("\n");
    status(grid, model, .crt);
    grid.write("   ");
    status(grid, model, .memory);
    grid.write("   ");
    status(grid, model, .cores);
    grid.write("\n");
    status(grid, model, .storage);
    grid.write("   ");
    status(grid, model, .console);
    grid.write("\n");
    status(grid, model, .display_prepare);
    grid.write("   ");
    status(grid, model, .display_scanout);
    grid.write("\n");
    if (model.input_available) grid.write("Esc logs | Ctrl-L splash | Ctrl-B pause | Ctrl-R resume\n");
    grid.write(if (dropped == 0) "\n" else "[older log bytes discarded]\n");
}
fn status(grid: anytype, model: *const stages.Model, stage: stages.Stage) void {
    grid.write(@tagName(stage));
    grid.write(": ");
    grid.write(@tagName(model.outcomes[@backingInt(stage)]));
}

test "fixed stage header and last log survive scrolling independently" {
    const std = @import("std");
    const Grid = @import("ascii.zig").Grid;
    var grid = Grid(78, 16){};
    var model = stages.Model{};
    try std.testing.expect(model.begin(.memory));
    try std.testing.expect(model.complete(.memory));
    try std.testing.expect(model.begin(.cores));
    model.fail(9);
    var log: [462]u8 = undefined;
    for (0..50) |index| @memcpy(log[index * 9 ..][0..9], "old line\n");
    @memcpy(log[450..], "UNIQUE TAIL\n");
    fill(&grid, &model, .{ &log, "" }, 17);
    try std.testing.expect(std.mem.indexOf(u8, &grid.cells, "[FAILED]") != null);
    try std.testing.expect(std.mem.indexOf(u8, &grid.cells, "last: memory   active: cores") != null);
    try std.testing.expect(std.mem.indexOf(u8, &grid.cells, "cores: failed") != null);
    try std.testing.expect(std.mem.indexOf(u8, &grid.cells, "UNIQUE TAIL") != null);
    try std.testing.expect(std.mem.indexOf(u8, &grid.cells, "input: not initialized") != null);
}

test "refreshing boot state preserves the append cursor and visible log history" {
    const std = @import("std");
    var grid = @import("ascii.zig").Grid(78, 16){};
    var model = stages.Model{};
    fill(&grid, &model, .{ "retained line\npartial", "" }, 0);
    const old = grid;
    try std.testing.expect(model.begin(.cores));
    refreshHeader(&grid, &model, 7);
    try std.testing.expectEqualSlices(u8, old.cells[header_rows * 78 ..], grid.cells[header_rows * 78 ..]);
    try std.testing.expectEqual(old.x, grid.x);
    try std.testing.expectEqual(old.y, grid.y);
    grid.write(" tail\n");
    try std.testing.expect(std.mem.indexOf(u8, &grid.cells, "partial tail") != null);
}
