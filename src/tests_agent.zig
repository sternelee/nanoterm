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

const fake_pi =
    \\import json, sys
    \\def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
    \\model = {"id": "sonnet", "name": "Sonnet", "provider": "anthropic"}
    \\state = {"model": model, "thinkingLevel": "high", "sessionId": "pi-1", "isStreaming": False}
    \\def started(): send({"type": "agent_start"})
    \\def settled(): send({"type": "agent_settled", "aborted": False})
    \\for line in sys.stdin:
    \\    m = json.loads(line)
    \\    kind, rid = m.get("type"), m.get("id")
    \\    def ok(data=None): send({"id": rid, "type": "response", "command": kind, "success": True, "data": data})
    \\    if kind == "get_state":
    \\        ok(state)
    \\    elif kind == "get_available_models":
    \\        ok({"models": [model, {"id": "opus", "name": "Opus", "provider": "anthropic"}]})
    \\    elif kind == "get_available_thinking_levels":
    \\        ok({"levels": ["off", "high"]})
    \\    elif kind == "get_commands":
    \\        ok({"commands": [{"name": "review", "description": "review the changes", "source": "prompt"}]})
    \\    elif kind == "set_model":
    \\        if m["modelId"] == "missing":
    \\            send({"id": rid, "type": "response", "command": kind, "success": False, "error": "no such model"})
    \\        else:
    \\            model.update({"provider": m["provider"], "id": m["modelId"]})
    \\            ok({"id": m["modelId"], "name": m["modelId"].title(), "provider": m["provider"]})
    \\    elif kind == "set_thinking_level":
    \\        state["thinkingLevel"] = m["level"]
    \\        ok({})
    \\        send({"type": "thinking_level_changed", "level": m["level"]})
    \\    elif kind == "prompt" and m["message"] == "first":
    \\        ok({"disposition": "started"})
    \\        started()
    \\        send({"type": "turn_start"})
    \\        send({"type": "message_start", "message": {"role": "assistant", "content": []}})
    \\        send({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "one"}})
    \\    elif kind == "prompt" and m["message"] == "second":
    \\        assert m.get("streamingBehavior") == "followUp"
    \\        ok({"disposition": "queued"})
    \\        settled()
    \\        started()
    \\        send({"type": "turn_start"})
    \\        send({"type": "message_start", "message": {"role": "assistant", "content": []}})
    \\        send({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "two"}})
    \\        send({"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": "two"}], "stopReason": "stop"}})
    \\        settled()
    \\    elif kind == "prompt":
    \\        ok({"disposition": "started"})
    \\        started()
    \\        send({"type": "turn_start"})
    \\        send({"type": "message_start", "message": {"role": "assistant", "content": []}})
    \\        send({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 0, "delta": "thinking: "}})
    \\        send({"type": "message_update", "assistantMessageEvent": {"type": "thinking_start", "contentIndex": 0}})
    \\        send({"type": "message_update", "assistantMessageEvent": {"type": "thinking_delta", "contentIndex": 0, "delta": "a plan"}})
    \\        send({"type": "message_update", "assistantMessageEvent": {"type": "toolcall_start", "contentIndex": 1, "id": "call_1", "toolName": "bash"}})
    \\        send({"type": "message_update", "assistantMessageEvent": {"type": "toolcall_end", "contentIndex": 1, "toolCall": {"type": "toolCall", "id": "call_1", "name": "bash", "arguments": {"command": "ls -la"}}}})
    \\        send({"type": "tool_execution_start", "toolCallId": "call_1", "toolName": "bash", "args": {"command": "ls -la"}})
    \\        send({"type": "tool_execution_update", "toolCallId": "call_1", "toolName": "bash", "args": {"command": "ls -la"}, "partialResult": {"content": [{"type": "text", "text": "partial"}]}})
    \\        send({"type": "tool_execution_end", "toolCallId": "call_1", "toolName": "bash", "result": {"content": [{"type": "text", "text": "a.txt"}, {"type": "text", "text": "b.txt"}]}, "isError": False})
    \\        send({"type": "message_update", "assistantMessageEvent": {"type": "text_delta", "contentIndex": 2, "delta": "done"}})
    \\        send({"type": "message_end", "message": {"role": "assistant", "content": [{"type": "text", "text": "thinking: "}, {"type": "thinking", "thinking": "a plan"}, {"type": "text", "text": "done"}], "stopReason": "stop"}})
    \\        send({"type": "turn_end", "message": {}, "toolResults": []})
    \\        send({"type": "agent_end", "messages": [], "willRetry": False})
    \\        settled()
    \\    elif kind == "abort":
    \\        ok({})
    \\        settled()
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
    return turnTextAt(t, 0);
}

