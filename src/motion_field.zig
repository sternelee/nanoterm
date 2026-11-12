//! The composer's pastel effects — typing-animations' pastel.zig, fitted to
//! what nanoui draws: an ASCII field rippling under the words as you type,
//! letters that spring in where they land, deletions dissolving into the
//! field, ff-tracking's locking brackets over finished words, and a caret
//! that recoils from each knock and settles. What the field itself draws
//! (its text, its caret) stays the field's; this is the field under it and
//! the ink over it.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const motion = @import("motion.zig");
const motion_input = @import("motion_input.zig");

/// The ASCII field's cell, in points: a composer glyph wide, a line tall.
const cell_w = 7.0;
const cell_h = 12.0;
/// The field's extent in cells — the pill's content box and well past it,
/// so a splash at the caret can ripple past the words.
const FW = 200;
const FH = 24;
/// The ramp, faint to dense; below the first step nothing is drawn.
const RAMP = ".,:;t%SX8#@";
/// A 4×4 ordered dither, so neighbouring cells step down the ramp one at a
/// time instead of all flipping glyph together.
const BAYER = [16]f32{ 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

const text_cap = 256;
const slots_len = 8;
const pop_cap = 64;
const lock_cap = 12;
/// How long one lock lives: the word brackets snap shut, hold a beat and
/// are gone; a delete's bracket collapses quicker still. The tag and the
/// fade both read from here, so the three never drift apart.
fn lockLife(kind: u8) f32 {
    return if (kind == 2) 0.45 else 0.7;
}
/// The point of a lock's life where it stops holding and starts leaving.
const lock_fade_at = 0.55;
const fish_cap = 64;
const ripple_cap = 24;
const streak_cap = 8;
/// Glyphs one delete dissolves; a paste springs at most this many pops.
const burst_cap = 12;
const pop_burst_cap = 4;

/// A typed glyph springing in where it landed, over the one the field drew.
const Pop = struct {
    bytes: [4]u8 = .{ 0, 0, 0, 0 },
    len: u8 = 0,
    /// Where it sits, in view points, at its line's top.
    x: f32 = 0,
    y: f32 = 0,
    born: f64 = 0,
    hue: u8 = 0,
};

/// ff-tracking's brackets: kind 0 closes over a finished word, kind 1 marks
/// where a caret jump landed, kind 2 collapses over what a delete took.
const Lock = struct {
    x0: f32 = 0,
    y0: f32 = 0,
    x1: f32 = 0,
    y1: f32 = 0,
    born: f64 = 0,
    kind: u8 = 0,
    /// "X:col Y:line", worn by the newest one only.
    label: [20]u8 = @splat(0),
    label_len: u8 = 0,
};

/// A fish swimming through the field, its wake the ink it leaves behind.
const Fish = struct {
    x: f32 = 0,
    y: f32 = 0,
    vx: f32 = 0,
    vy: f32 = 0,
    /// How fast its heading turns, in radians a second.
    turn: f32 = 0,
    born: f64 = 0,
    life: f32 = 0.5,
    hue: u8 = 0,
};

const Ripple = struct {
    x: f32 = 0,
    y: f32 = 0,
    born: f64 = 0,
    power: f32 = 1,
    hue: u8 = 0,
};

/// The trail a caret jump or a Return cuts through the field.
const Streak = struct {
    x0: f32 = 0,
    y0: f32 = 0,
    x1: f32 = 0,
    y1: f32 = 0,
    born: f64 = 0,
};

const Slot = struct {
    id: u64 = 0,
    /// The text as the last frame left it, to diff against.
    prev: [text_cap]u8 = undefined,
    prev_len: usize = 0,
    seeded: bool = false,
    /// The caret as the last frame left it: a jump is told from a nudge,
    /// a delete's direction from where it sat.
    prev_caret: usize = 0,
    prev_caret_rect: ui.Rect = .{},
    /// The pill's content corner, in view points — where cell (0, 0) sits.
    origin: ui.Point = .{ .x = 0, .y = 0 },
    last_t: f64 = -1,
    /// A counter the deterministic hash spreads into "random" kicks.
    rng: u32 = 0,

    /// The field: how inky each cell is, and in whose color.
    ink: [FW * FH]f32 = @splat(0),
    hue: [FW * FH]u8 = @splat(0),
    /// The inked cells' bounds, in cell coordinates; empty when ax1 <= ax0.
    ax0: u16 = 0,
    ay0: u16 = 0,
    ax1: u16 = 0,
    ay1: u16 = 0,

    pops: [pop_cap]Pop = @splat(.{}),
    pops_len: usize = 0,
    locks: [lock_cap]Lock = @splat(.{}),
    locks_len: usize = 0,
    fish: [fish_cap]Fish = @splat(.{}),
    fish_len: usize = 0,
    ripples: [ripple_cap]Ripple = @splat(.{}),
    ripples_len: usize = 0,
    streaks: [streak_cap]Streak = @splat(.{}),
    streaks_len: usize = 0,

    /// Keystrokes in a quick row, each a little bigger than the last.
    combo: u16 = 0,
    combo_t: f64 = -10,
    /// Which pop color the next word wears; a space turns it.
    hl: u8 = 0,
    /// The caret echo's springs: sideways recoil, the squash while keys are
    /// hot, and the shake that moves the whole fx layer.
    recoil: f32 = 0,
    recoil_v: f32 = 0,
    press: f32 = 0,
    press_v: f32 = 0,
    shx: f32 = 0,
    shx_v: f32 = 0,
    shy: f32 = 0,
    shy_v: f32 = 0,
    last_type: f64 = -10,
};

var slots: [slots_len]Slot = @splat(.{});

/// The field under the words, and the ink over them, for one frame. Called
/// inside the pill, before its text field: what is drawn first lies under.
/// `origin` is the pill's content corner, in view points.
pub fn under(c: *ui.Context, id: u64, origin: ui.Point, size: ui.Size) void {
    const s = find(id) orelse return;
    s.origin = origin;
    if (!motion.on()) return;
    step(c, s);
    // One stable wrapper, always opened: the cell count inside varies with
    // the field's bounds, and a varying child count would shift the ids of
    // the pill's later unkeyed children (their per-id state resets, and the
    // pill starts to breathe).
    _ = c.open(.{
        .absolute = true,
        .width = .{ .px = size.w },
        .height = .{ .px = size.h },
    }, null);
    drawField(c, s, size);
    c.end();
}

/// What this frame's edit left behind, drawn over the field. `size` is the
/// pill's content box; `submitted` says Return took the text this frame.
pub fn over(c: *ui.Context, ft: anytype, id: u64, origin: ui.Point, size: ui.Size, submitted: bool) void {
    const s = slotFor(id);
    s.origin = origin;
    if (!motion.on()) {
        // Motion off: keep the baseline current so re-enabling doesn't
        // read one huge edit, and drop whatever was mid-flight.
        reseed(s, ft);
        return;
    }
    note(c, s, ft, submitted);
    drawOver(c, s, origin, size, ft.caret_rect, ft.caret_rect.h);
}

fn find(id: u64) ?*Slot {
    for (&slots) |*s| {
        if (s.id == id) return s;
    }
    return null;
}

/// Whether any field still has live effects: the view tests use this to
/// tell pastel's layer apart from the field's own caret blinking.
pub fn activeAny() bool {
    for (&slots) |*s| {
        if (s.id == 0) continue;
        if (s.pops_len > 0 or s.locks_len > 0 or s.ripples_len > 0 or s.fish_len > 0 or s.streaks_len > 0 or s.ax1 > s.ax0) return true;
    }
    return false;
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

fn reseed(s: *Slot, ft: anytype) void {
    s.pops_len = 0;
    s.locks_len = 0;
    s.fish_len = 0;
    s.ripples_len = 0;
    s.streaks_len = 0;
    s.ink = @splat(0);
    s.ax1 = 0;
    s.ay1 = 0;
    s.seeded = false;
    noteBaseline(s, ft);
}

fn noteBaseline(s: *Slot, ft: anytype) void {
    if (ft.text.len > text_cap) {
        s.seeded = false;
        s.prev_len = 0;
        return;
    }
    @memcpy(s.prev[0..ft.text.len], ft.text);
    s.prev_len = ft.text.len;
    s.seeded = true;
    s.prev_caret = ft.caret;
    s.prev_caret_rect = ft.caret_rect;
}

/// One frame of the simulation: springs settle, fish swim and leave their
/// wake, the field fades. Everything is timed in seconds, stretched by the
/// motion duration and scaled by the intensity like the rest of the app.
fn step(c: *ui.Context, s: *Slot) void {
    const now = c.time;
    var dt: f32 = if (s.last_t < 0) 1.0 / 60.0 else @floatCast(now - s.last_t);
    s.last_t = now;
    dt = std.math.clamp(dt, 0, 0.05) * motion.duration;

    // The caret echo's recoil: knocked sideways, back in a beat.
    s.recoil_v += (-s.recoil * 2500 - s.recoil_v * 30) * dt;
    s.recoil += s.recoil_v * dt;
    // Its squash, held while the keys are hot.
    const goal: f32 = if (now - s.last_type < 0.12) 1 else 0;
    s.press_v += (-(s.press - goal) * 900 - s.press_v * 30) * dt;
    s.press += s.press_v * dt;
    // The shake: a knock moves the whole fx layer, the springs return it.
    s.shx_v += (-s.shx * 1600 - s.shx_v * 28) * dt;
    s.shx += s.shx_v * dt;
    s.shy_v += (-s.shy * 1600 - s.shy_v * 28) * dt;
    s.shy += s.shy_v * dt;

    var i: usize = 0;
    while (i < s.fish_len) {
        const f = &s.fish[i];
        const age: f32 = @floatCast(now - f.born);
        if (age >= f.life) {
            s.fish[i] = s.fish[s.fish_len - 1];
            s.fish_len -= 1;
            continue;
        }
        i += 1;
        const drag = @exp(-2.2 * dt);
        const ox = f.x;
        const oy = f.y;
        const cs = @cos(f.turn * dt);
        const sn = @sin(f.turn * dt);
        const nvx = f.vx * cs - f.vy * sn;
        const vy = f.vx * sn + f.vy * cs;
        f.vx = nvx * drag;
        f.vy = vy * drag;
        f.x += f.vx * dt;
        f.y += f.vy * dt;
        depositLine(s, ox, oy, f.x, f.y, 0.9 * (1 - age / f.life), f.hue);
    }

    fade(s, dt);
}

/// The field fades fast enough to keep up with the words; cells below the
/// dither's threshold go blank and the bounds empty when nothing is left.
fn fade(s: *Slot, dt: f32) void {
    if (s.ax1 <= s.ax0 or s.ay1 <= s.ay0) return;
    const keep = @exp(-dt * 6.5);
    var any = false;
    var cy: usize = s.ay0;
    while (cy < s.ay1) : (cy += 1) {
        var cx: usize = s.ax0;
        while (cx < s.ax1) : (cx += 1) {
            const i = cy * FW + cx;
            var v = s.ink[i] * keep;
            if (v < 0.05) v = 0 else any = true;
            s.ink[i] = v;
        }
    }
    if (!any) {
        s.ax0 = 0;
        s.ay0 = 0;
        s.ax1 = 0;
        s.ay1 = 0;
    }
}

/// What changed this frame, turned into the field's events: typed glyphs
/// pop and splash, deletions dissolve, a finished word locks its brackets,
/// a caret jump cuts a streak, Return washes the field with one big splash.
fn note(c: *ui.Context, s: *Slot, ft: anytype, submitted: bool) void {
    const new = ft.text;
    const now = c.time;
    if (new.len > text_cap) {
        // Too long to track: the next text is a baseline, not an edit.
        s.seeded = false;
        s.prev_len = 0;
        s.pops_len = 0;
        return;
    }
    if (!s.seeded) {
        noteBaseline(s, ft);
        return;
    }
    const prev = s.prev[0..s.prev_len];
    const d = motion_input.diff(prev, new);
    const removed = prev[d.p .. prev.len - d.q];
    const inserted = new[d.p .. new.len - d.q];
    if (submitted) {
        // Return: the line leaves with a splash, and the field rides the knock.
        splash(c, s, ft.caret_rect.x, ft.caret_rect.y + ft.caret_rect.h / 2, 1.0, 3);
        nudge(s, 0, 260);
    } else if (removed.len > 0 and new.len > 0) {
        // Backspace or a delete: the glyphs dissolve into the field.
        const backward = s.prev_caret >= d.p + removed.len;
        dissolve(c, s, removed, ft.caret_rect, backward);
    } else if (inserted.len > 0) {
        typeIn(c, s, new, d.p, inserted, ft.caret_rect);
    } else {
        // No edit: a caret that jumped — arrows, a click, Home — cuts a
        // streak from where it was to where it landed, and brackets mark
        // the landing.
        const dx = ft.caret_rect.x - s.prev_caret_rect.x;
        const dy = ft.caret_rect.y - s.prev_caret_rect.y;
        if (@abs(dx) > 70 or @abs(dy) > ft.caret_rect.h * 1.5) {
            addStreak(s, s.prev_caret_rect.x, s.prev_caret_rect.y + s.prev_caret_rect.h / 2, ft.caret_rect.x, ft.caret_rect.y + ft.caret_rect.h / 2, now);
            lockAt(s, ft.caret_rect.x - 4, ft.caret_rect.y, ft.caret_rect.x + 4, ft.caret_rect.y + ft.caret_rect.h, 1, new, ft.caret, now);
            splash(c, s, ft.caret_rect.x, ft.caret_rect.y + ft.caret_rect.h / 2, 0.7, 1);
        }
    }
    @memcpy(s.prev[0..new.len], new);
    s.prev_len = new.len;
    s.prev_caret = ft.caret;
    s.prev_caret_rect = ft.caret_rect;
}

/// A keystroke: the glyph springs in, the field splashes and ripples under
/// the caret, faster typing lands harder, and a word's end locks it up.
fn typeIn(c: *ui.Context, s: *Slot, text: []const u8, at_byte: usize, inserted: []const u8, at: ui.Rect) void {
    const now = c.time;
    if (now - s.combo_t < 0.26) s.combo += 1 else s.combo = 0;
    s.combo_t = now;
    const cl = @min(s.combo, 16);
    const power = 0.65 + @as(f32, @floatFromInt(cl)) * 0.035;
    s.last_type = now;
    s.press_v += 5;
    s.recoil_v += 240;
    nudge(s, (rnd(s) * 2 - 1) * 30, 70);

    // The glyphs that landed, where they sit: back from the caret.
    const style = ui.TextStyle{ .size = 14.5, .mono = true };
    var widths: [32]f32 = undefined;
    var bytes: [32][4]u8 = undefined;
    var lens: [32]u8 = undefined;
    var n: usize = 0;
    var total: f32 = 0;
    var it = std.unicode.Utf8View.initUnchecked(inserted).iterator();
    while (it.nextCodepointSlice()) |g| {
        if (n >= 32) break;
        bytes[n] = .{ g[0], if (g.len > 1) g[1] else 0, if (g.len > 2) g[2] else 0, if (g.len > 3) g[3] else 0 };
        lens[n] = @intCast(g.len);
        widths[n] = c.text.width(g, style);
        n += 1;
        total += widths[n - 1];
    }
    const shown = @min(n, pop_burst_cap);
    var x = at.x - total;
    for (0..n - shown) |i| x += widths[i];
    for (0..shown) |k| {
        const i = n - shown + k;
        addPop(s, bytes[i], lens[i], x, at.y, now, s.hl);
        x += widths[i];
    }

    // The splash under the caret, and the jolt running back through the field.
    splash(c, s, at.x, at.y + at.h / 2, power, 1 + cl / 6);
    depositLine(s, at.x - 3 * cell_w, at.y + at.h / 2, at.x, at.y + at.h / 2, 0.4 * power, s.hl);

    // A word's end: the space or punctuation that finished it locks it up.
    // The inserted run may end in several tail bytes (", "); walk back over
    // them to the word they closed, then back to where that word starts.
    const end = at_byte + inserted.len;
    var tail = end;
    while (tail > at_byte and !wordByte(text[tail - 1])) tail -= 1;
    if (tail > at_byte) {
        var a = tail;
        while (a > 0 and wordByte(text[a - 1])) a -= 1;
        const w_tail = c.text.width(text[tail..end], style);
        const w_word = c.text.width(text[a..tail], style);
        const x_end = at.x - w_tail;
        lockAt(s, x_end - w_word, at.y, x_end, at.y + at.h, 0, text, a, now);
    }
    // A space turns the color the next word wears.
    if (inserted[inserted.len - 1] == ' ') s.hl = (s.hl + 1) % 4;
}

/// A delete: rose blobs where the glyphs sat, fish sinking through them,
/// and a red bracket collapsing over the space they left.
fn dissolve(c: *ui.Context, s: *Slot, removed: []const u8, at: ui.Rect, backward: bool) void {
    const now = c.time;
    clearField(s);
    const style = ui.TextStyle{ .size = 14.5, .mono = true };
    var widths: [burst_cap]f32 = undefined;
    var n: usize = 0;
    var total: f32 = 0;
    var it = std.unicode.Utf8View.initUnchecked(removed).iterator();
    while (it.nextCodepointSlice()) |g| {
        if (n >= burst_cap) break;
        widths[n] = c.text.width(g, style);
        total += widths[n];
        n += 1;
    }
    var x = if (backward) at.x - total else at.x;
    for (0..n) |i| {
        const cx = x + widths[i] / 2;
        const cy = at.y + at.h / 2;
        depositBlob(s, cx, cy, 9, 1.0, 2);
        // One or two fish sink through each glyph's remains.
        const nf: usize = if (i % 2 == 0) 2 else 1;
        for (0..nf) |_| {
            addFish(s, cx, cy, (rnd(s) * 2 - 1) * 40, 60 + rnd(s) * 200, (rnd(s) * 2 - 1) * 2, 0.5 + rnd(s) * 0.4, 2, now);
        }
        x += widths[i];
    }
    const bx = if (backward) at.x - total else at.x;
    lockAt(s, bx - 2, at.y, bx + total + 2, at.y + at.h, 2, "", 0, now);
    s.recoil_v -= 200;
    nudge(s, if (rnd(s) < 0.5) -110 else 110, 20);
}

/// A splash at a point: a blob of ink, a ring running out of it, and a few
/// fish shooting off, the count and the force by how hard the key landed.
/// The last input alone leaves an afterimage: a fresh event wipes the
/// field's ink instead of stacking on what the previous keys left.
fn clearField(s: *Slot) void {
    s.ink = @splat(0);
    s.ax0 = 0;
    s.ay0 = 0;
    s.ax1 = 0;
    s.ay1 = 0;
}

fn splash(c: *ui.Context, s: *Slot, x: f32, y: f32, power: f32, nf: usize) void {
    const now = c.time;
    clearField(s);
    depositBlob(s, x, y, 13 * power, 0.95, s.hl);
    addRipple(s, x, y, power, s.hl, now);
    for (0..nf) |_| {
        const ang = rnd(s) * std.math.tau;
        const speed = 90 + rnd(s) * 130;
        addFish(s, x, y, @cos(ang) * speed, @sin(ang) * speed, (rnd(s) * 2 - 1) * 3, 0.35 + rnd(s) * 0.35, s.hl, now);
    }
}

// -- The field's ink -------------------------------------------------------

fn depositBlob(s: *Slot, x: f32, y: f32, r: f32, v: f32, hue: u8) void {
    const fx = (x - s.origin.x) / cell_w;
    const fy = (y - s.origin.y) / cell_h;
    const rx = @max(r / cell_w, 0.5);
    const ry = @max(r / cell_h, 0.5);
    const x0 = clampCell(fx - rx, FW);
    const x1 = clampCell(fx + rx, FW);
    const y0 = clampCell(fy - ry, FH);
    const y1 = clampCell(fy + ry, FH);
    var cy = y0;
    while (cy < y1) : (cy += 1) {
        var cx = x0;
        while (cx < x1) : (cx += 1) {
            const dx = (@as(f32, @floatFromInt(cx)) + 0.5 - fx) / rx;
            const dy = (@as(f32, @floatFromInt(cy)) + 0.5 - fy) / ry;
            const dist = @sqrt(dx * dx + dy * dy);
            if (dist >= 1) continue;
            const i = cy * FW + cx;
            const nv = v * (1 - dist);
            if (nv > s.ink[i]) {
                s.ink[i] = @min(nv, 1);
                s.hue[i] = hue;
            }
        }
    }
    growBounds(s, x0, y0, x1, y1);
}

fn depositLine(s: *Slot, x0: f32, y0: f32, x1: f32, y1: f32, v: f32, hue: u8) void {
    const dx = x1 - x0;
    const dy = y1 - y0;
    const len = @sqrt(dx * dx + dy * dy);
    const steps: usize = @min(@as(usize, @intFromFloat(len / (cell_w * 0.5))) + 1, 64);
    for (0..steps) |k| {
        const t = @as(f32, @floatFromInt(k)) / @as(f32, @floatFromInt(steps));
        depositBlob(s, x0 + dx * t, y0 + dy * t, cell_w * 0.8, v * 0.8, hue);
    }
}

fn clampCell(v: f32, cap: usize) usize {
    if (v <= 0) return 0;
    if (v >= @as(f32, @floatFromInt(cap))) return cap;
    return @intFromFloat(v);
}

fn growBounds(s: *Slot, x0: usize, y0: usize, x1: usize, y1: usize) void {
    const nx0: u16 = @intCast(x0);
    const ny0: u16 = @intCast(y0);
    const nx1: u16 = @intCast(x1);
    const ny1: u16 = @intCast(y1);
    if (s.ax1 <= s.ax0 or s.ay1 <= s.ay0) {
        s.ax0 = nx0;
        s.ay0 = ny0;
        s.ax1 = nx1;
        s.ay1 = ny1;
        return;
    }
    s.ax0 = @min(s.ax0, nx0);
    s.ay0 = @min(s.ay0, ny0);
    s.ax1 = @max(s.ax1, nx1);
    s.ay1 = @max(s.ay1, ny1);
}

// -- Spawners ---------------------------------------------------------------

fn addPop(s: *Slot, bytes: [4]u8, len: u8, x: f32, y: f32, now: f64, hue: u8) void {
    if (s.pops_len >= pop_cap) {
        std.mem.copyForwards(Pop, s.pops[0 .. pop_cap - 1], s.pops[1..pop_cap]);
        s.pops_len = pop_cap - 1;
    }
    s.pops[s.pops_len] = .{ .bytes = bytes, .len = len, .x = x, .y = y, .born = now, .hue = hue };
    s.pops_len += 1;
}

fn lockAt(s: *Slot, x0: f32, y0: f32, x1: f32, y1: f32, kind: u8, text: []const u8, at_byte: usize, now: f64) void {
    // One at a time: a fresh word's brackets take over from the last
    // word's, so the marks don't pile up behind the caret.
    if (kind == 0) {
        var i: usize = 0;
        while (i < s.locks_len) {
            if (s.locks[i].kind == 0) {
                s.locks[i] = s.locks[s.locks_len - 1];
                s.locks_len -= 1;
                continue;
            }
            i += 1;
        }
    }
    var label: [20]u8 = @splat(0);
    var label_len: u8 = 0;
    if (kind != 2) {
        const col, const line = lineCol(text, at_byte);
        const written = std.fmt.bufPrint(&label, "X:{d} Y:{d}", .{ col, line }) catch "";
        label_len = @intCast(written.len);
    }
    if (s.locks_len >= lock_cap) {
        std.mem.copyForwards(Lock, s.locks[0 .. lock_cap - 1], s.locks[1..lock_cap]);
        s.locks_len = lock_cap - 1;
    }
    s.locks[s.locks_len] = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .born = now, .kind = kind, .label = label, .label_len = label_len };
    s.locks_len += 1;
}

fn addFish(s: *Slot, x: f32, y: f32, vx: f32, vy: f32, turn: f32, life: f32, hue: u8, now: f64) void {
    if (s.fish_len >= fish_cap) {
        s.fish[0] = s.fish[s.fish_len - 1];
        s.fish_len -= 1;
    }
    s.fish[s.fish_len] = .{ .x = x, .y = y, .vx = vx, .vy = vy, .turn = turn, .born = now, .life = life, .hue = hue };
    s.fish_len += 1;
}

fn addRipple(s: *Slot, x: f32, y: f32, power: f32, hue: u8, now: f64) void {
    if (s.ripples_len >= ripple_cap) {
        s.ripples[0] = s.ripples[s.ripples_len - 1];
        s.ripples_len -= 1;
    }
    s.ripples[s.ripples_len] = .{ .x = x, .y = y, .born = now, .power = power, .hue = hue };
    s.ripples_len += 1;
}

fn addStreak(s: *Slot, x0: f32, y0: f32, x1: f32, y1: f32, now: f64) void {
    depositLine(s, x0, y0, x1, y1, 0.5, s.hl);
    if (s.streaks_len >= streak_cap) {
        s.streaks[0] = s.streaks[s.streaks_len - 1];
        s.streaks_len -= 1;
    }
    s.streaks[s.streaks_len] = .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .born = now };
    s.streaks_len += 1;
}

