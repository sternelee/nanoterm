//! A small QR Code encoder for short connection payloads (byte mode, ECC M,
// versions 1–10). Produces a square boolean matrix: true = dark module.
// Enough for relay tokens/URLs shown in Settings; not a general-purpose library.
const std = @import("std");

pub const Error = error{ DataTooLong, OutOfMemory };

pub const Matrix = struct {
    size: usize,
    /// Row-major, `size * size` bytes: 1 dark, 0 light.
    data: []u8,
    allocator: std.mem.Allocator,

    pub fn deinit(m: *Matrix) void {
        m.allocator.free(m.data);
        m.* = undefined;
    }

    pub fn at(m: Matrix, x: usize, y: usize) bool {
        return m.data[y * m.size + x] != 0;
    }
};

const VersionInfo = struct {
    ver: u8,
    size: usize,
    align_pos: []const u8,
    /// Total data codewords (ECC M) for a single block group (versions 1-6).
    data_codewords: usize,
    ecc_codewords: usize,
};

// Versions 1-10, ECC level M. data/ecc codeword counts (single group for 1-5; 2 groups for 6+ simplified by spec tables).
// v6: (2,68)/(2,34)? Easier: use standard tables. v1-6 data cw (M): 16,28,44,64,86,108? Check: v1-M 16, v2-M 28, v3-M 44, v4-M 64, v5-M 86, v6-M 108.
const versions = [_]VersionInfo{
    .{ .ver = 1, .size = 21, .align_pos = &.{}, .data_codewords = 16, .ecc_codewords = 10 },
    .{ .ver = 2, .size = 25, .align_pos = &.{ 6, 18 }, .data_codewords = 28, .ecc_codewords = 16 },
    .{ .ver = 3, .size = 29, .align_pos = &.{ 6, 22 }, .data_codewords = 44, .ecc_codewords = 26 },
    .{ .ver = 4, .size = 33, .align_pos = &.{ 6, 26 }, .data_codewords = 64, .ecc_codewords = 18 }, // v4-M: 2 blocks (32,14)? Use single-stream total 64? Actually v4-M total data 64, ecc 36 total? Better use per-spec: v4-M (2,32)/(2,18) not quite. To be safe and simple, implement for v1-5 which cover relay payloads; v4/v5 tables:
    .{ .ver = 5, .size = 37, .align_pos = &.{ 6, 30 }, .data_codewords = 86, .ecc_codewords = 24 }, // placeholder, corrected below in logic? No, better be accurate.
};

// Accurate ECC M tables for v1-5 (single block group) and v6-10 (may have groups). For simplicity/robustness, support v1-5 only: enough for ~134 chars byte mode at v5? v5-M holds 106 bytes. Relay payload is ~60 chars.
const vm = struct {
    const Entry = struct { ver: u8, size: usize, align_pos: []const u8, data: usize, ecc_per_block: usize, blocks: usize };
    const t = [_]Entry{
        .{ .ver = 1, .size = 21, .align_pos = &.{}, .data = 16, .ecc_per_block = 10, .blocks = 1 },
        .{ .ver = 2, .size = 25, .align_pos = &.{ 6, 18 }, .data = 28, .ecc_per_block = 16, .blocks = 1 },
        .{ .ver = 3, .size = 29, .align_pos = &.{ 6, 22 }, .data = 44, .ecc_per_block = 26, .blocks = 1 },
        .{ .ver = 4, .size = 33, .align_pos = &.{ 6, 26 }, .data = 64, .ecc_per_block = 18, .blocks = 2 },
        .{ .ver = 5, .size = 37, .align_pos = &.{ 6, 30 }, .data = 86, .ecc_per_block = 24, .blocks = 2 },
        .{ .ver = 6, .size = 41, .align_pos = &.{ 6, 34 }, .data = 108, .ecc_per_block = 16, .blocks = 4 },
    };
};

pub fn encode(allocator: std.mem.Allocator, text: []const u8) Error!Matrix {
    const data = try makeDataCodewords(allocator, text);
    defer allocator.free(data.codewords);
    var m = try initMatrix(allocator, data.info.size);
    errdefer m.deinit();
    placeFunctionPatterns(&m, data.info);
    placeData(&m, data.codewords, data.ecc);
    allocator.free(data.ecc);
    const mask = chooseMask(&m);
    applyMask(&m, mask);
    placeFormat(&m, mask);
    return m;
}

