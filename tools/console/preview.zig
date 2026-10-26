//! Host bridge for the same grid/raster linked by the native console option.
const console = @import("text_console");
export fn nih_console_preview(frame: [*]u8, length: usize, text: [*]const u8, text_length: usize, failed: bool, palette: u32, face: u32) bool {
    if (face < 1 or face > 2) return false;
    if (palette > 2) return false;
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
    var grid = console.Grid(console.raster.columns, console.raster.rows){};
    console.snapshot.fill(&grid, &model, journal.spans(), journal.dropped);
    if (face == 2) return console.raster.paintFace(null, .source_code, frame[0..length], 1440, &grid, @fromBackingInt(@intCast(palette)));
    return console.raster.paintFace(null, .jetbrains, frame[0..length], 1440, &grid, @fromBackingInt(@intCast(palette)));
}
