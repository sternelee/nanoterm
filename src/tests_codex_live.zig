//! A live run of Codex through nanoterm's own Agent: the real `codex exec`
//! JSONL stream and its thread resume, the acceptance path minus the window.
//! Off by default: run with NANOTERM_LIVE_CODEX=1.
const std = @import("std");
const nanoui = @import("nanoui");
const agent_mod = @import("agent.zig");
const blocks = @import("blocks.zig");
const proc = @import("proc.zig");

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

fn turnDone(a: *agent_mod.Agent) bool {
    const t = a.current() orelse return false;
    return t.done;
}
fn pumpUntil(a: *agent_mod.Agent) !void {
    var waited: f64 = 0;
    while (!turnDone(a)) : (waited += 0.02) {
        if (waited > 120) return error.Timeout;
        nanoui.runFor(0.02);
    }
}
fn noopChanged(_: *anyopaque) void {}
fn noBlock(_: *anyopaque, _: []const u8, _: []const u8) ?*blocks.Block {
    return null;
}
var ctx_dummy: u8 = 0;

fn textOf(a: *agent_mod.Agent) []const u8 {
    var said: []const u8 = "";
    for (a.current().?.items.items) |*it| switch (it.*) {
        .text => |tx| if (tx.items.len > 0) {
            said = tx.items;
        },
        else => {},
    };
    return said;
}

test "live: codex turns run, resume, and run a command" {
    if (std.c.getenv("NANOTERM_LIVE_CODEX") == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    std.debug.print("\n[live] starting codex via Agent…\n", .{});

    const home = "/tmp/nanoterm-codex-live";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    std.Io.Dir.cwd().createDirPath(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};

    var store: [4][1024]u8 = undefined;
    var list: [4][]const u8 = undefined;
    var n: usize = 0;
    {
        const h = if (std.c.getenv("HOME")) |hv| std.mem.sliceTo(hv, 0) else "/Users/sternelee";
        const s = std.fmt.bufPrint(&store[n], "PATH=/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:{s}/.bun/bin", .{h}) catch "";
        if (s.len > 0) {
            list[n] = s;
            n += 1;
        }
        if (std.c.getenv("HOME")) |hv| {
            const hv2 = std.mem.sliceTo(hv, 0);
            const hs = std.fmt.bufPrint(&store[n], "HOME={s}", .{hv2}) catch "";
            if (hs.len > 0) {
                list[n] = hs;
                n += 1;
            }
        }
        if (std.c.getenv("TMPDIR")) |tv| {
            const tv2 = std.mem.sliceTo(tv, 0);
            const ts = std.fmt.bufPrint(&store[n], "TMPDIR={s}", .{tv2}) catch "";
            if (ts.len > 0) {
                list[n] = ts;
                n += 1;
            }
        }
    }

    const app = agent_mod.App{ .ctx = @ptrCast(&ctx_dummy), .changed = noopChanged, .newBlock = noBlock };
    const ag = try agent_mod.Agent.create(gpa, io, app, .codex, home);
    defer ag.destroy();
    ag.env = list[0..n];

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const al = arena_state.allocator();
    try ag.start(try proc.cStrings(al, &.{}), try proc.cStrings(al, list[0..n]));

    try ag.prompt("Reply with exactly the single word: pong");
    try pumpUntil(ag);
    var said = textOf(ag);
    std.debug.print("[live] thread={s} text={s}\n", .{ ag.codex_thread orelse "?", said });
    try std.testing.expect(containsIgnoreCase(said, "pong"));
    try std.testing.expect(ag.codex_thread != null);

    try ag.prompt("What exact single word did you reply with? Reply with that word only.");
    try pumpUntil(ag);
    said = textOf(ag);
    std.debug.print("[live] resumed text={s}\n", .{said});
    try std.testing.expect(containsIgnoreCase(said, "pong"));
    // A tool turn: the command and its output come back as a row.
    try ag.prompt("Run the shell command: echo hi. Then say done.");
    try pumpUntil(ag);
    var cmd_row: ?*agent_mod.Tool = null;
    for (ag.current().?.items.items) |*it| switch (it.*) {
        .tool => |*tl| if (std.mem.eql(u8, tl.kind, "command_execution")) {
            cmd_row = tl;
        },
        else => {},
    };
    const row = cmd_row orelse return error.NoToolRow;
    std.debug.print("[live] tool kind={s} cmd={s} exit={?d} out={s}\n", .{ row.kind, row.command.items, row.exit_code, row.detail.items });
    try std.testing.expect(std.mem.indexOf(u8, row.command.items, "echo hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, row.detail.items, "hi") != null);
    try std.testing.expectEqual(@as(?i64, 0), row.exit_code);

    // Let the turn's process exit and be reaped before teardown.
    var drain: f64 = 0;
    while (ag.codexAlive() != null and drain < 5) : (drain += 0.02) nanoui.runFor(0.02);
    std.debug.print("[live] OK: codex text, resume, and a command\n", .{});
}
