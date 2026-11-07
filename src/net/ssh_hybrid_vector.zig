//! Public deterministic emulator test vector, never production key material.
pub const Vector = extern struct {
    seed: [64]u8,
    xsecret: [32]u8,
    pk: [1184]u8,
    server: [1120]u8,
    host: [51]u8,
    signature: [83]u8,
    pin: [32]u8,
    hash: [32]u8,
    combined: [32]u8,
};
pub const client_banner = "SSH-2.0-nihos_1.0";
pub const server_banner = "SSH-2.0-fixture";
pub const client_kex = "\x14client-kex";
pub const server_kex = "\x14server-kex";
