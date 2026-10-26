//! Compile-only RV32 probe, not a firmware entry point or device test.
const at = @import("esp_at");
var decoder: at.Decoder = .{};
var gate: at.CommandGate = .{};

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
