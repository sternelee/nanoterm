const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const harness_types = @import("harness/types.zig");
const harness_adapter = @import("harness/adapter.zig");
const claude_protocol = @import("harness/providers/claude/claude_protocol.zig");
const acp_provider = @import("harness/providers/acp/provider.zig");
const codex_provider = @import("harness/providers/codex/codex_provider.zig");

test {
    _ = @import("harness/registry.zig");
    _ = @import("harness_bridge.zig");
    _ = @import("harness/providers/acp/events.zig");
    _ = @import("harness/providers/hermes/hermes.zig");
    _ = @import("harness/providers/codex/codex.zig");
    _ = @import("harness/providers/others.zig");
    _ = @import("harness/providers/pi/pi.zig");
}

test "harness types compile" {
    const event = harness_types.HarnessEvent{ .session_started = {} };
    _ = event;
}

test "harness registry basic operations" {
    const gpa = std.testing.allocator;
    var registry = harness_adapter.HarnessRegistry.init(gpa);
    defer registry.deinit();

    // Test empty registry
    try std.testing.expect(registry.get("claude") == null);
    const list = try registry.list();
    defer gpa.free(list);
    try std.testing.expect(list.len == 0);
}

test "runtime mode to permission mapping" {
    try std.testing.expectEqual(claude_protocol.ClaudePermissionMode.default, claude_protocol.runtimeModeToPermission(.default));
    try std.testing.expectEqual(claude_protocol.ClaudePermissionMode.plan, claude_protocol.runtimeModeToPermission(.plan));
    try std.testing.expectEqual(claude_protocol.ClaudePermissionMode.auto, claude_protocol.runtimeModeToPermission(.auto));
}

test "buildControlRequest initialize" {
    const gpa = std.testing.allocator;
    const req = try claude_protocol.buildControlRequest(gpa, "req1", .initialize);
    defer gpa.free(req);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, req, .{});
    defer parsed.deinit();
    try std.testing.expect(std.mem.eql(u8, claude_protocol.str(parsed.value, "type").?, "control_request"));
}

/// A stand-in ACP agent: it answers `initialize` and `session/new`, then
/// streams one message chunk before ending the turn. Written to a temp file
/// and started by the provider, so the whole path is exercised without a real
/// agent.
const fake_acp_py =
    \\import json, sys
    \\def send(o):
    \\    sys.stdout.write(json.dumps(o) + "\n")
    \\    sys.stdout.flush()
    \\for line in sys.stdin:
    \\    line = line.strip()
    \\    if not line:
    \\        continue
    \\    m = json.loads(line)
    \\    method = m.get("method")
    \\    if method == "initialize":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"protocolVersion": 1, "agentCapabilities": {"promptCapabilities": {"image": False}}}})
    \\    elif method == "session/new":
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"sessionId": "sess-1"}})
    \\    elif method == "session/prompt":
    \\        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "sess-1", "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "hello from fake"}}}})
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {"stopReason": "end_turn"}})
    \\        sys.exit(0)
    \\    elif method == "session/cancel":
    \\        pass
    \\    else:
    \\        send({"jsonrpc": "2.0", "id": m["id"], "result": {}})
;

fn fakeArgv(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, model: ?[]const u8) anyerror![]const []const u8 {
    _ = io;
    _ = model;
    const script = env.get("FAKE_ACP") orelse return error.NotInstalled;
    return arena.dupe([]const u8, &.{ env.get("PYTHON") orelse "/usr/bin/python3", script });
}