fn nudge(s: *Slot, dx: f32, dy: f32) void {
    const k = @min(motion.intensity, 1.5) * 2.5;
    s.shx_v += dx * k;
    s.shy_v += dy * k;
}

fn rnd(s: *Slot) f32 {
    s.rng +%= 0x9e37;
    return motion_input.hash01(s.rng);
}

// -- Drawing ----------------------------------------------------------------

/// The four pop colors: accent, agent, failure (rose, the deletions' too),
/// success. Hues cycle as words end; deletes are always hue 2.
fn popColor(hue: u8) ui.Color {
    return switch (hue) {
        0 => theme.accent,
        1 => theme.agent,
        2 => theme.failure,
        else => theme.success,
    };
}

/// Which ramp glyph a cell's ink earns, dithered so neighbours differ: 0
/// draws nothing, 1 is the faintest mark, RAMP.len the densest.
fn rampIndex(v: f32, cx: usize, cy: usize) usize {
    const d = BAYER[(cy % 4) * 4 + (cx % 4)] / 16 - 0.5;
    const scaled = v * @as(f32, @floatFromInt(RAMP.len)) + d;
    if (scaled <= 0) return 0;
    return 1 + @min(@as(usize, @intFromFloat(scaled)), RAMP.len - 1);
}

/// The field itself: one small glyph per inked cell, in the hue of whatever
/// put it there, shaken with the rest of the layer. Cells past the pill's
/// content box aren't drawn — the field lives under the words, not over
/// whatever is beside them.
fn drawField(c: *ui.Context, s: *Slot, size: ui.Size) void {
    if (s.ax1 <= s.ax0 or s.ay1 <= s.ay0) return;
    const inten = @min(motion.intensity, 1);
    const max_cx: usize = @min(@as(usize, @intFromFloat((size.w + cell_w) / cell_w)), FW);
    const max_cy: usize = @min(@as(usize, @intFromFloat((size.h + cell_h) / cell_h)), FH);
    var drew = false;
    var cy: usize = s.ay0;
    while (cy < s.ay1 and cy < max_cy) : (cy += 1) {
        var cx: usize = s.ax0;
        while (cx < s.ax1 and cx < max_cx) : (cx += 1) {
            const v = s.ink[cy * FW + cx];
            if (v <= 0) continue;
            const ri = rampIndex(v, cx, cy);
            if (ri == 0) continue;
            drew = true;
            const col = popColor(s.hue[cy * FW + cx]).alpha((0.35 + 0.45 * v) * inten);
            _ = c.open(.{
                .absolute = true,
                .offset = .{
                    .x = @as(f32, @floatFromInt(cx)) * cell_w + s.shx,
                    .y = @as(f32, @floatFromInt(cy)) * cell_h + s.shy,
                },
                .width = .{ .px = cell_w + 2 },
                .height = .{ .px = cell_h },
            }, null);
            ui.text(c, RAMP[ri - 1 .. ri], .{ .size = 10.5, .mono = true, .color = col });
            c.end();
        }
    }
    if (drew) c.animationFrame();
}

