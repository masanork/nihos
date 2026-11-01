//! Compile-only entry that forces the full boot-admission closure for RV32.
//! This is not a public ABI and is never linked into the normal image.
const app_boot = @import("app_boot");

export fn nih_boot_admission_compile_probe(
    coordinator: *app_boot.Coordinator,
    inputs: *const app_boot.Inputs,
    workspace: *const app_boot.Workspace,
) callconv(.c) u32 {
    const result = coordinator.recover(inputs.*, workspace.*) catch return 0x8000_0000;
    return switch (result) {
        .unprovisioned => 1,
        .no_package => 2,
        .recovery_maintenance => 3,
        .ready => 4,
    };
}
