//! One local, explicit Input Support read. No PIN/data or keystroke logging.
const std = @import("std");
const card = @import("card");
const usb = @import("usb_probe.zig");
const i2c = @import("boot_i2c");
const timer = @import("timer_group");
const Pins = @import("display_probe.zig").Pins;
const display = @import("display_runtime.zig");
const renderer = @import("keypad_display.zig");
var service = card.Service{};
var entry = card.Entry{};
var owner = card.Owner{ .sequence = 3 };
var device: ?usb.Device = null;
var touch: ?card.Touch.Device = null;
var remaining_before: u32 = 255;
var preflight_cut: u32 = 0;
var erased = false;
pub var armed = false;
var abort_fault: u32 = 0;
var dma_erased = false;
pub const Report = struct {
    status: u32 = 2,
    fault: u32 = 0,
    remaining_before: u32 = 255,
    preflight_cut: u32 = 0,
    remaining_after: u32 = 255,
    verifies: u32 = 0,
    cleanup: u32 = 0,
    vbus_off: u32 = 0,
    attributes: u32 = 0,
    shown: u32 = 0,
    missing_glyphs: u32 = 0,
    erased: u32 = 0,
};
pub noinline fn prepare(clock: timer.Timer, panel: u32) linksection(".flash.text.card") !void {
    clock.start();
    clock.disarm();
    defer clock.stop();
    errdefer abort();
    // Prove the board-specific terminal cleanup on this reader BEFORE ever
    // offering PIN entry. This first job uses only empty VERIFY queries.
    for (0..2) |round| {
        var enumeration = usb.Report{};
        device = try usb.Device.openAuthenticated(clock, &enumeration);
        armed = true;
        if (enumeration.vid != 0x054c or enumeration.pid != 0x0dc9) return error.UnsupportedReader;
        owner = .{ .sequence = 3 };
        try service.start();
        for (0..8) |_| {
            if (!device.?.connected()) return error.Disconnected;
            _ = try owner.stepWithPowerCut(&service, &device.?);
            if (service.prompt() != null or service.state == .done) break;
        }
        const prompt = service.prompt() orelse return error.NotReady;
        if (round == 0) {
            if (device.?.policy.verifies != 0) return error.UnexpectedVerify;
            try device.?.powerCut();
            if (!device.?.cut_verified) return error.Cleanup;
            preflight_cut = 1;
            service.disconnected();
            try service.dismiss();
        } else {
            remaining_before = prompt.remaining;
            renderer.read_remaining = prompt.remaining;
        }
    }
    const selected: card.Touch.Panel = switch (panel) {
        1 => .ili9881c,
        2 => .st7123,
        3 => .st7121,
        else => return error.Panel,
    };
    var bus = i2c.Master(Pins){ .pins = .{ .clock = clock } };
    touch = try card.Touch.Device.identify(&bus, selected);
    if (touch.?.width != 720 or touch.?.height != 1280) return error.Geometry;
}

