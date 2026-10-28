//! `ls` with Nerd Font icons: the listings are told apart, the lines are
//! decorated without touching what the command printed, and the real view
//! shows them (Settings can turn them off).
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const ws_mod = @import("workspace.zig");
const session_mod = @import("session.zig");
const view = @import("view.zig");
const view_settings = @import("view_settings.zig");
const theme = @import("theme.zig");
const file_icons = @import("file_icons.zig");

test "ls is told apart from other commands, and how it printed" {
    try std.testing.expectEqual(file_icons.Mode.columns, file_icons.listing("ls"));
    try std.testing.expectEqual(file_icons.Mode.long, file_icons.listing("ls -l"));
    try std.testing.expectEqual(file_icons.Mode.long, file_icons.listing("ls -la /tmp"));
    try std.testing.expectEqual(file_icons.Mode.long, file_icons.listing("ll"));
    try std.testing.expectEqual(file_icons.Mode.long, file_icons.listing("ll -a"));
    try std.testing.expectEqual(file_icons.Mode.one_per_line, file_icons.listing("ls -1"));
    try std.testing.expectEqual(file_icons.Mode.none, file_icons.listing("echo ls"));
    try std.testing.expectEqual(file_icons.Mode.none, file_icons.listing("ls | wc -l"));
    try std.testing.expectEqual(file_icons.Mode.none, file_icons.listing("ls -m"));
}

test "a line of files gets an icon before each, without changing the output" {
    const previous_font = theme.mono_font;
    defer theme.mono_font = previous_font;
    theme.mono_font = "FiraCode Nerd Font Mono";
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const home = "/tmp/nanoterm-test-file-icons";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/src");
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/docs");

    const line = "src  docs";
    const original = [_]ui.Span{.{ .start = 0, .end = 3, .background = theme.accent }};
    const d = file_icons.decorate(arena, io, home, line, &original, .columns) orelse return error.NoIcons;
    try std.testing.expectEqualStrings("\u{f07b} src  \u{f07b} docs", d.text);
    try std.testing.expectEqualStrings("src  docs", line);

    var moved: ?ui.Span = null;
    for (d.spans) |span| {
        if (span.background != null) moved = span;
    }
    const span = moved orelse return error.SpanNotMoved;
    try std.testing.expectEqual(@as(u32, 4), span.start);
    try std.testing.expectEqual(@as(u32, 7), span.end);
}

test "a long listing puts its icon before the name, and total stays bare" {
    const previous_font = theme.mono_font;
    defer theme.mono_font = previous_font;
    theme.mono_font = "FiraCode Nerd Font Mono";
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-file-icons";

    const dir = "drwxr-xr-x  5 user  staff   160 Oct  2 10:00 src";
    const d = file_icons.decorate(arena, io, home, dir, &.{}, .long) orelse return error.NoIcons;
    try std.testing.expect(std.mem.endsWith(u8, d.text, "\u{f07b} src"));
    try std.testing.expect(std.mem.startsWith(u8, d.text, "drwxr-xr-x"));

    const run = "-rwxr-xr-x  1 user  staff    32 Oct  2 10:00 run.sh";
    const r = file_icons.decorate(arena, io, home, run, &.{}, .long) orelse return error.NoIcons;
    try std.testing.expect(std.mem.endsWith(u8, r.text, "\u{f135} run.sh"));

    try std.testing.expect(file_icons.decorate(arena, io, home, "total 8", &.{}, .long) == null);
}

test "ordinary mono fonts use visible icons instead of missing Nerd glyphs" {
    const previous_font = theme.mono_font;
    defer theme.mono_font = previous_font;
    theme.mono_font = "JetBrains Mono";
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const d = file_icons.decorate(arena_state.allocator(), std.testing.io, "/tmp/nanoterm-test-file-icons", "src", &.{}, .one_per_line) orelse return error.NoIcons;
    try std.testing.expectEqualStrings("📁 src", d.text);
    try std.testing.expect(std.mem.indexOf(u8, d.text, "\u{f07b}") == null);
}

test "the real view shows ls with its icons, and Settings can turn them off" {
    const previous_font = theme.mono_font;
    defer theme.mono_font = previous_font;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const home = "/tmp/nanoterm-test-file-icons";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/src");
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/readme.md", .data = "# nanoterm\n" }) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/picture.png", .data = "\x89PNG\n" }) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/archive.zip", .data = "PK\x05\x06" }) catch {};
    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/run.sh", .data = "printf ok\n" }) catch {};
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    var shared = try session_mod.Shared.init(gpa, io, arena, &env);
    shared.wire();
    defer shared.deinit();
    shared.prefs.setTerminalFont("FiraCode Nerd Font Mono");
    var w: ws_mod.Workspace = .{ .shared = &shared, .nanoapp = undefined };
    defer w.deinit();
    const s = try w.newTab(home);
    var t: ui.Tester = undefined;
    try t.init(gpa, .init(&w, view.view), .{ .width = 900, .height = 640, .theme = theme.ui() });
    defer t.deinit();
    t.settle(1);
    s.run("ls -1");
    var waited: f64 = 0;
    while (s.timeline.items.len == 0 or s.timeline.items[s.timeline.items.len - 1].block.state == .running) : (waited += 0.02) {
        if (waited > 10) return error.Timeout;
        nanoui.runFor(0.02);
        t.frame();
    }
    t.settle(1);
    try std.testing.expect(t.containsText("readme.md"));
    try std.testing.expect(t.containsText("\u{f07b} src"));
    try t.screenshot("/tmp/nanoterm-ls-file-icons.png");

    // The output itself is untouched: what Copy takes has no glyphs.
    const b = s.timeline.items[s.timeline.items.len - 1].block;
    const raw = try b.output.plainText(gpa);
    defer gpa.free(raw);
    try std.testing.expect(std.mem.indexOf(u8, raw, "\u{f07b}") == null);

    // A selection made by Settings is applied by the very next frame, not
    // left in the TextSystem's previous family until some later redraw.
    shared.prefs.setTerminalFont("Menlo");
    t.settle(1);
    try std.testing.expectEqualStrings("Menlo", t.text.mono_family.?);
    try std.testing.expect(t.containsText("📁 src"));
    try std.testing.expect(!t.containsText("\u{f07b} src"));

    // Settings: the terminal font and the icons are there, and off means off.
    w.openSettings();
    t.settle(1);
    try std.testing.expect(t.hasText("Terminal font"));
    try std.testing.expect(t.hasText("File icons in ls"));
    try std.testing.expect(t.hasText("System"));
    shared.prefs.setFileIcons(false);
    t.settle(1);
    try std.testing.expect(!t.containsText("\u{f07b} src"));
}

test "a long font name is fitted to the select, not let to overflow it" {
    const Blank = struct {
        fn build(_: *@This(), _: *ui.Context) void {}
    };
    var blank: Blank = .{};
    var t: ui.Tester = undefined;
    try t.init(std.testing.allocator, .init(&blank, Blank.build), .{ .width = 300, .height = 200 });
    defer t.deinit();

    try std.testing.expectEqualStrings("Menlo", view_settings.fontOptionLabel(&t.ctx, "Menlo"));
    const long = "Some Extremely Long Nerd Font Family Name With Many Words";
    const label = view_settings.fontOptionLabel(&t.ctx, long);
    try std.testing.expect(label.len < long.len);
    try std.testing.expect(std.mem.endsWith(u8, label, "…"));
    try std.testing.expect(t.text.width(label, .{ .size = 13 }) <= 200);
}
