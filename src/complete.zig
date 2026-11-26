//! Completions, as Warp's menu offers them: Tab completes the word being
//! typed — commands, files and folders, git's subcommands and branches —
//! and in agent mode "/" lists the agent's slash commands while "@" names
//! files and folders for the prompt. One candidate is taken at once;
//! several open a menu (↑↓ to choose, Tab or ↩ to take).
const std = @import("std");
const Commands = @import("commands.zig");
const agent_config = @import("agent_config.zig");

pub const Kind = enum { command, folder, file, git, branch, slash };

pub const Item = struct {
    /// The word as it replaces the one typed.
    word: []const u8,
    /// A description: a slash command's, or what kind of thing it is.
    detail: []const u8 = "",
    kind: Kind,
};

/// The completions of one word, in memory that lives until the next ones.
pub const Menu = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    items: std.ArrayList(Item) = .empty,
    /// Bytes [start, end) of the input are the word being completed.
    start: usize = 0,
    end: usize = 0,
    selected: usize = 0,
    open: bool = false,
    /// Closed with esc: it stays closed until the text changes.
    dismissed: bool = false,

    pub fn init(gpa: std.mem.Allocator) Menu {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(m: *Menu) void {
        m.items.deinit(m.gpa);
        m.arena.deinit();
    }

    pub fn close(m: *Menu) void {
        m.open = false;
        m.items.clearRetainingCapacity();
        _ = m.arena.reset(.retain_capacity);
        m.selected = 0;
    }

    fn add(m: *Menu, word: []const u8, detail: []const u8, kind: Kind) void {
        if (m.items.items.len >= max_items) return;
        const own = m.arena.allocator().dupe(u8, word) catch return;
        m.items.append(m.gpa, .{ .word = own, .detail = detail, .kind = kind }) catch {};
    }

    pub fn move(m: *Menu, by: i32) void {
        const n = m.items.items.len;
        if (n == 0) return;
        const i: i64 = @as(i64, @intCast(m.selected)) + by;
        m.selected = @intCast(@mod(i, @as(i64, @intCast(n))));
    }

    /// The longest start the candidates share.
    pub fn commonPrefix(m: *const Menu) []const u8 {
        const items = m.items.items;
        if (items.len == 0) return "";
        var p = items[0].word;
        for (items[1..]) |it| {
            var n: usize = 0;
            while (n < p.len and n < it.word.len and p[n] == it.word[n]) n += 1;
            p = p[0..n];
        }
        return p;
    }
};

const max_items = 200;

/// How many files and folders a mention's index holds. fx's own scans a
/// hundred thousand in a worker thread; the menu here walks in place, so
/// it takes fewer (the menu shows `max_items` of them anyway).
const max_files = 20_000;

/// The folder names a mention never enters, as fx's indexer skips
/// everywhere: the build's own output and the tree-sized dependencies.
/// (fx also reads git's ignore rules inside a repository; that parsing
/// stays fx's — this list is the menu's approximation.)
const skipped_names = [_][]const u8{ ".git", ".zig-cache", "zig-out", "node_modules", ".next", "dist", "build", "coverage" };

