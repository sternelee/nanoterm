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

    /// Claude's `--settings` wants camelCase keys.
    pub fn jsonStringify(s: ClaudeCliSettings, jw: anytype) !void {
        try jw.beginObject();
        if (s.disable_all_hooks) {
            try jw.objectField("disableAllHooks");
            try jw.write(true);
        }
        if (s.always_thinking_enabled) {
            try jw.objectField("alwaysThinkingEnabled");
            try jw.write(true);
        }
        if (s.fast_mode) {
            try jw.objectField("fastMode");
            try jw.write(true);
        }
        if (s.ultracode) {
            try jw.objectField("ultracode");
            try jw.write(true);
        }
        try jw.endObject();
    }
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

/// The kind a Claude tool name belongs to, as the view's buckets name it.
pub fn toolKind(name: []const u8) types.ToolKind {
    const eq = std.mem.eql;
    if (eq(u8, name, "Bash") or eq(u8, name, "BashOutput") or eq(u8, name, "KillShell")) return .execute;
    if (eq(u8, name, "Read") or eq(u8, name, "NotebookRead")) return .read;
    if (eq(u8, name, "Edit") or eq(u8, name, "Write") or eq(u8, name, "MultiEdit") or eq(u8, name, "NotebookEdit")) return .edit;
    if (eq(u8, name, "Grep") or eq(u8, name, "Glob") or eq(u8, name, "WebSearch")) return .search;
    if (eq(u8, name, "WebFetch")) return .fetch;
    if (eq(u8, name, "Task") or eq(u8, name, "TodoWrite")) return .think;
    return .other;
}

/// One stream-json message as harness events. A message with several content
/// blocks means several events; text and thinking arrive as deltas, a tool
/// call as a start, a tool result as an end.
pub fn mapMessage(arena: std.mem.Allocator, v: std.json.Value) []const types.HarnessEvent {
    const kind = str(v, "type") orelse return &.{};
    if (std.mem.eql(u8, kind, "system")) {
        if (!std.mem.eql(u8, str(v, "subtype") orelse "", "init")) return &.{};
        const sid = str(v, "session_id") orelse "";
        const out = arena.alloc(types.HarnessEvent, 2) catch return &.{};
        out[0] = .{ .session_provider_bound = sid };
        out[1] = .{ .session_started = {} };
        return out;
    }
    if (std.mem.eql(u8, kind, "assistant")) return content(arena, obj(v, "message") orelse return &.{});
    if (std.mem.eql(u8, kind, "user")) return toolResults(arena, obj(v, "message") orelse return &.{});
    if (std.mem.eql(u8, kind, "stream_event")) return partial(arena, obj(v, "event") orelse return &.{});
    if (std.mem.eql(u8, kind, "result")) return result(arena, v);
    if (std.mem.eql(u8, kind, "control_request")) return controlRequest(arena, v);
    return &.{};
}

fn one(arena: std.mem.Allocator, event: types.HarnessEvent) []const types.HarnessEvent {
    const out = arena.alloc(types.HarnessEvent, 1) catch return &.{};
    out[0] = event;
    return out;
}

fn content(arena: std.mem.Allocator, message: std.json.Value) []const types.HarnessEvent {
    const list = obj(message, "content") orelse return &.{};
    if (list != .array) return &.{};
    var out: std.ArrayList(types.HarnessEvent) = .empty;
    for (list.array.items) |block| {
        const t = str(block, "type") orelse continue;
        if (std.mem.eql(u8, t, "text")) {
            const text = str(block, "text") orelse continue;
            if (text.len > 0) out.append(arena, .{ .message_delta = text }) catch {};
        } else if (std.mem.eql(u8, t, "thinking")) {
            const text = str(block, "thinking") orelse continue;
            if (text.len > 0) out.append(arena, .{ .reasoning_delta = text }) catch {};
        } else if (std.mem.eql(u8, t, "tool_use")) {
            const id = str(block, "id") orelse continue;
            const name = str(block, "name") orelse "tool";
            const input = if (obj(block, "input")) |i| std.json.Stringify.valueAlloc(arena, i, .{}) catch null else null;
            out.append(arena, .{ .tool_start = .{ .id = id, .name = name, .kind = toolKind(name), .input = input } }) catch {};
        }
    }
    return out.items;
}

fn toolResults(arena: std.mem.Allocator, message: std.json.Value) []const types.HarnessEvent {
    const list = obj(message, "content") orelse return &.{};
    if (list != .array) return &.{};
    var out: std.ArrayList(types.HarnessEvent) = .empty;
    for (list.array.items) |block| {
        if (!std.mem.eql(u8, str(block, "type") orelse "", "tool_result")) continue;
        const id = str(block, "tool_use_id") orelse continue;
        const failed = blk: {
            const f = obj(block, "is_error") orelse break :blk false;
            break :blk f == .bool and f.bool;
        };
        out.append(arena, .{ .tool_result = .{
            .id = id,
            .kind = .other,
            .output = resultText(arena, obj(block, "content") orelse .null),
            .status = if (failed) .failed else .completed,
        } }) catch {};
    }
    return out.items;
}

/// A tool result's content: a string, or blocks with text.
fn resultText(arena: std.mem.Allocator, body: std.json.Value) []const u8 {
    if (body == .string) return body.string;
    if (body != .array) return "";
    var out: std.ArrayList(u8) = .empty;
    for (body.array.items) |block| {
        const text = str(block, "text") orelse continue;
        if (out.items.len > 0) out.append(arena, '\n') catch {};
        out.appendSlice(arena, text) catch {};
    }
    return out.items;
}

