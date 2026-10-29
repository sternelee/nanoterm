//! Settings: built-in Agent provider, MCP and Skills controls, external ACP
//! agents, appearance and updates. HOME is a temporary folder.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");

test "the Settings page: built-in Agent, agents, appearance, updates" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-settings-view";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    _ = try w.newTab(home);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 1000, .height = 2400, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    w.openSettings();
    t.settle(1);
    try std.testing.expect(t.hasText("Agents"));
    try std.testing.expect(t.hasText("Coding agents"));
    try std.testing.expect(t.hasText("Agent · built in"));
    const agents_row = t.findText("Coding agents").?;
    const agent_config_row = t.findText("Agent · built in").?;
    try std.testing.expect(agents_row.y < agent_config_row.y);
    try std.testing.expect(!t.hasText("Providers"));
    try t.clickText("Agent · built in");
    t.settle(1);
    try std.testing.expect(t.hasText("Providers"));
    try std.testing.expect(t.hasText("Add provider") and t.hasText("Add MCP server") and t.hasText("Add Skill"));
    try std.testing.expect(t.hasText("Codex") and t.hasText("opencode") and t.hasText("Hermes"));
    try std.testing.expect(t.hasText("Pi"));
    try std.testing.expect(t.hasText("Default"));
    try std.testing.expect(t.hasText("MCP servers") and t.hasText("Skills"));
    // New configurations hide in expandable panels until their title is clicked.
    try t.clickText("Add provider");
    t.settle(1);
    try std.testing.expect(t.hasText("Base URL, including /v1/"));
    try t.clickText("Add MCP server");
    t.settle(1);
    try std.testing.expect(t.hasText("Space-separated arguments for stdio command (optional)"));
    try t.clickText("Add Skill");
    t.settle(1);
    try std.testing.expect(t.hasText("Install from git URL or local path"));
    try t.screenshot("/tmp/nanoterm-settings.png");
}

fn printed(_: *ui.Tester, s: *session_mod.Session) bool {
    if (s.shell.busy() or s.timeline.items.len == 0) return false;
    return switch (s.timeline.items[s.timeline.items.len - 1]) {
        .block => |b| b.state == .done and b.output.lineCount() > 0,
        else => false,
    };
}

test "a command run in a new tab (an installer, a sign-in) waits for its shell's first prompt" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-newtab-run";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    var t: ui.Tester = undefined;
    const s = try w.newTab(home);
    // Before its shell has started.
    try std.testing.expectEqual(@import("shell.zig").Phase.starting, s.shell.phase);
    s.run("printf 'signed in\\n'");
    try t.init(gpa, .init(&w, view.view), .{ .width = 900, .height = 560, .theme = theme.ui() });
    defer t.deinit();
    var waited: f64 = 0;
    while (!printed(&t, s)) : (waited += 0.02) {
        if (waited > 10) return error.Timeout;
        nanoui.runFor(0.02);
        t.frame();
    }
    const b = s.timeline.items[s.timeline.items.len - 1].block;
    const text = try b.output.plainText(gpa);
    defer gpa.free(text);
    try std.testing.expectEqualStrings("signed in", text);
}
