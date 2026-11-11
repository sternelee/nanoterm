//! Bridge between nanoterm's Agent and harness adapters.
//! This allows incremental migration from direct agent_claude.Client to harness-based providers.
const std = @import("std");
const harness_adapter = @import("harness/adapter.zig");
const harness_types = @import("harness/types.zig");
const agent = @import("agent.zig");

pub const HarnessBridge = struct {
    gpa: std.mem.Allocator,
    registry: harness_adapter.HarnessRegistry,
    adapter: ?*harness_adapter.HarnessAdapter = null,
    thread_id: []const u8,

    pub fn init(gpa: std.mem.Allocator, thread_id: []const u8) HarnessBridge {
        return .{
            .gpa = gpa,
            .registry = harness_adapter.HarnessRegistry.init(gpa),
            .thread_id = thread_id,
        };
    }

    pub fn deinit(b: *HarnessBridge) void {
        b.registry.deinit();
        b.gpa.free(b.thread_id);
    }

    pub fn registerClaude(b: *HarnessBridge, binary_path: []const u8) !void {
        const claude_provider = try b.gpa.create(@import("harness/providers/claude/claude.zig").ClaudeProvider);
        claude_provider.* = @import("harness/providers/claude/claude.zig").ClaudeProvider.init(b.gpa, binary_path);
        
        const claude_adapter = try b.gpa.create(@import("harness/providers/claude/claude_adapter.zig").ClaudeAdapter);
        claude_adapter.* = .{
            .provider = claude_provider,
            .thread_id = b.thread_id,
        };
        
        const adapter = try b.gpa.create(harness_adapter.HarnessAdapter);
        adapter.* = @import("harness/providers/claude/claude_adapter.zig").ClaudeAdapter.asHarnessAdapter(claude_adapter);
        
        try b.registry.register(b.gpa, adapter);
        b.adapter = adapter;
    }

    pub fn sendTurn(b: *HarnessBridge, session_id: []const u8, cwd: []const u8, text: []const u8, images: []const agent.Image, on_event: *const fn (ctx: *anyopaque, event: harness_types.HarnessEvent) void) !void {
        if (b.adapter == null) return error.NoAdapter;
        
        // Convert nanoterm images to harness images
        var harness_images = try std.ArrayList(harness_types.Image).initCapacity(b.gpa, images.len);
        defer harness_images.deinit(b.gpa);
        
        for (images) |im| {
            try harness_images.append(b.gpa, .{
                .name = try b.gpa.dupe(u8, im.name),
                .mime = try b.gpa.dupe(u8, im.mime),
                .data = try b.gpa.dupe(u8, im.data),
            });
        }
        
        const input = harness_types.SendTurnInput{
            .session_id = session_id,
            .cwd = cwd,
            .prompt = text,
            .images = harness_images.items,
            .on_event = on_event,
        };
        
        try b.adapter.?.send_turn(b.adapter.?.ctx, &input);
    }
};
