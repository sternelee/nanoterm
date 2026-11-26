//! Nerd Font icons for the files `ls` prints: a folder, a picture, an
//! archive, a program. The glyphs are put in only as the lines are drawn,
//! so the output itself — what Copy takes, what Find searches — is the
//! command's own.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");

/// How the command laid its files out, which says where each name is.
pub const Mode = enum { none, columns, long, one_per_line };

/// What a file is, for its glyph and its color.
const Kind = enum { directory, symlink, image, audio, video, archive, pdf, code, markdown, config, lock, executable, text, generic };

const Glyph = struct { text: []const u8, color: ui.Color };

/// A Nerd family has the private-use glyphs itself. CoreText does not fall
/// back from an ordinary mono font to an installed Nerd font (it uses
/// LastResort), so ordinary families get visible Unicode file icons instead.
fn nerdEnabled() bool {
    const family = theme.mono_font orelse return false;
    if (family.len > 256) return false;
    var lower_buf: [256]u8 = undefined;
    const lower = std.ascii.lowerString(lower_buf[0..family.len], family);
    return std.mem.indexOf(u8, lower, "nerd") != null or std.mem.endsWith(u8, lower, " nf") or std.mem.endsWith(u8, lower, "nf");
}

fn pick(nerd: []const u8, fallback: []const u8, color: ui.Color) Glyph {
    return .{ .text = if (nerdEnabled()) nerd else fallback, .color = color };
}

fn glyph(kind: Kind) Glyph {
    return switch (kind) {
        .directory => pick("\u{f07b}", "📁", theme.cwd),
        .symlink => pick("\u{f0c1}", "🔗", theme.branch),
        .image => pick("\u{f1c5}", "🖼️", theme.agent),
        .audio => pick("\u{f1c7}", "🎵", theme.agent),
        .video => pick("\u{f1c8}", "🎬", theme.failure),
        .archive => pick("\u{f1c6}", "🗜️", theme.warning),
        .pdf => pick("\u{f1c1}", "📕", theme.failure),
        .code => pick("\u{f121}", "⌘", theme.accent),
        .markdown => pick("\u{f121}", "Ⓜ", theme.accent),
        .config => pick("\u{f013}", "⚙️", theme.warning),
        .lock => pick("\u{f023}", "🔒", theme.warning),
        .executable => pick("\u{f135}", "🚀", theme.success),
        .text => pick("\u{f15c}", "📄", theme.muted),
        .generic => pick("\u{f15b}", "📄", theme.faint),
    };
}

/// What `command` is: `ls` and how it printed, or not a listing.
pub fn listing(command: []const u8) Mode {
    var words = std.mem.tokenizeAny(u8, command, " \t");
    const first = words.next() orelse return .none;
    // The usual alias for `ls -l`; whatever it really runs, a line that
    // isn't that shape decorates nothing.
    if (std.mem.eql(u8, first, "ll")) return .long;
    if (!std.mem.eql(u8, first, "ls")) return .none;
    var long = false;
    var one = false;
    while (words.next()) |word| {
        // A pipe or another command after it: not a plain listing.
        if (word.len > 0 and std.mem.indexOfScalar(u8, "|&;<>", word[0]) != null) return .none;
        if (word.len < 2 or word[0] != '-') continue;
        if (word[1] == '-') continue;
        for (word[1..]) |ch| switch (ch) {
            'l' => long = true,
            '1' => one = true,
            // Comma-separated names, not one to a place.
            'm' => return .none,
            else => {},
        };
    }
    if (long) return .long;
    if (one) return .one_per_line;
    return .columns;
}

const Insertion = struct { at: usize, kind: Kind };

/// A line drawn with its icons: the text has them in, the spans say what
/// they are colored, and the command's spans have moved to follow.
pub const Decorated = struct { text: []const u8, spans: []const ui.Span };

/// Puts an icon before each file `line` names, in this frame's memory.
/// The original line and spans are not touched.
pub fn decorate(arena: std.mem.Allocator, io: std.Io, cwd: []const u8, line: []const u8, spans: []const ui.Span, mode: Mode) ?Decorated {
    if (mode == .none or line.len == 0) return null;
    var items: std.ArrayList(Insertion) = .empty;
    switch (mode) {
        .none => unreachable,
        .long => {
            const trimmed = std.mem.trim(u8, line, " ");
            if (std.mem.startsWith(u8, trimmed, "total ")) return null;
            const at = longFilenameStart(line) orelse return null;
            items.append(arena, .{ .at = at, .kind = longKind(io, cwd, line, line[at..]) }) catch return null;
        },
        .one_per_line => items.append(arena, .{ .at = 0, .kind = kindOf(io, cwd, line) }) catch return null,
        .columns => {
            var i: usize = 0;
            while (i < line.len) {
                while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
                if (i >= line.len) break;
                const start = i;
                while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
                items.append(arena, .{ .at = start, .kind = kindOf(io, cwd, line[start..i]) }) catch return null;
            }
        },
    }
    if (items.items.len == 0) return null;
    return assemble(arena, line, spans, items.items);
}

