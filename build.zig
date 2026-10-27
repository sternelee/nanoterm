const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const nanoui = b.dependency("nanoui", .{ .target = target, .optimize = optimize }).module("nanoui");
    // Release packages leave the debug information out (tools/package-linux.sh).
    const strip = b.option(bool, "strip", "Leave debug information out of nanoterm");
    // Its version, for `--version` and for updates where no bundle says it
    // (Linux, Windows): the packaging scripts set it.
    const options = b.addOptions();
    options.addOption([]const u8, "version", b.option([]const u8, "version", "nanoterm's version (release builds)") orelse "");

    // fx is compiled into nanoterm, not launched as `fx acp` or `fx ask`.
    // The submodule remains pristine upstream; this patch adds nanoterm's
    // embedding entry point and callbacks after a fresh submodule checkout.
    const prepare_fx = b.addSystemCommand(&.{"./scripts/prepare-fx.sh"});
    const fx_options = b.addOptions();
    fx_options.addOption([]const u8, "git_commit", "embedded");
    fx_options.addOption([]const u8, "app_version", "embedded");
    fx_options.addOption([]const u8, "update_channel", "stable");
    fx_options.addOption(enum { none, core, term }, "wasm_surface", .none);
    fx_options.addOption(bool, "libfx", false);
    const session_options = b.addOptions();
    session_options.addOption(bool, "hooks", false);
    session_options.addOptionPathUntracked("trace_dir", b.graph.path(.install_prefix, "session-manager-traces"));
    session_options.addOptionPathUntracked("src_dir", b.path("vendor/fx/src/core/session_manager"));
    const session_manager = b.createModule(.{
        .root_source_file = b.path("vendor/fx/src/core/session_manager/api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "build_options", .module = session_options.createModule() }},
    });
    const test_paths = b.addOptions();
    test_paths.addOptionPathUntracked("product_exe", b.graph.path(.install_bin, "nanoterm"));
    test_paths.addOptionPathUntracked("source_root", b.path("vendor/fx/src"));
    const fx = b.createModule(.{
        .root_source_file = b.path("vendor/fx/src/embedded.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "build_options", .module = fx_options.createModule() },
            .{ .name = "session_manager", .module = session_manager },
            .{ .name = "test_paths", .module = test_paths.createModule() },
        },
    });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .strip = strip,
        .imports = &.{ .{ .name = "nanoui", .module = nanoui }, .{ .name = "build_options", .module = options.createModule() }, .{ .name = "fx", .module = fx } },
    });
    const exe = b.addExecutable(.{ .name = "nanoterm", .root_module = mod });
    exe.step.dependOn(&prepare_fx.step);
    // A window of its own on Windows, without a console window beside it.
    if (target.result.os.tag == .windows) exe.subsystem = .windows;
    b.installArtifact(exe);
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run", "Run nanoterm").dependOn(&run.step);

    const filters = b.option([]const []const u8, "test-filter", "Run only the tests whose names contain this") orelse &.{};
    const tests = b.addTest(.{
        .filters = filters,
        .root_module = b.createModule(.{
            // Windows has tests of its own: no zsh, Python or Unix tools there.
            .root_source_file = b.path(if (target.result.os.tag == .windows) "src/tests_windows.zig" else "src/tests.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{ .{ .name = "nanoui", .module = nanoui }, .{ .name = "fx", .module = fx } },
        }),
    });
    tests.step.dependOn(&prepare_fx.step);
    b.step("test", "Run nanoterm's tests").dependOn(&b.addRunArtifact(tests).step);
    // The tests as a program, for another machine (Linux in a container).
    b.step("test-bin", "Install the tests as zig-out/bin/nanoterm-tests").dependOn(&b.addInstallArtifact(tests, .{ .dest_sub_path = if (target.result.os.tag == .windows) "nanoterm-tests.exe" else "nanoterm-tests" }).step);

    // The terminal benchmark (bench/README.md): its workloads and report, and
    // nanoterm's engine as a runner. Build it with -Doptimize=ReleaseFast.
    const vt_mod = b.createModule(.{
        .root_source_file = b.path("src/vt.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = nanoui }},
    });
    const runner = b.addExecutable(.{ .name = "nanoterm-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/nanoterm_bench.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "vt", .module = vt_mod }},
    }) });
    const termbench = b.addExecutable(.{ .name = "termbench", .root_module = b.createModule(.{
        .root_source_file = b.path("bench/termbench.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    // A video of nanoterm, rendered offscreen (src/video.zig).
    const video = b.addExecutable(.{ .name = "nanoterm-video", .root_module = b.createModule(.{
        .root_source_file = b.path("src/video.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "nanoui", .module = nanoui }, .{ .name = "fx", .module = fx } },
    }) });
    video.step.dependOn(&prepare_fx.step);
    b.step("video", "Build zig-out/bin/nanoterm-video").dependOn(&b.addInstallArtifact(video, .{}).step);

    const bench = b.step("bench", "Build the terminal benchmark (bench/README.md)");
    bench.dependOn(&b.addInstallArtifact(runner, .{}).step);
    bench.dependOn(&b.addInstallArtifact(termbench, .{}).step);
}
