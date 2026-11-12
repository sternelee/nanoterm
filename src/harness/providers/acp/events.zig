//! ACP `session/update` notifications as harness events. The mapping is
//! pure: it reads one parsed update and returns the events it means, with
//! every string living in the caller's arena. Nothing here touches a
//! process, so the whole translation can be tested from JSON literals.
const std = @import("std");
const acp = @import("../../../acp.zig");
const types = @import("../../types.zig");

/// The events `update` means. Empty when it carries nothing a turn shows
/// (a user echo, an update for a tool the view already drew).
pub fn map(arena: std.mem.Allocator, update: std.json.Value) []const types.HarnessEvent {
    const kind = acp.str(update, "sessionUpdate") orelse return &.{};
    if (std.mem.eql(u8, kind, "agent_message_chunk")) return text(arena, update, "message_delta");
    if (std.mem.eql(u8, kind, "agent_thought_chunk")) return text(arena, update, "reasoning_delta");
    if (std.mem.eql(u8, kind, "tool_call")) return toolCall(arena, update);
    if (std.mem.eql(u8, kind, "tool_call_update")) return toolUpdate(arena, update);
    if (std.mem.eql(u8, kind, "plan")) return plan(arena, update);
    if (std.mem.eql(u8, kind, "available_commands_update")) return commands(arena, update);
    if (std.mem.eql(u8, kind, "config_option_update")) return configOptions(arena, update);
    if (std.mem.eql(u8, kind, "current_mode_update")) return currentMode(arena, update);
    return &.{};
}

fn one(arena: std.mem.Allocator, event: types.HarnessEvent) []const types.HarnessEvent {
    const out = arena.alloc(types.HarnessEvent, 1) catch return &.{};
    out[0] = event;
    return out;
}

fn text(arena: std.mem.Allocator, update: std.json.Value, comptime field: []const u8) []const types.HarnessEvent {
    const body = acp.obj(update, "content") orelse return &.{};
    const s = acp.str(body, "text") orelse return &.{};
    if (s.len == 0) return &.{};
    return one(arena, @unionInit(types.HarnessEvent, field, s));
}

fn toolCall(arena: std.mem.Allocator, update: std.json.Value) []const types.HarnessEvent {
    const id = acp.str(update, "toolCallId") orelse return &.{};
    const name = acp.str(update, "title") orelse "";
    const kind = types.toolKindFromName(acp.str(update, "kind") orelse "other");
    const input = toolInput(arena, update);
    return one(arena, .{ .tool_start = .{ .id = id, .name = name, .kind = kind, .input = input } });
}

fn toolUpdate(arena: std.mem.Allocator, update: std.json.Value) []const types.HarnessEvent {
    const id = acp.str(update, "toolCallId") orelse return &.{};
    const kind = types.toolKindFromName(acp.str(update, "kind") orelse "other");
    const output = toolDetail(arena, update) orelse "";
    const status = toolStatus(acp.str(update, "status") orelse "in_progress");
    // A tool still running streams its output; one that finished reports it.
    if (status == .pending or status == .in_progress) {
        if (output.len == 0) return &.{};
        return one(arena, .{ .tool_delta = .{ .id = id, .kind = kind, .delta = output } });
    }
    return one(arena, .{ .tool_result = .{ .id = id, .kind = kind, .output = output, .status = status } });
}

fn plan(arena: std.mem.Allocator, update: std.json.Value) []const types.HarnessEvent {
    const entries = acp.obj(update, "entries") orelse return &.{};
    if (entries != .array) return &.{};
    var list: std.ArrayList(types.PlanEntry) = .empty;
    for (entries.array.items) |e| {
        list.append(arena, .{
            .text = acp.str(e, "content") orelse "",
            .status = acp.str(e, "status") orelse "pending",
        }) catch return &.{};
    }
    return one(arena, .{ .plan = list.items });
}

fn commands(arena: std.mem.Allocator, update: std.json.Value) []const types.HarnessEvent {
    const list = acp.obj(update, "availableCommands") orelse return &.{};
    if (list != .array) return &.{};
    var out: std.ArrayList(types.CommandInfo) = .empty;
    for (list.array.items) |c| out.append(arena, .{
        .name = acp.str(c, "name") orelse continue,
        .description = acp.str(c, "description") orelse "",
    }) catch return &.{};
    return one(arena, .{ .config = .{ .commands = out.items } });
}

fn configOptions(arena: std.mem.Allocator, update: std.json.Value) []const types.HarnessEvent {
    const opts = acp.obj(update, "configOptions") orelse return &.{};
    const parsed = parseOptions(arena, opts) catch return &.{};
    return one(arena, .{ .config = .{ .options = parsed } });
}

fn currentMode(arena: std.mem.Allocator, update: std.json.Value) []const types.HarnessEvent {
    const value = acp.str(update, "currentModeId") orelse return &.{};
    return one(arena, .{ .config = .{ .current_mode = .{ .id = "mode", .value = value } } });
}