/// Output a tool printed when it looks like nothing else: every line a
/// long listing's row, or every line a bare path. Agents list files
/// through tools whose names we never learn — a shell tool that prints
/// ls, a glob of paths — but the lines' shape says it, so the icons come
/// without asking the tool. Anything else stays plain.
pub fn decorateOutput(arena: std.mem.Allocator, io: std.Io, cwd: []const u8, text: []const u8) ?Decorated {
    var rows: usize = 0;
    var listings: usize = 0;
    var paths: usize = 0;
    var found: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const eol = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const line = std.mem.trim(u8, text[i..eol], " \t\r");
        if (line.len > 0) {
            rows += 1;
            if (headerRow(line) or longFilenameStart(line) != null) listings += 1;
            if (std.mem.indexOfAny(u8, line, " \t") == null) {
                paths += 1;
                if (statKind(io, cwd, line) != null) found += 1;
            }
        }
        i = eol + 1;
    }
    // Every row a listing's (headers aside), or bare paths — at least
    // two, and one of them really there — so prose and reports stay plain.
    const listing_rows = listings == rows;
    const bare_paths = paths == rows and rows >= 2 and found > 0;
    if (rows == 0 or (!listing_rows and !bare_paths)) return null;
    var items: std.ArrayList(Insertion) = .empty;
    i = 0;
    while (i < text.len) {
        const eol = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
        const raw = text[i..eol];
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len > 0) {
            if (listing_rows) {
                if (!headerRow(line)) {
                    if (longFilenameStart(raw)) |at| {
                        const name = std.mem.trimEnd(u8, raw[at..], " \r");
                        items.append(arena, .{ .at = i + at, .kind = longKind(io, cwd, raw, name) }) catch return null;
                    }
                }
            } else {
                const lead = @intFromPtr(line.ptr) - @intFromPtr(raw.ptr);
                items.append(arena, .{ .at = i + lead, .kind = kindOf(io, cwd, line) }) catch return null;
            }
        }
        i = eol + 1;
    }
    if (items.items.len == 0) return null;
    return assemble(arena, text, &.{}, items.items);
}

/// A row that says nothing: ls's `total`, exa's header.
fn headerRow(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "total ") or std.mem.startsWith(u8, line, "Permissions ");
}

/// The line with its icons in, the spans — the icons' own, and `spans`
/// shifted past them — saying what is colored.
fn assemble(arena: std.mem.Allocator, line: []const u8, spans: []const ui.Span, items: []const Insertion) ?Decorated {
    var extra: usize = 0;
    for (items) |item| extra += glyph(item.kind).text.len + 1;
    const text = arena.alloc(u8, line.len + extra) catch return null;
    var out: std.ArrayList(ui.Span) = .empty;
    out.ensureTotalCapacity(arena, spans.len + items.len) catch return null;

    var pos: usize = 0;
    var prev: usize = 0;
    for (items) |item| {
        const chunk = line[prev..item.at];
        @memcpy(text[pos..][0..chunk.len], chunk);
        pos += chunk.len;
        const icon = glyph(item.kind);
        const start = pos;
        @memcpy(text[pos..][0..icon.text.len], icon.text);
        pos += icon.text.len;
        const end = pos;
        text[pos] = ' ';
        pos += 1;
        out.appendAssumeCapacity(.{ .start = @intCast(start), .end = @intCast(end), .color = icon.color });
        prev = item.at;
    }
    const rest = line[prev..];
    @memcpy(text[pos..][0..rest.len], rest);
    pos += rest.len;
    std.debug.assert(pos == text.len);

    for (spans) |span| out.appendAssumeCapacity(shifted(span, items));
    const all = out.allocatedSlice();
    std.mem.sort(ui.Span, all, {}, struct {
        fn less(_: void, a: ui.Span, b: ui.Span) bool {
            return a.start < b.start;
        }
    }.less);
    return .{ .text = text, .spans = all };
}

/// Where the file's name is in a long listing. `ls -l` puts it after
/// eight fields — mode, links, owner, group, size, and a three-field
/// date month-first; exa and eza, which `ls` is often aliased to,
/// after seven — mode, size, user, and the date day-first. The date's
/// month says which of the two shapes a line is, so an exa behind an
/// `ll` alias decorates as well as ls itself. What is neither shape —
/// a header row, another command's output — names nothing.
fn longFilenameStart(line: []const u8) ?usize {
    var starts: [9]usize = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < line.len and n < 9) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) break;
        starts[n] = i;
        n += 1;
        while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
    }
    // exa's date is day-first — the month is the fifth field — so the
    // name is the seventh; ls's date is month-first, the name ninth
    // (its links and group make two fields more).
    if (n >= 7 and isMonth(line[starts[4]..nextSpace(line, starts[4])])) return starts[6];
    if (n >= 9 and isMonth(line[starts[5]..nextSpace(line, starts[5])])) return starts[8];
    return null;
}

