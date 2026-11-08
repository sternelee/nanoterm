//! The phone's nanoterm: what a workstation's relay sends, on a phone.
//!
//! A thin client, and thin is the point: a phone cannot run a terminal
//! (forks, a PTY, a shell), so it shows what the desktop relay sends —
//! the tabs, each command and what it printed, an agent's answers — and
//! sends back what the user does: a command to run, a question for the
//! agent, an answer to a permission it is waiting on.
//!
//! It connects to a relay at `--host HOST --port PORT --token TOKEN`
//! (defaults: 127.0.0.1, 4789, taken from NANOTERM_RELAY_TOKEN) and reads
//! the events the relay writes, one JSON object per line, on the main
//! thread: `fdwatch` for the socket, no polling, no second thread.
const types = @import("nanoui").ui.types;
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const fdwatch = nanoui.fdwatch;
const settings = @import("settings.zig");
const md = @import("markdown");
const highlight = @import("highlight");
/// The desktop's palette: the phone wears the same theme.
const theme = @import("theme");

comptime {
    // A phone's app: iOS (and, later, Android). The desktop has nanoterm
    // itself, with a shell on the other end of the relay.
    if (builtin.os.tag == .windows) @compileError("the phone's nanoterm is an iOS app; nanoterm on the Mac is the relay's other end");
}

/// A debug build says what it received on the console, which is how a
/// Simulator run is checked (and how `simctl launch --console` reads).
const develop = builtin.mode == .debug;

fn note(comptime fmt: []const u8, args: anytype) void {
    if (develop) std.debug.print("phone: " ++ fmt ++ "\n", args);
}

/// Lines kept, and the longest of them: a feed of what came, not history.
const keep_lines = 400;
const max_line = 2000;
/// Bytes of a partial event held while its newline arrives (the relay's
/// own limit is larger: this is a phone).
const max_waiting = 256 * 1024;
/// What one read takes before a frame gets its turn: enough for a long
/// reply's backlog, small enough to keep the touch responsive.
const max_drain = 512 * 1024;
/// Permission questions shown at once: the newest are the ones waiting.
const max_pending = 4;
/// A turn's id in `running`, apart from a block's: ids count from one in
/// both, and a block and a turn may be running in the same tab.
const turn_bit: u64 = 1 << 63;

/// Which of the two the window shows: the connection's own fields (a
/// phone has no command line to be told on), or what the relay sends.
const Screen = enum { connect, feed };

const Status = enum {
    connecting,
    live,
    down,

    fn label(s: Status) []const u8 {
        return switch (s) {
            .connecting => "connecting",
            .live => "connected",
            .down => "not connected",
        };
    }
};

/// What the agent asked and has not been answered: a card, and the tap
/// that answers it.
const Pending = struct {
    rpc: []u8,
    title: []u8,
    options: std.ArrayList([]u8) = .empty,
    /// The permission type: "file", "network", "execute", etc. for icon display.
    perm_type: []u8 = "",
    /// Additional detail about what this permission is for.
    detail: []u8 = "",
    /// Which option was chosen (null = not yet answered).
    chosen: ?usize = null,

    fn deinit(p: *Pending, gpa: std.mem.Allocator) void {
        gpa.free(p.rpc);
        gpa.free(p.title);
        if (p.perm_type.len > 0) gpa.free(p.perm_type);
        if (p.detail.len > 0) gpa.free(p.detail);
        for (p.options.items) |o| gpa.free(o);
        p.options.deinit(gpa);
    }
};

/// A note in the feed that is not a turn or a block: what the phone says
/// about the connection, an error, or a line the user typed.
const Line = struct {
    kind: Kind,
    text: []u8,

    const Kind = enum { notice, failure };

    fn deinit(l: *Line, gpa: std.mem.Allocator) void {
        gpa.free(l.text);
    }
};

/// One step of an agent's turn, as the relay sends it: the same items the
/// desktop draws, so the phone can show them the same way.
pub const Item = union(enum) {
    text: std.ArrayList(u8),
    thought: std.ArrayList(u8),
    tool: Tool,
    plan: std.ArrayList(PlanEntry),
    permission: Permission,
    command: u64,
    note: std.ArrayList(u8),
    visual: std.ArrayList(u8),

    pub const ToolStatus = enum { pending, in_progress, completed, failed };

    const Tool = struct {
        id: std.ArrayList(u8) = .empty,
        kind: std.ArrayList(u8) = .empty,
        title: std.ArrayList(u8) = .empty,
        detail: std.ArrayList(u8) = .empty,
        status: ToolStatus = .pending,
        /// The command block whose output it shows, when it ran one.
        block: ?u64 = null,

        fn deinit(t: *Tool, gpa: std.mem.Allocator) void {
            t.id.deinit(gpa);
            t.kind.deinit(gpa);
            t.title.deinit(gpa);
            t.detail.deinit(gpa);
        }
    };

    const PlanEntry = struct {
        text: std.ArrayList(u8) = .empty,
        status: std.ArrayList(u8) = .empty,

        fn deinit(e: *PlanEntry, gpa: std.mem.Allocator) void {
            e.text.deinit(gpa);
            e.status.deinit(gpa);
        }
    };

    const Option = struct {
        id: std.ArrayList(u8) = .empty,
        name: std.ArrayList(u8) = .empty,

        fn deinit(o: *Option, gpa: std.mem.Allocator) void {
            o.id.deinit(gpa);
            o.name.deinit(gpa);
        }
    };

    const Permission = struct {
        rpc: std.ArrayList(u8) = .empty,
        title: std.ArrayList(u8) = .empty,
        options: std.ArrayList(Option) = .empty,
        chosen: ?usize = null,

        fn deinit(p: *Permission, gpa: std.mem.Allocator) void {
            p.rpc.deinit(gpa);
            p.title.deinit(gpa);
            for (p.options.items) |*o| o.deinit(gpa);
            p.options.deinit(gpa);
        }
    };

    fn deinit(it: *Item, gpa: std.mem.Allocator) void {
        switch (it.*) {
            .text => |*l| l.deinit(gpa),
            .thought => |*l| l.deinit(gpa),
            .note => |*l| l.deinit(gpa),
            .visual => |*l| l.deinit(gpa),
            .tool => |*t| t.deinit(gpa),
            .plan => |*entries| {
                for (entries.items) |*e| e.deinit(gpa);
                entries.deinit(gpa);
            },
            .permission => |*p| p.deinit(gpa),
            .command => {},
        }
    }
};

fn statusOf(s: []const u8) Item.ToolStatus {
    if (std.mem.eql(u8, s, "completed")) return .completed;
    if (std.mem.eql(u8, s, "failed")) return .failed;
    if (std.mem.eql(u8, s, "in_progress")) return .in_progress;
    return .pending;
}

/// Where the reply starts: the text items after the last other item.
fn replyStart(items: []const Item) usize {
    var i = items.len;
    while (i > 0 and items[i - 1] == .text) i -= 1;
    return i;
}

/// Whether item `i` folds into a group (thoughts, tools, commands, and
/// the narration before the reply).
fn folds(items: []const Item, i: usize, reply: usize) bool {
    return switch (items[i]) {
        .thought, .tool, .command, .note => true,
        .text => i < reply,
        else => false,
    };
}

fn isVisualTool(tl: *const Item.Tool) bool {
    if (tl.status != .completed) return false;
    return std.mem.indexOf(u8, tl.title.items, "show_visual") != null or std.mem.indexOf(u8, tl.kind.items, "show_visual") != null;
}

fn shownByTool(t: *const Turn, block: u64) bool {
    for (t.items.items) |it| switch (it) {
        .tool => |tl| if (tl.block) |b| if (b == block) return true,
        else => {},
    };
    return false;
}

fn shownItem(t: *const Turn, it: *const Item) bool {
    return switch (it.*) {
        .tool => |*tl| !isVisualTool(tl),
        .command => |b| !shownByTool(t, b),
        else => true,
    };
}

fn plural(c: *ui.Context, n: usize, one: []const u8, many: []const u8) []const u8 {
    return c.print("{d} {s}", .{ n, if (n == 1) one else many });
}

/// What a group did, in the desktop's words.
fn summary(c: *ui.Context, t: *const Turn, items: []const Item) []const u8 {
    var reads: usize = 0;
    var edits: usize = 0;
    var commands: usize = 0;
    var searches: usize = 0;
    var fetches: usize = 0;
    var other: usize = 0;
    var thoughts: usize = 0;
    var notes: usize = 0;
    var failed: usize = 0;
    for (items) |*it| {
        if (!shownItem(t, it)) continue;
        switch (it.*) {
            .thought => thoughts += 1,
            .text, .note => notes += 1,
            .command => commands += 1,
            .tool => |tl| {
                if (tl.status == .failed) failed += 1;
                const k = tl.kind.items;
                const eq = std.mem.eql;
                if (eq(u8, k, "read")) reads += 1 else if (eq(u8, k, "edit") or eq(u8, k, "delete") or eq(u8, k, "move")) edits += 1 else if (eq(u8, k, "execute")) commands += 1 else if (eq(u8, k, "search")) searches += 1 else if (eq(u8, k, "fetch")) fetches += 1 else if (eq(u8, k, "think")) thoughts += 1 else other += 1;
            },
            else => {},
        }
    }
    var parts: std.ArrayList([]const u8) = .empty;
    const a = c.alloc();
    if (thoughts == 1) parts.append(a, "thought process") catch {};
    if (thoughts > 1) parts.append(a, c.print("thought {d} times", .{thoughts})) catch {};
    if (notes == 1) parts.append(a, "wrote a note") catch {};
    if (notes > 1) parts.append(a, c.print("wrote {d} notes", .{notes})) catch {};
    if (commands > 0) parts.append(a, c.print("ran {s}", .{plural(c, commands, "command", "commands")})) catch {};
    if (edits > 0) parts.append(a, c.print("edited {s}", .{plural(c, edits, "file", "files")})) catch {};
    if (reads > 0) parts.append(a, c.print("read {s}", .{plural(c, reads, "file", "files")})) catch {};
    if (searches > 0) parts.append(a, c.print("searched {s}", .{plural(c, searches, "time", "times")})) catch {};
    if (fetches > 0) parts.append(a, c.print("fetched {s}", .{plural(c, fetches, "page", "pages")})) catch {};
    if (other > 0) parts.append(a, c.print("called {s}", .{plural(c, other, "tool", "tools")})) catch {};
    if (failed > 0) parts.append(a, c.print("{d} failed", .{failed})) catch {};
    if (parts.items.len == 0) return "";
    const joined = std.mem.join(a, " · ", parts.items) catch return "";
    if (joined.len > 0) joined[0] = std.ascii.toUpper(joined[0]);
    return joined;
}

/// The desktop theme's own marks, which nanoui's theme does not carry: the
/// agent's violet and the working directory's blue.
fn agentTone(c: *ui.Context) ui.Color {
    return ui.Color.hex(if (c.theme.dark) 0xbd80e4 else 0x7a4ea3);
}

fn cwdTone(c: *ui.Context) ui.Color {
    return ui.Color.hex(if (c.theme.dark) 0x8a9bb0 else 0x3b6fb0);
}

/// The desktop's quiet text and its warning, between muted and border.
fn faintTone(c: *ui.Context) ui.Color {
    return c.theme.muted.alpha(0.62);
}

fn warningTone(c: *ui.Context) ui.Color {
    return ui.Color.hex(if (c.theme.dark) 0xd9a441 else 0x9a6e1b);
}

fn avatar(c: *ui.Context, icon: []const u8, color: ui.Color) void {
    const a = ui.div(c).row().size(20, 20).roundedFull().bg(color.alpha(0.16)).center();
    defer a.end();
    ui.icon(c, icon, .{ .size = 10, .color = color });
}

fn toolIcon(kind: []const u8) []const u8 {
    const table = .{
        .{ "read", "doc.text" },    .{ "edit", "pencil" },            .{ "delete", "trash" },
        .{ "move", "arrow.right" }, .{ "search", "magnifyingglass" }, .{ "execute", "terminal" },
        .{ "think", "brain" },      .{ "fetch", "globe" },
    };
    inline for (table) |e| if (std.mem.eql(u8, kind, e[0])) return e[1];
    return "wrench.and.screwdriver";
}

fn plan(c: *ui.Context, entries: []const Item.PlanEntry) void {
    const box = ui.div(c).column().wFull().p(10).gap(6).bg(c.theme.background).rounded(8).border(c.theme.border);
    defer box.end();
    ui.text(c, "Plan", .{ .size = 11.5, .weight = .semibold, .color = c.theme.muted });
    for (entries) |e| {
        const r = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer r.end();
        const done = std.mem.eql(u8, e.status.items, "completed");
        const doing = std.mem.eql(u8, e.status.items, "in_progress");
        ui.icon(c, if (done) "checkmark.circle.fill" else if (doing) "circle.dotted" else "circle", .{
            .size = 11,
            .color = if (done) c.theme.success else if (doing) c.theme.accent else faintTone(c),
        });
        ui.text(c, e.text.items, .{ .size = 13, .color = if (done) c.theme.muted else c.theme.text, .wrap = true });
    }
}

/// An agent's text, parsed by the desktop's Markdown and drawn with the
/// phone's theme.
fn markdown(c: *ui.Context, src: []const u8) void {
    if (std.mem.trim(u8, src, " \n\t").len == 0) return;
    const blocks = md.parse(c.alloc(), src, .{
        .code = c.theme.text,
        .code_bg = c.theme.surface_hover,
        .link = c.theme.accent,
        .muted = c.theme.muted,
    });
    const col = ui.div(c).column().wFull().gap(8);
    defer col.end();
    for (blocks) |b| mdBlock(c, b);
}

fn mdBlock(c: *ui.Context, b: md.Block) void {
    switch (b) {
        .paragraph => |in| ui.richText(c, in.text, in.spans, .{ .size = 13.5, .wrap = true, .leading = 1.45, .color = c.theme.text }),
        .heading => |h| {
            const size: f32 = switch (h.level) {
                1 => 17,
                2 => 15.5,
                3 => 14.5,
                else => 13.5,
            };
            ui.richText(c, h.text.text, h.text.spans, .{
                .size = size,
                .weight = if (h.level <= 2) .bold else .semibold,
                .wrap = true,
                .leading = 1.3,
                .color = c.theme.text,
            });
        },
        .item => |it| {
            const r = ui.div(c).row().wFull().gap(8).pl(@as(f32, @floatFromInt(it.depth)) * 16);
            defer r.end();
            const m = ui.div(c).row().minW(20).itemsCenter();
            defer m.end();
            if (it.task) |done| {
                ui.icon(c, if (done) "checkmark.circle.fill" else "circle", .{ .size = 12, .color = if (done) c.theme.success else c.theme.muted });
            } else {
                ui.text(c, it.marker, .{ .size = 13, .color = c.theme.muted });
            }
            const box = ui.div(c).column().grow();
            defer box.end();
            ui.richText(c, it.text.text, it.text.spans, .{ .size = 13.5, .wrap = true, .leading = 1.45, .color = if (it.task == true) c.theme.muted else c.theme.text });
        },
        .quote => |in| {
            const r = ui.div(c).row().wFull().gap(10);
            defer r.end();
            _ = c.leaf(.{ .width = .{ .px = 3 }, .height = .fill, .radius = 1.5, .background = c.theme.accent.alpha(0.45) }, .none, null);
            const box = ui.div(c).column().grow();
            defer box.end();
            ui.richText(c, in.text, in.spans, .{ .size = 13.5, .wrap = true, .leading = 1.45, .color = c.theme.muted, .italic = true });
        },
        .rule => ui.divider(c),
        .code => |code| codeBlock(c, code.lang, code.text),
        .table => |t| {
            const box = ui.div(c).column().wFull().p(1).rounded(8).border(c.theme.border).clip();
            defer box.end();
            mdTableRow(c, t.header, true, false);
            for (t.rows, 0..) |r, i| mdTableRow(c, r, false, i % 2 == 1);
        },
    }
}

