const std = @import("std");
const bridge = @import("sdmmc_owner.zig");
const sd = @import("../soc/esp32p4/sdmmc.zig");
const Model = struct {
    quiescence: sd.Quiescence = .{},
    launches: u32 = 0,
    fail_read: bool = false,
    fail_write: bool = false,
    fail_before_launch: bool = false,
    write_issued: bool = false,
    pub fn writeSectorControlled(self: *@This(), _: u32, _: *const [512]u8, _: anytype) sd.Error!void {
        self.launches += 1;
        self.write_issued = !self.fail_before_launch;
        if (self.fail_write) return error.Timeout;
    }
    pub fn readSectorControlled(self: *@This(), _: u32, _: *[512]u8, _: anytype) sd.Error!void {
        self.launches += 1;
        if (self.fail_read) return error.Timeout;
    }
};
const Control = struct {
    reason: sd.StopReason = .none,
    pub fn finishReason(self: @This()) sd.StopReason {
        return self.reason;
    }
};
const FaultBus = struct {
    pub const experimental_sd_write = true;
    stall_stop: bool,
    stall_fsm: bool,
    descriptor_stuck: bool,
    fail_release: bool,
    stopped: u32 = 0,
    releases: u32 = 0,
    issued: bool = false,
    pub fn read(self: *@This(), offset: usize) u32 {
        return switch (offset) {
            sd.regs.interrupts => (1 << 2) | (1 << 3),
            sd.regs.response => 0x900,
            sd.regs.dma_status => if (self.stall_fsm) 2 << 13 else 0,
            sd.regs.ctrl => if (self.stall_stop and self.stopped != 0) 4 else 0,
            sd.regs.descriptor => if (self.descriptor_stuck) 0x4ff1_0000 else 0,
            else => 0,
        };
    }
    pub fn write(self: *@This(), offset: usize, value: u32) void {
        if (offset == sd.regs.dma_mode and value == 0) self.stopped += 1;
        if (offset == sd.regs.command and (value & 63 == 17 or value & 63 == 24)) self.issued = true;
    }
    pub fn delay(_: *@This(), _: u32) void {}
    pub fn prepareDma(_: *@This(), _: u32) ?u32 {
        return 0x4ff1_0000;
    }
    pub fn finishDma(_: *@This(), _: *[512]u8, _: u32) bool {
        return true;
    }
    pub fn prepareWriteDma(_: *@This(), _: *const [512]u8) ?u32 {
        return 0x4ff1_0000;
    }
    pub fn finishWriteDma(_: *@This()) bool {
        return true;
    }
    pub fn releaseDma(self: *@This()) bool {
        std.debug.assert(self.stopped != 0 and !self.stall_stop and !self.stall_fsm);
        self.releases += 1;
        return !self.fail_release;
    }
};
test "block owner retains an incomplete DMA fence and denies further requests" {
    for (0..3) |missing| {
        var controller = Model{ .fail_read = true };
        if (missing == 0) controller.quiescence.device_idle = false;
        if (missing == 1) controller.quiescence.descriptors_released = false;
        if (missing == 2) controller.quiescence.cache_handed_back = false;
        var owner = bridge.ReadOwner{};
        var data: [512]u8 = @splat(0);
        try std.testing.expectError(error.Quarantined, owner.read(&controller, 0, &data, 1, Control{ .reason = .removed }));
        try std.testing.expect(owner.busy());
        try std.testing.expect(!owner.canRestart(false, false, true));
        try std.testing.expectError(error.Busy, owner.read(&controller, 0, &data, 2, Control{}));
        try std.testing.expectEqual(@as(u32, 1), controller.launches);
        try std.testing.expectError(error.Busy, owner.requests.discard(.{ .slot = 0, .generation = 1 }));
    }
}
test "card session restart requires an idle fenced owner and unused generation" {
    var owner = bridge.ReadOwner{};
    try std.testing.expect(owner.canRestart(false, false, true));
    try std.testing.expect(!owner.canRestart(true, false, true));
    try std.testing.expect(!owner.canRestart(false, true, true));
    try std.testing.expect(!owner.canRestart(false, false, false));
    owner.generation = 0xffff_ffff;
    try std.testing.expect(!owner.canRestart(false, false, true));
}
test "block owner closes stop notification window before completion publication" {
    for ([_]sd.StopReason{ .none, .cancelled, .removed }) |reason| {
        var controller = Model{};
        var owner = bridge.ReadOwner{};
        var data: [512]u8 = @splat(0);
        const result = owner.read(&controller, 0, &data, 1, Control{ .reason = reason });
        switch (reason) {
            .none => try result,
            .cancelled => try std.testing.expectError(error.Cancelled, result),
            .removed => try std.testing.expectError(error.Removed, result),
        }
        try std.testing.expect(!owner.busy());
        try std.testing.expectError(error.StaleHandle, owner.requests.discard(.{ .slot = 0, .generation = 1 }));
    }
}
test "block owner publishes failed reads only after quiescence" {
    var controller = Model{ .fail_read = true };
    var owner = bridge.ReadOwner{};
    var data: [512]u8 = @splat(0);
    try std.testing.expectError(error.ReadFailed, owner.read(&controller, 0, &data, 1, Control{}));
    try std.testing.expect(!owner.busy());
}

