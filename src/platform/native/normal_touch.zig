//! CPU0 foreground adapter. Borrows board I2C and the running UI timer;
//! never resets either controller/power policy, owns no IRQ or DMA memory.
const Touch = @import("card").Touch;
const pointer = @import("pointer_input");
pub const Status = extern struct { status: u32 = 0, panel: u32 = 0, width: u32 = 0, height: u32 = 0, slots: u32 = 0, polls: u32 = 0, fresh: u32 = 0, errors: u32 = 0, error_code: u32 = 0, max_poll_us: u32 = 0 };
pub const Events = extern struct { down: u32 = 0, move: u32 = 0, up: u32 = 0, cancel: u32 = 0, multi: u32 = 0, overflow: u32 = 0, quadrants: u32 = 0, queued: u32 = 0 };
var report: Status = .{};
var counts: Events = .{};
var device: ?Touch.Device = null;
var stream: pointer.Stream = .{};
var queue: pointer.Queue = .{};
var next: u64 = 0;
var selected: ?Touch.Panel = null;
pub fn begin(panel: u32) void {
    report = .{ .panel = panel };
    counts = .{};
    device = null;
    stream = .{};
    queue = .{};
    next = 1_000_000;
    selected = switch (panel) {
        1 => .ili9881c,
        2 => .st7123,
        3 => .st7121,
        else => null,
    };
}
pub fn ready() bool {
    return report.status == 1;
}
pub fn pop() ?pointer.Event {
    return queue.pop();
}
fn enqueue(event: pointer.Event) void {
    switch (event.kind) {
        .down => counts.down +|= 1,
        .move => counts.move +|= 1,
        .up => counts.up +|= 1,
        .cancel => counts.cancel +|= 1,
    }
    if (!queue.push(event)) {
        _ = stream.cancel(.overflow, event.at);
        counts.cancel +|= 1;
    }
}
fn failed(code: u32, now: u64) void {
    report.status = 2;
    report.errors +|= 1;
    report.error_code = code;
    enqueue(stream.cancel(.hardware, now));
}
pub fn poll(bus: anytype, clock: anytype, now: u64) void {
    if (report.status == 2 or now < next) return;
    next = now +| 33_333;
    const started = clock.counter() orelse {
        failed(1, now);
        return;
    };
    defer {
        const ended = clock.counter() orelse started;
        report.max_poll_us = @max(report.max_poll_us, @as(u32, @intCast(@min(ended -| started, 0xffff_ffff))));
    }
    if (device == null) {
        const panel = selected orelse {
            failed(2, now);
            return;
        };
        device = Touch.Device.identify(bus, panel) catch {
            failed(3, now);
            return;
        };
        report.width = device.?.width;
        report.height = device.?.height;
        report.slots = device.?.slots;
        report.status = 1;
        return;
    }
    const sample = device.?.sampleBatched(bus) catch {
        failed(4, now);
        return;
    };
    report.polls +|= 1;
    switch (sample) {
        .unchanged => {},
        .fresh => |point| {
            report.fresh +|= 1;
            if (point.contacts > 1) counts.multi +|= 1;
            if (point.contacts == 1) {
                const logical = pointer.landscape(point.x, point.y).?;
                const quadrant: u2 = @as(u2, @intFromBool(logical.x >= 640)) | (@as(u2, @intFromBool(logical.y >= 360)) << 1);
                counts.quadrants |= @as(u32, 1) << quadrant;
            }
            if (stream.fresh(point.contacts, point.x, point.y, now)) |event| enqueue(event);
        },
    }
    if (stream.tick(now)) |event| enqueue(event);
}
pub fn snapshot() Status {
    return report;
}
pub fn eventSnapshot() Events {
    counts.overflow = queue.overflows;
    counts.queued = @intCast(queue.length);
    return counts;
}
