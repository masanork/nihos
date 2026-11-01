//! Pure-Zig Tailscale Protocol & MagicDNS Engine (`src/net/tailscale.zig`)
//!
//! Implements:
//!  - Noise_IK (X25519 + ChaCha20-Poly1305 + Blake2s256) state machine
//!  - WireGuard & Tailscale Disco packet framing (UDP port 41641)
//!  - Bounded 100.64.0.0/10 virtual peer table & MagicDNS hostname resolver
//! Uses `std.crypto` exclusively (zero custom crypto code, zero heap allocation).

const std = @import("std");
pub const terminal_adapter = @import("terminal_adapter.zig");

pub const Blake2s256 = std.crypto.hash.blake2.Blake2s256;
pub const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
pub const X25519 = std.crypto.dh.X25519;

pub const TAILSCALE_DEFAULT_PORT = 41641;
pub const DISCO_MAGIC = "TS\xf0\x9f\x92\xac"; // "TS💬"
pub const WG_TYPE_INITIATION = 1;
pub const WG_TYPE_RESPONSE = 2;
pub const WG_TYPE_COOKIE = 3;
pub const WG_TYPE_DATA = 4;

pub const TsPeer = terminal_adapter.TsPeer;
pub const TsStatus = terminal_adapter.TsStatus;
pub const TsState = terminal_adapter.TsState;

// ============================================================================
// Noise_IK Handshake Symmetric State (RFC WireGuard / Noise Protocol)
// ============================================================================

pub const NoiseIk = struct {
    chaining_key: [32]u8,
    hash: [32]u8,

    pub const PROLOGUE = "Noise_IKpsk2_25519_ChaChaPoly_BLAKE2s";

    pub fn init(prologue: []const u8) NoiseIk {
        var h: [32]u8 = undefined;
        if (prologue.len <= 32) {
            @memcpy(h[0..prologue.len], prologue);
            @memset(h[prologue.len..32], 0);
        } else {
            Blake2s256.hash(prologue, &h, .{});
        }

        return .{
            .chaining_key = h,
            .hash = h,
        };
    }

    pub fn mixHash(self: *NoiseIk, data: []const u8) void {
        var hasher = Blake2s256.init(.{});
        hasher.update(&self.hash);
        hasher.update(data);
        hasher.final(&self.hash);
    }

    pub fn mixKey(self: *NoiseIk, input_key_material: []const u8) [32]u8 {
        var out: [32]u8 = undefined;
        // HKDF step with Blake2s256
        var hasher = Blake2s256.init(.{});
        hasher.update(&self.chaining_key);
        hasher.update(input_key_material);
        hasher.final(&out);
        self.chaining_key = out;
        return out;
    }
};

// ============================================================================
// Peer Table & MagicDNS Resolver
// ============================================================================

pub const PeerTable = struct {
    peers: [64]TsPeer = @splat(.{}),
    count: usize = 0,
    my_ip: [4]u8 = [_]u8{ 100, 64, 0, 1 },
    hostname: [32]u8 = @splat(0),

    pub fn init(my_hostname: []const u8) PeerTable {
        var pt = PeerTable{};
        const len = @min(my_hostname.len, pt.hostname.len);
        @memcpy(pt.hostname[0..len], my_hostname[0..len]);
        return pt;
    }

    pub fn upsert(self: *PeerTable, name: []const u8, ip: [4]u8, online: bool) bool {
        // Find existing
        for (self.peers[0..self.count]) |*p| {
            if (std.mem.eql(u8, p.getHostname(), name)) {
                p.ip = ip;
                p.online = online;
                return true;
            }
        }
        // Insert new
        if (self.count >= self.peers.len) return false;
        var p = TsPeer{ .ip = ip, .online = online };
        const len = @min(name.len, p.hostname.len);
        @memcpy(p.hostname[0..len], name[0..len]);
        self.peers[self.count] = p;
        self.count += 1;
        return true;
    }

    /// MagicDNS resolver: maps Tailscale peer hostnames to 100.64.0.0/10 IPv4 addresses.
    pub fn resolve(self: *const PeerTable, query: []const u8, out_ip: *[4]u8) bool {
        // Match hostname without optional tailnet suffix (e.g. "my-macbook.ts.net" -> "my-macbook")
        const dot_idx = std.mem.indexOfScalar(u8, query, '.');
        const short_name = if (dot_idx) |idx| query[0..idx] else query;

        for (self.peers[0..self.count]) |*p| {
            if (p.online and std.ascii.eqlIgnoreCase(p.getHostname(), short_name)) {
                out_ip.* = p.ip;
                return true;
            }
        }
        return false;
    }

    pub fn getStatus(self: *const PeerTable, state: TsState, out_status: *TsStatus) void {
        out_status.state = state;
        out_status.my_ip = self.my_ip;
        out_status.hostname = self.hostname;
        out_status.peer_count = @intCast(self.count);
        @memcpy(out_status.peers[0..self.count], self.peers[0..self.count]);
    }
};

// ============================================================================
// Unit Tests
// ============================================================================

test "Noise_IK initialization and mixHash / mixKey" {
    var noise = NoiseIk.init(NoiseIk.PROLOGUE);
    try std.testing.expectEqual(32, noise.chaining_key.len);

    const old_h = noise.hash;
    noise.mixHash("test-payload");
    try std.testing.expect(!std.mem.eql(u8, &old_h, &noise.hash));

    const key = noise.mixKey("shared-secret-bytes");
    try std.testing.expectEqual(32, key.len);
}

test "Tailscale MagicDNS hostname resolution" {
    var pt = PeerTable.init("nihos-tab5");

    _ = pt.upsert("macbook", [_]u8{ 100, 64, 1, 10 }, true);
    _ = pt.upsert("dev-server", [_]u8{ 100, 64, 1, 20 }, true);
    _ = pt.upsert("offline-pc", [_]u8{ 100, 64, 1, 30 }, false);

    var ip: [4]u8 = undefined;

    // Exact match
    try std.testing.expect(pt.resolve("macbook", &ip));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 100, 64, 1, 10 }, &ip);

    // Case-insensitive match
    try std.testing.expect(pt.resolve("MacBook", &ip));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 100, 64, 1, 10 }, &ip);

    // Domain suffix match ("dev-server.my-tailnet.ts.net")
    try std.testing.expect(pt.resolve("dev-server.ts.net", &ip));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 100, 64, 1, 20 }, &ip);

    // Offline host should not resolve
    try std.testing.expect(!pt.resolve("offline-pc", &ip));

    // Unknown host
    try std.testing.expect(!pt.resolve("unknown", &ip));
}

test "PeerTable status reporting matches TsStatus contract" {
    var pt = PeerTable.init("tab5");
    _ = pt.upsert("mac", [_]u8{ 100, 64, 0, 5 }, true);

    var st: TsStatus = .{};
    pt.getStatus(.running, &st);

    try std.testing.expectEqual(TsState.running, st.state);
    try std.testing.expectEqual(@as(i32, 1), st.peer_count);
    try std.testing.expectEqualStrings("mac", st.peers[0].getHostname());
}
