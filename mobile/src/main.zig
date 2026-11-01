//! The phone's nanoterm: what a workstation's relay sends, on a phone.
//!
//! A thin client, and thin is the point: a phone cannot run a terminal
//! (forks, a PTY, a shell), so it shows what the desktop relay sends —
//! the tabs, each command and what it printed, an agent's answers — and
//! sends back what the user does: a command to run, a question for the
//! agent, an answer to a permission it is waiting on.
//!
//! It connects to a relay at `--host HOST --port PORT --token TOKEN`
//! (defaults: 127.0.0.1, 4789, taken from NANOTERM_RELAY_TOKEN) and reads
//! the events the relay writes, one JSON object per line, on the main
//! thread: `fdwatch` for the socket, no polling, no second thread.
const types = @import("nanoui").ui.types;
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const fdwatch = nanoui.fdwatch;
const settings = @import("settings.zig");

comptime {
    // A phone's app: iOS (and, later, Android). The desktop has nanoterm
    // itself, with a shell on the other end of the relay.
    if (builtin.os.tag == .windows) @compileError("the phone's nanoterm is an iOS app; nanoterm on the Mac is the relay's other end");
}

/// A debug build says what it received on the console, which is how a
/// Simulator run is checked (and how `simctl launch --console` reads).
const develop = builtin.mode == .debug;

fn note(comptime fmt: []const u8, args: anytype) void {
    if (develop) std.debug.print("phone: " ++ fmt ++ "\n", args);
}

/// Lines kept, and the longest of them: a feed of what came, not history.
const keep_lines = 400;
const max_line = 2000;
/// Bytes of a partial event held while its newline arrives (the relay's
/// own limit is larger: this is a phone).
const max_waiting = 256 * 1024;
/// Permission questions shown at once: the newest are the ones waiting.
const max_pending = 4;
/// A turn's id in `running`, apart from a block's: ids count from one in
/// both, and a block and a turn may be running in the same tab.
const turn_bit: u64 = 1 << 63;

/// Which of the two the window shows: the connection's own fields (a
/// phone has no command line to be told on), or what the relay sends.
const Screen = enum { connect, feed };

const Status = enum {
    connecting,
    live,
    down,

    fn label(s: Status) []const u8 {
        return switch (s) {
            .connecting => "connecting",
            .live => "connected",
            .down => "not connected",
        };
    }
};

/// What the agent asked and has not been answered: a card, and the tap
/// that answers it.
const Pending = struct {
    rpc: []u8,
    title: []u8,
    options: std.ArrayList([]u8) = .empty,
    /// The permission type: "file", "network", "execute", etc. for icon display.
    perm_type: []u8 = "",
    /// Additional detail about what this permission is for.
    detail: []u8 = "",
    /// Which option was chosen (null = not yet answered).
    chosen: ?usize = null,

    fn deinit(p: *Pending, gpa: std.mem.Allocator) void {
        gpa.free(p.rpc);
        gpa.free(p.title);
        if (p.perm_type.len > 0) gpa.free(p.perm_type);
        if (p.detail.len > 0) gpa.free(p.detail);
        for (p.options.items) |o| gpa.free(o);
        p.options.deinit(gpa);
    }
};

/// A structured feed entry: what kind of message it is, so the view can
/// render it differently — a command, its output, an agent's reply.
const Entry = struct {
    kind: Kind,
    text: []u8,
    session: u64 = 0,
    timestamp: i64 = 0,
    collapsed: bool = false,

    const Kind = enum {
        command,
        output,
        agent_thought,
        agent_tool,
        agent_reply,
        permission_ask,
        permission_answer,
        system,
        err,
    };

    fn deinit(e: *Entry, gpa: std.mem.Allocator) void {
        gpa.free(e.text);
    }
};

fn getTimestamp() i64 {
    if (@hasDecl(std.time, "timestamp")) return std.time.timestamp();
    return 0;
}

/// A tab's metadata: what the relay sent about it, for the switcher.
const TabInfo = struct {
    id: u64,
    title: []u8 = "",
    cwd: []u8 = "",
    mode: []u8 = "",
    has_activity: bool = false,

    fn deinit(t: *TabInfo, gpa: std.mem.Allocator) void {
        if (t.title.len > 0) gpa.free(t.title);
        if (t.cwd.len > 0) gpa.free(t.cwd);
        if (t.mode.len > 0) gpa.free(t.mode);
    }
};

/// A saved connection: what was used before, for quick recall.
const SavedConnection = struct {
    name: []u8,
    host: []u8,
    port: u16,
    token: [32]u8,
    last_used: i64 = 0,

    fn deinit(s: *SavedConnection, gpa: std.mem.Allocator) void {
        gpa.free(s.name);
        gpa.free(s.host);
    }
};

/// Notification kind: info, success, warning, or error.
pub const NotificationKind = enum { info, success, warning, err };

/// A notification: a temporary message shown to the user.
const Notification = struct {
    kind: NotificationKind,
    message: []u8,
    timestamp: i64,
    /// Seconds until auto-dismiss (0 = manual dismiss only).
    duration: f32 = 3.0,

    fn deinit(n: *Notification, gpa: std.mem.Allocator) void {
        gpa.free(n.message);
    }
};