/// The ink over the words: ripples, streaks, the locks and their tags, the
/// fish, the caret's echo — one canvas for the vectors — then the pops.
fn drawOver(c: *ui.Context, s: *Slot, origin: ui.Point, size: ui.Size, caret: ui.Rect, lh: f32) void {
    const now = c.time;
    const inten = @min(motion.intensity, 1);
    // Room past the content box so a ring at the edge isn't cut off.
    const pad = 24;
    var vectors = false;
    for (s.ripples[0..s.ripples_len]) |*r| {
        if ((now - r.born) / (0.32 * motion.duration) < 1) vectors = true;
    }
    for (s.streaks[0..s.streaks_len]) |*k| {
        if ((now - k.born) / (0.22 * motion.duration) < 1) vectors = true;
    }
    for (s.locks[0..s.locks_len]) |*l| {
        const life: f32 = lockLife(l.kind);
        if ((now - l.born) / (life * motion.duration) < 1) vectors = true;
    }
    if (s.fish_len > 0) vectors = true;
    const echo_vis = @min(1, @abs(s.recoil) * 0.4 + s.press);
    if (echo_vis > 0.03) vectors = true;

    // Aging runs whether or not anything draws below: an item whose life
    // ends on a frame where nothing else moves must still drop, or it
    // would keep the layer "active" forever.
    sweep(s, now);

    if (vectors) {
        c.animationFrame();
        const cv = ui.canvas(c, .{
            .absolute = true,
            .offset = .{ .x = -pad, .y = -pad },
            .width = .{ .px = size.w + 2 * pad },
            .height = .{ .px = size.h + 2 * pad },
        });
        const px = struct {
            fn f(sl: *Slot, o: ui.Point, x: f32, y: f32, p: f32) ui.Point {
                return .{ .x = x - o.x + p + sl.shx, .y = y - o.y + p + sl.shy };
            }
        }.f;

        // Ripples: a ring running out of each splash, gone in a beat.
        const rlife = 0.32 * motion.duration;
        var i: usize = 0;
        while (i < s.ripples_len) {
            const r = &s.ripples[i];
            const t: f32 = @floatCast((now - r.born) / rlife);
            if (t >= 1) {
                s.ripples[i] = s.ripples[s.ripples_len - 1];
                s.ripples_len -= 1;
                continue;
            }
            i += 1;
            if (t < 0) continue;
            const ease = 1 - (1 - t) * (1 - t) * (1 - t);
            const rad = (5 + 55 * ease * r.power) * (0.5 + 0.5 * inten);
            cv.ring(px(s, origin, r.x, r.y, pad), rad, 1 + 7 * (1 - t), popColor(r.hue).alpha(0.85 * (1 - t) * inten));
        }

        // Streaks: the line a caret jump cut, fading as it goes.
        const slife = 0.22 * motion.duration;
        i = 0;
        while (i < s.streaks_len) {
            const k = &s.streaks[i];
            const t: f32 = @floatCast((now - k.born) / slife);
            if (t >= 1) {
                s.streaks[i] = s.streaks[s.streaks_len - 1];
                s.streaks_len -= 1;
                continue;
            }
            i += 1;
            if (t < 0) continue;
            cv.line(px(s, origin, k.x0, k.y0, pad), px(s, origin, k.x1, k.y1, pad), .{ .width = 2 * (1 - t), .color = theme.text.alpha(0.5 * (1 - t) * inten) });
        }

        // The locks: brackets closing over a finished word, marking where a
        // jump landed, collapsing over a delete. Red while they move, the
        // text's color once settled, then gone: short enough to read the
        // lock and clear the line again.
        i = 0;
        while (i < s.locks_len) {
            const l = &s.locks[i];
            const life: f32 = lockLife(l.kind) * motion.duration;
            const t: f32 = @floatCast((now - l.born) / life);
            if (t >= 1) {
                s.locks[i] = s.locks[s.locks_len - 1];
                s.locks_len -= 1;
                continue;
            }
            i += 1;
            if (t < 0) continue;
            drawLock(cv, s, l, t, origin, pad, inten);
        }

        // The fish: little arrows along their heading, fading as they swim.
        i = 0;
        while (i < s.fish_len) {
            const f = &s.fish[i];
            const age: f32 = @floatCast(now - f.born);
            const t = age / f.life;
            if (t >= 1) {
                s.fish[i] = s.fish[s.fish_len - 1];
                s.fish_len -= 1;
                continue;
            }
            i += 1;
            const sp = @sqrt(f.vx * f.vx + f.vy * f.vy) + 1e-3;
            const ux = f.vx / sp;
            const uy = f.vy / sp;
            const nose = px(s, origin, f.x + ux * 5, f.y + uy * 5, pad);
            const t1 = px(s, origin, f.x - ux * 2.5 - uy * 2.5, f.y - uy * 2.5 + ux * 2.5, pad);
            const t2 = px(s, origin, f.x - ux * 2.5 + uy * 2.5, f.y - uy * 2.5 - ux * 2.5, pad);
            cv.triangle(nose, t1, t2, popColor(f.hue).alpha(0.8 * (1 - t) * inten), 7);
        }

        // The caret's echo: a second caret the knocks throw sideways and the
        // recoil spring walks back over the field's own. Invisible at rest.
        if (echo_vis > 0.03) {
            const w = 2.5 * (1 - 0.3 * s.press);
            const p = px(s, origin, caret.x + 1 + s.recoil * 0.5, caret.y, pad);
            cv.rect(.{ .x = p.x, .y = p.y, .w = w, .h = lh }, theme.accent.alpha(echo_vis * 0.9), 1);
        }
    }

    drawPops(c, s, origin, lh);
    drawTags(c, s, origin);
}