/// A mention's file index, as fx's own "@" builds one: every file and
/// folder under the working folder, walked once and kept while the pane is
/// in it — the whole tree, not one level, so "@main" finds src/ui/main.zig.
pub const Files = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Paths relative to the working folder, folders with a trailing "/".
    items: std.ArrayList([]const u8) = .empty,
    /// The folder the list is of; a cd walks it again.
    root: std.ArrayList(u8) = .empty,
    scanned: bool = false,

    pub fn init(gpa: std.mem.Allocator) Files {
        return .{ .gpa = gpa, .arena = .init(gpa) };
    }

    pub fn deinit(f: *Files) void {
        f.items.deinit(f.gpa);
        f.root.deinit(f.gpa);
        f.arena.deinit();
    }

    /// The list for `cwd`, walked again when the folder changed or `fresh`
    /// asks (a new "@" opened: a file made since the last one is there).
    pub fn ensure(f: *Files, io: std.Io, cwd: []const u8, fresh: bool) void {
        if (!fresh and f.scanned and std.mem.eql(u8, f.root.items, cwd)) return;
        f.items.clearRetainingCapacity();
        _ = f.arena.reset(.retain_capacity);
        f.root.clearRetainingCapacity();
        f.root.appendSlice(f.gpa, cwd) catch return;
        var dir = std.Io.Dir.cwd().openDir(io, cwd, .{ .iterate = true }) catch return;
        defer dir.close(io);
        f.walk(io, dir, "");
        f.scanned = true;
        std.mem.sort([]const u8, f.items.items, {}, struct {
            fn lt(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lt);
    }

    fn walk(f: *Files, io: std.Io, dir: std.Io.Dir, prefix: []const u8) void {
        var entries = dir.iterate();
        while (entries.next(io) catch null) |e| {
            if (f.items.items.len >= max_files) return;
            if (e.name[0] == '.') continue;
            const folder = e.kind == .directory;
            if (folder and skipped(e.name)) continue;
            const path = std.mem.concat(f.arena.allocator(), u8, &.{ prefix, e.name, if (folder) "/" else "" }) catch continue;
            f.items.append(f.gpa, path) catch continue;
            if (folder) {
                var sub = dir.openDir(io, e.name, .{ .iterate = true }) catch continue;
                defer sub.close(io);
                f.walk(io, sub, path);
            }
        }
    }

    fn skipped(name: []const u8) bool {
        for (skipped_names) |s| if (std.mem.eql(u8, s, name)) return true;
        return false;
    }
};

pub const Context = struct {
    io: std.Io,
    cwd: []const u8,
    home: []const u8,
    commands: *const Commands.Commands,
    /// The agent's slash commands, in agent mode.
    slash: ?[]const agent_config.Command = null,
    /// The built-in Agent's arguments for its slash commands (agent_fx).
    fx_args: bool = false,
    /// A prompt being written: "@" names files and folders in it.
    mention: bool = false,
    /// The mention's index of the working folder's files.
    files: *Files,
};

/// Fills `m` with the completions of the word ending at `caret` in `text`.
pub fn compute(m: *Menu, text: []const u8, caret: usize, ctx: Context) void {
    m.close();
    const upto = text[0..@min(caret, text.len)];
    const start = if (std.mem.lastIndexOfScalar(u8, upto, ' ')) |i| i + 1 else 0;
    const word = upto[start..];
    m.start = start;
    m.end = upto.len;
    var words: [8][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeScalar(u8, upto[0..start], ' ');
    while (it.next()) |w| {
        if (n == words.len) break;
        words[n] = w;
        n += 1;
    }
    // The built-in Agent's command, whole and unspaced: its arguments
    // follow it ("/effort" offers its levels right away). Falls through
    // to the command list above when the name is not yet whole.
    if (ctx.fx_args and n == 0 and word.len > 1 and word[0] == '/') {
        if (@import("agent_fx.zig").words(word[1..])) |options| {
            for (options) |option| m.add(option, "", .slash);
            if (m.items.items.len > 0) {
                // The command stays: an argument appends after it, so the
                // word to replace is the empty one at the caret.
                m.start = upto.len;
                return;
            }
        }
    }
    if (ctx.slash) |cmds| if (n == 0 and word.len > 0 and word[0] == '/') {
        for (cmds) |c| if (std.mem.startsWith(u8, c.name, word[1..])) {
            var buf: [128]u8 = undefined;
            m.add(std.fmt.bufPrint(&buf, "/{s}", .{c.name}) catch continue, c.description, .slash);
        };
        return;
    };
    // A mention in a prompt: every file and folder of the working folder
    // that fuzzy-matches the word, its own "@" kept before each — as fx's
    // own picker ranks them, so "@main" finds src/ui/main.zig deep down.
    if (ctx.mention and word.len > 0 and word[0] == '@') {
        ctx.files.ensure(ctx.io, ctx.cwd, false);
        mentions(m, word[1..], ctx.files);
        return;
    }
    if (n == 0) {
        if (word.len == 0 or std.mem.indexOfScalar(u8, word, '/') != null) return paths(m, word, ctx, "");
        for (ctx.commands.withPrefix(word)) |c| m.add(c, "", .command);
        return;
    }
    // A built-in Agent command's argument: "/effort med…" offers its levels.
    if (ctx.fx_args and n == 1 and words[0].len > 1 and words[0][0] == '/') {
        if (@import("agent_fx.zig").words(words[0][1..])) |options| {
            for (options) |option| if (std.mem.startsWith(u8, option, word)) m.add(option, "", .slash);
            if (m.items.items.len > 0) return;
        }
    }
    if (word.len > 0 and word[0] == '-') return;
    if (std.mem.eql(u8, words[0], "git")) {
        if (n == 1) {
            for (Commands.git_subcommands) |s| if (std.mem.startsWith(u8, s, word)) m.add(s, "", .git);
            return;
        }
        if (n == 2 and Commands.takesBranch(words[1])) {
            branches(m, word, ctx);
            if (m.items.items.len > 0) return;
        }
    }
    paths(m, word, ctx, "");
}

/// Files and folders: `word` is a path, absolute, from ~, or from the cwd.
/// `prefix` stands before each candidate — "" for a path being typed, "@"
/// for a mention.
fn paths(m: *Menu, word: []const u8, ctx: Context, prefix: []const u8) void {    const slash = std.mem.lastIndexOfScalar(u8, word, '/');
    const dir_part = if (slash) |i| word[0 .. i + 1] else "";
    const base = if (slash) |i| word[i + 1 ..] else word;
    var buf: [2048]u8 = undefined;
    const dir_path = if (std.mem.startsWith(u8, dir_part, "~/"))
        std.fmt.bufPrint(&buf, "{s}/{s}", .{ ctx.home, dir_part[2..] }) catch return
    else if (dir_part.len > 0 and dir_part[0] == '/')
        dir_part
    else
        std.fmt.bufPrint(&buf, "{s}/{s}", .{ ctx.cwd, dir_part }) catch return;
    var dir = std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(ctx.io);
    var entries = dir.iterate();
    while (entries.next(ctx.io) catch null) |e| {
        if (!std.mem.startsWith(u8, e.name, base)) continue;
        if (e.name[0] == '.' and (base.len == 0 or base[0] != '.')) continue;
        var wbuf: [2048]u8 = undefined;
        const folder = e.kind == .directory;
        const full = std.fmt.bufPrint(&wbuf, "{s}{s}{s}{s}", .{ prefix, dir_part, e.name, if (folder) "/" else "" }) catch continue;
        m.add(full, "", if (folder) .folder else .file);
    }
    std.mem.sort(Item, m.items.items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            // Folders first, then by name.
            if ((a.kind == .folder) != (b.kind == .folder)) return a.kind == .folder;
            return std.mem.order(u8, a.word, b.word) == .lt;
        }
    }.lt);
}

