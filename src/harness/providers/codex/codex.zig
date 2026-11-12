//! Codex through its own app-server, not an ACP adapter. `codex app-server`
//! speaks headerless JSON-RPC over stdio: `initialize`, `thread/start` (or
//! `thread/resume`), then one `turn/start` per turn, with the turn's items
//! streamed back as notifications and approvals asked as server requests.
//!
//! Everything here is pure: the command line, the thread and turn parameters,
//! and the mapping from a notification to harness events.
const std = @import("std");
const proc = @import("../../../proc.zig");
const agents = @import("../../../agents.zig");
const types = @import("../../types.zig");

pub const id = types.ids.codex;
pub const label = "Codex";

/// `codex app-server`: the protocol nanoterm drives directly.
pub fn argv(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, model: ?[]const u8) ![]const []const u8 {
    _ = model;
    const path = agents.searchPath(arena, env.get("PATH") orelse "", env.get("HOME") orelse "/");
    const bin = proc.which(arena, io, path, "codex") orelse return error.NotInstalled;
    return arena.dupe([]const u8, &.{ bin, "app-server" });
}

/// What a turn may do, as Codex's approval and sandbox settings say it.
pub const Config = struct {
    approval_policy: []const u8,
    sandbox: []const u8,
    approvals_reviewer: []const u8,
    sandbox_policy: []const u8,

    /// The sandbox policy as Codex's tagged union spells it.
    pub fn sandboxPolicyJson(self: Config) []const u8 {
        if (std.mem.eql(u8, self.sandbox_policy, "readOnly")) return "{\"type\":\"readOnly\"}";
        if (std.mem.eql(u8, self.sandbox_policy, "dangerFullAccess")) return "{\"type\":\"dangerFullAccess\"}";
        return "{\"type\":\"workspaceWrite\"}";
    }
};

/// The access level's settings. A plan is a non-escalating read-only turn, so
/// it never asks for broader access than the mode the user chose.
pub fn configFor(mode: types.RuntimeMode, planning: bool) Config {
    if (planning or mode == .plan) return .{
        .approval_policy = "never",
        .sandbox = "read-only",
        .approvals_reviewer = "user",
        .sandbox_policy = "readOnly",
    };
    if (mode == .supervised) return .{
        .approval_policy = "untrusted",
        .sandbox = "read-only",
        .approvals_reviewer = "user",
        .sandbox_policy = "readOnly",
    };
    if (mode == .auto) return .{
        .approval_policy = "on-request",
        .sandbox = "workspace-write",
        .approvals_reviewer = "auto_review",
        .sandbox_policy = "workspaceWrite",
    };
    // The default is an editing turn that still asks before reaching out.
    return .{
        .approval_policy = "on-request",
        .sandbox = "workspace-write",
        .approvals_reviewer = "user",
        .sandbox_policy = "workspaceWrite",
    };
}

/// `thread/start`'s parameters.
pub fn threadStartParams(arena: std.mem.Allocator, cwd: []const u8, mode: types.RuntimeMode, planning: bool, model: ?[]const u8) !std.json.Value {
    const config = configFor(mode, planning);
    var map = std.json.ObjectMap.empty;
    try map.put(arena, "cwd", .{ .string = cwd });
    try map.put(arena, "approvalPolicy", .{ .string = config.approval_policy });
    try map.put(arena, "sandbox", .{ .string = config.sandbox });
    try map.put(arena, "approvalsReviewer", .{ .string = config.approvals_reviewer });
    try map.put(arena, "sandboxPolicy", try parseRaw(arena, config.sandboxPolicyJson()));
    // Only send a model when one was chosen: Codex rejects a null.
    if (model) |m| if (m.len > 0) try map.put(arena, "model", .{ .string = m });
    return .{ .object = map };
}

/// `turn/start`'s parameters: the prompt as input blocks, and the settings
/// this turn runs under.
pub fn turnStartParams(
    arena: std.mem.Allocator,
    thread_id: []const u8,
    mode: types.RuntimeMode,
    planning: bool,
    model: ?[]const u8,
    effort: ?[]const u8,
    prompt: []const u8,
    images: []const types.Image,
) !std.json.Value {
    const config = configFor(mode, planning);
    var map = std.json.ObjectMap.empty;
    try map.put(arena, "threadId", .{ .string = thread_id });
    try map.put(arena, "input", .{ .array = try inputBlocks(arena, prompt, images) });
    try map.put(arena, "approvalPolicy", .{ .string = config.approval_policy });
    try map.put(arena, "approvalsReviewer", .{ .string = config.approvals_reviewer });
    try map.put(arena, "sandboxPolicy", try parseRaw(arena, config.sandboxPolicyJson()));
    if (model) |m| if (m.len > 0) try map.put(arena, "model", .{ .string = m });
    if (effort) |e| if (e.len > 0) try map.put(arena, "effort", .{ .string = e });
    return .{ .object = map };
}