/// Drop every timed-out ripple, streak, lock and fish. Runs before the
/// draw pass so expiry never depends on the frame happening to animate.
fn sweep(s: *Slot, now: f64) void {
    var i: usize = 0;
    while (i < s.ripples_len) {
        if ((now - s.ripples[i].born) / (0.32 * motion.duration) >= 1) {
            s.ripples[i] = s.ripples[s.ripples_len - 1];
            s.ripples_len -= 1;
            continue;
        }
        i += 1;
    }
    i = 0;
    while (i < s.streaks_len) {
        if ((now - s.streaks[i].born) / (0.22 * motion.duration) >= 1) {
            s.streaks[i] = s.streaks[s.streaks_len - 1];
            s.streaks_len -= 1;
            continue;
        }
        i += 1;
    }
    i = 0;
    while (i < s.locks_len) {
        const life: f32 = lockLife(s.locks[i].kind) * motion.duration;
        if ((now - s.locks[i].born) / life >= 1) {
            s.locks[i] = s.locks[s.locks_len - 1];
            s.locks_len -= 1;
            continue;
        }
        i += 1;
    }
    i = 0;
    while (i < s.fish_len) {
        if ((now - s.fish[i].born) / s.fish[i].life >= 1) {
            s.fish[i] = s.fish[s.fish_len - 1];
            s.fish_len -= 1;
            continue;
        }
        i += 1;
    }
}

