//! Opt-in end-to-end smoke test for the in-process agent runtime. Point
//! NANOTERM_AGENT_SMOKE_URL at an OpenAI-compatible /v1 endpoint; the normal
//! unit-test run skips this and never needs credentials or a network. Set
//! NANOTERM_AGENT_SMOKE_EXPECT_TOOL=1 when the endpoint also exercises shell.
const std = @import("std");
const engine = @import("fx");
const runtime = @import("agent_native.zig");
const Store = @import("agent_settings.zig").Store;

const Capture = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    diagnostic: std.ArrayList(u8) = .empty,
    tool_output: std.ArrayList(u8) = .empty,
    tool_count: usize = 0,

    fn writeText(raw: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *Capture = @ptrCast(@alignCast(raw.?));
        try self.text.appendSlice(self.gpa, bytes);
    }

    fn writeDiagnostic(raw: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *Capture = @ptrCast(@alignCast(raw.?));
        try self.diagnostic.appendSlice(self.gpa, bytes);
    }

    fn tool(raw: ?*anyopaque, event: engine.ToolEvent) anyerror!void {
        const self: *Capture = @ptrCast(@alignCast(raw.?));
        self.tool_count += 1;
        self.tool_output.clearRetainingCapacity();
        try self.tool_output.appendSlice(self.gpa, event.output);
    }
};

test "the embedded agent scans only fx's own skill roots" {
    // nanoterm's patch trims the compatibility roots for other agent installs
    // (opencode, codex, claude, agents, claw): the agent sees workspace
    // `.fx/skills` and `skills/`, and the managed `~/.fx/skills`, nothing else.
    const policy = engine.skills.root_policy;
    try std.testing.expectEqual(@as(usize, 2), policy.workspace_roots.len);
    for (policy.workspace_roots) |spec| {
        const native = spec.source == .workspace_fx or spec.source == .workspace_shared;
        try std.testing.expect(native);
    }
    try std.testing.expectEqual(@as(usize, 0), policy.global_roots.len);
    const managed = policy.managed_root_source orelse return error.NoManagedRoot;
    try std.testing.expectEqual(@backingInt(managed), @backingInt(@TypeOf(managed).global_fx));
}

test "a session keeps its profile's MCP servers in this process" {
    // fx shares a profile's stdio servers between sessions through an owner
    // process, started by running fx's own binary again as
    // `--fx-internal-mcp-owner`. Here that binary is nanoterm, which would
    // open a window instead of answering: every server runs in the session.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try engine.shared_io.dirRealpathAlloc(gpa, tmp.dir, ".");
    defer gpa.free(home);
    try tmp.dir.createDirPath(io, ".fx");
    var file = try tmp.dir.createFile(io, ".fx/mcp.json", .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "{\"mcp\":{\"own\":{\"command\":[\"true\"]}}}");

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("HOME", home);
    engine.shared_io.setEnvironMap(&env);
    defer engine.shared_io.resetEnvironForTest();
    runtime.init();

    const h = (try engine.mcp_host.load(gpa, home, .{}, .{}, null)) orelse return error.NoHost;
    defer h.destroy();
    try std.testing.expectEqual(@as(usize, 1), h.runtime.resolved.servers.len);
    try std.testing.expect(h.runtime.resolved.shared[0]);
    try std.testing.expect(h.runtime.shared == null);
}

test "an embedded turn releases the MCP host it loaded" {
    // `fx ask` only signals its servers on its way out, as its process ends
    // next. nanoterm's goes on: a turn that kept its host would leave a
    // thread behind that restarts the servers it was meant to stop.
    const io = std.testing.io;
    var leak: std.heap.DebugAllocator(.{}) = .init;
    const gpa = leak.allocator();
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const home = try engine.shared_io.dirRealpathAlloc(gpa, tmp.dir, ".");
        defer gpa.free(home);
        try tmp.dir.createDirPath(io, ".fx");
        var file = try tmp.dir.createFile(io, ".fx/mcp.json", .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "{\"mcp\":{\"own\":{\"command\":[\"true\"]}}}");

        var env: std.process.Environ.Map = .init(gpa);
        defer env.deinit();
        try env.put("HOME", home);
        try env.put("PATH", "/usr/bin:/bin");
        engine.shared_io.setEnvironMap(&env);
        defer engine.shared_io.resetEnvironForTest();
        runtime.init();

        var store = try Store.init(gpa, io, home, null);
        defer store.deinit();
        store.provider_name.set("local-smoke");
        store.provider_url.set("http://127.0.0.1:9/v1");
        store.provider_model.set("smoke-model");
        store.provider_auth_env.set("");
        store.saveProvider();

        var capture: Capture = .{ .gpa = gpa };
        defer capture.text.deinit(gpa);
        defer capture.diagnostic.deinit(gpa);
        defer capture.tool_output.deinit(gpa);
        var cancel: std.atomic.Value(bool) = .init(false);
        // The provider address is deliberately unreachable. Newer fx retries
        // a failed connection with backoff, so without a deadline this turn
        // would keep retrying. The test only cares that the turn ends and
        // releases its MCP host; cancel it shortly after it starts.
        const CancelJob = struct {
            flag: *std.atomic.Value(bool),
            io: std.Io,
            fn run(arg: *@This()) void {
                std.Io.sleep(arg.io, std.Io.Duration.fromMilliseconds(1500), .awake) catch {};
                arg.flag.store(true, .release);
            }
        };
        var job = CancelJob{ .flag = &cancel, .io = io };
        const watchdog = std.Thread.spawn(.{}, CancelJob.run, .{&job}) catch null;
        defer if (watchdog) |t| t.join();
        // The turn cannot reach its provider, but it loaded the host first.
        const result = engine.run(gpa, "Reply with the smoke-test answer.", home, null, null, &.{}, &cancel, .{
            .context = &capture,
            .text = Capture.writeText,
            .diagnostic = Capture.writeDiagnostic,
            .tool = Capture.tool,
        }, null) catch null;
        if (result) |finished| finished.deinit(gpa);
    }
    try std.testing.expect(leak.deinit() == .ok);
}

