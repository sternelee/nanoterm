//! nanoterm's look: palettes in the shape of Harness's defaults,
//! CodeGraff Dark and CodeGraff Light (warm neutrals, an amber accent),
//! with their roles derived as Harness derives them (hover and borders
//! from white or black, the selection from the accent). Around them, a
//! shelf of named themes in the manner of Metalterm's — soot and orange,
//! a black dome, a green tube — one chosen in Settings or the system's
//! own light and dark. `apply` switches the palette; the view hands
//! nanoui the result every frame.
const std = @import("std");
const nanoui = @import("nanoui");
const Color = nanoui.ui.Color;

pub const Appearance = enum { dark, light };

/// A palette's seeds, as Harness's `codegraff_dark`/`codegraff_light`.
const Seeds = struct {
    dark: bool,
    background: u24,
    shell: u24,
    raised: u24,
    text: u24,
    muted: u24,
    faint: u24,
    accent: u24,
    danger: u24,
    warning: u24,
    success: u24,
    ansi: [16]u24,
    /// comment, keyword, string, number, type, function.
    syntax: [6]u24,
};

/// A named theme on Settings' shelf: what it is called, a line under
/// the name, and the seeds it grows from.
pub const Entry = struct {
    id: []const u8,
    name: []const u8,
    note: []const u8,
    seeds: Seeds,
};

/// The shelf. CodeGraff first — they are the house pair — then the
/// rest, each of which stands on its own in light of its seeds' own
/// `dark` flag, whatever the system is doing.
pub const list = [_]Entry{
    .{ .id = "codegraff-dark", .name = "CodeGraff Dark", .note = "warm neutrals, amber accent", .seeds = codegraff_dark },
    .{ .id = "codegraff-light", .name = "CodeGraff Light", .note = "paper, warm white", .seeds = codegraff_light },
    .{ .id = "soot", .name = "Soot", .note = "soot, orange accent", .seeds = soot },
    .{ .id = "soft-oled", .name = "Soft OLED", .note = "a black dome, panels off", .seeds = soft_oled },
    .{ .id = "nocturne", .name = "Nocturne", .note = "velvet indigo, lavender", .seeds = nocturne },
    .{ .id = "phosphor", .name = "Phosphor", .note = "a green tube in a dark room", .seeds = phosphor },
    .{ .id = "abyss", .name = "Abyss", .note = "ink water, cyan light", .seeds = abyss },
    .{ .id = "palenight", .name = "Palenight", .note = "dusk indigo, soft violet", .seeds = palenight },
};

/// The theme Settings chose — its id, or nothing for the system's own
/// light and dark. What is not on the shelf is nothing.
pub var chosen: []const u8 = "";

pub fn select(id: []const u8) void {
    chosen = if (find(id) == null) "" else id;
}

/// The entry `id` names, if it is on the shelf.
pub fn find(id: []const u8) ?*const Entry {
    for (&list) |*e| {
        if (std.mem.eql(u8, e.id, id)) return e;
    }
    return null;
}

const codegraff_dark: Seeds = .{
    .dark = true,
    .background = 0x16140f,
    .shell = 0x1f1c16,
    .raised = 0x2a261e,
    .text = 0xedeae2,
    .muted = 0x9a9384,
    .faint = 0x5c564b,
    .accent = 0xe8a33d,
    .danger = 0xd2674f,
    .warning = 0xd9a441,
    .success = 0x7fa86b,
    .ansi = .{ 0x16140f, 0xd2674f, 0x7fa86b, 0xd9a441, 0x8a9bb0, 0xbd80e4, 0x7fa86b, 0xedeae2, 0x5c564b, 0xd2674f, 0x7fa86b, 0xe8a33d, 0x8a9bb0, 0xbd80e4, 0x9a9384, 0xfaf8f3 },
    .syntax = .{ 0x5c564b, 0xe8a33d, 0x7fa86b, 0xd9a441, 0xedeae2, 0xe8a33d },
};

const codegraff_light: Seeds = .{
    .dark = false,
    .background = 0xfaf8f3,
    .shell = 0xf0ece3,
    .raised = 0xe7e1d5,
    .text = 0x1a1813,
    .muted = 0x6b6557,
    .faint = 0xa8a090,
    .accent = 0xc77d20,
    .danger = 0xb14228,
    .warning = 0x9a6e1b,
    .success = 0x5c7e47,
    .ansi = .{ 0x1a1813, 0xb14228, 0x5c7e47, 0x9a6e1b, 0x3b6fb0, 0x7a4ea3, 0x2f8f9d, 0x6b6557, 0xa8a090, 0xb14228, 0x5c7e47, 0xc77d20, 0x3b6fb0, 0x7a4ea3, 0x2f8f9d, 0x1a1813 },
    .syntax = .{ 0xa8a090, 0xc77d20, 0x5c7e47, 0x9a6e1b, 0x1a1813, 0xc77d20 },
};