/// `--include-partial-messages` events: a token at a time, as it streams.
fn partial(arena: std.mem.Allocator, event: std.json.Value) []const types.HarnessEvent {
    if (!std.mem.eql(u8, str(event, "type") orelse "", "content_block_delta")) return &.{};
    const delta = obj(event, "delta") orelse return &.{};
    const t = str(delta, "type") orelse return &.{};
    if (std.mem.eql(u8, t, "text_delta")) {
        const text = str(delta, "text") orelse return &.{};
        return one(arena, .{ .message_delta = text });
    }
    if (std.mem.eql(u8, t, "thinking_delta")) {
        const text = str(delta, "thinking") orelse return &.{};
        return one(arena, .{ .reasoning_delta = text });
    }
    return &.{};
}

fn result(arena: std.mem.Allocator, v: std.json.Value) []const types.HarnessEvent {
    var out: std.ArrayList(types.HarnessEvent) = .empty;
    const failed = blk: {
        const f = obj(v, "is_error") orelse break :blk false;
        break :blk f == .bool and f.bool;
    };
    if (failed) out.append(arena, .{ .session_error = str(v, "result") orelse "the turn failed" }) catch {};
    if (obj(v, "usage")) |usage| {
        const prompt = int(usage, "input_tokens") orelse 0;
        const completion = int(usage, "output_tokens") orelse 0;
        out.append(arena, .{ .turn_metrics = .{
            .prompt_tokens = @intCast(@max(prompt, 0)),
            .completion_tokens = @intCast(@max(completion, 0)),
            .total_tokens = @intCast(@max(prompt + completion, 0)),
        } }) catch {};
    }
    out.append(arena, .{ .turn_ended = str(v, "session_id") orelse "" }) catch {};
    return out.items;
}

/// Claude asks the client to allow a tool with `can_use_tool`.
fn controlRequest(arena: std.mem.Allocator, v: std.json.Value) []const types.HarnessEvent {
    const request = obj(v, "request") orelse return &.{};
    if (!std.mem.eql(u8, str(request, "subtype") orelse "", "can_use_tool")) return &.{};
    const id = str(v, "request_id") orelse return &.{};
    const tool_name = str(request, "tool_name") orelse "";
    const input = if (obj(request, "input")) |i| std.json.Stringify.valueAlloc(arena, i, .{}) catch null else null;
    const title = if (input) |i| std.fmt.allocPrint(arena, "{s} {s}", .{ tool_name, i }) catch tool_name else tool_name;
    return one(arena, .{ .permission_request = .{
        .request_id = @intCast(std.fmt.parseInt(u32, id, 10) catch 0),
        .title = title,
        .tool_name = tool_name,
        .input = input,
    } });
}

pub fn int(v: std.json.Value, key: []const u8) ?i64 {
    const f = obj(v, key) orelse return null;
    return if (f == .integer) f.integer else null;
}

/// One user turn as stream-json input: the text, and any pictures as base64
/// image blocks beside it.
pub fn writeUserLine(w: *std.Io.Writer, text: []const u8, images: []const types.Image) !void {
    try w.writeAll("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":");
    try std.json.Stringify.encodeJsonString(text, .{}, w);
    try w.writeAll("}");
    for (images) |im| {
        if (im.data.len == 0) continue;
        try w.writeAll(",{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
        try std.json.Stringify.encodeJsonString(im.mime, .{}, w);
        try w.writeAll(",\"data\":");
        try std.json.Stringify.encodeJsonString(im.data, .{}, w);
        try w.writeAll("}}");
    }
    try w.writeAll("]}}\n");
}

test "a user line carries the text and its pictures" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var data = "\x89PNG".*;
    const images = [_]types.Image{.{ .name = "shot.png", .mime = "image/png", .data = &data }};
    try writeUserLine(&aw.writer, "look", &images);
    const line = aw.written();
    try std.testing.expect(std.mem.endsWith(u8, line, "}}\n"));
    try std.testing.expect(std.mem.indexOf(u8, line, "\"media_type\":\"image/png\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\"text\":\"look\"") != null);
}

test "an assistant message maps to text, thinking, and a tool row" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"hi"},{"type":"thinking","thinking":"hmm"},{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"a.zig"}}]}}
    , .{});
    const events = mapMessage(a, v);
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqualStrings("hi", events[0].message_delta);
    try std.testing.expectEqualStrings("hmm", events[1].reasoning_delta);
    try std.testing.expectEqual(types.ToolKind.read, events[2].tool_start.kind);
    try std.testing.expectEqualStrings("t1", events[2].tool_start.id);
}

test "a tool result ends the row, a result message ends the turn" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tool = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"text","text":"done"}]}]}}
    , .{});
    const tool_event = mapMessage(a, tool)[0].tool_result;
    try std.testing.expectEqual(types.ToolStatus.completed, tool_event.status);
    try std.testing.expectEqualStrings("done", tool_event.output);

    const done = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"type":"result","subtype":"success","is_error":false,"session_id":"s1","usage":{"input_tokens":10,"output_tokens":4}}
    , .{});
    const events = mapMessage(a, done);
    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqual(@as(u32, 10), events[0].turn_metrics.prompt_tokens);
    try std.testing.expectEqualStrings("s1", events[1].turn_ended);
}

test "a permission request names the tool it wants" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"type":"control_request","request_id":"7","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"ls"}}}
    , .{});
    const ask = mapMessage(a, v)[0].permission_request;
    try std.testing.expectEqual(@as(u32, 7), ask.request_id);
    try std.testing.expectEqualStrings("Bash", ask.tool_name);
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
