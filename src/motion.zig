//! Motion across the app, tuned in one place: a duration multiplier
//! (every effect's timings), an intensity multiplier (how far each one
//! goes), and the system's Reduce Motion turning them all off. What
//! Metalterm does with its motion settings, made one dial set every
//! animated thing obeys: new output settling in a glyph at a time, the
//! cursor springing between cells, a running block's bar breathing.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;

/// Set each frame by the root view, from the settings and the system.
pub var duration: f32 = 1;
pub var intensity: f32 = 1;
pub var reduce: bool = false;

pub fn apply(dur: f32, inten: f32, system_reduce: bool) void {
    duration = std.math.clamp(dur, 0.25, 2);
    intensity = std.math.clamp(inten, 0, 1.5);
    reduce = system_reduce;
}

/// Whether the effects run at all: Reduce Motion, or none asked for.
pub fn on() bool {
    return !reduce and intensity > 0.01;
}

/// How long one arrival takes to fade in, seconds.
pub fn fade() f32 {
    return 0.12 * duration;
}

/// A chunk that landed together still settles one glyph at a time: this
/// many seconds between glyphs, past which the rest of it lands at once.
pub const per_glyph = 0.003;
pub const stagger_cap = 16;

/// A glyph `i` into a chunk that landed at `at`.
pub fn glyphAt(at: f64, i: u32) f64 {
    return at + @as(f64, @floatFromInt(@min(i, stagger_cap))) * per_glyph * duration;
}

/// 0…1: how much of `at` has arrived by `now`, eased out — new output
/// and cells show up at `1 - intensity` and settle to full.
pub fn arrived(now: f64, at: f64) f32 {
    if (!on()) return 1;
    if (now <= at) return @max(0, 1 - intensity);
    const t: f32 = @floatCast((now - at) / fade());
    if (t >= 1) return 1;
    const e = 1 - (1 - t) * (1 - t);
    return @max(0, 1 - intensity * (1 - e));
}

/// A running thing breathes for its first `pulse_window` seconds, then
/// sits still — an animation that runs forever costs more than it shows.
/// Null once it has, or when motion is off: draw it as it rests.
pub const pulse_window = 10;
pub const pulse_period = 1.4;

pub fn pulse(now: f64, since: f64) ?f32 {
    if (!on()) return null;
    const t: f32 = @floatCast(now - since);
    if (!(t >= 0) or t > pulse_window) return null;
    const w: f32 = 0.55 + 0.45 * (0.5 + 0.5 * @as(f32, @floatCast(@sin(2 * std.math.pi * t / pulse_period))));
    return 1 - intensity * (1 - w);
}

/// When each watched thing last changed state, so a pulse follows the
/// change rather than the app's start. At most this many are watched —
/// session agents' status dots (blocks keep theirs on the Block) — the
/// stillest evicted when it fills: a full table never leaves a dot
/// pulsing forever.
const Watch = struct { id: u64, state: u32, since: f32 };
const watch_cap = 64;
var watches: [watch_cap]Watch = @splat(.{ .id = 0, .state = 0, .since = 0 });

/// `id`'s moment it flipped into `state` (the clock of `now`, seconds).
pub fn flipped(id: u64, state: u32, now: f32) f32 {
    for (&watches) |*w| {
        if (w.id == id) {
            if (w.state != state) {
                w.state = state;
                w.since = now;
            }
            return w.since;
        }
    }
    // A free slot, else the stillest's: the one that flipped longest
    // ago is the least likely to still be breathing.
    var oldest: *Watch = &watches[0];
    for (&watches) |*w| {
        if (w.id == 0) {
            oldest = w;
            break;
        }
        if (w.since < oldest.since) oldest = w;
    }
    oldest.* = .{ .id = id, .state = state, .since = now };
    return now;
}

/// Whether a line's arrivals have all landed — no frame is needed for them.
pub fn lineSettled(line_at: f64, fresh_at: f64, fresh_from: u32, now: f64) bool {
    const last = @max(line_at, if (fresh_from != std.math.maxInt(u32)) fresh_at else line_at);
    return !on() or now - last >= @as(f64, fade()) + per_glyph * stagger_cap * duration;
}

/// As many spans as a fading line is split into; past this the rest of
/// its base spans land as they are — whole spans append cleanly (each
/// covers bytes past the faded ones), so a pathological line shows its
/// tail at full alpha rather than allocating without bound.
const max_fade_spans = 512;