const soot: Seeds = .{
    .dark = true,
    .background = 0x0e0d0b,
    .shell = 0x161513,
    .raised = 0x211f1b,
    .text = 0xf2efe9,
    .muted = 0x8f8a80,
    .faint = 0x55514a,
    .accent = 0xff9e2c,
    .danger = 0xe05644,
    .warning = 0xe0a63f,
    .success = 0x6fbf73,
    .ansi = .{ 0x0e0d0b, 0xe05644, 0x6fbf73, 0xe0a63f, 0x6da2c8, 0xc08ae0, 0x64c7c3, 0xf2efe9, 0x55514a, 0xf07a68, 0x8fd994, 0xf0bb61, 0x8cc0e6, 0xd6a8ee, 0x8ce0dc, 0xfffdf7 },
    .syntax = .{ 0x55514a, 0xff9e2c, 0x86c98a, 0xe0a63f, 0xf2efe9, 0xffb15e },
};

const soft_oled: Seeds = .{
    .dark = true,
    .background = 0x000000,
    .shell = 0x0a0a0c,
    .raised = 0x141418,
    .text = 0xf4f4f6,
    .muted = 0x8e8e96,
    .faint = 0x54545c,
    .accent = 0x64d2ff,
    .danger = 0xff6961,
    .warning = 0xffd60a,
    .success = 0x32d74b,
    .ansi = .{ 0x000000, 0xff6961, 0x32d74b, 0xffd60a, 0x64d2ff, 0xbf5af2, 0x66e0d8, 0xf4f4f6, 0x54545c, 0xff8a82, 0x6ae682, 0xffe566, 0x8ee0ff, 0xd48af5, 0x8eeae6, 0xffffff },
    .syntax = .{ 0x54545c, 0x64d2ff, 0x32d74b, 0xffd60a, 0xf4f4f6, 0x8ee0ff },
};

const nocturne: Seeds = .{
    .dark = true,
    .background = 0x12121f,
    .shell = 0x1a1a2b,
    .raised = 0x252538,
    .text = 0xeceaf8,
    .muted = 0x9490b0,
    .faint = 0x585475,
    .accent = 0xa78bfa,
    .danger = 0xf2705d,
    .warning = 0xdfb35c,
    .success = 0x79c99e,
    .ansi = .{ 0x12121f, 0xf2705d, 0x79c99e, 0xdfb35c, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xeceaf8, 0x585475, 0xf89485, 0x9adcb6, 0xecc984, 0x9cbcff, 0xd0bcfa, 0xa5e3ff, 0xfdfcff },
    .syntax = .{ 0x585475, 0xbb9af7, 0x9adcb6, 0xdfb35c, 0xeceaf8, 0x7aa2f7 },
};

const phosphor: Seeds = .{
    .dark = true,
    .background = 0x071008,
    .shell = 0x0c1a0e,
    .raised = 0x14261a,
    .text = 0xd8f5dd,
    .muted = 0x7fae87,
    .faint = 0x43614a,
    .accent = 0x42e07a,
    .danger = 0xe05644,
    .warning = 0xd9c85c,
    .success = 0x42e07a,
    .ansi = .{ 0x071008, 0xe05644, 0x42e07a, 0xd9c85c, 0x63b9c9, 0xb18ad4, 0x59c2b6, 0xd8f5dd, 0x43614a, 0xea7a70, 0x6fee9a, 0xe8da86, 0x86d4e2, 0xc6a5e6, 0x7fded2, 0xf0fff2 },
    .syntax = .{ 0x43614a, 0x59c2b6, 0xb8e89a, 0xd9c85c, 0xd8f5dd, 0x42e07a },
};

const abyss: Seeds = .{
    .dark = true,
    .background = 0x060a12,
    .shell = 0x0b1220,
    .raised = 0x122033,
    .text = 0xe6f0f5,
    .muted = 0x7e93a6,
    .faint = 0x495e70,
    .accent = 0x39c5cf,
    .danger = 0xe05644,
    .warning = 0xdcae4a,
    .success = 0x59b58a,
    .ansi = .{ 0x060a12, 0xe05644, 0x59b58a, 0xdcae4a, 0x5f9fd4, 0x9d8ad4, 0x39c5cf, 0xe6f0f5, 0x495e70, 0xea7a70, 0x7ace9f, 0xe9c473, 0x83bce8, 0xb5a3e6, 0x6adde7, 0xf2f9fb },
    .syntax = .{ 0x495e70, 0x39c5cf, 0x7ace9f, 0xdcae4a, 0xe6f0f5, 0x83bce8 },
};

