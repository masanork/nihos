const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    test_step.dependOn(&run_module_tests.step);
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
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = viewport_layout_module })).step);
    const xy_document_module = b.createModule(.{ .root_source_file = b.path("src/xy/document.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = xy_document_module })).step);
    const xy_ime_omni_module = b.createModule(.{ .root_source_file = b.path("src/xy/ime_omni.zig"), .target = target, .optimize = optimize });
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = xy_ime_omni_module })).step);
    const xy_scheme_bridge_module = b.createModule(.{ .root_source_file = b.path("src/xy/scheme_bridge.zig"), .target = target, .optimize = optimize });
    xy_scheme_bridge_module.addImport("viewport_layout", viewport_layout_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = xy_scheme_bridge_module })).step);
    const xy_render_adapter_module = b.createModule(.{ .root_source_file = b.path("src/xy/render_adapter.zig"), .target = target, .optimize = optimize });
    xy_render_adapter_module.addImport("surface", surface_module);
    xy_render_adapter_module.addImport("viewport_layout", viewport_layout_module);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = xy_render_adapter_module })).step);
}
