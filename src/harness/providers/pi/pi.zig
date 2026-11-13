//! Pi as a harness provider, over its own RPC mode (`pi --mode rpc`), not
//! ACP. Pi sends no greeting and needs no handshake: a turn goes out as a
//! `prompt` command and the session's events come back in order.
const std = @import("std");
const proc = @import("../../../proc.zig");
const agents = @import("../../../agents.zig");
const pi_rpc = @import("../../../pi.zig");
const types = @import("../../types.zig");

pub const id = types.ids.pi;
pub const label = "Pi";

/// `pi --mode rpc --no-session`, with the chosen model's provider and id.
pub fn argv(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, model: ?[]const u8) ![]const []const u8 {
    const path = agents.searchPath(arena, env.get("PATH") orelse "", env.get("HOME") orelse "/");
    const bin = proc.which(arena, io, path, "pi") orelse return error.NotInstalled;
    if (model) |m| {
        const parsed = pi_rpc.providerId(m, "");
        if (parsed.provider.len > 0) return arena.dupe([]const u8, &.{ bin, "--mode", "rpc", "--no-session", "--provider", parsed.provider, "--model", parsed.id });
        return arena.dupe([]const u8, &.{ bin, "--mode", "rpc", "--no-session", "--model", parsed.id });
    }
    return arena.dupe([]const u8, &.{ bin, "--mode", "rpc", "--no-session" });
}

/// Pi's events as harness events. The tool call arrives in two pieces (its
/// start, then its arguments), and its execution ends with a result.
pub fn mapEvent(arena: std.mem.Allocator, record: std.json.Value) []const types.HarnessEvent {
    const kind = pi_rpc.str(record, "type") orelse return &.{};
    if (std.mem.eql(u8, kind, "message_update")) return messageUpdate(arena, record);
    if (std.mem.eql(u8, kind, "tool_execution_start")) return executionStart(arena, record);
    if (std.mem.eql(u8, kind, "tool_execution_end")) return executionEnd(arena, record);
    if (std.mem.eql(u8, kind, "message_end")) return one(arena, .{ .message_completed = {} });
    if (std.mem.eql(u8, kind, "agent_settled")) return one(arena, .{ .turn_ended = "" });
    if (std.mem.eql(u8, kind, "agent_start")) return one(arena, .{ .status = "working" });
    return &.{};
}

fn one(arena: std.mem.Allocator, event: types.HarnessEvent) []const types.HarnessEvent {
    const out = arena.alloc(types.HarnessEvent, 1) catch return &.{};
    out[0] = event;
    return out;
}

fn messageUpdate(arena: std.mem.Allocator, record: std.json.Value) []const types.HarnessEvent {
    const ev = pi_rpc.obj(record, "assistantMessageEvent") orelse return &.{};
    const detail = pi_rpc.str(ev, "type") orelse return &.{};
    if (std.mem.eql(u8, detail, "text_delta")) {
        const text = pi_rpc.str(ev, "delta") orelse return &.{};
        return one(arena, .{ .message_delta = text });
    }
    if (std.mem.eql(u8, detail, "thinking_delta")) {
        const text = pi_rpc.str(ev, "delta") orelse return &.{};
        return one(arena, .{ .reasoning_delta = text });
    }
    if (std.mem.eql(u8, detail, "toolcall_start")) return toolCall(arena, ev);
    if (std.mem.eql(u8, detail, "toolcall_end")) {
        const call = pi_rpc.obj(ev, "toolCall") orelse return &.{};
        return toolCall(arena, call);
    }
    return &.{};
}

fn toolCall(arena: std.mem.Allocator, v: std.json.Value) []const types.HarnessEvent {
    const call_id = pi_rpc.str(v, "id") orelse return &.{};
    const name = pi_rpc.str(v, "toolName") orelse "tool";
    const input = if (pi_rpc.obj(v, "arguments")) |a| std.json.Stringify.valueAlloc(arena, a, .{}) catch null else null;
    return one(arena, .{ .tool_start = .{ .id = call_id, .name = name, .kind = types.ToolKind.other, .input = input } });
}

