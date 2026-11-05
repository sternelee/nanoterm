//! The tabs as a sidebar, through the real view: grouped by project, each
//! row's state, "needs you" counted, a finished turn unread until its tab
//! is looked at, a click choosing a tab. The agents are pretend (each
//! tab's facts set), the shells real, in a temporary HOME.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const view = @import("view.zig");
const theme = @import("theme.zig");
const sidebar = @import("view_sidebar.zig");

test "the sidebar: projects, states, needs you, unread until seen, a click" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-sidebar";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    // Two repositories and a folder that isn't one.
    for ([_][]const u8{ home ++ "/code/launchpad/.git", home ++ "/code/launchpad/web", home ++ "/code/ios-app/.git", home ++ "/notes" }) |d| try std.Io.Dir.cwd().createDirPath(io, d);
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();

    const Row = struct { dir: []const u8, facts: sidebar.Facts };
    const now = @import("blocks.zig").now();
    const rows = [_]Row{
        .{ .dir = home ++ "/code/launchpad", .facts = .{ .agent = true, .turn_open = true, .since = now - 70, .name = "landing-hero" } },
        .{ .dir = home ++ "/code/launchpad/web", .facts = .{ .agent = true, .turn_open = true, .asking = true, .since = now - 5, .name = "pricing-page" } },
        .{ .dir = home ++ "/code/launchpad", .facts = .{ .agent = true, .turns_done = 1, .since = now - 250, .name = "launch-thread" } },
        .{ .dir = home ++ "/code/ios-app", .facts = .{ .agent = true, .turns_done = 2, .since = now - 3700, .name = "onboarding-v2" } },
        .{ .dir = home ++ "/notes", .facts = .{} },
    };
    for (rows) |r| {
        _ = try w.newTab(r.dir);
        const t = w.tabs.items[w.tabs.items.len - 1];
        t.pretend = r.facts;
        // The shell starts in its folder (the sidebar groups by it).
        t.session().shell.cwd.clearRetainingCapacity();
        try t.session().shell.cwd.appendSlice(gpa, r.dir);
    }
    // onboarding-v2's turns were seen; launch-thread's wasn't.
    w.tabs.items[3].seen_turns = 2;
    w.selectTab(0);
    try std.testing.expectEqualStrings("launchpad", sidebar.project(io, home, home ++ "/code/launchpad/web"));
    try std.testing.expectEqualStrings("notes", sidebar.project(io, home, home ++ "/notes"));
    try std.testing.expectEqualStrings("~", sidebar.project(io, home, home));

    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 1100, .height = 640, .theme = theme.ui() });
    defer t.deinit();
    t.settle(0.5);
    try std.testing.expect(sidebar.shown(&w));
    for ([_][]const u8{ "launchpad", "ios-app", "notes", "landing-hero", "pricing-page", "launch-thread", "onboarding-v2", "1 needs you", "~/code/launchpad" }) |s| {
        if (!t.hasText(s)) {
            std.debug.print("missing: {s}\n", .{s});
            return error.TextMissing;
        }
    }
    try std.testing.expect(t.containsText("Working · "));
    // launchpad's three tabs are one group, before ios-app's.
    try std.testing.expect(t.findText("launch-thread").?.y < t.findText("ios-app").?.y);
    try std.testing.expect(t.findText("launchpad").?.y < t.findText("landing-hero").?.y);
    // launch-thread finished while unseen: unread until it's looked at.
    try std.testing.expect(w.tabs.items[2].seen_turns < 1);
    try t.screenshot("/tmp/nanoterm-sidebar.png");
    try t.clickText("launch-thread");
    t.settle(0.5);
    try std.testing.expectEqual(@as(usize, 2), w.active);
    try std.testing.expectEqual(@as(usize, 1), w.tabs.items[2].seen_turns);
    // Its state in the title (the minutes depend on how long the shells took to start).
    try std.testing.expect(t.containsText("Done · "));
    // Hidden from the View menu: the tabs are back in the title bar.
    w.sidebar = .hidden;
    t.settle(0.5);
    try std.testing.expect(!t.hasText("1 needs you"));
}

