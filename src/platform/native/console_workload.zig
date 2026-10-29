//! Emulator-only offscreen console exercise; no display or input emulation.
const console = @import("text_console");

pub fn Fixture(comptime face: console.raster.Face, comptime section: ?[]const u8) type {
    const L = console.raster.Layout(face);
    const Text = console.Grid(L.columns, L.rows);
    const Renderer = console.raster.Renderer(section, face);
    return struct {
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
            if (renderer.partial_updates == 0) return false;
            if ((face == .basic or face == .basic_light) and renderer.scrolls == 0) return false;
            const editor_fixture = @import("editor_fixture.zig");
            var editor = editor_fixture.Editor(Text){ .row = 9, .column = 0 };
            var keyboard = editor_fixture.Keyboard{};
            const Event = console.keyboard.Event;
            const events = [_]Event{
                .{ .modifiers = 1, .usage = 0x06 }, // control-C ignored
                .{ .modifiers = 2, .usage = 0x4f }, // shift-right ignored
                .{ .modifiers = 0, .usage = 0 }, // release filtered by driver
                .{ .modifiers = 0, .usage = 1 }, // malformed filtered by driver
                .{ .modifiers = 2, .usage = 0x37 }, // >
                .{ .modifiers = 0, .usage = 0x4f }, // right
                .{ .modifiers = 2, .usage = 0x20 }, // #
                .{ .modifiers = 0, .usage = 0x2a }, // backspace
                .{ .modifiers = 0, .usage = 0x50 }, // left
                .{ .modifiers = 0, .usage = 0x2c }, // space
            };
            var bus = editor_fixture.InputBus{ .events = &events };
            var driver = console.keyboard.Keyboard(editor_fixture.InputBus){ .bus = &bus };
            if (!(driver.begin() catch return false)) return false;
            var accepted: usize = 0;
            while (bus.next < events.len) {
                var batch: [4]Event = undefined;
                const count = driver.poll(&batch) catch return false;
                for (batch[0..count]) |event| {
                    const action = keyboard.press(event) orelse continue;
                    accepted += 1;
                    if (editor.apply(text, action) and !renderer.submit(frame, 1440, text, .green)) return false;
                }
            }
            if (accepted != 6 or driver.report.presses != 8 or driver.report.releases != 1 or driver.report.malformed != 1) return false;
            return console.raster.paintControl(section, frame, 1440, .{ .left = 1100, .top = 650, .right = 1260, .bottom = 706 }, "LOGS", .green);
        }
    };
}
