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
const assist = @import("assist.zig");

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

/// One of a turn's items as the wire last carried it: its content's
/// digest, what it is, the parts that do not grow (a tool's id, title and
/// status), and how much of the text that does grow it had — with the
/// bytes at that edge, to know the next change is only more text.
const SentItem = struct {
    digest: u64,
    kind: u8,
    base: u64,
    len: usize = 0,
    tail: [max_tail]u8 = @splat(0),
    tail_len: u8 = 0,
};

/// How much of an item's growing text is kept to know where an append
/// starts: as much as `entryDigest` looks at.
const max_tail = 64;

/// What an entry looked like when it was last sent: `id` it went out
/// under, the digest of its content then, and — for a turn — what its
/// items were, so a change that only appends is sent as the text that is
/// new rather than the whole turn again.
const Slot = struct {
    id: u64,
    digest: u64,
    /// The turn's items as last sent; empty for a block.
    items: []SentItem = &.{},
    /// The turn's own fields (done, title, timings): when they change, a
    /// turn goes out whole.
    meta: u64 = 0,
};

/// What a turn changed into since it was sent: new text at the end of its
/// last item, everything, or nothing the wire would show.
const Change = union(enum) {
    none,
    full,
    append: struct { index: usize, old_len: usize, text: []const u8 },
};

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
    /// What each session's metadata looked like when it was last sent: its
    /// agent, model and the choices it offers. A change goes out as a
    /// new `session` event, so the phone's picker stays current.
    session_sigs: std.AutoHashMapUnmanaged(*session_mod.Session, u64) = .empty,
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
        var slots = h.slots.valueIterator();
        while (slots.next()) |slot| h.freeSlot(slot);
        h.slots.deinit(h.gpa);
        h.session_sigs.deinit(h.gpa);
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
        for (s.timeline.items) |e| if (h.slots.fetchRemove(entryKey(e))) |kv| h.freeSlot(&kv.value);
        _ = h.session_sigs.remove(s);
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
    /// different from what went out before; then the session itself, when
    /// its agent, model or choices changed.
    fn pump(h: *Hub, s: *session_mod.Session) void {
        const sig = sessionDigest(s);
        if (h.conns.items.len > 0) {
            const known = h.session_sigs.get(s);
            if (known == null or known.? != sig) {
                h.session_sigs.put(h.gpa, s, sig) catch {};
                h.sendSession(null, s);
            }
        } else h.session_sigs.put(h.gpa, s, sig) catch {};
        for (s.timeline.items) |e| h.emit(s, e);
    }

    fn emit(h: *Hub, s: *session_mod.Session, e: session_mod.Entry) void {
        const key = entryKey(e);
        const digest = entryDigest(e);
        if (h.slots.getPtr(key)) |slot| {
            if (slot.digest == digest) return;
            slot.digest = digest;
            h.sendEntry(null, s, slot.id, e, slot);
            return;
        }
        const id = h.next_id;
        h.next_id += 1;
        const slot = h.slots.getOrPut(h.gpa, key) catch return;
        if (!slot.found_existing) slot.value_ptr.* = .{ .id = id, .digest = digest };
        h.sendEntry(null, s, id, e, slot.value_ptr);
    }

    /// A slot's item memory goes with it.
    fn freeSlot(h: *Hub, slot: *const Slot) void {
        if (slot.items.len > 0) h.gpa.free(slot.items);
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
                h.sendEntry(c, s, id, e, h.slots.getPtr(entryKey(e)));
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

    fn sendSession(h: *Hub, c: ?*Conn, s: *session_mod.Session) void {
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
        w.writeAll(",\"agent\":") catch {};
        json(w, s.which.label());
        w.writeAll(",\"agent_key\":") catch {};
        json(w, @tagName(s.which));
        w.writeAll(",\"agent_status\":") catch {};
        json(w, if (s.agent) |ag| @tagName(ag.status) else "off");
        w.writeAll(",\"model\":") catch {};
        json(w, modelName(s));
        w.writeAll(",\"models\":[") catch {};
        writeModels(w, s);
        w.writeAll("],\"agents\":[") catch {};
        writeAgents(w, s);
        w.writeByte(']') catch {};
        w.writeByte('}') catch {};
        h.finish(&aw, c);
    }

    /// What the tab's picker shows as its model: the agent's own choice
    /// once it has one, else the one saved for it.
    fn modelName(s: *session_mod.Session) []const u8 {
        if (s.agent) |ag| if (ag.config.find("model")) |o| return o.currentName();
        if (s.model_choice) |m| return m;
        if (s.which == .agent) if (s.shared.agent_store) |store| if (store.currentModel().len > 0) return store.currentModel();
        return "default model";
    }

    /// The models the tab offers: its agent's, once started; else the
    /// providers configured for the built-in Agent.
    fn writeModels(w: anytype, s: *session_mod.Session) void {
        var first = true;
        if (s.agent) |ag| if (ag.config.find("model")) |o| {
            for (o.choices) |ch| {
                if (!first) w.writeByte(',') catch {};
                first = false;
                w.writeAll("{\"value\":") catch {};
                json(w, ch.value);
                w.writeAll(",\"name\":") catch {};
                json(w, ch.name);
                w.writeAll(",\"provider\":\"\"}") catch {};
            }
        };
        if (first and s.which == .agent) if (s.shared.agent_store) |store| {
            for (store.providers.items) |provider| {
                for (provider.models.items) |model| {
                    if (!first) w.writeByte(',') catch {};
                    first = false;
                    w.writeAll("{\"value\":") catch {};
                    json(w, model);
                    w.writeAll(",\"name\":") catch {};
                    json(w, model);
                    w.writeAll(",\"provider\":") catch {};
                    json(w, provider.name);
                    w.writeByte('}') catch {};
                }
            }
        };
    }

    /// The agents the phone may switch to: as Settings found them, plus
    /// the built-in Agent and Claude Code, as the desktop's picker shows.
    fn writeAgents(w: anytype, s: *session_mod.Session) void {
        var first = true;
        for (std.enums.values(agent_mod.Which)) |which| {
            if (which != s.which and which != .agent and which != .claude and !s.shared.prefs.installed.get(which)) continue;
            if (!first) w.writeByte(',') catch {};
            first = false;
            w.writeAll("{\"key\":") catch {};
            json(w, @tagName(which));
            w.writeAll(",\"name\":") catch {};
            json(w, which.label());
            w.writeByte('}') catch {};
        }
    }

    /// What the phone's picker depends on: a change means a new `session`
    /// event.
    fn sessionDigest(s: *session_mod.Session) u64 {
        var hash = std.hash.Wyhash.init(0);
        const put = struct {
            fn text(hh: *std.hash.Wyhash, t: []const u8) void {
                hh.update(t);
                hh.update(&[_]u8{0});
            }
        }.text;
        put(&hash, s.title());
        put(&hash, s.cwd());
        put(&hash, @tagName(s.mode()));
        put(&hash, @tagName(s.which));
        put(&hash, if (s.agent) |ag| @tagName(ag.status) else "off");
        put(&hash, modelName(s));
        if (s.agent) |ag| if (ag.config.find("model")) |o| {
            for (o.choices) |ch| {
                put(&hash, ch.value);
                put(&hash, ch.name);
            }
        };
        if (s.which == .agent) if (s.shared.agent_store) |store| {
            for (store.providers.items) |provider| {
                put(&hash, provider.name);
                for (provider.models.items) |model| put(&hash, model);
            }
        };
        return hash.final();
    }

    fn sendEntry(h: *Hub, c: ?*Conn, s: *session_mod.Session, id: u64, e: session_mod.Entry, slot: ?*Slot) void {
        switch (e) {
            .block => |b| h.sendBlock(c, s, id, b),
            .turn => |t| h.sendTurn(c, s, id, t, slot),
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

    /// A turn as the phone needs it now: whole, or — when only its last
    /// item grew — just the text that is new. A phone on a slower link
    /// could never keep up with the whole turn going out again and again,
    /// so a long answer arrived long after the workstation's.
    fn sendTurn(h: *Hub, c: ?*Conn, s: *session_mod.Session, id: u64, t: *agent_mod.Turn, slot: ?*Slot) void {
        const meta = turnMeta(t);
        // A client just shown everything (`welcome`) needs all of it, not
        // what changed since the hub last sent it.
        if (c == null) {
            if (slot) |sl| {
                if (sl.meta == meta) switch (turnChange(t, sl.items)) {
                    .none => return,
                    .append => |at| {
                        h.sendTurnAppend(null, s, id, t, at);
                        sl.items[at.index] = sentItem(t.items.items[at.index]);
                        return;
                    },
                    .full => {},
                };
            }
        }
        h.sendTurnFull(c, s, id, t);
        if (slot) |sl| {
            sl.meta = meta;
            h.setSent(sl, t.items.items);
        }
    }

    fn sendTurnFull(h: *Hub, c: ?*Conn, s: *session_mod.Session, id: u64, t: *agent_mod.Turn) void {
        var aw: std.Io.Writer.Allocating = .init(h.gpa);
        defer aw.deinit();
        h.begin(&aw, "turn");
        const w = &aw.writer;
        writeTurnHead(w, s.id, id, t);
        w.writeAll(",\"items\":") catch {};
        writeItems(w, t.items.items);
        w.writeByte('}') catch {};
        h.finish(&aw, c);
    }

    fn sendTurnAppend(h: *Hub, c: ?*Conn, s: *session_mod.Session, id: u64, t: *agent_mod.Turn, at: anytype) void {
        var aw: std.Io.Writer.Allocating = .init(h.gpa);
        defer aw.deinit();
        h.begin(&aw, "turn");
        const w = &aw.writer;
        writeTurnAppend(w, s.id, id, t, at);
        w.writeByte('}') catch {};
        h.finish(&aw, c);
    }

    /// The items as last sent, kept to know what the next change added.
    fn setSent(h: *Hub, slot: *Slot, items: []const agent_mod.Item) void {
        const fresh = h.gpa.alloc(SentItem, items.len) catch {
            h.freeSlot(slot);
            return;
        };
        for (items, 0..) |item, i| fresh[i] = sentItem(item);
        h.freeSlot(slot);
        slot.items = fresh;
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

    /// The block's last lines, joined, their colored spans as SGR escapes
    /// (the phone draws them as the desktop does): as much as one event
    /// holds.
    fn tail(h: *Hub, o: *const vt.Output) []const u8 {
        h.scratch.clearRetainingCapacity();
        // The empty line after a last newline is not output, as the
        // desktop's line count puts it.
        const lines = o.lines.items[0..o.lineCount()];
        if (lines.len == 0) return h.scratch.items;
        var total: usize = 0;
        var start = lines.len;
        while (start > 0) {
            if (total + styledLen(&lines[start - 1]) + 1 > max_output) break;
            total += styledLen(&lines[start - 1]) + 1;
            start -= 1;
        }
        if (start == lines.len) {
            // One line, longer than an event holds: its end is what is new.
            const l = &lines[lines.len - 1];
            const text = l.text.items;
            var from = text.len -| max_output / 2;
            while (from < text.len and (text[from] & 0xc0) == 0x80) from += 1;
            styled(h, l, from);
            return h.scratch.items;
        }
        for (lines[start..], 0..) |*l, i| {
            if (i > 0) h.scratch.append(h.gpa, '\n') catch break;
            styled(h, l, 0);
        }
        return h.scratch.items;
    }

    /// How many bytes a line takes as escapes and text.
    fn styledLen(l: *const vt.Line) usize {
        var n = l.text.items.len;
        for (l.spans.items) |sp| {
            if (sp.color != null) n += 24;
        }
        return n;
    }

    /// A line's text from `from`, each span's color as `\x1b[38;2;r;g;bm`
    /// and closed with `\x1b[0m`: what a terminal would have received.
    fn styled(h: *Hub, l: *const vt.Line, from: usize) void {
        const text = l.text.items;
        var at = @min(from, text.len);
        for (l.spans.items) |sp| {
            const col = sp.color orelse continue;
            const start: usize = @min(@as(usize, sp.start), text.len);
            const end: usize = @min(@as(usize, sp.end), text.len);
            if (end <= at) continue;
            if (start >= text.len) break;
            if (start > at) {
                h.scratch.appendSlice(h.gpa, text[at..start]) catch return;
                at = start;
            }
            sgr(h, col);
            h.scratch.appendSlice(h.gpa, text[at..end]) catch return;
            h.scratch.appendSlice(h.gpa, "\x1b[0m") catch return;
            at = end;
        }
        if (at < text.len) h.scratch.appendSlice(h.gpa, text[at..]) catch {};
    }

    fn sgr(h: *Hub, col: nanoui.ui.Color) void {
        h.scratch.print(h.gpa, "\x1b[38;2;{d};{d};{d}m", .{ channel(col.r), channel(col.g), channel(col.b) }) catch {};
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
            provider: []const u8 = "",
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
        if (std.mem.eql(u8, m.op, "agent")) {
            const which = std.meta.stringToEnum(agent_mod.Which, m.text) orelse {
                h.refuse(c, "no such agent");
                return true;
            };
            s.choose(which);
            // Its choices (models) are what the picker asks for next; the
            // session event carries whatever it already knows.
            h.pump(s);
            h.ack(c, "agent");
            return true;
        }
        if (std.mem.eql(u8, m.op, "model")) {
            if (m.text.len == 0) {
                h.refuse(c, "model needs a name");
                return true;
            }
            if (m.provider.len > 0 and s.which == .agent) if (s.shared.agent_store) |store| store.selectProviderByName(m.provider);
            assist.chooseModel(s, m.text);
            h.pump(s);
            h.ack(c, "model");
            return true;
        }
        if (std.mem.eql(u8, m.op, "models")) {
            // Opens the agent so it can say what it offers; the session
            // event goes out again once its options arrive.
            _ = s.ensureAgent();
            h.pump(s);
            h.ack(c, "models");
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
        const mode: std.Io.File.Permissions = if (windows) .default_file else @fromBackingInt(@intCast(0o600));
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

/// A color channel as an SGR byte.
fn channel(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
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
                w.writeAll(",\"tool\":") catch {};
                json(w, tool.kind);
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

/// Everything of a turn but its items: the same fields whichever way its
/// items go.
fn writeTurnHead(w: anytype, session: u64, id: u64, t: *agent_mod.Turn) void {
    w.print(",\"session\":{d},\"id\":{d},\"agent\":", .{ session, id }) catch {};
    json(w, t.agent.label());
    w.writeAll(",\"prompt\":") catch {};
    json(w, t.prompt);
    w.writeAll(",\"title\":") catch {};
    if (t.title) |title| json(w, title) else w.writeAll("null") catch {};
    w.print(",\"sent\":{},\"done\":{},\"started\":{d:.3},\"ended\":{d:.3}", .{ t.sent, t.done, t.started, t.ended }) catch {};
}

/// What grew, against the whole turn: where it goes, how much the item had,
/// and the text that is new, for a phone whose copy ends where it says.
fn writeTurnAppend(w: anytype, session: u64, id: u64, t: *agent_mod.Turn, at: anytype) void {
    writeTurnHead(w, session, id, t);
    w.print(",\"append\":{{\"index\":{d},\"len\":{d},\"text\":", .{ at.index, at.old_len }) catch {};
    json(w, at.text);
    w.writeAll("}}") catch {};
}

/// What a turn's own fields looked like when it was sent: a change here
/// means the whole turn goes out, since it is not text that grew.
fn turnMeta(t: *const agent_mod.Turn) u64 {
    var h = std.hash.Wyhash.init(0);
    h.update(std.mem.asBytes(&t.sent));
    h.update(std.mem.asBytes(&t.done));
    h.update(@tagName(t.agent));
    h.update(t.prompt);
    if (t.title) |title| h.update(title);
    h.update(std.mem.asBytes(&t.started));
    h.update(std.mem.asBytes(&t.ended));
    return h.final();
}

/// The text an item streams, cut where the wire cuts it; null when it is
/// not an item that grows.
fn shownText(item: agent_mod.Item) ?[]const u8 {
    const text = switch (item) {
        .text => |text| text.items,
        .thought => |text| text.items,
        .note => |note| note,
        .tool => |tool| tool.detail.items,
        else => return null,
    };
    return clip(text, max_text);
}

fn itemKind(item: agent_mod.Item) u8 {
    return switch (item) {
        .text => 't',
        .thought => 'k',
        .note => 'n',
        .tool => 'T',
        .plan => 'P',
        .permission => 'Q',
        .command => 'C',
        .visual => 'v',
    };
}

/// The parts of an item that growing it leaves alone.
fn itemBase(item: agent_mod.Item) u64 {
    var h = std.hash.Wyhash.init(0);
    switch (item) {
        .text, .thought, .note => {},
        .tool => |tool| {
            h.update(tool.id);
            h.update(tool.kind);
            h.update(tool.title.items);
            h.update(@tagName(tool.status));
        },
        else => {
            const digest = itemDigest(item);
            h.update(std.mem.asBytes(&digest));
        },
    }
    return h.final();
}

fn itemDigest(item: agent_mod.Item) u64 {
    var h = std.hash.Wyhash.init(0);
    digestItem(&h, item);
    return h.final();
}

fn sentItem(item: agent_mod.Item) SentItem {
    var sent: SentItem = .{ .digest = itemDigest(item), .kind = itemKind(item), .base = itemBase(item) };
    if (shownText(item)) |shown| {
        sent.len = shown.len;
        const edge = tailOf(shown, max_tail);
        @memcpy(sent.tail[0..edge.len], edge);
        sent.tail_len = @intCast(edge.len);
    }
    return sent;
}

/// What `t` has to say since it went out as `was`: the new text when only
/// the last item grew, the whole turn when more changed (or the phone
/// could not put the new text where it belongs), nothing when the wire
/// would carry the same bytes.
fn turnChange(t: *const agent_mod.Turn, was: []const SentItem) Change {
    const items = t.items.items;
    if (items.len == 0 or was.len != items.len) return .full;
    const last = items.len - 1;
    for (items[0..last], was[0..last]) |item, before| {
        if (itemDigest(item) != before.digest) return .full;
    }
    const item = items[last];
    const before = was[last];
    const now = sentItem(item);
    if (now.kind != before.kind or now.base != before.base) return .full;
    if (now.digest == before.digest) return .none;
    const shown = shownText(item) orelse return .full;
    if (shown.len < before.len) return .full;
    // The bytes it had must still be where the new ones start.
    const edge = before.tail[0..before.tail_len];
    if (edge.len > 0 and !std.mem.eql(u8, shown[before.len - edge.len .. before.len], edge)) return .full;
    // At its clip, the wire would carry the same bytes: nothing to send.
    if (shown.len == before.len) return .none;
    return .{ .append = .{ .index = last, .old_len = before.len, .text = shown[before.len..] } };
}

test "a turn that only grew goes out as what is new" {
    const gpa = std.testing.allocator;
    var t: agent_mod.Turn = .{
        .prompt = try gpa.dupe(u8, "hi"),
        .agent = .claude,
        .started = 0,
        .items = .empty,
    };
    defer {
        for (t.items.items) |*it| switch (it.*) {
            .text => |*l| l.deinit(gpa),
            else => {},
        };
        t.items.deinit(gpa);
        gpa.free(t.prompt);
    }
    try t.items.append(gpa, .{ .text = std.ArrayList(u8).fromOwnedSlice(try gpa.dupe(u8, "Hel")) });
    var was: [2]SentItem = undefined;
    was[0] = sentItem(t.items.items[0]);
    try std.testing.expect(turnChange(&t, was[0..1]) == .none);

    // More of the same text: the new bytes, and where they start.
    try t.items.items[0].text.appendSlice(gpa, "lo");
    const grew = turnChange(&t, was[0..1]);
    try std.testing.expect(grew == .append);
    try std.testing.expectEqual(@as(usize, 0), grew.append.index);
    try std.testing.expectEqual(@as(usize, 3), grew.append.old_len);
    try std.testing.expectEqualStrings("lo", grew.append.text);
    was[0] = sentItem(t.items.items[0]);

    // A second item: the whole turn, so the phone learns about it.
    try t.items.append(gpa, .{ .text = std.ArrayList(u8).fromOwnedSlice(try gpa.dupe(u8, "there")) });
    try std.testing.expect(turnChange(&t, was[0..1]) == .full);
    was[1] = sentItem(t.items.items[1]);

    // The text it had, rewritten: not an append, so whole again.
    t.items.items[1].text.items.len = 0;
    try t.items.items[1].text.appendSlice(gpa, "hello");
    try std.testing.expect(turnChange(&t, was[0..2]) == .full);
}

test "an append event says where the new text goes" {
    const gpa = std.testing.allocator;
    var t: agent_mod.Turn = .{
        .prompt = try gpa.dupe(u8, "hi"),
        .agent = .claude,
        .started = 0,
        .items = .empty,
    };
    defer {
        for (t.items.items) |*it| switch (it.*) {
            .text => |*l| l.deinit(gpa),
            else => {},
        };
        t.items.deinit(gpa);
        gpa.free(t.prompt);
    }
    try t.items.append(gpa, .{ .text = std.ArrayList(u8).fromOwnedSlice(try gpa.dupe(u8, "Hello")) });
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    writeTurnAppend(&aw.writer, 3, 11, &t, .{ .index = 0, .old_len = 3, .text = "lo" });
    const line = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, line, "\"session\":3,\"id\":11") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, ",\"append\":{\"index\":0,\"len\":3,\"text\":\"lo\"}") != null);
    // What grew, not the whole turn again.
    try std.testing.expect(std.mem.indexOf(u8, line, "\"items\":") == null);
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
        else => &.{"ifconfig"},
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
    var chunk: [1][]u8 = .{buffer[0..]};
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
    var rest = line[marker + "inet ".len ..];
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
        rest = if (end < rest.len) rest[end + 1 ..] else &.{};
        if (token.len == 0) continue;
        if (isIpv4(token) and !std.mem.eql(u8, token, "127.0.0.1") and !std.mem.eql(u8, token, "0.0.0.0")) return token;
    }
    return null;
}

test "a block's tail carries its spans' colors as escapes" {
    const t = std.testing;
    var h: Hub = undefined;
    h.gpa = t.allocator;
    h.scratch = .empty;
    defer h.scratch.deinit(h.gpa);
    var o = vt.Output.init(t.allocator);
    defer o.deinit();
    try o.feed("plain \x1b[31mred\x1b[0m end\n");
    const out = Hub.tail(&h, &o);
    try t.expect(std.mem.indexOf(u8, out, "\x1b[38;2;") != null);
    try t.expect(std.mem.indexOf(u8, out, "red") != null);
    try t.expect(std.mem.indexOf(u8, out, "\x1b[0m") != null);
    try t.expect(std.mem.startsWith(u8, out, "plain \x1b[38;2;"));
    try t.expect(std.mem.endsWith(u8, out, "\x1b[0m end"));
}