pub const Phone = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    window: ?*nanoui.Window = null,
    stream: ?std.Io.net.Stream = null,
    watch: ?fdwatch.Watch = null,
    in: std.ArrayList(u8) = .empty,
    /// The structured feed: typed entries, newest at the end.
    entries: std.ArrayList(Entry) = .empty,
    /// The tab the composer sends to: the first one, or the one tapped.
    session: u64 = 0,
    tabs: usize = 0,
    /// The workstation's tabs, with their metadata: what the switcher shows.
    sessions: std.ArrayList(TabInfo) = .empty,
    /// Saved connections: recent ones for quick recall.
    saved_connections: std.ArrayList(SavedConnection) = .empty,
    screen: Screen = .feed,
    /// The connect screen's three fields, and what it says when they are
    /// not enough to try with.
    host_input: ui.TextBuffer = .{},
    port_input: ui.TextBuffer = .{},
    token_input: ui.TextBuffer = .{},
    connect_why: [160]u8 = @splat(0),
    connect_why_len: usize = 0,
    /// Whether an argument said so: an argument wins over the saved file,
    /// which is how a cable and `am start` still work.
    has_host: bool = false,
    has_port: bool = false,
    /// What the composer does with Return: run it here, or ask the agent.
    mode: usize = 0,
    input: ui.TextBuffer = .{},
    /// Command history: what was sent, newest first, for up/down arrow recall.
    history: std.ArrayList([]u8) = .empty,
    history_index: usize = 0,
    pending: std.ArrayList(Pending) = .empty,
    /// What is running, so Stop is offered only when there is something to
    /// stop: a block's id as it is, a turn's with the top bit set.
    running: std.ArrayList(u64) = .empty,
    /// A counter for the pulse animation when something is running.
    pulse_counter: u32 = 0,
    /// Gesture tracking: swipe to switch tabs, pull to refresh.
    swipe_start_x: f32 = 0,
    swipe_start_y: f32 = 0,
    swipe_tracking: bool = false,
    pull_distance: f32 = 0,
    pull_refreshing: bool = false,
    /// Notifications: temporary messages shown to the user.
    notifications: std.ArrayList(Notification) = .empty,
    status: Status = .connecting,
    /// Why it is not connected, when it is not.
    why: [200]u8 = @splat(0),
    why_len: usize = 0,
    /// "host:port", made once.
    where: [80]u8 = @splat(0),
    where_len: usize = 0,
    token: [32]u8 = @splat('0'),
    has_token: bool = false,
    port: u16 = 4789,
    host: [64]u8 = @splat(0),
    host_len: usize = 0,
    /// Theme preference: system, light, or dark.
    theme_pref: settings.ThemePreference = .system,
    /// Track how many items have been shown for each turn, so updates
    /// only add new items instead of duplicating all of them.
    turn_items_seen: std.AutoHashMap(u64, usize) = .init(undefined),
    arena_state: std.heap.ArenaAllocator,

    fn create(init: std.process.Init, args: []const []const u8) !*Phone {
        const p = try init.gpa.create(Phone);
        p.* = .{ .gpa = init.gpa, .io = init.io, .arena_state = .init(init.gpa) };
        p.turn_items_seen = .init(init.gpa);
        @memcpy(p.host[0..9], "127.0.0.1");
        p.host_len = 9;
        // What was typed on the phone last time, then the arguments over
        // it: the file is what a release build has, the arguments what a
        // debug build and a cable can add.
        if (settings.load(init.io, init.gpa)) |saved| {
            defer saved.deinit(init.gpa);
            if (saved.host.len <= p.host.len) {
                @memcpy(p.host[0..saved.host.len], saved.host);
                p.host_len = saved.host.len;
            }
            p.port = saved.port;
            p.theme_pref = saved.theme;
            if (saved.usable()) {
                @memcpy(&p.token, saved.token);
                p.has_token = true;
            }
        }
        var i: usize = 1;
        while (i + 1 < args.len) : (i += 1) {
            const flag = args[i];
            const value = args[i + 1];
            if (std.mem.eql(u8, flag, "--host")) {
                if (value.len > p.host.len) continue;
                @memcpy(p.host[0..value.len], value);
                p.host_len = value.len;
                p.has_host = true;
            } else if (std.mem.eql(u8, flag, "--port")) {
                p.port = std.fmt.parseInt(u16, value, 10) catch p.port;
                p.has_port = true;
            } else if (std.mem.eql(u8, flag, "--token")) {
                if (value.len == 32) {
                    @memcpy(&p.token, value[0..32]);
                    p.has_token = true;
                }
            } else continue;
            i += 1;
        }
        if (!p.has_token) if (init.environ_map.get("NANOTERM_RELAY_TOKEN")) |t| if (t.len == 32) {
            @memcpy(&p.token, t[0..32]);
            p.has_token = true;
        };
        const printed: []u8 = std.fmt.bufPrint(&p.where, "{s}:{d}", .{ p.host[0..p.host_len], p.port }) catch p.where[0..0];
        p.where_len = printed.len;
        // No token anywhere: the phone asks, once, and remembers.
        p.screen = if (p.has_token) .feed else .connect;
        p.fillConnect();
        return p;
    }

    pub fn destroy(p: *Phone) void {
        p.close();
        for (p.entries.items) |*e| e.deinit(p.gpa);
        p.entries.deinit(p.gpa);
        for (p.sessions.items) |*s| s.deinit(p.gpa);
        p.sessions.deinit(p.gpa);
        for (p.saved_connections.items) |*s| s.deinit(p.gpa);
        p.saved_connections.deinit(p.gpa);
        for (p.pending.items) |*q| q.deinit(p.gpa);
        p.pending.deinit(p.gpa);
        for (p.history.items) |h| p.gpa.free(h);
        p.history.deinit(p.gpa);
        for (p.notifications.items) |*n| n.deinit(p.gpa);
        p.notifications.deinit(p.gpa);
        p.running.deinit(p.gpa);
        p.input.deinit();
        p.host_input.deinit();
        p.port_input.deinit();
        p.token_input.deinit();
        p.in.deinit(p.gpa);
        p.arena_state.deinit();
        const gpa = p.gpa;
        gpa.destroy(p);
    }

    pub fn close(p: *Phone) void {
        if (p.watch) |w| w.cancel();
        p.watch = null;
        if (p.stream) |s| s.close(p.io);
        p.stream = null;
    }

    /// The relay, and hello to it: the token, then whatever it holds.
    pub fn open(p: *Phone) void {
        p.close();
        if (!p.has_token) {
            p.fail("no token: --token, or NANOTERM_RELAY_TOKEN");
            return;
        }
        const host = p.host[0..p.host_len];
        var addr = std.Io.net.IpAddress.parse(host, p.port) catch |err| {
            p.fail(@errorName(err));
            return;
        };
        addr.setPort(p.port);
        // A tunnel to a workstation is a TCP connection like any other.
        p.stream = std.Io.net.IpAddress.connect(&addr, p.io, .{ .mode = .stream }) catch |err| {
            p.fail(@errorName(err));
            return;
        };
        const fd = p.stream.?.socket.handle;
        p.watch = fdwatch.readable(fd, p, onReadable) catch |err| {
            p.fail(@errorName(err));
            return;
        };
        p.status = .live;
        var buf: [96]u8 = undefined;
        const hello = std.fmt.bufPrint(&buf, "{{\"op\":\"hello\",\"token\":\"{s}\"}}\n", .{p.token}) catch return;
        p.write(hello);
        p.push("connected to {s}", .{p.where[0..p.where_len]});
    }

    pub fn fail(p: *Phone, why: []const u8) void {
        note("down: {s}", .{why});
        p.status = .down;
        p.close();
        p.why_len = @min(why.len, p.why.len);
        @memcpy(p.why[0..p.why_len], why[0..p.why_len]);
        p.push("not connected: {s}", .{why});
    }

    pub fn onReadable(ctx: ?*anyopaque) callconv(.c) void {
        const p: *Phone = @ptrCast(@alignCast(ctx.?));
        p.read();
    }

    /// What the socket holds, once: the read source calls again while
    /// there is more.
    pub fn read(p: *Phone) void {
        const fd = if (p.stream) |s| s.socket.handle else return;
        var buf: [16 * 1024]u8 = undefined;
        const n = std.posix.read(fd, &buf) catch |err| {
            p.fail(@errorName(err));
            return;
        };
        if (n == 0) {
            p.fail("the relay closed the connection");
            return;
        }
        p.in.appendSlice(p.gpa, buf[0..n]) catch return;
        while (std.mem.indexOfScalar(u8, p.in.items, '\n')) |at| {
            const line = p.in.items[0..at];
            p.event(line);
            const left = p.in.items.len - at - 1;
            std.mem.copyForwards(u8, p.in.items[0..left], p.in.items[at + 1 ..]);
            p.in.items.len = left;
        }
        if (p.in.items.len > max_waiting) p.in.clearRetainingCapacity();
        p.draw();
    }

    /// One event, rendered as the thing it is, not as JSON.
    pub fn event(p: *Phone, line: []const u8) void {
        const Option = struct { id: []const u8 = "", name: []const u8 = "" };
        const Item = struct {
            kind: []const u8 = "",
            rpc: []const u8 = "",
            title: []const u8 = "",
            options: []const Option = &.{},
            chosen: ?usize = null,
            text: []const u8 = "",
            status: []const u8 = "",
        };
        const Event = struct {
            seq: u64 = 0,
            kind: []const u8 = "",
            id: u64 = 0,
            title: []const u8 = "",
            cwd: []const u8 = "",
            command: []const u8 = "",
            state: []const u8 = "",
            output: []const u8 = "",
            mode: []const u8 = "",
            sessions: []const u64 = &.{},
            message: []const u8 = "",
            prompt: []const u8 = "",
            done: bool = false,
            items: []const Item = &.{},
        };
        const arena = p.arena_state.allocator();
        defer _ = p.arena_state.reset(.retain_capacity);
        const e = std.json.parseFromSliceLeaky(Event, arena, line, .{ .ignore_unknown_fields = true }) catch return;
        if (std.mem.eql(u8, e.kind, "welcome")) {
            p.tabs = e.sessions.len;
            if (p.session == 0 and e.sessions.len > 0) p.session = e.sessions[0];
            for (e.sessions) |id| {
                var found = false;
                for (p.sessions.items) |s| {
                    if (s.id == id) {
                        found = true;
                        break;
                    }
}
                if (!found) p.sessions.append(p.gpa, .{ .id = id }) catch {};
            }
            const msg = std.fmt.allocPrint(arena, "{d} tab(s) on the workstation", .{e.sessions.len}) catch return;
            p.addEntry(.system, msg, 0);
        } else if (std.mem.eql(u8, e.kind, "session")) {
            if (p.session == 0) p.session = e.id;
            for (p.sessions.items) |*s| {
                if (s.id == e.id) {
                    if (s.title.len > 0) p.gpa.free(s.title);
                    if (s.cwd.len > 0) p.gpa.free(s.cwd);
                    if (s.mode.len > 0) p.gpa.free(s.mode);
                    s.title = p.gpa.dupe(u8, if (e.title.len > 0) e.title else "~") catch s.title;
                    s.cwd = p.gpa.dupe(u8, e.cwd) catch s.cwd;
                    s.mode = p.gpa.dupe(u8, e.mode) catch s.mode;
                    break;
                }
            }
            const msg = std.fmt.allocPrint(arena, "tab {d}: {s} — {s} ({s})", .{ e.id, if (e.title.len > 0) e.title else "~", e.cwd, e.mode }) catch return;
            p.addEntry(.system, msg, e.id);
        } else if (std.mem.eql(u8, e.kind, "gone")) {
            if (p.session == e.id) p.session = 0;
            for (p.sessions.items, 0..) |s, i| {
                if (s.id == e.id) {
                    var copy = s;
                    copy.deinit(p.gpa);
                    _ = p.sessions.orderedRemove(i);
                    break;
                }
            }
            const msg = std.fmt.allocPrint(arena, "tab {d} closed", .{e.id}) catch return;
            p.addEntry(.system, msg, e.id);
        } else if (std.mem.eql(u8, e.kind, "block")) {
            p.mark(e.id, std.mem.eql(u8, e.state, "running"));
            if (std.mem.eql(u8, e.state, "running")) {
                p.addEntry(.command, e.command, e.id);
            } else {
                const msg = std.fmt.allocPrint(arena, "{s}  ({s})", .{ e.command, e.state }) catch return;
                p.addEntry(.command, msg, e.id);
                var it = std.mem.splitScalar(u8, e.output, '\n');
                while (it.next()) |out| {
                    if (out.len > 0) p.addEntry(.output, out, e.id);
                }
            }
        } else if (std.mem.eql(u8, e.kind, "turn")) {
            p.mark(e.id | turn_bit, !e.done);
            // Track which items we've already shown for this turn, so updates
            // only add new items instead of duplicating everything.
            const turn_key = e.id | turn_bit;
            const seen = p.turn_items_seen.get(turn_key) orelse 0;
            // Show the prompt only once (when we haven't seen any items yet).
            if (seen == 0 and e.prompt.len > 0) p.addEntry(.agent_thought, e.prompt, e.id);
            // Only add items we haven't seen before.
            if (e.items.len > seen) {
                for (e.items[seen..]) |item| {
                    if (std.mem.eql(u8, item.kind, "permission")) {
                        if (item.chosen != null) {
                            p.answered(item.rpc);
                        } else {
                            p.ask(item);
                        }
                    } else if (std.mem.eql(u8, item.kind, "text") and item.text.len > 0) {
                        p.addEntry(.agent_reply, item.text, e.id);
                    } else if (std.mem.eql(u8, item.kind, "tool")) {
                        const msg = std.fmt.allocPrint(arena, "{s}: {s}", .{ item.title, item.status }) catch return;
                        p.addEntry(.agent_tool, msg, e.id);
                    }
                }
                p.turn_items_seen.put(turn_key, e.items.len) catch {};
            }
            // Clean up when the turn is done to avoid unbounded growth.
            if (e.done) p.turn_items_seen.remove(turn_key);
        } else if (std.mem.eql(u8, e.kind, "ack")) {
            // What was sent was taken: nothing to show.
        } else if (std.mem.eql(u8, e.kind, "error")) {
            p.addEntry(.err, e.message, 0);
            p.fail(e.message);
        }
    }

    /// A block (or a turn) started, or finished: what Stop has to stop.
    pub fn mark(p: *Phone, key: u64, on: bool) void {
        for (p.running.items, 0..) |k, i| {
            if (k != key) continue;
            if (!on) _ = p.running.orderedRemove(i);
            return;
        }
        if (!on) return;
        // A phone shows a handful; more than that is not a feed.
        if (p.running.items.len == 8) _ = p.running.orderedRemove(0);
        p.running.append(p.gpa, key) catch {};
    }

    /// A question waiting on this phone: a card, until it is answered.
    pub fn ask(p: *Phone, item: anytype) void {
        for (p.pending.items) |q| if (std.mem.eql(u8, q.rpc, item.rpc)) return;
        if (p.pending.items.len == max_pending) {
            var old = p.pending.orderedRemove(0);
            old.deinit(p.gpa);
        }
        var q: Pending = .{
            .rpc = p.gpa.dupe(u8, item.rpc) catch return,
            .title = p.gpa.dupe(u8, if (item.title.len > 0) item.title else "the agent asks") catch return,
            .perm_type = "",
            .detail = "",
            .chosen = null,
        };
        for (item.options) |o| {
            const name = p.gpa.dupe(u8, o.name) catch break;
            q.options.append(p.gpa, name) catch {
                p.gpa.free(name);
                break;
            };
        }
        p.pending.append(p.gpa, q) catch {
            q.deinit(p.gpa);
            return;
        };
        p.push("? {s}", .{q.title});
    }

    /// Answered here (or at the workstation): its card goes.
    pub fn answered(p: *Phone, rpc: []const u8) void {
        for (p.pending.items, 0..) |q, i| {
            if (std.mem.eql(u8, q.rpc, rpc)) {
                var gone = p.pending.orderedRemove(i);
                gone.deinit(p.gpa);
                return;
            }
        }
    }

    pub fn push(p: *Phone, comptime fmt: []const u8, args: anytype) void {
        var aw: std.Io.Writer.Allocating = .init(p.gpa);
        defer aw.deinit();
        aw.writer.print(fmt, args) catch return;
        const text = aw.written();
        const clipped = if (text.len > max_line) text[0..max_line] else text;
        note("{s}", .{clipped});
        const copy = p.gpa.dupe(u8, clipped) catch return;
        if (p.entries.items.len == keep_lines) {
            p.entries.items[0].deinit(p.gpa);
            std.mem.copyForwards(Entry, p.entries.items[0 .. keep_lines - 1], p.entries.items[1..keep_lines]);
            p.entries.items.len -= 1;
        }
        p.entries.append(p.gpa, .{ .kind = .system, .text = copy }) catch {
            p.gpa.free(copy);
            return;
        };
    }

    /// Show a notification: a temporary message in the UI.
    pub fn notify(p: *Phone, kind: NotificationKind, comptime fmt: []const u8, args: anytype) void {
        var aw: std.Io.Writer.Allocating = .init(p.gpa);
        defer aw.deinit();
        aw.writer.print(fmt, args) catch return;
        const text = aw.written();
        const copy = p.gpa.dupe(u8, text) catch return;
        const duration: f32 = switch (kind) {
            .info => 3.0,
            .success => 2.5,
            .warning => 4.0,
            .err => 5.0,
        };
        p.notifications.append(p.gpa, .{
            .kind = kind,
            .message = copy,
            .timestamp = getTimestamp(),
            .duration = duration,
        }) catch {
            p.gpa.free(copy);
            return;
        };
        // Keep only the last 5 notifications.
        while (p.notifications.items.len > 5) {
            p.notifications.items[0].deinit(p.gpa);
            std.mem.copyForwards(Notification, p.notifications.items[0 .. 5], p.notifications.items[1..6]);
            p.notifications.items.len -= 1;
        }
        p.draw();
    }

    /// Dismiss a notification by index.
    pub fn dismissNotification(p: *Phone, index: usize) void {
        if (index >= p.notifications.items.len) return;
        p.notifications.items[index].deinit(p.gpa);
        _ = p.notifications.swapRemove(index);
        p.draw();
    }

    /// Clean up expired notifications.
    pub fn pruneNotifications(p: *Phone) void {
        const now = getTimestamp();
        var i: usize = 0;
        while (i < p.notifications.items.len) {
            const age: f32 = @floatFromInt(now - p.notifications.items[i].timestamp);
            if (age >= p.notifications.items[i].duration) {
                p.notifications.items[i].deinit(p.gpa);
                _ = p.notifications.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// A structured entry: typed, so the view renders it differently.
    pub fn addEntry(p: *Phone, kind: Entry.Kind, text: []const u8, session: u64) void {
        const copy = p.gpa.dupe(u8, text) catch return;
        if (p.entries.items.len == keep_lines) {
            p.entries.items[0].deinit(p.gpa);
            std.mem.copyForwards(Entry, p.entries.items[0 .. keep_lines - 1], p.entries.items[1..keep_lines]);
            p.entries.items.len -= 1;
        }
        p.entries.append(p.gpa, .{
            .kind = kind,
            .text = copy,
            .session = session,
            .timestamp = getTimestamp(),
        }) catch {
            p.gpa.free(copy);
            return;
        };
    }

    /// A line to the relay, whole: a partial one would be read as JSON
    /// and refused.
    pub fn write(p: *Phone, bytes: []const u8) void {
        const s = p.stream orelse return;
        var wbuf: [512]u8 = undefined;
        var out = s.writer(p.io, &wbuf);
        out.interface.writeAll(bytes) catch |err| {
            p.fail(@errorName(err));
            return;
        };
        out.interface.flush() catch |err| {
            p.fail(@errorName(err));
            return;
        };
    }

    fn json(w: *std.Io.Writer, s: []const u8) void {
        std.json.Stringify.value(s, .{}, w) catch {};
    }

    /// A command or a question, as the relay reads it.
    pub fn opLine(w: *std.Io.Writer, op: []const u8, session: u64, text: []const u8) void {
        w.writeAll("{\"op\":") catch return;
        json(w, op);
        w.print(",\"session\":{d},\"text\":", .{session}) catch return;
        json(w, text);
        w.writeAll("}\n") catch return;
    }

    /// The tap on a permission's option: the relay answers the agent.
    pub fn answerLine(w: *std.Io.Writer, session: u64, rpc: []const u8, option: usize) void {
        w.print("{{\"op\":\"answer\",\"session\":{d},\"rpc\":", .{session}) catch return;
        json(w, rpc);
        w.print(",\"option\":{d}}}\n", .{option}) catch return;
    }

    /// Stop, as the relay reads it: whatever that tab is doing — the
    /// command in its shell, or the agent's turn — ends.
    pub fn interruptLine(w: *std.Io.Writer, session: u64) void {
        w.print("{{\"op\":\"interrupt\",\"session\":{d}}}\n", .{session}) catch return;
    }

    /// The tap on Stop: the tab it is pointed at stops what it is doing.
    pub fn interrupt(p: *Phone) void {
        if (p.session == 0) {
            p.push("no tab to stop: is the workstation's relay up?", .{});
            return;
        }
        var aw: std.Io.Writer.Allocating = .init(p.gpa);
        defer aw.deinit();
        interruptLine(&aw.writer, p.session);
        p.push("stop sent to tab {d}", .{p.session});
        p.write(aw.written());
    }

    /// The connect screen's fields, from what the phone has now: a second
    /// visit starts where the first one ended.
    pub fn fillConnect(p: *Phone) void {
        p.host_input.set(p.host[0..p.host_len]);
        var buf: [8]u8 = undefined;
        p.port_input.set(std.fmt.bufPrint(&buf, "{d}", .{p.port}) catch "4789");
        p.token_input.set(if (p.has_token) &p.token else "");
        p.connect_why_len = 0;
    }

    /// A reason the fields are not enough, said where they are.
    pub fn connectFail(p: *Phone, why: []const u8) void {
        note("connect: {s}", .{why});
        p.connect_why_len = @min(why.len, p.connect_why.len);
        @memcpy(p.connect_why[0..p.connect_why_len], why[0..p.connect_why_len]);
        p.notify(.err, "Connection failed: {s}", .{why});
        p.draw();
    }

    /// The tap on Connect: what is in the fields, saved, then tried.
    pub fn connect(p: *Phone) void {
        const host = std.mem.trim(u8, p.host_input.text(), " \t\r\n");
        const port_text = std.mem.trim(u8, p.port_input.text(), " \t\r\n");
        const token = std.mem.trim(u8, p.token_input.text(), " \t\r\n");
        if (host.len == 0) return p.connectFail("a host: an address, or a name on the network");
        if (host.len > p.host.len) return p.connectFail("a host shorter than 64 characters");
        if (token.len != settings.token_len) return p.connectFail("the token, all 32 characters of it: nanoterm prints it");
        const port = std.fmt.parseInt(u16, port_text, 10) catch
            return p.connectFail("a port, as a number: 4789 unless the relay said otherwise");
        @memcpy(p.host[0..host.len], host);
        p.host_len = host.len;
        p.port = port;
        @memcpy(&p.token, token);
        p.has_token = true;
        const printed: []u8 = std.fmt.bufPrint(&p.where, "{s}:{d}", .{ p.host[0..p.host_len], p.port }) catch p.where[0..0];
        p.where_len = printed.len;
        // Saved before it is tried: a phone that cannot save still works
        // for this run, and one that can does not ask again.
        _ = settings.save(p.io, p.gpa, host, port, token, p.theme_pref);
        // Save to recent connections history.
        p.saveConnection(host, port, token);
        p.connect_why_len = 0;
        p.status = .connecting;
        p.open();
        if (p.status == .live) {
            p.screen = .feed;
            p.notify(.success, "Connected to {s}", .{p.where[0..p.where_len]});
        } else if (p.status == .down) {
            // Connection failed: show the error on the connect screen.
            p.screen = .connect;
            p.connectFail(p.why[0..p.why_len]);
        }
    }

    /// Save a connection to the recent history, keeping last 5.
    fn saveConnection(p: *Phone, host: []const u8, port: u16, token: []const u8) void {
        // Check if already exists, update last_used.
        for (p.saved_connections.items) |*s| {
            if (std.mem.eql(u8, s.host, host) and s.port == port) {
                s.last_used = getTimestamp();
                return;
            }
        }
        // Add new, keep last 5.
        if (p.saved_connections.items.len == 5) {
            p.saved_connections.items[0].deinit(p.gpa);
            _ = p.saved_connections.orderedRemove(0);
        }
        const name = std.fmt.allocPrint(p.gpa, "{s}:{d}", .{ host, port }) catch return;
        const host_copy = p.gpa.dupe(u8, host) catch {
            p.gpa.free(name);
            return;
        };
        var token_copy: [32]u8 = @splat(0);
        if (token.len == 32) @memcpy(&token_copy, token);
        p.saved_connections.append(p.gpa, .{
            .name = name,
            .host = host_copy,
            .port = port,
            .token = token_copy,
            .last_used = getTimestamp(),
        }) catch {
            p.gpa.free(name);
            p.gpa.free(host_copy);
        };
    }

    /// Load a saved connection into the input fields.
    pub fn loadConnection(p: *Phone, index: usize) void {
        if (index >= p.saved_connections.items.len) return;
        const s = p.saved_connections.items[index];
        p.host_input.set(s.host);
        var buf: [8]u8 = undefined;
        p.port_input.set(std.fmt.bufPrint(&buf, "{d}", .{s.port}) catch "4789");
        p.token_input.set(&s.token);
        p.saved_connections.items[index].last_used = getTimestamp();
    }

    /// Back to the fields: from the header, to change where this points.
    pub fn toConnect(p: *Phone) void {
        p.fillConnect();
        p.screen = .connect;
        p.draw();
    }

    /// What the composer sends: a command to run, or a question for the
    /// agent, in the tab it is pointed at. Saved to history for recall.
    pub fn submit(p: *Phone) void {
        const text = std.mem.trim(u8, p.input.text(), " \t\r\n");
        if (text.len == 0) return;
        if (p.session == 0) {
            p.push("no tab to send to: is the workstation's relay up?", .{});
            return;
        }
        // "clear" is a local command: wipe the feed, do not send it.
        if (std.mem.eql(u8, text, "clear")) {
            for (p.entries.items) |*e| e.deinit(p.gpa);
            p.entries.clearRetainingCapacity();
            p.input.clear();
            p.push("feed cleared", .{});
            return;
        }
        var aw: std.Io.Writer.Allocating = .init(p.gpa);
        defer aw.deinit();
        opLine(&aw.writer, if (p.mode == 0) "run" else "ask", p.session, text);
        // The relay answers with the block it made; this is the echo that
        // says the tap landed even before that.
        p.push("{s} {s}", .{ if (p.mode == 0) "$" else "agent:", text });
        p.write(aw.written());
        p.input.clear();
        // Save to history (newest first), keep last 20 commands.
        const copy = p.gpa.dupe(u8, text) catch return;
        if (p.history.items.len == 20) {
            p.gpa.free(p.history.items[p.history.items.len - 1]);
            _ = p.history.orderedRemove(p.history.items.len - 1);
        }
        p.history.insert(p.gpa, 0, copy) catch {
            p.gpa.free(copy);
            return;
        };
        p.history_index = 0;
    }

    /// Recall a command from history: up goes back, forward goes newer.
    pub fn historyRecall(p: *Phone, direction: i32) void {
        if (p.history.items.len == 0) return;
        const new_index = @as(i32, @intCast(p.history_index)) + direction;
        if (new_index < 0 or new_index >= @as(i32, @intCast(p.history.items.len))) return;
        p.history_index = @intCast(new_index);
        p.input.set(p.history.items[p.history_index]);
    }

    /// The tap on a permission's option: the relay answers the agent.
    fn answer(p: *Phone, q: *Pending, option: usize) void {
        var aw: std.Io.Writer.Allocating = .init(p.gpa);
        defer aw.deinit();
        answerLine(&aw.writer, p.session, q.rpc, option);
        p.push("> {s}", .{q.options.items[option]});
        p.write(aw.written());
        // Remove the card immediately; the relay will not send it again.
        p.answered(q.rpc);
    }

    /// Where the workstation is: fields, saved connections, and help.
    pub fn connectView(p: *Phone, c: *ui.Context) void {
        ui.column(c, .{
            .width = .fill,
            .height = .fill,
            .padding = c.safe_area,
            .background = c.theme.background,
        });
        ui.scroll(c, .{
            .width = .fill,
            .grow = 1,
            .padding = .{ .top = 20, .bottom = 20, .left = 16, .right = 16 },
            .gap = 12,
        });
        // Header with icon and title.
        ui.row(c, .{ .width = .fill, .gap = 10, .align_items = .center });
        ui.text(c, "🔗", .{ .size = 24 });
        ui.column(c, .{ .gap = 2 });
        ui.text(c, "Connect to Workstation", .{ .size = 20, .weight = .semibold });
        ui.text(c, "Enter the relay address and token", .{ .size = 12, .color = c.theme.muted });
        ui.end(c);
        ui.end(c);

        // Connection form.
        ui.column(c, .{ .width = .fill, .gap = 10 });
        _ = p.field(c, "Host", "127.0.0.1 or workstation name", &p.host_input, false);
        _ = p.field(c, "Port", "4789", &p.port_input, false);
        ui.divider(c);
        const token = p.field(c, "Token", "the 32 characters from relay", &p.token_input, false);
        ui.end(c);

        // Error message if any.
        if (p.connect_why_len > 0) {
            ui.row(c, .{ .width = .fill, .gap = 6, .align_items = .center, .padding = .all(10), .background = c.theme.danger, .radius = 8 });
            ui.text(c, "⚠", .{ .size = 14 });
            ui.text(c, p.connect_why[0..p.connect_why_len], .{
                .size = 12,
                .color = c.theme.background,
                .wrap = true,
            });
            ui.end(c);
        }

        // Connect button.
        if (ui.button(c, if (p.status == .connecting) "Connecting…" else "Connect", .{
            .size = 15,
            .variant = .primary,
            .width = .fill,
        }).clicked or token.submitted) p.connect();

        // Back button if already connected.
        if (p.status == .live) {
            if (ui.button(c, "Back to the tabs", .{ .size = 13, .variant = .ghost, .width = .fill }).clicked) {
                p.screen = .feed;
                p.draw();
            }
        }

        // Saved connections section.
        if (p.saved_connections.items.len > 0) {
            ui.divider(c);
            ui.column(c, .{ .width = .fill, .gap = 8 });
            ui.text(c, "Recent Connections", .{ .size = 14, .weight = .semibold });
            for (p.saved_connections.items, 0..) |conn, i| {
                ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center, .padding = .all(10), .background = c.theme.surface, .radius = 8, .border = c.theme.border });
                ui.column(c, .{ .gap = 2, .grow = 1 });
                ui.text(c, conn.name, .{ .size = 13, .weight = .medium });
                ui.text(c, if (conn.last_used > 0) "Recent" else "Saved", .{ .size = 11, .color = c.theme.muted });
                ui.end(c);
                if (ui.button(c, "Use", .{ .size = 11, .variant = .secondary }).clicked) {
                    p.loadConnection(i);
                }
                ui.end(c);
            }
            ui.end(c);
        }

        // Theme preference section.
        ui.divider(c);
        ui.column(c, .{ .width = .fill, .gap = 8 });
        ui.text(c, "Appearance", .{ .size = 14, .weight = .semibold });
        ui.row(c, .{ .width = .fill, .gap = 8 });
        const theme_options = [_]struct { label: []const u8, value: settings.ThemePreference }{
            .{ .label = "System", .value = .system },
            .{ .label = "Light", .value = .light },
            .{ .label = "Dark", .value = .dark },
        };
        for (theme_options) |opt| {
            const is_selected = p.theme_pref == opt.value;
            if (ui.button(c, opt.label, .{ .size = 12, .variant = if (is_selected) .primary else .secondary }).clicked) {
                if (p.theme_pref != opt.value) {
                    p.theme_pref = opt.value;
                    // Save the theme preference immediately.
                    const host = p.host[0..p.host_len];
                    const port_str = p.port_input.text();
                    const port = std.fmt.parseInt(u16, port_str, 10) catch p.port;
                    const token_str = p.token_input.text();
                    if (token_str.len == 32) {
                        var token_buf: [32]u8 = undefined;
                        @memcpy(&token_buf, token_str);
                        _ = settings.save(p.io, p.gpa, host, port, &token_buf, p.theme_pref);
                    }
                    p.notify(.info, "Theme changed. Restart app to apply.", .{});
                    p.draw();
                }
            }
        }
        ui.end(c);
        ui.text(c, "⚠ Restart the app to see the new theme", .{ .size = 11, .color = c.theme.accent, .wrap = true });
        ui.end(c);

        // Help section.
        ui.divider(c);
        ui.column(c, .{ .width = .fill, .gap = 8, .padding = .all(12), .background = c.theme.surface, .radius = 8 });
        ui.row(c, .{ .width = .fill, .gap = 6, .align_items = .center });
        ui.text(c, "💡", .{ .size = 14 });
        ui.text(c, "Quick Tips", .{ .size = 13, .weight = .semibold });
        ui.end(c);
        ui.text(c, "• On the same Wi-Fi: use the workstation's local IP\n• Over USB cable: adb reverse tcp:4789 tcp:4789, then 127.0.0.1\n• Over Tailscale: use the Tailscale IP address\n• The token is printed when you start nanoterm --relay", .{
            .size = 11,
            .color = c.theme.muted,
            .wrap = true,
        });
        ui.end(c);

        ui.end(c);
        ui.end(c);
    }

    /// A label and its field: what the connect screen is made of.
    fn field(p: *Phone, c: *ui.Context, label: []const u8, hint: []const u8, buffer: *ui.TextBuffer, password: bool) ui.TextFieldResult {
        _ = p;
        ui.text(c, label, .{ .size = 12, .weight = .medium, .color = c.theme.muted });
        return ui.textField(c, buffer, .{
            .placeholder = hint,
            .width = .fill,
            .size = 15,
            .password = password,
            .select_all_on_focus = true,
        });
    }

    /// One structured feed entry, rendered as a card with visual hierarchy.
    pub fn renderEntry(p: *Phone, c: *ui.Context, entry: Entry) void {
        const is_running = for (p.running.items) |k| {
            if (entry.session > 0 and k == entry.session) break true;
        } else false;

        switch (entry.kind) {
            .command => {
                _ = ui.div(c).column().wFull().gap(6)
                    .bg(c.theme.background).rounded(10)
                    .border(c.theme.border).p(12);
                ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
                ui.text(c, "▶", .{ .size = 12, .color = if (is_running) c.theme.accent else c.theme.accent });
                ui.text(c, entry.text, .{ .size = 13, .weight = .semibold, .mono = true, .wrap = true });
                ui.end(c);
                if (is_running) {
                    ui.row(c, .{ .gap = 6, .align_items = .center });
                    ui.text(c, "●", .{ .size = 8, .color = c.theme.accent });
                    ui.text(c, "running", .{ .size = 11, .color = c.theme.muted });
                    ui.end(c);
                }
                ui.end(c);
            },
            .output => {
                _ = ui.div(c).column().wFull()
                    .bg(c.theme.surface).rounded(8).pl(16).pr(10).py(8);
                ui.text(c, entry.text, .{ .size = 11, .mono = true, .wrap = true, .color = c.theme.muted });
                ui.end(c);
            },
            .agent_thought => {
                _ = ui.div(c).column().wFull().gap(6)
                    .rounded(10).p(12);
                ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
                ui.text(c, "💭", .{ .size = 14 });
                ui.text(c, "Agent thinking", .{ .size = 11, .weight = .medium, .color = c.theme.text });
                ui.end(c);
                ui.text(c, entry.text, .{ .size = 12, .wrap = true, .color = c.theme.muted });
                ui.end(c);
            },
            .agent_reply => {
                _ = ui.div(c).column().wFull().gap(6)
                    .bg(c.theme.background).rounded(10).border(c.theme.accent).p(12);
                ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
                ui.text(c, "🤖", .{ .size = 14 });
                ui.text(c, "Agent", .{ .size = 11, .weight = .semibold, .color = c.theme.accent });
                ui.end(c);
                ui.text(c, entry.text, .{ .size = 12, .wrap = true });
                ui.end(c);
            },
            .agent_tool => {
                _ = ui.div(c).column().wFull()
                    .bg(c.theme.surface).rounded(8).border(c.theme.border).p(10);
                ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
                ui.text(c, "🔧", .{ .size = 12 });
                ui.text(c, entry.text, .{ .size = 11, .mono = true, .wrap = true, .color = c.theme.muted });
                ui.end(c);
                ui.end(c);
            },
            .permission_ask => {
                _ = ui.div(c).column().wFull().gap(8)
                    .bg(c.theme.accent).rounded(10).p(12);
                ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
                ui.text(c, "⚑", .{ .size = 14 });
                ui.text(c, entry.text, .{ .size = 13, .weight = .medium, .wrap = true });
                ui.end(c);
                ui.end(c);
            },
            .permission_answer => {
                _ = ui.div(c).column().wFull()
                    .bg(c.theme.success).rounded(8).p(10);
                ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
                ui.text(c, "✓", .{ .size = 12, .weight = .bold });
                ui.text(c, entry.text, .{ .size = 11, .wrap = true, .color = c.theme.background });
                ui.end(c);
                ui.end(c);
            },
            .system => {
                _ = ui.div(c).column().wFull()
                    .bg(c.theme.surface).rounded(6).p(8);
                ui.text(c, entry.text, .{ .size = 11, .wrap = true, .color = c.theme.muted });
                ui.end(c);
            },
            .err => {
                _ = ui.div(c).column().wFull().gap(6)
                    .bg(c.theme.danger).rounded(10).p(12);
                ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
                ui.text(c, "⚠", .{ .size = 14 });
                ui.text(c, entry.text, .{ .size = 12, .weight = .medium, .wrap = true, .color = c.theme.background });
                ui.end(c);
                ui.end(c);
            },
        }
    }

    /// Gesture handling: swipe left/right to switch tabs, pull down to refresh.
    fn handleGestures(p: *Phone, c: *ui.Context) void {
        const input = c.input;
        
        // Track swipe start when pointer goes down.
        if (input.pressed and !p.swipe_tracking) {
            p.swipe_start_x = input.mouse.x;
            p.swipe_start_y = input.mouse.y;
            p.swipe_tracking = true;
            p.pull_distance = 0;
        }
        
        // Track horizontal swipe and vertical pull while dragging.
        if (p.swipe_tracking and input.down) {
            const dx = input.mouse.x - p.swipe_start_x;
            const dy = input.mouse.y - p.swipe_start_y;
            
            // Horizontal swipe: switch tabs when threshold reached.
            if (@abs(dx) > 80 and @abs(dx) > @abs(dy) * 2) {
                if (p.sessions.items.len > 1) {
                    const current_idx = for (p.sessions.items, 0..) |s, i| {
                        if (s.id == p.session) break i;
                    } else 0;
                    
                    const new_idx = if (dx > 0) 
                        (if (current_idx == 0) p.sessions.items.len - 1 else current_idx - 1)
                    else
                        (if (current_idx == p.sessions.items.len - 1) 0 else current_idx + 1);
                    
                    if (new_idx != current_idx) {
                        p.session = p.sessions.items[new_idx].id;
                        p.notify(.info, "swiped to tab {d}", .{p.session});
                    }
                }
                p.swipe_tracking = false;
            }
            
            // Vertical pull down: refresh.
            if (dy > 0 and @abs(dy) > @abs(dx) * 2) {
                p.pull_distance = dy;
            }
        }
        
        // Swipe ended: check for pull-to-refresh.
        if (p.swipe_tracking and !input.down) {
            p.swipe_tracking = false;
            
            // Pull down far enough triggers refresh.
            if (p.pull_distance > 120 and !p.pull_refreshing) {
                p.pull_refreshing = true;
                p.refresh();
                p.pull_distance = 0;
            }
        }
        
        // Decay pull distance when not pulling.
        if (!p.swipe_tracking and p.pull_distance > 0) {
            p.pull_distance = @max(0, p.pull_distance - 8);
        }
    }

    /// Refresh: ask the relay to resend everything (the `list` command).
    pub fn refresh(p: *Phone) void {
        if (p.status != .live) {
            p.pull_refreshing = false;
            return;
        }
        p.write("{\"op\":\"list\"}\n");
        p.pull_refreshing = false;
    }

    pub fn draw(p: *Phone) void {
        if (p.window) |w| w.redraw();
    }

    pub fn view(p: *Phone, c: *ui.Context) void {
        if (p.screen == .connect) return p.connectView(c);
        
        // Gesture detection: horizontal swipe to switch tabs, pull down to refresh.
        p.handleGestures(c);
        
        ui.column(c, .{
            .width = .fill,
            .height = .fill,
            .padding = c.safe_area,
            .background = c.theme.background,
        });
        
        // Pull-to-refresh indicator: shown when pulling down from top.
        if (p.pull_distance > 20) {
            const progress = @min(p.pull_distance / 120.0, 1.0);
            ui.row(c, .{ .width = .fill, .justify = .center, .padding = .{ .top = 8, .bottom = 4 } });
            if (progress >= 1.0) {
                ui.text(c, "↓ Release to refresh", .{ .size = 12, .color = c.theme.accent });
            } else {
                ui.text(c, "↓ Pull to refresh", .{ .size = 12, .color = c.theme.muted });
            }
            ui.end(c);
        }
        
        // What this is, and whether it is on.
        ui.column(c, .{ .width = .fill, .padding = .{ .top = 14, .bottom = 10, .left = 16, .right = 16 }, .gap = 4, .background = c.theme.background });
        ui.row(c, .{ .width = .fill, .align_items = .center, .gap = 8 });
        ui.text(c, "nanoterm", .{ .size = 20, .weight = .semibold });
        ui.spacer(c);
        // Only while there is something to stop: a button that does
        // nothing is a button that teaches nothing.
        if (p.running.items.len > 0) {
            ui.row(c, .{ .gap = 6, .align_items = .center });
            ui.text(c, "●", .{ .size = 10, .color = c.theme.accent });
            if (ui.button(c, "Stop", .{ .size = 12, .variant = .danger }).clicked) p.interrupt();
            ui.end(c);
        } else if (p.status != .live) {
            // Down: the way back in is the fields, not a dead screen.
            if (ui.button(c, "Reconnect", .{ .size = 12 }).clicked) p.toConnect();
        } else {
            if (ui.button(c, "Settings", .{ .size = 12, .variant = .ghost }).clicked) p.toConnect();
        }
        ui.end(c);
        if (p.sessions.items.len > 0) {
            ui.row(c, .{
                .width = .fill,
                .padding = .{ .bottom = 6, .left = 12, .right = 12 },
                .gap = 6,
            });
            for (p.sessions.items) |tab| {
                const active = tab.id == p.session;
                const has_activity = for (p.running.items) |k| {
                    if (k == tab.id or (k & turn_bit) == tab.id) break true;
                } else false;

                ui.row(c, .{ .gap = 4, .align_items = .center });
                const title = if (tab.title.len > 0) tab.title else c.print("tab {d}", .{tab.id});
                const btn_width: f32 = @floatFromInt(@min(title.len * 8 + 24, 140));
                if (active) {
                    _ = ui.button(c, title, .{
                        .size = 12,
                        .variant = .primary,
                        .width = .{ .px = btn_width },
                    });
                } else {
                    if (ui.button(c, title, .{
                        .size = 12,
                        .variant = .ghost,
                        .width = .{ .px = btn_width },
                    }).clicked) {
                        p.session = tab.id;
                        p.notify(.info, "switched to tab {d}", .{tab.id});
                    }
                }
                if (has_activity) {
                    ui.text(c, "●", .{ .size = 6, .color = c.theme.accent });
                }
                ui.end(c);
            }
            ui.end(c);
        }
        ui.row(c, .{ .width = .fill, .align_items = .center, .gap = 6 });
        {
            // A subtle pulse when something is running.
            if (p.running.items.len > 0) {
                const t = @as(f32, @floatFromInt(p.pulse_counter));
                const pulse: f32 = 0.5 + 0.5 * @sin(t * 4.0);
                p.pulse_counter += 1;
                ui.text(c, "●", .{ .size = 8.0 + pulse * 4.0, .color = c.theme.accent });
            }
            const dot_color = switch (p.status) {
                .live => c.theme.success,
                .connecting => c.theme.accent,
                .down => c.theme.danger,
            };
            ui.text(c, "●", .{ .size = 10, .color = dot_color });
            ui.textf(c, .{ .size = 12, .color = c.theme.muted }, "{s} · {s} · tab {d}", .{ p.where[0..p.where_len], p.status.label(), p.session });
        }
        ui.end(c);
        if (p.status == .down and p.why_len > 0) {
            ui.text(c, p.why[0..p.why_len], .{ .size = 12, .color = c.theme.danger, .wrap = true });
        }
        ui.end(c);
        ui.row(c, .{ .width = .fill, .padding = .{ .left = 16, .right = 16 }, .align_items = .center });
        ui.spacer(c);
        if (p.entries.items.len > 0) {
            if (ui.button(c, "Clear", .{ .size = 12, .variant = .ghost }).clicked) {
                for (p.entries.items) |*e| e.deinit(p.gpa);
                p.entries.clearRetainingCapacity();
            }
        }
        ui.end(c);
        ui.divider(c);
        // What came, the last of it at the bottom: structured cards.
        ui.scroll(c, .{
            .width = .fill,
            .grow = 1,
            .padding = .{ .left = 12, .right = 12, .top = 10, .bottom = 10 },
            .gap = 8,
            .follow_end = true,
            .background = c.theme.surface,
        });
        if (p.entries.items.len == 0) {
            ui.column(c, .{ .width = .fill, .gap = 8, .align_items = .center, .padding = .{ .top = 32 } });
            ui.text(c, "∅", .{ .size = 28, .color = c.theme.border });
            ui.text(c, "Nothing yet", .{ .size = 14, .weight = .medium });
            ui.text(c, "A command run on the workstation shows up here.", .{
                .size = 12,
                .color = c.theme.muted,
                .wrap = true,
            });
            ui.end(c);
        }
        for (p.entries.items, 0..) |entry, i| {
            ui.keyInt(c, i);
            p.renderEntry(c, entry);
        }
        ui.end(c);
        // What the agent is waiting on: permission cards with clear options.
        for (p.pending.items, 0..) |*q, qi| {
            ui.keyInt(c, 10000 + qi);
            ui.column(c, .{
                .width = .fill,
                .gap = 10,
                .background = c.theme.background,
                .border = c.theme.accent,
                .radius = 12,
                .padding = .all(14),
            });
            // Header: icon and title.
            ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
            ui.text(c, "⚑", .{ .size = 16, .color = c.theme.accent });
            ui.text(c, "Permission Required", .{ .size = 13, .weight = .semibold, .color = c.theme.accent });
            ui.end(c);
            // The question title.
            ui.text(c, q.title, .{ .size = 14, .weight = .medium, .wrap = true });
            // Detail if any.
            if (q.detail.len > 0) {
                ui.text(c, q.detail, .{ .size = 12, .color = c.theme.muted, .wrap = true });
            }
            ui.divider(c);
            // Options: vertical stack, each a full-width button.
            ui.column(c, .{ .width = .fill, .gap = 8 });
            for (q.options.items, 0..) |name, i| {
                const is_chosen = q.chosen == i;
                const btn_text = if (is_chosen) c.print("✓ {s}", .{name}) else name;
                if (ui.button(c, btn_text, .{
                    .size = 14,
                    .variant = if (is_chosen) .primary else .secondary,
                    .width = .fill,
                    .disabled = q.chosen != null,
                }).clicked) {
                    p.answer(q, i);
                }
            }
            ui.end(c);
            // Cancel/skip option at the bottom.
            if (q.chosen == null) {
                if (ui.button(c, "Skip", .{
                    .size = 12,
                    .variant = .ghost,
                    .width = .fill,
                }).clicked) {
                    // Remove the card without answering (will be re-answered at workstation).
                    var gone = p.pending.orderedRemove(qi);
                    gone.deinit(p.gpa);
                    p.push("skipped permission: {s}", .{q.title});
                }
            }
            ui.end(c);
        }
        // The composer: what to run or ask, and which.
        ui.column(c, .{
            .width = .fill,
            .padding = .{ .left = 12, .right = 12, .top = 8, .bottom = 10 },
            .gap = 6,
            .background = c.theme.surface,
            .border = c.theme.border,
        });
        ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
        _ = ui.segmented(c, &.{ "Run", "Ask" }, &p.mode);
        ui.spacer(c);
        // History buttons: up goes back, forward goes newer.
        if (p.history.items.len > 0) {
            if (ui.button(c, "↑", .{ .size = 11, .variant = .ghost }).clicked) {
                p.historyRecall(-1);
            }
            if (ui.button(c, "↓", .{ .size = 11, .variant = .ghost }).clicked) {
                p.historyRecall(1);
            }
        }
        // Clear the input if there is text.
        if (p.input.text().len > 0) {
            if (ui.button(c, "✕", .{ .size = 11, .variant = .ghost }).clicked) {
                p.input.clear();
            }
        }
        ui.end(c);
        const typed = ui.textField(c, &p.input, .{
            .placeholder = if (p.mode == 0) "a command" else "a question",
            .width = .fill,
            .bare = true,
            .size = 13,
            .select_all_on_focus = false,
        });
        ui.row(c, .{ .width = .fill, .gap = 8, .align_items = .center });
        ui.spacer(c);
        const can_send = p.input.text().len > 0 and p.session != 0 and p.status == .live;
        if (ui.button(c, "Send", .{
            .size = 12,
            .variant = .primary,
            .disabled = !can_send,
        }).clicked or typed.submitted) p.submit();
        ui.end(c);
        ui.end(c);
        ui.end(c);
        
        // Notifications overlay: shown at the bottom, above everything.
        p.pruneNotifications();
        if (p.notifications.items.len > 0) {
            ui.column(c, .{
                .width = .fill,
                .gap = 6,
                .padding = .{ .left = 16, .right = 16, .bottom = 16 },
            });
            for (p.notifications.items, 0..) |*n, i| {
                const bg_color = switch (n.kind) {
                    .info => c.theme.accent,
                    .success => c.theme.success,
                    .warning => c.theme.accent,
                    .err => c.theme.danger,
                };
                const icon = switch (n.kind) {
                    .info => "ℹ",
                    .success => "✓",
                    .warning => "⚠",
                    .err => "✕",
                };
                ui.row(c, .{
                    .width = .fill,
                    .gap = 8,
                    .align_items = .center,
                    .padding = .all(12),
                    .background = bg_color,
                    .radius = 10,
                });
                ui.text(c, icon, .{ .size = 16, .color = c.theme.background });
                ui.text(c, n.message, .{
                    .size = 13,
                    .color = c.theme.background,
                    .wrap = true,
                });
                if (ui.button(c, "✕", .{ .size = 11, .variant = .ghost }).clicked) {
                    p.dismissNotification(i);
                }
                ui.end(c);
            }
            ui.end(c);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const p = try Phone.create(init, args);
    defer p.destroy();

    const app = try nanoui.App.create(init, .{ .name = "nanoterm" });
    defer app.destroy();
    
    // Determine theme override based on preference.
    const theme_override: ?ui.Theme = switch (p.theme_pref) {
        .system => null, // Follow system appearance.
        .light => ui.Theme.light,
        .dark => ui.Theme.dark_theme,
    };
    
    p.window = try app.newWindow(.{
        .title = "nanoterm",
        .width = 430,
        .height = 932,
        .full_bleed = true,
        .theme = theme_override,
        .content = .{ .view = .init(p, Phone.view) },
        .on_close = .{ .ctx = p, .func = closed },
    });
    if (p.screen == .feed) p.open();
    // The keyboard from the start: the token, or a command.
    if (p.screen == .connect) p.host_input.focus() else p.input.focus();
    try app.run();
}

/// The window is going: nothing may draw into it any more.
fn closed(ctx: *anyopaque, _: *nanoui.Window) void {
    const p: *Phone = @ptrCast(@alignCast(ctx));
    p.window = null;
}

test {
    _ = @import("tests_phone.zig");
    _ = @import("settings.zig");
}
