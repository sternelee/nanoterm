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
fn pendingPermission(a: *agent_mod.Agent) ?*agent_mod.Permission {
    const t = a.current() orelse return null;
    for (t.items.items) |*it| switch (it.*) {
        .permission => |*p| if (p.chosen == null) return p,
        else => {},
    };
    return null;
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

/// A 1x1 red PNG.
const red_dot_png = [_]u8{
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0,
    1, 8, 2, 0, 0, 0, 144, 119, 83, 222, 0, 0, 0, 12, 73, 68, 65, 84, 120, 218, 99,
    248, 207, 192, 0, 0, 3, 1, 1, 0, 247, 3, 65, 67, 0, 0, 0, 0, 73, 69, 78, 68,
    174, 66, 96, 130,
};

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

    // init populated the palette and the model menu.
    try std.testing.expect(ag.config.commands.items.len > 0);
    try std.testing.expect(ag.config.find("model") != null);
    std.debug.print("[live] commands={d}, model menu={}\n", .{ ag.config.commands.items.len, ag.config.find("model") != null });

    // Turn 2: a shell tool — the can_use_tool card must appear, and Allow it must run.
    try ag.prompt("Use the shell to run exactly: echo hello-from-claude");
    var waited: f64 = 0;
    var allowed = false;
    while (!turnDone(ag)) : (waited += 0.02) {
        if (waited > 150) return error.TimeoutTools;
        nanoui.runFor(0.02);
        if (!allowed) {
            if (pendingPermission(ag)) |p| {
                std.debug.print("[live] permission card: {s}\n", .{p.title});
                ag.answer(p, 0); // Allow
                allowed = true;
            }
        }
    }
    const t2 = ag.current().?;
    try std.testing.expect(t2.done);
    var ran = false;
    for (t2.items.items) |it| switch (it) {
        .tool => |tl| {
            if (tl.status != .pending and tl.status != .in_progress) ran = true;
            std.debug.print("[live] tool {s} {s}: {s}\n", .{ tl.kind, tl.title.items, tl.detail.items });
        },
        else => {},
    };
    // The user's own settings may auto-allow a command, so a card is not
    // guaranteed; either way the tool must have run to a terminal status.
    try std.testing.expect(ran);
    std.debug.print("[live] OK: tool ran (card={})\n", .{allowed});

    // The model menu, then a running set_model.
    {
        const mo = ag.config.find("model").?;
        try std.testing.expect(mo.choices.len >= 2);
        std.debug.print("[live] model choices:", .{});
        for (mo.choices) |ch| std.debug.print(" {s}", .{ch.value});
        std.debug.print("\n", .{});
    }
    ag.setOption("model", "haiku");
    try std.testing.expectEqualStrings("haiku", ag.config.find("model").?.currentName());
    try ag.prompt("Reply with exactly the single word: ok2");
    try pumpUntil(turnDone, ag);
    std.debug.print("[live] after set_model, turn done\n", .{});

    // A picture as a base64 image block reaches claude.
    {
        const imgs = try gpa.alloc(agent_mod.Image, 1);
        imgs[0] = .{
            .name = try gpa.dupe(u8, "dot.png"),
            .mime = "image/png",
            .data = try gpa.dupe(u8, &red_dot_png),
            .path = try gpa.dupe(u8, ""),
        };
        try ag.promptWith(null, "What is the color of this 1x1 image? Reply with one word.", imgs);
        try pumpUntil(turnDone, ag);
        var got = false;
        for (ag.current().?.items.items) |it| switch (it) {
            .text => |tx| {
                if (tx.items.len > 0) got = true;
            },
            else => {},
        };
        try std.testing.expect(got);
        std.debug.print("[live] image turn answered\n", .{});
    }

    // Resume: a second Agent continues the same claude session.
    {
        const sid = ag.session orelse return error.NoSession;
        const sid_copy = try gpa.dupe(u8, sid);
        defer gpa.free(sid_copy);
        const ag2 = try agent_mod.Agent.create(gpa, io, app, .claude, home);
        defer ag2.destroy();
        ag2.env = list[0..n];
        // Validates that --mcp-config (the visual server shape) is accepted.
        ag2.mcp = .{ .name = "livemcp", .command = "/bin/true", .args = &.{} };
        ag2.setResume(sid_copy);
        try ag2.start(try proc.cStrings(al, &.{}), try proc.cStrings(al, list[0..n]));
        try ag2.prompt("Reply with exactly the single word: resumed");
        try pumpUntil(turnDone, ag2);
        std.debug.print("[live] resume session={s} (was {s})\n", .{ ag2.session orelse "?", sid });
        try std.testing.expect(ag2.session != null);
    }
}