// EXPERIMENT (temporary): an embedded session with a profile MCP server.
test "EXPERIMENT a session calls a profile MCP tool" {
    const gpa = std.testing.allocator;
    const base_url = std.testing.environ.getAlloc(gpa, "NANOTERM_MCP_EXPERIMENT_URL") catch return error.SkipZigTest;
    defer gpa.free(base_url);
    const io = std.testing.io;
    const home = "/tmp/fx-e2e/home";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/.fx");
    var file = try std.Io.Dir.cwd().createFile(io, home ++ "/.fx/mcp.json", .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "{\"mcp\":{\"own\":{\"command\":[\"/opt/homebrew/bin/python3\",\"/tmp/fx-e2e/mcp_server.py\"]}}}");

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("FX_DISABLE_KEYCHAIN", "1");
    try env.put("FX_TRACE_STDERR", "1");
    try env.put("FX_TRACE_SCOPES", "mcp-owner,mcp");
    engine.shared_io.setEnvironMap(&env);
    defer engine.shared_io.resetEnvironForTest();
    runtime.init();

    var store = try Store.init(gpa, io, home, null);
    defer store.deinit();
    store.provider_name.set("local-smoke");
    store.provider_url.set(base_url);
    store.provider_model.set("smoke-model");
    store.provider_auth_env.set("");
    store.saveProvider();
    std.debug.print("EXPERIMENT provider status: {s}\n", .{store.status});

    var capture: Capture = .{ .gpa = gpa };
    defer capture.text.deinit(gpa);
    defer capture.diagnostic.deinit(gpa);
    defer capture.tool_output.deinit(gpa);
    var cancel: std.atomic.Value(bool) = .init(false);
    const start = std.Io.Clock.awake.now(io).toMilliseconds();
    const result = try engine.run(gpa, "Call the echo tool with the text hi.", home, null, null, &.{}, &cancel, .{
        .context = &capture,
        .text = Capture.writeText,
        .diagnostic = Capture.writeDiagnostic,
        .tool = Capture.tool,
    }, null);
    const ms = std.Io.Clock.awake.now(io).toMilliseconds() - start;
    std.debug.print("EXPERIMENT elapsed_ms={d} tools_called={d} text={s} diagnostic={s} tool_output={s}\n", .{ ms, capture.tool_count, capture.text.items, capture.diagnostic.items, capture.tool_output.items });
    result.deinit(gpa);
    engine.shared_io.sleep(2 * std.time.ns_per_s);
}

test "native agent answers through an OpenAI-compatible provider (opt-in)" {
    const gpa = std.testing.allocator;
    const base_url = std.testing.environ.getAlloc(gpa, "NANOTERM_AGENT_SMOKE_URL") catch return error.SkipZigTest;
    defer gpa.free(base_url);
    const io = std.testing.io;
    const home = "/tmp/nanoterm-agent-native-smoke";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);

    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    engine.shared_io.setEnvironMap(&env);
    defer engine.shared_io.resetEnvironForTest();
    runtime.init();

    var store = try Store.init(gpa, io, home, null);
    defer store.deinit();
    store.provider_name.set("local-smoke");
    store.provider_url.set(base_url);
    store.provider_model.set("smoke-model");
    store.provider_auth_env.set("");
    store.saveProvider();
    try std.testing.expectEqualStrings("Provider saved and selected", store.status);
    try std.testing.expect(store.providers.items.len == 1);

    var capture: Capture = .{ .gpa = gpa };
    defer capture.text.deinit(gpa);
    defer capture.diagnostic.deinit(gpa);
    defer capture.tool_output.deinit(gpa);
    var cancel: std.atomic.Value(bool) = .init(false);
    const result = try engine.run(gpa, "Reply with the smoke-test answer.", home, null, null, &.{}, &cancel, .{
        .context = &capture,
        .text = Capture.writeText,
        .diagnostic = Capture.writeDiagnostic,
        .tool = Capture.tool,
    }, null);
    defer result.deinit(gpa);
    try std.testing.expect(std.mem.indexOf(u8, capture.text.items, "native-agent-ok") != null);
    try std.testing.expect(result.session_id.len > 0);
    try std.testing.expectEqualStrings("smoke-model", result.model);
    const expect_tool = std.testing.environ.getAlloc(gpa, "NANOTERM_AGENT_SMOKE_EXPECT_TOOL") catch null;
    defer if (expect_tool) |value| gpa.free(value);
    if (expect_tool != null) {
        try std.testing.expect(capture.tool_count > 0);
        try std.testing.expect(std.mem.indexOf(u8, capture.tool_output.items, "native-tool-ok") != null);
    }
}
