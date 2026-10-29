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

    const test_step = b.step("test", "Run host-side nihOS unit tests");
    test_step.dependOn(&run_module_tests.step);
    const surface_tests = b.addTest(.{ .root_module = surface_module });
    test_step.dependOn(&b.addRunArtifact(surface_tests).step);
    const canvas_module = b.createModule(.{ .root_source_file = b.path("src/graphics/canvas.zig"), .target = target, .optimize = optimize });
    canvas_module.addImport("surface", surface_module);
    const console_scroll_probe = b.createModule(.{ .root_source_file = b.path("src/graphics/console_canvas_scroll_test.zig"), .target = target, .optimize = optimize });
    console_scroll_probe.addImport("canvas", canvas_module);
    console_scroll_probe.addImport("console", b.createModule(.{ .root_source_file = b.path("src/console.zig"), .target = target, .optimize = optimize }));
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = console_scroll_probe })).step);
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
}