fn nextSpace(line: []const u8, from: usize) usize {
    var i = from;
    while (i < line.len and line[i] != ' ' and line[i] != '\t') i += 1;
    return i;
}

fn isMonth(field: []const u8) bool {
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    for (months) |m| if (std.mem.eql(u8, field, m)) return true;
    return false;
}

fn longKind(io: std.Io, cwd: []const u8, line: []const u8, name: []const u8) Kind {
    const trimmed = std.mem.trim(u8, line, " ");
    if (trimmed.len == 0) return kindOf(io, cwd, name);
    if (trimmed[0] == 'd') return .directory;
    if (trimmed[0] == 'l') return .symlink;
    if (trimmed.len >= 10 and (trimmed[3] == 'x' or trimmed[6] == 'x' or trimmed[9] == 'x')) return .executable;
    return kindOf(io, cwd, name);
}

fn shifted(span: ui.Span, items: []const Insertion) ui.Span {
    var out = span;
    for (items) |item| {
        const by: u32 = @intCast(glyph(item.kind).text.len + 1);
        if (span.start >= item.at) out.start += by;
        if (span.end > item.at) out.end += by;
    }
    return out;
}

fn kindOf(io: std.Io, cwd: []const u8, name: []const u8) Kind {
    if (statKind(io, cwd, name)) |kind| return kind;
    var n = name;
    if (n.len >= 2 and n[0] == '"' and n[n.len - 1] == '"') n = n[1 .. n.len - 1];
    if (std.mem.indexOf(u8, n, " -> ") != null) return .symlink;
    if (n.len > 0) {
        const mark = n[n.len - 1];
        if (std.mem.indexOfScalar(u8, "/@|=*", mark) != null) {
            n = n[0 .. n.len - 1];
            if (mark == '/') return .directory;
            if (mark == '@') return .symlink;
            if (mark == '*') return .executable;
        }
    }
    if (n.len == 0) return .generic;
    if (isName(n, &.{ "package-lock.json", "yarn.lock", "pnpm-lock.yaml", "cargo.lock", "flake.lock", "poetry.lock", "uv.lock" })) return .lock;
    if (isExt(n, &.{ ".md", ".markdown" })) return .markdown;
    if (isExt(n, &.{ ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg", ".bmp", ".ico", ".tiff", ".heic" })) return .image;
    if (isExt(n, &.{ ".mp3", ".wav", ".flac", ".aac", ".ogg", ".m4a" })) return .audio;
    if (isExt(n, &.{ ".mp4", ".mov", ".mkv", ".avi", ".webm" })) return .video;
    if (isExt(n, &.{ ".zip", ".tar", ".gz", ".tgz", ".rar", ".7z", ".bz2", ".xz", ".zst" })) return .archive;
    if (isExt(n, &.{".pdf"})) return .pdf;
    if (isExt(n, &.{ ".zig", ".js", ".ts", ".tsx", ".jsx", ".mjs", ".cjs", ".py", ".rb", ".rs", ".go", ".c", ".h", ".cpp", ".hpp", ".java", ".kt", ".swift", ".sh", ".bash", ".zsh", ".css", ".scss", ".html", ".sql", ".lua", ".php", ".vue", ".svelte" })) return .code;
    if (isExt(n, &.{ ".json", ".yaml", ".yml", ".toml", ".ini", ".cfg", ".conf", ".env", ".zshrc", ".bashrc", ".gitconfig" })) return .config;
    if (isExt(n, &.{ ".txt", ".text", ".log" })) return .text;
    return .generic;
}

fn isName(name: []const u8, names: []const []const u8) bool {
    for (names) |want| if (std.ascii.eqlIgnoreCase(name, want)) return true;
    return false;
}

/// What the file really is, from the directory the command listed.
fn statKind(io: std.Io, cwd: []const u8, name: []const u8) ?Kind {
    if (cwd.len == 0 or name.len == 0) return null;
    var buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ cwd, name }) catch return null;
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    if (stat.kind == .directory) return .directory;
    if (stat.kind == .file and stat.permissions.toMode() & 0o111 != 0) return .executable;
    return null;
}

fn isExt(name: []const u8, extensions: []const []const u8) bool {
    const ext = std.fs.path.extension(name);
    for (extensions) |want| if (std.ascii.eqlIgnoreCase(ext, want)) return true;
    return false;
}
