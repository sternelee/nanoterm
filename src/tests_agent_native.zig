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

    fn tool(raw: ?*anyopaque, _: []const u8, _: []const u8, output: []const u8) anyerror!void {
        const self: *Capture = @ptrCast(@alignCast(raw.?));
        self.tool_count += 1;
        self.tool_output.clearRetainingCapacity();
        try self.tool_output.appendSlice(self.gpa, output);
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
    try std.testing.expectEqual(@intFromEnum(managed), @intFromEnum(@TypeOf(managed).global_fx));
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

    var store = try Store.init(gpa, io, home);
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
