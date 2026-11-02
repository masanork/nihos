//! RV32 code-generation probe only. Never execute on a device.
//! Station and TCP share one module instance, as required by the native owner.
const hosted = @import("hosted_station");
const Owner = hosted.tcp_owner.Owner;
comptime {
    if (@sizeOf(Owner) > 24 * 1024) @compileError("experimental TCP owner exceeds 24 KiB probe budget");
}

export fn nih_tcp_owner_size() usize {
    return @sizeOf(Owner);
}
export fn nih_tcp_owner_open(owner: *Owner, client: *hosted.Client, now_us: u64) bool {
    _ = owner.open(client, .{ .address = .{ 10, 0, 2, 2 }, .port = 22 }, 50001, 123, now_us, now_us / 1000 +| 5000) catch return false;
    return true;
}
export fn nih_tcp_owner_receive(owner: *Owner, client: *hosted.Client, bytes: [*]const u8, len: usize, now_us: u64) bool {
    return owner.receive(client, .{ .interface = 1, .payload = bytes[0..len] }, now_us) catch false;
}
export fn nih_tcp_owner_next(owner: *Owner, client: *hosted.Client, now_us: u64) usize {
    const choice = owner.next(client, now_us, false) catch return 0;
    return switch (choice) {
        .idle => 0,
        .station => |bytes| bytes.len,
        .tcp => |bytes| bytes.len,
    };
}
export fn nih_tcp_owner_sent(owner: *Owner, client: *hosted.Client, len: usize, now_us: u64) bool {
    owner.sent(client, len, now_us) catch return false;
    return true;
}
export fn nih_tcp_owner_reset(owner: *Owner) bool {
    owner.reset() catch return false;
    return true;
}
