const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const view_config_module = b.createModule(.{ .root_source_file = b.path("src/xy/view_config.zig"), .target = target, .optimize = optimize });
    const module = b.addModule("nihos", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ccid_module = b.createModule(.{
        .root_source_file = b.path("src/usb/ccid.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("ccid", ccid_module);
    module.addImport("view_config", view_config_module);
    const surface_module = b.createModule(.{
        .root_source_file = b.path("src/graphics/surface.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("surface", surface_module);

    const module_tests = b.addTest(.{
        .root_module = module,
    });
    const run_module_tests = b.addRunArtifact(module_tests);
    const protected_fault = b.createModule(.{
        .root_source_file = b.path("src/protected_fault_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    protected_fault.addImport("scheduler", b.createModule(.{
        .root_source_file = b.path("src/kernel/scheduler.zig"),
        .target = target,
        .optimize = optimize,
    }));
    protected_fault.addImport("task_control", b.createModule(.{
        .root_source_file = b.path("src/kernel/task_control.zig"),
        .target = target,
        .optimize = optimize,
    }));

    const test_step = b.step("test", "Run host-side nihOS unit tests");
    const wasm_ui_tests = b.createModule(.{ .root_source_file = b.path("src/app/wasm_ui_controller.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = wasm_ui_tests })).step);
    const async_start_tests = b.createModule(.{ .root_source_file = b.path("src/app/async_start.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = async_start_tests })).step);
    const mailbox_tests = b.createModule(.{ .root_source_file = b.path("src/app/frame_mailbox.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mailbox_tests })).step);
    const leased_stack_tests = b.createModule(.{ .root_source_file = b.path("src/arch/riscv32/leased_stack.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = leased_stack_tests })).step);
    test_step.dependOn(appTests(b, target, optimize));
    test_step.dependOn(&run_module_tests.step);
    const hosted_ota_tests = b.createModule(.{ .root_source_file = b.path("src/net/hosted_ota_test.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hosted_ota_tests })).step);
    const hosted_ota_pump_tests = b.createModule(.{ .root_source_file = b.path("src/net/hosted_ota_pump_test.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hosted_ota_pump_tests })).step);
    const hosted_ota_session_tests = b.createModule(.{ .root_source_file = b.path("src/net/hosted_ota_session_test.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hosted_ota_session_tests })).step);
    const hosted_ota_arm_tests = b.createModule(.{ .root_source_file = b.path("src/net/hosted_ota_arm_test.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hosted_ota_arm_tests })).step);
    const hosted_ota_guard_tests = b.createModule(.{ .root_source_file = b.path("src/net/hosted_ota_guard_test.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hosted_ota_guard_tests })).step);
    const hosted_diagnostics_tests = b.createModule(.{ .root_source_file = b.path("src/net/hosted_diagnostics_test.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = hosted_diagnostics_tests })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = protected_fault })).step);
    // Ownership contracts only: no camera hardware or video driver is wired here.
    const camera_contract = b.createModule(.{ .root_source_file = b.path("src/device/camera_contract.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = camera_contract })).step);
    const camera_stream_model = b.createModule(.{ .root_source_file = b.path("src/device/camera_stream_model.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = camera_stream_model })).step);
    const camera_preview = b.createModule(.{ .root_source_file = b.path("src/board/tab5/camera_preview.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = camera_preview })).step);
    const tab5_camera = b.createModule(.{ .root_source_file = b.path("src/board/tab5/camera.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tab5_camera })).step);
    const csi_preflight = b.createModule(.{ .root_source_file = b.path("src/board/tab5/csi_preflight.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = csi_preflight })).step);
    const csi_stability = b.createModule(.{ .root_source_file = b.path("src/board/tab5/csi_stability.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = csi_stability })).step);
    const camera_sha = b.createModule(.{ .root_source_file = b.path("src/board/tab5/camera_sha256.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = camera_sha })).step);
    const csi_workspace = b.createModule(.{ .root_source_file = b.path("src/board/tab5/csi_workspace.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = csi_workspace })).step);
    inline for (.{ "csi_first_frame_test.zig", "csi_inflight_stop.zig", "csi_inflight_adapter.zig", "sc202cs_exposure.zig" }) |name| {
        const camera_stage = b.createModule(.{ .root_source_file = b.path("src/board/tab5/" ++ name), .target = target, .optimize = optimize });
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = camera_stage })).step);
    }
    const surface_tests = b.addTest(.{ .root_module = surface_module });
    test_step.dependOn(&b.addRunArtifact(surface_tests).step);
    const canvas_module = b.createModule(.{ .root_source_file = b.path("src/graphics/canvas.zig"), .target = target, .optimize = optimize });
    canvas_module.addImport("surface", surface_module);
    module.addImport("canvas", canvas_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = canvas_module })).step);
    const console_scroll_probe = b.createModule(.{ .root_source_file = b.path("src/graphics/console_canvas_scroll_test.zig"), .target = target, .optimize = optimize });
    console_scroll_probe.addImport("canvas", canvas_module);
    const console_probe_module = b.createModule(.{ .root_source_file = b.path("src/console.zig"), .target = target, .optimize = optimize });
    console_probe_module.addImport("view_config", view_config_module);
    console_probe_module.addImport("canvas", canvas_module);
    const camera_input = b.createModule(.{ .root_source_file = b.path("src/console/camera_input.zig"), .target = target, .optimize = optimize });
    camera_input.addImport("text_console", console_probe_module);
    camera_input.addImport("camera_preview", camera_preview);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = camera_input })).step);
    console_scroll_probe.addImport("console", console_probe_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = console_scroll_probe })).step);
    const editor_fixture = b.createModule(.{ .root_source_file = b.path("src/platform/native/editor_fixture.zig"), .target = target, .optimize = optimize });
    editor_fixture.addImport("text_console", console_probe_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = editor_fixture })).step);
    const editor_live = b.createModule(.{ .root_source_file = b.path("src/platform/native/editor_live.zig"), .target = target, .optimize = optimize });
    editor_live.addImport("text_console", console_probe_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = editor_live })).step);
    const pattern_module = b.createModule(.{ .root_source_file = b.path("src/platform/native/canvas_pattern.zig"), .target = target, .optimize = optimize });
    pattern_module.addImport("canvas", canvas_module);
    const pattern_tests = b.addTest(.{ .root_module = pattern_module });
    test_step.dependOn(&b.addRunArtifact(pattern_tests).step);
    const demo_pointer_module = b.createModule(.{ .root_source_file = b.path("src/input/pointer.zig"), .target = target, .optimize = optimize });
    const demo_app_module = b.createModule(.{ .root_source_file = b.path("src/platform/native/canvas_demo_app.zig"), .target = target, .optimize = optimize });
    demo_app_module.addImport("canvas", canvas_module);
    demo_app_module.addImport("pointer_input", demo_pointer_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = demo_app_module })).step);
    const workloads_module = b.createModule(.{ .root_source_file = b.path("src/platform/native/canvas_workloads.zig"), .target = target, .optimize = optimize });
    workloads_module.addImport("canvas", canvas_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = workloads_module })).step);
    const ccid_tests = b.addTest(.{ .root_module = ccid_module });
    test_step.dependOn(&b.addRunArtifact(ccid_tests).step);
    const ttf_module = b.createModule(.{ .root_source_file = b.path("src/graphics/ttf.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = ttf_module })).step);
    const viewport_layout_module = b.createModule(.{ .root_source_file = b.path("src/graphics/viewport_layout.zig"), .target = target, .optimize = optimize });
    viewport_layout_module.addImport("view_config", view_config_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = viewport_layout_module })).step);
    const rotated_surface_module = b.createModule(.{ .root_source_file = b.path("src/graphics/rotated_surface.zig"), .target = target, .optimize = optimize });
    rotated_surface_module.addImport("surface", surface_module);
    const terminal_adapter_module = b.createModule(.{ .root_source_file = b.path("src/net/terminal_adapter.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = terminal_adapter_module })).step);
    const xy_native_render_module = b.createModule(.{ .root_source_file = b.path("src/xy/native_render_entry.zig"), .target = target, .optimize = optimize });
    xy_native_render_module.addImport("view_config", view_config_module);
    xy_native_render_module.addImport("surface", surface_module);
    xy_native_render_module.addImport("viewport_layout", viewport_layout_module);
    xy_native_render_module.addImport("rotated_surface", rotated_surface_module);
    xy_native_render_module.addImport("terminal_adapter", terminal_adapter_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = xy_native_render_module })).step);
    const xy_reader_module = b.createModule(.{ .root_source_file = b.path("src/xy/reader.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = xy_reader_module })).step);
    const xy_catalog_module = b.createModule(.{ .root_source_file = b.path("src/xy/catalog.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = xy_catalog_module })).step);
    const xy_learning_catalog_module = b.createModule(.{ .root_source_file = b.path("src/xy/learning_catalog.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = xy_learning_catalog_module })).step);
    const xy_document_module = b.createModule(.{ .root_source_file = b.path("src/xy/document.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = xy_document_module })).step);
    const xy_ime_omni_module = b.createModule(.{ .root_source_file = b.path("src/xy/ime_omni.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = xy_ime_omni_module })).step);
    const vt100_module = b.createModule(.{ .root_source_file = b.path("src/net/vt100.zig"), .target = target, .optimize = optimize });
    vt100_module.addImport("terminal_adapter", terminal_adapter_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = vt100_module })).step);
    const ssh_module = b.createModule(.{ .root_source_file = b.path("src/net/ssh.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = ssh_module })).step);
    const tailscale_module = b.createModule(.{ .root_source_file = b.path("src/net/tailscale.zig"), .target = target, .optimize = optimize });
    tailscale_module.addImport("terminal_adapter", terminal_adapter_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = tailscale_module })).step);
    const xy_scheme_bridge_module = b.createModule(.{ .root_source_file = b.path("src/xy/scheme_bridge.zig"), .target = target, .optimize = optimize });
    xy_scheme_bridge_module.addImport("view_config", view_config_module);
    xy_scheme_bridge_module.addImport("viewport_layout", viewport_layout_module);
    xy_scheme_bridge_module.addImport("terminal_adapter", terminal_adapter_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = xy_scheme_bridge_module })).step);
    const code_font_module = b.createModule(.{ .root_source_file = b.path("src/graphics/code_font.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = code_font_module })).step);
    const pixel_transfer_module = b.createModule(.{ .root_source_file = b.path("src/graphics/pixel_transfer.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = pixel_transfer_module })).step);
    const xy_live_module = b.createModule(.{ .root_source_file = b.path("src/xy/live_workspace.zig"), .target = target, .optimize = optimize });
    xy_live_module.addImport("view_config", view_config_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = xy_live_module })).step);
    const xy_render_adapter_module = b.createModule(.{ .root_source_file = b.path("src/xy/render_adapter.zig"), .target = target, .optimize = optimize });
    xy_render_adapter_module.addImport("view_config", view_config_module);
    xy_render_adapter_module.addImport("surface", surface_module);
    xy_render_adapter_module.addImport("viewport_layout", viewport_layout_module);
    xy_render_adapter_module.addImport("terminal_adapter", terminal_adapter_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = xy_render_adapter_module })).step);
    const xy_terminal_buffer_module = b.createModule(.{ .root_source_file = b.path("src/xy/terminal_buffer.zig"), .target = target, .optimize = optimize });
    xy_terminal_buffer_module.addImport("viewport_layout", viewport_layout_module);
    xy_terminal_buffer_module.addImport("terminal_adapter", terminal_adapter_module);
    xy_terminal_buffer_module.addImport("vt100", vt100_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = xy_terminal_buffer_module })).step);
    const lp_core_module = b.createModule(.{ .root_source_file = b.path("src/soc/esp32p4/lp_core.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = lp_core_module })).step);
    const suspend_module = b.createModule(.{ .root_source_file = b.path("src/soc/esp32p4/suspend.zig"), .target = target, .optimize = optimize });
    suspend_module.addImport("lp_core", lp_core_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = suspend_module })).step);

    // Japanese Dictionary benchmark & tests
    const dict_module = b.createModule(.{ .root_source_file = b.path("src/xy/dict.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = dict_module })).step);

    const conv_module = b.createModule(.{ .root_source_file = b.path("src/xy/conv.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = conv_module })).step);

    const bench_dict_exe = b.addExecutable(.{
        .name = "benchmark_dict",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/benchmark_dict.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    bench_dict_exe.root_module.addImport("dict", dict_module);
    const run_bench_dict = b.addRunArtifact(bench_dict_exe);
    const bench_dict_step = b.step("bench-dict", "Run MeOS vs nihos Japanese dictionary benchmark");
    bench_dict_step.dependOn(&run_bench_dict.step);
}

fn appTestModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, path: []const u8, imports: []const std.Build.Module.Import) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path(path), .target = target, .optimize = optimize, .imports = imports });
}

fn appTests(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step {
    const step = b.step("test-app", "Run experimental app admission and journal host tests");
    const policy = appTestModule(b, target, optimize, "src/app/module_policy.zig", &.{});
    const package = appTestModule(b, target, optimize, "src/app/package.zig", &.{.{ .name = "app_policy", .module = policy }});
    const install = appTestModule(b, target, optimize, "src/app/package_install.zig", &.{ .{ .name = "app_package", .module = package }, .{ .name = "app_policy", .module = policy } });
    const store = appTestModule(b, target, optimize, "src/app/trust_snapshot_store.zig", &.{});
    const snapshot = appTestModule(b, target, optimize, "src/app/trust_snapshot.zig", &.{.{ .name = "app_package", .module = package }});
    const ed25519 = appTestModule(b, target, optimize, "src/app/package_ed25519.zig", &.{.{ .name = "app_package", .module = package }});
    const roots = appTestModule(b, target, optimize, "src/app/trust_snapshot_ed25519.zig", &.{ .{ .name = "app_package", .module = package }, .{ .name = "package_ed25519", .module = ed25519 }, .{ .name = "trust_snapshot", .module = snapshot }, .{ .name = "trust_snapshot_store", .module = store } });
    const imports: []const std.Build.Module.Import = &.{ .{ .name = "app_install", .module = install }, .{ .name = "app_package", .module = package }, .{ .name = "app_policy", .module = policy }, .{ .name = "package_ed25519", .module = ed25519 }, .{ .name = "trust_snapshot", .module = snapshot }, .{ .name = "trust_snapshot_ed25519", .module = roots }, .{ .name = "trust_snapshot_store", .module = store } };
    const boot = appTestModule(b, target, optimize, "src/app/boot_admission.zig", imports);
    const boot_test = appTestModule(b, target, optimize, "probes/wamr-native/boot-admission-test.zig", imports);
    boot_test.addImport("app_boot", boot);
    const file_test = appTestModule(b, target, optimize, "probes/wamr-native/file-storage-test.zig", imports);
    const chain_test = appTestModule(b, target, optimize, "probes/wamr-native/trust-snapshot-chain-test.zig", imports);
    for ([_]*std.Build.Module{ policy, package, install, store, snapshot, ed25519, roots, boot_test, file_test, chain_test }) |module| {
        step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    }
    return step;
}
