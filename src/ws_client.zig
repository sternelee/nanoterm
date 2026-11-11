//! A small WebSocket client (RFC 6455) on top of std.Io.net and
//! std.crypto.tls, driven by fdwatch on the main loop.
//!
//!   var ws_buf = try gpa.create(ws_client.Ws);
//!   ws_buf.* = try ws_client.Ws.connect(gpa, io, "wss://relay.example.com/agent?th=...");
//!   try ws_buf.start();          // registers the fdwatch on the final address
//!   ...
//!   ws_buf.sendText(json);
//!
//! Complete frames are delivered to `onMessage(frame)`; `sendText` /
//! `sendBinary` frame them back. A close frame ends the connection.
//! Nothing here is protocol-specific: it just carries frames.

const std = @import("std");
const crypto = std.crypto;
const tls_mod = crypto.tls;
const net = std.Io.net;
const Io = std.Io;
const fdwatch = @import("nanoui").fdwatch;

pub const Frame = union(enum) {
    text: []const u8,
    binary: []const u8,
    close: struct { code: u16, reason: []const u8 },
    ping: []const u8,
    pong: []const u8,
};

const min_buffer_len = tls_mod.Client.min_buffer_len;
const MaskBit = @as(u8, 1 << 7);

/// The most one message may occupy, reassembly included. A relay that sends
/// more than this is not one we want to serve.
const max_buffered = 8 * 1024 * 1024;

/// The `ca` field of the TLS client's options, named so a value can be built
/// before the options are.
const CaOpt = @FieldType(tls_mod.Client.Options, "ca");

/// How a `wss` peer's certificate is checked.
pub const Trust = enum {
    /// Against this machine's CA store; the default.
    system,
    /// Whatever the peer sends. Only for a relay behind something this machine
    /// cannot verify, or a phone without a CA store: the caller has to say so
    /// out loud, in the settings page or in the code.
    insecure,
};

/// A CA store, kept for as long as a connection needs it: the TLS client holds
/// pointers into it.
const Ca = struct {
    bundle: std.crypto.Certificate.Bundle,
    lock: std.Io.RwLock,
};

/// The TLS session plus the plaintext stream it exposes. Heap allocated so
/// its address (which the TLS client stores) stays stable for the whole
/// connection.
const TlsConn = struct {
    client: tls_mod.Client,
    sock_reader: net.Stream.Reader,
    sock_writer: net.Stream.Writer,
    read_buf: [min_buffer_len]u8,
    write_buf: [min_buffer_len]u8,
};

