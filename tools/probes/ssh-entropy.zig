//! RV32 code generation only: fixed bytes are not a qualified entropy source.
const ssh_entropy = @import("ssh_entropy");
const CompileOnlySource = struct {
    seed: *const [ssh_entropy.seed_bytes]u8,
    pub fn qualified(_: *@This()) bool {
        return true;
    }
    pub fn fillSeed(self: *@This(), out: *[ssh_entropy.seed_bytes]u8) !void {
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
