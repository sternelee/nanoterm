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
fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or hay.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var ok = true;
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(hay[i + j]) != std.ascii.toLower(ch)) {
                ok = false;
                break;
            }
        }
        if (ok) return true;
    }
    return false;
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

/// A 32x32 solid red PNG.
const red_dot_png = [_]u8{
    137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82,
    0, 0, 0, 32, 0, 0, 0, 32, 8, 2, 0, 0, 0, 252, 24, 237,
    163, 0, 0, 0, 39, 73, 68, 65, 84, 120, 218, 237, 205, 177, 9, 0,
    0, 8, 192, 176, 254, 255, 180, 94, 225, 32, 4, 178, 167, 169, 83, 9,
    4, 2, 129, 64, 32, 16, 8, 4, 130, 47, 193, 2, 50, 195, 252, 46,
    112, 253, 35, 61, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130,
};

/// A tiny stdio MCP server: initialize, tools/list (one `ping`), tools/call
/// (writes the marker it was given, answers "pong-mcp").
const mcp_server =
    \\#!/usr/bin/env python3
    \\import json, sys
    \\marker = sys.argv[1] if len(sys.argv) > 1 else "/tmp/mcp-called"
    \\def send(o):
    \\    sys.stdout.write(json.dumps(o) + "\n"); sys.stdout.flush()
    \\for line in sys.stdin:
    \\    line = line.strip()
    \\    if not line: continue
    \\    try: m = json.loads(line)
    \\    except Exception: continue
    \\    mid, method = m.get("id"), m.get("method")
    \\    if method == "initialize":
    \\        send({"jsonrpc":"2.0","id":mid,"result":{"protocolVersion":"2024-11-05","capabilities":{"tools":{}},"serverInfo":{"name":"livemcp","version":"1"}}})
    \\    elif method == "tools/list":
    \\        send({"jsonrpc":"2.0","id":mid,"result":{"tools":[{"name":"ping","description":"Return pong-mcp","inputSchema":{"type":"object","properties":{}}}]}})
    \\    elif method == "tools/call":
    \\        open(marker, "w").write("called")
    \\        send({"jsonrpc":"2.0","id":mid,"result":{"content":[{"type":"text","text":"pong-mcp"}],"isError":False}})
    \\    elif mid is not None:
    \\        send({"jsonrpc":"2.0","id":mid,"result":{}})
    \\
