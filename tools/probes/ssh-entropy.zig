//! RV32 code generation only: fixed bytes are not a qualified entropy source.
const ssh_entropy = @import("ssh_entropy");
const CompileOnlySource = struct {
    seed: *const [ssh_entropy.seed_bytes]u8,
    pub fn lease(_: *@This()) ?u64 {
        return 1;
    }
    pub fn fillSeed(self: *@This(), generation: u64, out: *[ssh_entropy.seed_bytes]u8) !void {
        if (generation != 1) return error.EntropyUnavailable;
        out.* = self.seed.*;
    }
};
export fn nih_ssh_entropy_compile_probe(entropy: *ssh_entropy.Entropy, seed: *const [ssh_entropy.seed_bytes]u8, out: *[32]u8) bool {
    var source: CompileOnlySource = .{ .seed = seed };
    entropy.seedFrom(&source) catch return false;
    defer entropy.clear();
    entropy.fill(out) catch return false;
    return true;
}
