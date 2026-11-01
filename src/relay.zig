//! The relay: what a phone shows of this machine's sessions, and the way
//! back to them. A client connects to 127.0.0.1 — a tunnel (Tailscale, or
//! `ssh -L`) puts that on the network — says hello with the token the
//! relay started with, and is then sent one event per change: a block's
//! command and its output, a turn's items, a permission question waiting
//! for an answer. It sends back what the user does with them (`run`,
//! `ask`, `interrupt`, `answer`), and the session does it, on the main
//! thread, as if the keys were pressed here.
//!
//! Nothing polls. The listening socket is watched with `fdwatch`, as
//! visual_host.zig watches its own, and the timeline is looked at once per
//! frame at most: a change is compared against what was last sent, so an
//! event goes out only for what is new.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const fdwatch = nanoui.fdwatch;
const blocks = @import("blocks.zig");
const vt = @import("vt.zig");
const session_mod = @import("session.zig");
const agent_mod = @import("agent.zig");

/// The protocol's version; a field in `welcome` and in `hello`.
pub const protocol = 1;
pub const default_port: u16 = 4789;

/// A command from the phone: several, in one read.
const max_line = 64 * 1024;
/// A block's output in one event: its last lines. The phone is small.
const max_output = 8 * 1024;
/// A turn's text in one event, before it is cut.
const max_text = 64 * 1024;
/// How often the timeline is looked at, at most, in seconds.
const min_interval = 0.05;
/// A client that cannot take an event is dropped: it reconnects with the
/// `seq` it last saw, and `hello` sends it everything again.
const max_waiting = 4 * max_line;

const windows = builtin.os.tag == .windows;
const NoSockets = struct {
    fn accept(_: c_int, _: ?*anyopaque, _: ?*c_uint) c_int {
        return -1;
    }
    fn read(_: c_int, _: [*]u8, _: usize) isize {
        return -1;
    }
    fn write(_: c_int, _: [*]const u8, _: usize) isize {
        return -1;
    }
    fn close(_: c_int) c_int {
        return -1;
    }
    fn fcntl(_: c_int, _: c_int, ...) c_int {
        return -1;
    }
};
const sys = if (windows) NoSockets else struct {
    extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*c_uint) c_int;
    extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
    extern "c" fn write(fd: c_int, buf: [*]const u8, n: usize) isize;
    extern "c" fn close(fd: c_int) c_int;
    extern "c" fn fcntl(fd: c_int, cmd: c_int, ...) c_int;
};

const F_SETFL = 4;
const O_NONBLOCK = if (builtin.os.tag == .linux) 0o4000 else 0x4;

/// Where the listening socket binds: only this machine (the default for
/// `--relay`), every address on the LAN, or every address including the
/// Tailscale one (Settings picks; both listen on everything, and what
/// differs is the address the phone is told to reach).
pub const Bind = enum {
    loopback,
    lan,
    tailscale,
};

/// What an entry looked like when it was last sent: `id` it went out
/// under, and the digest of its content then.
const Slot = struct { id: u64, digest: u64 };

pub const Options = struct {
    port: u16 = default_port,
    /// Which addresses to listen on; `.loopback` is only this machine.
    mode: Bind = .loopback,
    /// The token a client must say hello with: 32 hex characters. Empty
    /// means read `token_path`, and make one if there is none there.
    token: []const u8 = "",
    /// Where the token is kept between runs (empty: not kept).
    token_path: []const u8 = "",
};

/// The socket's address for a port and a mode: 127.0.0.1, or 0.0.0.0 for
/// anything reachable over a network.
fn bindAddress(port: u16, mode: Bind) std.Io.net.IpAddress {
    if (mode == .loopback) return .{ .ip4 = std.Io.net.Ip4Address.loopback(port) };
    return .{ .ip4 = .{ .port = port, .bytes = .{ 0, 0, 0, 0 } } };
}