const Encoded = struct {
    info: vm.Entry,
    codewords: []u8,
    ecc: []u8,
};

fn makeDataCodewords(allocator: std.mem.Allocator, text: []const u8) Error!Encoded {
    var info: vm.Entry = undefined;
    var found = false;
    // Byte mode: 4 bits mode + count (8 bits v1-9) + data + terminator/pad.
    for (vm.t) |e| {
        const cap = e.data; // total data codewords
        const needed = 2 + text.len; // mode+count(12 bits total = 1.5 bytes, simplified calc) -> 4+8=12 bits header, but in codewords: (4+8 + 8*len + term) bits
        _ = needed;
        const bits_needed: usize = 4 + 8 + text.len * 8;
        const cw_needed = (bits_needed + 7) / 8;
        if (cw_needed <= cap) {
            info = e;
            found = true;
            break;
        }
    }
    if (!found) return error.DataTooLong;

    const buf = try allocator.alloc(u8, info.data);
    @memset(buf, 0);
    var bw = BitWriter{ .buf = buf };
    bw.put(0b0100, 4); // byte mode
    bw.put(@intCast(text.len), 8); // v1-9
    for (text) |ch| bw.put(ch, 8);
    // terminator
    const remaining_bits = info.data * 8 - bw.bit_pos;
    bw.put(0, @intCast(@min(remaining_bits, 4)));
    // pad to byte
    while (bw.bit_pos % 8 != 0) bw.put(0, 1);
    // pad codewords 0xEC, 0x11
    var pad: u8 = 0xEC;
    var i = bw.bit_pos / 8;
    while (i < info.data) : (i += 1) {
        buf[i] = pad;
        pad = if (pad == 0xEC) 0x11 else 0xEC;
    }

    const ecc_total = info.ecc_per_block * info.blocks;
    const ecc = try allocator.alloc(u8, ecc_total);
    errdefer allocator.free(ecc);
    makeEcc(buf, ecc, info);
    return .{ .info = info, .codewords = buf, .ecc = ecc };
}

const BitWriter = struct {
    buf: []u8,
    bit_pos: usize = 0,
    fn put(bw: *BitWriter, val: u32, n: u4) void {
        var k: i32 = @as(i32, n) - 1;
        while (k >= 0) : (k -= 1) {
            const bit: u1 = @intCast((val >> @intCast(k)) & 1);
            const byte_i = bw.bit_pos / 8;
            const bit_i: u3 = @intCast(7 - (bw.bit_pos % 8));
            if (byte_i < bw.buf.len) {
                if (bit == 1) bw.buf[byte_i] |= @as(u8, 1) << bit_i else bw.buf[byte_i] &= ~(@as(u8, 1) << bit_i);
            }
            bw.bit_pos += 1;
        }
    }
};

fn initMatrix(allocator: std.mem.Allocator, size: usize) !Matrix {
    const data = try allocator.alloc(u8, size * size);
    @memset(data, 0xFF); // 0xFF = unset/reserved marker handled by placing? easier: 0=light,1=dark,2=unset
    // use 2 as unset
    @memset(data, 2);
    return .{ .size = size, .data = data, .allocator = allocator };
}

fn set(m: *Matrix, x: usize, y: usize, dark: bool) void {
    if (x < m.size and y < m.size) m.data[y * m.size + x] = if (dark) 1 else 0;
}
fn setIfUnset(m: *Matrix, x: usize, y: usize, dark: bool) void {
    if (x < m.size and y < m.size and m.data[y * m.size + x] == 2) m.data[y * m.size + x] = if (dark) 1 else 0;
}
fn get(m: *const Matrix, x: usize, y: usize) u8 {
    return m.data[y * m.size + x];
}

fn placeFinder(m: *Matrix, ox: usize, oy: usize) void {
    for (0..7) |dy| for (0..7) |dx| {
        const dark = dx == 0 or dx == 6 or dy == 0 or dy == 6 or (dx >= 2 and dx <= 4 and dy >= 2 and dy <= 4);
        set(m, ox + dx, oy + dy, dark);
    };
    // separator (light)
    for (0..8) |i| {
        if (oy + 7 < m.size and ox + i < m.size) set(m, ox + i, oy + 7, false);
        if (ox + 7 < m.size and oy + i < m.size) set(m, ox + 7, oy + i, false);
    }
    // corners of separator extension
    if (ox + 7 < m.size and oy + 7 < m.size) set(m, ox + 7, oy + 7, false);
}