/// A mention's candidates: every path in `files` that fuzzy-matches
/// `query` (the word's "@" taken off), best first — the palette's own
/// scoring, whose word starts are a path's "/" boundaries. A folder keeps
/// its trailing "/", so taking one leaves a word that narrows inside it.
fn mentions(m: *Menu, query: []const u8, files: *Files) void {
    if (files.items.items.len == 0) return;
    const Scored = struct { path: []const u8, s: i32 };
    var list: std.ArrayList(Scored) = .empty;
    defer list.deinit(m.gpa);
    for (files.items.items) |p| {
        // A word that already names a folder: taking it left this list, so
        // what follows is what is inside it, not the folder again.
        if (query.len > 0 and std.mem.eql(u8, p, query)) continue;
        const s = @import("palette.zig").score(p, query) orelse continue;
        list.append(m.gpa, .{ .path = p, .s = s }) catch return;
    }
    std.mem.sort(Scored, list.items, {}, struct {
        fn gt(_: void, a: Scored, b: Scored) bool {
            if (a.s != b.s) return a.s > b.s;
            return std.mem.order(u8, a.path, b.path) == .lt;
        }
    }.gt);
    for (list.items) |it| {
        const folder = it.path.len > 0 and it.path[it.path.len - 1] == '/';
        var buf: [2048]u8 = undefined;
        const w = std.fmt.bufPrint(&buf, "@{s}", .{it.path}) catch break;
        m.add(w, "", if (folder) .folder else .file);
    }
}

/// Local branches, from the repository's refs (no git process).
fn branches(m: *Menu, word: []const u8, ctx: Context) void {
    var dir_buf: [2048]u8 = undefined;
    var at: []const u8 = ctx.cwd;
    // The repository: the cwd or the nearest folder above with a .git.
    while (true) {
        const git = std.fmt.bufPrint(&dir_buf, "{s}/.git/refs/heads", .{at}) catch return;
        var dir = std.Io.Dir.cwd().openDir(ctx.io, git, .{ .iterate = true }) catch {
            const up = std.fs.path.dirname(at) orelse return;
            if (up.len == at.len) return;
            at = up;
            continue;
        };
        defer dir.close(ctx.io);
        var walker = dir.walk(m.gpa) catch return;
        defer walker.deinit();
        while (walker.next(ctx.io) catch null) |e| {
            if (e.kind != .file or !std.mem.startsWith(u8, e.path, word)) continue;
            m.add(e.path, "", .branch);
        }
        return;
    }
}