const palenight: Seeds = .{
    .dark = true,
    .background = 0x22243a,
    .shell = 0x2a2d47,
    .raised = 0x343858,
    .text = 0xe3e6f3,
    .muted = 0x8f94b8,
    .faint = 0x5b6088,
    .accent = 0x82aaff,
    .danger = 0xff5370,
    .warning = 0xffcb6b,
    .success = 0xc3e88d,
    .ansi = .{ 0x22243a, 0xff5370, 0xc3e88d, 0xffcb6b, 0x82aaff, 0xc792ea, 0x89ddff, 0xe3e6f3, 0x5b6088, 0xff8a9f, 0xd4f4ab, 0xffdd98, 0xa3c2ff, 0xdbb1f4, 0xa8e9ff, 0xf7f9ff },
    .syntax = .{ 0x5b6088, 0xc792ea, 0xc3e88d, 0xf78c6c, 0xffcb6b, 0x82aaff },
};

pub var appearance: Appearance = .dark;
pub var dark = true;

pub var background: Color = default.background;
pub var panel: Color = default.panel;
pub var raised: Color = default.raised;
pub var block_hover: Color = default.block_hover;
pub var block_selected: Color = default.block_selected;
pub var border: Color = default.border;
pub var text: Color = default.text;
pub var muted: Color = default.muted;
pub var faint: Color = default.faint;
pub var accent: Color = default.accent;
/// Text and icons on an accent fill.
pub var on_accent: Color = default.on_accent;
/// The agent's mark (its avatar, name, visuals).
pub var agent: Color = default.agent;
pub var success: Color = default.success;
pub var failure: Color = default.failure;
pub var warning: Color = default.warning;
pub var cwd: Color = default.cwd;
pub var branch: Color = default.branch;
pub var shadow: Color = default.shadow;
/// Harness's stronger edge, and its maximum-contrast plate (switch knobs).
pub var border_strong: Color = default.border_strong;
pub var solid: Color = default.solid;
/// The composer's fill (Harness's input glass, opaque).
pub var input: Color = default.input;

/// The fonts: Geist for text, and the terminal's monospaced family —
/// JetBrains Mono to start, or what Settings picked (null: the system's).
pub const font = "Geist";
pub var mono_font: ?[]const u8 = "JetBrains Mono";

// Code: panels, inline code, and syntax colors.
pub var code_bg: Color = default.code_bg;
pub var code_header: Color = default.code_header;
pub var code_inline: Color = default.code_inline;
pub var code_inline_bg: Color = default.code_inline_bg;
pub var syn_keyword: Color = default.syn_keyword;
pub var syn_string: Color = default.syn_string;
pub var syn_number: Color = default.syn_number;
pub var syn_comment: Color = default.syn_comment;
pub var syn_type: Color = default.syn_type;
pub var syn_call: Color = default.syn_call;

/// The 16 ANSI colors: normal 0–7, bright 8–15.
pub var ansi: [16]Color = default.ansi;

/// Every role of a palette.
const Palette = struct {
    background: Color,
    panel: Color,
    raised: Color,
    block_hover: Color,
    block_selected: Color,
    border: Color,
    text: Color,
    muted: Color,
    faint: Color,
    accent: Color,
    on_accent: Color,
    agent: Color,
    success: Color,
    failure: Color,
    warning: Color,
    cwd: Color,
    branch: Color,
    shadow: Color,
    border_strong: Color,
    solid: Color,
    input: Color,
    code_bg: Color,
    code_header: Color,
    code_inline: Color,
    code_inline_bg: Color,
    syn_keyword: Color,
    syn_string: Color,
    syn_number: Color,
    syn_comment: Color,
    syn_type: Color,
    syn_call: Color,
    ansi: [16]Color,
};

const default = palette(codegraff_dark);