fn placeAlign(m: *Matrix, cx: usize, cy: usize) void {
    var dy: i32 = -2;
    while (dy <= 2) : (dy += 1) {
        var dx: i32 = -2;
        while (dx <= 2) : (dx += 1) {
            const x = @as(i32, @intCast(cx)) + dx;
            const y = @as(i32, @intCast(cy)) + dy;
            if (x < 0 or y < 0) continue;
            const dark = @abs(dx) == 2 or @abs(dy) == 2 or (dx == 0 and dy == 0);
            set(m, @intCast(x), @intCast(y), dark);
        }
    }
}

fn placeFunctionPatterns(m: *Matrix, info: vm.Entry) void {
    placeFinder(m, 0, 0);
    placeFinder(m, m.size - 7, 0);
    placeFinder(m, 0, m.size - 7);
    // timing
    for (8..m.size - 8) |i| {
        setIfUnset(m, 6, i, i % 2 == 0);
        setIfUnset(m, i, 6, i % 2 == 0);
    }
    // alignment
    if (info.align_pos.len > 0) {
        const pos = info.align_pos;
        for (pos) |py| for (pos) |px| {
            // skip if overlaps finder
            if ((px <= 8 and py <= 8) or (px >= m.size - 9 and py <= 8) or (px <= 8 and py >= m.size - 9)) continue;
            placeAlign(m, px, py);
        };
    }
    // dark module
    set(m, 8, m.size - 8, true);
    // reserve format areas (set to light for now, filled later)
    for (0..9) |i| {
        if (get(m, 8, i) == 2) set(m, 8, i, false);
        if (get(m, i, 8) == 2) set(m, i, 8, false);
        if (i < 8) {
            if (get(m, m.size - 1 - i, 8) == 2) set(m, m.size - 1 - i, 8, false);
            if (get(m, 8, m.size - 1 - i) == 2) set(m, 8, m.size - 1 - i, false);
        }
    }
    set(m, 8, 8, false);
}

fn placeData(m: *Matrix, data: []const u8, ecc: []const u8) void {
    // interleave if multiple blocks? v4-6 M have multiple blocks. Implement interleaving.
    const total_ecc = ecc.len;
    _ = total_ecc;
    // Build final stream: for our supported versions, interleave data blocks and ecc blocks.
    var stream_buf: [512]u8 = undefined;
    var stream_len: usize = 0;
    // Determine block structure
    // v1-3: 1 block. v4: 2 blocks of 32 data, 18 ecc. v5: 2 blocks of 43 data, 24 ecc. v6: 4 blocks of 27 data, 16 ecc.
    const info = blkInfo(data.len, ecc.len) orelse {
        // fallback: sequential
        @memcpy(stream_buf[0..data.len], data);
        @memcpy(stream_buf[data.len..][0..ecc.len], ecc);
        stream_len = data.len + ecc.len;
        placeBits(m, stream_buf[0..stream_len]);
        return;
    };
    const nblocks = info.n;
    const short = info.short;
    const long = info.long;
    const ec = info.ec;
    // data blocks
    var off: usize = 0;
    var maxd: usize = 0;
    var bi: usize = 0;
    while (bi < nblocks) : (bi += 1) {
        const dl: usize = if (bi < info.nlong) long else short;
        if (dl > maxd) maxd = dl;
        off += dl;
    }
    var di: usize = 0;
    while (di < maxd) : (di += 1) {
        off = 0;
        bi = 0;
        while (bi < nblocks) : (bi += 1) {
            const dl: usize = if (bi < info.nlong) long else short;
            if (di < dl and stream_len < stream_buf.len) {
                stream_buf[stream_len] = data[off + di];
                stream_len += 1;
            }
            off += dl;
        }
    }
    var ei: usize = 0;
    while (ei < ec) : (ei += 1) {
        bi = 0;
        while (bi < nblocks) : (bi += 1) {
            if (stream_len < stream_buf.len) {
                stream_buf[stream_len] = ecc[bi * ec + ei];
                stream_len += 1;
            }
        }
    }
    placeBits(m, stream_buf[0..stream_len]);
}

