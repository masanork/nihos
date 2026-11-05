const std = @import("std");
const hybrid = @import("ssh_hybrid_transcript.zig");
const K = std.crypto.kem.ml_kem.MLKem768;
const X = std.crypto.dh.X25519;
const Vector = @import("ssh_hybrid_vector.zig").Vector;
const client_banner = @import("ssh_hybrid_vector.zig").client_banner;
const server_banner = @import("ssh_hybrid_vector.zig").server_banner;
const client_kex = @import("ssh_hybrid_vector.zig").client_kex;
const server_kex = @import("ssh_hybrid_vector.zig").server_kex;
pub fn generate() !Vector {
    var v: Vector = undefined;
    v.seed = @splat(0x37);
    v.xsecret = @splat(0x24);
    const server_secret: [32]u8 = @splat(0x45);
    const coins: [32]u8 = @splat(0x48);
    const pair = try K.KeyPair.generateDeterministic(v.seed);
    v.pk = pair.public_key.toBytes();
    const encaps = pair.public_key.encapsDeterministic(&coins);
    v.server[0..1088].* = encaps.ciphertext;
    v.server[1088..].* = X.recoverPublicKey(server_secret);
    const classic = try X.scalarmult(v.xsecret, v.server[1088..][0..32].*);
    v.combined = try hybrid.combine(encaps.shared_secret, classic);
    var client: [1216]u8 = undefined;
    client[0..1184].* = v.pk;
    client[1184..].* = X.recoverPublicKey(v.xsecret);
    const host_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(@splat(0x69));
    std.mem.writeInt(u32, v.host[0..4], 11, .big);
    @memcpy(v.host[4..15], "ssh-ed25519");
    std.mem.writeInt(u32, v.host[15..19], 32, .big);
    v.host[19..].* = host_pair.public_key.toBytes();
    std.crypto.hash.sha2.Sha256.hash(&v.host, &v.pin, .{});
    v.hash = try hybrid.exchangeHash(client_banner, server_banner, client_kex, server_kex, &v.host, &client, &v.server, v.combined);
    const sig = try host_pair.sign(&v.hash, null);
    std.mem.writeInt(u32, v.signature[0..4], 11, .big);
    @memcpy(v.signature[4..15], "ssh-ed25519");
    std.mem.writeInt(u32, v.signature[15..19], 64, .big);
    v.signature[19..].* = sig.toBytes();
    return v;
}
export fn nih_make_public_ssh_vector(out: *Vector) bool {
    out.* = generate() catch return false;
    return true;
}