/// One lock's brackets at age `t` (0…1 of its life).
fn drawLock(cv: *ui.Canvas, s: *Slot, l: *const Lock, t: f32, origin: ui.Point, pad: f32, inten: f32) void {
    const cx = (l.x0 + l.x1) / 2;
    const cy = (l.y0 + l.y1) / 2;
    var scale: f32 = 1;
    var a: f32 = 1;
    var col = theme.text;
    var hatch = false;
    if (l.kind == 2) {
        // A delete: the bracket collapses into the space the glyphs left.
        scale = 1 - 0.85 * t * t;
        a = 1 - t;
        col = theme.failure;
        hatch = t < 0.5;
    } else {
        // A word or a landing: the bracket snaps shut from wide, red while
        // it moves, then settles to the text's color and fades out late.
        const grow = @min(t / 0.35, 1);
        const ease = 1 - (1 - grow) * (1 - grow);
        scale = 1.8 - 0.8 * ease;
        hatch = t < 0.35;
        if (hatch) col = theme.failure;
        if (t > lock_fade_at) a = 1 - (t - lock_fade_at) / (1 - lock_fade_at);
    }
    const w = (l.x1 - l.x0) * scale;
    const h = (l.y1 - l.y0) * scale;
    const x0 = cx - w / 2;
    const y0 = cy - h / 2;
    const x1 = cx + w / 2;
    const y1 = cy + h / 2;
    const arm = @min(@min(w, h), 80) * 0.28;
    const th = 2;
    const fill = col.alpha(a * 0.9 * inten);
    cv.rect(.{ .x = x0 - origin.x + pad + s.shx, .y = y0 - origin.y + pad + s.shy, .w = arm, .h = th }, fill, 0);
    cv.rect(.{ .x = x0 - origin.x + pad + s.shx, .y = y0 - origin.y + pad + s.shy, .w = th, .h = arm }, fill, 0);
    cv.rect(.{ .x = x1 - arm - origin.x + pad + s.shx, .y = y0 - origin.y + pad + s.shy, .w = arm, .h = th }, fill, 0);
    cv.rect(.{ .x = x1 - th - origin.x + pad + s.shx, .y = y0 - origin.y + pad + s.shy, .w = th, .h = arm }, fill, 0);
    cv.rect(.{ .x = x0 - origin.x + pad + s.shx, .y = y1 - th - origin.y + pad + s.shy, .w = arm, .h = th }, fill, 0);
    cv.rect(.{ .x = x0 - origin.x + pad + s.shx, .y = y1 - arm - origin.y + pad + s.shy, .w = th, .h = arm }, fill, 0);
    cv.rect(.{ .x = x1 - arm - origin.x + pad + s.shx, .y = y1 - th - origin.y + pad + s.shy, .w = arm, .h = th }, fill, 0);
    cv.rect(.{ .x = x1 - th - origin.x + pad + s.shx, .y = y1 - arm - origin.y + pad + s.shy, .w = th, .h = arm }, fill, 0);
    if (hatch) {
        // Hatching while it moves: the word is still being tracked.
        const hc = theme.failure.alpha(0.12 * inten);
        var k: usize = 0;
        while (k < 4) : (k += 1) {
            const fx = x0 + w * @as(f32, @floatFromInt(k)) / 3;
            cv.line(.{ .x = fx - origin.x + pad + s.shx, .y = y0 - origin.y + pad + s.shy }, .{ .x = fx + h - origin.x + pad + s.shx, .y = y1 - origin.y + pad + s.shy }, .{ .width = 1, .color = hc });
        }
    }
}

