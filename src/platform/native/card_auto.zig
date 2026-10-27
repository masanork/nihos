//! Card insertion -> PIN-free application detection -> one local job -> removal.
//! Foreground only. Never logs identifiers, touch coordinates, PINs or values.
const card = @import("card");
const usb = @import("usb_probe.zig");
const i2c = @import("boot_i2c");
const timer = @import("timer_group");
const Pins = @import("display_probe.zig").Pins;
const display = @import("display_runtime.zig");
const renderer = @import("keypad_display.zig");
const photo = @import("photo_runtime.zig");
const options = @import("native_options");
const Service = card.ServiceType(true, ".flash.photo");
const License = card.License.Parser(".flash.photo");
var service = Service{};
var entry = card.Entry{};
var owner = card.Owner{};
var device: ?usb.Device = null;
var touch: ?card.Touch.Device = null;
var gate = card.Presence.Gate{};
pub var armed = false;
pub const Report = struct {
    job: u32 = 0,
    kind: u32 = 0,
    state: u32 = 0,
    fault: u32 = 0,
    sw: u32 = 0,
    pin_index: u32 = 0,
    pin1_remaining: u32 = 255,
    pin2_remaining: u32 = 255,
    pin1_verifies: u32 = 0,
    pin2_verifies: u32 = 0,
    fields: u32 = 0,
    photo_decoded: u32 = 0,
    photo_error: u32 = 0,
    shown: u32 = 0,
    missing: u32 = 0,
    truncated: u32 = 0,
    cleanup: u32 = 0,
    erased: u32 = 0,
};
pub var report = Report{};
pub fn diagnostic() Report {
    var result = report;
    result.state = @backingInt(if (service.fault != .none) service.fault_state else service.state);
    result.fault = @backingInt(service.fault);
    if (device) |link| if (link.policy.profile != .detection) {
        result.pin1_verifies = link.policy.verifies;
        result.pin2_verifies = link.policy.surface_verifies;
    };
    return result;
}
fn frame() []u8 {
    return @as([*]u8, @ptrFromInt(0x48030000))[0 .. 720 * 1280 * 2];
}
pub noinline fn prepare(clock: timer.Timer, panel: u32) linksection(".flash.photo") !void {
    clock.start();
    clock.disarm();
    defer clock.stop();
    try photo.prepare();
    if (!photo.close()) return error.Cleanup;
    var bus = i2c.Master(Pins){ .pins = .{ .clock = clock } };
    const selected: card.Touch.Panel = switch (panel) {
        1 => .ili9881c,
        2 => .st7123,
        3 => .st7121,
        else => return error.Panel,
    };
    touch = try card.Touch.Device.identify(&bus, selected);
    if (touch.?.width != 720 or touch.?.height != 1280) return error.Geometry;
    renderer.static_frame = true;
    renderer.overview_frame = false;
    renderer.pin_kind = 0;
    try card.ResultScreen.notice(".flash.keypad.font", frame(), "カードを置いてください", "マイナンバーカード・IC運転免許証");
}
noinline fn redraw(clock: timer.Timer, panel: u32) linksection(".flash.photo") !void {
    const result = display.replace(clock, panel);
    clock.start();
    clock.disarm();
    if (result.status != 1) return error.Display;
}
noinline fn notice(clock: timer.Timer, panel: u32, title: []const u8, detail: []const u8) linksection(".flash.photo") !void {
    renderer.static_frame = true;
    renderer.overview_frame = false;
    renderer.pin_kind = 0;
    try card.ResultScreen.notice(".flash.keypad.font", frame(), title, detail);
    try redraw(clock, panel);
}
noinline fn open(clock: timer.Timer) linksection(".flash.photo") !void {
    var enumeration = usb.Report{};
    device = try usb.Device.openAutomatic(clock, &enumeration);
    armed = true;
    if (enumeration.vid != 0x054c or enumeration.pid != 0x0dc9) return error.UnsupportedReader;
    owner = .{ .sequence = 3 };
}
noinline fn close() linksection(".flash.photo") !void {
    if (device) |*link| {
        if (!link.cut_verified) try link.powerCut();
        try link.close();
        device = null;
    }
}
pub noinline fn emergency() linksection(".flash.photo") bool {
    entry.clear();
    var clean = true;
    if (device) |*link| clean = link.emergency();
    device = null;
    service.disconnected();
    service.dismiss() catch {
        clean = false;
    };
    if (!photo.close()) clean = false;
    if (!display.emergency()) clean = false;
    armed = false;
    return clean;
}
noinline fn detect() linksection(".flash.photo") !u2 {
    try service.startDetection();
    for (0..8) |_| {
        _ = try owner.stepWithPowerCut(&service, &device.?);
        if (service.state == .done) break;
    }
    const kind = service.detectedKind() orelse return error.Detection;
    try close();
    try service.dismiss();
    report.cleanup = 2;
    report.erased = 1;
    return kind;
}
noinline fn begin(clock: timer.Timer, kind: u2) linksection(".flash.photo") !void {
    report.cleanup = 0;
    report.erased = 0;
    try photo.prepare();
    if (kind == 1) {
        try open(clock);
        device.?.policy.profile = .mynumber;
        device.?.policy.probe_only = true;
        try service.startSurfaceProbe();
        for (0..8) |_| {
            _ = try owner.stepWithPowerCut(&service, &device.?);
            if (service.state == .done) break;
        }
        report.pin2_remaining = service.surface_remaining orelse 255;
        if (service.fault != .none or service.cleanup_failed) return error.Counter;
        try close();
        try service.dismiss();
        try open(clock);
        device.?.policy.profile = .mynumber;
        try service.startPortraitWith(card.Surface.Parser(".flash.photo"), photo.raw());
    } else {
        try open(clock);
        device.?.policy.profile = .license;
        try service.startLicenseWith(License, photo.raw());
    }
}
noinline fn input(clock: timer.Timer, panel: u32, log: anytype) linksection(".flash.photo") !void {
    const prompt = service.prompt() orelse return error.Prompt;
    entry.clear();
    entry.contact.held = true;
    entry.contact.disarm();
    renderer.static_frame = false;
    renderer.overview_frame = false;
    renderer.demo_frame = false;
    renderer.pin_kind = prompt.index;
    renderer.read_remaining = prompt.remaining;
    try redraw(clock, panel);
    report.pin_index = prompt.index;
    if (report.kind == 2 and prompt.index == 1) report.pin2_remaining = service.license_remaining[1];
    if (prompt.index == 2) report.pin2_remaining = prompt.remaining else report.pin1_remaining = prompt.remaining;
    report.pin1_verifies = device.?.policy.verifies;
    report.pin2_verifies = device.?.policy.surface_verifies;
    log.prompt(&report);
    var bus = i2c.Master(Pins){ .pins = .{ .clock = clock } };
    var queued: u8 = 0;
    const deadline = (clock.counter() orelse 0) + 180_000_000;
    var next_slot: u64 = 0;
    while (service.prompt() != null) {
        if (!device.?.connected()) return error.Disconnected;
        const now = clock.counter() orelse return error.Timer;
        if (now >= next_slot) {
            if (try device.?.slotState(&owner.sequence) != 0) return error.Removed;
            next_slot = now + 250_000;
        }
        const sample = try touch.?.sample(&bus);
        if (sample == .fresh) {
            const point = sample.fresh;
            entry.touchWide(&service, point.contacts, point.x, point.y);
        }
        const view = entry.view(&service);
        if (view.masked_digits != queued) {
            if (renderer.update(view.masked_digits)) |_| queued = view.masked_digits else |err| if (err != error.Busy) return err;
        }
        if (now >= deadline) service.cancel();
        if (!bus.pins.delay(20_000)) return error.Timer;
    }
    entry.clear();
}
noinline fn renderResult(clock: timer.Timer, panel: u32) linksection(".flash.photo") !void {
    var portrait: ?[]const u8 = null;
    if (service.portrait()) |encoded| portrait = photo.decode(encoded);
    report.photo_decoded = @intFromBool(portrait != null);
    report.photo_error = photo.report.error_code;
    var painted: card.ResultScreen.Paint = .{};
    if (report.kind == 1) {
        if (service.attributesResult()) |attributes| {
            painted = try card.ResultScreen.overview(".flash.keypad.font", frame(), attributes, portrait);
            report.fields = 15;
        }
    } else if (service.licenseResult()) |raw| {
        const attributes = try License.decode(raw, photo.raw()[4096..][0..card.License.text_bytes]);
        painted = try card.ResultScreen.licenseOverview(".flash.keypad.font", frame(), attributes, portrait);
        report.fields = 31;
    }
    if (report.fields == 0) {
        try notice(clock, panel, "読み取りを中止しました", "カードを取り外してください");
        return;
    }
    renderer.static_frame = true;
    renderer.overview_frame = true;
    try redraw(clock, panel);
    report.shown = painted.shown;
    report.missing = painted.missing;
    report.truncated = @intFromBool(painted.truncated);
}
noinline fn waitForDismiss(clock: timer.Timer) linksection(".flash.photo") !void {
    try open(clock); // Only slot status; the authenticated link is already cut.
    var bus = i2c.Master(Pins){ .pins = .{ .clock = clock } };
    var gesture = card.Contact{ .held = true };
    var absent: u8 = 0;
    var next_slot: u64 = 0;
    const until = (clock.counter() orelse 0) + 180_000_000;
    while (true) {
        const now = clock.counter() orelse return error.Timer;
        if (now >= next_slot) {
            absent = if (try device.?.slotState(&owner.sequence) == 2) absent + 1 else 0;
            if (absent >= 2) break;
            next_slot = now + 250_000;
        }
        const sample = try touch.?.sample(&bus);
        if (sample == .fresh) {
            const point = sample.fresh;
            if (gesture.sample(true, point.contacts, point.x, point.y, anyTap)) |_| break;
        }
        if (now >= until) break;
        if (!bus.pins.delay(20_000)) return error.Timer;
    }
    try close();
}
fn anyTap(_: u16, _: u16) ?card.Key {
    return .submit;
}
noinline fn job(clock: timer.Timer, panel: u32, log: anytype) linksection(".flash.photo") !void {
    try begin(clock, @intCast(report.kind));
    for (0..180) |_| {
        if (service.state == .done) break;
        if (service.prompt() != null) try input(clock, panel, log) else {
            if (!device.?.connected()) return error.Disconnected;
            _ = try owner.stepWithPowerCut(&service, &device.?);
        }
    }
    if (service.state != .done) return error.Exhausted;
    report.state = @backingInt(service.fault_state);
    report.fault = @backingInt(service.fault);
    report.sw = service.last_sw;
    report.pin1_verifies = device.?.policy.verifies;
    report.pin2_verifies = device.?.policy.surface_verifies;
    try close();
    if (service.cleanup_failed) return error.Cleanup;
    report.cleanup = 2;
    try renderResult(clock, panel);
    log.result(&report);
    if (report.fields != 0) try waitForDismiss(clock);
    try service.dismiss();
    if (!photo.close()) return error.Cleanup;
    report.erased = 1;
    try notice(clock, panel, "カードを取り外してください", "取り外し後、次のカードを検知します");
    log.finish(&report);
}
pub noinline fn run(clock: timer.Timer, panel: u32, log: anytype) linksection(".flash.photo") void {
    clock.start();
    clock.disarm();
    var bus = i2c.Master(Pins){ .pins = .{ .clock = clock } };
    while (display.snapshot().frames < 32) if (!bus.pins.delay(20_000)) halt();
    const refreshed = display.snapshot();
    log.refresh(&refreshed);
    log.boot(&photo.report);
    while (true) {
        if (device == null) open(clock) catch {
            if (!emergency()) halt();
            notice(clock, panel, "リーダーを確認してください", "USB-Aにカードリーダーを接続してください") catch {
                halt();
            };
            if (!bus.pins.delay(1_000_000)) halt();
            continue;
        };
        const slot = device.?.slotState(&owner.sequence) catch {
            if (!emergency()) halt();
            gate.finish();
            notice(clock, panel, "リーダーを確認してください", "カードを取り外してから接続してください") catch {
                halt();
            };
            continue;
        };
        const event = gate.observe(slot != 2);
        if (event == .removed) {
            notice(clock, panel, "カードを置いてください", "マイナンバーカード・IC運転免許証") catch {
                halt();
            };
            log.removed(gate.job);
        } else if (event == .detect) {
            report = .{ .job = gate.job };
            notice(clock, panel, "カードを確認しています", "しばらくお待ちください") catch {
                halt();
            };
            const kind = detect() catch {
                report = diagnostic();
                if (report.fault == 0) report.fault = 0x80000000;
                log.abort(&report);
                if (!emergency()) halt();
                gate.finish();
                notice(clock, panel, "カードを判定できませんでした", "カードを取り外してください") catch {
                    halt();
                };
                continue;
            };
            report.kind = kind;
            log.detected(&report);
            if (options.card_auto_probe) {
                notice(clock, panel, if (kind == 1) "マイナンバーカードを検知しました" else if (kind == 2) "IC運転免許証を検知しました" else "対応するカードではありません", "PINは送信しません・取り外して次へ") catch {
                    halt();
                };
            } else if (kind == 1 or kind == 2) job(clock, panel, log) catch {
                report = diagnostic();
                if (report.fault == 0) report.fault = 0x80000000;
                log.abort(&report);
                if (!emergency()) halt();
                notice(clock, panel, "読み取りを中止しました", "カードを取り外してください") catch {
                    halt();
                };
            } else notice(clock, panel, "対応するカードではありません", "カードを取り外してください") catch {
                halt();
            };
            gate.finish();
        }
        if (!bus.pins.delay(250_000)) halt();
    }
}
fn halt() noreturn {
    while (true) asm volatile ("wfi");
}
