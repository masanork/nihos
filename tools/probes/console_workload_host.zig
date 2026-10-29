//! Host reference uses the same fixture, not an independent pixel oracle.
const fixture = @import("fixture");
const options = @import("fixture_options");
const App = fixture.Fixture(@fromBackingInt(@intCast(options.face)), null);
var scratch: App.Scratch = .{};
export fn render(out: [*]u8, length: usize) bool {
    return App.paint(out[0..length], &scratch);
}
