//! Host-only ML-KEM backend for the shared hybrid SSH handshake experiment.
const std = @import("std");
const kex = @import("ssh_kex.zig");
const reply = @import("ssh_hybrid_reply.zig");
const handshake = @import("ssh_hybrid_handshake.zig");
const Kem = std.crypto.kem.ml_kem.MLKem768;
const native = @import("pqc_config").native;
const Job = extern struct { secret_key: [2400]u8, epoch: u32, phase: c_int, arena_peak: usize };
extern fn nih_host_mlkem_keypair(*[1184]u8, *Job, *const [64]u8) c_int;
extern fn nih_host_mlkem_decaps(*[32]u8, *const [1088]u8, *Job) c_int;
pub const Probe = struct {
    keypair: if (native) Job else Kem.KeyPair,
    protocol: handshake.Handshake,
    pub fn init(seed: [64]u8, secret: [32]u8, pin: [32]u8, banner: []const u8) !Probe {
        var keypair: if (native) Job else Kem.KeyPair = if (native) std.mem.zeroes(Job) else try Kem.KeyPair.generateDeterministic(seed);
        defer std.crypto.secureZero(u8, std.mem.asBytes(&keypair));
        var public: [1184]u8 = undefined;
        if (native) {
            if (nih_host_mlkem_keypair(&public, &keypair, &seed) != 1) return error.Malformed;
        } else {
            public = keypair.public_key.toBytes();
        }
        return .{ .keypair = keypair, .protocol = try handshake.Handshake.init(secret, pin, banner, &public) };
    }
    pub fn start(self: *Probe, cookie: [16]u8, out: []u8) ![]const u8 {
        return self.protocol.start(cookie, out);
    }
    pub fn serverInit(self: *Probe, input: []const u8, out: []u8) ![]const u8 {
        return self.protocol.serverInit(input, out);
    }
    pub fn decaps(self: *Probe, ciphertext: *const [1088]u8) ![32]u8 {
        var pq: [32]u8 = undefined;
        if (native) {
            if (nih_host_mlkem_decaps(&pq, ciphertext, &self.keypair) != 1) return error.Malformed;
        } else {
            pq = try self.keypair.secret_key.decaps(ciphertext);
        }
        return pq;
    }
    pub fn finish(self: *Probe, input: []const u8) !kex.Keys {
        const parsed = try reply.parse(input);
        var pq = try self.decaps(parsed.ciphertext());
        defer std.crypto.secureZero(u8, &pq);
        return self.finishWithPq(input, &pq);
    }
    pub fn finishWithPq(self: *Probe, input: []const u8, pq: *const [32]u8) !kex.Keys {
        return self.protocol.finishWithPq(input, pq);
    }
    pub fn deinit(self: *Probe) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }
};
