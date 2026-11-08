//! The relay link the workstation's QR code carries, read back into its
//! pieces: the host, the port, and the token a phone needs to connect.
//!
//! The desktop encodes `nanoterm://relay?host=<addr>&port=<port>&token=<32
//! hex>`. This reads that, and is lenient about the rest: any scheme, the
//! parameters in any order, and a `host:port` authority for schemes that
//! carry one (`nanoterm-relay://10.0.0.5:5000?token=…`). A missing port is
//! the relay's default. It borrows the slices from `text`.
const std = @import("std");

pub const default_port: u16 = 4789;
pub const token_len: usize = 32;
pub const host_max: usize = 64;

pub const Link = struct {
    host: []const u8,
    port: u16,
    token: []const u8,
};

/// The link `text` holds, or null when it is not one this relay would print:
/// no host, a token that is not 32 characters, a port that is not a number.
pub fn parse(text: []const u8) ?Link {
    var host: ?[]const u8 = null;
    var port: u16 = default_port;
    var token: ?[]const u8 = null;

    // A scheme's authority, when it has one: `//host[:port]` before any
    // `/`, `?` or `#`.
    if (std.mem.indexOf(u8, text, "://")) |i| {
        const rest = text[i + 3 ..];
        const end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
        const authority = rest[0..end];
        if (std.mem.lastIndexOfScalar(u8, authority, ':')) |c| {
            if (c > 0) host = authority[0..c];
            if (std.fmt.parseInt(u16, authority[c + 1 ..], 10)) |v| {
                port = v;
            } else |_| {}
        } else if (authority.len > 0 and std.mem.indexOfScalar(u8, authority, '.') != null) {
            // A bare authority is a host only when it looks like an address:
            // `nanoterm://relay?…`'s "relay" is the resource, not a host.
            host = authority;
        }
    }

    // The query: `key=value` pairs after the `?`, in any order.
    const query = if (std.mem.indexOfScalar(u8, text, '?')) |q| text[q + 1 ..] else "";
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = pair[0..eq];
        const val = pair[eq + 1 ..];
        if (std.mem.eql(u8, key, "host")) {
            if (val.len > 0) host = val;
        } else if (std.mem.eql(u8, key, "port")) {
            if (std.fmt.parseInt(u16, val, 10)) |v| {
                port = v;
            } else |_| return null;
        } else if (std.mem.eql(u8, key, "token")) {
            if (val.len > 0) token = val;
        }
    }

    const h = host orelse return null;
    const t = token orelse return null;
    if (h.len == 0 or h.len > host_max) return null;
    if (t.len != token_len) return null;
    return .{ .host = h, .port = port, .token = t };
}

const testing = std.testing;
const hex32 = "0123456789abcdef0123456789abcdef";

test "the desktop's own link reads back" {
    const l = parse("nanoterm://relay?host=192.168.31.124&port=4789&token=" ++ hex32).?;
    try testing.expectEqualStrings("192.168.31.124", l.host);
    try testing.expectEqual(@as(u16, 4789), l.port);
    try testing.expectEqualStrings(hex32, l.token);
}

test "a missing port is the relay's default, and order does not matter" {
    const l = parse("nanoterm://relay?token=" ++ hex32 ++ "&host=10.0.0.7").?;
    try testing.expectEqualStrings("10.0.0.7", l.host);
    try testing.expectEqual(default_port, l.port);
    try testing.expectEqualStrings(hex32, l.token);
}

test "an authority-style link carries host and port" {
    const l = parse("nanoterm-relay://10.0.0.5:5000?token=" ++ hex32).?;
    try testing.expectEqualStrings("10.0.0.5", l.host);
    try testing.expectEqual(@as(u16, 5000), l.port);
}

test "what is not a link is not one" {
    try testing.expect(parse("hello world") == null);
    try testing.expect(parse("nanoterm://relay?host=1.2.3.4&port=4789") == null); // no token
    try testing.expect(parse("nanoterm://relay?port=4789&token=" ++ hex32) == null); // no host
    try testing.expect(parse("nanoterm://relay?host=1.2.3.4&token=abc") == null); // short token
    try testing.expect(parse("nanoterm://relay?host=1.2.3.4&port=xx&token=" ++ hex32) == null); // bad port
}