/// What the provider's events said, copied out of the callback's arena.
const Sink = struct {
    gpa: std.mem.Allocator,
    texts: std.ArrayList([]u8) = .empty,
    errors: std.ArrayList([]u8) = .empty,
    done: bool = false,
    /// A turn has started and not ended yet.
    turn_open: bool = false,

    fn deinit(self: *Sink) void {
        for (self.texts.items) |t| self.gpa.free(t);
        self.texts.deinit(self.gpa);
        for (self.errors.items) |e| self.gpa.free(e);
        self.errors.deinit(self.gpa);
    }

    fn on(ctx: *anyopaque, event: harness_types.HarnessEvent) void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        switch (event) {
            .message_delta => |t| self.texts.append(self.gpa, self.gpa.dupe(u8, t) catch return) catch {},
            .session_error => |e| self.errors.append(self.gpa, self.gpa.dupe(u8, e) catch return) catch {},
            .turn_started => self.turn_open = true,
            .turn_ended => {
                self.turn_open = false;
                self.done = true;
            },
            else => {},
        }
    }
};

test "an ACP provider runs a whole turn against a stand-in agent" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = "/tmp/nanoterm-test-acp-provider";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir);
    const script = try std.fs.path.join(arena, &.{ dir, "fake.py" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = script, .data = fake_acp_py });

    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", dir);
    try env.put("PATH", "/usr/bin:/bin:/usr/local/bin");
    try env.put("FAKE_ACP", script);

    var provider = acp_provider.Provider.init(gpa, io, &env, .{ .id = "fake", .label = "Fake", .argv = fakeArgv });
    defer provider.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    const input = harness_types.SendTurnInput{ .session_id = "s1", .cwd = dir, .prompt = "hi", .on_event = Sink.on };
    try provider.sendTurn(&input, &sink);
    var waited: f64 = 0;
    while (!sink.done) : (waited += 0.02) {
        if (waited > 30) return error.Timeout;
        nanoui.runFor(0.02);
    }
    // The stand-in exits after its answer, so its end is drained here: the
    // provider is torn down with nothing left to report.
    for (0..5) |_| nanoui.runFor(0.02);
    try std.testing.expectEqual(@as(usize, 0), sink.errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), sink.texts.items.len);
    try std.testing.expectEqualStrings("hello from fake", sink.texts.items[0]);
}

/// A stand-in `codex app-server`: headerless JSON-RPC, a thread, one turn,
/// then its end. Wrapped in a `codex` script so the provider's own launcher
/// finds it on PATH.
const fake_codex_py =
    \\import json, sys
    \\def send(o):
    \\    sys.stdout.write(json.dumps(o) + "\n")
    \\    sys.stdout.flush()
    \\for line in sys.stdin:
    \\    line = line.strip()
    \\    if not line:
    \\        continue
    \\    m = json.loads(line)
    \\    method = m.get("method")
    \\    rid = m.get("id")
    \\    if method is None:
    \\        continue
    \\    if method == "initialize":
    \\        send({"id": rid, "result": {"userAgent": "fake"}})
    \\    elif method == "initialized":
    \\        pass
    \\    elif method == "thread/start":
    \\        send({"id": rid, "result": {"thread": {"id": "th-1"}}})
    \\    elif method == "turn/start":
    \\        send({"id": rid, "result": {"turn": {"id": "tu-1"}}})
    \\        send({"method": "turn/started", "params": {"turn": {"id": "tu-1"}}})
    \\        send({"method": "item/agentMessage/delta", "params": {"itemId": "i1", "delta": "hello from codex"}})
    \\        send({"method": "turn/completed", "params": {"turn": {"id": "tu-1", "status": "completed"}}})
    \\        sys.exit(0)
    \\    else:
    \\        send({"id": rid, "result": {}})
;

test "a Codex provider runs a whole turn against a stand-in app-server" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = "/tmp/nanoterm-test-codex-provider";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir ++ "/bin");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/fake.py", .data = fake_codex_py });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = dir ++ "/bin/codex",
        .data = "#!/bin/sh\nexec /usr/bin/python3 " ++ dir ++ "/fake.py \"$@\"\n",
        .flags = .{ .permissions = .executable_file },
    });

    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", dir);
    try env.put("PATH", dir ++ "/bin");

    var provider = codex_provider.CodexProvider.init(gpa, io, &env);
    defer provider.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    const input = harness_types.SendTurnInput{ .session_id = "s1", .cwd = dir, .prompt = "hi", .on_event = Sink.on };
    try provider.sendTurn(&input, &sink);
    var waited: f64 = 0;
    while (!sink.done) : (waited += 0.02) {
        if (waited > 30) return error.Timeout;
        nanoui.runFor(0.02);
    }
    for (0..5) |_| nanoui.runFor(0.02);
    try std.testing.expectEqual(@as(usize, 0), sink.errors.items.len);
    try std.testing.expectEqual(@as(usize, 1), sink.texts.items.len);
    try std.testing.expectEqualStrings("hello from codex", sink.texts.items[0]);
}

