//! What an agent lets the user choose, against a fake ACP agent: config
//! options (model, mode) set through session/set_config_option, slash
//! commands offered as "/" is typed. Nothing reaches the user's agents.
const std = @import("std");
const agent_mod = @import("agent.zig");
const blocks = @import("blocks.zig");
const proc = @import("proc.zig");

fn pumpUntil(ctx: anytype, comptime done: fn (@TypeOf(ctx)) bool) !void {
    var waited: f64 = 0;
    while (!done(ctx)) : (waited += 0.02) {
        if (waited > 20) return error.Timeout;
        @import("nanoui").runFor(0.02);
    }
}

const fake_agent =
    \\import json, sys
    \\def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
    \\model = {"id": "model", "name": "Model", "category": "model", "type": "select", "currentValue": "sonnet",
    \\         "options": [{"value": "sonnet", "name": "Sonnet"}, {"value": "opus", "name": "Opus", "description": "smartest"}]}
    \\mode = {"id": "mode", "name": "Mode", "category": "mode", "type": "select", "currentValue": "default",
    \\        "options": [{"value": "default", "name": "Default"}, {"value": "plan", "name": "Plan"}]}
    \\for line in sys.stdin:
    \\    m = json.loads(line)
    \\    method = m.get("method")
    \\    if method == "initialize":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1}})
    \\    elif method == "session/new":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s1", "configOptions": [model, mode]}})
    \\        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {
    \\            "sessionUpdate": "available_commands_update",
    \\            "availableCommands": [{"name": "review", "description": "review the changes", "input": {"hint": "<what>"}}]}}})
    \\    elif method == "session/set_config_option":
    \\        p = m["params"]
    \\        for o in (model, mode):
    \\            if o["id"] == p["configId"]: o["currentValue"] = p["value"]
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"configOptions": [model, mode]}})
    \\        if p["configId"] == "mode":
    \\            send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "current_mode_update", "currentModeId": p["value"]}}})
    \\
;

const Host = struct {
    fn changed(_: *anyopaque) void {}
    fn newBlock(_: *anyopaque, _: []const u8, _: []const u8) ?*blocks.Block {
        return null;
    }
};

test "an agent's models, modes and slash commands" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = "/tmp/nanoterm-test-config";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/agent.py", .data = fake_agent });

    var host: u8 = 0;
    const a = try agent_mod.Agent.create(gpa, io, .{ .ctx = &host, .changed = Host.changed, .newBlock = Host.newBlock }, .claude, dir);
    defer a.destroy();
    try a.start(try proc.cStrings(arena, &.{ "/usr/bin/python3", "-I", dir ++ "/agent.py" }), try proc.cStrings(arena, &.{"PATH=/usr/bin:/bin"}));
    try pumpUntil(a, struct {
        fn f(x: *agent_mod.Agent) bool {
            return x.status == .ready and x.config.commands.items.len > 0;
        }
    }.f);
    const model = a.config.find("model").?;
    try std.testing.expectEqualStrings("Sonnet", model.currentName());
    try std.testing.expectEqualStrings("<what>", a.config.commands.items[0].hint);

    // Choosing a model shows at once, and the agent confirms it.
    a.setOption("model", "opus");
    try std.testing.expectEqualStrings("Opus", a.config.find("model").?.currentName());
    a.setOption("mode", "plan");
    try pumpUntil(a, struct {
        fn f(x: *agent_mod.Agent) bool {
            const m = x.config.find("mode") orelse return false;
            const md = x.config.find("model") orelse return false;
            return std.mem.eql(u8, m.current, "plan") and std.mem.eql(u8, md.current, "opus") and x.client.pending.count() == 0;
        }
    }.f);
    try std.testing.expectEqualStrings("smartest", a.config.find("model").?.choices[1].description);
}

/// Covers an ACP agent whose last line sits unflushed: the first answer arrives after the
/// second prompt was sent.
const lagging_agent =
    \\import json, sys
    \\def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
    \\def chunk(t): send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": t}}}})
    \\waiting = None
    \\for line in sys.stdin:
    \\    m = json.loads(line)
    \\    method = m.get("method")
    \\    if method == "initialize":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1}})
    \\    elif method == "session/new":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "s1"}})
    \\    elif method == "session/prompt":
    \\        if waiting is None:
    \\            chunk("one")
    \\            waiting = m["id"]
    \\        else:
    \\            send({"jsonrpc": "2.0", "id": waiting, "result": {"stopReason": "end_turn"}})
    \\            chunk("two")
    \\            send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
    \\
;

fn turnText(t: *agent_mod.Turn) []const u8 {
    for (t.items.items) |it| switch (it) {
        .text => |l| return l.items,
        else => {},
    };
    return "";
}

test "a late answer ends its own turn, not the one sent after it" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = "/tmp/nanoterm-test-lag";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/agent.py", .data = lagging_agent });
    var host: u8 = 0;
    const a = try agent_mod.Agent.create(gpa, io, .{ .ctx = &host, .changed = Host.changed, .newBlock = Host.newBlock }, .claude, dir);
    defer a.destroy();
    try a.start(try proc.cStrings(arena, &.{ "/usr/bin/python3", "-I", dir ++ "/agent.py" }), try proc.cStrings(arena, &.{"PATH=/usr/bin:/bin"}));
    try pumpUntil(a, struct {
        fn f(x: *agent_mod.Agent) bool {
            return x.status == .ready;
        }
    }.f);
    try a.promptWith(null, "first", &.{});
    try pumpUntil(a, struct {
        fn f(x: *agent_mod.Agent) bool {
            return turnText(x.turns.items[0]).len > 0;
        }
    }.f);
    try std.testing.expect(!a.turns.items[0].done);
    try a.promptWith(null, "second", &.{});
    try pumpUntil(a, struct {
        fn f(x: *agent_mod.Agent) bool {
            return x.turns.items.len == 2 and x.turns.items[1].done;
        }
    }.f);
    try std.testing.expect(a.turns.items[0].done);
    try std.testing.expectEqualStrings("one", turnText(a.turns.items[0]));
    try std.testing.expectEqualStrings("two", turnText(a.turns.items[1]));
    try std.testing.expectEqual(agent_mod.Status.ready, a.status);
}
