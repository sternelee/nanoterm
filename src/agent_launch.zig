//! Starting an agent: the command line of each, as Harness starts them.
const std = @import("std");
const agent_mod = @import("agent.zig");
const proc = @import("proc.zig");
const agents = @import("agents.zig");

/// Whether `which`'s CLI is installed (on PATH or where installers put it).
pub fn installed(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, which: agent_mod.Which) bool {
    if (which == .agent) return true;
    const path = agents.searchPath(arena, env.get("PATH") orelse "", env.get("HOME") orelse "/");
    return proc.which(arena, io, path, agents.info(which).cli) != null;
}

/// How to start each external agent: ACP over stdio, except Pi, whose own
/// RPC mode (`pi.zig`) nanoterm speaks directly. The built-in Agent runtime
/// never comes through this process launcher.
pub fn argv(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, which: agent_mod.Which, model: ?[]const u8) ![*:null]const ?[*:0]const u8 {
    const path = agents.searchPath(arena, env.get("PATH") orelse "", env.get("HOME") orelse "/");
    switch (which) {
        .pi => {
            // Pi's own RPC mode (`pi.zig`), not ACP: no adapter, no npx.
            // Its session is new each start (`--no-session`), like an ACP
            // session: the conversation lives in this pane.
            const bin = proc.which(arena, io, path, "pi") orelse return error.NotInstalled;
            if (model) |m| {
                const p = @import("pi.zig").providerId(m, "");
                if (p.provider.len > 0) return proc.cStrings(arena, &.{ bin, "--mode", "rpc", "--no-session", "--provider", p.provider, "--model", p.id });
                return proc.cStrings(arena, &.{ bin, "--mode", "rpc", "--no-session", "--model", p.id });
            }
            return proc.cStrings(arena, &.{ bin, "--mode", "rpc", "--no-session" });
        },
        .codex => {
            if (proc.which(arena, io, path, "codex-acp")) |bin| return proc.cStrings(arena, &.{bin});
            if (proc.which(arena, io, path, "codex") == null) return error.NotInstalled;
            const npx = proc.which(arena, io, path, "npx") orelse return error.NotInstalled;
            return proc.cStrings(arena, &.{ npx, "-y", "@agentclientprotocol/codex-acp@1.1.14" });
        },
        .opencode => return proc.cStrings(arena, &.{ proc.which(arena, io, path, "opencode") orelse return error.NotInstalled, "acp" }),
        .grok => return proc.cStrings(arena, &.{ proc.which(arena, io, path, "grok") orelse return error.NotInstalled, "--no-auto-update", "agent", "--no-leader", "stdio" }),
        .devin => return proc.cStrings(arena, &.{ proc.which(arena, io, path, "devin") orelse return error.NotInstalled, "acp" }),
        .hermes => return proc.cStrings(arena, &.{ proc.which(arena, io, path, "hermes") orelse return error.NotInstalled, "acp" }),
        .agent => unreachable,
        .claude => {
            if (proc.which(arena, io, path, "claude-agent-acp")) |bin| return proc.cStrings(arena, &.{bin});
            const node = proc.which(arena, io, path, "node") orelse return error.NotInstalled;
            const home = env.get("HOME") orelse "/";
            const base = try std.fs.path.join(arena, &.{ home, "Library/Application Support/Zed/external_agents/claude-agent-acp" });
            if (std.Io.Dir.cwd().openDir(io, base, .{ .iterate = true })) |dir_| {
                var dir = dir_;
                defer dir.close(io);
                var it = dir.iterate();
                var newest: ?[]const u8 = null;
                while (it.next(io) catch null) |e| {
                    if (e.kind != .directory) continue;
                    if (newest == null or std.mem.order(u8, e.name, newest.?) == .gt) newest = try arena.dupe(u8, e.name);
                }
                if (newest) |v| {
                    const entry = try std.fs.path.join(arena, &.{ base, v, "node_modules/@zed-industries/claude-agent-acp/dist/index.js" });
                    if (std.Io.Dir.cwd().access(io, entry, .{})) |_| return proc.cStrings(arena, &.{ node, entry }) else |_| {}
                }
            } else |_| {}
            const npx = proc.which(arena, io, path, "npx") orelse return error.NotInstalled;
            return proc.cStrings(arena, &.{ npx, "-y", "@zed-industries/claude-agent-acp" });
        },
    }
}

test "Pi starts in RPC mode, with the chosen model" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A PATH of stand-ins, so the test never starts a real agent.
    const dir = "/tmp/nanoterm-test-agent-launch";
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, dir ++ "/bin");
    for ([_][]const u8{ "pi", "npx" }) |name| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(arena, "{s}/bin/{s}", .{ dir, name }), .data = "#!/bin/sh\n", .flags = .{ .permissions = .executable_file } });
    }
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", dir);
    try env.put("PATH", dir ++ "/bin");

    // Pi is its own RPC client: `pi --mode rpc`, never an ACP adapter.
    const pi = try argv(arena, io, &env, .pi, null);
    try std.testing.expectEqualStrings(dir ++ "/bin/pi", std.mem.span(pi[0].?));
    try std.testing.expectEqualStrings("--mode", std.mem.span(pi[1].?));
    try std.testing.expectEqualStrings("rpc", std.mem.span(pi[2].?));
    try std.testing.expectEqualStrings("--no-session", std.mem.span(pi[3].?));
    try std.testing.expect(pi[4] == null);

    // A chosen model goes as Pi's own flags: provider and id apart.
    const pi_model = try argv(arena, io, &env, .pi, "openai/gpt-5");
    try std.testing.expectEqualStrings("--provider", std.mem.span(pi_model[4].?));
    try std.testing.expectEqualStrings("openai", std.mem.span(pi_model[5].?));
    try std.testing.expectEqualStrings("--model", std.mem.span(pi_model[6].?));
    try std.testing.expectEqualStrings("gpt-5", std.mem.span(pi_model[7].?));
    try std.testing.expect(pi_model[8] == null);

    try std.Io.Dir.cwd().deleteTree(io, dir);
}
