//! Register-level synthetic touch bus. No physical I2C, IRQ or timing model.
const touch = @import("board/tab5/touch.zig");
const pointer = @import("input/pointer.zig");
pub const service = pointer.TouchService(touch, pointer);
pub var selected: u32 = 0;
pub const View = extern struct {
    status: u32 = 0,
    polls: u32 = 0,
    fresh: u32 = 0,
    errors: u32 = 0,
    error_code: u32 = 0,
    transfers: u32 = 0,
    report_reads: u32 = 0,
    report_bytes: u32 = 0,
    max_read: u32 = 0,
    acknowledgments: u32 = 0,
    fault: u32 = 0,
};
var metrics: View = .{};
var bus: Bus = .{};
const Clock = struct {
    now: u64,
    pub fn counter(self: Clock) ?u64 {
        return self.now;
    }
};
const Bus = struct {
    slots: u8 = 10,
    flags: u8 = 0,
    records: [70]u8 = @splat(0),
    chunk: u32 = 0,
    pub fn transfer(self: *Bus, address: u8, write: []const u8, output: []u8) !void {
        metrics.transfers += 1;
        if (selected == 1 and address == 0x5d and write.len == 3 and output.len == 0) {
            if (write[0] != 0x4e or write[1] != 0x81 or write[2] != 0) return error.Register;
            if (metrics.fault == 4) return error.Nack;
            self.flags = 0;
            metrics.acknowledgments += 1;
            return;
        }
        if (write.len != 2 or output.len == 0 or output.len > 64) return error.Register;
        const reg = if (selected == 1) @as(u16, write[1]) << 8 | write[0] else @as(u16, write[0]) << 8 | write[1];
        if (selected == 1) {
            if (address != 0x5d) return error.Address;
            switch (reg) {
                0x8140 => {
                    if (output.len != 4) return error.Register;
                    @memcpy(output, "911\x00");
                },
                0x8048 => {
                    if (output.len != 4) return error.Register;
                    @memcpy(output, &[_]u8{ 0xd0, 2, 0, 5 });
                },
                0x814e => {
                    if (output.len != 1) return error.Register;
                    if (metrics.fault == 1) return error.Nack;
                    output[0] = self.flags;
                },
                0x814f => try self.readReport(0, output),
                else => return error.Register,
            }
        } else {
            if (address != 0x55) return error.Address;
            switch (reg) {
                0 => {
                    if (output.len != 1) return error.Register;
                    output[0] = if (selected == 3) 1 else 3;
                },
                5 => {
                    if (output.len != 5) return error.Register;
                    @memcpy(output, &[_]u8{ 2, 0xd0, 5, 0, self.slots });
                },
                0x10 => {
                    if (output.len != 1) return error.Register;
                    if (metrics.fault == 1) return error.Nack;
                    output[0] = if (metrics.fault == 6) 0x88 else self.flags;
                },
                else => {
                    if (reg < 0x14 or reg > 0x53 or (reg - 0x14) % 7 != 0 or output.len % 7 != 0) return error.Register;
                    try self.readReport(reg - 0x14, output);
                    // Fixture assumption: consume a complete Sitronix register
                    // snapshot. No claim about physical report/IRQ persistence.
                    if (reg - 0x14 + output.len == @as(usize, self.slots) * 7) self.flags = 0;
                },
            }
        }
    }
    fn readReport(self: *Bus, offset: usize, output: []u8) !void {
        if (offset + output.len > self.records.len) return error.Register;
        self.chunk += 1;
        metrics.report_reads += 1;
        metrics.max_read = @max(metrics.max_read, @as(u32, @intCast(output.len)));
        if ((metrics.fault == 2 and self.chunk == 1) or (metrics.fault == 3 and self.chunk == 2)) return error.Nack;
        @memcpy(output, self.records[offset..][0..output.len]);
        metrics.report_bytes += @intCast(output.len);
    }
};
pub fn reset(panel: u32, slots: u8) bool {
    if (panel > 3 or slots == 0 or slots > 10 or (panel == 1 and slots != 5)) return false;
    selected = panel;
    bus = .{ .slots = slots };
    metrics = .{};
    service.begin(panel);
    if (panel != 0) poll(1_000_000);
    return true;
}
pub fn poll(now: u64) void {
    service.poll(&bus, Clock{ .now = now }, now);
}
pub fn report(contacts: u8, x: u16, y: u16, sparse: bool) bool {
    if (selected == 0 or contacts > bus.slots or (selected == 1 and contacts > 5)) return false;
    bus.records = @splat(0);
    bus.chunk = 0;
    bus.flags = if (selected == 1) 0x80 | contacts else 8;
    for (0..contacts) |index| {
        const slot = if (sparse) bus.slots - contacts + index else index;
        const px: u16 = if (metrics.fault == 5) 720 else x;
        if (selected == 1) {
            const offset = index * 8;
            bus.records[offset] = @intCast(index);
            bus.records[offset + 1] = @truncate(px);
            bus.records[offset + 2] = @truncate(px >> 8);
            bus.records[offset + 3] = @truncate(y);
            bus.records[offset + 4] = @truncate(y >> 8);
        } else {
            const offset = slot * 7;
            bus.records[offset] = 0x80 | @as(u8, @truncate(px >> 8));
            bus.records[offset + 1] = @truncate(px);
            bus.records[offset + 2] = @truncate(y >> 8);
            bus.records[offset + 3] = @truncate(y);
        }
    }
    return true;
}
pub export fn normal_controller_fault(fault: u32) bool {
    if (fault > 6) return false;
    metrics.fault = fault;
    return true;
}
pub export fn normal_controller_view(out: *View) void {
    const status = service.snapshot();
    metrics.status = if (selected == 0) 0 else status.status;
    metrics.polls = status.polls;
    metrics.fresh = status.fresh;
    metrics.errors = status.errors;
    metrics.error_code = status.error_code;
    out.* = metrics;
}
