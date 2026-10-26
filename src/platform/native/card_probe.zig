//! PIN-free integration check after CPU0/CPU1 qualification has quiesced.
const card = @import("card");
const usb = @import("usb_probe.zig");
const i2c = @import("boot_i2c");
const timer = @import("timer_group");
const Pins = @import("display_probe.zig").Pins;
var service = card.Service{};
pub const Report = struct {
    status: u32 = 2,
    stage: u32 = 0,
    usb: u32 = 0,
    card: u32 = 0,
    remaining: u32 = 255,
    card_fault: u32 = 0,
    poweroff: u32 = 0,
    dma_erased: u32 = 0,
    pin_data_sent: u32 = 0,
    touch: u32 = 0,
    width: u32 = 0,
    height: u32 = 0,
    slots: u32 = 0,
    samples: u32 = 0,
    fresh: u32 = 0,
    releases: u32 = 0,
    contacts: u32 = 0,
    max_contacts: u32 = 0,
    last_type: u32 = 0,
    last_flags: u32 = 0,
    last_error: u32 = 0,
    last_parameter: u32 = 0,
    last_bytes: u32 = 0,
};

pub fn run(clock: timer.Timer, panel: u32) Report {
    var report = Report{};
    clock.start();
    clock.disarm();
    defer clock.stop();
    report.stage = 1;
    checkCard(clock, &report);
    report.stage = 2;
    checkTouch(clock, panel, &report);
    report.stage = 3;
    if (report.card == 1 and report.touch == 1 and report.poweroff == 1 and report.dma_erased == 1) report.status = 1;
    return report;
}
fn checkCard(clock: timer.Timer, report: *Report) void {
    var enumeration = usb.Report{};
    var device = usb.Device.open(clock, &enumeration) catch return;
    report.usb = 1;
    defer {
        report.last_type = device.last_header[0];
        report.last_flags = device.last_header[7];
        report.last_error = device.last_header[8];
        report.last_parameter = device.last_header[9];
        report.last_bytes = device.last_header[1];
        if (device.close()) |_| {
            report.dma_erased = 1;
        } else |_| {
            report.card = 0;
        }
    }
    var owner = card.Owner{ .sequence = 3 }; // enumeration consumed 0,1,2
    service.start() catch return;
    defer {
        service.disconnected();
        service.dismiss() catch {
            report.card = 0;
        };
    }
    // PowerOn, AP select, PIN EF select, empty VERIFY, PowerOff. No submit().
    for (0..6) |_| {
        if (!device.connected()) return;
        _ = owner.step(&service, &device) catch return;
        if (service.remaining) |remaining| report.remaining = remaining;
        if (service.prompt() != null) service.cancel();
        if (service.state == .done) {
            report.card_fault = @backingInt(service.fault);
            if (service.cleanup_failed) return;
            report.poweroff = 1;
            if (service.fault == .cancelled or service.fault == .last_attempt or service.fault == .blocked) report.card = 1;
            return;
        }
    }
}
fn checkTouch(clock: timer.Timer, panel: u32, report: *Report) void {
    const selected: card.Touch.Panel = switch (panel) {
        1 => .ili9881c,
        2 => .st7123,
        3 => .st7121,
        else => return,
    };
    const pins = Pins{ .clock = clock };
    var bus = i2c.Master(Pins){ .pins = pins };
    const device = card.Touch.Device.identify(&bus, selected) catch return;
    report.width = device.width;
    report.height = device.height;
    report.slots = device.slots;
    for (0..64) |_| {
        const sample = device.sample(&bus) catch return;
        report.samples += 1;
        switch (sample) {
            .unchanged => {},
            .fresh => |point| {
                report.fresh += 1;
                if (point.contacts == 0) report.releases += 1 else report.contacts += 1;
                report.max_contacts = @max(report.max_contacts, point.contacts);
            },
        }
        if (!pins.delay(50_000)) return;
    }
    report.touch = 1;
}