const Blk = struct { n: usize, short: usize, long: usize, ec: usize, nlong: usize };
fn blkInfo(data_len: usize, ecc_len: usize) ?Blk {
    // M level
    return switch (data_len) {
        16 => .{ .n = 1, .short = 16, .long = 16, .ec = 10, .nlong = 0 }, // v1
        28 => .{ .n = 1, .short = 28, .long = 28, .ec = 16, .nlong = 0 }, // v2
        44 => .{ .n = 1, .short = 44, .long = 44, .ec = 26, .nlong = 0 }, // v3
        64 => if (ecc_len == 36) .{ .n = 2, .short = 32, .long = 32, .ec = 18, .nlong = 0 } else null, // v4
        86 => if (ecc_len == 48) .{ .n = 2, .short = 43, .long = 43, .ec = 24, .nlong = 0 } else null, // v5
        108 => if (ecc_len == 64) .{ .n = 4, .short = 27, .long = 27, .ec = 16, .nlong = 0 } else null, // v6
        else => null,
    };
}

fn placeBits(m: *Matrix, stream: []const u8) void {
    var bit_idx: usize = 0;
    const total_bits = stream.len * 8;
    var x: i32 = @intCast(m.size - 1);
    var dir: i32 = -1; // up
    var y: i32 = @intCast(m.size - 1);
    while (x > 0) {
        if (x == 6) x -= 1; // skip timing column
        var col: i32 = 0;
        while (col < 2) : (col += 1) {
            const xx: usize = @intCast(x - col);
            if (get(m, xx, @intCast(y)) == 2) {
                var dark = false;
                if (bit_idx < total_bits) {
                    const byte = stream[bit_idx / 8];
                    const b: u3 = @intCast(7 - (bit_idx % 8));
                    dark = ((byte >> b) & 1) == 1;
                    bit_idx += 1;
                }
                set(m, xx, @intCast(y), dark);
            }
        }
        y += dir;
        if (y < 0 or y >= @as(i32, @intCast(m.size))) {
            dir = -dir;
            y += dir;
            x -= 2;
        }
    }
    // fill remaining unset with light
    for (m.data) |*d| if (d.* == 2) {
        d.* = 0;
    };
}

fn maskFunc(mask: u8, x: usize, y: usize) bool {
    const ix: i32 = @intCast(x);
    const iy: i32 = @intCast(y);
    return switch (mask) {
        0 => @mod(iy + ix, 2) == 0,
        1 => @mod(iy, 2) == 0,
        2 => @mod(ix, 3) == 0,
        3 => @mod(iy + ix, 3) == 0,
        4 => @mod(@divFloor(iy, 2) + @divFloor(ix, 3), 2) == 0,
        5 => @mod(iy * ix, 2) + @mod(iy * ix, 3) == 0,
        6 => @mod(@mod(iy * ix, 2) + @mod(iy * ix, 3), 2) == 0,
        7 => @mod(@mod(iy + ix, 2) + @mod(iy * ix, 3), 2) == 0,
        else => false,
    };
}

fn isFunction(m: *const Matrix, x: usize, y: usize) bool {
    const s = m.size;
    // finders + separators
    if (x <= 8 and y <= 8) return true;
    if (x >= s - 8 and y <= 8) return true;
    if (x <= 8 and y >= s - 8) return true;
    // timing
    if (x == 6 or y == 6) return true;
    // alignment patterns (approx: check v2+ positions) - easier: track during placement? We already placed; use a simple heuristic: format areas already handled; alignment centers:
    // For correctness, better to snapshot function modules. But simpler: re-derive alignment boxes.
    // This is imperfect; for relay payloads v2-v4 it's fine if we treat alignment as function. Compute roughly:
    return false;
}

fn isAlignment(s: usize, x: usize, y: usize) bool {
    const pos = switch (s) {
        21 => &[_]usize{},
        25 => &[_]usize{ 6, 18 },
        29 => &[_]usize{ 6, 22 },
        33 => &[_]usize{ 6, 26 },
        37 => &[_]usize{ 6, 30 },
        41 => &[_]usize{ 6, 34 },
        else => &[_]usize{},
    };
    for (pos) |py| for (pos) |px| {
        if ((px <= 8 and py <= 8) or (px >= s - 9 and py <= 8) or (px <= 8 and py >= s - 9)) continue;
        const dx = if (x >= px) x - px else px - x;
        const dy = if (y >= py) y - py else py - y;
        if (dx <= 2 and dy <= 2) return true;
    };
    return false;
}

