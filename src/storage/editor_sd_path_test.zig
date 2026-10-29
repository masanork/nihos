//! Host-only end-to-end editor/checkpoint/SD-owner test. MMIO and the media
//! durability barrier are modeled; this is not a native SD driver or emulator.
const std = @import("std");
const session = @import("../console/session.zig");
const sd = @import("../soc/esp32p4/sdmmc.zig");
const bridge = @import("../fs/sdmmc_owner.zig");
const model = @import("model_media.zig");
const sectors = @import("sector_media.zig");
const checkpoint = @import("checkpoint_model.zig");
const Backing = model.Media(40 * 4096);
const Bus = struct {
    pub const experimental_sd_write = true;
    backing: *Backing,
    data: [512]u8 = @splat(0),
    argument: u32 = 0,
    interrupts: u32 = 0,
    commands: usize = 0,
    pub fn read(self: *@This(), reg: usize) u32 {
        return switch (reg) {
            sd.regs.interrupts => self.interrupts,
            sd.regs.response => 0x900,
            else => 0,
        };
    }
    pub fn write(self: *@This(), reg: usize, value: u32) void {
        if (reg == sd.regs.interrupts) self.interrupts &= ~value;
        if (reg == sd.regs.argument) self.argument = value;
        if (reg != sd.regs.command) return;
        const cmd = value & 63;
        self.interrupts = 1 << 2;
        if (cmd == 17) {
            self.backing.read(@as(u64, self.argument) * 512, &self.data) catch {
                self.interrupts = 1 << 7;
                return;
            };
            self.interrupts |= 1 << 3;
            self.commands += 1;
        } else if (cmd == 24) {
            self.backing.write(@as(u64, self.argument) * 512, &self.data) catch {
                self.interrupts = 1 << 7;
                return;
            };
            self.interrupts |= 1 << 3;
            self.commands += 1;
        }
    }
    pub fn delay(_: *@This(), _: u32) void {}
    pub fn prepareDma(_: *@This(), _: u32) ?u32 {
        return 1;
    }
    pub fn finishDma(self: *@This(), out: *[512]u8, _: u32) bool {
        out.* = self.data;
        return true;
    }
    pub fn prepareWriteDma(self: *@This(), bytes: *const [512]u8) ?u32 {
        self.data = bytes.*;
        return 1;
    }
    pub fn finishWriteDma(_: *@This()) bool {
        return true;
    }
    pub fn releaseDma(_: *@This()) bool {
        return true;
    }
};
const Controller = sd.Controller(*Bus);
const Owner = struct {
    pub const Lease = u32;
    controller: *Controller,
    backing: *Backing,
    requests: bridge.ReadOwner = .{},
    signal: bridge.Signal = .{},
    turns: usize = 0,
    pub fn checkRange(_: *@This(), lease: Lease, first: u64, count: u64) error{Io}!void {
        if (lease != 1 or first != 8 or count != 256) return error.Io;
    }
    fn check(lease: Lease, lba: u32) error{Io}!void {
        if (lease != 1 or lba < 8 or lba >= 264) return error.Io;
    }
    pub fn readSector(self: *@This(), lease: Lease, lba: u32, out: *[512]u8) error{Io}!void {
        try check(lease, lba);
        const control = self.signal.begin() orelse return error.Io;
        self.requests.read(self.controller, lba, out, control.ticket, control) catch return error.Io;
        self.turns += 1; // A modeled scheduler opportunity, not a latency claim.
    }
    pub fn writeSector(self: *@This(), lease: Lease, lba: u32, bytes: *const [512]u8) error{Io}!void {
        try check(lease, lba);
        const control = self.signal.begin() orelse return error.Io;
        self.requests.write(self.controller, lba, bytes, control.ticket, control) catch return error.Io;
        self.turns += 1;
    }
    pub fn sync(self: *@This(), lease: Lease) error{Io}!void {
        if (lease != 1 or self.requests.recovery_required) return error.Io;
        self.backing.sync() catch {
            self.requests.recovery_required = true;
            return error.Io;
        };
    }
};
const Device = sectors.Media(Owner, 32 * 4096);
const Store = checkpoint.Store(Device, .{ .leaf_pages = 2, .index_pages = 8 });
const Sink = struct {
    pub fn write(_: *@This(), _: []const u8) void {}
};

test "editor save traverses SD controller and survives modeled restart" {
    var backing: Backing = .{};
    var bus = Bus{ .backing = &backing };
    var controller = Controller{ .io = &bus, .poll_limit = 4, .ready_poll_limit = 2, .rca = 1 << 16, .sectors = 320 };
    var owner = Owner{ .controller = &controller, .backing = &backing };
    var device = try Device.init(&owner, 1, 8, 320);
    var store: Store = .{};
    try store.format(&device);
    var document: session.Model = .{};
    var sink: Sink = .{};
    var keyboard: session.input.Hid = .{};
    const usages = [_]u8{ 0x22, 0x28, 0x16, 0x04, 0x19, 0x08, 0x07, 0x2c, 0x17, 0x08, 0x1b, 0x17, 0x2c, 0x2c };
    for (usages) |usage| _ = document.handle(keyboard.feed(0, usage).?, &sink);
    try std.testing.expectEqualStrings("saved text  ", document.editorText());
    try store.begin();
    try store.put(1, document.editorText());
    try store.commit();
    try std.testing.expect(owner.turns > 0 and bus.commands > 0);
    backing.powerLoss();
    var bus2 = Bus{ .backing = &backing };
    var controller2 = Controller{ .io = &bus2, .poll_limit = 4, .ready_poll_limit = 2, .rca = 1 << 16, .sectors = 320 };
    var owner2 = Owner{ .controller = &controller2, .backing = &backing };
    var device2 = try Device.init(&owner2, 1, 8, 320);
    var recovered: Store = .{};
    try recovered.recover(&device2);
    var buf: [64]u8 = undefined;
    const n = try recovered.read(1, 0, &buf);
    var restarted: session.Model = .{};
    try restarted.loadEditor(buf[0..n]);
    try std.testing.expectEqualStrings("saved text  ", restarted.editorText());
    for (backing.stable[0 .. 8 * 512]) |byte| try std.testing.expectEqual(@as(u8, 0xff), byte);
    for (backing.stable[264 * 512 ..]) |byte| try std.testing.expectEqual(@as(u8, 0xff), byte);
    // A torn first write is unknown and must close the owner until recovery.
    backing.background = .all;
    backing.cut = .{ .event = 0, .prefix = 31 };
    try recovered.begin();
    try std.testing.expectError(error.Io, recovered.put(1, "unsaved"));
    try std.testing.expect(owner2.requests.recovery_required);
    var bytes: [512]u8 = undefined;
    try std.testing.expectError(error.Io, owner2.readSector(1, 8, &bytes));
    try std.testing.expectEqual(@as(u32, 0), owner2.signal.active());
    backing.powerLoss();
    var bus3 = Bus{ .backing = &backing };
    var controller3 = Controller{ .io = &bus3, .poll_limit = 4, .ready_poll_limit = 2, .rca = 1 << 16, .sectors = 320 };
    var owner3 = Owner{ .controller = &controller3, .backing = &backing };
    var device3 = try Device.init(&owner3, 1, 8, 320);
    var after_fault: Store = .{};
    try after_fault.recover(&device3);
    const n2 = try after_fault.read(1, 0, &buf);
    try std.testing.expectEqualStrings("saved text  ", buf[0..n2]);
}
