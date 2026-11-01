//! Compile-only freestanding probe, no device or flash operations.
const exchange = @import("hosted_c6_time_exchange.zig");
const wire = @import("hosted.zig");
var client: exchange.Exchange = .{};
var decoder: wire.Decoder = .{};
export fn nih_c6_time_probe_begin(generation: u64, now: u64, deadline: u64) bool {
    client.begin(.saved, generation, now, deadline) catch return false;
    decoder.reset();
    return true;
}
export fn nih_c6_time_probe_tx(now: u64) usize {
    const bytes = client.tx(now) catch return 0;
    return bytes.len;
}
export fn nih_c6_time_probe_sent(count: usize, now: u64) bool {
    client.sent(count, now) catch return false;
    return true;
}
export fn nih_c6_time_probe_feed(byte: u8, now: u64) bool {
    if (decoder.push(byte) catch return false) |frame| {
        client.receive(frame, now) catch return false;
    }
    return true;
}