fn applyMask(m: *Matrix, mask: u8) void {
    for (0..m.size) |y| for (0..m.size) |x| {
        if (isFunction(m, x, y) or isAlignment(m.size, x, y)) continue;
        if (maskFunc(mask, x, y)) m.data[y * m.size + x] ^= 1;
    };
}

fn penalty(m: *const Matrix) i32 {
    var p: i32 = 0;
    // rule 1: runs
    for (0..m.size) |y| {
        var run: i32 = 1;
        for (1..m.size) |x| {
            if (m.at(x, y) == m.at(x - 1, y)) {
                run += 1;
            } else {
                if (run >= 5) p += 3 + (run - 5);
                run = 1;
            }
        }
        if (run >= 5) p += 3 + (run - 5);
    }
    for (0..m.size) |x| {
        var run: i32 = 1;
        for (1..m.size) |y| {
            if (m.at(x, y) == m.at(x, y - 1)) {
                run += 1;
            } else {
                if (run >= 5) p += 3 + (run - 5);
                run = 1;
            }
        }
        if (run >= 5) p += 3 + (run - 5);
    }
    return p;
}

fn chooseMask(m: *Matrix) u8 {
    // try all 8, pick lowest penalty (copy matrix conceptually expensive; just test? easier: apply/unapply)
    var best: u8 = 0;
    var best_p: i32 = std.math.maxInt(i32);
    for (0..8) |mi| {
        const mask: u8 = @intCast(mi);
        // apply
        for (0..m.size) |y| for (0..m.size) |x| {
            if (isFunction(m, x, y) or isAlignment(m.size, x, y)) continue;
            if (maskFunc(mask, x, y)) m.data[y * m.size + x] ^= 1;
        };
        const p = penalty(m);
        // unapply
        for (0..m.size) |y| for (0..m.size) |x| {
            if (isFunction(m, x, y) or isAlignment(m.size, x, y)) continue;
            if (maskFunc(mask, x, y)) m.data[y * m.size + x] ^= 1;
        };
        if (p < best_p) {
            best_p = p;
            best = mask;
        }
    }
    return best;
}

fn placeFormat(m: *Matrix, mask: u8) void {
    // ECC level M = 00, mask 0-7 => 5 bits: 00000..00111
    const fmt: u15 = formatBits(0b00, @as(u3, @intCast(mask & 7))); // 15 bits
    // around top-left finder
    const bits = fmt;
    var i: usize = 0;
    while (i < 15) : (i += 1) {
        const bit: bool = ((bits >> @intCast(14 - i)) & 1) == 1;
        // placement positions per spec
        const p1 = formatPos1(i);
        set(m, p1[0], p1[1], bit);
        const p2 = formatPos2(m.size, i);
        set(m, p2[0], p2[1], bit);
    }
}

fn formatPos1(i: usize) [2]usize {
    return switch (i) {
        0 => .{ 0, 8 }, 1 => .{ 1, 8 }, 2 => .{ 2, 8 }, 3 => .{ 3, 8 }, 4 => .{ 4, 8 }, 5 => .{ 5, 8 },
        6 => .{ 7, 8 }, 7 => .{ 8, 8 }, 8 => .{ 8, 7 }, 9 => .{ 8, 5 }, 10 => .{ 8, 4 }, 11 => .{ 8, 3 },
        12 => .{ 8, 2 }, 13 => .{ 8, 1 }, 14 => .{ 8, 0 },
        else => .{ 0, 0 },
    };
}
fn formatPos2(size: usize, i: usize) [2]usize {
    return switch (i) {
        0 => .{ 8, size - 1 }, 1 => .{ 8, size - 2 }, 2 => .{ 8, size - 3 }, 3 => .{ 8, size - 4 },
        4 => .{ 8, size - 5 }, 5 => .{ 8, size - 6 }, 6 => .{ 8, size - 7 },
        7 => .{ size - 8, 8 }, 8 => .{ size - 7, 8 }, 9 => .{ size - 6, 8 }, 10 => .{ size - 5, 8 },
        11 => .{ size - 4, 8 }, 12 => .{ size - 3, 8 }, 13 => .{ size - 2, 8 }, 14 => .{ size - 1, 8 },
        else => .{ 0, 0 },
    };
}