fn mdTableRow(c: *ui.Context, cells: []const md.Inline, head: bool, zebra: bool) void {
    var r = ui.div(c).row().wFull();
    if (head) r = r.bg(c.theme.surface_hover) else if (zebra) r = r.bg(c.theme.surface);
    defer r.end();
    for (cells) |cell| {
        const d = ui.div(c).column().grow().px(8).py(5);
        defer d.end();
        ui.richText(c, cell.text, cell.spans, .{
            .size = 12.5,
            .wrap = true,
            .leading = 1.35,
            .weight = if (head) .semibold else .regular,
            .color = c.theme.text,
        });
    }
}

fn syntax(c: *ui.Context) highlight.Palette {
    return .{
        .keyword = c.theme.accent,
        .string = c.theme.success,
        .number = c.theme.danger,
        .comment = c.theme.muted,
        .type = c.theme.accent_hover,
        .call = c.theme.text,
    };
}

fn codeBlock(c: *ui.Context, lang: []const u8, src: []const u8) void {
    const box = ui.div(c).column().wFull().p(1).bg(c.theme.surface_hover).rounded(8).border(c.theme.border).clip();
    defer box.end();
    {
        const h = ui.div(c).row().wFull().px(10).py(4).gap(6).itemsCenter();
        defer h.end();
        ui.text(c, if (lang.len > 0) lang else "code", .{ .size = 11, .weight = .medium, .color = c.theme.muted });
        ui.spacer(c);
        if (ui.button(c, "Copy", .{ .variant = .ghost, .size = 11, .icon = "doc.on.doc" }).clicked) c.clipboard.write(c.clipboard.ctx, src);
    }
    const lines = ui.div(c).column().wFull().px(10).py(8).gap(0);
    defer lines.end();
    var in_block = false;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |l| {
        const spans = highlight.line(c.alloc(), l, lang, syntax(c), &in_block);
        ui.richText(c, if (l.len == 0) " " else l, spans, .{ .size = 11.5, .mono = true, .wrap = true, .leading = 1.35, .color = c.theme.text });
    }
}

/// A command's output line: the relay sends each colored span as an SGR
/// escape, as a terminal would have, so the colors are drawn as the
/// desktop draws them.
fn ansiLine(c: *ui.Context, line: []const u8, style: ui.TextStyle) void {
    if (std.mem.indexOfScalar(u8, line, 0x1b) == null) {
        ui.text(c, if (line.len == 0) " " else line, style);
        return;
    }
    const a = c.alloc();
    var text: std.ArrayList(u8) = .empty;
    var spans: std.ArrayList(ui.Span) = .empty;
    var fg: ?ui.Color = null;
    var bg: ?ui.Color = null;
    var bold = false;
    var italic = false;
    var underline = false;
    var strike = false;
    var run: usize = 0;
    var i: usize = 0;
    while (i < line.len) {
        if (line[i] != 0x1b or i + 1 >= line.len or line[i + 1] != '[') {
            text.append(a, line[i]) catch return;
            i += 1;
            continue;
        }
        const close = std.mem.indexOfScalarPos(u8, line, i + 2, 'm') orelse {
            i += 1;
            continue;
        };
        if (text.items.len > run and (fg != null or bg != null or bold or italic or underline or strike)) {
            spans.append(a, .{
                .start = @intCast(run),
                .end = @intCast(text.items.len),
                .color = fg,
                .background = bg,
                .weight = if (bold) .bold else null,
                .italic = italic,
                .underline = underline,
                .strike = strike,
            }) catch {};
        }
        var params: [16]u16 = undefined;
        var nparams: usize = 0;
        var q = i + 2;
        while (q < close and nparams < params.len) {
            var v: u16 = 0;
            var any = false;
            while (q < close and line[q] != ';') : (q += 1) {
                if (line[q] < '0' or line[q] > '9') continue;
                any = true;
                v = v *| 10 +| line[q] - '0';
            }
            params[nparams] = if (any) v else 0;
            nparams += 1;
            if (q < close and line[q] == ';') q += 1;
        }
        if (nparams == 0) {
            params[0] = 0;
            nparams = 1;
        }
        var k: usize = 0;
        while (k < nparams) : (k += 1) {
            const code = params[k];
            switch (code) {
                0 => {
                    fg = null;
                    bg = null;
                    bold = false;
                    italic = false;
                    underline = false;
                    strike = false;
                },
                1 => bold = true,
                3 => italic = true,
                4 => underline = true,
                9 => strike = true,
                22 => bold = false,
                23 => italic = false,
                24 => underline = false,
                29 => strike = false,
                39 => fg = null,
                49 => bg = null,
                30...37 => fg = ansi16(code - 30),
                90...97 => fg = ansi16(code - 90 + 8),
                40...47 => bg = ansi16(code - 40),
                100...107 => bg = ansi16(code - 100 + 8),
                38, 48 => {
                    var col: ?ui.Color = null;
                    if (k + 4 < nparams and params[k + 1] == 2) {
                        col = rgb(params[k + 2], params[k + 3], params[k + 4]);
                        k += 4;
                    } else if (k + 2 < nparams and params[k + 1] == 5) {
                        col = ansi256(params[k + 2]);
                        k += 2;
                    }
                    if (col) |col_| {
                        if (code == 38) fg = col_ else bg = col_;
                    }
                },
                else => {},
            }
        }
        run = text.items.len;
        i = close + 1;
    }
    if (text.items.len > run and (fg != null or bg != null or bold or italic or underline or strike)) {
        spans.append(a, .{
            .start = @intCast(run),
            .end = @intCast(text.items.len),
            .color = fg,
            .background = bg,
            .weight = if (bold) .bold else null,
            .italic = italic,
            .underline = underline,
            .strike = strike,
        }) catch {};
    }
    if (text.items.len == 0) {
        ui.text(c, " ", style);
    } else if (spans.items.len == 0) {
        ui.text(c, text.items, style);
    } else {
        ui.richText(c, text.items, spans.items, style);
    }
}

fn rgb(r: u16, g: u16, b: u16) ui.Color {
    return .{
        .r = @as(f32, @floatFromInt(@min(r, 255))) / 255,
        .g = @as(f32, @floatFromInt(@min(g, 255))) / 255,
        .b = @as(f32, @floatFromInt(@min(b, 255))) / 255,
    };
}

/// The sixteen colors a terminal starts with.
fn ansi16(n: u16) ui.Color {
    const hexes = [16]u24{
        0x000000, 0xcd3131, 0x0dbc79, 0xe5e510,
        0x2472c8, 0xbc3fbc, 0x11a8cd, 0xe5e5e5,
        0x666666, 0xf14c4c, 0x23d18b, 0xf5f543,
        0x3b8eea, 0xd670d6, 0x29b8db, 0xe5e5e5,
    };
    return ui.Color.hex(hexes[@min(n, 15)]);
}

/// The 256-color palette: the sixteen, a 6x6x6 cube, then grays.
fn ansi256(n: u16) ui.Color {
    const v = @min(n, 255);
    if (v < 16) return ansi16(v);
    if (v < 232) {
        const i = v - 16;
        const step = [6]u16{ 0, 95, 135, 175, 215, 255 };
        return rgb(step[(i / 36) % 6], step[(i / 6) % 6], step[i % 6]);
    }
    const g: u16 = 8 + (v - 232) * 10;
    return rgb(g, g, g);
}

/// A duration, in the frame's memory.
fn duration(c: *ui.Context, seconds: f64) []const u8 {
    if (seconds < 1) return c.print("{d:.0}ms", .{seconds * 1000});
    if (seconds < 60) return c.print("{d:.1}s", .{seconds});
    const s: u64 = @intFromFloat(seconds);
    return c.print("{d}m {d:0>2}s", .{ s / 60, s % 60 });
}

const spinner = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

fn spin(c: *ui.Context) []const u8 {
    c.frameIn(1.0 / 12.0);
    const i: usize = @intFromFloat(@mod(c.time * 12, spinner.len));
    return spinner[i];
}

/// A pulsing dot for connection status indicators.
fn pulse(c: *ui.Context) []const u8 {
    c.frameIn(1.0 / 2.0);
    const phase = @mod(c.time * 2, 1.0);
    return if (phase < 0.5) "●" else "○";
}

/// More text on the item a turn's last step grew: only one that grows
/// the same way has a place for it, and only where the phone's copy ends.
fn appendText(it: *Item, was_len: usize, more: []const u8, gpa: std.mem.Allocator) bool {
    const text: *std.ArrayList(u8) = switch (it.*) {
        .text => |*l| l,
        .thought => |*l| l,
        .note => |*l| l,
        .tool => |*tool| &tool.detail,
        else => return false,
    };
    if (text.items.len != was_len) return false;
    text.appendSlice(gpa, more) catch return false;
    return true;
}

/// A copy of `s` in an ArrayList that frees it again: the feed's strings
/// are all owned this way, so an update can replace them whole.
fn owned(gpa: std.mem.Allocator, s: []const u8) std.ArrayList(u8) {
    const copy = gpa.dupe(u8, s) catch return .empty;
    return std.ArrayList(u8).fromOwnedSlice(copy);
}

/// A string owned by `gpa`, replacing what `dst` held; `""` when the
/// allocator says no (drawing what is there beats failing).
fn setOwned(gpa: std.mem.Allocator, s: []const u8) []u8 {
    return gpa.dupe(u8, s) catch "";
}

fn setText(gpa: std.mem.Allocator, dst: *[]u8, text: []const u8) void {
    if (dst.len > 0) gpa.free(dst.*);
    dst.* = setOwned(gpa, text);
}

/// The agent's turn: what was asked, the steps it took, and its reply.
pub const Turn = struct {
    id: u64 = 0,
    session: u64 = 0,
    agent: std.ArrayList(u8) = .empty,
    prompt: std.ArrayList(u8) = .empty,
    /// What the turn shows instead of the prompt, when the ask had one.
    title: std.ArrayList(u8) = .empty,
    sent: bool = false,
    done: bool = false,
    started: f64 = 0,
    ended: f64 = 0,
    items: std.ArrayList(Item) = .empty,
    /// Which of its step groups are open, one bit each, as on the desktop.
    open_groups: u64 = 0,

    fn deinit(t: *Turn, gpa: std.mem.Allocator) void {
        t.agent.deinit(gpa);
        t.prompt.deinit(gpa);
        t.title.deinit(gpa);
        for (t.items.items) |*it| it.deinit(gpa);
        t.items.deinit(gpa);
    }
};

/// A command as the relay ran it: where, what, its output, and how it ended.
pub const Block = struct {
    id: u64 = 0,
    session: u64 = 0,
    is_agent: bool = false,
    command: std.ArrayList(u8) = .empty,
    cwd: std.ArrayList(u8) = .empty,
    branch: std.ArrayList(u8) = .empty,
    state: State = .running,
    exit: ?i32 = null,
    started: f64 = 0,
    ended: f64 = 0,
    output: std.ArrayList(u8) = .empty,
    /// Whether all of its output is shown.
    expanded: bool = false,

    const State = enum { running, done };

    fn deinit(b: *Block, gpa: std.mem.Allocator) void {
        b.command.deinit(gpa);
        b.cwd.deinit(gpa);
        b.branch.deinit(gpa);
        b.output.deinit(gpa);
    }

    pub fn failed(b: *const Block) bool {
        return b.state == .done and (b.exit orelse 0) != 0;
    }
};

/// What the feed holds, in the order it came: a turn, a command, a notice.
pub const Feed = union(enum) {
    turn: *Turn,
    block: *Block,
    line: Line,

    fn deinit(f: *Feed, gpa: std.mem.Allocator) void {
        switch (f.*) {
            .turn => |t| {
                t.deinit(gpa);
                gpa.destroy(t);
            },
            .block => |b| {
                b.deinit(gpa);
                gpa.destroy(b);
            },
            .line => |*l| l.deinit(gpa),
        }
    }

    fn session(f: Feed) u64 {
        return switch (f) {
            .turn => |t| t.session,
            .block => |b| b.session,
            .line => 0,
        };
    }
};

fn getTimestamp() i64 {
    if (@hasDecl(std.time, "timestamp")) return std.time.timestamp();
    return 0;
}

/// A model the tab's agent offers: what to send, what to show, and the
/// provider it belongs to (empty when the agent names none).
const ModelChoice = struct {
    value: []u8 = "",
    name: []u8 = "",
    provider: []u8 = "",

    fn deinit(m: *ModelChoice, gpa: std.mem.Allocator) void {
        if (m.value.len > 0) gpa.free(m.value);
        if (m.name.len > 0) gpa.free(m.name);
        if (m.provider.len > 0) gpa.free(m.provider);
    }
};

/// An agent the phone may switch to: its key, and what it is called.
const AgentChoice = struct {
    key: []u8 = "",
    name: []u8 = "",

    fn deinit(a: *AgentChoice, gpa: std.mem.Allocator) void {
        if (a.key.len > 0) gpa.free(a.key);
        if (a.name.len > 0) gpa.free(a.name);
    }
};

/// A tab's metadata: what the relay sent about it, for the switcher, and
/// the agent and model the composer is pointed at.
const TabInfo = struct {
    id: u64,
    title: []u8 = "",
    cwd: []u8 = "",
    mode: []u8 = "",
    agent: []u8 = "",
    agent_key: []u8 = "",
    agent_status: []u8 = "",
    model: []u8 = "",
    models: std.ArrayList(ModelChoice) = .empty,
    has_activity: bool = false,

    fn deinit(t: *TabInfo, gpa: std.mem.Allocator) void {
        if (t.title.len > 0) gpa.free(t.title);
        if (t.cwd.len > 0) gpa.free(t.cwd);
        if (t.mode.len > 0) gpa.free(t.mode);
        if (t.agent.len > 0) gpa.free(t.agent);
        if (t.agent_key.len > 0) gpa.free(t.agent_key);
        if (t.agent_status.len > 0) gpa.free(t.agent_status);
        if (t.model.len > 0) gpa.free(t.model);
        for (t.models.items) |*m| m.deinit(gpa);
        t.models.deinit(gpa);
    }
};

