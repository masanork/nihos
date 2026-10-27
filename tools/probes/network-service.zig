//! Codegen-only normal-boot network owner. Never execute on a live device.
const network = @import("network_service");
const timers = @import("timer_group");

export fn nih_network_owner_compile_probe(backing: *align(64) [network.storage_bytes]u8) u32 {
    network.begin(timers.Timer.fromGroup(0x500c3000, 0).?, .saved, backing);
    network.poll();
    network.configure(.disabled) catch return 0;
    network.scanBluetooth() catch return network.bluetoothSnapshot().phase;
    return network.snapshot().phase;
}