/// Puts the chosen theme's — or, with none chosen, appearance `a`'s —
/// palette in place.
pub fn apply(a: Appearance) void {
    const s = seeds(a);
    const p = palette(s);
    appearance = a;
    dark = s.dark;
    background = p.background;
    panel = p.panel;
    raised = p.raised;
    block_hover = p.block_hover;
    block_selected = p.block_selected;
    border = p.border;
    text = p.text;
    muted = p.muted;
    faint = p.faint;
    accent = p.accent;
    on_accent = p.on_accent;
    agent = p.agent;
    success = p.success;
    failure = p.failure;
    warning = p.warning;
    cwd = p.cwd;
    branch = p.branch;
    shadow = p.shadow;
    border_strong = p.border_strong;
    solid = p.solid;
    input = p.input;
    code_bg = p.code_bg;
    code_header = p.code_header;
    code_inline = p.code_inline;
    code_inline_bg = p.code_inline_bg;
    syn_keyword = p.syn_keyword;
    syn_string = p.syn_string;
    syn_number = p.syn_number;
    syn_comment = p.syn_comment;
    syn_type = p.syn_type;
    syn_call = p.syn_call;
    ansi = p.ansi;
}

/// The seeds in play: the chosen theme's, else the house pair the
/// appearance asks for.
fn seeds(a: Appearance) Seeds {
    if (find(chosen)) |e| return e.seeds;
    return if (a == .dark) codegraff_dark else codegraff_light;
}

/// A palette, from its seeds.
fn palette(s: Seeds) Palette {
    @setEvalBranchQuota(10_000);
    var p: Palette = undefined;
    const white: Color = .{ .r = 1, .g = 1, .b = 1 };
    const black: Color = .{};
    const tone = if (s.dark) white else black;
    p.background = .hex(s.background);
    p.panel = .hex(s.shell);
    p.raised = .hex(s.raised);
    p.text = .hex(s.text);
    p.muted = .hex(s.muted);
    p.faint = .hex(s.faint);
    p.accent = .hex(s.accent);
    p.failure = .hex(s.danger);
    p.warning = .hex(s.warning);
    p.success = .hex(s.success);
    // Harness's derived roles, flattened onto the background.
    p.block_hover = p.background.mix(tone, if (s.dark) 0.07 else 0.05);
    p.block_selected = p.background.mix(p.accent, if (s.dark) 0.16 else 0.12);
    p.border = p.background.mix(tone, if (s.dark) 0.10 else 0.12);
    p.border_strong = p.background.mix(tone, if (s.dark) 0.18 else 0.22);
    p.solid = if (s.dark) Color.hex(0xebebef) else Color.hex(0x232328);
    p.input = if (s.dark) p.background.mix(p.raised, 0.72) else p.panel;
    // Amber takes dark text, in both (Harness's best-on color).
    p.on_accent = if (s.dark) p.background else p.text;
    p.agent = .hex(s.ansi[5]);
    p.cwd = .hex(s.ansi[4]);
    p.branch = p.success;
    p.shadow = .{ .a = if (s.dark) 0.5 else 0.14 };
    p.code_bg = if (s.dark) p.background.mix(black, 0.28) else p.panel;
    p.code_header = if (s.dark) p.panel else p.raised;
    p.code_inline = p.accent;
    p.code_inline_bg = p.raised;
    p.syn_comment = .hex(s.syntax[0]);
    p.syn_keyword = .hex(s.syntax[1]);
    p.syn_string = .hex(s.syntax[2]);
    p.syn_number = .hex(s.syntax[3]);
    p.syn_type = .hex(s.syntax[4]);
    p.syn_call = .hex(s.syntax[5]);
    for (&p.ansi, s.ansi) |*o, v| o.* = .hex(v);
    return p;
}

/// xterm's 256 colors: the 16, a 6×6×6 cube, 24 grays.
pub fn color256(i: u8) Color {
    if (i < 16) return ansi[i];
    if (i < 232) {
        const n = i - 16;
        const levels = [6]f32{ 0, 95, 135, 175, 215, 255 };
        return .{ .r = levels[n / 36] / 255, .g = levels[(n / 6) % 6] / 255, .b = levels[n % 6] / 255 };
    }
    const g = @as(f32, @floatFromInt(8 + 10 * @as(u32, i - 232))) / 255;
    return .{ .r = g, .g = g, .b = g };
}

/// nanoui's theme, in this palette.
pub fn ui() nanoui.ui.Theme {
    var t = if (dark) nanoui.ui.Theme.dark_theme else nanoui.ui.Theme.light;
    t.background = background;
    t.surface = panel;
    t.surface_hover = block_hover;
    t.text = text;
    t.muted = muted;
    t.border = border;
    t.accent = accent;
    t.accent_hover = accent.mix(text, 0.12);
    t.accent_text = on_accent;
    t.track = if (dark) raised else raised;
    t.danger = failure;
    t.success = success;
    t.shadow = shadow;
    t.font = font;
    t.mono_font = mono_font;
    return t;
}