pub fn abort() void {
    if (device) |*link| dma_erased = link.emergency();
    entry.clear();
    const previous = service.fault;
    const unknown = previous == .pin_outcome_unknown;
    service.disconnected();
    abort_fault = @backingInt(if (unknown) previous else service.fault);
    service.dismiss() catch {
        std.crypto.secureZero(u8, std.mem.asBytes(&service));
        abort_fault = @backingInt(@as(@FieldType(card.Service, "fault"), .transport));
    };
    erased = true;
}
pub fn emergency() bool {
    armed = false;
    abort();
    return display.emergency() and dma_erased;
}
fn frame() []u8 {
    return @as([*]u8, @ptrFromInt(0x48030000))[0 .. 720 * 1280 * 2];
}
fn redraw(clock: timer.Timer, panel: u32) !void {
    const report = display.replace(clock, panel);
    // replace owns/stops the shared timer; resume foreground timing.
    clock.start();
    clock.disarm();
    if (report.status != 1) return error.Display;
}
pub noinline fn run(clock: timer.Timer, panel: u32, log: anytype) linksection(".flash.text.card") void {
    clock.start();
    clock.disarm();
    var report = Report{ .remaining_before = remaining_before, .preflight_cut = preflight_cut };
    var bus = i2c.Master(Pins){ .pins = .{ .clock = clock } };
    while (display.snapshot().frames < 32) {
        if (!bus.pins.delay(20_000)) {
            abort();
            break;
        }
    }
    const initial = display.snapshot();
    log.refresh(&initial);
    if (!erased) log.ready(&report);
    const deadline = (clock.counter() orelse 0) + 180_000_000;
    var queued: u8 = 0;
    while (service.state == .pin) {
        if (!device.?.connected()) {
            abort();
            break;
        }
        const sample = touch.?.sample(&bus) catch {
            abort();
            break;
        };
        if (sample == .fresh) {
            const point = sample.fresh;
            entry.touchWide(&service, point.contacts, point.x, point.y);
        }
        const view = entry.view(&service);
        if (queued != view.masked_digits) {
            if (renderer.update(view.masked_digits)) |_| queued = view.masked_digits else |err| {
                if (err != error.Busy) {
                    abort();
                    break;
                }
            }
        }
        const snapshot = display.snapshot();
        log.refresh(&snapshot);
        if ((clock.counter() orelse deadline) >= deadline) service.cancel();
        if (!bus.pins.delay(20_000)) {
            abort();
            break;
        }
    }
    entry.clear();
    // Exactly one service transaction, including terminal cleanup. No new
    // session, automatic retry, repeat VERIFY, or return to a live PIN screen.
    if (!erased) for (0..20) |_| {
        if (service.state == .done) break;
        _ = owner.stepWithPowerCut(&service, &device.?) catch {
            abort();
            break;
        };
    };
    report.fault = if (erased) abort_fault else @backingInt(service.fault);
    report.remaining_after = service.remaining orelse 255;
    if (device) |*link| {
        report.verifies = link.policy.verifies;
        report.cleanup = if (link.cut_verified) 2 else if (!service.cleanup_failed) 1 else 0;
        link.close() catch {
            abort();
        };
        dma_erased = !erased;
        report.vbus_off = @intFromBool(!erased);
    }
    if (service.result()) |attributes| {
        report.status = 1;
        report.attributes = 15;
        log.result(&report);
        renderer.static_frame = true;
        var pager = card.ResultScreen.Pager{};
        var gesture = card.Contact{};
        var keep = true;
        while (keep) {
            const painted = card.ResultScreen.result(".flash.keypad.font", frame(), attributes, &pager) catch {
                report.status = 2;
                abort();
                break;
            };
            report.missing_glyphs += painted.missing;
            redraw(clock, panel) catch {
                report.status = 2;
                abort();
                break;
            };
            report.shown |= @as(u32, 1) << @as(u2, @intCast(pager.field));
            const until = (clock.counter() orelse 0) + 180_000_000;
            while (true) {
                const sample = touch.?.sample(&bus) catch {
                    report.status = 2;
                    keep = false;
                    break;
                };
                if (sample == .fresh) {
                    const point = sample.fresh;
                    // Only explicit releases of a single contact advance.
                    if (gesture.sample(true, point.contacts, point.x, point.y, anyTap)) |_| {
                        keep = pager.next();
                        break;
                    }
                }
                if ((clock.counter() orelse until) >= until) {
                    keep = false;
                    break;
                }
                if (!bus.pins.delay(20_000)) {
                    report.status = 2;
                    keep = false;
                    break;
                }
            }
        }
    }
    service.cancel();
    if (service.state == .done) service.dismiss() catch {
        std.crypto.secureZero(u8, std.mem.asBytes(&service));
        report.status = 2;
        report.fault = @backingInt(@as(@FieldType(card.Service, "fault"), .transport));
    };
    entry.clear();
    renderer.static_frame = true;
    card.ResultScreen.message(".flash.keypad.font", frame(), report.status == 1);
    report.erased = @intFromBool(dma_erased);
    redraw(clock, panel) catch {
        report.status = 2;
        if (!display.emergency()) report.erased = 0;
    };
    if (report.erased == 1) armed = false;
    log.finish(&report);
    while (true) asm volatile ("wfi");
}
fn anyTap(_: u16, _: u16) ?card.Key {
    return .submit;
}
