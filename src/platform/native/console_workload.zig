//! Emulator-only offscreen console exercise; no display or input emulation.
const console = @import("text_console");
const L = console.raster.Layout(.basic_light);
const Text = console.Grid(L.columns, L.rows);
const Renderer = console.raster.Renderer(null, .basic_light);

pub const Scratch = struct { text: Text = .{}, renderer: Renderer = .{} };

pub fn paint(frame: []u8, scratch: *Scratch) bool {
    scratch.* = .{};
    const text = &scratch.text;
    const renderer = &scratch.renderer;
    text.write("NIHOS RV32 CONSOLE\n");
    for (1..7) |_| text.write("fixed header\n");
    if (!text.setScrollTop(7)) return false;
    for (7..L.rows - 1) |row| {
        text.write(&.{@intCast('A' + row % 26)});
        text.write(" deterministic console line\n");
    }
    if (!renderer.submit(frame, 1440, text, .green)) return false;
    text.write("first scroll\nsecond scroll\n");
    if (!renderer.submit(frame, 1440, text, .green)) return false;
    while (renderer.moving()) if (!renderer.step(frame, 1440, .green)) return false;
    if (renderer.scrolls == 0) return false;
    return console.raster.paintControl(null, frame, 1440, .{ .left = 1100, .top = 650, .right = 1260, .bottom = 706 }, "LOGS", .green);
}