pub const Ws = struct {
    gpa: std.mem.Allocator,
    io: Io,
    fd: c_int,
    watch: ?fdwatch.Watch = null,
    tls: ?*TlsConn = null,

    /// Bytes read but not yet turned into complete frames.
    in: std.ArrayList(u8) = .empty,
    /// A message being reassembled, and the opcode it started with (0 when
    /// none is in flight).
    frag: std.ArrayList(u8) = .empty,
    frag_op: u8 = 0,
    /// The CA store a `wss` peer was checked against, when one was.
    ca: ?*Ca = null,
    closed: bool = false,
    /// Masking key for frames we send (clients mask; servers don't).
    mask: [4]u8 = undefined,

    /// Called on the main thread when a complete frame arrives.
    onMessage: ?*const fn (ctx: ?*anyopaque, frame: Frame) void = null,
    /// Called when the connection is gone (error or clean close).
    onClosed: ?*const fn (ctx: ?*anyopaque, code: u16, reason: []const u8) void = null,
    ctx: ?*anyopaque = null,

    /// Connect to `url` ("ws://host:port/path" or "wss://host:port/path"),
    /// verifying the peer against this machine's CA store. The returned value
    /// must be moved to its final address before `start`.
    pub fn connect(gpa: std.mem.Allocator, io: Io, url: []const u8) !Ws {
        return connectWith(gpa, io, url, .system);
    }

    /// As `connect`, with a say in how the peer is authenticated.
    pub fn connectWith(gpa: std.mem.Allocator, io: Io, url: []const u8, trust: Trust) !Ws {
        const parsed = try parseUrl(io, url);
        const stream = try net.IpAddress.connect(&parsed.addr, io, .{ .mode = .stream });

        var w: Ws = .{
            .gpa = gpa,
            .io = io,
            .fd = stream.socket.handle,
        };
        errdefer w.deinit();
        io.random(&w.mask);

        if (parsed.tls) {
            const tc = try gpa.create(TlsConn);
            tc.sock_reader = stream.reader(io, &tc.read_buf);
            tc.sock_writer = stream.writer(io, &tc.write_buf);
            // From here on `deinit` frees the session, so the error paths
            // below only have to return.
            w.tls = tc;

            const now = Io.Clock.real.now(io);
            var ca: CaOpt = .no_verification;
            switch (trust) {
                .system => {
                    const store = try gpa.create(Ca);
                    store.* = .{ .bundle = .empty, .lock = .init };
                    errdefer {
                        store.bundle.deinit(gpa);
                        gpa.destroy(store);
                    }
                    try store.bundle.rescan(gpa, io, now);
                    w.ca = store;
                    ca = .{ .bundle = .{
                        .gpa = gpa,
                        .io = io,
                        .lock = &store.lock,
                        .bundle = &store.bundle,
                    } };
                },
                .insecure => std.log.warn(
                    "ws: the certificate of {s} is not checked: the tunnel is encrypted but nobody vouches for the far end",
                    .{parsed.host},
                ),
            }

            var entropy: [tls_mod.Client.Options.entropy_len]u8 = undefined;
            io.random(&entropy);
            tc.client = tls_mod.Client.init(&tc.sock_reader.interface, &tc.sock_writer.interface, .{
                .host = .{ .explicit = parsed.host },
                .ca = ca,
                .write_buffer = &tc.write_buf,
                .read_buffer = &tc.read_buf,
                .entropy = &entropy,
                .realtime_now = now,
                // A peer that drops mid-record is gone, and that is all an
                // unverified peer could tell us anyway.
                .allow_truncation_attacks = trust == .insecure,
            }) catch |err| {
                std.log.warn("ws: tls handshake with {s} failed: {s}", .{ parsed.host, @errorName(err) });
                return err;
            };
        }

        try w.handshake(parsed);
        return w;
    }

    /// Register the socket with the event loop. Call this on the final
    /// address of the `Ws` (not on a temporary copy).
    pub fn start(w: *Ws) !void {
        w.watch = try fdwatch.readable(w.fd, w, onReadable);
    }

    fn handshake(w: *Ws, parsed: Url) !void {
        var key_buf: [24]u8 = undefined;
        const key = std.base64.standard.Encoder.encode(&key_buf, &w.mask);

        var req: [512]u8 = undefined;
        var host_buf: [192]u8 = undefined;
        const default_port = if (parsed.tls) @as(u16, 443) else 80;
        const host_hdr = if (parsed.port == default_port)
            try std.fmt.bufPrint(&host_buf, "{s}", .{parsed.host})
        else
            try std.fmt.bufPrint(&host_buf, "{s}:{d}", .{ parsed.host, parsed.port });
        const req_bytes = try std.fmt.bufPrint(
            &req,
            "GET {s} HTTP/1.1\r\nHost: {s}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
                "Sec-WebSocket-Key: {s}\r\nSec-WebSocket-Version: 13\r\n\r\n",
            .{ parsed.path, host_hdr, key },
        );
        try w.writeRaw(req_bytes);

        var rsp: [2048]u8 = undefined;
        var got: usize = 0;
        while (got < rsp.len) {
            const n = w.readRaw(rsp[got..]) catch break;
            if (n == 0) return error.BadUpgrade;
            got += n;
            const head_end = std.mem.indexOf(u8, rsp[0..got], "\r\n\r\n") orelse continue;
            if (!std.mem.startsWith(u8, rsp[0..got], "HTTP/1.1 101")) {
                std.log.warn("ws: upgrade refused: {s}", .{rsp[0..head_end]});
                return error.BadUpgrade;
            }
            const leftover = rsp[head_end + 4 .. got];
            if (leftover.len > 0) try w.in.appendSlice(w.gpa, leftover);
            return;
        }
        return error.BadUpgrade;
    }

    pub fn sendText(w: *Ws, text: []const u8) bool {
        return w.sendFrame(0x1, text);
    }

    pub fn sendBinary(w: *Ws, payload: []const u8) bool {
        return w.sendFrame(0x2, payload);
    }

    pub fn sendPong(w: *Ws, payload: []const u8) bool {
        return w.sendFrame(0xa, payload);
    }

    /// Send a close frame, then drop the socket.
    pub fn close(w: *Ws, code: u16, reason: []const u8) void {
        if (w.closed) return;
        var payload: [2 + 123]u8 = undefined;
        std.mem.writeInt(u16, payload[0..2], code, .big);
        var pl: usize = 2;
        const n = @min(reason.len, payload.len - 2);
        @memcpy(payload[2..][0..n], reason[0..n]);
        pl += n;
        _ = w.sendFrame(0x8, payload[0..pl]);
        w.closed = true;
        w.shutdown();
    }

    pub fn deinit(w: *Ws) void {
        w.shutdown();
        if (w.tls) |tc| {
            w.gpa.destroy(tc);
            w.tls = null;
        }
        if (w.ca) |store| {
            store.bundle.deinit(w.gpa);
            w.gpa.destroy(store);
            w.ca = null;
        }
        w.in.deinit(w.gpa);
        w.frag.deinit(w.gpa);
    }

    fn shutdown(w: *Ws) void {
        if (w.watch) |watch| {
            watch.cancel();
            w.watch = null;
        }
        if (w.fd >= 0) {
            _ = sys.close(w.fd);
            w.fd = -1;
        }
    }

    /// Writes one frame. Returns false once the tunnel cannot take it: the
    /// caller drops the client then, rather than queueing forever.
    fn sendFrame(w: *Ws, opcode: u8, payload: []const u8) bool {
        if (w.closed or w.fd < 0) return false;

        var header: [14]u8 = undefined;
        header[0] = 0x80 | (opcode & 0x0f);
        var hlen: usize = 2;
        if (payload.len < 126) {
            header[1] = MaskBit | @as(u8, @intCast(payload.len));
        } else if (payload.len <= 0xffff) {
            header[1] = MaskBit | 126;
            std.mem.writeInt(u16, header[2..4], @intCast(payload.len), .big);
            hlen = 4;
        } else {
            header[1] = MaskBit | 127;
            std.mem.writeInt(u64, header[2..10], @intCast(payload.len), .big);
            hlen = 10;
        }
        @memcpy(header[hlen..][0..4], &w.mask);
        hlen += 4;
        w.writeRaw(header[0..hlen]) catch {
            w.closed = true;
            return false;
        };

        var off: usize = 0;
        var chunk: [4096]u8 = undefined;
        while (off < payload.len) {
            const n = @min(payload.len - off, chunk.len);
            for (0..n) |i| chunk[i] = payload[off + i] ^ w.mask[(off + i) % 4];
            w.writeRaw(chunk[0..n]) catch {
                w.closed = true;
                return false;
            };
            off += n;
        }
        return true;
    }

    /// Write plaintext bytes: TLS encrypts them, plain ws goes to the socket.
    fn writeRaw(w: *Ws, bytes: []const u8) !void {
        if (w.tls) |tc| {
            try tc.client.writer.writeAll(bytes);
            try tc.client.writer.flush();
            return;
        }
        if (w.fd < 0) return error.Closed;
        var written: usize = 0;
        while (written < bytes.len) {
            const n = sys.write(w.fd, bytes.ptr + written, bytes.len - written);
            if (n <= 0) return error.Closed;
            written += @intCast(n);
        }
    }

    /// Read plaintext bytes. `error.Eof` is the peer closing the connection,
    /// 0 is a read that has nothing for us yet.
    fn readRaw(w: *Ws, buf: []u8) !usize {
        if (buf.len == 0) return 0;
        if (w.tls) |tc| {
            // `readSliceShort` reports a closed stream as a short read, not
            // as an error of its own.
            const n = tc.client.reader.readSliceShort(buf) catch return error.ReadFailed;
            if (n == 0) return error.Eof;
            return n;
        }
        if (w.fd < 0) return error.Eof;
        const n = sys.read(w.fd, buf.ptr, buf.len);
        if (n == 0) return error.Eof;
        if (n < 0) return 0;
        return @intCast(n);
    }

    /// The connection cannot go on: say so once, then drop the socket.
    fn fail(w: *Ws, code: u16, reason: []const u8) void {
        if (w.closed) return;
        w.closed = true;
        w.shutdown();
        if (w.onClosed) |f| f(w.ctx, code, reason);
    }

    fn onReadable(ctx: ?*anyopaque) callconv(.c) void {
        const w: *Ws = @ptrCast(@alignCast(ctx orelse return));
        if (w.closed) return;
        var chunk: [16 * 1024]u8 = undefined;
        const n = w.readRaw(&chunk) catch |err| {
            if (err == error.Eof) w.fail(1006, "the far end closed the connection");
            return;
        };
        if (n == 0) return;
        if (w.in.items.len + n > max_buffered) {
            w.fail(1009, "a frame larger than this client buffers");
            return;
        }
        w.in.appendSlice(w.gpa, chunk[0..n]) catch {
            w.fail(1011, "out of memory");
            return;
        };
        w.drain();
    }

    /// Turn buffered bytes into complete frames and dispatch them. A message
    /// split over several frames is reassembled first: the callback sees one
    /// message either way.
    fn drain(w: *Ws) void {
        while (!w.closed) {
            const p = parseOne(w.in.items) orelse return;
            // `p.payload` points into `w.in`, which `consumeParsed` overwrites,
            // so everything that keeps bytes copies them before that.
            var more = true;
            switch (p.opcode) {
                0x9 => _ = w.sendPong(p.payload),
                0xa => {},
                0x8 => {
                    w.fail(
                        if (p.payload.len >= 2) std.mem.readInt(u16, p.payload[0..2], .big) else 1005,
                        if (p.payload.len > 2) p.payload[2..] else "",
                    );
                    more = false;
                },
                0x0, 0x1, 0x2 => {
                    if (p.opcode == 0x0) {
                        if (w.frag_op == 0) {
                            w.fail(1002, "a continuation frame with nothing to continue");
                            more = false;
                        }
                    } else if (w.frag_op != 0) {
                        w.fail(1002, "a new message inside an unfinished one");
                        more = false;
                    } else {
                        w.frag_op = p.opcode;
                        w.frag.clearRetainingCapacity();
                    }
                    if (more) {
                        if (w.frag.items.len + p.payload.len > max_buffered) {
                            w.fail(1009, "a message larger than this client buffers");
                            more = false;
                        } else if (w.frag.appendSlice(w.gpa, p.payload)) |_| {} else |_| {
                            w.fail(1011, "out of memory");
                            more = false;
                        }
                    }
                    if (more and p.fin) {
                        const opcode = w.frag_op;
                        w.frag_op = 0;
                        const frame: Frame = if (opcode == 0x1)
                            .{ .text = w.frag.items }
                        else
                            .{ .binary = w.frag.items };
                        // The callback reads the payload where it lies: the
                        // next message reuses the buffer, so copy what is kept.
                        if (w.onMessage) |f| f(w.ctx, frame);
                    }
                },
                else => {
                    w.fail(1002, "an unknown opcode");
                    more = false;
                },
            }
            if (!more) return;
            w.consumeParsed(p.total);
        }
    }

    fn consumeParsed(w: *Ws, total: usize) void {
        const rest = w.in.items.len - total;
        if (rest > 0) std.mem.copyForwards(u8, w.in.items[0..rest], w.in.items[total..]);
        w.in.shrinkRetainingCapacity(rest);
    }
};