test "completing commands, git, files" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var cmds: Commands.Commands = .init(gpa);
    defer cmds.deinit();
    for ([_][]const u8{ "git", "grep", "gzip", "ls" }) |c| cmds.add(c);
    std.mem.sort([]const u8, cmds.sorted.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    const dir = "/tmp/nanoterm-test-complete";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir ++ "/src/ui");
    try std.Io.Dir.cwd().createDirPath(io, dir ++ "/.git/refs/heads/feature");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/src/ui/panel.zig", .data = "" });
    try std.Io.Dir.cwd().createDirPath(io, dir ++ "/node_modules");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/node_modules/skip.js", .data = "" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/stack.zig", .data = "" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/.git/refs/heads/main", .data = "" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dir ++ "/.git/refs/heads/feature/menu", .data = "" });
    var files: Files = .init(gpa);
    defer files.deinit();
    const ctx: Context = .{ .io = io, .cwd = dir, .home = dir, .commands = &cmds, .files = &files };

    var m: Menu = .init(gpa);
    defer m.deinit();
    compute(&m, "g", 1, ctx);
    try std.testing.expectEqual(@as(usize, 3), m.items.items.len);
    try std.testing.expectEqualStrings("g", m.commonPrefix());
    compute(&m, "git sta", 7, ctx);
    try std.testing.expectEqual(@as(usize, 2), m.items.items.len); // stash, status
    try std.testing.expectEqualStrings("sta", m.commonPrefix());
    compute(&m, "cat s", 5, ctx);
    try std.testing.expectEqual(@as(usize, 2), m.items.items.len);
    try std.testing.expectEqualStrings("src/", m.items.items[0].word); // folders first
    try std.testing.expectEqual(@as(usize, 4), m.start);
    compute(&m, "ls src/", 7, ctx);
    try std.testing.expectEqualStrings("src/ui/", m.items.items[0].word);
    compute(&m, "git switch fe", 13, ctx);
    try std.testing.expectEqualStrings("feature/menu", m.items.items[0].word);
    try std.testing.expectEqual(Kind.branch, m.items.items[0].kind);
    // A built-in Agent command's arguments: "/effort " offers its levels.
    compute(&m, "/effort m", 9, .{ .io = io, .cwd = dir, .home = dir, .commands = &cmds, .files = &files, .fx_args = true });
    try std.testing.expectEqual(@as(usize, 2), m.items.items.len); // minimal, medium
    try std.testing.expectEqualStrings("minimal", m.items.items[0].word);
    try std.testing.expectEqual(Kind.slash, m.items.items[0].kind);
    // Without fx args (an external agent), the path completion stands.
    compute(&m, "/effort m", 9, .{ .io = io, .cwd = dir, .home = dir, .commands = &cmds, .files = &files });
    try std.testing.expect(m.items.items.len == 0 or m.items.items[0].kind != .slash);

    // A mention in a prompt: every file of the working folder, however
    // deep, fuzzy-matched (fx's own picker), each keeping the word's "@".
    const mctx: Context = .{ .io = io, .cwd = dir, .home = dir, .commands = &cmds, .files = &files, .mention = true };
    compute(&m, "read @pan", 9, mctx);
    try std.testing.expectEqualStrings("@src/ui/panel.zig", m.items.items[0].word);
    try std.testing.expectEqual(Kind.file, m.items.items[0].kind);
    try std.testing.expectEqual(@as(usize, 5), m.start);
    // The word already names a folder: what follows is what is inside it.
    compute(&m, "read @src/", 10, mctx);
    try std.testing.expectEqualStrings("@src/ui/", m.items.items[0].word);
    try std.testing.expectEqual(Kind.folder, m.items.items[0].kind);
    // The folders fx skips (node_modules, .git) are not in the list.
    compute(&m, "read @skip", 10, mctx);
    try std.testing.expectEqual(@as(usize, 0), m.items.items.len);
    compute(&m, "read @refs", 10, mctx);
    try std.testing.expectEqual(@as(usize, 0), m.items.items.len);
    // Outside a prompt, "@" is nothing special: no "@" candidates appear.
    compute(&m, "read @s", 7, ctx);
    try std.testing.expectEqual(@as(usize, 0), m.items.items.len);

    var cmd_name = "review".*;
    var desc = "review code".*;
    var hint = "".*;
    const slash = [_]agent_config.Command{.{ .name = &cmd_name, .description = &desc, .hint = &hint }};
    var actx = ctx;
    actx.slash = &slash;
    compute(&m, "/re", 3, actx);
    try std.testing.expectEqualStrings("/review", m.items.items[0].word);
}
