//! What Settings (⌘,) keeps: the agent new tabs start with, the text
//! size, the input's editing keys, whether coding agents are on at all,
//! whether onboarding was done, and the
//! analytics choice (with the install's random id, sent only with it), in
//! `~/Library/Application Support/nanoterm/settings.json`; and which
//! external agents are installed, looked for when Settings opens.
const std = @import("std");
const agent_mod = @import("agent.zig");
const Which = agent_mod.Which;
const launch = @import("agent_launch.zig");

/// Whether anonymous usage analytics are shared: not asked yet, yes, no.
pub const Analytics = enum { unset, on, off };

pub const Prefs = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8 = "",
    agent: Which = .agent,
    zoom: f32 = 1,
    keys: @import("nanoui").ui.Keymap = .system,
    /// Coding agents at all: off, nanoterm is a terminal and nothing else
    /// (everything typed runs; nothing is classified or sent).
    agents: bool = true,
    onboarded: bool = false,
    analytics: Analytics = .unset,
    install_id: [32]u8 = @splat('0'),
    /// The terminal's font: empty is the system's monospaced face.
    terminal_font: []const u8 = "",
    /// Whether `ls` output gets a Nerd Font icon before each file.
    file_icons: bool = true,
    /// Motion's dials: every effect's timings scale by `motion_duration`,
    /// how far each goes by `motion_intensity`; the system's Reduce
    /// Motion turns them all off regardless.
    motion_duration: f32 = 1,
    motion_intensity: f32 = 1,
    installed: std.EnumArray(Which, bool) = .initFill(false),
    /// Anonymous usage analytics, sent only when `analytics` is on.
    telemetry: @import("analytics.zig").Client,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, arena: std.mem.Allocator, home: []const u8, env: *std.process.Environ.Map) Prefs {
        var p: Prefs = .{ .gpa = gpa, .io = io, .telemetry = .init(gpa, env) };
        p.terminal_font = gpa.dupe(u8, "JetBrains Mono") catch "";
        p.path = std.fs.path.join(arena, &.{ home, "Library", "Application Support", "nanoterm", "settings.json" }) catch "";
        const data = std.Io.Dir.cwd().readFileAlloc(io, p.path, gpa, .limited(64 * 1024)) catch return p;
        defer gpa.free(data);
        const S = struct { agent: []const u8 = "agent", zoom: f32 = 1, keys: []const u8 = "system", agents: bool = true, onboarded: bool = false, analytics: []const u8 = "unset", install_id: []const u8 = "", font: []const u8 = "JetBrains Mono", file_icons: bool = true, motion_duration: f32 = 1, motion_intensity: f32 = 1 };
        const parsed = std.json.parseFromSlice(S, gpa, data, .{ .ignore_unknown_fields = true }) catch return p;
        defer parsed.deinit();
        const v = parsed.value;
        p.agent = std.meta.stringToEnum(Which, v.agent) orelse .agent;
        p.zoom = std.math.clamp(v.zoom, 0.6, 2.4);
        p.keys = std.meta.stringToEnum(@TypeOf(p.keys), v.keys) orelse .system;
        p.agents = v.agents;
        p.onboarded = v.onboarded;
        p.analytics = std.meta.stringToEnum(Analytics, v.analytics) orelse .unset;
        p.setTerminalFont(v.font);
        p.file_icons = v.file_icons;
        p.motion_duration = std.math.clamp(v.motion_duration, 0.25, 2);
        p.motion_intensity = std.math.clamp(v.motion_intensity, 0, 1.5);
        if (v.install_id.len == p.install_id.len) @memcpy(&p.install_id, v.install_id);
        return p;
    }

    pub fn deinit(p: *Prefs) void {
        p.telemetry.deinit();
        if (p.terminal_font.len > 0) p.gpa.free(p.terminal_font);
    }

    /// Records an anonymous usage event, if the user shares analytics.
    pub fn track(p: *Prefs, event: []const u8, props: anytype) void {
        p.telemetry.track(p, event, props);
    }

    fn save(p: *Prefs) void {
        if (p.path.len == 0) return;
        if (std.fs.path.dirname(p.path)) |dir| std.Io.Dir.cwd().createDirPath(p.io, dir) catch {};
        var buf: [512]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\n  \"agent\": \"{s}\",\n  \"zoom\": {d:.2},\n  \"keys\": \"{s}\",\n  \"agents\": {},\n  \"onboarded\": {},\n  \"analytics\": \"{s}\",\n  \"install_id\": \"{s}\",\n  \"font\": \"{s}\",\n  \"file_icons\": {},\n  \"motion_duration\": {d:.2},\n  \"motion_intensity\": {d:.2}\n}}\n", .{ @tagName(p.agent), p.zoom, @tagName(p.keys), p.agents, p.onboarded, @tagName(p.analytics), &p.install_id, p.terminal_font, p.file_icons, p.motion_duration, p.motion_intensity }) catch return;
        std.Io.Dir.cwd().writeFile(p.io, .{ .sub_path = p.path, .data = json }) catch {};
    }

    /// The agent new tabs start with.
    pub fn setAgent(p: *Prefs, w: Which) void {
        if (p.agent == w) return;
        p.agent = w;
        p.save();
    }

    pub fn setKeys(p: *Prefs, k: @TypeOf(@as(Prefs, undefined).keys)) void {
        if (p.keys == k) return;
        p.keys = k;
        p.save();
    }

    pub fn setAgents(p: *Prefs, on: bool) void {
        if (p.agents == on) return;
        p.agents = on;
        p.save();
    }

    /// Onboarding is done (shown once).
    pub fn finishOnboarding(p: *Prefs) void {
        p.onboarded = true;
        p.save();
    }

    /// Shares anonymous usage analytics, or stops; a new random id the
    /// first time they're turned on.
    pub fn setAnalytics(p: *Prefs, a: Analytics, io: std.Io) void {
        if (a == .on and std.mem.allEqual(u8, &p.install_id, '0')) {
            var raw: [16]u8 = undefined;
            io.random(&raw);
            p.install_id = std.fmt.bytesToHex(raw, .lower);
        }
        p.analytics = a;
        p.save();
    }

    pub fn setZoom(p: *Prefs, z: f32) void {
        if (@abs(p.zoom - z) < 0.001) return;
        p.zoom = z;
        p.save();
    }

    /// The terminal's font; empty is the system's monospaced face.
    pub fn setTerminalFont(p: *Prefs, family: []const u8) void {
        if (std.mem.eql(u8, p.terminal_font, family)) return;
        const kept = p.gpa.dupe(u8, family) catch return;
        if (p.terminal_font.len > 0) p.gpa.free(p.terminal_font);
        p.terminal_font = kept;
        p.save();
    }

    /// Whether `ls` output gets a Nerd Font icon before each file.
    pub fn setFileIcons(p: *Prefs, on: bool) void {
        if (p.file_icons == on) return;
        p.file_icons = on;
        p.save();
    }

    /// Motion's dials; both are kept for the next launch.
    pub fn setMotion(p: *Prefs, dur: f32, inten: f32) void {
        const d = std.math.clamp(dur, 0.25, 2);
        const i = std.math.clamp(inten, 0, 1.5);
        if (@abs(p.motion_duration - d) < 0.001 and @abs(p.motion_intensity - i) < 0.001) return;
        p.motion_duration = d;
        p.motion_intensity = i;
        p.save();
    }

    /// Looks again for each agent's CLI.
    pub fn refresh(p: *Prefs, env: *std.process.Environ.Map) void {
        var arena: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena.deinit();
        for (std.enums.values(Which)) |w| p.installed.set(w, launch.installed(arena.allocator(), p.io, env, w));
    }
};

