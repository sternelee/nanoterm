const std = @import("std");
const harness_types = @import("harness/types.zig");
const harness_adapter = @import("harness/adapter.zig");
const claude_protocol = @import("harness/providers/claude/claude_protocol.zig");

test "harness types compile" {
    const event = harness_types.HarnessEvent{ .session_started = {} };
    _ = event;
}

test "harness registry basic operations" {
    const gpa = std.testing.allocator;
    var registry = harness_adapter.HarnessRegistry.init(gpa);
    defer registry.deinit();

    // Test empty registry
    try std.testing.expect(registry.get("claude") == null);
    const list = try registry.list();
    defer gpa.free(list);
    try std.testing.expect(list.len == 0);
}

test "runtime mode to permission mapping" {
    try std.testing.expectEqual(claude_protocol.ClaudePermissionMode.default, claude_protocol.runtimeModeToPermission(.default));
    try std.testing.expectEqual(claude_protocol.ClaudePermissionMode.plan, claude_protocol.runtimeModeToPermission(.plan));
    try std.testing.expectEqual(claude_protocol.ClaudePermissionMode.auto, claude_protocol.runtimeModeToPermission(.auto));
}

test "buildControlRequest initialize" {
    const gpa = std.testing.allocator;
    const req = try claude_protocol.buildControlRequest(gpa, "req1", .initialize);
    defer gpa.free(req);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, req, .{});
    defer parsed.deinit();
    try std.testing.expect(std.mem.eql(u8, claude_protocol.str(parsed.value, "type").?, "control_request"));
}
