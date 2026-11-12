//! The adapters nanoterm knows, in one registry. Building it makes a provider
//! per agent and wraps each in its `HarnessAdapter`; `deinit` tears the whole
//! thing down, children included.
const std = @import("std");
const harness = @import("adapter.zig");
const types = @import("types.zig");
const acp_provider = @import("providers/acp/provider.zig");
const acp_adapter = @import("providers/acp/adapter.zig");
const claude = @import("providers/claude/claude.zig");
const claude_adapter = @import("providers/claude/claude_adapter.zig");
const hermes = @import("providers/hermes/hermes.zig");
const codex = @import("providers/codex/codex.zig");
const others = @import("providers/others.zig");
const pi = @import("providers/pi/pi.zig");
const pi_provider = @import("providers/pi/pi_provider.zig");
const pi_adapter = @import("providers/pi/pi_adapter.zig");
const codex_provider = @import("providers/codex/codex_provider.zig");
const codex_adapter = @import("providers/codex/codex_adapter.zig");

const AcpEntry = struct {
    provider: *acp_provider.Provider,
    adapter: *acp_adapter.AcpAdapter,
};

const ClaudeEntry = struct {
    provider: *claude.ClaudeProvider,
    adapter: *claude_adapter.ClaudeAdapter,
};

const PiEntry = struct {
    provider: *pi_provider.PiProvider,
    adapter: *pi_adapter.PiAdapter,
};

const CodexEntry = struct {
    provider: *codex_provider.CodexProvider,
    adapter: *codex_adapter.CodexAdapter,
};

/// A registry and everything it owns. Keep it alive as long as turns run.
pub const Built = struct {
    gpa: std.mem.Allocator,
    registry: harness.HarnessRegistry,
    acp: []AcpEntry,
    claude_entry: ?ClaudeEntry,
    pi_entry: ?PiEntry,
    codex_entry: ?CodexEntry,

    pub fn deinit(b: *Built) void {
        for (b.acp) |e| {
            e.provider.deinit();
            b.gpa.destroy(e.provider);
            b.gpa.destroy(e.adapter);
        }
        b.gpa.free(b.acp);
        if (b.claude_entry) |e| {
            e.provider.deinit();
            b.gpa.destroy(e.provider);
            b.gpa.destroy(e.adapter);
        }
        if (b.pi_entry) |e| {
            e.provider.deinit();
            b.gpa.destroy(e.provider);
            b.gpa.destroy(e.adapter);
        }
        if (b.codex_entry) |e| {
            e.provider.deinit();
            b.gpa.destroy(e.provider);
            b.gpa.destroy(e.adapter);
        }
        b.registry.deinit();
    }

    pub fn get(b: *Built, id: []const u8) ?*const harness.HarnessAdapter {
        return b.registry.get(id);
    }

    /// Points the adapter at `sink_ctx`, the context its `on_event` expects.
    pub fn setSink(b: *Built, id: []const u8, sink_ctx: *anyopaque) void {
        for (b.acp) |e| if (std.mem.eql(u8, e.provider.opts.id, id)) {
            e.adapter.sink_ctx = sink_ctx;
            return;
        };
        if (b.claude_entry) |e| if (std.mem.eql(u8, claude.id, id)) {
            e.adapter.sink_ctx = sink_ctx;
        };
        if (b.pi_entry) |e| if (std.mem.eql(u8, pi.id, id)) {
            e.adapter.sink_ctx = sink_ctx;
        };
        if (b.codex_entry) |e| if (std.mem.eql(u8, codex.id, id)) {
            e.adapter.sink_ctx = sink_ctx;
        };
    }
};

/// Every adapter nanoterm can drive: Claude Code, Codex, Hermes, and the other
/// ACP agents. A provider whose CLI is missing registers anyway and reports
/// `NotInstalled` when a turn starts, so the picker stays the same either way.
pub fn init(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) !Built {
    var registry = harness.HarnessRegistry.init(gpa);
    errdefer registry.deinit();

    var opts: std.ArrayList(acp_provider.Options) = .empty;
    defer opts.deinit(gpa);
    try opts.append(gpa, hermes.options());
    try opts.appendSlice(gpa, &others.all);

    const entries = try gpa.alloc(AcpEntry, opts.items.len);
    var built: usize = 0;
    errdefer {
        for (entries[0..built]) |e| {
            e.provider.deinit();
            gpa.destroy(e.provider);
            gpa.destroy(e.adapter);
        }
        gpa.free(entries);
    }
    for (opts.items, 0..) |o, i| {
        const p = try gpa.create(acp_provider.Provider);
        p.* = acp_provider.Provider.init(gpa, io, env, o);
        const a = try gpa.create(acp_adapter.AcpAdapter);
        a.* = .{ .provider = p };
        const h = a.harness();
        try registry.register(&h);
        entries[i] = .{ .provider = p, .adapter = a };
        built += 1;
    }

    const cp = try gpa.create(claude.ClaudeProvider);
    cp.* = claude.ClaudeProvider.init(gpa, io, env);
    const ca = try gpa.create(claude_adapter.ClaudeAdapter);
    ca.* = .{ .provider = cp };
    const ch = ca.harness();
    try registry.register(&ch);

    const pp = try gpa.create(pi_provider.PiProvider);
    pp.* = pi_provider.PiProvider.init(gpa, io, env);
    const pa = try gpa.create(pi_adapter.PiAdapter);
    pa.* = .{ .provider = pp };
    const ph = pa.harness();
    try registry.register(&ph);

    // Codex runs its own app-server, not an ACP adapter.
    const xp = try gpa.create(codex_provider.CodexProvider);
    xp.* = codex_provider.CodexProvider.init(gpa, io, env);
    const xa = try gpa.create(codex_adapter.CodexAdapter);
    xa.* = .{ .provider = xp };
    const xh = xa.harness();
    try registry.register(&xh);

    return .{
        .gpa = gpa,
        .registry = registry,
        .acp = entries,
        .claude_entry = .{ .provider = cp, .adapter = ca },
        .pi_entry = .{ .provider = pp, .adapter = pa },
        .codex_entry = .{ .provider = xp, .adapter = xa },
    };
}

test "the registry knows every provider" {
    const gpa = std.testing.allocator;
    var env: std.process.Environ.Map = .init(gpa);
    defer env.deinit();
    try env.put("HOME", "/tmp");
    try env.put("PATH", "/usr/bin");
    var built = try init(gpa, std.testing.io, &env);
    defer built.deinit();
    for ([_][]const u8{ types.ids.claude, types.ids.codex, types.ids.hermes, types.ids.opencode, types.ids.grok, types.ids.devin, types.ids.pi }) |id| {
        try std.testing.expect(built.get(id) != null);
    }
    const list = try built.registry.list();
    defer gpa.free(list);
    try std.testing.expectEqual(@as(usize, 7), list.len);
}