/// One frame as it was read, before it is interpreted: the drain needs the
/// opcode and the FIN bit to know whether a message is complete.
const Parsed = struct {
    opcode: u8,
    fin: bool,
    payload: []u8,
    /// The whole frame, header and payload.
    total: usize,
};

test "a frame with a length the header cannot hold is refused, not read" {
    // 64-bit payload length far beyond what a usize can hold on a 32-bit
    // build, and already impossible here: it must not wrap into a small one.
    var buf = [_]u8{ 0x82, 127, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0 };
    try std.testing.expect(parseOne(&buf) == null);
}

test "a frame cut in half waits for the rest instead of reading past it" {
    var buf = [_]u8{ 0x81, 5, 'h', 'e', 'l' };
    try std.testing.expect(parseOne(&buf) == null);
}

test "a masked frame is unmasked and its payload is the text" {
    const key = [4]u8{ 1, 2, 3, 4 };
    const text = "hello";
    var buf: [2 + 4 + text.len]u8 = undefined;
    buf[0] = 0x81;
    buf[1] = 0x80 | text.len;
    @memcpy(buf[2..6], &key);
    for (text, 0..) |c, i| buf[6 + i] = c ^ key[i % 4];
    const p = parseOne(&buf) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, buf.len), p.total);
    try std.testing.expect(p.fin);
    try std.testing.expectEqual(@as(u8, 0x1), p.opcode);
    try std.testing.expectEqualStrings(text, p.payload);
}