test "the sidebar: watched Github threads, their proposal and Run" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-sidebar-threads";
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
    const th = &shared.threads;
    try th.cfg.projects.append(gpa, .{
        .cwd = try gpa.dupe(u8, home),
        .repo = try gpa.dupe(u8, "owner/repo"),
        .verified = true,
    });
    const now = @import("blocks.zig").now();
    const Row = struct { key: []const u8, kind: @import("threads.zig").Kind, number: u32, title: []const u8, state: @import("threads.zig").State };
    const rows = [_]Row{
        .{ .key = "issue:owner/repo#7", .kind = .issue, .number = 7, .title = "Fix the flaky test", .state = .proposed },
        .{ .key = "ci:owner/repo#8", .kind = .ci, .number = 8, .title = "Checks failed", .state = .analyzing },
    };
    for (rows, 1..) |r, i| try th.threads.append(gpa, .{
        .id = i,
        .key = try gpa.dupe(u8, r.key),
        .kind = r.kind,
        .number = r.number,
        .title = try gpa.dupe(u8, r.title),
        .url = try gpa.dupe(u8, "https://github.com/owner/repo"),
        .state = r.state,
        .proposal = if (r.state == .proposed) try gpa.dupe(u8, "the plan") else &.{},
        .created = now,
        .changed = now,
    });
    w.sidebar = .shown;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 1100, .height = 640, .theme = theme.ui() });
    defer t.deinit();
    t.settle(0.5);
    for ([_][]const u8{ "Threads", "1 needs you", "Fix the flaky test", "Checks failed", "Run" }) |s| {
        if (!t.hasText(s)) {
            std.debug.print("missing: {s}\n", .{s});
            return error.TextMissing;
        }
    }
    // The proposal is the group that needs you, above the tab's project.
    try std.testing.expect(t.findText("Threads").?.y < t.findText("Fix the flaky test").?.y);
    // Two sections: what Github asked for on top, your own tabs below.
    const projects = t.findText("Projects") orelse return error.TextMissing;
    try std.testing.expect(projects.y > t.findText("Checks failed").?.y);
    // The tab's own group sits under that heading (its folder is the home).
    try std.testing.expect(projects.y < t.findText("~").?.y);
}

test "the sidebar: a thread waits for Read when agents start by hand" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-sidebar-thread-read";
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
    const th = &shared.threads;
    try th.cfg.projects.append(gpa, .{
        .cwd = try gpa.dupe(u8, home),
        .repo = try gpa.dupe(u8, "owner/repo"),
        .verified = true,
    });
    th.cfg.auto_start = false;
    const now = @import("blocks.zig").now();
    try th.threads.append(gpa, .{
        .id = 1,
        .key = try gpa.dupe(u8, "issue:owner/repo#7"),
        .kind = .issue,
        .number = 7,
        .title = try gpa.dupe(u8, "Fix the flaky test"),
        .url = try gpa.dupe(u8, "https://github.com/owner/repo/issues/7"),
        .state = .queued,
        .created = now,
        .changed = now,
    });
    w.sidebar = .shown;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 1100, .height = 640, .theme = theme.ui() });
    defer t.deinit();
    t.settle(0.5);
    // Nothing is reading it: the row offers Read, and pressing it asks.
    try std.testing.expect(t.hasText("Fix the flaky test"));
    try t.clickText("Read");
    try std.testing.expect(th.threads.items[0].asked);
}

test "the sidebar: a thread that needs you comes before one that is reading" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-sidebar-thread-order";
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
    const th = &shared.threads;
    try th.cfg.projects.append(gpa, .{ .cwd = try gpa.dupe(u8, home), .repo = try gpa.dupe(u8, "owner/repo"), .verified = true });
    const now = @import("blocks.zig").now();
    // Added reading first, waiting second: the sidebar still puts the one
    // that needs you on top.
    for ([_]struct { title: []const u8, state: @import("threads.zig").State }{
        .{ .title = "Still reading", .state = .analyzing },
        .{ .title = "Waiting on you", .state = .proposed },
    }, 1..) |r, i| try th.threads.append(gpa, .{
        .id = i,
        .key = try gpa.dupe(u8, if (i == 1) "pr:owner/repo#1" else "pr:owner/repo#2"),
        .kind = .pr,
        .number = @intCast(i),
        .title = try gpa.dupe(u8, r.title),
        .url = try gpa.dupe(u8, "https://github.com/owner/repo"),
        .state = r.state,
        .created = now,
        .changed = now,
    });
    w.sidebar = .shown;
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 1100, .height = 640, .theme = theme.ui() });
    defer t.deinit();
    t.settle(0.5);
    try std.testing.expect(t.findText("Waiting on you").?.y < t.findText("Still reading").?.y);
}

test "a file opened with nanoterm: a tab in its folder, showing it; the fresh first tab gives way" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-open";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/docs");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/docs/REPORT.md", .data = "# Report\n" });
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    _ = try w.newTab(home);
    const open = @import("open_files.zig").open;
    open(&w, &.{home ++ "/docs/REPORT.md"});
    try std.testing.expectEqual(@as(usize, 1), w.tabs.items.len);
    const s = w.tab().session();
    try std.testing.expectEqualStrings(home ++ "/docs", s.cwd());
    try std.testing.expectEqualStrings("cat 'REPORT.md'", s.queue.items[0]);
    // A folder: a tab in it, beside the first (no longer fresh).
    open(&w, &.{home ++ "/docs"});
    try std.testing.expectEqual(@as(usize, 2), w.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), w.tab().session().queue.items.len);
}
