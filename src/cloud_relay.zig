//! Desktop agent for an [alma-relay](https://github.com/) cloud relay: the
//! phone talks to the relay over HTTPS, the relay forwards requests to this
//! process over one WebSocket, and the sessions here answer them.
//!
//! `session.zig` implements the `on_hreq` callback and supplies the ctx; this
//! file owns the socket, the frames, and nothing about sessions — which keeps
//! it free of an import cycle.
//!
//! Wire protocol: `docs/PROTOCOL.md` in alma-relay. We register with `proto: 2`,
//! which streams request bodies but has no per-stream credit window (protocol
//! 3); every response here is small, so the simpler one is enough.

const std = @import("std");
const ws_client = @import("ws_client.zig");

const sha256_mod = std.crypto.hash.sha2;
const b64 = std.base64.standard.Encoder;

/// What the host answers. `id`, `method`, `path` and `body` belong to the
/// relay's frame and live until the callback returns.
pub const Callback = struct {
    on_hreq: ?*const fn (
        cr: *CloudRelay,
        id: []const u8,
        method: []const u8,
        path: []const u8,
        body: []const u8,
    ) anyerror!void = null,
    /// The phone asked for a WebSocket. Answering with `sendWopened` opens it;
    /// an error is reported to the phone as `werr`.
    on_wopen: ?*const fn (cr: *CloudRelay, id: []const u8, path: []const u8) anyerror!void = null,
    /// Bytes the phone sent through that socket. Valid until the callback
    /// returns, and only for ids `on_wopen` opened.
    on_wmsg: ?*const fn (cr: *CloudRelay, id: []const u8, bytes: []const u8) void = null,
    on_wclose: ?*const fn (cr: *CloudRelay, id: []const u8) void = null,
    /// The tunnel itself is gone — closed by the relay, by our side, or by the
    /// network. The clients that came through it are dead with it; `cr` is
    /// still allocated here, but nothing more can be sent over it.
    on_closed: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
};

