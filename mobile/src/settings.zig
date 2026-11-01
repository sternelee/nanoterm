//! Where the phone keeps what it needs to find the workstation: the host,
//! the port, the token, and the theme preference.
//!
//! A file, not an argument: a phone has no command line, and nanoui's
//! launch ignores an intent's extras in a non-debuggable build (any app
//! could send them), so a release build can only be told by the person
//! holding it — once, on the connect screen — and has to remember it.
//!
//! It lives in the app's own directory: the sandbox's home on iOS, the
//! cache directory Android sets TMPDIR to, `$HOME` on a desktop. Losing it
//! costs one retyping, nothing more.
const std = @import("std");

pub const port_default: u16 = 4789;
/// A relay's token: 16 random bytes, written as hex.
pub const token_len = 32;
pub const host_max = 64;

/// Theme preference: follow system, or force light/dark.
pub const ThemePreference = enum {
    system,
    light,
    dark,
};

/// How the tabs are shown: the desktop's bottom tabs as a row of pills, or
/// its sidebar as a drawer.
pub const Layout = enum {
    tabs,
    sidebar,
};

/// What the file holds, in memory: owned by the allocator it was read with.
pub const Stored = struct {
    host: []u8 = &.{},
    port: u16 = port_default,
    token: []u8 = &.{},
    theme: ThemePreference = .system,
    layout: Layout = .tabs,

    pub fn deinit(s: Stored, gpa: std.mem.Allocator) void {
        if (s.host.len > 0) gpa.free(s.host);
        if (s.token.len > 0) gpa.free(s.token);
    }

    /// A token is 32 hex characters, or it is not a token: a file with
    /// half of one is a file that was cut short.
    pub fn usable(s: Stored) bool {
        return s.token.len == token_len;
    }
};

/// The file's own name, in `buf`.
pub fn path(buf: *[512]u8) ?[]const u8 {
    const home = std.c.getenv("HOME");
    const tmp = std.c.getenv("TMPDIR");
    const base = if (home) |h| std.mem.sliceTo(h, 0) else if (tmp) |t| std.mem.sliceTo(t, 0) else return null;
    return std.fmt.bufPrint(buf, "{s}/.nanoterm-phone.json", .{base}) catch null;
}

/// The file, as written: every field optional, so a hand-edited one with
/// only a host still reads.
const Written = struct {
    host: []const u8 = "",
    port: u16 = port_default,
    token: []const u8 = "",
    theme: []const u8 = "system",
    layout: []const u8 = "tabs",
};

/// What was saved, or null (the first run, or a file that does not read).
pub fn load(io: std.Io, gpa: std.mem.Allocator) ?Stored {
    var buf: [512]u8 = undefined;
    const p = path(&buf) orelse return null;
    return loadFile(io, gpa, p);
}

pub fn loadFile(io: std.Io, gpa: std.mem.Allocator, p: []const u8) ?Stored {
    const data = std.Io.Dir.cwd().readFileAlloc(io, p, gpa, .limited(8 * 1024)) catch return null;
    defer gpa.free(data);
    var parsed = std.json.parseFromSlice(Written, gpa, data, .{ .ignore_unknown_fields = true }) catch return null;
    defer parsed.deinit();
    const w = parsed.value;
    var s: Stored = .{ .port = w.port };
    // Nothing half-saved is worth keeping: an empty host is the default.
    s.host = gpa.dupe(u8, if (w.host.len > 0 and w.host.len <= host_max) w.host else "127.0.0.1") catch return null;
    s.token = gpa.dupe(u8, if (w.token.len == token_len) w.token else "") catch {
        gpa.free(s.host);
        return null;
    };
    // Theme preference: parse the string, default to system.
    s.theme = if (std.mem.eql(u8, w.theme, "light")) .light else if (std.mem.eql(u8, w.theme, "dark")) .dark else .system;
    s.layout = if (std.mem.eql(u8, w.layout, "sidebar")) .sidebar else .tabs;
    return s;
}

/// Writes it, and says whether it landed: a phone that cannot save still
/// works for this run, it just asks again next time.
pub fn save(io: std.Io, gpa: std.mem.Allocator, host: []const u8, port: u16, token: []const u8, theme: ThemePreference, layout: Layout) bool {
    var buf: [512]u8 = undefined;
    const p = path(&buf) orelse return false;
    return saveFile(io, gpa, p, host, port, token, theme, layout);
}

pub fn saveFile(io: std.Io, gpa: std.mem.Allocator, p: []const u8, host: []const u8, port: u16, token: []const u8, theme: ThemePreference, layout: Layout) bool {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    const theme_str = switch (theme) {
        .system => "system",
        .light => "light",
        .dark => "dark",
    };
    std.json.Stringify.value(Written{ .host = host, .port = port, .token = token, .theme = theme_str, .layout = @tagName(layout) }, .{}, &aw.writer) catch return false;
    var file = std.Io.Dir.cwd().createFile(io, p, .{ .truncate = true }) catch return false;
    defer file.close(io);
    file.writeStreamingAll(io, aw.written()) catch return false;
    return true;
}

const testing = std.testing;

