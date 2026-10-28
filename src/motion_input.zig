//! The composer's little motions: a soft flash where a glyph lands as
//! you type, and the glyphs Backspace takes falling away as they decay —
//! Metalterm's input animations, in a flash and drifting glyphs. What
//! the field itself draws (its text, its caret) stays the field's.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const motion = @import("motion.zig");

/// How long a deleted glyph decays, and a typed one flashes.
const decay_life = 0.30;
const flash_life = 0.16;
/// Glyphs alive at once (rapid Backspaces overlap); a burst caps at 12.
const glyph_cap = 24;
const burst_cap = 12;
/// Text longer than this isn't tracked: its edits animate as nothing.
const text_cap = 256;
/// One per pane's composer; past this, effects are skipped.
const slots_len = 8;

const Glyph = struct {
    bytes: [4]u8 = .{ 0, 0, 0, 0 },
    len: u8 = 0,
    /// Where it was, in view points (the window's), when it died.
    x: f32 = 0,
    y: f32 = 0,
    born: f64 = 0,
    seed: u32 = 0,
};

const Slot = struct {
    id: u64 = 0,
    /// The text as the last frame left it, to diff against.
    prev: [text_cap]u8 = undefined,
    prev_len: usize = 0,
    /// Whether `prev` holds a baseline at all — it does from the
    /// field's first frame, even empty (the pill starts blank), and
    /// stops when the cap resets it: what lands after that is the new
    /// baseline, not one glyph taken.
    seeded: bool = false,
    /// The caret as the last frame left it, to tell which way a delete
    /// went: past the run that disappeared, it was a Backspace.
    prev_caret: usize = 0,
    glyphs: [glyph_cap]Glyph = @splat(.{}),
    glyphs_len: usize = 0,
    flash_x: f32 = 0,
    flash_y: f32 = 0,
    flash_at: f64 = -1,
};

var slots: [slots_len]Slot = @splat(.{});

/// The input's effects for a frame: what its last edit left behind,
/// drawn over the field from the container it sits in. `origin` is that
/// container's content corner, in view points; `lh` its line height.
/// `ft` is nanoui's `FocusedText`; it isn't exported past the ui
/// module, so it is taken as anytype rather than named here.
pub fn fx(c: *ui.Context, ft: anytype, origin: ui.Point, lh: f32) void {
    const s = slotFor(ft.id);
    note(c, s, ft);
    draw(c, s, origin, lh);
}

fn slotFor(id: u64) *Slot {
    for (&slots) |*s| {
        if (s.id == id) return s;
        if (s.id == 0) {
            s.* = .{ .id = id };
            return s;
        }
    }
    // Full: borrow the first, as the least recently claimed.
    slots[0] = .{ .id = id };
    return &slots[0];
}

/// What changed between two texts: the run that disappeared is
/// `prev[p .. prev.len - q]`, and `new.len - q - p` bytes appeared.
const Diff = struct { p: usize = 0, q: usize = 0 };

fn diff(prev: []const u8, new: []const u8) Diff {
    var d = Diff{};
    while (d.p < prev.len and d.p < new.len and prev[d.p] == new[d.p]) d.p += 1;
    while (d.q < prev.len - d.p and d.q < new.len - d.p and prev[prev.len - 1 - d.q] == new[new.len - 1 - d.q]) d.q += 1;
    // Both ends on glyph boundaries, whatever the edit did to bytes.
    // (p can sit at prev.len — a pure insert — where there is no byte
    // to test, so that case short-circuits rather than reading past.)
    while (d.p > 0 and d.p < prev.len and (prev[d.p] & 0xc0) == 0x80) d.p -= 1;
    while (d.q > 0 and (prev[prev.len - d.q] & 0xc0) == 0x80) d.q -= 1;
    return d;
}

