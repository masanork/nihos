//! Codegen-only normal-boot network owner. Never execute on a live device.
const network = @import("network_service");
const timers = @import("timer_group");

export fn nih_network_owner_compile_probe(backing: *align(64) [network.storage_bytes]u8, ssh: *network.ExperimentalSshSession) u32 {
    network.bindExperimentalSshStorage(ssh) catch |err| {
        if (err != error.TcpDisabled) return 0;
    };
    network.begin(timers.Timer.fromGroup(0x500c3000, 0).?, .saved, backing);
    network.poll();
    var tcp_result: u32 = 0;
    if (network.experimentalTcpOpen(.{ 10, 0, 2, 2 }, 22, 50001, 123, 5_000_000)) |handle| {
        var buffer: [8]u8 = @splat(0);
        _ = network.experimentalTcpReady(handle) catch false;
        _ = network.experimentalTcpWrite(handle, &buffer, 5_000_000) catch 0;
        _ = network.experimentalTcpRead(handle, &buffer) catch 0;
        if (network.experimentalSshAdapter(handle, 5000)) |value| {
            var adapter = value;
            adapter.advance(1_000_000) catch return 0;
            const socket = adapter.io();
            _ = socket.read(socket.context, &buffer) catch return 0;
            _ = socket.write(socket.context, &buffer) catch return 0;
        } else |err| tcp_result +|= @intFromError(err);
        if (network.experimentalSshSessionStart(ssh, handle, 5_000_000, 5000, @splat(1), @splat(2), @splat(3), 80, 24)) |_| {
            const now = network.experimentalSshSessionNow() catch return 0;
            const padding: [32]u8 = @splat(4); // Code generation only; never use as entropy.
            _ = ssh.poll(now, &padding, "probe", @splat(5)) catch return 0;
            _ = ssh.read(now, &padding, &buffer) catch return 0;
            _ = ssh.write(now, &padding, &buffer) catch return 0;
            ssh.abort();
        } else |_| {}
        if (network.experimentalSshReservedStart(handle, 5_000_000, 5000, @splat(1), @splat(2), @splat(3), 80, 24)) |reserved| {
            const now = network.experimentalSshSessionNow() catch return 0;
            const padding: [32]u8 = @splat(4); // Code generation only.
            _ = reserved.poll(now, &padding, "probe", @splat(5)) catch return 0;
            network.experimentalSshReservedRelease(reserved) catch return 0;
        } else |_| {}
        network.experimentalTcpCancel(handle) catch return 0;
        network.experimentalTcpCloseWrite(handle, 5_000_000) catch return 0;
        _ = network.experimentalTcpCloseComplete(handle) catch false;
    } else |err| tcp_result = @intFromError(err);
    network.configure(.disabled) catch return 0;
    network.scanBluetooth() catch return network.bluetoothSnapshot().phase;
    return network.snapshot().phase +| tcp_result;
}