pub const Hub = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    token: [32]u8,
    server: std.Io.net.Server,
    mode: Bind = .loopback,
    /// Where a phone in the same place reaches it: the LAN address for a
    /// LAN relay, the Tailscale one for that. Empty when there is none.
    lan: []const u8 = "",
    ts: []const u8 = "",
    watch: ?fdwatch.Watch = null,
    conns: std.ArrayList(*Conn) = .empty,
    sessions: std.ArrayList(*session_mod.Session) = .empty,
    slots: std.AutoHashMapUnmanaged(*const anyopaque, Slot) = .empty,
    /// The event being made; `send` hands it to every client that can take it.
    out: std.ArrayList(u8) = .empty,
    /// A block's output, joined, before it is escaped into an event.
    scratch: std.ArrayList(u8) = .empty,
    next_id: u64 = 1,
    seq: u64 = 0,
    last_pump: f64 = 0,
    pending: bool = false,

    /// The port listened on: `options.port`, or the one the system chose
    /// when it was 0.
    pub fn port(h: *const Hub) u16 {
        return std.Io.net.IpAddress.getPort(h.server.socket.address);
    }

    /// Starts listening. Nothing is read until a client connects, and no
    /// session is shown until `attach`.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, options: Options) !*Hub {
        if (windows) return error.Unsupported;
        const h = try gpa.create(Hub);
        errdefer gpa.destroy(h);
        const token = try tokenFor(io, options);
        const address: std.Io.net.IpAddress = bindAddress(options.port, options.mode);
        h.* = .{
            .gpa = gpa,
            .io = io,
            .token = token,
            .mode = options.mode,
            .server = undefined,
        };
        h.server = try std.Io.net.IpAddress.listen(&address, io, .{ .reuse_address = true });
        errdefer h.server.deinit(io);
        h.watch = fdwatch.readable(h.server.socket.handle, h, onAccept) catch |err| {
            std.log.warn("relay: the listening socket cannot be watched: {s}", .{@errorName(err)});
            return err;
        };
        h.setAddresses();
        return h;
    }

    /// Starts listening again, on another port or another set of
    /// addresses; the sessions and their clients stay attached, and the
    /// token is kept (the phone already has it).
    pub fn rebind(h: *Hub, io: std.Io, options: Options) !void {
        if (windows) return error.Unsupported;
        if (h.watch) |w| w.cancel();
        h.watch = null;
        h.server.deinit(io);
        const address: std.Io.net.IpAddress = bindAddress(options.port, options.mode);
        h.server = try std.Io.net.IpAddress.listen(&address, io, .{ .reuse_address = true });
        errdefer h.server.deinit(io);
        h.mode = options.mode;
        h.watch = fdwatch.readable(h.server.socket.handle, h, onAccept) catch |err| {
            std.log.warn("relay: the listening socket cannot be watched: {s}", .{@errorName(err)});
            return err;
        };
        h.setAddresses();
    }

    /// The addresses a phone has to be told, found once when the relay
    /// starts listening.
    fn setAddresses(h: *Hub) void {
        // The helpers return a dupe, or the empty literal when there is no
        // such address — so only a non-empty one is owned.
        const lan = lanAddress(h.gpa, h.io);
        if (lan.len > 0) {
            if (h.lan.len > 0) h.gpa.free(h.lan);
            h.lan = lan;
        }
        const ts = tailscaleAddress(h.gpa, h.io);
        if (ts.len > 0) {
            if (h.ts.len > 0) h.gpa.free(h.ts);
            h.ts = ts;
        }
    }

    /// The token as the phone must say it: the 32 hex characters it holds.
    pub fn tokenHex(h: *const Hub) []const u8 {
        return h.token[0..];
    }

    /// Where the token is kept between runs.
    pub fn tokenPath(gpa: std.mem.Allocator, home: []const u8) []const u8 {
        const p = std.fs.path.join(gpa, &.{ home, "Library", "Application Support", "nanoterm", "relay-token" }) catch return gpa.dupe(u8, "") catch "";
        defer gpa.free(p);
        return gpa.dupe(u8, p) catch gpa.dupe(u8, "") catch "";
    }

    pub fn destroy(h: *Hub) void {
        while (h.conns.items.len > 0) h.drop(h.conns.items[h.conns.items.len - 1]);
        if (h.watch) |w| w.cancel();
        if (h.lan.len > 0) h.gpa.free(h.lan);
        if (h.ts.len > 0) h.gpa.free(h.ts);
        h.server.deinit(h.io);
        h.slots.deinit(h.gpa);
        h.out.deinit(h.gpa);
        h.scratch.deinit(h.gpa);
        h.sessions.deinit(h.gpa);
        h.conns.deinit(h.gpa);
        h.gpa.destroy(h);
    }

    /// A session the phone may see, with whatever it already holds: a tab
    /// made before the relay started shows up whole.
    pub fn attach(h: *Hub, s: *session_mod.Session) void {
        if (!windows) h.sessions.append(h.gpa, s) catch return;
        h.pump(s);
    }

    /// A session the phone may no longer see, before it is freed.
    pub fn detach(h: *Hub, s: *session_mod.Session) void {
        var gone = false;
        for (h.sessions.items, 0..) |x, i| {
            if (x == s) {
                _ = h.sessions.swapRemove(i);
                gone = true;
                break;
            }
        }
        for (s.timeline.items) |e| _ = h.slots.remove(entryKey(e));
        // A tab closed here leaves the phone's list too, rather than
        // staying on it showing what it last showed.
        if (gone and h.conns.items.len > 0) {
            var aw: std.Io.Writer.Allocating = .init(h.gpa);
            defer aw.deinit();
            h.begin(&aw, "gone");
            aw.writer.print(",\"id\":{d}", .{s.id}) catch {};
            aw.writer.writeByte('}') catch {};
            h.finish(&aw, null);
        }
    }

    /// Called when `s` changed: its timeline is sent, at most every
    /// `min_interval`; what is left waits for `tick`, in the next frame.
    pub fn touched(h: *Hub, s: *session_mod.Session) void {
        if (h.conns.items.len == 0) {
            h.pending = false;
            return;
        }
        const now = blocks.now();
        if (now - h.last_pump < min_interval) {
            h.pending = true;
            return;
        }
        h.pending = false;
        h.last_pump = now;
        h.pump(s);
    }

    /// Sends what a change in the last `min_interval` held back. The frame
    /// after a change always comes, so nothing waits for another one.
    pub fn tick(h: *Hub) void {
        if (!h.pending) return;
        if (h.conns.items.len == 0) {
            h.pending = false;
            return;
        }
        const now = blocks.now();
        if (now - h.last_pump < min_interval) return;
        h.pending = false;
        h.last_pump = now;
        for (h.sessions.items) |s| h.pump(s);
    }

    /// Every entry of `s`, each event going out only if it is new or
    /// different from what went out before.
    fn pump(h: *Hub, s: *session_mod.Session) void {
        for (s.timeline.items) |e| h.emit(s, e);
    }

    fn emit(h: *Hub, s: *session_mod.Session, e: session_mod.Entry) void {
        const key = entryKey(e);
        const digest = entryDigest(e);
        if (h.slots.get(key)) |slot| {
            if (slot.digest == digest) return;
            // Debug: turn digest changed, will re-emit
            if (e == .turn) {
                const t = e.turn;
                std.debug.print("relay: turn {d} digest changed (items: {d}, done: {}), re-emitting\n", .{ slot.id, t.items.items.len, t.done });
            }
            h.slots.put(h.gpa, key, .{ .id = slot.id, .digest = digest }) catch return;
            h.sendEntry(null, s, slot.id, e);
            return;
        }
        const id = h.next_id;
        h.next_id += 1;
        // Debug: new turn emitted
        if (e == .turn) {
            const t = e.turn;
            std.debug.print("relay: new turn {d} emitted (items: {d}, done: {})\n", .{ id, t.items.items.len, t.done });
        }
        h.slots.put(h.gpa, key, .{ .id = id, .digest = digest }) catch return;
        h.sendEntry(null, s, id, e);
    }

    /// A new client's view: the tabs, then everything in them.
    fn welcome(h: *Hub, c: *Conn) void {
        {
            var aw: std.Io.Writer.Allocating = .init(h.gpa);
            defer aw.deinit();
            h.begin(&aw, "welcome");
            const w = &aw.writer;
            w.print(",\"protocol\":{d},\"port\":{d},\"sessions\":[", .{ protocol, h.port() }) catch {};
            for (h.sessions.items, 0..) |s, i| {
                if (i > 0) w.writeByte(',') catch {};
                w.print("{d}", .{s.id}) catch {};
            }
            w.writeAll("]}") catch {};
            h.finish(&aw, c);
        }
        for (h.sessions.items) |s| {
            h.sendSession(c, s);
            for (s.timeline.items) |e| {
                const id = h.idFor(e);
                h.sendEntry(c, s, id, e);
            }
        }
    }

    /// The entry's id, made if this client is the first to see it.
    fn idFor(h: *Hub, e: session_mod.Entry) u64 {
        const key = entryKey(e);
        if (h.slots.get(key)) |slot| return slot.id;
        const id = h.next_id;
        h.next_id += 1;
        h.slots.put(h.gpa, key, .{ .id = id, .digest = entryDigest(e) }) catch {};
        return id;
    }

    fn sendSession(h: *Hub, c: *Conn, s: *session_mod.Session) void {
        var aw: std.Io.Writer.Allocating = .init(h.gpa);
        defer aw.deinit();
        h.begin(&aw, "session");
        const w = &aw.writer;
        w.print(",\"id\":{d},\"title\":", .{s.id}) catch {};
        json(w, s.title());
        w.writeAll(",\"cwd\":") catch {};
        json(w, s.cwd());
        w.writeAll(",\"mode\":") catch {};
        json(w, @tagName(s.mode()));
        w.writeByte('}') catch {};
        h.finish(&aw, c);
    }

    fn sendEntry(h: *Hub, c: ?*Conn, s: *session_mod.Session, id: u64, e: session_mod.Entry) void {
        switch (e) {
            .block => |b| h.sendBlock(c, s, id, b),
            .turn => |t| h.sendTurn(c, s, id, t),
        }
    }

    fn sendBlock(h: *Hub, c: ?*Conn, s: *session_mod.Session, id: u64, b: *blocks.Block) void {
        var aw: std.Io.Writer.Allocating = .init(h.gpa);
        defer aw.deinit();
        h.begin(&aw, "block");
        const w = &aw.writer;
        w.print(",\"session\":{d},\"id\":{d},\"source\":", .{ s.id, id }) catch {};
        json(w, @tagName(b.source));
        w.writeAll(",\"command\":") catch {};
        json(w, b.command);
        w.writeAll(",\"cwd\":") catch {};
        json(w, b.cwd);
        w.writeAll(",\"branch\":") catch {};
        json(w, b.git_branch);
        w.writeAll(",\"state\":") catch {};
        json(w, @tagName(b.state));
        w.print(",\"exit\":{?d},\"started\":{d:.3},\"ended\":{d:.3},\"output\":", .{ b.exit_code, b.started, b.ended }) catch {};
        json(w, h.tail(&b.output));
        w.writeByte('}') catch {};
        h.finish(&aw, c);
    }

    fn sendTurn(h: *Hub, c: ?*Conn, s: *session_mod.Session, id: u64, t: *agent_mod.Turn) void {
        var aw: std.Io.Writer.Allocating = .init(h.gpa);
        defer aw.deinit();
        h.begin(&aw, "turn");
        const w = &aw.writer;
        w.print(",\"session\":{d},\"id\":{d},\"agent\":", .{ s.id, id }) catch {};
        json(w, t.agent.label());
        w.writeAll(",\"prompt\":") catch {};
        json(w, t.prompt);
        w.writeAll(",\"title\":") catch {};
        if (t.title) |title| json(w, title) else w.writeAll("null") catch {};
        w.print(",\"sent\":{},\"done\":{},\"items\":", .{ t.sent, t.done }) catch {};
        writeItems(w, t.items.items);
        w.writeByte('}') catch {};
        h.finish(&aw, c);
    }

    /// The first fields of every event: its place in the stream and what
    /// it is. No brace at the end: `finish` writes it.
    fn begin(h: *Hub, aw: *std.Io.Writer.Allocating, kind: []const u8) void {
        h.seq += 1;
        aw.writer.print("{{\"seq\":{d},\"kind\":", .{h.seq}) catch {};
        json(&aw.writer, kind);
    }

    fn finish(h: *Hub, aw: *std.Io.Writer.Allocating, c: ?*Conn) void {
        aw.writer.writeByte('\n') catch return;
        const bytes = aw.written();
        if (c) |conn| {
            if (!writeAll(conn.fd, bytes)) h.drop(conn);
        } else h.broadcast(bytes);
    }

    fn ack(h: *Hub, c: *Conn, op: []const u8) void {
        var aw: std.Io.Writer.Allocating = .init(h.gpa);
        defer aw.deinit();
        h.begin(&aw, "ack");
        aw.writer.writeAll(",\"op\":") catch {};
        json(&aw.writer, op);
        aw.writer.writeByte('}') catch {};
        h.finish(&aw, c);
    }

    fn refuse(h: *Hub, c: *Conn, message: []const u8) void {
        var aw: std.Io.Writer.Allocating = .init(h.gpa);
        defer aw.deinit();
        h.begin(&aw, "error");
        aw.writer.writeAll(",\"message\":") catch {};
        json(&aw.writer, message);
        aw.writer.writeByte('}') catch {};
        h.finish(&aw, c);
    }

    fn broadcast(h: *Hub, bytes: []const u8) void {
        var i = h.conns.items.len;
        while (i > 0) {
            i -= 1;
            const c = h.conns.items[i];
            if (!c.authed) continue;
            if (!writeAll(c.fd, bytes)) h.drop(c);
        }
    }

    fn drop(h: *Hub, c: *Conn) void {
        for (h.conns.items, 0..) |x, i| {
            if (x == c) {
                _ = h.conns.swapRemove(i);
                break;
            }
        }
        if (c.watch) |w| w.cancel();
        _ = sys.close(c.fd);
        c.in.deinit(h.gpa);
        h.gpa.destroy(c);
    }

    /// The session a command names, or null when the id is not one of ours.
    fn find(h: *Hub, id: u64) ?*session_mod.Session {
        for (h.sessions.items) |s| if (s.id == id) return s;
        return null;
    }

    /// The block's last lines, joined: as much of them as one event holds.
    fn tail(h: *Hub, o: *const vt.Output) []const u8 {
        h.scratch.clearRetainingCapacity();
        const lines = o.lines.items;
        if (lines.len == 0) return h.scratch.items;
        var total: usize = 0;
        var start = lines.len;
        while (start > 0) {
            const n = lines[start - 1].text.items.len + 1;
            if (total + n > max_output) break;
            total += n;
            start -= 1;
        }
        if (start == lines.len) {
            // One line, longer than an event holds: its end is what is new.
            h.scratch.appendSlice(h.gpa, tailOf(lines[lines.len - 1].text.items, max_output)) catch {};
            return h.scratch.items;
        }
        for (lines[start..], 0..) |l, i| {
            if (i > 0) h.scratch.append(h.gpa, '\n') catch break;
            h.scratch.appendSlice(h.gpa, l.text.items) catch break;
        }
        return h.scratch.items;
    }

    /// A line from a client: what it asks for, done here.
    fn command(h: *Hub, c: *Conn, line: []const u8) bool {
        if (line.len == 0) return true;
        var arena_state: std.heap.ArenaAllocator = .init(h.gpa);
        defer arena_state.deinit();
        const Msg = struct {
            op: []const u8 = "",
            token: []const u8 = "",
            session: u64 = 0,
            text: []const u8 = "",
            rpc: []const u8 = "",
            option: usize = 0,
        };
        const m = std.json.parseFromSliceLeaky(Msg, arena_state.allocator(), line, .{ .ignore_unknown_fields = true }) catch {
            h.refuse(c, "a command must be JSON: {\"op\":\"run\",\"session\":1,\"text\":\"ls\"}");
            return true;
        };
        if (std.mem.eql(u8, m.op, "hello")) {
            if (m.token.len != 32 or !std.crypto.timing_safe.eql([32]u8, m.token[0..32].*, h.token)) {
                h.refuse(c, "the token is not this relay's");
                return false;
            }
            c.authed = true;
            h.welcome(c);
            return true;
        }
        if (!c.authed) {
            h.refuse(c, "hello first, with the relay's token");
            return false;
        }
        if (std.mem.eql(u8, m.op, "list")) {
            h.welcome(c);
            return true;
        }
        const s = h.find(m.session) orelse {
            h.refuse(c, "no session with that id");
            return true;
        };
        if (std.mem.eql(u8, m.op, "run")) {
            if (m.text.len == 0) {
                h.refuse(c, "run needs text");
                return true;
            }
            s.run(m.text);
            h.ack(c, "run");
            return true;
        }
        if (std.mem.eql(u8, m.op, "ask")) {
            if (m.text.len == 0) {
                h.refuse(c, "ask needs text");
                return true;
            }
            s.ask(m.text);
            h.ack(c, "ask");
            return true;
        }
        if (std.mem.eql(u8, m.op, "interrupt")) {
            s.interrupt();
            h.ack(c, "interrupt");
            return true;
        }
        if (std.mem.eql(u8, m.op, "answer")) {
            const ag = s.agent orelse {
                h.refuse(c, "that session has no agent");
                return true;
            };
            const p = permissionOf(ag, m.rpc) orelse {
                h.refuse(c, "no permission question with that id");
                return true;
            };
            if (p.chosen != null) {
                h.refuse(c, "that question was already answered");
                return true;
            }
            if (m.option >= p.options.len) {
                h.refuse(c, "no such option");
                return true;
            }
            ag.answer(p, m.option);
            h.ack(c, "answer");
            return true;
        }
        h.refuse(c, "no such op");
        return true;
    }

    fn onAccept(ctx: ?*anyopaque) callconv(.c) void {
        const h: *Hub = @ptrCast(@alignCast(ctx));
        const fd = sys.accept(h.server.socket.handle, null, null);
        if (fd < 0) return;
        _ = sys.fcntl(fd, F_SETFL, @as(c_int, O_NONBLOCK));
        const c = h.gpa.create(Conn) catch {
            _ = sys.close(fd);
            return;
        };
        c.* = .{ .hub = h, .fd = fd };
        h.conns.append(h.gpa, c) catch {
            h.gpa.destroy(c);
            _ = sys.close(fd);
            return;
        };
        c.watch = fdwatch.readable(fd, c, onReadable) catch {
            h.drop(c);
            return;
        };
    }

    fn onReadable(ctx: ?*anyopaque) callconv(.c) void {
        const c: *Conn = @ptrCast(@alignCast(ctx));
        const h = c.hub;
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            const n = sys.read(c.fd, &chunk, chunk.len);
            if (n == 0) return h.drop(c);
            if (n < 0) break;
            c.in.appendSlice(h.gpa, chunk[0..@intCast(n)]) catch return h.drop(c);
            if (c.in.items.len > max_waiting) return h.drop(c);
        }
        // Whole lines, in the order they came; the rest waits.
        var used: usize = 0;
        var keep = true;
        while (std.mem.indexOfScalar(u8, c.in.items[used..], '\n')) |at| {
            const end = used + at;
            const line = std.mem.trim(u8, c.in.items[used..end], " \r\t");
            used = end + 1;
            if (line.len > max_line) {
                h.refuse(c, "a command is longer than the relay takes");
                keep = false;
                break;
            }
            if (!h.command(c, line)) {
                keep = false;
                break;
            }
        }
        if (used > 0) {
            const left = c.in.items.len - used;
            std.mem.copyForwards(u8, c.in.items[0..left], c.in.items[used..]);
            c.in.items.len = left;
        }
        if (!keep) h.drop(c);
    }
};

