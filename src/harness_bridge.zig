//! The bridge between a pane's `Agent` and the harness adapters. It owns the
//! registry and the environment the agents are started in, and it points the
//! adapter at the sink that receives a turn's events.
const std = @import("std");
const types = @import("harness/types.zig");
const registry = @import("harness/registry.zig");

pub const HarnessBridge = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    built: registry.Built,
    env: std.process.Environ.Map,
    thread_id: []const u8,

    /// Builds the registry for one pane. `env` is the app's environment as
    /// "KEY=value" strings, the same ones the agents are started with.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, env: []const []const u8, thread_id: []const u8) !*HarnessBridge {
        const self = try gpa.create(HarnessBridge);
        errdefer gpa.destroy(self);
        self.gpa = gpa;
        self.io = io;
        self.env = .init(gpa);
        errdefer self.env.deinit();
        for (env) |entry| {
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
            try self.env.put(entry[0..eq], entry[eq + 1 ..]);
        }
        self.thread_id = try gpa.dupe(u8, thread_id);
        errdefer gpa.free(self.thread_id);
        self.built = try registry.init(gpa, io, &self.env);
        return self;
    }

    pub fn destroy(self: *HarnessBridge) void {
        self.built.deinit();
        self.gpa.free(self.thread_id);
        self.env.deinit();
        self.gpa.destroy(self);
    }

    pub fn has(self: *HarnessBridge, id: []const u8) bool {
        return self.built.get(id) != null;
    }

    /// Whether a follow-up can be folded into the turn running now.
    pub fn canSteer(self: *HarnessBridge, id: []const u8) bool {
        return self.built.registry.canSteer(id);
    }

    /// Sends a turn through `id`'s adapter, with `sink_ctx` as the context the
    /// caller's `on_event` is called with.
    pub fn sendTurn(self: *HarnessBridge, id: []const u8, sink_ctx: *anyopaque, input: *const types.SendTurnInput) !void {
        self.built.setSink(id, sink_ctx);
        try self.built.registry.sendTurn(input, id);
    }

    pub fn cancelTurn(self: *HarnessBridge, id: []const u8, session_id: []const u8) !void {
        try self.built.registry.cancelTurn(id, session_id);
    }

    /// Folds `input`'s text into the turn already running.
    pub fn steerTurn(self: *HarnessBridge, id: []const u8, sink_ctx: *anyopaque, input: *const types.SteerTurnInput) !void {
        self.built.setSink(id, sink_ctx);
        try self.built.registry.steerTurn(input, id);
    }

    pub fn stopSession(self: *HarnessBridge, id: []const u8, session_id: []const u8) !void {
        try self.built.registry.stopSession(id, session_id);
    }

    pub fn forgetSession(self: *HarnessBridge, id: []const u8, session_id: []const u8) !void {
        try self.built.registry.forgetSession(id, session_id);
    }

    pub fn respondApproval(self: *HarnessBridge, id: []const u8, session_id: []const u8, request_id: u32, decision: types.ApprovalDecision) !void {
        try self.built.registry.respondApproval(id, session_id, request_id, decision);
    }
};

test "the bridge reads the environment it was given" {
    const gpa = std.testing.allocator;
    const env = [_][]const u8{ "PATH=/usr/bin", "HOME=/tmp/me", "not-a-pair" };
    var bridge = try HarnessBridge.create(gpa, std.testing.io, &env, "thread-1");
    defer bridge.destroy();
    try std.testing.expectEqualStrings("/tmp/me", bridge.env.get("HOME").?);
    try std.testing.expectEqualStrings("thread-1", bridge.thread_id);
    try std.testing.expect(bridge.has(types.ids.hermes));
    try std.testing.expect(bridge.has(types.ids.claude));
}