test "unproved reset idle descriptor or cache handback quarantines the actual block owner" {
    const owner_module = bridge;
    const Source = struct {
        model: *FaultBus,
        enabled: bool,
        pub fn cancelled(self: @This()) bool {
            return self.enabled and self.model.issued;
        }
    };
    for ([_]bool{ false, true }) |linked| {
        for (0..4) |fault| {
            var model = FaultBus{ .stall_stop = fault == 0, .stall_fsm = fault == 1, .descriptor_stuck = fault == 2, .fail_release = fault == 3 };
            var controller = sd.Controller(*FaultBus){ .io = &model, .poll_limit = 4, .rca = 1 << 16, .sectors = 8 };
            var owner = owner_module.ReadOwner{};
            var signal = owner_module.Signal{};
            var data: [512]u8 = @splat(0xa5);
            const control = signal.begin().?;
            const relay = bridge.CancelRelay(Source){ .target = control, .source = .{ .model = &model, .enabled = linked } };
            try std.testing.expectError(error.Quarantined, owner.read(&controller, 0, &data, control.ticket, relay));
            try std.testing.expect(owner.busy() and controller.cleanup_failed);
            try std.testing.expect(!controller.quiescence.complete());
            try std.testing.expectError(error.Controller, controller.prepare());
            try std.testing.expectError(error.Controller, controller.readSector(0, &data));
            if (fault < 2) try std.testing.expectEqual(@as(u32, 0), model.releases);
        }
    }
}

test "write owner distinguishes prelaunch failure from unknown publication" {
    const bytes: [512]u8 = @splat(0x5a);
    for ([_]bool{ false, true }) |launched| {
        var controller = Model{ .fail_write = true, .fail_before_launch = !launched };
        var owner = bridge.ReadOwner{};
        const result = owner.write(&controller, 0, &bytes, 1, Control{});
        if (launched) {
            try std.testing.expectError(error.PublicationUnknown, result);
            try std.testing.expect(owner.recovery_required);
            try std.testing.expectError(error.RecoveryRequired, owner.write(&controller, 0, &bytes, 2, Control{}));
            var out: [512]u8 = undefined;
            try std.testing.expectError(error.RecoveryRequired, owner.read(&controller, 0, &out, 2, Control{}));
            try std.testing.expectEqual(@as(u32, 1), controller.launches);
        } else {
            try std.testing.expectError(error.WriteFailed, result);
            try std.testing.expect(!owner.recovery_required);
        }
        try std.testing.expect(!owner.busy());
    }
}

test "late cancellation or removal after launched write requires recovery" {
    const bytes: [512]u8 = @splat(0);
    for ([_]sd.StopReason{ .none, .cancelled, .removed }) |reason| {
        var controller = Model{};
        var owner = bridge.ReadOwner{};
        const result = owner.write(&controller, 0, &bytes, 1, Control{ .reason = reason });
        if (reason == .none) {
            try result;
            try std.testing.expect(!owner.recovery_required);
        } else {
            try std.testing.expectError(error.PublicationUnknown, result);
            try std.testing.expect(owner.recovery_required);
        }
        try std.testing.expect(!owner.busy());
    }
}

test "write owner retains the source lease when DMA quiescence is unproved" {
    const bytes: [512]u8 = @splat(0);
    for (0..3) |missing| {
        var controller = Model{ .fail_write = true };
        if (missing == 0) controller.quiescence.device_idle = false;
        if (missing == 1) controller.quiescence.descriptors_released = false;
        if (missing == 2) controller.quiescence.cache_handed_back = false;
        var owner = bridge.ReadOwner{};
        try std.testing.expectError(error.Quarantined, owner.write(&controller, 0, &bytes, 1, Control{}));
        try std.testing.expect(owner.busy() and owner.recovery_required);
        try std.testing.expectError(error.Busy, owner.write(&controller, 0, &bytes, 2, Control{}));
        try std.testing.expectEqual(@as(u32, 1), controller.launches);
    }
}

test "actual write controller marks launch and owner gates cancellation after CMD24" {
    const Source = struct {
        bus: *FaultBus,
        pub fn cancelled(self: @This()) bool {
            return self.bus.issued;
        }
    };
    const bytes: [512]u8 = @splat(0x42);
    for ([_]bool{ false, true }) |cancel| {
        var bus = FaultBus{ .stall_stop = false, .stall_fsm = false, .descriptor_stuck = false, .fail_release = false };
        var controller = sd.Controller(*FaultBus){ .io = &bus, .poll_limit = 4, .ready_poll_limit = 2, .rca = 1 << 16, .sectors = 8 };
        var owner = bridge.ReadOwner{};
        var signal = bridge.Signal{};
        const control = signal.begin().?;
        if (cancel) {
            const relay = bridge.CancelRelay(Source){ .target = control, .source = .{ .bus = &bus } };
            try std.testing.expectError(error.PublicationUnknown, owner.write(&controller, 0, &bytes, control.ticket, relay));
            try std.testing.expect(owner.recovery_required);
        } else {
            try owner.write(&controller, 0, &bytes, control.ticket, control);
            try std.testing.expect(!owner.recovery_required);
        }
        try std.testing.expect(controller.write_issued and bus.issued);
        try std.testing.expect(controller.quiescence.complete() and !owner.busy());
    }
}
