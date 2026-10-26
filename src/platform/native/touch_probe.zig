//! Interactive contact/colour experiment; no PIN model or card transport.
const card = @import("card");
const i2c = @import("boot_i2c");
const timer = @import("timer_group");
const display = @import("display_runtime.zig");
const Pins = @import("display_probe.zig").Pins;
extern fn nih_display_touch_feedback(u32) callconv(.c) bool;
pub const Event = struct { contacts: u32, x: u32, y: u32, color: u32, inferred_release: u32 };
pub const Report = struct {
    status: u32 = 2,
    pin_enabled: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    slots: u32 = 0,
    samples: u32 = 0,
    contacts: u32 = 0,
    max_contacts: u32 = 0,
    quadrants: u32 = 0,
    explicit_releases: u32 = 0,
    inferred_releases: u32 = 0,
    updates: u32 = 0,
    errors: u32 = 0,
    vbus_off: u32 = 0,
    frames: u32 = 0,
};

/// Keeps the experiment interactive after publishing one qualification report.
/// The first report is emitted after four quadrants/release, or after 60 s.
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
    const device = card.Touch.Device.identify(&bus, selected) catch {
        report.errors = 3;
        log.finish(&report);
        return;
    };
    report.width = device.width;
    report.height = device.height;
    report.slots = device.slots;
    if (!nih_display_touch_feedback(card.TouchFeedback.background)) {
        report.errors = 4;
        log.finish(&report);
        return;
    }
    report.updates = 1;
    log.start(&report);
    var feedback = card.TouchFeedback.State{};
    const started = clock.counter() orelse {
        report.errors = 5;
        log.finish(&report);
        return;
    };
    var published = false;
    while (true) {
        const sample = device.sample(&bus) catch {
            report.errors = 6;
            log.finish(&report);
            return;
        };
        report.samples +|= 1;
        if (feedback.observe(sample, selected != .ili9881c)) |observed| {
            if (!nih_display_touch_feedback(observed.color)) {
                report.errors = 7;
                log.finish(&report);
                return;
            }
            report.updates +|= 1;
            const event = Event{ .contacts = observed.point.contacts, .x = observed.point.x, .y = observed.point.y, .color = observed.color, .inferred_release = @intFromBool(observed.inferred_release) };
            log.event(&event);
        }
        report.contacts = feedback.contact_samples;
        report.max_contacts = feedback.max_contacts;
        report.quadrants = feedback.quadrants;
        report.explicit_releases = feedback.explicit_releases;
        report.inferred_releases = feedback.inferred_releases;
        const snapshot = display.snapshot();
        report.frames = snapshot.frames;
        log.refresh(&snapshot);
        const now = clock.counter() orelse {
            report.errors = 8;
            log.finish(&report);
            return;
        };
        if (!published and report.frames >= 32 and ((feedback.quadrants == 15 and feedback.point.contacts == 0) or now - started >= 60_000_000)) {
            report.status = 1;
            log.finish(&report);
            published = true;
        }
        if (!bus.pins.delay(20_000)) {
            report.errors = 9;
            log.finish(&report);
            return;
        }
    }
}
