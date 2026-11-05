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
    // fx's own dials, for the pane the panel is over.
    try std.testing.expect(t.hasText("Sign in"));
    try std.testing.expect(t.hasText("Permissions"));
    try std.testing.expect(t.hasText("Reasoning effort"));
    try std.testing.expect(t.hasText("Additional workspaces"));
    try std.testing.expect(t.hasText("Project instructions"));
    // A permission mode picked here is written to fx's own settings.
    try t.clickText("Full access");
    t.settle(1);
    {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, home ++ "/.fx/settings.json", gpa, .limited(65536));
        defer gpa.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "full-access") != null);
    }
    // New configurations hide in expandable panels until their title is clicked.
    // They sit below fx's dials now: scroll the page to reach them.
    t.scroll(600, 500, -1200);
    t.settle(1);
    try t.clickText("Add provider");
    t.settle(1);
    try std.testing.expect(t.hasText("Base URL, including /v1/"));
    try t.clickText("Add MCP server");
    t.settle(1);
    try std.testing.expect(t.hasText("Space-separated arguments for stdio command (optional)"));
    t.scroll(600, 500, -1200);
    t.settle(1);
    try t.clickText("Add Skill");
    t.settle(1);
    try std.testing.expect(t.hasText("Install from git URL or local path"));
    try t.screenshot("/tmp/nanoterm-settings.png");
}

test "Settings sets the model new tabs and Thread tasks start with" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-settings-model";
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
    const first = try w.newTab(home);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 1000, .height = 2400, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    w.openSettings();
    t.settle(1);
    try std.testing.expect(t.hasText("Default model"));
    try std.testing.expect(t.hasText("The agent's own model"));
    // Type a model into the field and submit it.
    const field = t.findText("The agent's own model") orelse return error.FieldNotFound;
    t.click(field.x + 10, field.y + field.h / 2);
    t.typeText("anthropic/claude-sonnet");
    t.key(.enter);
    t.settle(1);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet", shared.prefs.model);
    // The pane that follows the default agent takes it, and so do new tabs.
    try std.testing.expectEqualStrings("anthropic/claude-sonnet", first.model_choice.?);
    const second = try w.newTab(home);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet", second.model_choice.?);
    try t.screenshot("/tmp/nanoterm-settings-default-model.png");
    // Kept for the next launch, for the calls nanoterm makes itself.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, home ++ "/Library/Application Support/nanoterm/settings.json", gpa, .limited(65536));
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"model\": \"anthropic/claude-sonnet\"") != null);
}

test "Settings' Threads page links several folders to their repositories" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-settings-threads";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/work");
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/work-two");
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
    try t.clickText("Threads");
    t.settle(1);
    // The page is taller than the card: the Projects box is below the fold.
    t.scroll(600, 500, -300);
    t.settle(1);
    try std.testing.expect(t.hasText("Projects"));
    try std.testing.expect(t.hasText("Add folder"));
    try std.testing.expect(t.hasText("Use focused pane"));
    // A path with no root is refused before gh is ever asked.
    const field = t.findText("/path/to/checkout") orelse return error.FieldNotFound;
    t.click(field.x + 10, field.y + field.h / 2);
    t.typeText("relative/folder");
    try t.clickText("Add folder");
    t.settle(1);
    try std.testing.expect(shared.threads.errorText().len > 0);
    try std.testing.expectEqual(@as(usize, 0), shared.threads.projects().len);
    // Two folders, each with the repository a poll would learn.
    try std.testing.expect(shared.threads.addProject(home ++ "/work"));
    try std.testing.expect(shared.threads.addProject(home ++ "/work-two"));
    shared.threads.projectAt(0).?.repo = try gpa.dupe(u8, "owner/repo");
    shared.threads.projectAt(0).?.verified = true;
    shared.threads.projectAt(1).?.repo = try gpa.dupe(u8, "acme/widget");
    // The second folder holds something else: the page says so, per row,
    // and offers the explicit switch.
    shared.threads.projectAt(1).?.found = try gpa.dupe(u8, "someone/else");
    if (shared.threads.last_error.len > 0) gpa.free(shared.threads.last_error);
    shared.threads.last_error = try gpa.dupe(u8, "this folder holds someone/else, not acme/widget; no agent is called until they match");
    w.closeOverlay();
    w.openSettings();
    t.settle(1);
    try t.clickText("Threads");
    t.settle(1);
    t.scroll(600, 500, -300);
    t.settle(1);
    try std.testing.expect(t.hasText(home ++ "/work"));
    try std.testing.expect(t.hasText(home ++ "/work-two"));
    try std.testing.expect(t.hasText("owner/repo"));
    try std.testing.expect(t.hasText("acme/widget"));
    try std.testing.expect(t.hasText("This folder holds someone/else, not acme/widget."));
    try std.testing.expect(t.hasText("Watch someone/else"));
    try t.screenshot("/tmp/nanoterm-settings-threads.png");
    // Removing a row stops watching that folder; the other stays.
    try t.clickText("Remove");
    t.settle(1);
    try std.testing.expectEqual(@as(usize, 1), shared.threads.projects().len);
    try std.testing.expectEqualStrings(home ++ "/work-two", shared.threads.projects()[0].cwd);
}