/// The field's text as this frame leaves it, against the last frame's:
/// what disappeared decays, what appeared flashes.
fn note(c: *ui.Context, s: *Slot, ft: anytype) void {
    const new = ft.text;
    if (new.len > text_cap) {
        // Too long to keep: stop tracking rather than misread edits.
        s.seeded = false;
        s.prev_len = 0;
        s.glyphs_len = 0;
        s.flash_at = -1;
        return;
    }
    if (!s.seeded) {
        // Nothing tracked yet — the field's first frame, or the cap's
        // reset behind it: its text is the baseline, not an edit.
        @memcpy(s.prev[0..new.len], new);
        s.prev_len = new.len;
        s.seeded = true;
        s.prev_caret = ft.caret;
        return;
    }
    const prev = s.prev[0..s.prev_len];
    const d = diff(prev, new);
    const removed = prev[d.p .. prev.len - d.q];
    const inserted_len = new.len - d.q - d.p;
    const now = c.time;
    if (removed.len > 0 and new.len > 0 and motion.on()) {
        // The caret sat past what went — Backspace, its glyphs behind —
        // else a forward or selection delete, its glyphs ahead. (A
        // field emptied whole — submit, Esc, select-all — bursts
        // nothing: it wasn't one glyph taken, it all went at once.)
        const backward = s.prev_caret >= d.p + removed.len;
        addBurst(c, s, removed, ft.caret_rect, backward, now);
    }
    if (inserted_len > 0 and motion.on()) {
        s.flash_x = ft.caret_rect.x;
        s.flash_y = ft.caret_rect.y;
        s.flash_at = now;
    }
    @memcpy(s.prev[0..new.len], new);
    s.prev_len = new.len;
    s.prev_caret = ft.caret;
}

fn addBurst(c: *ui.Context, s: *Slot, removed: []const u8, at: ui.Rect, backward: bool, now: f64) void {
    // A glyph at a time, each where it sat: back from the caret for a
    // Backspace, ahead for a forward delete. Widths from the composer's
    // own style, so they land on the line they left.
    const style = ui.TextStyle{ .size = 14.5, .mono = true };
    var it = std.unicode.Utf8View.initUnchecked(removed).iterator();
    var widths: [burst_cap]f32 = undefined;
    var bytes: [burst_cap][4]u8 = undefined;
    var lens: [burst_cap]u8 = undefined;
    var n: usize = 0;
    var total: f32 = 0;
    while (it.nextCodepointSlice()) |g| {
        if (n >= burst_cap) break;
        bytes[n] = .{ g[0], if (g.len > 1) g[1] else 0, if (g.len > 2) g[2] else 0, if (g.len > 3) g[3] else 0 };
        lens[n] = @intCast(g.len);
        widths[n] = c.text.width(g, style);
        total += widths[n];
        n += 1;
    }
    var x = if (backward) at.x - total else at.x;
    for (0..n) |i| {
        addGlyph(s, bytes[i], lens[i], x, at.y, now);
        x += widths[i];
    }
}

fn addGlyph(s: *Slot, bytes: [4]u8, len: u8, x: f32, y: f32, now: f64) void {
    if (s.glyphs_len < s.glyphs.len) {
        s.glyphs[s.glyphs_len] = .{ .bytes = bytes, .len = len, .x = x, .y = y, .born = now, .seed = @as(u32, bytes[0]) << 8 ^ @as(u32, len) ^ @as(u32, @intFromFloat(@abs(x * 16))) };
        s.glyphs_len += 1;
        return;
    }
    // Full: the oldest has decayed longest; it goes first.
    std.mem.copyForwards(Glyph, s.glyphs[0 .. s.glyphs.len - 1], s.glyphs[1..]);
    s.glyphs[s.glyphs.len - 1] = .{ .bytes = bytes, .len = len, .x = x, .y = y, .born = now, .seed = @as(u32, bytes[0]) << 8 ^ @as(u32, len) ^ @as(u32, @intFromFloat(@abs(x * 16))) };
}

fn draw(c: *ui.Context, s: *Slot, origin: ui.Point, lh: f32) void {
    if (!motion.on()) {
        s.glyphs_len = 0;
        s.flash_at = -1;
        return;
    }
    drawFlash(c, s, origin, lh);
    drawGlyphs(c, s, origin, lh);
}

