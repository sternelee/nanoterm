//! Claude Code, driven through its own streaming CLI rather than a third-party
//! ACP adapter. The process is `claude -p --input-format stream-json
//! --output-format stream-json --verbose`: user turns go in as JSON lines on
//! stdin, and every event (system/init, assistant, user, result, control
//! requests) comes back as a JSON line on stdout. This client owns the
//! process, splits stdout into lines, and hands each parsed message to the
//! handler; it keeps no request/response ids, as the stream has none.
const std = @import("std");
const proc = @import("proc.zig");

pub const Handler = struct {
    ctx: *anyopaque,
    /// One JSON message of the stream; `v` and the strings in it live in
    /// `arena`, freed when the handler returns.
    message: *const fn (ctx: *anyopaque, v: std.json.Value, arena: std.mem.Allocator) void,
    /// The process ended (or could not be watched any more).
    exited: *const fn (ctx: *anyopaque, code: i32) void,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    process: proc.Process = undefined,
    handler: Handler,
    line: std.ArrayList(u8) = .empty,
    alive: bool = false,
    /// What the agent wrote to stderr, for errors.
    stderr: proc.Tail,

    pub fn init(gpa: std.mem.Allocator, handler: Handler) Client {
        return .{ .gpa = gpa, .handler = handler, .stderr = .{ .gpa = gpa } };
    }

    pub fn deinit(c: *Client) void {
        if (c.alive) c.process.close();
        c.alive = false;
        c.line.deinit(c.gpa);
        c.stderr.deinit();
    }

    pub fn start(c: *Client, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, cwd: [*:0]const u8) !void {
        try c.stderr.open();
        try proc.spawnPipesErr(&c.process, argv, envp, cwd, false, c.stderr.write_fd, .{ .ctx = c, .output = onOutput, .exited = onExited });
        c.stderr.closeWriteEnd();
        c.alive = true;
    }

    /// A user turn, as the stream-json input wants it: one line, the text in
    /// a content block. Sent as the CLI is promptable (after `system/init`).
    pub fn sendText(c: *Client, text: []const u8) void {
        var aw: std.Io.Writer.Allocating = .init(c.gpa);
        defer aw.deinit();
        writeTextLine(&aw.writer, text) catch return;
        if (c.alive) c.process.send(aw.written());
    }

    /// Raw bytes to stdin (a control response, once those are wired).
    pub fn sendRaw(c: *Client, bytes: []const u8) void {
        if (c.alive) c.process.send(bytes);
    }

    fn onOutput(ctx: *anyopaque, bytes: []const u8) void {
        const c: *Client = @ptrCast(@alignCast(ctx));
        c.line.appendSlice(c.gpa, bytes) catch return;
        while (std.mem.indexOfScalar(u8, c.line.items, '\n')) |nl| {
            const msg = c.line.items[0..nl];
            if (std.mem.trim(u8, msg, " \r").len > 0) c.dispatch(msg);
            const rest = c.line.items.len - nl - 1;
            std.mem.copyForwards(u8, c.line.items[0..rest], c.line.items[nl + 1 ..]);
            c.line.items.len = rest;
        }
    }

    fn onExited(ctx: *anyopaque, code: i32) void {
        const c: *Client = @ptrCast(@alignCast(ctx));
        c.alive = false;
        c.handler.exited(c.handler.ctx, code);
    }

    fn dispatch(c: *Client, msg: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, msg, .{}) catch return;
        if (v != .object) return;
        c.handler.message(c.handler.ctx, v, a);
    }
};

/// The stream-json input line for a user's text: `{"type":"user","message":
/// {"role":"user","content":[{"type":"text","text":…}]}}`.
pub fn writeTextLine(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":");
    try std.json.Stringify.encodeJsonString(text, .{}, w);
    try w.writeAll("}]}}\n");
}

/// The `type` of a stream message (`system`, `assistant`, `user`, `result`,
/// `control_request`, …), or "".
pub fn typeOf(v: std.json.Value) []const u8 {
    if (v != .object) return "";
    const t = v.object.get("type") orelse return "";
    return if (t == .string) t.string else "";
}

/// The `subtype` of a stream message, or "".
pub fn subtypeOf(v: std.json.Value) []const u8 {
    if (v != .object) return "";
    const t = v.object.get("subtype") orelse return "";
    return if (t == .string) t.string else "";
}

/// The string field `key` of object `v`, or null.
pub fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

/// The object field `key` of `v`, or null.
pub fn obj(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

test "a user turn writes the stream-json input line" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeTextLine(&aw.writer, "hi \"there\"\n");
    const line = aw.written();
    try std.testing.expect(std.mem.endsWith(u8, line, "}\n"));
    const v = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, line, .{});
    defer v.deinit();
    try std.testing.expectEqualStrings("user", typeOf(v.value));
    const msg = obj(v.value, "message").?;
    try std.testing.expectEqualStrings("user", str(msg, "role").?);
    const content = obj(msg, "content").?;
    try std.testing.expectEqual(@as(usize, 1), content.array.items.len);
    try std.testing.expectEqualStrings("text", typeOf(content.array.items[0]));
    try std.testing.expectEqualStrings("hi \"there\"\n", str(content.array.items[0], "text").?);
}

test "stream messages are classified by type and subtype" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const init_ = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"type":"system","subtype":"init","session_id":"s1","model":"m"}
    , .{});
    try std.testing.expectEqualStrings("system", typeOf(init_));
    try std.testing.expectEqualStrings("init", subtypeOf(init_));
    try std.testing.expectEqualStrings("s1", str(init_, "session_id").?);
    const result = try std.json.parseFromSliceLeaky(std.json.Value, a, "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false}", .{});
    try std.testing.expectEqualStrings("result", typeOf(result));
    try std.testing.expectEqualStrings("success", subtypeOf(result));
}