/// Spans over `text` with each byte's arrival faded in: the line's own
/// spans (`base`, find's and the colors') kept, bytes without one shown
/// as `plain`. The line arrived whole at `arrived`; bytes from
/// `fresh_from` were written again at `fresh_at`, and settle one glyph
/// at a time. Base spans untouched when everything has arrived.
pub fn arriveSpans(
    alloc: std.mem.Allocator,
    text: []const u8,
    base: []const ui.Span,
    plain: ui.Color,
    line_at: f64,
    fresh_at: f64,
    fresh_from: u32,
    now: f64,
) []const ui.Span {
    const settled = lineSettled(line_at, fresh_at, fresh_from, now);
    if (settled or text.len == 0) return base;

    const line_alpha = arrived(now, line_at);
    const byte_alpha = struct {
        fn go(n: f64, la: f32, f_at: f64, f_from: u32, i: usize) f32 {
            var a = la;
            if (f_from != std.math.maxInt(u32) and i >= f_from) a = @min(a, arrived(n, glyphAt(f_at, @intCast(i - f_from))));
            return a;
        }
    }.go;

    var out: std.ArrayList(ui.Span) = .empty;
    var next: usize = 0; // The first byte not covered yet.
    var b: usize = 0;
    while (b < text.len and out.items.len < max_fade_spans) {
        const sp: ?ui.Span = if (next < base.len and base[next].start <= b and b < base[next].end) base[next] else null;
        const start = b;
        const q = quant(byte_alpha(now, line_alpha, fresh_at, fresh_from, b));
        b += 1;
        while (b < text.len and out.items.len < max_fade_spans) : (b += 1) {
            const nq = quant(byte_alpha(now, line_alpha, fresh_at, fresh_from, b));
            const nsp: ?ui.Span = if (next < base.len and base[next].start <= b and b < base[next].end) base[next] else null;
            if (nq != q or (sp != null) != (nsp != null) or (sp != null and nsp != null and !sameSpan(sp.?, nsp.?))) break;
        }
        if (sp) |s| {
            if (b >= s.end) next += 1;
            const base_color = s.color orelse plain;
            out.append(alloc, .{
                .start = @intCast(start),
                .end = @intCast(b),
                .color = if (q >= 8) s.color else base_color.alpha(@as(f32, @floatFromInt(q)) / 8),
                .weight = s.weight,
                .italic = s.italic,
                .underline = s.underline,
                .strike = s.strike,
            }) catch return base;
        } else if (q < 8) {
            // Bytes the line left its own color: dimmed as they arrive.
            out.append(alloc, .{
                .start = @intCast(start),
                .end = @intCast(b),
                .color = plain.alpha(@as(f32, @floatFromInt(q)) / 8),
            }) catch return base;
        }
    }
    // The rest of the base spans, past the text's fading bytes.
    if (next < base.len) out.appendSlice(alloc, base[next..]) catch return base;
    return out.items;
}

/// Eight steps of arrival: as few spans as read as smooth.
fn quant(a: f32) u4 {
    return @intFromFloat(std.math.clamp(a * 8, 0, 8));
}

fn sameSpan(a: ui.Span, b: ui.Span) bool {
    return a.weight == b.weight and a.italic == b.italic and a.underline == b.underline and a.strike == b.strike and std.meta.eql(a.color, b.color);
}

/// The dials as they were, for a test to put back however it ends.
const Dials = struct { d: f32, i: f32, r: bool };

fn dials() Dials {
    return .{ .d = duration, .i = intensity, .r = reduce };
}

test "arrivals settle from dim to full" {
    const saved = dials();
    defer {
        duration = saved.d;
        intensity = saved.i;
        reduce = saved.r;
    }
    apply(1, 1, false);
    const at: f64 = 10;
    try std.testing.expectApproxEqAbs(@as(f32, 0), arrived(at, at), 0.001);
    // A quarter of the way through a 0.12s fade, eased out: 43.75%.
    try std.testing.expectApproxEqAbs(@as(f32, 0.4375), arrived(at + 0.03, at), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), arrived(at + 0.06, at), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), arrived(at + 0.5, at), 0.001);
    // Half intensity: half the fade.
    apply(1, 0.5, false);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), arrived(at, at), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), arrived(at + 0.2, at), 0.001);
    // The per-glyph stagger caps at 16 glyphs: everything past them
    // lands together.
    apply(1, 1, false);
    try std.testing.expectApproxEqAbs(at, glyphAt(at, 0), 0.001);
    try std.testing.expectEqual(glyphAt(at, 16), glyphAt(at, 160));
}

