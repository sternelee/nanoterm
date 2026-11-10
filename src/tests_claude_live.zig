//! A live run of Claude Code through nanoterm's own Agent: the real CLI,
//! the real stream-json transport, the real turn mapping — the acceptance
//! path minus the window. Off by default (it spends API credit and needs a
//! signed-in claude): run with NANOTERM_LIVE_CLAUDE=1.
const std = @import("std");
const nanoui = @import("nanoui");
const agent_mod = @import("agent.zig");
const blocks = @import("blocks.zig");
const proc = @import("proc.zig");

fn pumpUntil(comptime done: fn (*agent_mod.Agent) bool, a: *agent_mod.Agent) !void {
    var waited: f64 = 0;
    while (!done(a)) : (waited += 0.02) {
        if (waited > 120) return error.Timeout;
        nanoui.runFor(0.02);
    }
}

fn turnDone(a: *agent_mod.Agent) bool {
    const t = a.current() orelse return false;
    return t.done;
}

fn noopChanged(_: *anyopaque) void {}
fn noBlock(_: *anyopaque, _: []const u8, _: []const u8) ?*blocks.Block {
    return null;
}

var ctx_dummy: u8 = 0;

/// "KEY=value" for the environment variable `key` (a literal), in `buf`.
fn envVal(comptime key: [:0]const u8, buf: *[1024]u8, out: *[]const u8) bool {
    const v = std.c.getenv(key) orelse return false;
    const s = std.mem.sliceTo(v, 0);
    if (s.len + key.len + 1 > buf.len) return false;
    @memcpy(buf[0..key.len], key);
    buf[key.len] = '=';
    @memcpy(buf[key.len + 1 ..][0..s.len], s);
    out.* = buf[0 .. key.len + 1 + s.len];
    return true;
}

test "live: a claude turn through the Agent runs and answers" {
    if (std.c.getenv("NANOTERM_LIVE_CLAUDE") == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    std.debug.print("\n[live] starting claude via Agent…\n", .{});

    const home = "/tmp/nanoterm-claude-live";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    std.Io.Dir.cwd().createDirPath(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    var store: [6][1024]u8 = undefined;
    var list: [6][]const u8 = undefined;
    var n: usize = 0;
    var tmp: []const u8 = undefined;
    // PATH: the test's (may be unset), plus where installers put claude.
    {
        const h = if (std.c.getenv("HOME")) |hv| std.mem.sliceTo(hv, 0) else "/Users/sternelee";
        const p = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin";
        const s = std.fmt.bufPrint(&store[n], "PATH={s}:{s}/.bun/bin:{s}/.local/bin:/opt/homebrew/bin", .{ p, h, h }) catch "";
        if (s.len > 0) {
            list[n] = s;
            n += 1;
        }
    }
    if (envVal("HOME", &store[n], &tmp)) {
        list[n] = tmp;
        n += 1;
    }
    if (envVal("TMPDIR", &store[n], &tmp)) {
        list[n] = tmp;
        n += 1;
    }
    if (envVal("USER", &store[n], &tmp)) {
        list[n] = tmp;
        n += 1;
    }
    if (envVal("SHELL", &store[n], &tmp)) {
        list[n] = tmp;
        n += 1;
    }
    if (envVal("LANG", &store[n], &tmp)) {
        list[n] = tmp;
        n += 1;
    }

    const app = agent_mod.App{ .ctx = @ptrCast(&ctx_dummy), .changed = noopChanged, .newBlock = noBlock };
    const ag = try agent_mod.Agent.create(gpa, io, app, .claude, home);
    defer ag.destroy();
    ag.env = list[0..n];

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const al = arena_state.allocator();
    try ag.start(try proc.cStrings(al, &.{}), try proc.cStrings(al, list[0..n]));
    try ag.prompt("Reply with exactly the single word: pong");
    try pumpUntil(turnDone, ag);
    std.debug.print("[live] session={s}\n", .{ag.session orelse "?"});

    const t = ag.current() orelse return error.NoTurn;
    try std.testing.expect(t.done);
    var saw_text = false;
    for (t.items.items) |it| switch (it) {
        .text => |txt| {
            if (txt.items.len > 0) saw_text = true;
            std.debug.print("[live] assistant text: {s}\n", .{txt.items});
        },
        else => {},
    };
    try std.testing.expect(saw_text);
    std.debug.print("[live] OK: turn done with assistant text\n", .{});
}