/// The prompt as app-server input: the text, then each picture either as a
/// data URL or, when it has no bytes here, by its path.
fn inputBlocks(arena: std.mem.Allocator, prompt: []const u8, images: []const types.Image) !std.json.Array {
    var list = std.json.Array.init(arena);
    var text = std.json.ObjectMap.empty;
    try text.put(arena, "type", .{ .string = "text" });
    try text.put(arena, "text", .{ .string = prompt });
    try list.append(.{ .object = text });
    for (images) |im| {
        if (im.data.len > 0 and isImage(im.mime)) {
            var block = std.json.ObjectMap.empty;
            try block.put(arena, "type", .{ .string = "image" });
            const enc = std.base64.standard.Encoder;
            const b64 = try arena.alloc(u8, enc.calcSize(im.data.len));
            try block.put(arena, "url", .{ .string = try std.fmt.allocPrint(arena, "data:{s};base64,{s}", .{
                im.mime,
                enc.encode(b64, im.data),
            }) });
            try list.append(.{ .object = block });
        } else if (im.path.len > 0) {
            var block = std.json.ObjectMap.empty;
            try block.put(arena, "type", .{ .string = "localImage" });
            try block.put(arena, "path", .{ .string = im.path });
            try list.append(.{ .object = block });
        }
    }
    return list;
}

fn isImage(mime: []const u8) bool {
    return std.mem.startsWith(u8, mime, "image/");
}