/// ACP's `configOptions` array as harness options.
pub fn parseOptions(arena: std.mem.Allocator, value: std.json.Value) ![]const types.ConfigOption {
    if (value != .array) return &.{};
    var out: std.ArrayList(types.ConfigOption) = .empty;
    for (value.array.items) |o| {
        var values: std.ArrayList(types.ConfigValue) = .empty;
        if (acp.obj(o, "options")) |list| if (list == .array) {
            for (list.array.items) |v| values.append(arena, .{
                .id = acp.str(v, "value") orelse acp.str(v, "id") orelse continue,
                .name = acp.str(v, "name") orelse "",
                .description = acp.str(v, "description") orelse "",
            }) catch {};
        };
        try out.append(arena, .{
            .id = acp.str(o, "id") orelse continue,
            .name = acp.str(o, "name") orelse "",
            .category = acp.str(o, "category") orelse "",
            .current = acp.str(o, "currentValue") orelse acp.str(o, "current_value") orelse "",
            .values = values.items,
        });
    }
    return out.items;
}

fn toolStatus(name: []const u8) types.ToolStatus {
    if (std.mem.eql(u8, name, "pending")) return .pending;
    if (std.mem.eql(u8, name, "completed")) return .completed;
    if (std.mem.eql(u8, name, "failed")) return .failed;
    return .in_progress;
}

/// A tool call's input, serialized back to JSON so a view can show it.
fn toolInput(arena: std.mem.Allocator, update: std.json.Value) ?[]const u8 {
    const raw = acp.obj(update, "rawInput") orelse return null;
    if (raw == .null) return null;
    return std.json.Stringify.valueAlloc(arena, raw, .{}) catch null;
}

/// The text a tool showed, from ACP's content blocks (text and diffs).
fn toolDetail(arena: std.mem.Allocator, update: std.json.Value) ?[]const u8 {
    const content = acp.obj(update, "content") orelse return null;
    if (content != .array) return null;
    var out: std.ArrayList(u8) = .empty;
    for (content.array.items) |block| {
        const inner = acp.obj(block, "content") orelse block;
        if (acp.str(inner, "text")) |t| {
            if (out.items.len > 0) out.append(arena, '\n') catch {};
            out.appendSlice(arena, t) catch {};
        } else if (acp.str(block, "path")) |path| {
            if (out.items.len > 0) out.append(arena, '\n') catch {};
            out.appendSlice(arena, path) catch {};
        }
    }
    if (out.items.len == 0) return null;
    return out.items;
}

test "an agent message chunk is a message delta" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"hi"}}
    , .{});
    const events = map(a, v);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("hi", events[0].message_delta);
}

test "a thought chunk is reasoning, an empty one is nothing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"why"}}
    , .{});
    try std.testing.expectEqualStrings("why", map(a, v)[0].reasoning_delta);
    const empty = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":""}}
    , .{});
    try std.testing.expectEqual(@as(usize, 0), map(a, empty).len);
}

test "a tool call opens a row with its kind and input" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sessionUpdate":"tool_call","toolCallId":"t1","title":"Read main.zig","kind":"read","rawInput":{"path":"src/main.zig"}}
    , .{});
    const events = map(a, v);
    try std.testing.expectEqual(@as(usize, 1), events.len);
    const start = events[0].tool_start;
    try std.testing.expectEqualStrings("t1", start.id);
    try std.testing.expectEqualStrings("Read main.zig", start.name);
    try std.testing.expectEqual(types.ToolKind.read, start.kind);
    try std.testing.expectEqualStrings("{\"path\":\"src/main.zig\"}", start.input.?);
}

test "a running tool streams, a finished one reports" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const running = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sessionUpdate":"tool_call_update","toolCallId":"t1","kind":"execute","status":"in_progress","content":[{"type":"content","content":{"type":"text","text":"building"}}]}
    , .{});
    try std.testing.expectEqualStrings("building", map(a, running)[0].tool_delta.delta);
    const done = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sessionUpdate":"tool_call_update","toolCallId":"t1","kind":"execute","status":"completed","content":[{"type":"content","content":{"type":"text","text":"ok"}}]}
    , .{});
    const result = map(a, done)[0].tool_result;
    try std.testing.expectEqual(types.ToolStatus.completed, result.status);
    try std.testing.expectEqualStrings("ok", result.output);
}

test "a plan replaces the turn's list, commands and modes update config" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plan_update = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sessionUpdate":"plan","entries":[{"content":"Read","status":"completed"},{"content":"Write","status":"pending"}]}
    , .{});
    const entries = map(a, plan_update)[0].plan;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("Read", entries[0].text);
    try std.testing.expectEqualStrings("completed", entries[0].status);

    const cmds = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"init","description":"Start"}]}
    , .{});
    try std.testing.expectEqualStrings("init", map(a, cmds)[0].config.commands[0].name);

    const mode = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sessionUpdate":"current_mode_update","currentModeId":"accept_edits"}
    , .{});
    try std.testing.expectEqualStrings("accept_edits", map(a, mode)[0].config.current_mode.value);
}

test "config options carry their values and current pick" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\[{"id":"model","name":"Model","category":"model","currentValue":"sonnet","options":[{"value":"sonnet","name":"Sonnet"},{"value":"opus","name":"Opus"}]}]
    , .{});
    const opts = try parseOptions(a, v);
    try std.testing.expectEqual(@as(usize, 1), opts.len);
    try std.testing.expectEqualStrings("sonnet", opts[0].current);
    try std.testing.expectEqual(@as(usize, 2), opts[0].values.len);
    try std.testing.expectEqualStrings("Opus", opts[0].values[1].name);
}
