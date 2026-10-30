//! Test-only deterministic packager. The RFC seed is public test material.
const std = @import("std");
const package = @import("app_package");
const ed25519 = @import("package_ed25519");
const policy = @import("app_policy");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 3 and args.len != 4) return error.ExpectedInputOutputAndOptionalSequence;
    const sequence = if (args.len == 4)
        try std.fmt.parseInt(u64, args[3], 10)
    else
        1;
    const version = std.math.cast(u32, sequence) orelse return error.SequenceTooLarge;
    const wasm = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        args[1],
        init.gpa,
        .limited(4096),
    );
    defer init.gpa.free(wasm);
    const output = try init.gpa.alloc(u8, package.header_bytes + wasm.len + 64);
    defer init.gpa.free(output);

    var seed: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(
        &seed,
        "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60",
    );
    const key_pair = try std.crypto.sign.Ed25519.KeyPair.generateDeterministic(seed);
    const prepared = try package.prepare(output, .{
        .algorithm = ed25519.algorithm_id,
        .signature_bytes = 64,
        .sequence = sequence,
        .schema = policy.current_schema,
        .sdk_abi = policy.current_sdk_abi,
        .module_id = "nihos-rust-wasm1".*,
        .publisher_id = "nihos.dev/system".*,
        .version = version,
        .services = policy.Service.graphics,
        .max_linear_pages = 1,
        .instruction_budget = 10_000,
        .key_id = "rfc8032-vector01".*,
        .wasm = wasm,
    });
    const signature = try key_pair.sign(prepared.signed_bytes, null);
    @memcpy(prepared.signature, &signature.toBytes());
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = args[2],
        .data = prepared.package,
    });
}