;

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
    // The model menu comes from claude's initialize response (its own list),
    // which arrives at start without a prompt; wait briefly for it.
    var wm: f64 = 0;
    while (ag.config.find("model") == null) : (wm += 0.02) {
        if (wm > 8) break;
        nanoui.runFor(0.02);
    }
    try std.testing.expect(ag.config.find("model") != null);
    std.debug.print("[live] menu before prompt: {}", .{ag.config.find("model") != null});
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

    // The model menu, then a running set_model.
    {
        const mo = ag.config.find("model").?;
        try std.testing.expect(mo.choices.len >= 2);
        std.debug.print("[live] model choices:", .{});
        for (mo.choices) |ch| std.debug.print(" [{s}]=>{s}", .{ ch.value, ch.name });
        std.debug.print("\n", .{});
    }
    // A value from claude's own menu (the list the picker shows).
    ag.setOption("model", "sonnet");
    {
        const mo2 = ag.config.find("model").?;
        std.debug.print("[live] after setOption current={s} name={s} choices={d}\n", .{ mo2.current, mo2.currentName(), mo2.choices.len });
        try std.testing.expectEqualStrings("sonnet", mo2.current);
    }
    try ag.prompt("Reply with exactly the single word: ok2");
    try pumpUntil(turnDone, ag);
    std.debug.print("[live] after switch(sonnet), turn done; modelUsage={s}\n", .{ag.claude_model_used orelse "?"});

    // A picture as a base64 image block reaches claude.
    {
        const imgs = try gpa.alloc(agent_mod.Image, 1);
        imgs[0] = .{
            .name = try gpa.dupe(u8, "dot.png"),
            .mime = "image/png",
            .data = try gpa.dupe(u8, &red_dot_png),
            .path = try gpa.dupe(u8, ""),
        };
        try ag.promptWith(null, "What is the color of this image? Reply with one word.", imgs);
        try pumpUntil(turnDone, ag);
        var said: []const u8 = "";
        for (ag.current().?.items.items) |*it| switch (it.*) {
            .text => |tx| if (tx.items.len > 0) {
                said = tx.items;
            },
            else => {},
        };
        try std.testing.expect(said.len > 0);
        std.debug.print("[live] image answer: {s}\n", .{said});
        // The image is red: naming it means the image reached the model.
        try std.testing.expect(containsIgnoreCase(said, "red"));
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
        try ag2.prompt("What was the last single word you replied with? Reply with that word only.");
        try pumpUntil(turnDone, ag2);
        var said2: []const u8 = "";
        for (ag2.current().?.items.items) |*it| switch (it.*) {
            .text => |tx| if (tx.items.len > 0) {
                said2 = tx.items;
            },
            else => {},
        };
        std.debug.print("[live] resume session={s} (was {s}), answer: {s}\n", .{ ag2.session orelse "?", sid, said2 });
        try std.testing.expect(ag2.session != null);
        // Resumed context: it recalls the last word from before the new Agent ("Red").
        try std.testing.expect(containsIgnoreCase(said2, "red"));
    }

    // A slash command goes as plain user text; claude runs it and its output
    // arrives in `result` (no assistant message) — shown as the turn's text.
    try ag.prompt("/cost");
    try pumpUntil(turnDone, ag);
    {
        var said: []const u8 = "";
        for (ag.current().?.items.items) |it| switch (it) {
            .text => |tx| if (tx.items.len > 0) {
                said = tx.items;
            },
            else => {},
        };
        std.debug.print("[live] /cost output: {s}\n", .{said[0..@min(said.len, 60)]});
        try std.testing.expect(containsIgnoreCase(said, "cost"));
    }

    // A terminal-only command is refused with a clear note, not sent.
    std.debug.print("[live] terminal cmds: {d}\n", .{ag.claude_terminal.items.len});
    if (ag.claude_terminal.items.len > 0) {
        const cmd = ag.claude_terminal.items[0];
        var buf: [128]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "/{s}", .{cmd});
        try ag.prompt(line);
        try pumpUntil(turnDone, ag);
        var noted = false;
        for (ag.current().?.items.items) |it| switch (it) {
            .note => |nt| {
                if (containsIgnoreCase(nt, "needs Claude")) noted = true;
            },
            else => {},
        };
        std.debug.print("[live] /{s} terminal note: {}\n", .{ cmd, noted });
        try std.testing.expect(noted);
    }

    // A real MCP server: its ping tool must actually be called (it writes a
    // marker), and claude's request for it must reach us as a card we allow.
    {
        const script = try std.fmt.allocPrint(gpa, "{s}/mcp.py", .{home});
        const marker = try std.fmt.allocPrint(gpa, "{s}/mcp-called", .{home});
        const ag3 = try agent_mod.Agent.create(gpa, io, app, .claude, home);
        ag3.env = list[0..n];
        ag3.mcp = .{ .name = "livemcp", .command = script, .args = &.{marker} };
        defer ag3.destroy();
        defer gpa.free(script);
        defer gpa.free(marker);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script, .data = mcp_server, .flags = .{ .permissions = .executable_file } });
        try ag3.start(try proc.cStrings(al, &.{}), try proc.cStrings(al, list[0..n]));
        try ag3.prompt("Use the livemcp MCP server's ping tool, then tell me exactly what it returned.");
        var waited3: f64 = 0;
        var answered = false;
        while (!turnDone(ag3)) : (waited3 += 0.02) {
            if (waited3 > 150) return error.TimeoutMcp;
            nanoui.runFor(0.02);
            if (pendingPermission(ag3)) |pm| {
                std.debug.print("[live] mcp permission: {s}\n", .{pm.title});
                ag3.answer(pm, 0);
                answered = true;
            }
        }
        std.Io.Dir.cwd().access(io, marker, .{}) catch return error.McpNotCalled;
        std.debug.print("[live] OK: MCP tool called (card={})\n", .{answered});
    }
}
