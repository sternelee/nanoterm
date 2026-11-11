//! Claude Code protocol: spawn args, control channel, parsing.
const std = @import("std");
const types = @import("../../types.zig");

pub const ClaudePermissionMode = enum {
    default,
    plan,
    accept_edits,
    auto,
    bypass_permissions,
};

pub const ClaudeCliSettings = struct {
    disable_all_hooks: bool = false,
    always_thinking_enabled: bool = false,
    fast_mode: bool = false,
    ultracode: bool = false,
};

pub const ClaudeSpawnInput = struct {
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    resume_session: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    settings: ?ClaudeCliSettings = null,
    include_partial_messages: bool = true,
    max_turns: ?u32 = null,
    isolated: bool = false,
    permission_mode: ?ClaudePermissionMode = null,
};

pub const ControlRequest = union(enum) {
    initialize: void,
    list_models: void,
    set_model: struct { model: []const u8 },
};

pub const ControlResponse = struct {
    request_id: []const u8,
    response: ?std.json.Value = null,
};

pub fn runtimeModeToPermission(mode: types.RuntimeMode) ClaudePermissionMode {
    return switch (mode) {
        .default => .default,
        .supervised => .default,
        .plan => .plan,
        .auto => .auto,
    };
}

pub fn buildClaudeSpawnArgs(gpa: std.mem.Allocator, input: ClaudeSpawnInput) ![][]const u8 {
    var args = try std.ArrayList([]const u8).initCapacity(gpa, 16);
    defer args.deinit(gpa);

    try args.append(gpa, "--output-format");
    try args.append(gpa, "stream-json");
    try args.append(gpa, "--verbose");
    try args.append(gpa, "--input-format");
    try args.append(gpa, "stream-json");

    if (!input.isolated) {
        try args.append(gpa, "--permission-prompt-tool");
        try args.append(gpa, "stdio");
    }

    if (input.include_partial_messages) {
        try args.append(gpa, "--include-partial-messages");
    }

    const settings = if (input.isolated)
        ClaudeCliSettings{ .disable_all_hooks = true }
    else
        input.settings orelse ClaudeCliSettings{};

    if (input.isolated) {
        try args.append(gpa, "--no-session-persistence");
        try args.append(gpa, "--strict-mcp-config");
        {
            var mcp_writer = std.Io.Writer.Allocating.init(gpa);
            defer mcp_writer.deinit();
            try std.json.Stringify.value(.{ .mcp_servers = .{} }, .{}, &mcp_writer.writer);
            const mcp_config = try gpa.dupe(u8, mcp_writer.writer.buffered());
            try args.append(gpa, "--mcp-config");
            try args.append(gpa, mcp_config);
        }
        {
            var settings_writer = std.Io.Writer.Allocating.init(gpa);
            defer settings_writer.deinit();
            try std.json.Stringify.value(settings, .{}, &settings_writer.writer);
            const settings_json = try gpa.dupe(u8, settings_writer.writer.buffered());
            try args.append(gpa, "--settings");
            try args.append(gpa, settings_json);
        }
    } else {
        try args.append(gpa, "--setting-sources=user,project,local");
        {
            var settings_writer = std.Io.Writer.Allocating.init(gpa);
            defer settings_writer.deinit();
            try std.json.Stringify.value(settings, .{}, &settings_writer.writer);
            const settings_json = try gpa.dupe(u8, settings_writer.writer.buffered());
            try args.append(gpa, "--settings");
            try args.append(gpa, settings_json);
        }
    }

    if (input.model) |m| {
        try args.append(gpa, "--model");
        try args.append(gpa, m);
    }
    if (input.effort) |e| {
        try args.append(gpa, "--effort");
        try args.append(gpa, e);
    }
    if (input.permission_mode) |pm| {
        try args.append(gpa, "--permission-mode");
        try args.append(gpa, @tagName(pm));
    }
    if (input.permission_mode == .bypass_permissions) {
        try args.append(gpa, "--allow-dangerously-skip-permissions");
    }
    if (input.resume_session) |r| {
        try args.append(gpa, "--resume");
        try args.append(gpa, r);
    }
    if (input.session_id) |sid| {
        try args.append(gpa, "--session-id");
        try args.append(gpa, sid);
    }
    if (input.max_turns) |mt| {
        try args.append(gpa, "--max-turns");
        const s = try std.fmt.allocPrint(gpa, "{d}", .{mt});
        try args.append(gpa, s);
    }

    return args.toOwnedSlice(gpa);
}

pub fn buildControlRequest(gpa: std.mem.Allocator, request_id: []const u8, request: ControlRequest) ![]const u8 {
    const subtype = switch (request) {
        .initialize => "initialize",
        .list_models => "list_models",
        .set_model => "set_model",
    };
    var writer = std.Io.Writer.Allocating.init(gpa);
    defer writer.deinit();
    try std.json.Stringify.value(.{
        .type = "control_request",
        .request_id = request_id,
        .request = .{ .subtype = subtype },
    }, .{}, &writer.writer);
    return gpa.dupe(u8, writer.writer.buffered());
}

pub fn parseControlResponse(v: std.json.Value) ?ControlResponse {
    if (v != .object) return null;
    if (!std.mem.eql(u8, str(v, "type") orelse "", "control_response")) return null;
    return .{
        .request_id = str(v, "request_id") orelse "",
        .response = obj(v, "response"),
    };
}

pub fn listModelsFromControlResponse(v: std.json.Value, request_id: []const u8) ?[]std.json.Value {
    const resp = parseControlResponse(v) orelse return null;
    if (!std.mem.eql(u8, resp.request_id, request_id)) return null;
    const response = resp.response orelse return null;
    if (response != .object) return null;
    const data = obj(response, "data") orelse return null;
    if (data != .array) return null;
    return data.array.items;
}

pub fn isInitMessage(v: std.json.Value) bool {
    if (v != .object) return false;
    return std.mem.eql(u8, str(v, "type") orelse "", "system") and
           std.mem.eql(u8, str(v, "subtype") orelse "", "init");
}

pub fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

pub fn obj(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

test "buildControlRequest initialize" {
    const gpa = std.testing.allocator;
    const req = try buildControlRequest(gpa, "req1", .initialize);
    defer gpa.free(req);
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, req, .{});
    defer parsed.deinit();
    try std.testing.expect(std.mem.eql(u8, str(parsed.value, "type").?, "control_request"));
}
