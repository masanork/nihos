//! Emulator offscreen adapter for the same Document/input/presentation used by
//! normal boot. No panel, DMA, storage or Scheme VM is exercised here.
const std = @import("std");
const console = @import("text_console");
const Layout = console.raster.Layout(.jetbrains);
const Text = console.Grid(Layout.columns, Layout.rows);
pub fn Live(comptime section: ?[]const u8) type {
    return struct {
        const Self = @This();
        model: console.scratch.Model,
        text: Text,
        renderer: console.raster.Renderer(section, .jetbrains),
        pub fn start(self: *Self, frame: []u8) bool {
            @memset(std.mem.asBytes(self), 0);
            self.model.initInPlace();
            return self.render(frame);
        }
        pub fn render(self: *Self, frame: []u8) bool {
            // Deterministic observation fixtures; these are not native counters.
            switch (self.model.takeSystemRequest()) {
                .none => {},
                .log => {
                    self.model.snapshot.write("Emulator fixture / retained boot log\n");
                    for (0..60) |_| self.model.snapshot.write("retained observation\n");
                    self.model.snapshot.write("END OF FIXTURE LOG");
                    self.model.snapshot.dropped = 17;
                },
                .memory => {
                    self.model.snapshot.write("Emulator fixture / CPU0 owner only\n");
                    self.model.snapshot.usage("SRAM boot arena", @as(?struct { capacity: u32, free: u32 }, .{ .capacity = 65536, .free = 49152 }));
                },
                .tasks => {
                    self.model.snapshot.write("Emulator fixture / per-field counters\n");
                    self.model.snapshot.counters(0, .{ .ticks = 42, .switches = 7, .calls = 3 });
                },
            }
            self.model.render(&self.text);
            return self.renderer.submit(frame, 1440, &self.text, .neutral);
        }
        pub fn press(self: *Self, frame: []u8, modifiers: u8, usage: u8) error{InvalidFrame}!bool {
            const before = self.model.doc.revision;
            self.model.feedHid(modifiers, usage);
            if (!self.render(frame)) return error.InvalidFrame;
            return before != self.model.doc.revision;
        }
        pub fn serialByte(self: *Self, frame: []u8, byte: u8, now: u64) error{InvalidFrame}!bool {
            const before = self.model.doc.revision;
            self.model.feedSerial(byte, now);
            self.model.expireSerial(now);
            if (!self.render(frame)) return error.InvalidFrame;
            return before != self.model.doc.revision;
        }
        pub fn document(self: *const Self) []const u8 {
            return self.model.doc.slice();
        }
    };
}