/// A client: its socket, and the bytes of a command that has not all come.
const Conn = struct {
    hub: *Hub,
    fd: c_int,
    watch: ?fdwatch.Watch = null,
    in: std.ArrayList(u8) = .empty,
    authed: bool = false,
};

fn tokenFor(io: std.Io, options: Options) ![32]u8 {
    if (options.token.len > 0) {
        if (options.token.len != 32) return error.BadToken;
        var out: [32]u8 = undefined;
        @memcpy(&out, options.token[0..32]);
        return out;
    }
    if (options.token_path.len > 0) {
        var buf: [64]u8 = undefined;
        if (std.Io.Dir.cwd().readFile(io, options.token_path, &buf)) |data| {
            const kept = std.mem.trim(u8, data, " \r\n");
            if (kept.len == 32) {
                var out: [32]u8 = undefined;
                @memcpy(&out, kept[0..32]);
                return out;
            }
        } else |_| {}
    }
    var rnd: [16]u8 = undefined;
    io.random(&rnd);
    var out: [32]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{rnd}) catch unreachable;
    if (options.token_path.len > 0) {
        if (std.fs.path.dirname(options.token_path)) |dir| std.Io.Dir.cwd().createDirPath(io, dir) catch {};
        // Only the user who started nanoterm reads it: the phone is shown
        // the same 32 characters on the terminal it was started from.
        const mode: std.Io.File.Permissions = if (windows) .default_file else @enumFromInt(0o600);
        std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = options.token_path,
            .data = &out,
            .flags = .{ .permissions = mode },
        }) catch {};
    }
    return out;
}