/// The typed glyphs springing in: they drop the last few points into place,
/// bounce on a damped cosine, and cool from their pop color to the text's.
fn drawPops(c: *ui.Context, s: *Slot, origin: ui.Point, lh: f32) void {
    const now = c.time;
    const life = 0.45 * motion.duration;
    const inten = @min(motion.intensity, 1);
    var i: usize = 0;
    while (i < s.pops_len) {
        const p = &s.pops[i];
        const age: f32 = @floatCast(now - p.born);
        const t = age / life;
        if (t >= 1) {
            s.pops[i] = s.pops[s.pops_len - 1];
            s.pops_len -= 1;
            continue;
        }
        i += 1;
        if (t < 0) continue;
        c.animationFrame();
        var dy: f32 = 0;
        var sx: f32 = 1;
        var sy: f32 = 1;
        const fall = 0.05 * motion.duration;
        if (age < fall) {
            // The drop: from just above, stretching as it lands.
            const kf = age / fall;
            dy = -16 * (1 - kf) * (1 - kf);
            sx = 0.88;
            sy = 1.14;
        } else {
            // The bounce: a damped cosine, quick and small.
            const u = (age - fall) / motion.duration;
            const e = @exp(-12 * u) * @cos(30 * u);
            sy = 1 - 0.24 * e;
            sx = 1 + 0.18 * e;
        }
        const base = ui.TextStyle{ .size = 14.5, .mono = true };
        const w0 = c.text.width(p.bytes[0..p.len], base);
        const warm = @min(age / (0.35 * motion.duration), 1);
        const col = ui.Color.mix(popColor(p.hue), theme.text, warm).alpha((1 - t) * 0.9 * inten);
        const style = ui.TextStyle{ .size = 14.5 * sy, .mono = true, .weight = .bold, .color = col };
        _ = c.open(.{
            .absolute = true,
            .offset = .{
                .x = p.x - w0 * (sx - 1) / 2 - origin.x + s.shx,
                .y = p.y + dy + (lh - lh * sy) / 2 - origin.y + s.shy,
            },
            .width = .{ .px = w0 * sx + 2 },
            .height = .{ .px = lh },
        }, null);
        ui.text(c, p.bytes[0..p.len], style);
        c.end();
    }
}