fn parseRaw(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

/// Codex's wire decision for an approval.
pub fn approvalDecision(decision: types.ApprovalDecision) []const u8 {
    return switch (decision) {
        .allow => "accept",
        .deny => "decline",
    };
}

/// `turn/steer`'s parameters: a follow-up folded into the turn already
/// running. `expected_turn_id` is the turn it must land in; Codex refuses the
/// steer when that turn has ended, so a late follow-up is not silently
/// answered by a different turn.
pub fn steerParams(
    arena: std.mem.Allocator,
    thread_id: []const u8,
    expected_turn_id: []const u8,
    prompt: []const u8,
    images: []const types.Image,
) !std.json.Value {
    var map = std.json.ObjectMap.empty;
    try map.put(arena, "threadId", .{ .string = thread_id });
    try map.put(arena, "expectedTurnId", .{ .string = expected_turn_id });
    try map.put(arena, "input", .{ .array = try inputBlocks(arena, prompt, images) });
    return .{ .object = map };
}

/// The events a notification means. `turn/completed` and `turn/aborted` also
/// end the turn; the provider settles the turn when it sees them.
pub fn mapNotification(arena: std.mem.Allocator, method: []const u8, params: std.json.Value) []const types.HarnessEvent {
    if (std.mem.eql(u8, method, "item/agentMessage/delta")) {
        const delta = str(params, "delta") orelse return &.{};
        if (delta.len == 0) return &.{};
        return one(arena, .{ .message_delta = delta });
    }
    if (std.mem.eql(u8, method, "item/reasoning/summaryTextDelta") or std.mem.eql(u8, method, "item/reasoning/textDelta")) {
        const delta = str(params, "delta") orelse return &.{};
        if (delta.len == 0) return &.{};
        return one(arena, .{ .reasoning_delta = delta });
    }
    if (std.mem.eql(u8, method, "turn/plan/updated")) return plan(arena, params);
    if (std.mem.eql(u8, method, "item/started") or std.mem.eql(u8, method, "item/completed")) {
        return item(arena, std.mem.eql(u8, method, "item/completed"), params);
    }
    if (std.mem.eql(u8, method, "item/commandExecution/outputDelta")) {
        const call_id = str(params, "itemId") orelse return &.{};
        const delta = str(params, "delta") orelse return &.{};
        if (delta.len == 0) return &.{};
        return one(arena, .{ .tool_delta = .{ .id = call_id, .kind = .execute, .delta = delta } });
    }
    if (std.mem.eql(u8, method, "thread/tokenUsage/updated")) return tokenUsage(arena, params);
    if (std.mem.eql(u8, method, "turn/completed") or std.mem.eql(u8, method, "turn/aborted")) {
        return turnEnd(arena, std.mem.eql(u8, method, "turn/aborted"), params);
    }
    if (std.mem.eql(u8, method, "error")) {
        const message = str(obj(params, "error") orelse .null, "message") orelse str(params, "message") orelse "Codex error";
        const will_retry = blk: {
            const v = obj(params, "willRetry") orelse break :blk false;
            break :blk v == .bool and v.bool;
        };
        // Codex retries the request itself; a note per attempt would only
        // interrupt the transcript.
        if (will_retry) return one(arena, .{ .note = message });
        return one(arena, .{ .session_error = message });
    }
    if (std.mem.eql(u8, method, "configWarning") or std.mem.eql(u8, method, "warning")) {
        const message = str(params, "summary") orelse str(params, "message") orelse str(params, "details") orelse return &.{};
        return one(arena, .{ .note = message });
    }
    return &.{};
}

/// A whole plan the turn keeps, as `turn/plan/updated` gives it.
fn plan(arena: std.mem.Allocator, params: std.json.Value) []const types.HarnessEvent {
    const steps = obj(params, "plan") orelse return &.{};
    if (steps != .array) return &.{};
    var list: std.ArrayList(types.PlanEntry) = .empty;
    for (steps.array.items) |step| {
        const text = str(step, "step") orelse continue;
        if (text.len == 0) continue;
        list.append(arena, .{ .text = text, .status = str(step, "status") orelse "pending" }) catch return &.{};
    }
    return one(arena, .{ .plan = list.items });
}

/// An item Codex started or finished. The item's own type says what it is.
fn item(arena: std.mem.Allocator, completed: bool, params: std.json.Value) []const types.HarnessEvent {
    const it = obj(params, "item") orelse return &.{};
    const call_id = str(it, "id") orelse return &.{};
    const kind = str(it, "type") orelse return &.{};
    // nanoterm already draws the user's own message; the rest is metadata.
    if (std.mem.eql(u8, kind, "userMessage") or std.mem.eql(u8, kind, "contextCompaction") or std.mem.eql(u8, kind, "enteredReviewMode")) return &.{};

    if (std.mem.eql(u8, kind, "agentMessage")) {
        if (!completed) return &.{};
        const text = str(it, "text") orelse return &.{};
        if (text.len == 0) return &.{};
        const out = arena.alloc(types.HarnessEvent, 2) catch return &.{};
        out[0] = .{ .message_delta = text };
        out[1] = .{ .message_completed = {} };
        return out;
    }
    if (std.mem.eql(u8, kind, "reasoning")) {
        if (!completed) return &.{};
        const summary = obj(it, "summary") orelse return one(arena, .{ .reasoning_completed = {} });
        if (summary != .array) return one(arena, .{ .reasoning_completed = {} });
        var text: std.ArrayList(u8) = .empty;
        for (summary.array.items) |part| {
            const piece = if (part == .string) part.string else str(part, "text") orelse continue;
            if (piece.len == 0) continue;
            if (text.items.len > 0) text.append(arena, '\n') catch {};
            text.appendSlice(arena, piece) catch {};
        }
        if (text.items.len == 0) return one(arena, .{ .reasoning_completed = {} });
        const out = arena.alloc(types.HarnessEvent, 2) catch return &.{};
        out[0] = .{ .reasoning_delta = text.items };
        out[1] = .{ .reasoning_completed = {} };
        return out;
    }
    if (std.mem.eql(u8, kind, "plan")) {
        const text = str(it, "text") orelse return &.{};
        return one(arena, .{ .plan = &.{.{ .text = text }} });
    }
    if (std.mem.eql(u8, kind, "commandExecution")) {
        const command = commandText(it) orelse "Shell";
        if (!completed) return one(arena, .{ .tool_start = .{ .id = call_id, .name = command, .kind = .execute } });
        const output = str(it, "aggregatedOutput") orelse str(it, "output") orelse "";
        return one(arena, .{ .tool_result = .{
            .id = call_id,
            .kind = .execute,
            .output = output,
            .status = itemStatus(str(it, "status"), false),
        } });
    }
    if (std.mem.eql(u8, kind, "fileChange")) {
        if (!completed) return one(arena, .{ .tool_start = .{ .id = call_id, .name = "Edit", .kind = .edit } });
        return one(arena, .{ .tool_result = .{
            .id = call_id,
            .kind = .edit,
            .output = changePaths(arena, it),
            .status = itemStatus(str(it, "status"), false),
        } });
    }
    if (std.mem.eql(u8, kind, "webSearch")) {
        const query = str(it, "query") orelse "Search";
        if (!completed) return one(arena, .{ .tool_start = .{ .id = call_id, .name = query, .kind = .search } });
        return one(arena, .{ .tool_result = .{ .id = call_id, .kind = .search, .output = query, .status = .completed } });
    }
    if (std.mem.eql(u8, kind, "mcpToolCall")) {
        const server = str(it, "server") orelse "mcp";
        const tool = str(it, "tool") orelse "tool";
        const title = std.fmt.allocPrint(arena, "{s}:{s}", .{ server, tool }) catch return &.{};
        if (!completed) return one(arena, .{ .tool_start = .{ .id = call_id, .name = title, .kind = .other } });
        return one(arena, .{ .tool_result = .{ .id = call_id, .kind = .other, .output = "", .status = .completed } });
    }
    return &.{};
}

/// The command a `commandExecution` item ran. Codex sends a string, but a
/// shell launcher can arrive as argv, whose script element is the real one.
fn commandText(it: std.json.Value) ?[]const u8 {
    const command = obj(it, "command") orelse return null;
    if (command == .string) return if (command.string.len > 0) command.string else null;
    if (command != .array) return null;
    var launcher: []const u8 = "";
    if (command.array.items.len > 0 and command.array.items[0] == .string) {
        const first = command.array.items[0].string;
        launcher = std.fs.path.basename(first);
    }
    const posix = std.mem.eql(u8, launcher, "sh") or std.mem.eql(u8, launcher, "bash") or std.mem.eql(u8, launcher, "zsh") or std.mem.eql(u8, launcher, "dash") or std.mem.eql(u8, launcher, "ksh");
    var i: usize = 1;
    while (i + 1 < command.array.items.len) : (i += 1) {
        const part = command.array.items[i];
        if (part != .string) continue;
        const flag = part.string;
        if (posix and (std.mem.eql(u8, flag, "--command") or (flag.len > 1 and flag[0] == '-' and std.mem.indexOfScalar(u8, flag[1..], 'c') != null))) {
            const script = command.array.items[i + 1];
            if (script == .string) return script.string;
        }
    }
    return null;
}

/// The files a `fileChange` item touched, one per line.
fn changePaths(arena: std.mem.Allocator, it: std.json.Value) []const u8 {
    const changes = obj(it, "changes") orelse return "";
    if (changes != .array) return "";
    var out: std.ArrayList(u8) = .empty;
    for (changes.array.items) |change| {
        const path = str(change, "path") orelse continue;
        if (out.items.len > 0) out.append(arena, '\n') catch {};
        out.appendSlice(arena, path) catch {};
    }
    return out.items;
}

fn itemStatus(status: ?[]const u8, completed: bool) types.ToolStatus {
    const value = status orelse return if (completed) .completed else .in_progress;
    if (std.mem.eql(u8, value, "failed")) return .failed;
    if (std.mem.eql(u8, value, "completed")) return .completed;
    if (std.mem.eql(u8, value, "pending")) return .pending;
    return .in_progress;
}

fn tokenUsage(arena: std.mem.Allocator, params: std.json.Value) []const types.HarnessEvent {
    const usage = obj(params, "tokenUsage") orelse return &.{};
    const last = obj(usage, "last") orelse return &.{};
    const used = int(last, "totalTokens") orelse 0;
    const window = int(usage, "modelContextWindow") orelse 0;
    if (used == 0 and window == 0) return &.{};
    return one(arena, .{ .context = .{
        .used = if (used > 0) @intCast(used) else null,
        .window = if (window > 0) @intCast(window) else null,
    } });
}

/// The turn is over: text and thinking close, and a failure is reported.
fn turnEnd(arena: std.mem.Allocator, aborted: bool, params: std.json.Value) []const types.HarnessEvent {
    const turn = obj(params, "turn") orelse .null;
    const status = str(turn, "status") orelse if (aborted) "interrupted" else "completed";
    var out: std.ArrayList(types.HarnessEvent) = .empty;
    out.append(arena, .{ .message_completed = {} }) catch {};
    out.append(arena, .{ .reasoning_completed = {} }) catch {};
    if (std.mem.eql(u8, status, "failed")) {
        const message = str(obj(turn, "error") orelse .null, "message") orelse "Codex turn failed.";
        out.append(arena, .{ .session_error = message }) catch {};
    }
    out.append(arena, .{ .turn_ended = "" }) catch {};
    return out.items;
}

fn one(arena: std.mem.Allocator, event: types.HarnessEvent) []const types.HarnessEvent {
    const out = arena.alloc(types.HarnessEvent, 1) catch return &.{};
    out[0] = event;
    return out;
}

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = obj(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

fn obj(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn int(v: std.json.Value, key: []const u8) ?i64 {
    const f = obj(v, key) orelse return null;
    return if (f == .integer) f.integer else null;
}

test "each access level picks its approval and sandbox settings" {
    const supervised = configFor(.supervised, false);
    try std.testing.expectEqualStrings("untrusted", supervised.approval_policy);
    try std.testing.expectEqualStrings("read-only", supervised.sandbox);
    try std.testing.expectEqualStrings("{\"type\":\"readOnly\"}", supervised.sandboxPolicyJson());
    // A plan never escalates, whatever the mode says.
    try std.testing.expectEqualStrings("never", configFor(.auto, true).approval_policy);
    try std.testing.expectEqualStrings("readOnly", configFor(.auto, true).sandbox_policy);
    try std.testing.expectEqualStrings("auto_review", configFor(.auto, false).approvals_reviewer);
    try std.testing.expectEqualStrings("workspaceWrite", configFor(.default, false).sandbox_policy);
}

test "a thread's parameters carry the sandbox policy and the model" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const params = try threadStartParams(a, "/tmp/work", .supervised, false, "gpt-5");
    const json = try std.json.Stringify.valueAlloc(a, params, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"cwd\":\"/tmp/work\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"sandboxPolicy\":{\"type\":\"readOnly\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\":\"gpt-5\"") != null);
    // No model chosen: the member is left out, not sent as null.
    const bare = try threadStartParams(a, "/tmp/work", .default, false, null);
    const bare_json = try std.json.Stringify.valueAlloc(a, bare, .{});
    try std.testing.expect(std.mem.indexOf(u8, bare_json, "\"model\"") == null);
}

test "a turn's input is the text and its pictures" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var data = "\x89PNG".*;
    const images = [_]types.Image{.{ .name = "s.png", .mime = "image/png", .data = &data }};
    const params = try turnStartParams(a, "th1", .default, false, null, "high", "look", &images);
    const json = try std.json.Stringify.valueAlloc(a, params, .{});
    try std.testing.expect(std.mem.indexOf(u8, json, "\"threadId\":\"th1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"text\":\"look\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"url\":\"data:image/png;base64,") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"effort\":\"high\"") != null);
}