test "the pulse breathes ten seconds, then rests" {
    const saved = dials();
    defer {
        duration = saved.d;
        intensity = saved.i;
        reduce = saved.r;
    }
    apply(1, 1, false);
    const since: f64 = 100;
    try std.testing.expect(pulse(since, since) != null);
    try std.testing.expect(pulse(since + 9.9, since) != null);
    // The window's last moment still breathes; past it, rest.
    try std.testing.expect(pulse(since + 10.0, since) != null);
    try std.testing.expect(pulse(since + 10.1, since) == null);
    try std.testing.expect(pulse(since - 1, since) == null);
    const a = pulse(since, since).?;
    const b = pulse(since + @as(f64, pulse_period) / 4, since).?;
    try std.testing.expect(a < b); // It breathes up over a quarter period.
    apply(1, 1, true);
    try std.testing.expect(pulse(since, since) == null);
}

test "Reduce Motion and zero intensity show everything, still" {
    const saved = dials();
    defer {
        duration = saved.d;
        intensity = saved.i;
        reduce = saved.r;
    }
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = [_]ui.Span{.{ .start = 0, .end = 2, .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 } }};
    // The system asked for stillness: everything lands at once.
    apply(1, 1, true);
    try std.testing.expect(!on());
    try std.testing.expectApproxEqAbs(@as(f32, 1), arrived(10, 10), 0.001);
    try std.testing.expect(lineSettled(10, 10, 0, 10));
    try std.testing.expect(pulse(10, 10) == null);
    try std.testing.expectEqualSlices(ui.Span, &base, arriveSpans(a, "hi", &base, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, 10, 10, 0, 10));
    // So does an intensity of zero: the dial, not the system.
    apply(1, 0, false);
    try std.testing.expect(!on());
}

test "watches note the moment a state flips into it" {
    const t: f32 = 5;
    try std.testing.expectApproxEqAbs(t, flipped(0xfeed, 3, t), 0.001);
    try std.testing.expectApproxEqAbs(t, flipped(0xfeed, 3, t + 1), 0.001);
    try std.testing.expectApproxEqAbs(t + 2, flipped(0xfeed, 4, t + 2), 0.001);
}

test "a full watch table claims its stillest slot" {
    // Fill the table with states that all flipped at t = 1.
    var i: u64 = 0;
    while (i < watch_cap) : (i += 1) {
        _ = flipped(0x1000 + i, 1, 1);
    }
    // A newcomer at t = 100 evicts the stillest — and claims the slot,
    // so the pulse it starts runs from 100, not from every frame after.
    try std.testing.expectApproxEqAbs(@as(f32, 100), flipped(0xdead, 1, 100), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 100), flipped(0xdead, 1, 101), 0.001);
}

test "spans fade bytes that have not arrived" {
    const saved = dials();
    defer {
        duration = saved.d;
        intensity = saved.i;
        reduce = saved.r;
    }
    apply(1, 1, false);
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "hello";
    const plain = ui.Color{ .r = 1, .g = 1, .b = 1, .a = 1 };
    const now: f64 = 10;
    // Nothing arrived: every byte dimmed, in its own spans.
    const none = arriveSpans(a, text, &.{}, plain, now, now, 0, now);
    try std.testing.expect(none.len > 0);
    try std.testing.expectEqual(@as(u32, 0), none[0].start);
    // A settled line rewritten from byte 3 — a prompt redrawn — fades
    // only what the rewrite touched, from where it started.
    const fresh = arriveSpans(a, text, &.{}, plain, 0, now, 3, now);
    try std.testing.expectEqual(@as(usize, 1), fresh.len);
    try std.testing.expectEqual(@as(u32, 3), fresh[0].start);
    try std.testing.expectEqual(@as(u32, 5), fresh[0].end);
    try std.testing.expect(fresh[0].color.?.a < 0.01); // Byte 3 is at time 0 of its fade.
    // All arrived: the base spans come back untouched.
    const base = [_]ui.Span{.{ .start = 0, .end = 5, .color = .{ .r = 1, .g = 0, .b = 0, .a = 1 } }};
    try std.testing.expectEqualSlices(ui.Span, &base, arriveSpans(a, text, &base, plain, now, now, 0, now + 1));
}