/// The tag: only the newest lock that isn't a deletion wears its "X:col
/// Y:line" label, knocked out of a small filled pill above the bracket.
fn drawTags(c: *ui.Context, s: *Slot, origin: ui.Point) void {
    const now = c.time;
    const inten = @min(motion.intensity, 1);
    var newest: ?*const Lock = null;
    for (s.locks[0..s.locks_len]) |*l| {
        if (l.kind == 2) continue;
        const t: f32 = @floatCast((now - l.born) / (lockLife(l.kind) * motion.duration));
        if (t >= 1 or t < 0) continue;
        if (newest == null or l.born > newest.?.born) newest = l;
    }
    const l = newest orelse return;
    const t: f32 = @floatCast((now - l.born) / (lockLife(l.kind) * motion.duration));
    var a: f32 = 1;
    if (t > lock_fade_at) a = 1 - (t - lock_fade_at) / (1 - lock_fade_at);
    const label = l.label[0..l.label_len];
    const tw = c.text.width(label, .{ .size = 7, .mono = true }) + 6;
    _ = c.open(.{
        .absolute = true,
        .offset = .{
            .x = l.x1 - tw - origin.x + s.shx,
            .y = l.y0 - 11 - origin.y + s.shy,
        },
        .width = .{ .px = tw },
        .height = .{ .px = 10 },
        .radius = 2,
        .background = theme.failure.alpha(a * inten),
    }, null);
    ui.text(c, label, .{ .size = 7, .mono = true, .color = theme.background.alpha(a) });
    c.end();
}