/// The `n`th text item: text either side of a tool call is its own item.
fn turnTextAt(t: *agent_mod.Turn, n: usize) []const u8 {
    var i: usize = 0;
    for (t.items.items) |it| switch (it) {
        .text => |l| {
            if (i == n) return l.items;
            i += 1;
        },
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

test "Pi over RPC: state, tools, config and a settled turn" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = "/tmp/nanoterm-test-pi";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/pi.py", .data = fake_pi });

    var host: u8 = 0;
    const a = try agent_mod.Agent.create(gpa, io, .{ .ctx = &host, .changed = Host.changed, .newBlock = Host.newBlock }, .pi, dir);
    defer a.destroy();
    try a.start(try proc.cStrings(arena, &.{ "/usr/bin/python3", "-I", dir ++ "/pi.py" }), try proc.cStrings(arena, &.{"PATH=/usr/bin:/bin"}));
    try pumpUntil(a, struct {
        fn f(x: *agent_mod.Agent) bool {
            return x.status == .ready and x.config.commands.items.len > 0 and x.config.find("model") != null;
        }
    }.f);
    // Its model, as provider/id, and the levels it offers.
    try std.testing.expectEqualStrings("anthropic/sonnet", a.config.find("model").?.current);
    try std.testing.expectEqualStrings("Sonnet", a.config.find("model").?.currentName());
    try std.testing.expectEqual(@as(usize, 2), a.config.find("model").?.choices.len);
    try std.testing.expectEqualStrings("high", a.config.find("thought_level").?.current);

    // Choosing one goes as Pi's own set_model, provider and id apart.
    a.setOption("model", "anthropic/opus");
    try pumpUntil(a, struct {
        fn f(x: *agent_mod.Agent) bool {
            return std.mem.eql(u8, x.config.find("model").?.current, "anthropic/opus") and x.pi_client.pending.count() == 0;
        }
    }.f);
    try std.testing.expectEqualStrings("Opus", a.config.find("model").?.currentName());
    a.setOption("thought_level", "off");
    try pumpUntil(a, struct {
        fn f(x: *agent_mod.Agent) bool {
            return std.mem.eql(u8, x.config.find("thought_level").?.current, "off") and x.pi_client.pending.count() == 0;
        }
    }.f);

    // A prompt: its text streams, its tool call runs, and the turn settles.
    try a.promptWith(null, "list the files", &.{});
    try pumpUntil(a, struct {
        fn f(x: *agent_mod.Agent) bool {
            return x.turns.items.len == 1 and x.turns.items[0].done;
        }
    }.f);
    const t = a.turns.items[0];
    try std.testing.expectEqualStrings("thinking: ", turnText(t));
    try std.testing.expectEqualStrings("done", turnTextAt(t, 1));
    var tool_text: []const u8 = "";
    var tool_status: agent_mod.ToolStatus = .pending;
    var thought: []const u8 = "";
    for (t.items.items) |it| switch (it) {
        .tool => |tl| {
            tool_text = tl.detail.items;
            tool_status = tl.status;
        },
        .thought => |l| thought = l.items,
        else => {},
    };
    try std.testing.expectEqualStrings("a.txt\nb.txt", tool_text);
    try std.testing.expectEqual(agent_mod.ToolStatus.completed, tool_status);
    try std.testing.expectEqualStrings("a plan", thought);
    try std.testing.expectEqual(agent_mod.Status.ready, a.status);
    try std.testing.expectEqual(@as(usize, 0), a.pi_client.pending.count());

    // A refused model change puts the choice back, and says so on the turn.
    try std.testing.expectEqualStrings("anthropic/opus", a.config.find("model").?.current);
    a.setOption("model", "anthropic/missing");
    try pumpUntil(a, struct {
        fn f(x: *agent_mod.Agent) bool {
            return x.pi_client.pending.count() == 0 and std.mem.eql(u8, x.config.find("model").?.current, "anthropic/opus");
        }
    }.f);
    var noted = false;
    for (t.items.items) |it| switch (it) {
        .note => |n| noted = noted or std.mem.startsWith(u8, n, "the model was not set:"),
        else => {},
    };
    try std.testing.expect(noted);
}

test "Pi over RPC: a follow-up is queued and settles as its own turn" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const dir = "/tmp/nanoterm-test-pi-queue";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/pi.py", .data = fake_pi });

    var host: u8 = 0;
    const a = try agent_mod.Agent.create(gpa, io, .{ .ctx = &host, .changed = Host.changed, .newBlock = Host.newBlock }, .pi, dir);
    defer a.destroy();
    try a.start(try proc.cStrings(arena, &.{ "/usr/bin/python3", "-I", dir ++ "/pi.py" }), try proc.cStrings(arena, &.{"PATH=/usr/bin:/bin"}));
    try pumpUntil(a, struct {
        fn f(x: *agent_mod.Agent) bool {
            return x.status == .ready;
        }
    }.f);

    try a.promptWith(null, "first", &.{});
    try pumpUntil(a, struct {
        fn f(x: *agent_mod.Agent) bool {
            return x.turns.items.len == 1 and turnText(x.turns.items[0]).len > 0;
        }
    }.f);
    try a.promptWith(null, "second", &.{});
    try pumpUntil(a, struct {
        fn f(x: *agent_mod.Agent) bool {
            return x.turns.items.len == 2 and x.turns.items[0].done and x.turns.items[1].done;
        }
    }.f);
    try std.testing.expectEqualStrings("one", turnText(a.turns.items[0]));
    try std.testing.expectEqualStrings("two", turnText(a.turns.items[1]));
    try std.testing.expectEqual(agent_mod.Status.ready, a.status);
    try std.testing.expectEqual(@as(usize, 0), a.pi_client.pending.count());
}
