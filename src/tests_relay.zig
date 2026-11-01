//! The relay, end to end: a client that is not the relay's token refused,
//! and one that is shown the tab, given its blocks, and able to run a
//! command in it. A real socket, a real shell — nothing leaves the machine.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const relay = @import("relay.zig");
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");

const token = "relay-test-token-0123456789abcde";

const sys = struct {
    extern "c" fn socket(domain: c_int, kind: c_int, protocol: c_int) c_int;
    extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
    extern "c" fn usleep(usec: c_uint) c_int;
};

const F_SETFL = 4;
const O_NONBLOCK = if (builtin.os.tag == .linux) 0o4000 else 0x4;
const AF_INET = 2;
const SOCK_STREAM = 1;

/// Loopback, as this platform lays `sockaddr_in` out.
const SockaddrIn = if (@import("builtin").os.tag == .macos) extern struct {
    len: u8 = 16,
    family: u8 = AF_INET,
    port: u16,
    addr: [4]u8 = .{ 127, 0, 0, 1 },
    zero: [8]u8 = @splat(0),
} else extern struct {
    family: u16 = AF_INET,
    port: u16,
    addr: [4]u8 = .{ 127, 0, 0, 1 },
    zero: [8]u8 = @splat(0),
};

const Client = struct {
    fd: c_int,
    buf: [16 * 1024]u8 = undefined,
    len: usize = 0,

    fn open(port: u16) ?Client {
        const fd = sys.socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return null;
        var addr: SockaddrIn = .{ .port = std.mem.nativeToBig(u16, port) };
        if (sys.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrIn)) != 0) {
            _ = sys.close(fd);
            return null;
        }
        _ = sys.fcntl(fd, F_SETFL, @as(c_int, O_NONBLOCK));
        return .{ .fd = fd };
    }

    fn close(c: Client) void {
        _ = sys.close(c.fd);
    }

    fn send(c: *Client, bytes: []const u8) bool {
        var sent: usize = 0;
        var tries: usize = 0;
        while (sent < bytes.len and tries < 400) : (tries += 1) {
            const n = sys.write(c.fd, bytes.ptr + sent, bytes.len - sent);
            if (n > 0) sent += @intCast(n) else _ = sys.usleep(2000);
        }
        return sent == bytes.len;
    }

    /// The next line it sends, without its newline: null when none comes.
    fn next(c: *Client, out: []u8) ?[]const u8 {
        var tries: usize = 0;
        while (tries < 2000) : (tries += 1) {
            if (std.mem.indexOfScalar(u8, c.buf[0..c.len], '\n')) |at| {
                if (at > out.len) return null;
                @memcpy(out[0..at], c.buf[0..at]);
                const left = c.len - at - 1;
                std.mem.copyForwards(u8, c.buf[0..left], c.buf[at + 1 .. c.len]);
                c.len = left;
                return out[0..at];
            }
            if (c.len == c.buf.len) return null;
            const n = sys.read(c.fd, c.buf[c.len..].ptr, c.buf.len - c.len);
            if (n > 0) c.len += @intCast(n) else _ = sys.usleep(2000);
        }
        return null;
    }
};

const Result = struct {
    /// Why it failed, when it did: a phrase, no allocation.
    failed: ?[]const u8 = null,
    /// What the relay said the tab's id was.
    session: u64 = 0,
    /// The phone has been shown the tabs (the test closes one then).
    seen: bool = false,
    done: bool = false,
};

/// The first tab id of a welcome, when it lists one.
fn firstId(welcome: []const u8) ?u64 {
    const at = std.mem.indexOf(u8, welcome, "\"sessions\":[") orelse return null;
    var id: u64 = 0;
    for (welcome[at + "\"sessions\":[".len ..]) |ch| {
        if (ch < '0' or ch > '9') break;
        id = id * 10 + (ch - '0');
    }
    return if (id == 0) null else id;
}

/// The phone: refused without the token, shown the tab with it, and able to
/// run a command in that tab.
fn phone(port: u16, r: *Result) void {
    defer @atomicStore(bool, &r.done, true, .release);
    {
        var c = Client.open(port) orelse {
            r.failed = "the relay did not take a connection";
            return;
        };
        defer c.close();
        if (!c.send("{\"op\":\"hello\",\"token\":\"relay-test-token-0123456789ab999\"}\n")) {
            r.failed = "a hello could not be sent";
            return;
        }
        var buf: [4096]u8 = undefined;
        const said = c.next(&buf) orelse {
            r.failed = "a wrong token was not answered";
            return;
        };
        if (std.mem.indexOf(u8, said, "\"kind\":\"error\"") == null) {
            r.failed = "a wrong token was let in";
            return;
        }
        if (c.next(&buf) != null) {
            r.failed = "the refused socket stayed open";
            return;
        }
    }
    var c = Client.open(port) orelse {
        r.failed = "the relay took no second connection";
        return;
    };
    defer c.close();
    var hello: [128]u8 = undefined;
    const hello_line = std.fmt.bufPrint(&hello, "{{\"op\":\"hello\",\"token\":\"{s}\"}}\n", .{token}) catch return;
    if (!c.send(hello_line)) {
        r.failed = "the relay's own token could not be sent";
        return;
    }
    var buf: [16 * 1024]u8 = undefined;
    // The tabs, then how the one tab is; then a command run from here.
    var ran = false;
    var tries: usize = 0;
    while (tries < 4000) : (tries += 1) {
        const said = c.next(&buf) orelse {
            r.failed = "the relay stopped talking";
            return;
        };
        if (std.mem.indexOf(u8, said, "\"kind\":\"welcome\"") != null) {
            const after = std.mem.indexOf(u8, said, "\"sessions\":[") orelse {
                r.failed = "a welcome without its tabs";
                return;
            };
            const digits = said[after + "\"sessions\":[".len ..];
            var id: u64 = 0;
            for (digits) |ch| {
                if (ch < '0' or ch > '9') break;
                id = id * 10 + (ch - '0');
            }
            if (id == 0) {
                r.failed = "a welcome with no tab";
                return;
            }
            r.session = id;
        }
        if (!ran and r.session != 0) {
            var run_buf: [128]u8 = undefined;
            const run_line = std.fmt.bufPrint(&run_buf, "{{\"op\":\"run\",\"session\":{d},\"text\":\"echo from-the-phone\"}}\n", .{r.session}) catch return;
            if (!c.send(run_line)) {
                r.failed = "a run could not be sent";
                return;
            }
            ran = true;
        }
        // The block, done, saying what it printed.
        if (std.mem.indexOf(u8, said, "\"command\":\"echo from-the-phone\"") != null and
            std.mem.indexOf(u8, said, "\"state\":\"done\"") != null and
            std.mem.indexOf(u8, said, "\"output\":\"from-the-phone") != null)
        {
            return;
        }
    }
    r.failed = "the command run from the phone never finished";
}

