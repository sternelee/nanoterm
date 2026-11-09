//! Scanning on Android: ask for the camera, then let scan_camera.c (NDK
//! camera2 + quirc) decode frames. The C worker hands a decode back through
//! `nanoterm_qr_found`; the UI thread polls it each frame (`poll`), so the
//! fields are filled where the view runs, as everything else is.
//!
//! After the permission dialog, NativeActivity gets no result callback, so the
//! activity simply resumes: the view keeps running on that thread and `poll`
//! notices the grant and starts the camera. If the camera yields nothing in a
//! few seconds, `poll` says so, so a silent failure is not silent.
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
extern fn qr_scan_frames() c_int;

pub var notify: ?*const fn (msg: []const u8) void = null;

var lock: std.atomic.Mutex = .unlocked;
var buf: [1024]u8 = undefined;
var out: [1024]u8 = undefined;
var len: usize = 0;
var found = std.atomic.Value(bool).init(false);
/// Asked for permission, waiting for the grant.
var pending = false;
/// The camera is running (granted and started).
var scanning = false;
var frames: u32 = 0;
var pending_frames: u32 = 0;

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

/// Whether the view should show "scanning": asking for the camera, or
/// running it. The view keeps a spinner on screen while this holds, which is
/// also what keeps redrawing (nanoui draws on demand) so `poll` keeps running.
pub fn busy() bool {
    return pending or scanning;
}

/// Start scanning: check/ask for the camera on the activity thread.
pub fn start() bool {
    // Ask now, on this (the activity) thread, so the view paints the
    // scanning state at once and starts redrawing; the JNI runs posted.
    pending = true;
    pending_frames = 0;
    if (!act.onUiThread(null, begin)) {
        pending = false;
        return false;
    }
    return true;
}

fn cameraGranted(env: jni.Env, a: *nanoui.ndk.ANativeActivity) bool {
    const perm = jni.string(env, "android.permission.CAMERA");
    defer jni.deleteLocal(env, perm);
    const g = jni.call(env, a.clazz, "checkSelfPermission", "(Ljava/lang/String;)I", &.{jni.ref(perm)});
    return (g orelse -1) == 0;
}

fn begin(_: ?*anyopaque, env: jni.Env) void {
    const a = act.activity orelse return;
    if (cameraGranted(env, a)) {
        startCamera();
        return;
    }
    const perm = jni.string(env, "android.permission.CAMERA");
    defer jni.deleteLocal(env, perm);
    const arr = jni.newStringArray(env, 1);
    if (arr != null) {
        jni.setArrayElement(env, arr, 0, perm);
        _ = jni.call(env, a.clazz, "requestPermissions", "([Ljava/lang/String;I)V", &.{ jni.ref(arr), jni.int(4001) });
        jni.deleteLocal(env, arr);
    }
    pending = true;
    if (notify) |f| f("Allow the camera to scan the QR code.");
}

fn startCamera() void {
    if (scanning) return;
    scanning = true;
    pending = false;
    frames = 0;
    _ = qr_scan_start();
    if (notify) |f| f("Scanning: point the camera at the desktop's QR code.");
}

/// Each frame, on the UI thread: notice a grant while waiting, surface a
/// camera that produces nothing, and hand back a decoded link.
pub fn poll() ?[]const u8 {
    if (pending) {
        if (act.env) |env| if (act.activity) |a| {
            if (cameraGranted(env, a)) {
                startCamera();
            } else {
                pending_frames += 1;
                // ~15s at 12fps: the dialog closed and it was not granted.
                if (pending_frames > 180) {
                    stop();
                    if (notify) |f| f("Camera permission was not granted.");
                    return null;
                }
            }
        };
    }
    if (scanning and !found.load(.acquire)) {
        frames += 1;
        // ~10s at 12fps: the camera opened but has given no frames at all
        // (busy elsewhere, or the device accepts the session but streams
        // nothing). Frames that do arrive but hold no QR keep scanning, so
        // the person can keep aiming.
        if (frames > 120 and qr_scan_frames() == 0) {
            stop();
            if (notify) |f| f("The camera gave no frames. Try Scan again (is the camera in use?).");
            return null;
        }
    }
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
    pending = false;
    scanning = false;
    frames = 0;
    pending_frames = 0;
    qr_scan_stop();
}
