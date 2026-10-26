//! Host bridge for the same grid/raster linked by the native console option.
const console = @import("text_console");
export fn nih_console_preview(frame: [*]u8, length: usize, text: [*]const u8, text_length: usize, failed: bool, palette: u32, face: u32) bool {
    if (face > 3) return false;
    return switch (face) {
        0 => render(.basic, frame, length, text, text_length, failed, palette),
        1 => render(.jetbrains, frame, length, text, text_length, failed, palette),
        2 => render(.source_code, frame, length, text, text_length, failed, palette),
        3 => render(.basic_light, frame, length, text, text_length, failed, palette),
        else => false,
    };
}
fn render(comptime face: console.raster.Face, frame: [*]u8, length: usize, text: [*]const u8, text_length: usize, failed: bool, palette: u32) bool {
    if (palette > 4) return false;
    var journal = console.Journal(2048){};
    journal.append(text[0..text_length]);
    var model = console.boot.Model{};
    for ([_]console.boot.Stage{ .crt, .memory, .display_prepare }) |stage| {
        if (!model.begin(stage) or !model.complete(stage)) return false;
    }
    if (!model.unavailable(.storage) or !model.begin(.cores)) return false;
    if (failed) model.fail(1) else {
        if (!model.complete(.cores)) return false;
        for ([_]console.boot.Stage{ .display_scanout, .console }) |stage| {
            if (!model.begin(stage) or !model.complete(stage)) return false;
        }
    }
    const L = console.raster.Layout(face);
    var grid = console.Grid(L.columns, L.rows){};
    console.snapshot.fill(&grid, &model, journal.spans(), journal.dropped);
    return console.raster.paintFace(null, face, frame[0..length], 1440, &grid, @fromBackingInt(@intCast(palette)));
}