fn writeAll(fd: c_int, bytes: []const u8) bool {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = sys.write(fd, bytes.ptr + sent, bytes.len - sent);
        if (n <= 0) return false;
        sent += @intCast(n);
    }
    return true;
}

/// `s` as JSON writes it: quoted, with its quotes and control characters escaped.
fn json(w: *std.Io.Writer, s: []const u8) void {
    std.json.Stringify.value(s, .{}, w) catch {};
}

/// The first `max` bytes of `s`, cut at a character's edge.
fn clip(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xc0) == 0x80) n -= 1;
    return s[0..n];
}

/// The last `max` bytes of `s`, cut at a character's edge.
fn tailOf(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var i = s.len - max;
    while (i < s.len and (s[i] & 0xc0) == 0x80) i += 1;
    return s[i..];
}

fn writeItems(w: *std.Io.Writer, items: []const agent_mod.Item) void {
    w.writeByte('[') catch {};
    for (items, 0..) |item, i| {
        if (i > 0) w.writeByte(',') catch {};
        switch (item) {
            .text => |text| {
                w.writeAll("{\"kind\":\"text\",\"text\":") catch {};
                json(w, clip(text.items, max_text));
                w.writeByte('}') catch {};
            },
            .thought => |text| {
                w.writeAll("{\"kind\":\"thought\",\"text\":") catch {};
                json(w, clip(text.items, max_text));
                w.writeByte('}') catch {};
            },
            .tool => |tool| {
                w.writeAll("{\"kind\":\"tool\",\"id\":") catch {};
                json(w, tool.id);
                w.writeAll(",\"title\":") catch {};
                json(w, tool.title.items);
                w.writeAll(",\"status\":") catch {};
                json(w, @tagName(tool.status));
                w.writeAll(",\"detail\":") catch {};
                json(w, clip(tool.detail.items, max_text));
                if (tool.block) |b| w.print(",\"block\":{d}", .{b.id}) catch {};
                w.writeByte('}') catch {};
            },
            .plan => |entries| {
                w.writeAll("{\"kind\":\"plan\",\"entries\":[") catch {};
                for (entries.items, 0..) |e, j| {
                    if (j > 0) w.writeByte(',') catch {};
                    w.writeAll("{\"text\":") catch {};
                    json(w, e.text);
                    w.writeAll(",\"status\":") catch {};
                    json(w, e.status);
                    w.writeByte('}') catch {};
                }
                w.writeAll("]}") catch {};
            },
            .permission => |p| {
                w.writeAll("{\"kind\":\"permission\",\"rpc\":") catch {};
                json(w, p.rpc_id);
                w.writeAll(",\"title\":") catch {};
                json(w, p.title);
                w.writeAll(",\"options\":[") catch {};
                for (p.options, 0..) |o, j| {
                    if (j > 0) w.writeByte(',') catch {};
                    w.writeAll("{\"id\":") catch {};
                    json(w, o.id);
                    w.writeAll(",\"name\":") catch {};
                    json(w, o.name);
                    w.writeByte('}') catch {};
                }
                w.writeAll("],\"chosen\":") catch {};
                if (p.chosen) |chosen| w.print("{d}", .{chosen}) catch {} else w.writeAll("null") catch {};
                w.writeByte('}') catch {};
            },
            .command => |b| w.print("{{\"kind\":\"command\",\"block\":{d}}}", .{b.id}) catch {},
            .note => |note| {
                w.writeAll("{\"kind\":\"note\",\"text\":") catch {};
                json(w, clip(note, max_text));
                w.writeByte('}') catch {};
            },
            .visual => |shown| {
                w.writeAll("{\"kind\":\"visual\",\"title\":") catch {};
                json(w, shown.title);
                w.writeByte('}') catch {};
            },
        }
    }
    w.writeByte(']') catch {};
}