test "settings are kept across launches" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const home = "/tmp/nanoterm-test-settings";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var env: std.process.Environ.Map = .init(arena.allocator());
    {
        var p: Prefs = .init(gpa, io, arena.allocator(), home, &env);
        defer p.deinit();
        try std.testing.expectEqual(Which.agent, p.agent);
        p.setAgent(.codex);
        p.setZoom(1.2);
        p.setKeys(.vim);
        p.setAgents(false);
        p.setAnalytics(.on, io);
        p.setTerminalFont("JetBrainsMono Nerd Font");
        p.setFileIcons(false);
        p.setMotion(1.5, 0.5);
        p.finishOnboarding();
    }
    var p: Prefs = .init(gpa, io, arena.allocator(), home, &env);
    defer p.deinit();
    try std.testing.expectEqual(Which.codex, p.agent);
    try std.testing.expectApproxEqAbs(@as(f32, 1.2), p.zoom, 0.001);
    try std.testing.expectEqual(@import("nanoui").ui.Keymap.vim, p.keys);
    try std.testing.expect(!p.agents);
    try std.testing.expect(p.onboarded);
    try std.testing.expectEqual(Analytics.on, p.analytics);
    try std.testing.expectEqualStrings("JetBrainsMono Nerd Font", p.terminal_font);
    try std.testing.expect(!p.file_icons);
    try std.testing.expectApproxEqAbs(@as(f32, 1.5), p.motion_duration, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), p.motion_intensity, 0.001);
    try std.testing.expect(!std.mem.allEqual(u8, &p.install_id, '0'));
}