test "the end of a message is what its FIN bit says, not its opcode" {
    var first = [_]u8{ 0x01, 0 };
    const a = parseOne(&first) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!a.fin);
    var last = [_]u8{ 0x80, 0 };
    const b = parseOne(&last) orelse return error.TestUnexpectedResult;
    try std.testing.expect(b.fin);
    try std.testing.expectEqual(@as(u8, 0x0), b.opcode);
}

/// Parse one frame out of `buf`, unmasking its payload in place. Returns null
/// when more bytes are needed.
fn parseOne(buf: []u8) ?Parsed {
    if (buf.len < 2) return null;
    const opcode = buf[0] & 0x0f;
    const fin = (buf[0] & 0x80) != 0;
    const masked = (buf[1] & 0x80) != 0;
    var len: u64 = buf[1] & 0x7f;
    var idx: usize = 2;
    if (len == 126) {
        if (buf.len < 4) return null;
        len = std.mem.readInt(u16, buf[2..4], .big);
        idx = 4;
    } else if (len == 127) {
        if (buf.len < 10) return null;
        len = std.mem.readInt(u64, buf[2..10], .big);
        idx = 10;
    }
    var mask_key: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        // `idx` is 2, 4 or 10 here, so this cannot overflow.
        if (buf.len < idx + 4) return null;
        @memcpy(&mask_key, buf[idx..][0..4]);
        idx += 4;
    }
    const payload_len: usize = std.math.cast(usize, len) orelse return null;
    // A declared length must fit the bytes we actually hold, so that neither
    // this sum nor the slice below can run past the buffer.
    const total = std.math.add(usize, idx, payload_len) catch return null;
    if (buf.len < total) return null;

    const payload = buf[idx..total];
    if (masked) {
        for (payload, 0..) |*byte, i| byte.* ^= mask_key[i % 4];
    }
    return .{ .opcode = opcode, .fin = fin, .payload = payload, .total = total };
}