fn entryKey(e: session_mod.Entry) *const anyopaque {
    return switch (e) {
        .block => |b| b,
        .turn => |t| t,
    };
}

/// What the phone has to be told again about: the output it can see and
/// how the block ended, or the items a turn has now.
fn entryDigest(e: session_mod.Entry) u64 {
    var h = std.hash.Wyhash.init(0);
    switch (e) {
        .block => |b| {
            h.update(std.mem.asBytes(&b.state));
            h.update(std.mem.asBytes(&b.exit_code));
            const lines = b.output.lines.items;
            const count = lines.len;
            h.update(std.mem.asBytes(&count));
            var n = lines.len;
            var seen: usize = 0;
            while (n > 0 and seen < 2) : (seen += 1) {
                n -= 1;
                const length = lines[n].text.items.len;
                h.update(std.mem.asBytes(&length));
                h.update(tailOf(lines[n].text.items, 256));
            }
        },
        .turn => |t| {
            h.update(std.mem.asBytes(&t.done));
            h.update(std.mem.asBytes(&t.sent));
            if (t.title) |title| h.update(title);
            const count = t.items.items.len;
            h.update(std.mem.asBytes(&count));
            for (t.items.items) |item| digestItem(&h, item);
        },
    }
    return h.final();
}

fn digestItem(h: *std.hash.Wyhash, item: agent_mod.Item) void {
    switch (item) {
        .text => |text| {
            h.update("t");
            const length = text.items.len;
            h.update(std.mem.asBytes(&length));
            h.update(tailOf(text.items, 64));
        },
        .thought => |text| {
            h.update("k");
            const length = text.items.len;
            h.update(std.mem.asBytes(&length));
            h.update(tailOf(text.items, 64));
        },
        .tool => |tool| {
            h.update("T");
            h.update(tool.id);
            h.update(tool.title.items);
            h.update(@tagName(tool.status));
            h.update(tool.detail.items);
        },
        .plan => |entries| {
            h.update("P");
            for (entries.items) |e| {
                h.update(e.text);
                h.update(e.status);
            }
        },
        .permission => |p| {
            h.update("Q");
            h.update(p.rpc_id);
            if (p.chosen) |chosen| h.update(std.mem.asBytes(&chosen));
        },
        .command => |b| {
            h.update("C");
            h.update(std.mem.asBytes(&b.id));
        },
        .note => |note| {
            h.update("N");
            h.update(note);
        },
        .visual => |shown| {
            h.update("V");
            h.update(shown.title);
        },
    }
}