/// The phone, coming back to a tab that closed while it was away: the tab
/// leaves its list, and `list` shows it what is left.
fn phoneAgain(port: u16, r: *Result) void {
    defer @atomicStore(bool, &r.done, true, .release);
    var c = Client.open(port) orelse {
        r.failed = "the relay took no connection";
        return;
    };
    defer c.close();
    var hello: [128]u8 = undefined;
    const hello_line = std.fmt.bufPrint(&hello, "{{\"op\":\"hello\",\"token\":\"{s}\"}}\n", .{token}) catch return;
    if (!c.send(hello_line)) {
        r.failed = "hello could not be sent";
        return;
    }
    var buf: [16 * 1024]u8 = undefined;
    var listed = false;
    var tries: usize = 0;
    while (tries < 4000) : (tries += 1) {
        const said = c.next(&buf) orelse {
            r.failed = "the relay stopped talking";
            return;
        };
        if (!listed and std.mem.indexOf(u8, said, "\"kind\":\"welcome\"") != null) {
            r.session = firstId(said) orelse {
                r.failed = "a welcome with no tab";
                return;
            };
            @atomicStore(bool, &r.seen, true, .release);
            listed = true;
            continue;
        }
        if (std.mem.indexOf(u8, said, "\"kind\":\"gone\"") != null) {
            if (std.mem.indexOf(u8, said, "\"id\":1") == null) {
                r.failed = "gone for a tab that is not the one closed";
                return;
            }
            // Everything again: what is left is nothing.
            if (!c.send("{\"op\":\"list\"}\n")) {
                r.failed = "a list could not be sent";
                return;
            }
            continue;
        }
        if (std.mem.indexOf(u8, said, "\"kind\":\"welcome\"") != null) {
            if (std.mem.indexOf(u8, said, "\"sessions\":[]") == null) {
                r.failed = "a closed tab was still listed";
                return;
            }
            return;
        }
    }
    r.failed = "the closed tab was never said to be gone";
}

test "the relay: a wrong token refused, a tab shown, a command run from it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-relay";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    try env.put("PATH", "/usr/bin:/bin");
    const h = try relay.Hub.create(gpa, io, .{ .port = 0, .token = token });
    shared.relay = h;
    defer {
        h.destroy();
        shared.relay = null;
    }
    try std.testing.expect(h.port() != 0);
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    const s = try w.newTab(home);

    var result: Result = .{};
    const thread = try std.Thread.spawn(.{}, phone, .{ h.port(), &result });
    var waited: f64 = 0;
    while (!@atomicLoad(bool, &result.done, .acquire) and waited < 30) : (waited += 0.02) {
        nanoui.runFor(0.02);
        // The frame that follows a change is what sends what the change held.
        h.tick();
    }
    thread.join();
    if (result.failed) |why| {
        std.debug.print("relay test: {s}\n", .{why});
        return error.RelayTest;
    }
    try std.testing.expectEqual(s.id, result.session);
    // What the phone ran is a block of the tab it ran it in.
    var found = false;
    for (s.timeline.items) |e| switch (e) {
        .block => |b| if (std.mem.eql(u8, b.command, "echo from-the-phone") and b.state == .done) {
            found = true;
        },
        .turn => {},
    };
    try std.testing.expect(found);
}

test "the relay: a closed tab leaves the phone's list, and list shows what is left" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-relay-closed";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    const h = try relay.Hub.create(gpa, io, .{ .port = 0, .token = token });
    shared.relay = h;
    defer {
        h.destroy();
        shared.relay = null;
    }
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    const s = try w.newTab(home);

    var result: Result = .{};
    const thread = try std.Thread.spawn(.{}, phoneAgain, .{ h.port(), &result });
    var waited: f64 = 0;
    while (!@atomicLoad(bool, &result.seen, .acquire) and waited < 30) : (waited += 0.02) {
        nanoui.runFor(0.02);
        h.tick();
    }
    // The tab it was shown, closed while it watched.
    if (@atomicLoad(bool, &result.seen, .acquire)) h.detach(s);
    while (!@atomicLoad(bool, &result.done, .acquire) and waited < 90) : (waited += 0.02) {
        nanoui.runFor(0.02);
        h.tick();
    }
    thread.join();
    if (result.failed) |why| {
        std.debug.print("relay test: {s}\n", .{why});
        return error.RelayTest;
    }
    try std.testing.expectEqual(@as(u64, 1), result.session);
}
