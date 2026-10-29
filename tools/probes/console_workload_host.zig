//! Host reference uses the same fixture, not an independent pixel oracle.
const fixture = @import("fixture");
var scratch: fixture.Scratch = .{};
export fn render(out: [*]u8, length: usize) bool {
    return fixture.paint(out[0..length], &scratch);
}