/// The permission question a turn still waits on, by the id the agent gave it.
fn permissionOf(ag: *agent_mod.Agent, rpc: []const u8) ?*agent_mod.Permission {
    var i = ag.turns.items.len;
    while (i > 0) {
        i -= 1;
        const items = ag.turns.items[i].items.items;
        var j = items.len;
        while (j > 0) {
            j -= 1;
            if (items[j] == .permission) {
                const p = &items[j].permission;
                if (std.mem.eql(u8, p.rpc_id, rpc)) return p;
            }
        }
    }
    return null;
}

/// The address this machine has on its own network: what the phone
/// types when it is on the same Wi-Fi. Empty when there is none to find.
pub fn lanAddress(gpa: std.mem.Allocator, io: std.Io) []const u8 {
    if (windows) return "";
    const argv: []const []const u8 = switch (builtin.os.tag) {
        .linux => &.{ "ip", "-4", "addr" },
        else => &.{ "ifconfig" },
    };
    return firstAddress(gpa, io, argv, inetAddress);
}

/// The Tailscale address, if this machine has one; empty when the CLI is
/// not installed or the network is not up.
pub fn tailscaleAddress(gpa: std.mem.Allocator, io: std.Io) []const u8 {
    if (windows) return "";
    return firstAddress(gpa, io, &.{ "tailscale", "ip", "-4" }, tokenAddress);
}