/// A soft accent glow where a glyph landed, gone in a blink.
fn drawFlash(c: *ui.Context, s: *Slot, origin: ui.Point, lh: f32) void {
    const life = flash_life * motion.duration;
    const t: f32 = @floatCast((c.time - s.flash_at) / life);
    if (!(s.flash_at >= 0) or t < 0 or t >= 1) return;
    c.animationFrame();
    const a = 0.35 * @min(motion.intensity, 1) * (1 - t);
    const w = 3 + 10 * t;
    _ = c.leaf(.{
        .absolute = true,
        .offset = .{ .x = s.flash_x - w / 2 - origin.x, .y = s.flash_y - origin.y },
        .width = .{ .px = w },
        .height = .{ .px = lh },
        .radius = lh / 2,
        .background = theme.accent.alpha(a),
    }, .none, null);
}

/// The deleted glyphs: they drift apart and fall as they fade, what
/// Backspace took with it. What rests was never really deleted.
fn drawGlyphs(c: *ui.Context, s: *Slot, origin: ui.Point, lh: f32) void {
    const life = decay_life * motion.duration;
    var i: usize = 0;
    while (i < s.glyphs_len) {
        const g = &s.glyphs[i];
        const t: f32 = @floatCast((c.time - g.born) / life);
        if (t >= 1) {
            std.mem.copyForwards(Glyph, s.glyphs[i .. s.glyphs_len - 1], s.glyphs[i + 1 .. s.glyphs_len]);
            s.glyphs_len -= 1;
            continue;
        }
        i += 1;
        if (t < 0) continue;
        c.animationFrame();
        const e = 1 - (1 - t) * (1 - t); // The drift eases out…
        const fall = t * t; // …the fall eases in.
        const dx = (hash01(g.seed) * 2 - 1) * 24 * motion.intensity * e;
        const dy = fall * (10 + hash01(g.seed ^ 0x9e37) * 16) * motion.intensity;
        const a = std.math.pow(f32, 1 - t, 1.6);
        const style = ui.TextStyle{ .size = 14.5, .mono = true, .color = theme.text.alpha(a) };
        const w = c.text.width(g.bytes[0..g.len], style) + 2;
        _ = c.open(.{
            .absolute = true,
            .offset = .{ .x = g.x + dx - origin.x, .y = g.y + dy - origin.y },
            .width = .{ .px = w },
            .height = .{ .px = lh },
        }, null);
        ui.text(c, g.bytes[0..g.len], style);
        c.end();
    }
}

fn hash01(seed: u32) f32 {
    // A uint32 mix (SplitMix32) mapped to 0…1: deterministic drift.
    var z = seed +% 0x9e3779b9;
    z = (z ^ (z >> 16)) *% 0x85ebca6b;
    z = (z ^ (z >> 13)) *% 0xc2b2ae35;
    z = z ^ (z >> 16);
    return @as(f32, @floatFromInt(z >> 8)) / (1 << 24);
}

test "diff finds what an edit took and added" {
    // "hello world" → "hello worl": the common prefix runs to the 'd'.
    var d = diff("hello world", "hello worl");
    try std.testing.expectEqualStrings("d", "hello world"[d.p .. "hello world".len - d.q]);
    // A middle insert: "ab" → "aXb" takes 'X' alone.
    d = diff("ab", "aXb");
    try std.testing.expectEqualStrings("X", "aXb"[d.p .. "aXb".len - d.q]);
    // Multibyte: "héllo" → "héo" drops both l's, never é's last byte.
    d = diff("héllo", "héo");
    try std.testing.expectEqualStrings("ll", "héllo"[d.p .. "héllo".len - d.q]);
    // A pure insert at the end: p sits at prev.len without reading past.
    d = diff("ab", "abcd");
    try std.testing.expectEqual(@as(usize, 2), d.p);
    try std.testing.expectEqual(@as(usize, 0), d.q);
    // The field's first frame: everything appeared, nothing was taken.
    d = diff("", "hello");
    try std.testing.expectEqual(@as(usize, 0), d.p);
    try std.testing.expectEqual(@as(usize, 0), d.q);
}

test "hash01 spreads across the unit range" {
    var min: f32 = 1;
    var max: f32 = 0;
    for (0..100) |i| {
        const v = hash01(@intCast(i * 7919));
        min = @min(min, v);
        max = @max(max, v);
    }
    try std.testing.expect(min < 0.05 and max > 0.95);
}