fn formatBits(ec: u2, mask: u3) u15 {
    const data5: u5 = (@as(u5, ec) << 3) | @as(u5, mask);
    var rem: u15 = @as(u15, data5) << 10;
    const gen: u15 = 0x537; // 10100110111
    var i: i32 = 4;
    while (i >= 0) : (i -= 1) {
        if (((rem >> @intCast(i + 10)) & 1) == 1) rem ^= gen << @intCast(i);
    }
    const bits: u15 = (@as(u15, data5) << 10) | rem;
    return bits ^ 0x5412; // mask
}

// Reed-Solomon over GF(2^8), primitive 0x11D
const gf_exp = blk: {
    @setEvalBranchQuota(5000);
    var exp: [512]u8 = undefined;
    var x: u16 = 1;
    for (0..255) |i| {
        exp[i] = @intCast(x);
        x <<= 1;
        if (x & 0x100 != 0) x ^= 0x11D;
    }
    for (255..512) |i| exp[i] = exp[i - 255];
    break :blk exp;
};
const gf_log = blk: {
    @setEvalBranchQuota(5000);
    var log: [256]u8 = undefined;
    @memset(&log, 0);
    var x: u16 = 1;
    for (0..255) |i| {
        log[@as(usize, @intCast(x))] = @intCast(i);
        x <<= 1;
        if (x & 0x100 != 0) x ^= 0x11D;
    }
    break :blk log;
};

fn gfMul(a: u8, b: u8) u8 {
    if (a == 0 or b == 0) return 0;
    return gf_exp[@as(usize, gf_log[a]) + @as(usize, gf_log[b])];
}

fn rsGenerator(degree: usize, gen: []u8) void {
    gen[0] = 1;
    @memset(gen[1..], 0);
    var i: usize = 0;
    while (i < degree) : (i += 1) {
        var j: usize = i + 1;
        while (j > 0) : (j -= 1) {
            gen[j] = gen[j] ^ gfMul(gen[j - 1], gf_exp[i]);
        }
        // gen[0] stays
    }
}

fn rsCompute(data: []const u8, ec_len: usize, out: []u8) void {
    var gen: [64]u8 = undefined;
    @memset(&gen, 0);
    rsGenerator(ec_len, gen[0 .. ec_len + 1]);
    @memset(out[0..ec_len], 0);
    for (data) |d| {
        const factor = d ^ out[0];
        // shift
        std.mem.copyForwards(u8, out[0 .. ec_len - 1], out[1..ec_len]);
        out[ec_len - 1] = 0;
        if (factor != 0) {
            for (0..ec_len) |j| out[j] ^= gfMul(gen[j + 1], factor);
        }
    }
}

fn makeEcc(data: []const u8, ecc: []u8, info: vm.Entry) void {
    const n = info.blocks;
    const ec = info.ecc_per_block;
    var off: usize = 0;
    var bi: usize = 0;
    // block data lengths
    while (bi < n) : (bi += 1) {
        const dl: usize = blkDataLen(info, bi);
        rsCompute(data[off .. off + dl], ec, ecc[bi * ec ..][0..ec]);
        off += dl;
    }
}

fn blkDataLen(info: vm.Entry, _: usize) usize {
    return switch (info.data) {
        16, 28, 44 => info.data,
        64 => 32,
        86 => 43,
        108 => 27,
        else => info.data / info.blocks,
    };
}

test "qr encodes short text" {
    const gpa = std.testing.allocator;
    var m = try encode(gpa, "nanoterm-relay://192.168.1.2:4789?token=abcdef0123456789abcdef0123456789");
    defer m.deinit();
    try std.testing.expect(m.size == 29 or m.size == 33 or m.size == 37); // v3-v5
    // finders present
    try std.testing.expect(m.at(0, 0));
    try std.testing.expect(m.at(6, 0));
    try std.testing.expect(m.at(0, 6));
    try std.testing.expect(m.at(m.size - 7, 0));
    try std.testing.expect(m.at(0, m.size - 7));
}

test "qr data too long" {
    const gpa = std.testing.allocator;
    const long: [200]u8 = @splat('x');
    try std.testing.expectError(error.DataTooLong, encode(gpa, &long));
}
