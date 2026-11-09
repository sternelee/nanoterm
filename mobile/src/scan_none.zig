//! Scanning, where there is no camera path (desktop, iOS as yet): nothing
//! starts, and the connect screen says so.
const std = @import("std");

pub var notify: ?*const fn (msg: []const u8) void = null;

pub fn busy() bool {
    _ = &notify;
    return false;
}
pub fn supported() bool {
    _ = &notify;
    return false;
}
pub fn start() bool {
    _ = &notify;
    return false;
}
pub fn stop() void {}
pub fn poll() ?[]const u8 {
    _ = &notify;
    return null;
}