/// One request to the relay, as `session.zig` wants to see it. Never
/// referenced through `Callback`: the host only needs the ctx.
pub const CloudRelay = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    ws: ?*ws_client.Ws = null,
    /// `sha256_hex(token)`: what the relay keys the tunnel by.
    token_hash: []const u8 = "",
    cb: Callback = .{},
    /// The protocol the relay settled on. 2 unless it answered otherwise.
    proto: u8 = 2,
    closed: bool = false,

    /// Connects to `wss://host:port/agent?th=sha256_hex(token)` and registers.
    /// Nothing is read until `start`, so the caller may still move the result.
    pub fn connect(
        gpa: std.mem.Allocator,
        io: std.Io,
        host: []const u8,
        port: u16,
        token: []const u8,
        trust: ws_client.Trust,
        cb: Callback,
    ) !*CloudRelay {
        const self = try gpa.create(CloudRelay);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .io = io, .cb = cb };

        const th = try sha256Hex(gpa, token);
        errdefer gpa.free(th);
        self.token_hash = th;

        // A host that carries its own scheme (``ws://127.0.0.1:8787``) is used
        // as-is: that is how a relay running in plaintext, such as a local
        // ``wrangler dev``, is reached. Otherwise the tunnel is WSS.
        var url_buf: [512]u8 = undefined;
        const url = if (std.mem.startsWith(u8, host, "ws://") or std.mem.startsWith(u8, host, "wss://"))
            try std.fmt.bufPrint(&url_buf, "{s}/agent?th={s}", .{ host, th })
        else
            try std.fmt.bufPrint(&url_buf, "wss://{s}:{d}/agent?th={s}", .{ host, port, th });

        const ws = try gpa.create(ws_client.Ws);
        errdefer gpa.destroy(ws);
        ws.* = try ws_client.Ws.connectWith(gpa, io, url, trust);
        self.ws = ws;

        var reg_buf: [256]u8 = undefined;
        const reg = try std.fmt.bufPrint(
            &reg_buf,
            "{{\"t\":\"register\",\"tokenHash\":\"{s}\",\"name\":\"nanoterm\",\"proto\":2}}",
            .{th},
        );
        _ = ws.sendText(reg);
        return self;
    }

    /// Watches the socket. Call once the pointer sits where it will stay.
    pub fn start(cr: *CloudRelay) !void {
        const ws = cr.ws orelse return error.NotConnected;
        ws.onMessage = &onMessage;
        ws.onClosed = &onClosed;
        ws.ctx = @ptrCast(cr);
        try ws.start();
    }

    pub fn deinit(cr: *CloudRelay) void {
        // Senders and the close path both watch this: freeing the tunnel must
        // not leave a frame half-written to it, nor a callback into a host
        // that is about to forget it.
        cr.closed = true;
        cr.cb.on_closed = null;
        cr.cb.on_hreq = null;
        cr.cb.on_wopen = null;
        cr.cb.on_wmsg = null;
        cr.cb.on_wclose = null;
        if (cr.ws) |ws| {
            ws.close(1000, "");
            ws.deinit();
            cr.gpa.destroy(ws);
            cr.ws = null;
        }
        if (cr.token_hash.len > 0) cr.gpa.free(cr.token_hash);
        cr.gpa.destroy(cr);
    }

    /// Send `{t:'hres', id, status, headers}`. `headers` is a JSON object,
    /// already encoded by the caller.
    pub fn sendHres(cr: *CloudRelay, id: []const u8, status: u16, headers: []const u8) void {
        var id_buf: [512]u8 = undefined;
        const idj = jsonEscape(&id_buf, id) orelse return;
        cr.sendJson("{{\"t\":\"hres\",\"id\":\"{s}\",\"status\":{d},\"headers\":{s}}}", .{
            idj, status, headers,
        });
    }

    /// Send `{t:'hchunk', id, b:<base64>}`: response body bytes.
    pub fn sendHchunk(cr: *CloudRelay, id: []const u8, data: []const u8) void {
        if (data.len == 0) return;
        const enc_len = b64.calcSize(data.len);
        const buf = cr.gpa.alloc(u8, enc_len + id.len + 96) catch return;
        defer cr.gpa.free(buf);

        var id_buf: [512]u8 = undefined;
        const idj = jsonEscape(&id_buf, id) orelse return;

        var w = std.Io.Writer.fixed(buf);
        w.print("{{\"t\":\"hchunk\",\"id\":\"{s}\",\"b\":\"", .{idj}) catch return;
        const encoded = b64.encode(buf[w.end..][0..enc_len], data);
        w.writeAll(encoded) catch return;
        w.writeAll("\"}") catch return;

        _ = (cr.ws orelse return).sendText(buf[0..w.end]);
    }

    /// Send `{t:'hend', id}`: the response is complete.
    pub fn sendHend(cr: *CloudRelay, id: []const u8) void {
        var id_buf: [512]u8 = undefined;
        const idj = jsonEscape(&id_buf, id) orelse return;
        cr.sendJson("{{\"t\":\"hend\",\"id\":\"{s}\"}}", .{idj});
    }

    /// Send `{t:'herr', id, message}`: the request failed.
    pub fn sendHerr(cr: *CloudRelay, id: []const u8, message: []const u8) void {
        var id_buf: [512]u8 = undefined;
        const idj = jsonEscape(&id_buf, id) orelse return;
        var msg_buf: [512]u8 = undefined;
        const msg = jsonEscape(&msg_buf, message) orelse "the message was too long to send";
        cr.sendJson("{{\"t\":\"herr\",\"id\":\"{s}\",\"message\":\"{s}\"}}", .{ idj, msg });
    }

    /// `hack`: the relay may send more request body bytes for `id`.
    fn sendHack(cr: *CloudRelay, id: []const u8, n: usize) void {
        var id_buf: [512]u8 = undefined;
        const idj = jsonEscape(&id_buf, id) orelse return;
        cr.sendJson("{{\"t\":\"hack\",\"id\":\"{s}\",\"n\":{d}}}", .{ idj, n });
    }

    /// Send `{t:'wopened', id}`: the socket the phone asked for is open.
    pub fn sendWopened(cr: *CloudRelay, id: []const u8) void {
        var id_buf: [512]u8 = undefined;
        const idj = jsonEscape(&id_buf, id) orelse return;
        cr.sendJson("{{\"t\":\"wopened\",\"id\":\"{s}\"}}", .{idj});
    }

    /// Send `{t:'werr', id, message}`: the socket could not be opened.
    pub fn sendWerr(cr: *CloudRelay, id: []const u8, message: []const u8) void {
        var id_buf: [512]u8 = undefined;
        const idj = jsonEscape(&id_buf, id) orelse return;
        var msg_buf: [512]u8 = undefined;
        const msg = jsonEscape(&msg_buf, message) orelse "the message was too long to send";
        cr.sendJson("{{\"t\":\"werr\",\"id\":\"{s}\",\"message\":\"{s}\"}}", .{ idj, msg });
    }

    /// Send `{t:'wclose', id}`: the host closed the socket.
    pub fn sendWclose(cr: *CloudRelay, id: []const u8) void {
        var id_buf: [512]u8 = undefined;
        const idj = jsonEscape(&id_buf, id) orelse return;
        cr.sendJson("{{\"t\":\"wclose\",\"id\":\"{s}\"}}", .{idj});
    }

    /// Bytes for the phone, as a WBIN frame: `[3][idLen][id][payload]`.
    ///
    /// The payload is relay line protocol — a block's output carries quotes
    /// and backslashes that JSON fields would have to escape — so it travels
    /// opaque rather than as a `wmsg` string the relay would re-encode.
    /// Answers false when the tunnel is gone.
    pub fn sendWmsg(cr: *CloudRelay, id: []const u8, bytes: []const u8) bool {
        const ws = cr.ws orelse return false;
        if (cr.closed) return false;
        if (id.len > 255) return false;
        const buf = cr.gpa.alloc(u8, 2 + id.len + bytes.len) catch return false;
        defer cr.gpa.free(buf);
        buf[0] = 3;
        buf[1] = @intCast(id.len);
        @memcpy(buf[2..][0..id.len], id);
        @memcpy(buf[2 + id.len ..], bytes);
        return ws.sendBinary(buf);
    }

    /// Copy `s` into `out` as the inside of a JSON string. The relay picks the
    /// ids that come back to us, so a quote or a backslash in one must not be
    /// able to break (or forge) the frame we build around it.
    fn jsonEscape(out: []u8, s: []const u8) ?[]const u8 {
        var w = std.Io.Writer.fixed(out);
        for (s) |ch| switch (ch) {
            '"' => w.writeAll("\\\"") catch return null,
            '\\' => w.writeAll("\\\\") catch return null,
            '\n' => w.writeAll("\\n") catch return null,
            '\r' => w.writeAll("\\r") catch return null,
            '\t' => w.writeAll("\\t") catch return null,
            0...8, 11...12, 14...0x1f => w.print("\\u{x:0>4}", .{ch}) catch return null,
            else => w.writeByte(ch) catch return null,
        };
        return out[0..w.end];
    }

    fn sendJson(cr: *CloudRelay, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        const ws = cr.ws orelse return;
        if (cr.closed) return;
        _ = ws.sendText(text);
    }

    /// One text frame from the relay.
    fn handleJson(cr: *CloudRelay, text: []const u8) void {
        const Frame = struct {
            t: []const u8 = "",
            id: []const u8 = "",
            proto: u8 = 0,
            method: []const u8 = "",
            path: []const u8 = "",
            b: []const u8 = "",
            s: []const u8 = "",
            message: []const u8 = "",
        };
        var arena = std.heap.ArenaAllocator.init(cr.gpa);
        defer arena.deinit();
        const gpa = arena.allocator();

        const m = std.json.parseFromSliceLeaky(Frame, gpa, text, .{
            .ignore_unknown_fields = true,
        }) catch {
            // The frame is the relay's, not a log line: printing it would let a
            // peer inject terminal escapes, and 200 bytes of it say little.
            std.log.warn("cloud: unreadable frame ({d} bytes)", .{text.len});
            return;
        };

        if (std.mem.eql(u8, m.t, "registered")) {
            if (m.proto > 0) cr.proto = m.proto;
            std.log.info("cloud: registered with the relay (proto {d})", .{cr.proto});
            return;
        }
        if (std.mem.eql(u8, m.t, "error")) {
            std.log.err("cloud: the relay refused us: {s}", .{m.message});
            return;
        }
        if (std.mem.eql(u8, m.t, "hreq")) {
            cr.handleHreq(gpa, m.id, m.method, m.path, m.b);
            return;
        }
        if (std.mem.eql(u8, m.t, "wopen")) {
            const cb = cr.cb.on_wopen orelse {
                cr.sendWerr(m.id, "the host has no websocket handler");
                return;
            };
            cb(cr, m.id, m.path) catch |err| {
                var ebuf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&ebuf, "host error: {s}", .{@errorName(err)}) catch "host error";
                cr.sendWerr(m.id, msg);
            };
            return;
        }
        if (std.mem.eql(u8, m.t, "wmsg")) {
            if (cr.cb.on_wmsg) |cb| cb(cr, m.id, m.s);
            return;
        }
        if (std.mem.eql(u8, m.t, "wclose")) {
            if (cr.cb.on_wclose) |cb| cb(cr, m.id);
            return;
        }
        // hcancel: the phone gave up on a request we already answered.
        // ack is protocol 3 credit; we do not hold any back.
    }

    /// `{t:'hreq', id, method, path, headers, b?}`. `b` is base64 in protocol 1;
    /// in protocol 2 the body may also arrive as HBODY frames, which we do not
    /// buffer — every route here is a GET, so there is nothing to collect.
    fn handleHreq(
        cr: *CloudRelay,
        gpa: std.mem.Allocator,
        id: []const u8,
        method: []const u8,
        path: []const u8,
        b: []const u8,
    ) void {
        var body: []const u8 = "";
        if (b.len > 0) {
            const len = std.base64.standard.Decoder.calcSizeForSlice(b) catch 0;
            if (len > 0) {
                const decoded = gpa.alloc(u8, len) catch return;
                if (std.base64.standard.Decoder.decode(decoded, b)) |_| {
                    body = decoded;
                } else |_| {}
            }
        }

        const f = cr.cb.on_hreq orelse {
            cr.sendHerr(id, "no host handler");
            return;
        };
        f(cr, id, method, path, body) catch |err| {
            var msg_buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "host error: {s}", .{@errorName(err)}) catch "host error";
            cr.sendHerr(id, msg);
            return;
        };
        cr.sendHack(id, 0);
    }

    fn onMessage(ctx: ?*anyopaque, frame: ws_client.Frame) void {
        const cr: *CloudRelay = @ptrCast(@alignCast(ctx));
        switch (frame) {
            .text => |text| cr.handleJson(text),
            .binary => |payload| {
                // Protocol 2: [kind:u8][idLen:u8][id][payload].
                if (payload.len < 2) return;
                const kind = payload[0];
                const id_len = @as(usize, payload[1]);
                if (payload.len < 2 + id_len) return;
                switch (kind) {
                    // 3 WBIN, 4 WTEXT: the phone's bytes for a socket we
                    // opened. Both are the relay's line protocol on top.
                    3, 4 => {
                        const id = payload[2 .. 2 + id_len];
                        const data = payload[2 + id_len ..];
                        if (cr.cb.on_wmsg) |cb| cb(cr, id, data);
                    },
                    // 1 HCHUNK, 2 HBODY: request bodies. Every route reads
                    // its body from the `hreq` frame itself, so there is
                    // nothing to collect here.
                    else => return,
                }
            },
            .close => |c| {
                std.log.info("cloud: relay closed the tunnel ({d} {s})", .{ c.code, c.reason });
                cr.finish();
            },
            .ping, .pong => {},
        }
    }

    fn onClosed(ctx: ?*anyopaque, code: u16, reason: []const u8) void {
        const cr: *CloudRelay = @ptrCast(@alignCast(ctx));
        std.log.info("cloud: relay connection closed ({d} {s})", .{ code, reason });
        cr.finish();
    }

    /// The tunnel ended, once: the host hears about it so it can drop the
    /// clients the tunnel was carrying, which are unreachable from here on.
    fn finish(cr: *CloudRelay) void {
        if (cr.closed) return;
        cr.closed = true;
        if (cr.cb.on_closed) |f| f(cr.cb.ctx);
    }
};