fn executionStart(arena: std.mem.Allocator, record: std.json.Value) []const types.HarnessEvent {
    const call_id = pi_rpc.str(record, "toolCallId") orelse return &.{};
    const name = pi_rpc.str(record, "toolName") orelse "tool";
    return one(arena, .{ .tool_start = .{ .id = call_id, .name = name, .kind = types.ToolKind.other } });
}

fn executionEnd(arena: std.mem.Allocator, record: std.json.Value) []const types.HarnessEvent {
    const call_id = pi_rpc.str(record, "toolCallId") orelse return &.{};
    const failed = blk: {
        const e = pi_rpc.obj(record, "isError") orelse break :blk false;
        break :blk e == .bool and e.bool;
    };
    return one(arena, .{ .tool_result = .{
        .id = call_id,
        .kind = .other,
        .output = resultText(arena, pi_rpc.obj(record, "result") orelse .null),
        .status = if (failed) .failed else .completed,
    } });
}

/// A tool result's text blocks, joined.
fn resultText(arena: std.mem.Allocator, body: std.json.Value) []const u8 {
    const content = pi_rpc.obj(body, "content") orelse return "";
    if (content != .array) return "";
    var out: std.ArrayList(u8) = .empty;
    for (content.array.items) |block| {
        if (!std.mem.eql(u8, pi_rpc.str(block, "type") orelse "", "text")) continue;
        const text = pi_rpc.str(block, "text") orelse continue;
        if (out.items.len > 0) out.append(arena, '\n') catch {};
        out.appendSlice(arena, text) catch {};
    }
    return out.items;
}

test "pi's deltas and tool calls become harness events" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const delta = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"hi"}}
    , .{});
    try std.testing.expectEqualStrings("hi", mapEvent(a, delta)[0].message_delta);
    const thought = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"type":"message_update","assistantMessageEvent":{"type":"thinking_delta","delta":"why"}}
    , .{});
    try std.testing.expectEqualStrings("why", mapEvent(a, thought)[0].reasoning_delta);
    const call = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"type":"message_update","assistantMessageEvent":{"type":"toolcall_start","id":"t1","toolName":"shell"}}
    , .{});
    try std.testing.expectEqualStrings("t1", mapEvent(a, call)[0].tool_start.id);
    const settled = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"type\":\"agent_settled\"}", .{});
    try std.testing.expectEqualStrings("", mapEvent(a, settled)[0].turn_ended);
}

test "pi's execution end reports its output and how it went" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"type":"tool_execution_end","toolCallId":"t1","isError":false,"result":{"content":[{"type":"text","text":"ok"}]}}
    , .{});
    const result = mapEvent(a, v)[0].tool_result;
    try std.testing.expectEqual(types.ToolStatus.completed, result.status);
    try std.testing.expectEqualStrings("ok", result.output);
}

test "pi's extension select is a question, and its other dialogs are not" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A `select` carries its choices as plain strings, which is what the card
    // offers; the harness has no event for the rest, so they stay unhandled
    // here and the provider declines them.
    const select = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"type":"extension_ui_request","id":"e1","method":"select","title":"Pick one","options":["Red","Blue"]}
    , .{});
    try std.testing.expectEqualStrings("select", pi_rpc.str(select, "method").?);
    const options = pi_rpc.obj(select, "options").?;
    try std.testing.expectEqual(@as(usize, 2), options.array.items.len);
    try std.testing.expectEqualStrings("Blue", options.array.items[1].string);
    // mapEvent leaves it alone: the provider handles it before mapping.
    try std.testing.expectEqual(@as(usize, 0), mapEvent(a, select).len);

    const confirm = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"type":"extension_ui_request","id":"e2","method":"confirm","title":"Sure?","message":"Really?"}
    , .{});
    try std.testing.expectEqualStrings("confirm", pi_rpc.str(confirm, "method").?);
    try std.testing.expectEqual(@as(usize, 0), mapEvent(a, confirm).len);
}
