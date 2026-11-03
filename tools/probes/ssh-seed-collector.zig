//! Code generation only; these fixed bytes are not an entropy source.
const collector = @import("ssh_seed_collector");
const Backend = struct {
    pub fn begin(_: *@This()) !void {}
    pub fn owned(_: *@This()) bool {
        return true;
    }
    pub fn sample(_: *@This()) !?u8 {
        return 0;
    }
    pub fn release(_: *@This()) bool {
        return true;
    }
};
export fn nih_ssh_seed_collector_compile_probe() bool {
    var backend: Backend = .{};
    var generations: collector.Generations = .{};
    var source = collector.Collector(Backend).init(&backend, &generations);
    source.begin(0, 100) catch return false;
    for (0..32) |_| source.poll(1);
    const generation = source.lease() orelse return false;
    var seed: [32]u8 = undefined;
    source.fillSeed(generation, &seed) catch return false;
    source.cancel();
    source.poll(2);
    return true;
}
