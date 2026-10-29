//! Host-only adapter for full, incremental and scrolling console updates.
const console = @import("text_console");
const L = console.raster.Layout(.basic_light);
const Text = console.Grid(L.columns, L.rows);
const Renderer = console.raster.Renderer(null, .basic_light);
var text: Text = .{};
var renderer: Renderer = .{};
const bytes = 720 * 1280 * 2;

export fn setup(out: [*]u8, length: usize) bool {
    if (length < bytes) return false;
    text = .{};
    renderer = .{};
    text.write("NIHOS CONSOLE BENCH\n");
    for (1..7) |_| text.write("fixed header\n");
    if (!text.setScrollTop(7)) return false;
    for (7..L.rows - 1) |row| {
        text.write(&.{@intCast('A' + row % 26)});
        text.write(" deterministic console line\n");
    }
    return renderer.submit(out[0..length], 1440, &text, .green);
}
export fn render(out: [*]u8, length: usize, mode: u32) bool {
    if (length < bytes) return false;
    const frame = out[0..length];
    if (mode == 0) return console.raster.paintFace(null, .basic_light, frame, 1440, &text, .green);
    if (mode == 1) text.write("incremental text") else if (mode == 2) text.write("scroll line\n") else return false;
    if (!renderer.submit(frame, 1440, &text, .green)) return false;
    while (renderer.moving()) if (!renderer.step(frame, 1440, .green)) return false;
    return if (mode == 2) renderer.scrolls != 0 else renderer.partial_updates != 0;
}
