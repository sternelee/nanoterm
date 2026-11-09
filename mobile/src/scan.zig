//! Scanning a relay QR code into the connect fields: the Android camera path
//! where there is one, and a friendly nothing elsewhere.
const builtin = @import("builtin");

pub const impl = if (builtin.abi.isAndroid()) @import("scan_android.zig") else @import("scan_none.zig");

pub const supported = impl.supported;
pub const start = impl.start;
pub const stop = impl.stop;
pub const poll = impl.poll;

/// Where a status line goes (a Phone's notification): set once at startup.
pub fn setNotify(f: ?*const fn (msg: []const u8) void) void {
    impl.notify = f;
}
