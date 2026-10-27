//! Full-size keypad demonstration. Logs effects/counts, never key identities.
const card = @import("card");
const timer = @import("timer_group");
const i2c = @import("boot_i2c");
const Pins = @import("display_service").probe.Pins;
const screen = @import("display_service").runtime;
const renderer = @import("display_service").keypad;
pub const Event = struct { effect: u32, count: u32 };
pub const Report = struct {
    status: u32 = 2,
    pin_enabled: u32 = 0,
    vbus_off: u32 = 0,
    samples: u32 = 0,
    increments: u32 = 0,
    erases: u32 = 0,
    cancels: u32 = 0,
    confirms: u32 = 0,
    full: u32 = 0,
    updates: u32 = 0,
    retries: u32 = 0,
    shown_mask: u32 = 1,
    errors: u32 = 0,
    frames: u32 = 0,
};
pub fn run(clock: timer.Timer, panel: u32, log: anytype) void {
    var report = Report{};
    clock.start();
    clock.disarm();
    defer clock.stop();
    var bus = i2c.Master(Pins){ .pins = .{ .clock = clock } };
    i2c.usbPowerOff(&bus) catch {
        report.errors = 1;
        log.finish(&report);
        return;
    };
    report.vbus_off = 1;
    const selected: card.Touch.Panel = switch (panel) {
        1 => .ili9881c,
        2 => .st7123,
        3 => .st7121,
        else => {
            report.errors = 2;
            log.finish(&report);
            return;
        },
    };
    const touch = card.Touch.Device.identify(&bus, selected) catch {
        report.errors = 3;
        log.finish(&report);
        return;
    };
    log.start(&report);
    var model = card.KeypadDemo.Model{};
    var queued: u8 = 0;
    var seen: u32 = 0;
    var seen_at: u32 = 0;
    var published = false;
    const started = clock.counter() orelse return;
    while (true) {
        const sample = touch.sample(&bus) catch {
            report.errors = 4;
            log.finish(&report);
            return;
        };
        report.samples +|= 1;
        if (sample == .fresh) {
            const point = sample.fresh;
            if (model.sample(point.contacts, point.x, point.y)) |effect| {
                const event = Event{ .effect = @backingInt(effect), .count = model.count };
                log.event(&event);
            }
        }
        if (queued != model.count) {
            if (renderer.update(model.count)) |_| {
                queued = model.count;
                report.updates +|= 1;
            } else |err| {
                if (err != error.Busy) {
                    report.errors = 5;
                    log.finish(&report);
                    return;
                }
                report.retries +|= 1;
            }
        }
        const snapshot = screen.snapshot();
        log.refresh(&snapshot);
        report.frames = snapshot.frames;
        const shown = renderer.shown();
        if (shown > 4) {
            report.errors = 6;
            log.finish(&report);
            return;
        }
        if (shown != seen) {
            seen = shown;
            seen_at = snapshot.frames;
        } else if (snapshot.frames > seen_at) report.shown_mask |= @as(u32, 1) << @as(u5, @intCast(shown));
        report.increments = model.increments;
        report.erases = model.erases;
        report.cancels = model.cancels;
        report.confirms = model.confirms;
        report.full = model.full;
        const now = clock.counter() orelse return;
        const complete = report.shown_mask == 31 and report.erases > 0 and report.cancels > 0 and report.confirms > 0;
        if (!published and report.frames >= 32 and (complete or now - started >= 120_000_000)) {
            report.status = 1;
            log.finish(&report);
            published = true;
        }
        if (!bus.pins.delay(20_000)) return;
    }
}