/// A command's output, one entry per line: the last line of what it printed.
fn output(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, out: *std.ArrayListUnmanaged([]const u8)) void {
    var child = std.process.spawn(io, .{ .argv = argv, .stdout = .pipe, .stderr = .inherit }) catch return;
    defer _ = child.wait(io) catch {};
    const file = child.stdout orelse return;
    var buffer: [16 * 1024]u8 = undefined;
    var reader = std.Io.File.Reader.init(file, io, buffer[0..]);
    var lines: std.ArrayListUnmanaged(u8) = .empty;
    defer lines.deinit(gpa);
    var chunk: [1][]u8 = .{ buffer[0..] };
    while (true) {
        const n = reader.interface.readVec(&chunk) catch break;
        if (n == 0) break;
        lines.appendSlice(gpa, buffer[0..n]) catch {};
        var i: usize = 0;
        while (i < lines.items.len) {
            if (lines.items[i] == '\n') {
                if (i > 0) out.append(gpa, gpa.dupe(u8, lines.items[0..i]) catch "") catch {};
                lines.items = lines.items[i + 1 ..];
                i = 0;
                continue;
            }
            i += 1;
        }
    }
    if (lines.items.len > 0) out.append(gpa, gpa.dupe(u8, lines.items) catch "") catch {};
}