test "what was saved is what is read back" {
    const dir = "/tmp/nanoterm-phone-test";
    std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    const p = dir ++ "/settings.json";

    // Nothing saved yet: nothing read.
    try testing.expect(loadFile(testing.io, testing.allocator, p) == null);

    try testing.expect(saveFile(testing.io, testing.allocator, p, "192.168.1.20", 4790, "0123456789abcdef0123456789abcdef", .system, .tabs));
    const s = loadFile(testing.io, testing.allocator, p) orelse return error.NotRead;
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("192.168.1.20", s.host);
    try testing.expectEqual(@as(u16, 4790), s.port);
    try testing.expectEqualStrings("0123456789abcdef0123456789abcdef", s.token);
    try testing.expect(s.usable());
    try testing.expectEqual(ThemePreference.system, s.theme);
    try testing.expectEqual(Layout.tabs, s.layout);

    // Saving again replaces it, rather than appending.
    try testing.expect(saveFile(testing.io, testing.allocator, p, "mac.local", 4789, "ffffffffffffffffffffffffffffffff", .dark, .sidebar));
    const t = loadFile(testing.io, testing.allocator, p) orelse return error.NotRead;
    defer t.deinit(testing.allocator);
    try testing.expectEqualStrings("mac.local", t.host);
    try testing.expectEqualStrings("ffffffffffffffffffffffffffffffff", t.token);
    try testing.expectEqual(ThemePreference.dark, t.theme);
    try testing.expectEqual(Layout.sidebar, t.layout);
}

test "a file with a half token, or a hand-edited one, still reads" {
    const dir = "/tmp/nanoterm-phone-test-bad";
    std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};

    // Cut short: the token goes, the host stays.
    var file = try std.Io.Dir.cwd().createFile(testing.io, dir ++ "/half.json", .{ .truncate = true });
    try file.writeStreamingAll(testing.io, "{\"host\":\"10.0.0.2\",\"port\":5000,\"token\":\"abc\"}");
    file.close(testing.io);
    const a = loadFile(testing.io, testing.allocator, dir ++ "/half.json") orelse return error.NotRead;
    defer a.deinit(testing.allocator);
    try testing.expectEqualStrings("10.0.0.2", a.host);
    try testing.expectEqual(@as(u16, 5000), a.port);
    try testing.expectEqual(@as(usize, 0), a.token.len);
    try testing.expect(!a.usable());

    // Not JSON at all, and a field nobody knows: the default, then the rest.
    var f2 = try std.Io.Dir.cwd().createFile(testing.io, dir ++ "/junk.json", .{ .truncate = true });
    try f2.writeStreamingAll(testing.io, "not json at all");
    f2.close(testing.io);
    try testing.expect(loadFile(testing.io, testing.allocator, dir ++ "/junk.json") == null);

    var f3 = try std.Io.Dir.cwd().createFile(testing.io, dir ++ "/extra.json", .{ .truncate = true });
    try f3.writeStreamingAll(testing.io, "{\"token\":\"0123456789abcdef0123456789abcdef\",\"future\":true}");
    f3.close(testing.io);
    const c = loadFile(testing.io, testing.allocator, dir ++ "/extra.json") orelse return error.NotRead;
    defer c.deinit(testing.allocator);
    try testing.expectEqualStrings("127.0.0.1", c.host);
    try testing.expectEqual(@as(u16, port_default), c.port);
    try testing.expect(c.usable());
}

test "theme preference is saved and loaded" {
    const dir = "/tmp/nanoterm-phone-test-theme";
    std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(testing.io, dir);
    defer std.Io.Dir.cwd().deleteTree(testing.io, dir) catch {};
    const p = dir ++ "/theme.json";

    // Default theme is system.
    try testing.expect(saveFile(testing.io, testing.allocator, p, "127.0.0.1", 4789, "0123456789abcdef0123456789abcdef", .system, .tabs));
    const s1 = loadFile(testing.io, testing.allocator, p) orelse return error.NotRead;
    defer s1.deinit(testing.allocator);
    try testing.expectEqual(ThemePreference.system, s1.theme);

    // Light theme.
    try testing.expect(saveFile(testing.io, testing.allocator, p, "127.0.0.1", 4789, "0123456789abcdef0123456789abcdef", .light, .tabs));
    const s2 = loadFile(testing.io, testing.allocator, p) orelse return error.NotRead;
    defer s2.deinit(testing.allocator);
    try testing.expectEqual(ThemePreference.light, s2.theme);

    // Dark theme.
    try testing.expect(saveFile(testing.io, testing.allocator, p, "127.0.0.1", 4789, "0123456789abcdef0123456789abcdef", .dark, .tabs));
    const s3 = loadFile(testing.io, testing.allocator, p) orelse return error.NotRead;
    defer s3.deinit(testing.allocator);
    try testing.expectEqual(ThemePreference.dark, s3.theme);

    // Unknown theme string defaults to system.
    var f = try std.Io.Dir.cwd().createFile(testing.io, dir ++ "/unknown.json", .{ .truncate = true });
    try f.writeStreamingAll(testing.io, "{\"host\":\"127.0.0.1\",\"port\":4789,\"token\":\"0123456789abcdef0123456789abcdef\",\"theme\":\"unknown\"}");
    f.close(testing.io);
    const s4 = loadFile(testing.io, testing.allocator, dir ++ "/unknown.json") orelse return error.NotRead;
    defer s4.deinit(testing.allocator);
    try testing.expectEqual(ThemePreference.system, s4.theme);
}
