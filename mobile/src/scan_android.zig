//! Scanning on Android: ask for the camera, then let scan_camera.c (NDK
//! camera2 + quirc) decode frames. The C worker hands a decode back through
//! `nanoterm_qr_found`; the UI thread polls it each frame (`poll`), so the
//! fields are filled where the view runs, as everything else is.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");

comptime {
    if (!builtin.abi.isAndroid()) @compileError("scan_android is Android only");
}

const act = nanoui.android_activity;
const jni = nanoui.jni;

extern fn qr_scan_start() c_int;
extern fn qr_scan_stop() void;

pub var notify: ?*const fn (msg: []const u8) void = null;

var lock: std.atomic.Mutex = .unlocked;
var buf: [1024]u8 = undefined;
var out: [1024]u8 = undefined;
var len: usize = 0;
var found = std.atomic.Value(bool).init(false);
var running = false;

/// The C worker calls this from its own thread; it only copies and flags.
export fn nanoterm_qr_found(payload: [*]const u8, n: c_int) callconv(.c) void {
    const count: usize = if (n <= 0) 0 else @min(@as(usize, @intCast(n)), buf.len);
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    defer lock.unlock();
    @memcpy(buf[0..count], payload[0..count]);
    len = count;
    found.store(true, .release);
}

pub fn supported() bool {
    return true;
}

/// Start scanning, asking for the camera permission first (on the Java
/// thread). Returns false only if the activity is gone.
pub fn start() bool {
    if (running) return true;
    running = true;
    if (!act.onUiThread(null, begin)) {
        running = false;
        return false;
    }
    return true;
}

fn begin(_: ?*anyopaque, env: jni.Env) void {
    const a = act.activity orelse {
        running = false;
        return;
    };
    const perm = jni.string(env, "android.permission.CAMERA");
    defer jni.deleteLocal(env, perm);
    const granted = jni.call(env, a.clazz, "checkSelfPermission", "(Ljava/lang/String;)I", &.{jni.ref(perm)});
    if ((granted orelse -1) == 0) {
        _ = qr_scan_start();
        return;
    }
    // Ask; the answer has no callback through NativeActivity, so the person
    // taps Scan again once it is allowed.
    const arr = jni.newStringArray(env, 1);
    if (arr != null) {
        jni.setArrayElement(env, arr, 0, perm);
        _ = jni.call(env, a.clazz, "requestPermissions", "([Ljava/lang/String;I)V", &.{ jni.ref(arr), jni.int(4001) });
        jni.deleteLocal(env, arr);
    }
    running = false;
    if (notify) |f| f("Allow the camera, then tap Scan again.");
}

/// The decoded link, if a frame yielded one: stops the camera and hands the
/// text back (valid until the next decode). Called from the UI thread.
pub fn poll() ?[]const u8 {
    if (!found.load(.acquire)) return null;
    // Copy under the lock, then stop outside it: the worker takes the lock in
    // nanoterm_qr_found, so joining while holding it would deadlock.
    while (!lock.tryLock()) std.atomic.spinLoopHint();
    found.store(false, .release);
    const n = len;
    @memcpy(out[0..n], buf[0..n]);
    lock.unlock();
    stop();
    return out[0..n];
}

pub fn stop() void {
    if (!running) return;
    running = false;
    qr_scan_stop();
}