/// The first address the command's output mentions.
fn firstAddress(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, comptime find: fn ([]const u8) ?[]const u8) []const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    defer lines.deinit(gpa);
    output(gpa, io, argv, &lines);
    for (lines.items) |line| {
        if (find(line)) |a| return gpa.dupe(u8, a) catch "";
    }
    return "";
}

/// An IPv4 address, four digits separated by three dots.
fn isIpv4(s: []const u8) bool {
    if (s.len < 7 or s.len > 15) return false;
    var parts: [4]usize = .{ 0, 0, 0, 0 };
    var n: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '.') {
            if (n >= 4 or i == s.len - 1) return false;
            n += 1;
        } else if (c >= '0' and c <= '9') {
            parts[n] = parts[n] * 10 + (c - '0');
            if (parts[n] > 255) return false;
        } else {
            return false;
        }
    }
    return n == 3;
}

/// The address after "inet " — how `ifconfig` and `ip -4 addr` both
/// label an interface's address.
fn inetAddress(line: []const u8) ?[]const u8 {
    const marker = std.mem.indexOf(u8, line, "inet ") orelse return null;
    var rest = line[marker + "inet ".len..];
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    var token = rest[0..end];
    if (std.mem.indexOfScalar(u8, token, '/')) |_| token = token[0..std.mem.indexOfScalar(u8, token, '/').?];
    if (!isIpv4(token)) return null;
    if (std.mem.eql(u8, token, "127.0.0.1") or std.mem.eql(u8, token, "0.0.0.0")) return null;
    return token;
}

/// The first address anywhere on a line: the Tailscale CLI prints bare
/// addresses, one per line.
fn tokenAddress(line: []const u8) ?[]const u8 {
    var rest = line;
    while (rest.len > 0) {
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const token = rest[0..end];
        rest = if (end < rest.len) rest[end + 1..] else &.{};
        if (token.len == 0) continue;
        if (isIpv4(token) and !std.mem.eql(u8, token, "127.0.0.1") and !std.mem.eql(u8, token, "0.0.0.0")) return token;
    }
    return null;
}
