//! Test-only handoff of a journal-recovered Rust Wasm to the host runtime.
const std = @import("std");
const adapter = @import("process_adapter");
const boot = @import("app_boot");
const package = @import("app_package");
const roots_module = @import("trust_snapshot_ed25519");

pub const boot_process_max_package = 4096;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 7) return error.ExpectedTrustCounterPackageRootOutputSequence;
    const expected_sequence = try std.fmt.parseInt(u64, args[6], 10);
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    const trust_file = try cwd.openFile(io, args[1], .{ .mode = .read_write });
    defer trust_file.close(io);
    const counter_file = try cwd.openFile(io, args[2], .{ .mode = .read_write });
    defer counter_file.close(io);
    const package_file = try cwd.openFile(io, args[3], .{ .mode = .read_write });
    defer package_file.close(io);
    const root_file = try cwd.openFile(io, args[4], .{});
    defer root_file.close(io);
    var root: [33]u8 = undefined;
    if (try root_file.readPositionalAll(io, &root, 0) != 32) return error.InvalidRootLength;
    var root_records = [_]roots_module.RootRecord{.{
        .root_key_id = "root-test-key-01".*,
        .public_key = root[0..32].*,
        .status = .trusted,
        .role = .normal,
    }};
    var roots = roots_module.RootStore{ .roots = &root_records, .limits = .{
        .max_snapshot_bytes = 512,
        .max_signature_bytes = 64,
        .max_keys = 8,
        .max_rollback = 8,
    } };
    var trust = adapter.FileAdapter{ .file = trust_file, .io = io, .bytes = 1216 };
    var counter = adapter.FileCounter{ .file = counter_file, .io = io };
    var packages = adapter.FileAdapter{ .file = package_file, .io = io, .bytes = 8480 };
    var work = adapter.Work{};
    var coordinator = boot.Coordinator{};
    const ready = switch (try coordinator.recover(
        adapter.bootInputs(&trust, &counter, &roots, &packages),
        work.workspace(),
    )) {
        .ready => |value| value,
        else => return error.ExpectedReady,
    };
    if (ready.installed.sequence != expected_sequence) return error.UnexpectedSequence;
    const envelope = try package.parse(ready.package_bytes, .{
        .max_package_bytes = boot_process_max_package,
        .max_signature_bytes = 64,
    });
    // No output path is opened until trust, journal integrity and application
    // policy all accept. The runner owns this temporary handoff file.
    try cwd.writeFile(io, .{ .sub_path = args[5], .data = envelope.wasm });
    std.debug.print("NIHOS_BOOT_EXPORT trust_epoch={d} sequence={d} package_bytes={d} wasm_bytes={d} pid={d}\n", .{
        ready.trust_epoch, ready.installed.sequence, ready.package_bytes.len, envelope.wasm.len, std.c.getpid(),
    });
}
