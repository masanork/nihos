//! Compile-only RV32 probe, not a firmware entry point or device test.
const control = @import("at_controller");
const at = control.wire;
var decoder: at.Decoder = .{};
var gate: at.CommandGate = .{};
var owner: control.Controller = .{};

export fn nih_at_probe_push(byte: u8) u32 {
    const result = decoder.push(byte) catch return 0xffffffff;
    if (result) |item| return switch (item) {
        .line => |line| @intCast(line.len),
        .prompt => 1,
        .available => |available| available.count,
        .data => |data| @intCast(data.bytes.len),
    };
    return 0;
}

export fn nih_at_probe_arm(link: u8, limit: u32) bool {
    decoder.expectSocketRead(link, limit) catch return false;
    return true;
}

export fn nih_at_probe_prompt() bool {
    decoder.expectPrompt() catch return false;
    return true;
}

export fn nih_at_probe_finish() bool {
    decoder.endCommand() catch return false;
    return true;
}

export fn nih_at_probe_epoch(now: u64, deadline: u64) bool {
    gate.invalidate();
    decoder.abort();
    gate.establish() catch return false;
    const token = gate.begin(now, deadline) catch return false;
    gate.complete(token, now) catch return false;
    _ = gate.expire(deadline);
    return true;
}

export fn nih_at_probe_controller(action: u32, byte: u8, now: u64, until: u64) u32 {
    switch (action) {
        0 => owner.recover(now, until) catch return 0xffffffff,
        1 => return @intCast((owner.tx(now) catch return 0xffffffff).len),
        2 => owner.consumeTx(byte, now) catch return 0xffffffff,
        3 => {
            if (owner.push(byte, now) catch return 0xffffffff) |notice| return switch (notice) {
                .line => |line| @intCast(line.len),
                .available => |available| available.count,
                .data => |data| @intCast(data.bytes.len),
                .profile_ready => 1,
            };
        },
        4 => {
            _ = owner.submit(.version, now, until) catch return 0xffffffff;
        },
        5 => {
            _ = owner.submit(.{ .socket_read = .{ .link = 0, .limit = 1024 } }, now, until) catch return 0xffffffff;
        },
        6 => {
            _ = owner.submit(.{ .socket_send = .{ .link = 0, .bytes = "abc" } }, now, until) catch return 0xffffffff;
        },
        7 => {
            _ = owner.submit(.{ .ble_write = .{ .link = 0, .service = 3, .characteristic = 6, .bytes = "a" } }, now, until) catch return 0xffffffff;
        },
        8 => owner.cancel(),
        9 => owner.transportFailed(),
        10 => if (owner.takeCompletion()) |completion| {
            return @intCast(completion.bytes.len);
        },
        else => return @intFromBool(owner.ready()),
    }
    return 0;
}
