//! The phone's nanoterm: nanoui as an iOS app (`Name.app` in zig-out/ios,
//! `zig build run` in the booted Simulator).
//!
//! Zig 0.17.0 cannot build a program for iOS as it ships; nanoui's
//! tools/ios/zig-lib.sh makes a lib folder with one line fixed and prints
//! the flag that uses it, which goes before any other:
//!
//!   zig build $(sh ../zig-pkg/nanoui-*/tools/ios/zig-lib.sh) run -Dtarget=aarch64-ios-simulator
//!
//! (`mobile/dev.sh run` does that, and finds the package.) On a desktop the
//! same program builds as a plain window, which is how it is tried out.
const std = @import("std");
const nanoui = @import("nanoui");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // The nanoui the phone is built against: the local fork with Android
    // IME text support. The URL dependency below is still imported for its
    // build helpers (`@import("nanoui").android` / `.ios`), byte-identical
    // to the fork's own tools.
    const fork = b.dependency("nanoui_fork", .{ .target = target, .optimize = optimize });

    // The desktop's Markdown parser and syntax colors, so agent text on
    // the phone is read exactly as it is at the workstation.
    const markdown = b.createModule(.{
        .root_source_file = b.path("../src/markdown.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = fork.module("nanoui") }},
    });
    const highlight = b.createModule(.{
        .root_source_file = b.path("../src/highlight.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = fork.module("nanoui") }},
    });
    // The desktop's palette, so the phone wears the same theme.
    const theme = b.createModule(.{
        .root_source_file = b.path("../src/theme.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "nanoui", .module = fork.module("nanoui") }},
    });

    const exe = b.addExecutable(.{
        .name = "nanoterm",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "nanoui", .module = fork.module("nanoui") },
                .{ .name = "markdown", .module = markdown },
                .{ .name = "highlight", .module = highlight },
                .{ .name = "theme", .module = theme },
            },
        }),
    });

    // Android is a library, not an executable: it is installed as an APK
    // below. Installing the exe here would need a libc Zig cannot provide
    // for this target.
    if (!target.result.abi.isAndroid()) b.installArtifact(exe);

    // A desktop build runs in this session's window server, as nanoterm
    // does: the same program, so the relay client can be tried without a
    // Simulator in the way.
    const run = b.addRunArtifact(exe);
    run.addPassthruArgs();
    b.step("run-native", "Run the phone's app as a desktop window").dependOn(&run.step);

    // What the phone makes of the relay's events, on this machine.
    // Android has no host test binary (its app is a library); tests there
    // run on the device via adb, so only the desktop/iOS builds get this.
    if (!target.result.abi.isAndroid()) {
        const tests = b.addTest(.{ .root_module = exe.root_module });
        b.step("test", "Test the phone's app").dependOn(&b.addRunArtifact(tests).step);
    }

    // Android: a library NativeActivity loads, packed into an APK.
    if (target.result.abi.isAndroid()) {
        const android = @import("nanoui").android;
        const lib = android.library(b, .{
            .name = "nanoterm",
            .root_module = exe.root_module,
            .nanoui = fork.module("nanoui"),
        });
        if (android.Sdk.find(b)) |sdk| _ = android.linkNdk(b, lib, sdk);
        const opts: android.Options = .{ .name = "nanoterm", .id = "com.justrach.nanoterm", .version = "0.1", .icon = b.path("android/ic_launcher.png") };
        const apk = android.apk(b, lib, opts);
        b.getInstallStep().dependOn(&b.addInstallFileWithDir(apk, .prefix, "android/nanoterm.apk").step);
        const run_android = android.runOnDevice(b, apk, opts, b.path("."));
        run_android.addPassthruArgs();
        b.step("run-android", "Run the app on the device adb sees").dependOn(&run_android.step);
        return;
    }

    // iOS: the bundle, then the Simulator.
    if (target.result.os.tag != .ios) return;
    const ios = @import("nanoui").ios;
    const opts: ios.Options = .{ .name = "nanoterm", .id = "com.justrach.nanoterm", .version = "0.1", .assets = b.path("ios/Assets.xcassets") };
    const bundle = ios.app(b, exe, opts);
    b.getInstallStep().dependOn(&b.addInstallDirectory(.{
        .source_dir = bundle,
        .install_dir = .prefix,
        .install_subdir = "ios/nanoterm.app",
    }).step);
    const step = b.step("run", "Run the app in the booted iOS Simulator");
    if (target.result.abi == .simulator) {
        const sim = ios.runInSimulator(b, bundle, opts, b.path("."));
        sim.addPassthruArgs();
        step.dependOn(&sim.step);
    } else step.dependOn(&b.addFail("run is the Simulator (-Dtarget=aarch64-ios-simulator); run-native is this Mac").step);
}