/// A saved connection: what was used before, for quick recall.
const SavedConnection = struct {
    name: []u8,
    host: []u8,
    port: u16,
    token: [32]u8,
    last_used: i64 = 0,

    fn deinit(s: *SavedConnection, gpa: std.mem.Allocator) void {
        gpa.free(s.name);
        gpa.free(s.host);
    }
};

/// Notification kind: info, success, warning, or error.
pub const NotificationKind = enum { info, success, warning, err };

/// A notification: a temporary message shown to the user.
const Notification = struct {
    kind: NotificationKind,
    message: []u8,
    timestamp: i64,
    /// Seconds until auto-dismiss (0 = manual dismiss only).
    duration: f32 = 3.0,

    fn deinit(n: *Notification, gpa: std.mem.Allocator) void {
        gpa.free(n.message);
    }
};

pub const Phone = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    window: ?*nanoui.Window = null,
    stream: ?std.Io.net.Stream = null,
    watch: ?fdwatch.Watch = null,
    in: std.ArrayList(u8) = .empty,
    /// What the relay sent, in order: turns, commands, and notices.
    feed: std.ArrayList(Feed) = .empty,
    /// The tab the composer sends to: the first one, or the one tapped.
    session: u64 = 0,
    tabs: usize = 0,
    /// The workstation's tabs, with their metadata: what the switcher shows.
    sessions: std.ArrayList(TabInfo) = .empty,
    /// The agents the workstation offers, as the relay last said.
    agents: std.ArrayList(AgentChoice) = .empty,
    /// How the tabs are shown: the desktop's bottom bar as pills, or its
    /// sidebar as a drawer. The drawer and the agent/model picker are open
    /// while their flag is set.
    layout: settings.Layout = .tabs,
    drawer_open: bool = false,
    picker_open: bool = false,
    /// Saved connections: recent ones for quick recall.
    saved_connections: std.ArrayList(SavedConnection) = .empty,
    screen: Screen = .feed,
    /// The connect screen's three fields, and what it says when they are
    /// not enough to try with.
    host_input: ui.TextBuffer = .{},
    port_input: ui.TextBuffer = .{},
    token_input: ui.TextBuffer = .{},
    connect_why: [160]u8 = @splat(0),
    connect_why_len: usize = 0,
    /// Whether an argument said so: an argument wins over the saved file,
    /// which is how a cable and `am start` still work.
    has_host: bool = false,
    has_port: bool = false,
    /// What the composer does with Return: run it here, or ask the agent.
    mode: usize = 0,
    input: ui.TextBuffer = .{},
    /// Command history: what was sent, newest first, for up/down arrow recall.
    history: std.ArrayList([]u8) = .empty,
    history_index: usize = 0,
    pending: std.ArrayList(Pending) = .empty,
    /// What is running, so Stop is offered only when there is something to
    /// stop: a block's id as it is, a turn's with the top bit set.
    running: std.ArrayList(u64) = .empty,
    /// A counter for the pulse animation when something is running.
    pulse_counter: u32 = 0,
    /// Gesture tracking: swipe to switch tabs, pull to refresh.
    swipe_start_x: f32 = 0,
    swipe_start_y: f32 = 0,
    swipe_tracking: bool = false,
    pull_distance: f32 = 0,
    pull_refreshing: bool = false,
    feed_loading: bool = false,
    /// Notifications: temporary messages shown to the user.
    notifications: std.ArrayList(Notification) = .empty,
    status: Status = .connecting,
    /// Why it is not connected, when it is not.
    why: [200]u8 = @splat(0),
    why_len: usize = 0,
    /// "host:port", made once.
    where: [80]u8 = @splat(0),
    where_len: usize = 0,
    token: [32]u8 = @splat('0'),
    has_token: bool = false,
    port: u16 = 4789,
    host: [64]u8 = @splat(0),
    host_len: usize = 0,
    /// Theme preference: system, light, or dark.
    theme_pref: settings.ThemePreference = .system,
    arena_state: std.heap.ArenaAllocator,

    fn create(init: std.process.Init, args: []const []const u8) !*Phone {
        const p = try init.gpa.create(Phone);
        p.* = .{ .gpa = init.gpa, .io = init.io, .arena_state = .init(init.gpa) };
        @memcpy(p.host[0..9], "127.0.0.1");
        p.host_len = 9;
        // What was typed on the phone last time, then the arguments over
        // it: the file is what a release build has, the arguments what a
        // debug build and a cable can add.
        if (settings.load(init.io, init.gpa)) |saved| {
            defer saved.deinit(init.gpa);
            if (saved.host.len <= p.host.len) {
                @memcpy(p.host[0..saved.host.len], saved.host);
                p.host_len = saved.host.len;
            }
            p.port = saved.port;
            p.theme_pref = saved.theme;
            p.layout = saved.layout;
            if (saved.usable()) {
                @memcpy(&p.token, saved.token);
                p.has_token = true;
            }
        }
        var i: usize = 1;
        while (i + 1 < args.len) : (i += 1) {
            const flag = args[i];
            const value = args[i + 1];
            if (std.mem.eql(u8, flag, "--host")) {
                if (value.len > p.host.len) continue;
                @memcpy(p.host[0..value.len], value);
                p.host_len = value.len;
                p.has_host = true;
            } else if (std.mem.eql(u8, flag, "--port")) {
                p.port = std.fmt.parseInt(u16, value, 10) catch p.port;
                p.has_port = true;
            } else if (std.mem.eql(u8, flag, "--token")) {
                if (value.len == 32) {
                    @memcpy(&p.token, value[0..32]);
                    p.has_token = true;
                }
            } else continue;
            i += 1;
        }
        if (!p.has_token) if (init.environ_map.get("NANOTERM_RELAY_TOKEN")) |t| if (t.len == 32) {
            @memcpy(&p.token, t[0..32]);
            p.has_token = true;
        };
        const printed: []u8 = std.fmt.bufPrint(&p.where, "{s}:{d}", .{ p.host[0..p.host_len], p.port }) catch p.where[0..0];
        p.where_len = printed.len;
        // No token anywhere: the phone asks, once, and remembers.
        p.screen = if (p.has_token) .feed else .connect;
        p.fillConnect();
        return p;
    }

    pub fn destroy(p: *Phone) void {
        p.close();
        for (p.feed.items) |*f| f.deinit(p.gpa);
        p.feed.deinit(p.gpa);
        for (p.sessions.items) |*s| s.deinit(p.gpa);
        p.sessions.deinit(p.gpa);
        for (p.agents.items) |*a| a.deinit(p.gpa);
        p.agents.deinit(p.gpa);
        for (p.saved_connections.items) |*s| s.deinit(p.gpa);
        p.saved_connections.deinit(p.gpa);
        for (p.pending.items) |*q| q.deinit(p.gpa);
        p.pending.deinit(p.gpa);
        for (p.history.items) |h| p.gpa.free(h);
        p.history.deinit(p.gpa);
        for (p.notifications.items) |*n| n.deinit(p.gpa);
        p.notifications.deinit(p.gpa);
        p.running.deinit(p.gpa);
        p.input.deinit();
        p.host_input.deinit();
        p.port_input.deinit();
        p.token_input.deinit();
        p.in.deinit(p.gpa);
        p.arena_state.deinit();
        const gpa = p.gpa;
        gpa.destroy(p);
    }

    pub fn close(p: *Phone) void {
        if (p.watch) |w| w.cancel();
        p.watch = null;
        if (p.stream) |s| s.close(p.io);
        p.stream = null;
    }

    /// The relay, and hello to it: the token, then whatever it holds.
    pub fn open(p: *Phone) void {
        p.close();
        if (!p.has_token) {
            p.fail("no token: --token, or NANOTERM_RELAY_TOKEN");
            return;
        }
        const host = p.host[0..p.host_len];
        var addr = std.Io.net.IpAddress.parse(host, p.port) catch |err| {
            p.fail(@errorName(err));
            return;
        };
        addr.setPort(p.port);
        // A tunnel to a workstation is a TCP connection like any other.
        p.stream = std.Io.net.IpAddress.connect(&addr, p.io, .{ .mode = .stream }) catch |err| {
            p.fail(@errorName(err));
            return;
        };
        const fd = p.stream.?.socket.handle;
        p.watch = fdwatch.readable(fd, p, onReadable) catch |err| {
            p.fail(@errorName(err));
            return;
        };
        p.status = .live;
        var buf: [96]u8 = undefined;
        const hello = std.fmt.bufPrint(&buf, "{{\"op\":\"hello\",\"token\":\"{s}\"}}\n", .{p.token}) catch return;
        p.write(hello);
        p.push("connected to {s}", .{p.where[0..p.where_len]});
    }

    pub fn fail(p: *Phone, why: []const u8) void {
        note("down: {s}", .{why});
        p.status = .down;
        p.close();
        p.why_len = @min(why.len, p.why.len);
        @memcpy(p.why[0..p.why_len], why[0..p.why_len]);
        p.push("not connected: {s}", .{why});
    }

    pub fn onReadable(ctx: ?*anyopaque) callconv(.c) void {
        const p: *Phone = @ptrCast(@alignCast(ctx.?));
        p.read();
    }

    /// Everything the socket holds now, then one frame: reading a chunk
    /// at a time drew a frame of a turn the next chunk would replace, and
    /// a phone left behind a relay still streaming fell further behind
    /// the longer the answer ran.
    pub fn read(p: *Phone) void {
        const fd = if (p.stream) |s| s.socket.handle else return;
        var buf: [16 * 1024]u8 = undefined;
        var drained: usize = 0;
        while (drained < max_drain) {
            const n = std.posix.read(fd, &buf) catch |err| {
                if (err == error.WouldBlock) break;
                p.fail(@errorName(err));
                return;
            };
            if (n == 0) {
                p.fail("the relay closed the connection");
                return;
            }
            p.in.appendSlice(p.gpa, buf[0..n]) catch break;
            drained += n;
            // A short read is the end of what had come.
            if (n < buf.len) break;
        }
        while (std.mem.indexOfScalar(u8, p.in.items, '\n')) |at| {
            const line = p.in.items[0..at];
            p.event(line);
            const left = p.in.items.len - at - 1;
            std.mem.copyForwards(u8, p.in.items[0..left], p.in.items[at + 1 ..]);
            p.in.items.len = left;
        }
        if (p.in.items.len > max_waiting) p.in.clearRetainingCapacity();
        p.draw();
    }

    /// One event, rendered as the thing it is, not as JSON.
    pub fn event(p: *Phone, line: []const u8) void {
        const Option = struct { id: []const u8 = "", name: []const u8 = "" };
        const PlanItem = struct { text: []const u8 = "", status: []const u8 = "" };
        const WireModel = struct {
            value: []const u8 = "",
            name: []const u8 = "",
            provider: []const u8 = "",
        };
        const WireAgent = struct {
            key: []const u8 = "",
            name: []const u8 = "",
        };
        const WireItem = struct {
            kind: []const u8 = "",
            text: []const u8 = "",
            id: []const u8 = "",
            /// A tool's kind: "read", "edit", "execute", …
            tool: []const u8 = "",
            title: []const u8 = "",
            status: []const u8 = "",
            detail: []const u8 = "",
            block: ?u64 = null,
            entries: []const PlanItem = &.{},
            rpc: []const u8 = "",
            options: []const Option = &.{},
            chosen: ?usize = null,
        };
        const Event = struct {
            seq: u64 = 0,
            kind: []const u8 = "",
            id: u64 = 0,
            session: u64 = 0,
            title: ?[]const u8 = null,
            cwd: []const u8 = "",
            branch: []const u8 = "",
            source: []const u8 = "",
            command: []const u8 = "",
            state: []const u8 = "",
            exit: ?i32 = null,
            started: f64 = 0,
            ended: f64 = 0,
            output: []const u8 = "",
            mode: []const u8 = "",
            agent: []const u8 = "",
            agent_key: []const u8 = "",
            agent_status: []const u8 = "",
            model: []const u8 = "",
            models: []const WireModel = &.{},
            agents: []const WireAgent = &.{},
            sessions: []const u64 = &.{},
            message: []const u8 = "",
            prompt: []const u8 = "",
            sent: bool = false,
            done: bool = false,
            items: []const WireItem = &.{},
            /// The text a turn's last item grew by, instead of the whole
            /// turn: where it goes, how much it had, and what is new.
            append: ?struct {
                index: usize = 0,
                len: usize = 0,
                text: []const u8 = "",
            } = null,
        };
        const arena = p.arena_state.allocator();
        defer _ = p.arena_state.reset(.retain_capacity);
        const e = std.json.parseFromSliceLeaky(Event, arena, line, .{ .ignore_unknown_fields = true }) catch return;
        if (std.mem.eql(u8, e.kind, "welcome")) {
            p.tabs = e.sessions.len;
            if (p.session == 0 and e.sessions.len > 0) p.session = e.sessions[0];
            p.feed_loading = false;
            for (e.sessions) |id| {
                var found = false;
                for (p.sessions.items) |s| {
                    if (s.id == id) {
                        found = true;
                        break;
                    }
                }
                if (!found) p.sessions.append(p.gpa, .{ .id = id }) catch {};
            }
        } else if (std.mem.eql(u8, e.kind, "session")) {
            if (p.session == 0) p.session = e.id;
            if (e.cwd.len > 0) {
                const t = std.fmt.bufPrint(&p.where, "{s}:{d}", .{ p.host[0..p.host_len], p.port }) catch p.where[0..0];
                p.where_len = t.len;
            }
            var found = false;
            for (p.sessions.items) |*s| {
                if (s.id != e.id) continue;
                found = true;
                p.applySession(s, e);
                break;
            }
            // A tab that was never in a welcome is still one.
            if (!found) {
                var s: TabInfo = .{ .id = e.id };
                p.applySession(&s, e);
                p.sessions.append(p.gpa, s) catch s.deinit(p.gpa);
            }
            if (e.agents.len > 0) p.setAgents(e.agents);
        } else if (std.mem.eql(u8, e.kind, "gone")) {
            if (p.session == e.id) {
                p.session = 0;
                p.drawer_open = false;
                p.picker_open = false;
            }
            for (p.sessions.items, 0..) |s, i| {
                if (s.id == e.id) {
                    _ = p.sessions.orderedRemove(i);
                    var copy = s;
                    copy.deinit(p.gpa);
                    break;
                }
            }
        } else if (std.mem.eql(u8, e.kind, "block")) {
            p.syncBlock(e);
        } else if (std.mem.eql(u8, e.kind, "turn")) {
            p.syncTurn(e);
        } else if (std.mem.eql(u8, e.kind, "ack")) {
            // What was sent was taken: nothing to show.
        } else if (std.mem.eql(u8, e.kind, "error")) {
            p.fail(e.message);
        }
    }

    /// The tab as the relay now sees it: its title and folder, and the
    /// agent and model its composer would use.
    fn applySession(p: *Phone, s: *TabInfo, e: anytype) void {
        const title_text = if (e.title) |t| if (t.len > 0) t else "~" else "~";
        setText(p.gpa, &s.title, title_text);
        setText(p.gpa, &s.cwd, e.cwd);
        setText(p.gpa, &s.mode, e.mode);
        setText(p.gpa, &s.agent, e.agent);
        setText(p.gpa, &s.agent_key, e.agent_key);
        setText(p.gpa, &s.agent_status, e.agent_status);
        setText(p.gpa, &s.model, e.model);
        for (s.models.items) |*m| m.deinit(p.gpa);
        s.models.clearRetainingCapacity();
        for (e.models) |m| {
            const value = setOwned(p.gpa, m.value);
            const name = setOwned(p.gpa, if (m.name.len > 0) m.name else m.value);
            const provider = setOwned(p.gpa, m.provider);
            s.models.append(p.gpa, .{ .value = value, .name = name, .provider = provider }) catch {
                if (value.len > 0) p.gpa.free(value);
                if (name.len > 0) p.gpa.free(name);
                if (provider.len > 0) p.gpa.free(provider);
            };
        }
    }

    /// The agents the tab may switch to, when the relay's list changed.
    fn setAgents(p: *Phone, list: anytype) void {
        if (p.agents.items.len == list.len) {
            var same = true;
            for (p.agents.items, list) |have, now| {
                if (!std.mem.eql(u8, have.key, now.key) or !std.mem.eql(u8, have.name, now.name)) {
                    same = false;
                    break;
                }
            }
            if (same) return;
        }
        for (p.agents.items) |*a| a.deinit(p.gpa);
        p.agents.clearRetainingCapacity();
        for (list) |a| {
            const key = setOwned(p.gpa, a.key);
            const name = setOwned(p.gpa, a.name);
            p.agents.append(p.gpa, .{ .key = key, .name = name }) catch {
                if (key.len > 0) p.gpa.free(key);
                if (name.len > 0) p.gpa.free(name);
            };
        }
    }

    /// The tab the composer is pointed at: its agent and model.
    pub fn currentTab(p: *Phone) ?*TabInfo {
        for (p.sessions.items) |*s| {
            if (s.id == p.session) return s;
        }
        return null;
    }

    /// The turn with this id in this tab, or a new one at the feed's end.
    fn turnFor(p: *Phone, session: u64, id: u64) ?*Turn {
        for (p.feed.items) |*f| switch (f.*) {
            .turn => |t| if (t.session == session and t.id == id) return t,
            else => {},
        };
        if (p.feed.items.len == keep_lines) {
            p.feed.items[0].deinit(p.gpa);
            std.mem.copyForwards(Feed, p.feed.items[0 .. keep_lines - 1], p.feed.items[1..keep_lines]);
            p.feed.items.len -= 1;
        }
        const t = p.gpa.create(Turn) catch return null;
        t.* = .{ .id = id, .session = session };
        p.feed.append(p.gpa, .{ .turn = t }) catch {
            p.gpa.destroy(t);
            return null;
        };
        return t;
    }

    /// The command block with this id in this tab, or a new one.
    fn blockFor(p: *Phone, session: u64, id: u64) ?*Block {
        for (p.feed.items) |*f| switch (f.*) {
            .block => |b| if (b.session == session and b.id == id) return b,
            else => {},
        };
        if (p.feed.items.len == keep_lines) {
            p.feed.items[0].deinit(p.gpa);
            std.mem.copyForwards(Feed, p.feed.items[0 .. keep_lines - 1], p.feed.items[1..keep_lines]);
            p.feed.items.len -= 1;
        }
        const b = p.gpa.create(Block) catch return null;
        b.* = .{ .id = id, .session = session };
        p.feed.append(p.gpa, .{ .block = b }) catch {
            p.gpa.destroy(b);
            return null;
        };
        return b;
    }

    /// A turn as the relay now sees it: the whole snapshot replaces what
    /// was there, so a text item that grew while streaming is not added
    /// twice.
    fn syncTurn(p: *Phone, e: anytype) void {
        const t = p.turnFor(e.session, e.id) orelse return;
        if (t.agent.items.len > 0 or e.agent.len > 0) {
            t.agent.deinit(p.gpa);
            t.agent = owned(p.gpa, e.agent);
        }
        if (t.prompt.items.len > 0 or e.prompt.len > 0) {
            t.prompt.deinit(p.gpa);
            t.prompt = owned(p.gpa, e.prompt);
        }
        const title = e.title orelse "";
        if (t.title.items.len > 0 or title.len > 0) {
            t.title.deinit(p.gpa);
            t.title = owned(p.gpa, title);
        }
        t.sent = e.sent;
        t.done = e.done;
        t.started = e.started;
        t.ended = e.ended;
        // A streaming turn's next text alone, on the item it grew: the
        // whole turn again for every few words is what kept a phone
        // behind a long answer.
        if (e.append) |a| {
            if (a.index < t.items.items.len and appendText(&t.items.items[a.index], a.len, a.text, p.gpa)) {
                p.mark(e.id | turn_bit, !e.done);
                return;
            }
            // Where the relay put it is not where the phone's copy ends:
            // ask for the feed whole again.
            p.write("{\"op\":\"list\"}\n");
            return;
        }
        for (t.items.items) |*it| it.deinit(p.gpa);
        t.items.clearRetainingCapacity();
        for (e.items) |it| p.addItem(t, it);
        p.mark(e.id | turn_bit, !e.done);
        for (e.items) |it| {
            if (!std.mem.eql(u8, it.kind, "permission")) continue;
            if (it.chosen == null) p.ask(it) else p.answered(it.rpc);
        }
    }

    /// A command block as the relay now sees it.
    fn syncBlock(p: *Phone, e: anytype) void {
        const b = p.blockFor(e.session, e.id) orelse return;
        b.is_agent = std.mem.eql(u8, e.source, "agent");
        b.command.deinit(p.gpa);
        b.command = owned(p.gpa, e.command);
        b.cwd.deinit(p.gpa);
        b.cwd = owned(p.gpa, e.cwd);
        b.branch.deinit(p.gpa);
        b.branch = owned(p.gpa, e.branch);
        b.state = if (std.mem.eql(u8, e.state, "done")) .done else .running;
        b.exit = e.exit;
        b.started = e.started;
        b.ended = e.ended;
        b.output.deinit(p.gpa);
        b.output = owned(p.gpa, e.output);
        p.mark(e.id, b.state == .running);
    }

    /// One step of a turn, kept the way the phone draws it.
    fn addItem(p: *Phone, t: *Turn, it: anytype) void {
        if (std.mem.eql(u8, it.kind, "text")) {
            if (it.text.len > 0) t.items.append(p.gpa, .{ .text = owned(p.gpa, it.text) }) catch {};
        } else if (std.mem.eql(u8, it.kind, "thought")) {
            if (it.text.len > 0) t.items.append(p.gpa, .{ .thought = owned(p.gpa, it.text) }) catch {};
        } else if (std.mem.eql(u8, it.kind, "note")) {
            if (it.text.len > 0) t.items.append(p.gpa, .{ .note = owned(p.gpa, it.text) }) catch {};
        } else if (std.mem.eql(u8, it.kind, "visual")) {
            t.items.append(p.gpa, .{ .visual = owned(p.gpa, it.title) }) catch {};
        } else if (std.mem.eql(u8, it.kind, "command")) {
            const block = it.block orelse return;
            t.items.append(p.gpa, .{ .command = block }) catch {};
        } else if (std.mem.eql(u8, it.kind, "tool")) {
            var tl: Item.Tool = .{
                .id = owned(p.gpa, it.id),
                .kind = owned(p.gpa, it.tool),
                .title = owned(p.gpa, it.title),
                .detail = owned(p.gpa, it.detail),
                .status = statusOf(it.status),
                .block = it.block,
            };
            t.items.append(p.gpa, .{ .tool = tl }) catch tl.deinit(p.gpa);
        } else if (std.mem.eql(u8, it.kind, "plan")) {
            var entries: std.ArrayList(Item.PlanEntry) = .empty;
            for (it.entries) |x| {
                entries.append(p.gpa, .{
                    .text = owned(p.gpa, x.text),
                    .status = owned(p.gpa, x.status),
                }) catch {};
            }
            t.items.append(p.gpa, .{ .plan = entries }) catch {
                for (entries.items) |*x| x.deinit(p.gpa);
                entries.deinit(p.gpa);
            };
        } else if (std.mem.eql(u8, it.kind, "permission")) {
            var options: std.ArrayList(Item.Option) = .empty;
            for (it.options) |o| {
                options.append(p.gpa, .{
                    .id = owned(p.gpa, o.id),
                    .name = owned(p.gpa, o.name),
                }) catch {};
            }
            var perm: Item.Permission = .{
                .rpc = owned(p.gpa, it.rpc),
                .title = owned(p.gpa, it.title),
                .options = options,
                .chosen = it.chosen,
            };
            t.items.append(p.gpa, .{ .permission = perm }) catch perm.deinit(p.gpa);
        }
    }

    /// A block (or a turn) started, or finished: what Stop has to stop.
    pub fn mark(p: *Phone, key: u64, on: bool) void {
        for (p.running.items, 0..) |k, i| {
            if (k != key) continue;
            if (!on) _ = p.running.orderedRemove(i);
            return;
        }
        if (!on) return;
        // A phone shows a handful; more than that is not a feed.
        if (p.running.items.len == 8) _ = p.running.orderedRemove(0);
        p.running.append(p.gpa, key) catch {};
    }

    /// A question waiting on this phone: a card, until it is answered.
    pub fn ask(p: *Phone, asked: anytype) void {
        for (p.pending.items) |q| if (std.mem.eql(u8, q.rpc, asked.rpc)) return;
        if (p.pending.items.len == max_pending) {
            var old = p.pending.orderedRemove(0);
            old.deinit(p.gpa);
        }
        var q: Pending = .{
            .rpc = p.gpa.dupe(u8, asked.rpc) catch return,
            .title = p.gpa.dupe(u8, if (asked.title.len > 0) asked.title else "the agent asks") catch return,
            .perm_type = "",
            .detail = "",
            .chosen = null,
        };
        for (asked.options) |o| {
            const name = p.gpa.dupe(u8, o.name) catch break;
            q.options.append(p.gpa, name) catch {
                p.gpa.free(name);
                break;
            };
        }
        p.pending.append(p.gpa, q) catch {
            q.deinit(p.gpa);
            return;
        };
    }

    /// Answered here (or at the workstation): its card goes.
    pub fn answered(p: *Phone, rpc: []const u8) void {
        for (p.pending.items, 0..) |q, i| {
            if (std.mem.eql(u8, q.rpc, rpc)) {
                var gone = p.pending.orderedRemove(i);
                gone.deinit(p.gpa);
                return;
            }
        }
    }

    pub fn push(p: *Phone, comptime fmt: []const u8, args: anytype) void {
        p.pushLine(.notice, fmt, args);
    }

    /// A notice (or a failure) in the feed: the phone's own words, apart
    /// from what the workstation sent.
    pub fn pushLine(p: *Phone, kind: Line.Kind, comptime fmt: []const u8, args: anytype) void {
        var aw: std.Io.Writer.Allocating = .init(p.gpa);
        defer aw.deinit();
        aw.writer.print(fmt, args) catch return;
        const text = aw.written();
        const clipped = if (text.len > max_line) text[0..max_line] else text;
        note("{s}", .{clipped});
        const copy = p.gpa.dupe(u8, clipped) catch return;
        if (p.feed.items.len == keep_lines) {
            p.feed.items[0].deinit(p.gpa);
            std.mem.copyForwards(Feed, p.feed.items[0 .. keep_lines - 1], p.feed.items[1..keep_lines]);
            p.feed.items.len -= 1;
        }
        p.feed.append(p.gpa, .{ .line = .{ .kind = kind, .text = copy } }) catch {
            p.gpa.free(copy);
            return;
        };
    }

    /// The feed and nothing else: a phone is not a history.
    pub fn clearFeed(p: *Phone) void {
        for (p.feed.items) |*f| f.deinit(p.gpa);
        p.feed.clearRetainingCapacity();
    }

    /// Show a notification: a temporary message in the UI.
    pub fn notify(p: *Phone, kind: NotificationKind, comptime fmt: []const u8, args: anytype) void {
        var aw: std.Io.Writer.Allocating = .init(p.gpa);
        defer aw.deinit();
        aw.writer.print(fmt, args) catch return;
        const text = aw.written();
        const copy = p.gpa.dupe(u8, text) catch return;
        const seconds: f32 = switch (kind) {
            .info => 3.0,
            .success => 2.5,
            .warning => 4.0,
            .err => 5.0,
        };
        p.notifications.append(p.gpa, .{
            .kind = kind,
            .message = copy,
            .timestamp = getTimestamp(),
            .duration = seconds,
        }) catch {
            p.gpa.free(copy);
            return;
        };
        // Keep only the last 5 notifications.
        while (p.notifications.items.len > 5) {
            p.notifications.items[0].deinit(p.gpa);
            std.mem.copyForwards(Notification, p.notifications.items[0..5], p.notifications.items[1..6]);
            p.notifications.items.len -= 1;
        }
        p.draw();
    }

    /// Dismiss a notification by index.
    pub fn dismissNotification(p: *Phone, index: usize) void {
        if (index >= p.notifications.items.len) return;
        p.notifications.items[index].deinit(p.gpa);
        _ = p.notifications.swapRemove(index);
        p.draw();
    }

    /// Clean up expired notifications.
    pub fn pruneNotifications(p: *Phone) void {
        const now = getTimestamp();
        var i: usize = 0;
        while (i < p.notifications.items.len) {
            const age: f32 = @floatFromInt(now - p.notifications.items[i].timestamp);
            if (age >= p.notifications.items[i].duration) {
                p.notifications.items[i].deinit(p.gpa);
                _ = p.notifications.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// A line to the relay, whole: a partial one would be read as JSON
    /// and refused.
    pub fn write(p: *Phone, bytes: []const u8) void {
        const s = p.stream orelse return;
        var wbuf: [512]u8 = undefined;
        var out = s.writer(p.io, &wbuf);
        out.interface.writeAll(bytes) catch |err| {
            p.fail(@errorName(err));
            return;
        };
        out.interface.flush() catch |err| {
            p.fail(@errorName(err));
            return;
        };
    }

    fn json(w: *std.Io.Writer, s: []const u8) void {
        std.json.Stringify.value(s, .{}, w) catch {};
    }

    /// A command or a question, as the relay reads it.
    pub fn opLine(w: *std.Io.Writer, op: []const u8, session: u64, text: []const u8) void {
        w.writeAll("{\"op\":") catch return;
        json(w, op);
        w.print(",\"session\":{d},\"text\":", .{session}) catch return;
        json(w, text);
        w.writeAll("}\n") catch return;
    }

    /// The tap on a permission's option: the relay answers the agent.
    pub fn answerLine(w: *std.Io.Writer, session: u64, rpc: []const u8, option: usize) void {
        w.print("{{\"op\":\"answer\",\"session\":{d},\"rpc\":", .{session}) catch return;
        json(w, rpc);
        w.print(",\"option\":{d}}}\n", .{option}) catch return;
    }

    /// Stop, as the relay reads it: whatever that tab is doing — the
    /// command in its shell, or the agent's turn — ends.
    pub fn interruptLine(w: *std.Io.Writer, session: u64) void {
        w.print("{{\"op\":\"interrupt\",\"session\":{d}}}\n", .{session}) catch return;
    }

    /// The agent picker's tap: the tab runs this agent from its next prompt.
    pub fn agentLine(w: *std.Io.Writer, session: u64, key: []const u8) void {
        w.print("{{\"op\":\"agent\",\"session\":{d},\"text\":", .{session}) catch return;
        json(w, key);
        w.writeAll("}\n") catch return;
    }

    /// The model picker's tap: the tab's agent uses this model.
    pub fn modelLine(w: *std.Io.Writer, session: u64, value: []const u8, provider: []const u8) void {
        w.print("{{\"op\":\"model\",\"session\":{d},\"text\":", .{session}) catch return;
        json(w, value);
        if (provider.len > 0) {
            w.writeAll(",\"provider\":") catch return;
            json(w, provider);
        }
        w.writeAll("}\n") catch return;
    }

    /// Asks the relay to open the tab's agent, so it says what models it
    /// offers; the session event that follows fills the picker.
    pub fn modelsLine(w: *std.Io.Writer, session: u64) void {
        w.print("{{\"op\":\"models\",\"session\":{d}}}\n", .{session}) catch return;
    }

    /// The picker opened: the tab's agent is asked what it offers.
    pub fn openPicker(p: *Phone) void {
        if (p.session == 0) {
            p.notify(.info, "No tab to change: is the relay up?", .{});
            return;
        }
        p.picker_open = true;
        var aw: std.Io.Writer.Allocating = .init(p.gpa);
        defer aw.deinit();
        modelsLine(&aw.writer, p.session);
        p.write(aw.written());
        p.draw();
    }

    /// The agent chosen in the picker: it applies from the next prompt.
    pub fn pickAgent(p: *Phone, key: []const u8) void {
        if (p.session == 0) return;
        var aw: std.Io.Writer.Allocating = .init(p.gpa);
        defer aw.deinit();
        agentLine(&aw.writer, p.session, key);
        // Its models are what the picker shows next.
        modelsLine(&aw.writer, p.session);
        p.write(aw.written());
        p.draw();
    }

    /// The model chosen in the picker: the tab's agent takes it.
    pub fn pickModel(p: *Phone, value: []const u8, provider: []const u8) void {
        if (p.session == 0) return;
        var aw: std.Io.Writer.Allocating = .init(p.gpa);
        defer aw.deinit();
        modelLine(&aw.writer, p.session, value, provider);
        p.write(aw.written());
        p.picker_open = false;
        p.notify(.success, "Model: {s}", .{value});
        p.draw();
    }

    /// The layout and theme, saved as the connect fields were.
    fn persist(p: *Phone) void {
        if (!p.has_token) return;
        _ = settings.save(p.io, p.gpa, p.host[0..p.host_len], p.port, &p.token, p.theme_pref, p.layout);
    }

    /// Tabs as pills, or the desktop's sidebar as a drawer.
    pub fn setLayout(p: *Phone, layout: settings.Layout) void {
        if (p.layout == layout) return;
        p.layout = layout;
        p.drawer_open = false;
        p.persist();
        p.draw();
    }

    /// The tap on Stop: the tab it is pointed at stops what it is doing.
    pub fn interrupt(p: *Phone) void {
        if (p.session == 0) {
            p.push("no tab to stop: is the workstation's relay up?", .{});
            return;
        }
        var aw: std.Io.Writer.Allocating = .init(p.gpa);
        defer aw.deinit();
        interruptLine(&aw.writer, p.session);
        p.push("stop sent to tab {d}", .{p.session});
        p.write(aw.written());
    }

    /// The connect screen's fields, from what the phone has now: a second
    /// visit starts where the first one ended.
    pub fn fillConnect(p: *Phone) void {
        p.host_input.set(p.host[0..p.host_len]);
        var buf: [8]u8 = undefined;
        p.port_input.set(std.fmt.bufPrint(&buf, "{d}", .{p.port}) catch "4789");
        p.token_input.set(if (p.has_token) &p.token else "");
        p.connect_why_len = 0;
    }

    /// A reason the fields are not enough, said where they are.
    pub fn connectFail(p: *Phone, why: []const u8) void {
        note("connect: {s}", .{why});
        p.connect_why_len = @min(why.len, p.connect_why.len);
        @memcpy(p.connect_why[0..p.connect_why_len], why[0..p.connect_why_len]);
        p.notify(.err, "Connection failed: {s}", .{why});
        p.draw();
    }

    /// The tap on Connect: what is in the fields, saved, then tried.
    pub fn connect(p: *Phone) void {
        const host = std.mem.trim(u8, p.host_input.text(), " \t\r\n");
        const port_text = std.mem.trim(u8, p.port_input.text(), " \t\r\n");
        const token = std.mem.trim(u8, p.token_input.text(), " \t\r\n");
        if (host.len == 0) return p.connectFail("a host: an address, or a name on the network");
        if (host.len > p.host.len) return p.connectFail("a host shorter than 64 characters");
        if (token.len != settings.token_len) return p.connectFail("the token, all 32 characters of it: nanoterm prints it");
        const port = std.fmt.parseInt(u16, port_text, 10) catch
            return p.connectFail("a port, as a number: 4789 unless the relay said otherwise");
        @memcpy(p.host[0..host.len], host);
        p.host_len = host.len;
        p.port = port;
        @memcpy(&p.token, token);
        p.has_token = true;
        const printed: []u8 = std.fmt.bufPrint(&p.where, "{s}:{d}", .{ p.host[0..p.host_len], p.port }) catch p.where[0..0];
        p.where_len = printed.len;
        // Saved before it is tried: a phone that cannot save still works
        // for this run, and one that can does not ask again.
        _ = settings.save(p.io, p.gpa, host, port, token, p.theme_pref, p.layout);
        // Save to recent connections history.
        p.saveConnection(host, port, token);
        p.connect_why_len = 0;
        p.status = .connecting;
        p.open();
        if (p.status == .live) {
            p.screen = .feed;
            // Note: haptic feedback will be added via the leaf API in the view when drawing
            p.notify(.success, "Connected to {s}", .{p.where[0..p.where_len]});
        } else if (p.status == .down) {
            // Connection failed: show the error on the connect screen.
            p.screen = .connect;
            p.connectFail(p.why[0..p.why_len]);
        }
    }

    /// Save a connection to the recent history, keeping last 5.
    fn saveConnection(p: *Phone, host: []const u8, port: u16, token: []const u8) void {
        // Check if already exists, update last_used.
        for (p.saved_connections.items) |*s| {
            if (std.mem.eql(u8, s.host, host) and s.port == port) {
                s.last_used = getTimestamp();
                return;
            }
        }
        // Add new, keep last 5.
        if (p.saved_connections.items.len == 5) {
            p.saved_connections.items[0].deinit(p.gpa);
            _ = p.saved_connections.orderedRemove(0);
        }
        const name = std.fmt.allocPrint(p.gpa, "{s}:{d}", .{ host, port }) catch return;
        const host_copy = p.gpa.dupe(u8, host) catch {
            p.gpa.free(name);
            return;
        };
        var token_copy: [32]u8 = @splat(0);
        if (token.len == 32) @memcpy(&token_copy, token);
        p.saved_connections.append(p.gpa, .{
            .name = name,
            .host = host_copy,
            .port = port,
            .token = token_copy,
            .last_used = getTimestamp(),
        }) catch {
            p.gpa.free(name);
            p.gpa.free(host_copy);
        };
    }

    /// Load a saved connection into the input fields.
    pub fn loadConnection(p: *Phone, index: usize) void {
        if (index >= p.saved_connections.items.len) return;
        const s = p.saved_connections.items[index];
        p.host_input.set(s.host);
        var buf: [8]u8 = undefined;
        p.port_input.set(std.fmt.bufPrint(&buf, "{d}", .{s.port}) catch "4789");
        p.token_input.set(&s.token);
        p.saved_connections.items[index].last_used = getTimestamp();
    }

    /// Back to the fields: from the header, to change where this points.
    pub fn toConnect(p: *Phone) void {
        p.fillConnect();
        p.screen = .connect;
        p.draw();
    }

    /// What the composer sends: a command to run, or a question for the
    /// agent, in the tab it is pointed at. Saved to history for recall.
    pub fn submit(p: *Phone) void {
        const text = std.mem.trim(u8, p.input.text(), " \t\r\n");
        if (text.len == 0) return;
        if (p.session == 0) {
            p.push("no tab to send to: is the workstation's relay up?", .{});
            return;
        }
        // "clear" is a local command: wipe the feed, do not send it.
        if (std.mem.eql(u8, text, "clear")) {
            p.clearFeed();
            p.input.clear();
            return;
        }
        var aw: std.Io.Writer.Allocating = .init(p.gpa);
        defer aw.deinit();
        opLine(&aw.writer, if (p.mode == 0) "run" else "ask", p.session, text);
        // What was asked shows when its block or turn comes back from the
        // relay, as it does on the desktop: the workstation is the record.
        p.write(aw.written());
        p.input.clear();
        // Save to history (newest first), keep last 20 commands.
        const copy = p.gpa.dupe(u8, text) catch return;
        if (p.history.items.len == 20) {
            p.gpa.free(p.history.items[p.history.items.len - 1]);
            _ = p.history.orderedRemove(p.history.items.len - 1);
        }
        p.history.insert(p.gpa, 0, copy) catch {
            p.gpa.free(copy);
            return;
        };
        p.history_index = 0;
    }

    /// Recall a command from history: up goes back, forward goes newer.
    pub fn historyRecall(p: *Phone, direction: i32) void {
        if (p.history.items.len == 0) return;
        const new_index = @as(i32, @intCast(p.history_index)) + direction;
        if (new_index < 0 or new_index >= @as(i32, @intCast(p.history.items.len))) return;
        p.history_index = @intCast(new_index);
        p.input.set(p.history.items[p.history_index]);
    }

    /// Where the workstation is: fields, saved connections, and help.
    pub fn connectView(p: *Phone, c: *ui.Context) void {
        ui.column(c, .{
            .width = .fill,
            .height = .fill,
            .padding = c.safe_area,
            .background = c.theme.background,
        });
        // The same title strip as the feed's: where this is, and whether
        // the link is up.
        {
            const bar = ui.div(c).row().wFull().h(48).gap(10).itemsCenter().px(16);
            defer bar.end();
            if (p.status == .live) {
                ui.key(c, "back");
                if (ui.button(c, "", .{ .variant = .ghost, .size = 12, .icon = "chevron.left" }).clicked) p.screen = .feed;
            } else ui.icon(c, "terminal.fill", .{ .size = 13, .color = c.theme.accent });
            ui.text(c, "Connect", .{ .size = 14, .weight = .semibold });
            ui.spacer(c);
            const dot = switch (p.status) {
                .live => c.theme.success,
                .connecting => c.theme.accent,
                .down => c.theme.danger,
            };
            if (p.status == .connecting) {
                ui.text(c, pulse(c), .{ .size = 16, .color = dot, .mono = true });
            } else {
                _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 4, .background = dot }, .none, null);
            }
            ui.text(c, p.status.label(), .{ .size = 12, .color = c.theme.muted });
        }
        ui.divider(c);
        ui.scroll(c, .{
            .width = .fill,
            .grow = 1,
            .padding = .{ .top = 20, .bottom = 24, .left = 16, .right = 16 },
            .gap = 20,
        });
        {
            ui.text(c, "Workstation", .{ .size = 13, .weight = .semibold, .color = c.theme.muted });
            const box = ui.div(c).column().wFull().p(16).gap(12).bg(c.theme.surface).rounded(12).border(c.theme.border);
            defer box.end();
            ui.text(c, "The relay on the machine running nanoterm prints the address and a token.", .{ .size = 13, .color = c.theme.muted, .wrap = true, .leading = 1.4 });
            _ = p.field(c, "Host", "127.0.0.1 or workstation name", &p.host_input, false);
            _ = p.field(c, "Port", "4789", &p.port_input, false);
            const token = p.field(c, "Token", "the 32 characters from relay", &p.token_input, false);
            if (ui.button(c, if (p.status == .connecting) "Connecting…" else "Connect", .{
                .size = 14,
                .variant = .primary,
                .width = .fill,
            }).clicked or token.submitted) p.connect();
            if (p.status == .live) {
                if (ui.button(c, "Back to the tabs", .{ .size = 13, .variant = .ghost, .width = .fill }).clicked) p.screen = .feed;
            }
        }
        {
            ui.text(c, "First time?", .{ .size = 13, .weight = .semibold, .color = c.theme.muted });
            const box = ui.div(c).column().wFull().p(16).gap(10).bg(c.theme.surface).rounded(12).border(c.theme.border);
            defer box.end();
            const steps = [_][]const u8{
                "1. On your workstation, run: nanoterm --relay",
                "2. Copy the address and token it prints",
                "3. Enter them above and tap Connect",
            };
            for (steps) |step| ui.text(c, step, .{ .size = 13, .color = c.theme.text, .wrap = true, .leading = 1.4 });
        }
        if (p.connect_why_len > 0) {
            const err = ui.div(c).column().wFull().gap(8).p(16).bg(c.theme.danger.alpha(0.12)).rounded(12).border(c.theme.danger.alpha(0.4));
            defer err.end();
            const r = ui.div(c).row().gap(10).itemsCenter();
            defer r.end();
            ui.icon(c, "exclamationmark.triangle.fill", .{ .size = 18, .color = c.theme.danger });
            ui.text(c, "Connection failed", .{ .size = 14, .weight = .semibold, .color = c.theme.danger });
            ui.text(c, p.connect_why[0..p.connect_why_len], .{ .size = 13, .color = c.theme.danger, .wrap = true, .leading = 1.4 });
        }
        if (p.saved_connections.items.len > 0) {
            ui.text(c, "Recent connections", .{ .size = 13, .weight = .semibold, .color = c.theme.muted });
            const list = ui.div(c).column().wFull().gap(8).bg(c.theme.surface).rounded(12).border(c.theme.border).clip();
            defer list.end();
            for (p.saved_connections.items, 0..) |conn, i| {
                ui.key(c, c.print("conn-{d}", .{i}));
                var row = ui.div(c).row().wFull().gap(12).itemsCenter().px(16).py(14).hover(c.theme.surface_hover);
                defer row.end();
                if (row.clicked()) p.loadConnection(i);
                ui.icon(c, "globe", .{ .size = 18, .color = c.theme.accent });
                const text = ui.div(c).column().grow().gap(2);
                defer text.end();
                ui.text(c, conn.name, .{ .size = 14, .weight = .medium });
                ui.textf(c, .{ .size = 12, .color = c.theme.muted, .mono = true }, "{s}:{d}", .{ conn.host, conn.port });
                if (ui.button(c, "Connect", .{ .size = 13, .variant = .secondary }).clicked) p.loadConnection(i);
            }
        }
        {
            ui.text(c, "Appearance", .{ .size = 13, .weight = .semibold, .color = c.theme.muted });
            const box = ui.div(c).column().wFull().p(16).gap(12).bg(c.theme.surface).rounded(12).border(c.theme.border);
            defer box.end();
            ui.text(c, "The phone follows the system's light or dark; a new choice applies when the app restarts.", .{ .size = 13, .color = c.theme.muted, .wrap = true, .leading = 1.4 });
            const order = [_][]const u8{ "System", "Light", "Dark" };
            var picked: usize = switch (p.theme_pref) {
                .system => 0,
                .light => 1,
                .dark => 2,
            };
            if (ui.segmented(c, &order, &picked)) {
                const next: settings.ThemePreference = switch (picked) {
                    0 => .system,
                    1 => .light,
                    else => .dark,
                };
                if (p.theme_pref != next) {
                    p.theme_pref = next;
                    const host = p.host[0..p.host_len];
                    const port = p.port;
                    if (p.has_token) _ = settings.save(p.io, p.gpa, host, port, &p.token, p.theme_pref, p.layout);
                    p.notify(.info, "Theme saved: it applies when the app restarts.", .{});
                }
            }
            ui.text(c, "Sessions", .{ .size = 13, .weight = .medium, .color = c.theme.muted });
            const layouts = [_][]const u8{ "Tabs", "Sidebar" };
            var picked_layout: usize = if (p.layout == .tabs) 0 else 1;
            if (ui.segmented(c, &layouts, &picked_layout)) p.setLayout(if (picked_layout == 0) .tabs else .sidebar);
            ui.text(c, if (p.layout == .tabs)
                "A row of pills under the title, as the desktop's bottom bar."
            else
                "A drawer from the left, as the desktop's sidebar: the button by the title opens it.", .{ .size = 12, .color = c.theme.muted, .wrap = true, .leading = 1.4 });
        }
        {
            ui.text(c, "Connection methods", .{ .size = 13, .weight = .semibold, .color = c.theme.muted });
            const box = ui.div(c).column().wFull().p(16).gap(12).bg(c.theme.surface).rounded(12).border(c.theme.border);
            defer box.end();
            const methods = [_]struct { icon: []const u8, title: []const u8, desc: []const u8 }{
                .{ .icon = "wifi", .title = "Same Wi-Fi", .desc = "Use the workstation's local IP address" },
                .{ .icon = "cable", .title = "USB (ADB)", .desc = "Run: adb reverse tcp:4789 tcp:4789, then use 127.0.0.1" },
                .{ .icon = "globe", .title = "Tailscale", .desc = "Use the Tailscale IP address of your workstation" },
            };
            for (methods) |m| {
                const row = ui.div(c).row().gap(12).itemsStart();
                defer row.end();
                ui.icon(c, m.icon, .{ .size = 20, .color = c.theme.accent });
                const col = ui.div(c).column().grow().gap(2);
                defer col.end();
                ui.text(c, m.title, .{ .size = 13, .weight = .semibold });
                ui.text(c, m.desc, .{ .size = 12, .color = c.theme.muted, .wrap = true, .leading = 1.3 });
            }
        }
        ui.end(c);
        ui.end(c);
    }

    /// A label and its field: what the connect screen is made of.
    fn field(p: *Phone, c: *ui.Context, label: []const u8, hint: []const u8, buffer: *ui.TextBuffer, password: bool) ui.TextFieldResult {
        _ = p;
        ui.text(c, label, .{ .size = 13, .weight = .medium, .color = c.theme.muted });
        return ui.textField(c, buffer, .{
            .placeholder = hint,
            .width = .fill,
            .size = 16,
            .password = password,
            .select_all_on_focus = true,
        });
    }

    /// One thing in the feed, drawn as the desktop draws it.
    pub fn renderFeed(p: *Phone, c: *ui.Context, f: *const Feed) void {
        switch (f.*) {
            .turn => |t| p.renderTurn(c, t),
            .block => |b| p.renderBlock(c, b, false),
            .line => |l| switch (l.kind) {
                .notice => ui.text(c, l.text, .{ .size = 11.5, .color = c.theme.muted, .wrap = true }),
                .failure => {
                    const r = ui.div(c).row().wFull().gap(6).itemsStart();
                    defer r.end();
                    ui.icon(c, "exclamationmark.triangle", .{ .size = 11, .color = c.theme.danger });
                    ui.text(c, l.text, .{ .size = 12, .color = c.theme.danger, .wrap = true });
                },
            },
        }
    }

    /// The prompt, the agent, and what it did in order: the desktop's turn,
    /// at a phone's width.
    fn renderTurn(p: *Phone, c: *ui.Context, t: *Turn) void {
        const d = ui.div(c).column().wFull().px(12).py(12).gap(12)
            .bg(c.theme.surface).rounded(12).border(c.theme.border);
        defer d.end();
        {
            const r = ui.div(c).row().wFull().gap(12).itemsStart();
            defer r.end();
            avatar(c, "person.fill", c.theme.accent);
            const q = ui.div(c).column().grow().pt(2);
            defer q.end();
            const asked = if (t.title.items.len > 0) t.title.items else t.prompt.items;
            ui.text(c, if (asked.len > 0) asked else "…", .{ .size = 15, .weight = .semibold, .wrap = true, .leading = 1.4 });
        }
        {
            const h = ui.div(c).row().wFull().gap(10).itemsCenter().pt(2);
            defer h.end();
            avatar(c, "sparkles", agentTone(c));
            ui.text(c, if (t.agent.items.len > 0) t.agent.items else "Agent", .{ .size = 13, .weight = .semibold, .color = agentTone(c) });
            ui.spacer(c);
            if (!t.done) {
                ui.text(c, spin(c), .{ .size = 13, .color = agentTone(c), .mono = true });
            } else if (t.started > 0 and t.ended > t.started) {
                ui.text(c, duration(c, t.ended - t.started), .{ .size = 12, .color = c.theme.muted, .mono = true });
            }
        }
        const body = ui.div(c).column().wFull().pl(30).gap(12).pt(4);
        defer body.end();
        const items = t.items.items;
        const reply = replyStart(items);
        var i: usize = 0;
        var ordinal: usize = 0;
        while (i < items.len) {
            if (folds(items, i, reply)) {
                var j = i;
                while (j < items.len and folds(items, j, reply)) j += 1;
                p.group(c, t, i, j, ordinal, !t.done and j == items.len);
                ordinal += 1;
                i = j;
                continue;
            }
            ui.key(c, c.print("it-{x}-{d}", .{ @intFromPtr(t), i }));
            p.item(c, t, &items[i]);
            i += 1;
        }
        if (!t.done and items.len == 0) ui.text(c, "Thinking…", .{ .size = 13, .color = c.theme.muted, .italic = true });
    }

    /// One item as it is drawn, in the reply or inside an open group.
    fn item(p: *Phone, c: *ui.Context, t: *Turn, it: *const Item) void {
        switch (it.*) {
            .text => |l| markdown(c, l.items),
            .thought => |l| {
                const r = ui.div(c).row().wFull().gap(6).itemsStart();
                defer r.end();
                ui.icon(c, "brain", .{ .size = 11, .color = faintTone(c) });
                const shown = if (l.items.len > 600) c.print("{s}…", .{l.items[0..600]}) else l.items;
                ui.text(c, std.mem.trim(u8, shown, " \n"), .{ .size = 12.5, .color = c.theme.muted, .wrap = true, .italic = true, .leading = 1.4 });
            },
            .tool => |*tl| if (!isVisualTool(tl)) p.tool(c, t, tl),
            .visual => |title| {
                const r = ui.div(c).row().wFull().gap(6).itemsCenter();
                defer r.end();
                ui.icon(c, "photo", .{ .size = 12, .color = c.theme.accent });
                ui.text(c, title.items, .{ .size = 12.5, .color = c.theme.muted, .wrap = true });
                // A visual runs in its own sandbox on the workstation: the
                // phone shows that it was shown, not the picture.
                ui.text(c, "(shown on the workstation)", .{ .size = 11, .color = c.theme.muted });
            },
            .command => |id| if (!shownByTool(t, id)) {
                if (p.blockFor(t.session, id)) |b| p.renderBlock(c, b, true);
            },
            .plan => |entries| plan(c, entries.items),
            .permission => |*perm| p.permission(c, perm),
            .note => |n| {
                const r = ui.div(c).row().wFull().gap(6).itemsCenter();
                defer r.end();
                ui.icon(c, "exclamationmark.triangle", .{ .size = 12, .color = warningTone(c) });
                ui.text(c, n.items, .{ .size = 12.5, .color = warningTone(c), .wrap = true });
            },
        }
    }

    /// A group of steps, folded into one line that says what they did; a
    /// tap opens it, as on the desktop.
    fn group(p: *Phone, c: *ui.Context, t: *Turn, from: usize, to: usize, ordinal: usize, live: bool) void {
        const items = t.items.items[from..to];
        const text = summary(c, t, items);
        if (text.len == 0 and !live) return;
        const bit: u64 = if (ordinal < 64) @as(u64, 1) << @intCast(ordinal) else 0;
        const expanded = t.open_groups & bit != 0;
        const col = ui.div(c).column().wFull().gap(12);
        defer col.end();
        ui.key(c, c.print("fold-{d}", .{ordinal}));
        {
            const it = ui.pressable(c, .{ .direction = .row, .gap = 10, .align_items = .center, .padding = .{ .top = 4, .bottom = 4 }, .control = true }, null);
            defer ui.end(c);
            if (it.clicked) {
                t.open_groups ^= bit;
                c.changed = true;
            }
            const color = if (it.hovered) c.theme.text else c.theme.muted;
            if (live) ui.text(c, spin(c), .{ .size = 13, .color = agentTone(c), .mono = true });
            ui.text(c, if (text.len > 0) text else "Working", .{ .size = 14, .color = color, .wrap = true });
            ui.icon(c, if (expanded) "chevron.down" else "chevron.right", .{ .size = 9, .weight = .semibold, .color = if (it.hovered) c.theme.muted else faintTone(c) });
        }
        if (!expanded) return;
        const r = ui.div(c).row().wFull().gap(16).itemsStretch().pl(4);
        defer r.end();
        _ = c.leaf(.{ .width = .{ .px = 1 }, .background = c.theme.border }, .none, null);
        const steps = ui.div(c).column().grow().gap(12);
        defer steps.end();
        for (items, from..) |*it, k| {
            if (!shownItem(t, it)) continue;
            ui.key(c, c.print("it-{x}-{d}", .{ @intFromPtr(t), k }));
            p.item(c, t, it);
        }
    }

    fn tool(p: *Phone, c: *ui.Context, t: *Turn, tl: *const Item.Tool) void {
        const col = ui.div(c).column().wFull().gap(8);
        defer col.end();
        {
            const r = ui.div(c).row().wFull().gap(10).itemsCenter();
            defer r.end();
            ui.icon(c, toolIcon(tl.kind.items), .{ .size = 12, .frame = 16, .color = c.theme.muted });
            ui.text(c, if (tl.title.items.len > 0) tl.title.items else tl.kind.items, .{ .size = 14, .wrap = true });
            ui.spacer(c);
            switch (tl.status) {
                .pending, .in_progress => ui.text(c, spin(c), .{ .size = 13, .color = c.theme.accent, .mono = true }),
                .completed => ui.icon(c, "checkmark", .{ .size = 11, .weight = .bold, .color = c.theme.success }),
                .failed => ui.icon(c, "xmark", .{ .size = 11, .weight = .bold, .color = c.theme.danger }),
            }
        }
        if (tl.block) |id| {
            if (p.blockFor(t.session, id)) |b| p.renderBlock(c, b, true);
        } else if (tl.detail.items.len > 0 and tl.status != .in_progress) {
            const d = tl.detail.items;
            const shown = if (d.len > 400) c.print("{s}…", .{d[0..400]}) else d;
            ui.text(c, shown, .{ .size = 12, .mono = true, .color = faintTone(c), .wrap = true });
        }
    }

    fn permission(p: *Phone, c: *ui.Context, perm: *const Item.Permission) void {
        const box = ui.div(c).column().wFull().p(14).gap(12)
            .bg(c.theme.surface).rounded(10)
            .border(if (perm.chosen == null) warningTone(c) else c.theme.border);
        defer box.end();
        {
            const r = ui.div(c).row().gap(10).itemsCenter();
            defer r.end();
            ui.icon(c, "hand.raised", .{ .size = 13, .color = warningTone(c) });
            ui.text(c, perm.title.items, .{ .size = 14, .weight = .semibold, .wrap = true });
        }
        if (perm.chosen) |i| {
            const name = if (i < perm.options.items.len) perm.options.items[i].name.items else "";
            ui.text(c, c.print("Answered: {s}", .{name}), .{ .size = 13, .color = c.theme.muted });
            return;
        }
        const r = ui.div(c).row().wFull().gap(10).pt(4);
        defer r.end();
        for (perm.options.items, 0..) |o, i| {
            const allow = std.mem.startsWith(u8, o.id.items, "allow");
            const variant: ui.ButtonOptions = .{ .variant = if (allow and i == 0) .primary else if (allow) .secondary else .ghost, .size = 13 };
            if (ui.button(c, o.name.items, variant).clicked) p.answerRelay(perm.rpc.items, i);
        }
    }

    /// A command as the desktop's block: where it ran, what, its output
    /// (its tail, the rest behind a button), and how it ended.
    fn renderBlock(p: *Phone, c: *ui.Context, b: *Block, nested: bool) void {
        _ = p;
        const d = ui.div(c).column().wFull().px(if (nested) 12 else 14).py(10).gap(8)
            .bg(c.theme.surface).rounded(10).border(c.theme.border);
        defer d.end();
        const bar = if (b.state == .running) c.theme.accent else if (b.failed()) c.theme.danger else c.theme.border;
        _ = c.leaf(.{ .absolute = true, .width = .{ .px = 3 }, .height = .fill, .radius = 1.5, .background = bar, .offset = .{ .x = if (nested) -10 else -12 } }, .none, null);
        {
            const r = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer r.end();
            if (b.cwd.items.len > 0) ui.text(c, b.cwd.items, .{ .size = 12, .mono = true, .color = cwdTone(c), .truncate = .middle });
            if (b.branch.items.len > 0) {
                ui.icon(c, "arrow.triangle.branch", .{ .size = 11, .color = c.theme.success });
                ui.text(c, b.branch.items, .{ .size = 12, .mono = true, .color = c.theme.success });
            }
            if (b.is_agent) ui.badge(c, "Agent", agentTone(c));
            ui.spacer(c);
            switch (b.state) {
                .running => ui.text(c, spin(c), .{ .size = 13, .color = c.theme.accent, .mono = true }),
                .done => {
                    const ok = !b.failed();
                    ui.icon(c, if (ok) "checkmark" else "xmark", .{ .size = 11, .weight = .bold, .color = if (ok) c.theme.success else c.theme.danger });
                    if (!ok) ui.text(c, c.print("{d}", .{b.exit orelse 0}), .{ .size = 12, .mono = true, .color = c.theme.danger });
                    if (b.started > 0 and b.ended > b.started) ui.text(c, duration(c, b.ended - b.started), .{ .size = 12, .color = c.theme.muted, .mono = true });
                },
            }
        }
        {
            const r = ui.div(c).row().wFull().gap(8).itemsStart();
            defer r.end();
            ui.text(c, if (b.is_agent) "⚡" else "❯", .{ .size = 14, .weight = .bold, .color = if (b.is_agent) agentTone(c) else c.theme.accent, .mono = true });
            ui.richText(c, b.command.items, &.{}, .{ .size = 14, .weight = .semibold, .mono = true, .wrap = true, .color = c.theme.text });
        }
        const all = b.output.items;
        if (all.len == 0) return;
        var count: usize = 1;
        for (all) |ch| {
            if (ch == '\n') count += 1;
        }
        const keep = 200;
        const first: usize = if (!b.expanded and count > keep) count - keep else 0;
        const lines = ui.div(c).column().wFull().pt(2).gap(0);
        defer lines.end();
        if (first > 0) {
            if (ui.button(c, c.print("Show {d} earlier lines", .{first}), .{ .variant = .ghost, .size = 11, .icon = "chevron.up" }).clicked) b.expanded = true;
        }
        var it = std.mem.splitScalar(u8, all, '\n');
        var n: usize = 0;
        while (it.next()) |l| : (n += 1) {
            if (n < first) continue;
            ansiLine(c, l, .{ .size = 11, .mono = true, .color = c.theme.text, .wrap = true });
        }
        if (b.expanded and count > keep) {
            if (ui.button(c, "Show less", .{ .variant = .ghost, .size = 11, .icon = "chevron.down" }).clicked) b.expanded = false;
        }
    }

    /// A permission's option: the relay answers the agent.
    fn answerRelay(p: *Phone, rpc: []const u8, option: usize) void {
        var aw: std.Io.Writer.Allocating = .init(p.gpa);
        defer aw.deinit();
        answerLine(&aw.writer, p.session, rpc, option);
        p.write(aw.written());
        p.answered(rpc);
    }

    /// Gesture handling: swipe left/right to switch tabs, pull down to refresh.
    fn handleGestures(p: *Phone, c: *ui.Context) void {
        const input = c.input;

        // Track swipe start when pointer goes down.
        if (input.pressed and !p.swipe_tracking) {
            p.swipe_start_x = input.mouse.x;
            p.swipe_start_y = input.mouse.y;
            p.swipe_tracking = true;
            p.pull_distance = 0;
        }

        // Track horizontal swipe and vertical pull while dragging.
        if (p.swipe_tracking and input.down) {
            const dx = input.mouse.x - p.swipe_start_x;
            const dy = input.mouse.y - p.swipe_start_y;

            // Horizontal swipe: switch tabs when threshold reached.
            if (@abs(dx) > 80 and @abs(dx) > @abs(dy) * 2) {
                if (p.sessions.items.len > 1) {
                    const current_idx = for (p.sessions.items, 0..) |s, i| {
                        if (s.id == p.session) break i;
                    } else 0;

                    const new_idx = if (dx > 0)
                        (if (current_idx == 0) p.sessions.items.len - 1 else current_idx - 1)
                    else
                        (if (current_idx == p.sessions.items.len - 1) 0 else current_idx + 1);

                    if (new_idx != current_idx) {
                        p.session = p.sessions.items[new_idx].id;
                        // Trigger haptic feedback on tab switch
                        if (builtin.os.tag == .ios) nanoui.haptics.impact(.light);
                        p.notify(.info, "swiped to tab {d}", .{p.session});
                    }
                }
                p.swipe_tracking = false;
            }

            // Vertical pull down: refresh.
            if (dy > 0 and @abs(dy) > @abs(dx) * 2) {
                p.pull_distance = dy;
            }
        }

        // Swipe ended: check for pull-to-refresh.
        if (p.swipe_tracking and !input.down) {
            p.swipe_tracking = false;

            // Pull down far enough triggers refresh.
            if (p.pull_distance > 120 and !p.pull_refreshing) {
                p.pull_refreshing = true;
                // Trigger haptic feedback on refresh
                if (builtin.os.tag == .ios) nanoui.haptics.impact(.medium);
                p.refresh();
                p.pull_distance = 0;
            }
        }

        // Decay pull distance when not pulling.
        if (!p.swipe_tracking and p.pull_distance > 0) {
            p.pull_distance = @max(0, p.pull_distance - 8);
        }
    }

    /// Refresh: ask the relay to resend everything (the `list` command).
    pub fn refresh(p: *Phone) void {
        if (p.status != .live) {
            p.pull_refreshing = false;
            p.feed_loading = false;
            return;
        }
        p.feed_loading = true;
        const cmd = [_]u8{ '{', '"', 'o', 'p', '"', ':', '"', 'l', 'i', 's', 't', '"', '}', '\n' };
        p.write(&cmd);
        p.pull_refreshing = false;
    }

    pub fn draw(p: *Phone) void {
        if (p.window) |w| w.redraw();
    }

    /// Whether this tab has work in it: a command or a turn running.
    fn busyFor(p: *Phone, id: u64) bool {
        for (p.running.items) |k| {
            if (k == id or (k & turn_bit) == id) return true;
        }
        return false;
    }

    /// The desktop's sidebar, as a drawer: every tab, its folder and its
    /// agent, and the way back to the pill row.
    fn sidebar(p: *Phone, c: *ui.Context) void {
        if (!p.drawer_open) return;
        {
            const d = ui.div(c).fixed().offset(0, 0).w(c.size.w).h(c.size.h).layer(8).bg(ui.Color.hex(0x000000).alpha(if (c.theme.dark) 0.5 else 0.3));
            const it = d.interaction();
            d.end();
            if (it.clicked) {
                p.drawer_open = false;
                c.changed = true;
            }
        }
        const width = @min(320, c.size.w * 0.84);
        const panel = ui.div(c).fixed().offset(0, 0).w(width).h(c.size.h).layer(9).column().px(12).gap(2).bg(c.theme.background).border(c.theme.border).pt(c.safe_area.top).pb(c.safe_area.bottom);
        defer panel.end();
        _ = panel.interaction();
        {
            const head = ui.div(c).row().wFull().gap(8).itemsCenter().py(10);
            defer head.end();
            ui.icon(c, "sidebar.left", .{ .size = 12, .color = c.theme.accent });
            ui.text(c, "Sessions", .{ .size = 14, .weight = .semibold });
            ui.spacer(c);
            if (ui.button(c, "", .{ .variant = .ghost, .size = 10, .icon = "xmark" }).clicked) {
                p.drawer_open = false;
                c.changed = true;
            }
        }
        ui.textf(c, .{ .size = 10.5, .color = c.theme.muted }, "{s} · {d} tabs", .{ p.where[0..p.where_len], p.sessions.items.len });
        ui.scroll(c, .{ .width = .fill, .grow = 1, .gap = 2, .padding = .{ .top = 6, .bottom = 8 } });
        for (p.sessions.items) |tab| {
            const active = tab.id == p.session;
            ui.key(c, c.print("drawer-{d}", .{tab.id}));
            var row = ui.div(c).column().wFull().gap(3).px(10).py(8).rounded(8);
            row = if (active) row.bg(c.theme.surface_hover) else row.hover(c.theme.surface_hover);
            defer row.end();
            if (row.clicked()) {
                p.session = tab.id;
                p.drawer_open = false;
                c.changed = true;
            }
            {
                const top = ui.div(c).row().wFull().gap(6).itemsCenter();
                defer top.end();
                ui.icon(c, "terminal.fill", .{ .size = 10, .color = if (active) c.theme.accent else c.theme.muted });
                const label = if (tab.title.len > 0) tab.title else c.print("tab {d}", .{tab.id});
                ui.text(c, label, .{ .size = 12.5, .weight = if (active) .semibold else .regular, .color = c.theme.text, .truncate = .middle });
                ui.spacer(c);
                if (p.busyFor(tab.id)) _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = c.theme.accent }, .none, null);
            }
            {
                const sub = ui.div(c).row().wFull().gap(6).itemsCenter().pl(16);
                defer sub.end();
                const dir = if (tab.cwd.len > 0) tab.cwd else "~";
                ui.text(c, dir, .{ .size = 10.5, .color = c.theme.muted, .mono = true, .truncate = .middle });
                ui.spacer(c);
                const kind = if (tab.agent.len > 0) tab.agent else if (tab.mode.len > 0) tab.mode else "shell";
                ui.text(c, kind, .{ .size = 10, .weight = .semibold, .color = if (tab.agent.len > 0) agentTone(c) else c.theme.muted });
            }
        }
        ui.end(c);
        ui.divider(c);
        if (ui.button(c, "Show as tabs", .{ .size = 12, .variant = .ghost, .width = .fill, .icon = "rectangle.split.2x1" }).clicked) {
            p.setLayout(.tabs);
            c.changed = true;
        }
    }

    /// The agent's light, as the desktop's model chip draws it.
    fn agentDot(c: *ui.Context, status: []const u8) ui.Color {
        if (std.mem.eql(u8, status, "working")) return agentTone(c);
        if (std.mem.eql(u8, status, "ready")) return c.theme.success;
        if (std.mem.eql(u8, status, "starting")) return warningTone(c);
        if (std.mem.eql(u8, status, "failed")) return c.theme.danger;
        return c.theme.muted.alpha(0.5);
    }

    /// The desktop's model picker, as a sheet: the agent, then its models.
    fn pickerPanel(p: *Phone, c: *ui.Context) void {
        if (!p.picker_open) return;
        {
            const d = ui.div(c).fixed().offset(0, 0).w(c.size.w).h(c.size.h).layer(8).bg(ui.Color.hex(0x000000).alpha(if (c.theme.dark) 0.5 else 0.3));
            const it = d.interaction();
            d.end();
            if (it.clicked) {
                p.picker_open = false;
                c.changed = true;
            }
        }
        const height = @min(520, c.size.h * 0.7);
        const panel = ui.div(c).fixed().offset(0, c.size.h - height).w(c.size.w).h(height).layer(9).column().gap(10).px(16).pt(14).pb(c.safe_area.bottom + 10).bg(c.theme.surface).rounded(18);
        defer panel.end();
        _ = panel.interaction();
        {
            const head = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer head.end();
            ui.icon(c, "sparkles", .{ .size = 12, .color = agentTone(c) });
            ui.text(c, "Agent & model", .{ .size = 15, .weight = .semibold });
            ui.spacer(c);
            if (ui.button(c, "", .{ .variant = .ghost, .size = 10, .icon = "xmark" }).clicked) {
                p.picker_open = false;
                c.changed = true;
            }
        }
        const tab = p.currentTab() orelse {
            ui.text(c, "This tab is not here any more.", .{ .size = 12.5, .color = c.theme.muted });
            return;
        };
        // The agent, as Settings found it; the running one is lit.
        if (p.agents.items.len > 1) {
            const names = c.alloc().alloc([]const u8, p.agents.items.len) catch return;
            var selected: usize = 0;
            for (p.agents.items, 0..) |a, i| {
                names[i] = a.name;
                if (std.mem.eql(u8, a.key, tab.agent_key)) selected = i;
            }
            if (ui.segmented(c, names, &selected)) p.pickAgent(p.agents.items[selected].key);
        }
        {
            const line = ui.div(c).row().wFull().gap(6).itemsCenter();
            defer line.end();
            _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = agentDot(c, tab.agent_status) }, .none, null);
            ui.text(c, if (tab.agent.len > 0) tab.agent else "Agent", .{ .size = 11.5, .weight = .semibold, .color = c.theme.text });
            const status = if (tab.agent_status.len > 0) tab.agent_status else "off";
            ui.text(c, status, .{ .size = 10.5, .color = c.theme.muted });
            ui.spacer(c);
            const model_label = ui.div(c).row().maxW(150).clip();
            defer model_label.end();
            ui.text(c, if (tab.model.len > 0) tab.model else "default model", .{ .size = 11, .mono = true, .color = c.theme.muted, .truncate = .middle });
        }
        ui.scroll(c, .{ .width = .fill, .grow = 1, .gap = 1, .padding = .{ .top = 2, .bottom = 6 } });
        if (tab.models.items.len == 0) {
            const why = if (std.mem.eql(u8, tab.agent_status, "starting"))
                c.print("Starting {s} to see its models…", .{if (tab.agent.len > 0) tab.agent else "the agent"})
            else
                "No models listed yet: the agent names its models once it is running.";
            ui.text(c, why, .{ .size = 12, .color = c.theme.muted, .wrap = true });
        } else {
            for (tab.models.items) |m| {
                const current = std.mem.eql(u8, m.value, tab.model);
                ui.key(c, c.print("model-{s}-{s}", .{ m.provider, m.value }));
                var row = ui.div(c).row().wFull().gap(8).itemsCenter().px(10).py(8).rounded(8);
                row = if (current) row.bg(c.theme.surface_hover) else row.hover(c.theme.surface_hover);
                defer row.end();
                if (row.clicked()) p.pickModel(m.value, m.provider);
                ui.icon(c, if (current) "checkmark.circle.fill" else "cpu", .{ .size = 11, .color = if (current) c.theme.success else c.theme.muted });
                const words = ui.div(c).column().grow().gap(1);
                defer words.end();
                ui.text(c, m.name, .{ .size = 12.5, .mono = true, .color = c.theme.text });
                if (m.provider.len > 0) ui.text(c, m.provider, .{ .size = 10.5, .color = c.theme.muted });
            }
        }
        ui.end(c);
    }

    pub fn view(p: *Phone, c: *ui.Context) void {
        if (p.screen == .connect) return p.connectView(c);

        // Gesture detection: horizontal swipe to switch tabs, pull down to refresh.
        p.handleGestures(c);

        ui.column(c, .{
            .width = .fill,
            .height = .fill,
            .padding = c.safe_area,
            .background = c.theme.background,
        });

        // Pull-to-refresh indicator: shown when pulling down from top.
        if (p.pull_distance > 20) {
            const progress = @min(p.pull_distance / 120.0, 1.0);
            ui.row(c, .{ .width = .fill, .justify = .center, .padding = .{ .top = 12, .bottom = 8 } });
            if (progress >= 1.0) {
                ui.text(c, spin(c), .{ .size = 14, .color = c.theme.accent, .mono = true });
                ui.text(c, " Release to refresh", .{ .size = 13, .color = c.theme.accent });
            } else {
                ui.text(c, "↓ Pull to refresh", .{ .size = 13, .color = c.theme.muted });
            }
            ui.end(c);
        }

        // The title strip, as the desktop's: what this is, the tab it
        // shows, and whether the link is up — one line, not a stack.
        {
            const bar = ui.div(c).row().wFull().h(48).gap(10).itemsCenter().px(16);
            defer bar.end();
            ui.icon(c, "terminal.fill", .{ .size = 13, .color = c.theme.accent });
            ui.text(c, "nanoterm", .{ .size = 14, .weight = .semibold });
            var title: []const u8 = "";
            for (p.sessions.items) |tab| {
                if (tab.id == p.session and tab.title.len > 0) title = tab.title;
            }
            if (title.len > 0) {
                const t = ui.div(c).row().maxW(160).clip();
                defer t.end();
                ui.text(c, title, .{ .size = 13, .color = c.theme.muted, .mono = true, .truncate = .middle });
            }
            ui.spacer(c);
            const dot = switch (p.status) {
                .live => c.theme.success,
                .connecting => c.theme.accent,
                .down => c.theme.danger,
            };
            if (p.status == .connecting) {
                ui.text(c, pulse(c), .{ .size = 16, .color = dot, .mono = true });
            } else {
                _ = c.leaf(.{ .width = .{ .px = 8 }, .height = .{ .px = 8 }, .radius = 4, .background = dot }, .none, null);
            }
            if (p.running.items.len > 0) {
                ui.key(c, "stop");
                if (ui.button(c, "", .{ .variant = .danger, .size = 12, .icon = "stop.circle" }).clicked) p.interrupt();
            } else if (p.status != .live) {
                if (ui.button(c, "Reconnect", .{ .size = 13, .variant = .secondary }).clicked) p.toConnect();
            }
            if (p.feed.items.len > 0) {
                ui.key(c, "clear");
                if (ui.button(c, "", .{ .variant = .ghost, .size = 12, .icon = "trash" }).clicked) p.clearFeed();
            }
            // The switcher's shape: a row of pills, or the desktop's
            // sidebar in a drawer.
            ui.key(c, "layout");
            const layout_icon = if (p.layout == .sidebar) "sidebar.left" else "rectangle.split.2x1";
            if (ui.button(c, "", .{ .variant = .ghost, .size = 12, .icon = layout_icon }).clicked) {
                if (p.layout == .tabs) {
                    p.setLayout(.sidebar);
                    p.drawer_open = true;
                    p.draw();
                } else {
                    p.drawer_open = !p.drawer_open;
                    p.draw();
                }
            }
            ui.key(c, "settings");
            if (ui.button(c, "", .{ .variant = .ghost, .size = 12, .icon = "slider.horizontal.3" }).clicked) p.toConnect();
        }
        // Ghostty's tab bar, as on the desktop: a pill per tab, the one
        // shown lit; they scroll sideways when there are many. The sidebar
        // layout shows the same tabs in a drawer instead.
        if (p.layout == .tabs and p.sessions.items.len > 1) {
            _ = c.open(.{
                .direction = .row,
                .width = .fill,
                .height = .{ .px = 40 },
                .gap = 8,
                .padding = .{ .left = 14, .right = 14, .bottom = 10 },
                .scroll_x = true,
                .clip = true,
            }, "tabs");
            defer c.end();
            for (p.sessions.items) |tab| {
                const active = tab.id == p.session;
                ui.key(c, c.print("tab-{d}", .{tab.id}));
                var pill = ui.div(c).row().gap(8).itemsCenter().px(12).py(6).rounded(8).maxW(190).clip();
                pill = if (active) pill.bg(c.theme.surface_hover) else pill.hover(c.theme.surface_hover);
                defer pill.end();
                if (pill.clicked() and !active) p.session = tab.id;
                const label = if (tab.title.len > 0) tab.title else c.print("tab {d}", .{tab.id});
                ui.text(c, label, .{ .size = 13, .weight = if (active) .semibold else .regular, .color = if (active) c.theme.text else c.theme.muted });
                const busy = for (p.running.items) |k| {
                    if (k == tab.id or (k & turn_bit) == tab.id) break true;
                } else false;
                if (busy) _ = c.leaf(.{ .width = .{ .px = 6 }, .height = .{ .px = 6 }, .radius = 3, .background = c.theme.accent }, .none, null);
            }
        }
        // Not connected: where it would go, and why it is not there.
        if (p.status != .live) {
            const why = ui.div(c).column().wFull().px(16).pb(8).gap(2);
            defer why.end();
            ui.textf(c, .{ .size = 11.5, .color = c.theme.muted }, "{s} · {s}", .{ p.where[0..p.where_len], p.status.label() });
            if (p.why_len > 0) ui.text(c, p.why[0..p.why_len], .{ .size = 11.5, .color = c.theme.danger, .wrap = true });
        }
        // What came, in the order it came: the tab's turns and commands,
        // drawn as the desktop draws them.
        ui.scroll(c, .{
            .width = .fill,
            .grow = 1,
            .padding = .{ .left = 14, .right = 14, .top = 12, .bottom = 12 },
            .gap = 12,
            .follow_end = true,
            .background = c.theme.surface,
        });
        // Loading skeleton: shown while refreshing the feed.
        if (p.feed_loading) {
            const skel = ui.div(c).column().wFull().gap(12);
            defer skel.end();
            for (0..3) |_| {
                const row = ui.div(c).row().wFull().gap(12).itemsCenter();
                defer row.end();
                _ = c.leaf(.{ .width = .{ .px = 32 }, .height = .{ .px = 32 }, .radius = 8, .background = c.theme.surface_hover }, .none, null);
                const col = ui.div(c).column().grow().gap(8);
                defer col.end();
                _ = c.leaf(.{ .width = .{ .px = 120 }, .height = .{ .px = 14 }, .radius = 6, .background = c.theme.surface_hover }, .none, null);
                _ = c.leaf(.{ .width = .{ .px = 80 }, .height = .{ .px = 12 }, .radius = 6, .background = c.theme.surface_hover }, .none, null);
            }
        }
        var shown_here: usize = 0;
        for (p.feed.items, 0..) |*f, i| {
            const session = f.session();
            if (session != 0 and session != p.session) continue;
            shown_here += 1;
            switch (f.*) {
                .turn => |t| ui.key(c, c.print("turn-{x}", .{@intFromPtr(t)})),
                .block => |b| ui.key(c, c.print("blk-{x}", .{@intFromPtr(b)})),
                .line => ui.keyInt(c, i),
            }
            p.renderFeed(c, f);
        }
        if (shown_here == 0) {
            // The desktop's welcome, smaller: what this is, and a few
            // things to try — a tap puts one in the input.
            const outer = ui.div(c).column().wFull().itemsCenter().pt(48).px(24).gap(16);
            defer outer.end();
            const head = ui.div(c).row().gap(12).itemsCenter();
            defer head.end();
            ui.icon(c, "terminal.fill", .{ .size = 28, .color = c.theme.accent });
            ui.text(c, "nanoterm", .{ .size = 26, .weight = .bold });
            ui.text(c, "Commands and questions in one input. As the workstation draws a command's block or the agent's turn, so this does.", .{
                .size = 14,
                .color = c.theme.muted,
                .wrap = true,
                .leading = 1.5,
            });
            const tries = [_]struct { text: []const u8, agent: bool }{
                .{ .text = "git status", .agent = false },
                .{ .text = "ls -la", .agent = false },
                .{ .text = "what does this project do?", .agent = true },
            };
            for (tries, 0..) |t, i| {
                ui.key(c, c.print("try-{d}", .{i}));
                const chip = ui.div(c).row().gap(8).itemsCenter().px(14).py(8).rounded(10).border(c.theme.border).hover(c.theme.surface_hover).control();
                defer chip.end();
                if (chip.clicked()) {
                    p.input.set(t.text);
                    p.mode = if (t.agent) 1 else 0;
                }
                ui.icon(c, if (t.agent) "sparkles" else "chevron.right", .{ .size = 12, .color = c.theme.accent });
                ui.text(c, t.text, .{ .size = 13, .mono = !t.agent });
            }
        }
        ui.end(c);
        // The input, as the desktop's composer: a rounded pill holding
        // the text, a chip for where Return sends it, and the send button
        // (a stop square while something runs and the box is empty).
        ui.column(c, .{ .width = .fill, .padding = .{ .left = 14, .right = 14, .top = 8, .bottom = 12 }, .gap = 8, .background = c.theme.background });
        {
            const pill = ui.div(c).column().wFull().gap(10).px(16).pt(12).pb(10).rounded(20).bg(c.theme.surface).border(c.theme.border);
            defer pill.end();
            const typed = ui.textField(c, &p.input, .{
                .placeholder = if (p.mode == 0) "Run a command" else "Ask the agent anything",
                .width = .fill,
                .bare = true,
                .size = 14.5,
                .select_all_on_focus = false,
            });
            const actions = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer actions.end();
            {
                const agent = p.mode == 1;
                const color = c.theme.accent;
                ui.key(c, "mode-pill");
                const d = ui.div(c).row().gap(6).itemsCenter().px(12).py(5).roundedFull().bg(color.alpha(0.12)).hover(color.alpha(0.2)).control();
                defer d.end();
                if (d.clicked()) p.mode = 1 - p.mode;
                if (agent) ui.icon(c, "sparkles", .{ .size = 11, .color = color }) else ui.text(c, "❯", .{ .size = 13, .weight = .bold, .color = color, .mono = true });
                ui.text(c, if (agent) "Agent" else "shell", .{ .size = 12, .weight = .semibold, .color = color });
            }
            // The tab's agent and model, one tap to change either.
            if (p.currentTab()) |tab| {
                if (tab.agent.len > 0 or tab.model.len > 0) {
                    ui.key(c, "model-chip");
                    const chip = ui.div(c).row().gap(6).itemsCenter().px(10).py(5).roundedFull().hover(c.theme.text.alpha(0.06)).control();
                    defer chip.end();
                    if (chip.clicked()) p.openPicker();
                    _ = c.leaf(.{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 3.5, .background = agentDot(c, tab.agent_status) }, .none, null);
                    ui.text(c, if (tab.agent.len > 0) tab.agent else "Agent", .{ .size = 12, .weight = .semibold, .color = c.theme.text });
                    if (tab.model.len > 0) {
                        const m = ui.div(c).row().maxW(110).clip();
                        defer m.end();
                        ui.text(c, tab.model, .{ .size = 12, .mono = true, .color = c.theme.muted, .truncate = .middle });
                    }
                    ui.icon(c, "chevron.up.chevron.down", .{ .size = 9, .color = c.theme.muted });
                }
            }
            ui.spacer(c);
            if (p.history.items.len > 0) {
                ui.key(c, "history-back");
                if (ui.button(c, "", .{ .variant = .ghost, .size = 11, .icon = "chevron.up" }).clicked) p.historyRecall(-1);
                ui.key(c, "history-forward");
                if (ui.button(c, "", .{ .variant = .ghost, .size = 11, .icon = "chevron.down" }).clicked) p.historyRecall(1);
            }
            const has_text = p.input.text().len > 0;
            const running = p.running.items.len > 0;
            const can_send = has_text and p.session != 0 and p.status == .live;
            ui.key(c, "send");
            var send = ui.div(c).row().size(34, 34).roundedFull().center().bg(c.theme.text);
            if (!can_send and !running) send = send.opacity(0.35);
            defer send.end();
            if (send.clicked()) {
                if (running and !has_text) p.interrupt() else if (can_send) p.submit();
            }
            if (running and !has_text) {
                _ = c.leaf(.{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .radius = 3.5, .background = c.theme.background }, .none, null);
            } else ui.icon(c, "arrow.up", .{ .size = 14, .weight = .bold, .color = c.theme.background });
            if (typed.submitted) p.submit();
        }
        ui.end(c);
        ui.end(c);

        // The sidebar and the agent/model picker, over the feed but under
        // the notifications.
        p.sidebar(c);
        p.pickerPanel(c);

        // Notifications overlay: shown at the bottom, above everything.
        p.pruneNotifications();
        if (p.notifications.items.len > 0) {
            ui.column(c, .{
                .width = .fill,
                .gap = 6,
                .padding = .{ .left = 16, .right = 16, .bottom = 16 },
            });
            for (p.notifications.items, 0..) |*n, i| {
                const bg_color = switch (n.kind) {
                    .info => c.theme.accent,
                    .success => c.theme.success,
                    .warning => c.theme.accent,
                    .err => c.theme.danger,
                };
                const icon = switch (n.kind) {
                    .info => "ℹ",
                    .success => "✓",
                    .warning => "⚠",
                    .err => "✕",
                };
                ui.row(c, .{
                    .width = .fill,
                    .gap = 8,
                    .align_items = .center,
                    .padding = .all(12),
                    .background = bg_color,
                    .radius = 10,
                });
                ui.text(c, icon, .{ .size = 16, .color = c.theme.background });
                ui.text(c, n.message, .{
                    .size = 13,
                    .color = c.theme.background,
                    .wrap = true,
                });
                if (ui.button(c, "✕", .{ .size = 11, .variant = .ghost }).clicked) {
                    p.dismissNotification(i);
                }
                ui.end(c);
            }
            ui.end(c);
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const p = try Phone.create(init, args);
    defer p.destroy();

    const app = try nanoui.App.create(init, .{ .name = "nanoterm" });
    defer app.destroy();

    // The desktop's palette, chosen by preference (system appearance when
    // it is the system's), so the phone looks like the workstation.
    const appearance: theme.Appearance = switch (p.theme_pref) {
        .system => if (nanoui.isDark()) .dark else .light,
        .light => .light,
        .dark => .dark,
    };
    theme.apply(appearance);
    const theme_override: ?ui.Theme = theme.ui();

    p.window = try app.newWindow(.{
        .title = "nanoterm",
        .width = 430,
        .height = 932,
        .full_bleed = true,
        .theme = theme_override,
        .content = .{ .view = .init(p, Phone.view) },
        .on_close = .{ .ctx = p, .func = closed },
    });
    if (p.screen == .feed) p.open();
    // The keyboard from the start: the token, or a command.
    if (p.screen == .connect) p.host_input.focus() else p.input.focus();
    try app.run();
}

/// The window is going: nothing may draw into it any more.
fn closed(ctx: *anyopaque, _: *nanoui.Window) void {
    const p: *Phone = @ptrCast(@alignCast(ctx));
    p.window = null;
}

test {
    _ = @import("tests_phone.zig");
    _ = @import("settings.zig");
}