const Url = struct {
    tls: bool,
    host: []const u8,
    port: u16,
    path: []const u8,
    addr: net.IpAddress,
};

fn parseUrl(io: Io, url: []const u8) !Url {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return error.BadUrl;
    const scheme = url[0..scheme_end];
    const rest = url[scheme_end + 3 ..];
    const is_tls = std.mem.eql(u8, scheme, "wss");
    if (!is_tls and !std.mem.eql(u8, scheme, "ws")) return error.BadUrl;

    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..path_start];
    const path = if (path_start < rest.len) rest[path_start..] else "/";
    if (authority.len == 0) return error.BadUrl;

    var host = authority;
    var port: u16 = if (is_tls) 443 else 80;
    if (authority[0] == '[') {
        const close_br = std.mem.indexOfScalar(u8, authority, ']') orelse return error.BadUrl;
        host = authority[1..close_br];
        if (close_br + 2 < authority.len and authority[close_br + 1] == ':') {
            port = std.fmt.parseInt(u16, authority[close_br + 2 ..], 10) catch return error.BadUrl;
        }
    } else if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return error.BadUrl;
    }
    if (host.len == 0) return error.BadUrl;

    const addr = try net.IpAddress.resolve(io, host, port);
    return .{ .tls = is_tls, .host = host, .port = port, .path = path, .addr = addr };
}

const sys = struct {
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
};