/// A stand-in app-server that opens a turn and waits: it only answers once a
/// follow-up has been steered into the turn, so the test proves the steer
/// reached the running turn.
const fake_codex_steer_py =
    \\import json, sys
    \\def send(o):
    \\    sys.stdout.write(json.dumps(o) + "\n")
    \\    sys.stdout.flush()
    \\for line in sys.stdin:
    \\    line = line.strip()
    \\    if not line:
    \\        continue
    \\    m = json.loads(line)
    \\    method = m.get("method")
    \\    rid = m.get("id")
    \\    if method is None:
    \\        continue
    \\    if method == "initialize":
    \\        send({"id": rid, "result": {"userAgent": "fake"}})
    \\    elif method == "initialized":
    \\        pass
    \\    elif method == "thread/start":
    \\        send({"id": rid, "result": {"thread": {"id": "th-1"}}})
    \\    elif method == "turn/start":
    \\        send({"id": rid, "result": {"turn": {"id": "tu-1"}}})
    \\        send({"method": "turn/started", "params": {"turn": {"id": "tu-1"}}})
    \\    elif method == "turn/steer":
    \\        if m["params"].get("expectedTurnId") != "tu-1":
    \\            send({"id": rid, "error": {"code": -1, "message": "wrong turn"}})
    \\            continue
    \\        send({"id": rid, "result": {}})
    \\        send({"method": "item/agentMessage/delta", "params": {"itemId": "i1", "delta": "steered"}})
    \\        send({"method": "turn/completed", "params": {"turn": {"id": "tu-1", "status": "completed"}}})
    \\        sys.exit(0)
    \\    else:
    \\        send({"id": rid, "result": {}})
;

test "a follow-up is steered into the Codex turn already running" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dir = "/tmp/nanoterm-test-codex-steer";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir ++ "/bin");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/fake.py", .data = fake_codex_steer_py });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = dir ++ "/bin/codex",
        .data = "#!/bin/sh\nexec /usr/bin/python3 " ++ dir ++ "/fake.py \"$@\"\n",
        .flags = .{ .permissions = .executable_file },
    });

    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", dir);
    try env.put("PATH", dir ++ "/bin");

    var provider = codex_provider.CodexProvider.init(gpa, io, &env);
    defer provider.deinit();
    var sink: Sink = .{ .gpa = gpa };
    defer sink.deinit();

    const input = harness_types.SendTurnInput{ .session_id = "s1", .cwd = dir, .prompt = "hi", .on_event = Sink.on };
    try provider.sendTurn(&input, &sink);
    // Let the turn open, then fold a follow-up into it.
    var waited: f64 = 0;
    while (!sink.turn_open and waited < 30) : (waited += 0.02) nanoui.runFor(0.02);
    try std.testing.expect(sink.turn_open);
    // The turn's own id arrives with the `turn/started` notification, which
    // may share a read with the response or follow it.
    for (0..3) |_| nanoui.runFor(0.02);
    const steer = harness_types.SteerTurnInput{ .session_id = "s1", .cwd = dir, .text = "also do this", .on_event = Sink.on };
    try provider.steerTurn(&steer);
    while (!sink.done) : (waited += 0.02) {
        if (waited > 60) return error.Timeout;
        nanoui.runFor(0.02);
    }
    for (0..5) |_| nanoui.runFor(0.02);
    try std.testing.expectEqual(@as(usize, 0), sink.errors.items.len);
    try std.testing.expectEqualStrings("steered", sink.texts.items[0]);
}