// -- Small helpers ----------------------------------------------------------

/// Word characters for the bracket and the hue: ASCII letters, digits,
/// underscore, and anything multibyte (a non-ASCII word is still a word).
fn wordByte(b: u8) bool {
    return (b >= 'a' and b <= 'z') or (b >= 'A' and b <= 'Z') or (b >= '0' and b <= '9') or b == '_' or b >= 0x80;
}

/// Where a byte sits for the tag: its column on its line (0-based, as
/// ff-tracking counts) and which line that is (1-based).
fn lineCol(text: []const u8, at: usize) [2]usize {
    var line: usize = 1;
    var start: usize = 0;
    for (text[0..at], 0..) |ch, i| {
        if (ch == '\n') {
            line += 1;
            start = i + 1;
        }
    }
    return .{ at - start, line };
}

test "rampIndex dithers neighbours down the ramp" {
    // The same ink earns different glyphs in adjacent cells, and none at
    // the very bottom of the ramp.
    var differ = false;
    for (0..16) |cx| {
        if (rampIndex(0.3, cx, 0) != rampIndex(0.3, cx, 1)) differ = true;
    }
    try std.testing.expect(differ);
    try std.testing.expectEqual(@as(usize, 0), rampIndex(0.01, 0, 0));
    // Full ink is the densest glyph everywhere.
    for (0..4) |cx| {
        for (0..4) |cy| {
            try std.testing.expectEqual(@as(usize, RAMP.len), rampIndex(1, cx, cy));
        }
    }
}

test "a word is the word characters before the caret" {
    const text = "run git status";
    // The space after "status" finishes the word: the scan from the caret
    // walks back to where the word starts.
    var a: usize = 14;
    while (a > 0 and wordByte(text[a - 1])) a -= 1;
    try std.testing.expectEqualStrings("status", text[a..14]);
    try std.testing.expect(!wordByte(' '));
    try std.testing.expect(wordByte('_') and wordByte('7') and wordByte(0xc3));
}

test "lineCol counts lines and columns" {
    const col, const line = lineCol("ab\ncdef", 5);
    try std.testing.expectEqual(@as(usize, 2), col);
    try std.testing.expectEqual(@as(usize, 2), line);
    const col0, const line0 = lineCol("ab\ncdef", 1);
    try std.testing.expectEqual(@as(usize, 1), col0);
    try std.testing.expectEqual(@as(usize, 1), line0);
}

test "the recoil spring settles back to rest" {
    var s = Slot{ .id = 1 };
    s.recoil_v += 240;
    var t: f32 = 0;
    while (t < 2) : (t += 1.0 / 60.0) {
        const dt: f32 = 1.0 / 60.0;
        s.recoil_v += (-s.recoil * 2500 - s.recoil_v * 30) * dt;
        s.recoil += s.recoil_v * dt;
    }
    try std.testing.expect(@abs(s.recoil) < 0.01);
    try std.testing.expect(@abs(s.recoil_v) < 0.1);
}

test "a blob inks its cells and the bounds hold it" {
    var s = Slot{ .id = 1, .origin = .{ .x = 100, .y = 50 } };
    depositBlob(&s, 107, 56, 7, 1, 1);
    try std.testing.expect(s.ax1 > s.ax0 and s.ay1 > s.ay0);
    var inked: usize = 0;
    for (s.ink) |v| {
        if (v > 0) inked += 1;
    }
    try std.testing.expect(inked > 0 and inked < 16);
    try std.testing.expectEqual(@as(u8, 1), s.hue[s.ay0 * FW + s.ax0]);
    // Faded to nothing, the bounds empty themselves.
    fade(&s, 10);
    try std.testing.expectEqual(@as(u16, 0), s.ax1);
}

test "only the last input's afterimage stays: ink is wiped, the newest word lock replaces" {
    var s = Slot{ .id = 1, .origin = .{ .x = 100, .y = 50 } };
    // Two inputs in a row: the second's field holds only its own ink.
    depositBlob(&s, 107, 56, 7, 1, 1);
    clearField(&s);
    try std.testing.expectEqual(@as(u16, 0), s.ax1);
    for (s.ink) |v| try std.testing.expectEqual(@as(f32, 0), v);
    depositBlob(&s, 137, 56, 7, 1, 2);
    try std.testing.expectEqual(@as(u8, 2), s.hue[s.ay0 * FW + s.ax0]);

    // A finished word's brackets give way to the next word's.
    const text = "one two";
    lockAt(&s, 0, 0, 20, 10, 0, text, 3, 1.0);
    try std.testing.expectEqual(@as(usize, 1), s.locks_len);
    lockAt(&s, 30, 0, 50, 10, 0, text, 7, 2.0);
    try std.testing.expectEqual(@as(usize, 1), s.locks_len);
    try std.testing.expectEqual(@as(f64, 2.0), s.locks[0].born);
    // A delete's bracket is its own: it doesn't displace the word's.
    lockAt(&s, 30, 0, 50, 10, 2, text, 0, 3.0);
    try std.testing.expectEqual(@as(usize, 2), s.locks_len);
}
