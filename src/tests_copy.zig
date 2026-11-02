//! The agent's reply, copied: the Copy reply button by its name puts the
//! reply on the clipboard as one text — its messages, in order, a blank
//! line between them. The Tester's clipboard takes it; the system's is
//! never touched.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const agent_mod = @import("agent.zig");
const proc = @import("proc.zig");
const view = @import("view.zig");
const view_turn = @import("view_turn.zig");
const theme = @import("theme.zig");

const fake_agent =
    \\import json, sys
    \\def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
    \\def up(u): send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": u}})
    \\for line in sys.stdin:
    \\    m = json.loads(line)
    \\    method = m.get("method")
    \\    if method == "initialize":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1}})
    \\    elif method == "session/new":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s1"}})
    \\    elif method == "session/prompt":
    \\        up({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "First message.\n"}})
    \\        up({"sessionUpdate": "agent_thought_chunk", "content": {"type": "text", "text": "Between them, a thought."}})
    \\        up({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "Second message."}})
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
    \\
;

fn list(arena: std.mem.Allocator, s: []const u8) !std.ArrayList(u8) {
    var l: std.ArrayList(u8) = .empty;
    try l.appendSlice(arena, s);
    return l;
}

test "copying skips empty messages and blank-lines between the rest" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var t: agent_mod.Turn = .{ .prompt = try arena.dupe(u8, "why"), .agent = .claude, .started = 0 };
    try t.items.append(arena, .{ .text = try list(arena, "One.\n") });
    try t.items.append(arena, .{ .thought = try list(arena, "a thought") });
    try t.items.append(arena, .{ .text = try list(arena, "   ") });
    try t.items.append(arena, .{ .text = try list(arena, "\nTwo.\n") });
    const text = view_turn.replyText(arena, &t) orelse return error.NoReply;
    try std.testing.expectEqualStrings("One.\n\nTwo.", text);

    var none: agent_mod.Turn = .{ .prompt = try arena.dupe(u8, "why"), .agent = .claude, .started = 0 };
    try none.items.append(arena, .{ .text = try list(arena, " \n") });
    try std.testing.expect(view_turn.replyText(arena, &none) == null);
}

test "the agent's reply copies as one text, its messages in order" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-copy";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/agent.py", .data = fake_agent });
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("TMPDIR", home);
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    const s = try w.newTab(home);
    const ag = try agent_mod.Agent.create(gpa, io, .{ .ctx = s, .changed = session_mod.Session.changed, .newBlock = struct {
        fn f(_: *anyopaque, _: []const u8, _: []const u8) ?*@import("blocks.zig").Block {
            return null;
        }
    }.f }, .claude, home);
    s.agent = ag;
    try ag.start(try proc.cStrings(arena, &.{ "/usr/bin/python3", "-I", home ++ "/agent.py" }), try proc.cStrings(arena, &.{"PATH=/usr/bin:/bin"}));
    s.ask("Say two things");
    var waited: f64 = 0;
    while (waited < 20) : (waited += 0.02) {
        nanoui.runFor(0.02);
        if (ag.current()) |t| if (t.done) break;
    }
    try std.testing.expect(ag.current().?.done);

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 900, .height = 700, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    // The steps fold: the first message is inside them, the reply tail stays.
    try std.testing.expect(!t.containsText("First message."));
    try std.testing.expect(t.hasText("Second message."));
    // Copy reply is a hover action: it shows once the pointer is over the turn.
    try std.testing.expect(!t.hasText("Copy reply"));
    try t.clickText("Second message.");
    try std.testing.expect(t.hasText("Copy reply"));
    try t.screenshot("/tmp/nanoterm-copy.png");
    try t.clickText("Copy reply");
    t.settle(1);
    // The whole reply, the folded message too.
    try std.testing.expectEqualStrings("First message.\n\nSecond message.", t.clipboard.items);
}