/// `sha256_hex(token)`, allocated with `gpa`: what the relay keys by.
fn sha256Hex(gpa: std.mem.Allocator, token: []const u8) ![]const u8 {
    var hash: [32]u8 = undefined;
    var h = sha256_mod.Sha256.init(.{});
    h.update(token);
    h.final(&hash);

    const hex = try gpa.alloc(u8, 64);
    for (hash, 0..) |byte, i| {
        hex[i * 2] = hexDigit(byte >> 4);
        hex[i * 2 + 1] = hexDigit(byte & 0x0f);
    }
    return hex;
}

fn hexDigit(nibble: u8) u8 {
    return if (nibble < 10) '0' + nibble else 'a' + nibble - 10;
}

test "an id the relay chose cannot break the frame it goes into" {
    var buf: [64]u8 = undefined;
    const out = CloudRelay.jsonEscape(&buf, "a\"b\\c\n\td") orelse return error.TooLong;
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\n\\td", out);
    // Too small for the escaped form: no half-written id ever reaches a frame.
    var small: [3]u8 = undefined;
    try std.testing.expect(CloudRelay.jsonEscape(&small, "\"\"\"") == null);
}

test "sha256Hex matches the token" {
    const gpa = std.testing.allocator;
    const hex = try sha256Hex(gpa, "abc");
    defer gpa.free(hex);
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        hex,
    );
}