test "codex's notifications map to harness events" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const delta = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"delta\":\"hi\"}", .{});
    try std.testing.expectEqualStrings("hi", mapNotification(a, "item/agentMessage/delta", delta)[0].message_delta);
    const thought = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"delta\":\"why\"}", .{});
    try std.testing.expectEqualStrings("why", mapNotification(a, "item/reasoning/textDelta", thought)[0].reasoning_delta);
    const usage = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"tokenUsage":{"last":{"totalTokens":120},"modelContextWindow":400}}
    , .{});
    const ctx = mapNotification(a, "thread/tokenUsage/updated", usage)[0].context;
    try std.testing.expectEqual(@as(?u32, 120), ctx.used);
    try std.testing.expectEqual(@as(?u32, 400), ctx.window);
}

test "a command item becomes a row with its command and output" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const started = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"item":{"id":"c1","type":"commandExecution","command":"zig build test","status":"inProgress"}}
    , .{});
    const start = mapNotification(a, "item/started", started)[0].tool_start;
    try std.testing.expectEqualStrings("zig build test", start.name);
    try std.testing.expectEqual(types.ToolKind.execute, start.kind);

    const done = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"item":{"id":"c1","type":"commandExecution","command":["/bin/zsh","-lc","rg --files"],"aggregatedOutput":"a.zig","status":"completed"}}
    , .{});
    const result = mapNotification(a, "item/completed", done)[0].tool_result;
    try std.testing.expectEqualStrings("rg --files", commandText(obj(done, "item").? ).?);
    try std.testing.expectEqualStrings("a.zig", result.output);
    try std.testing.expectEqual(types.ToolStatus.completed, result.status);
}

test "a plan update and a finished turn" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plan_update = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"turnId":"t1","plan":[{"step":"Read","status":"completed"},{"step":"Write","status":"pending"}]}
    , .{});
    const entries = mapNotification(a, "turn/plan/updated", plan_update)[0].plan;
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("Write", entries[1].text);

    const done = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"turn\":{\"status\":\"completed\"}}", .{});
    const events = mapNotification(a, "turn/completed", done);
    try std.testing.expectEqual(@as(usize, 3), events.len);
    try std.testing.expectEqualStrings("", events[2].turn_ended);

    const failed = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"turn":{"status":"failed","error":{"message":"boom"}}}
    , .{});
    const failure = mapNotification(a, "turn/completed", failed);
    try std.testing.expectEqualStrings("boom", failure[2].session_error);
}