test "Settings' Threads page switches what the poll watches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-settings-sources";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
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
    try t.clickText("Threads");
    t.settle(1);
    const labels = [_][]const u8{
        "Issues assigned to me",
        "Pull requests asking for my review",
        "Pull requests assigned to me",
        "Comments that mention me",
        "Review decisions on my pull requests",
        "Failing checks on my pull requests",
        "Github notifications",
    };
    for (labels) |s| {
        if (!t.hasText(s)) {
            std.debug.print("missing: {s}\n", .{s});
            return error.TextMissing;
        }
    }
    const th = &shared.threads;
    try std.testing.expectEqual(@as(usize, 7), th.watchedCount());
    try std.testing.expect(t.hasText("7 of 7 on"));
    // They read in the order they are listed, one row each, each hint under
    // its own switch and clear of the next one.
    for (labels[1..], labels[0 .. labels.len - 1]) |lower, upper| {
        const up = t.findText(upper) orelse return error.TextMissing;
        const lo = t.findText(lower) orelse return error.TextMissing;
        try std.testing.expect(up.y + up.h < lo.y);
    }
    const first_hint = t.findText("Issues on these repositories that gh says are assigned to you.") orelse return error.TextMissing;
    const first = t.findText(labels[0]).?;
    const second = t.findText(labels[1]).?;
    try std.testing.expect(first_hint.y > first.y + first.h / 2);
    try std.testing.expect(first_hint.y + first_hint.h < second.y);
    // Each switch is on its own: turning mentions off leaves the rest alone.
    try t.clickText("Comments that mention me");
    t.settle(1);
    try std.testing.expect(!th.source(.mentions));
    try std.testing.expect(th.source(.issues) and th.source(.reviews) and th.source(.assigned_prs));
    try std.testing.expect(th.source(.my_reviews) and th.source(.ci) and th.source(.notifications));
    try std.testing.expect(t.hasText("6 of 7 on"));
    try t.screenshot("/tmp/nanoterm-settings-sources.png");
}

fn printed(_: *ui.Tester, s: *session_mod.Session) bool {
    if (s.shell.busy() or s.timeline.items.len == 0) return false;
    return switch (s.timeline.items[s.timeline.items.len - 1]) {
        .block => |b| b.state == .done and b.output.lineCount() > 0,
        else => false,
    };
}

test "the theme shelf: a named theme takes, and keeps across launches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-settings-theme";
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
    _ = try w.newTab(home);
    try t.init(gpa, .init(&w, view.view), .{ .width = 1000, .height = 800, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    w.openSettings();
    t.settle(1);
    try t.clickText("Appearance");
    t.settle(1);
    // The shelf is there: System, the house pair, and the named themes.
    try std.testing.expect(t.hasText("System"));
    try std.testing.expect(t.hasText("Soot"));
    try std.testing.expect(t.hasText("Palenight"));
    // A click takes a theme — the palette moves with it.
    try t.clickText("Phosphor");
    t.settle(1);
    try std.testing.expectEqualStrings("phosphor", w.shared.prefs.theme);
    try std.testing.expect(t.hasText("a green tube in a dark room"));
    // Kept: a fresh workspace reads it back.
    var again: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer again.deinit();
    _ = try again.newTab(home);
    var t2: ui.Tester = undefined;
    try t2.init(gpa, .init(&again, view.view), .{ .width = 1000, .height = 800, .theme = theme.ui() });
    defer t2.deinit();
    t2.settle(1);
    try std.testing.expectEqualStrings("phosphor", again.shared.prefs.theme);
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

test "Settings' Relay page: off by default, and LAN turns the relay on" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-relay-settings";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    // A port of its own, so a relay left running by another test cannot
    // take this one's.
    shared.prefs.relay_port = 4799;
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    _ = try w.newTab(home);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 1000, .height = 2400, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    w.openSettings();
    t.settle(1);
    try t.clickText("Relay");
    t.settle(1);
    try std.testing.expect(t.hasText("Phone · relay"));
    try std.testing.expect(t.hasText("The relay is off."));
    try std.testing.expect(shared.relay == null);
    // A LAN relay starts listening and shows its address and token.
    try t.clickText("LAN");
    t.settle(1);
    try std.testing.expect(shared.relay != null);
    try std.testing.expect(shared.prefs.relay == .lan);
    try std.testing.expect(t.containsText("Token"));
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        io,
        home ++ "/Library/Application Support/nanoterm/relay-token",
        gpa,
        .limited(64),
    );
    defer gpa.free(bytes);
    try std.testing.expect(bytes.len == 32);
    try t.screenshot("/tmp/nanoterm-settings-relay.png");
    // Turning it off again stops it.
    try t.clickText("Off");
    t.settle(1);
    try std.testing.expect(shared.relay == null);
    try std.testing.expect(t.hasText("The relay is off."));
}
