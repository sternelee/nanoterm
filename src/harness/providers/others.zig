//! The remaining ACP agents nanoterm starts. They share the ACP provider;
//! only their command line differs, so each is one function and one entry in
//! `options`.
const std = @import("std");
const proc = @import("../../proc.zig");
const agents = @import("../../agents.zig");
const types = @import("../types.zig");
const provider = @import("acp/provider.zig");

fn which(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, name: []const u8) ![]const u8 {
    const path = agents.searchPath(arena, env.get("PATH") orelse "", env.get("HOME") orelse "/");
    return proc.which(arena, io, path, name) orelse error.NotInstalled;
}

pub fn opencode(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, model: ?[]const u8) ![]const []const u8 {
    _ = model;
    return arena.dupe([]const u8, &.{ try which(arena, io, env, "opencode"), "acp" });
}

pub fn grok(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, model: ?[]const u8) ![]const []const u8 {
    _ = model;
    return arena.dupe([]const u8, &.{ try which(arena, io, env, "grok"), "--no-auto-update", "agent", "--no-leader", "stdio" });
}

pub fn devin(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, model: ?[]const u8) ![]const []const u8 {
    _ = model;
    return arena.dupe([]const u8, &.{ try which(arena, io, env, "devin"), "acp" });
}

pub const all = [_]provider.Options{
    .{ .id = types.ids.opencode, .label = "opencode", .argv = opencode },
    .{ .id = types.ids.grok, .label = "Grok", .argv = grok },
    .{ .id = types.ids.devin, .label = "Devin", .argv = devin },
};

test "every other agent has an id, a label, and a command" {
    var seen: [all.len][]const u8 = undefined;
    for (all, 0..) |o, i| {
        try std.testing.expect(o.id.len > 0);
        try std.testing.expect(o.label.len > 0);
        for (seen[0..i]) |prior| try std.testing.expect(!std.mem.eql(u8, prior, o.id));
        seen[i] = o.id;
    }
    // Each starts its own CLI over ACP: a PATH of stand-ins, so the test
    // never starts a real agent.
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const dir = "/tmp/nanoterm-test-others";
    std.Io.Dir.cwd().deleteTree(std.testing.io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir ++ "/bin");
    for ([_][]const u8{ "opencode", "grok", "devin" }) |name| {
        try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fmt.allocPrint(a, "{s}/bin/{s}", .{ dir, name }), .data = "#!/bin/sh\n", .flags = .{ .permissions = .executable_file } });
    }
    var env: std.process.Environ.Map = .init(a);
    try env.put("PATH", dir ++ "/bin");
    try env.put("HOME", dir);
    for (all) |o| {
        const argv = try o.argv(a, std.testing.io, &env, null);
        try std.testing.expect(std.mem.endsWith(u8, argv[0], o.id));
    }
    try std.Io.Dir.cwd().deleteTree(std.testing.io, dir);
}
