//! Pi's RPC mode: JSONL over its stdin and stdout (`pi --mode rpc`), not
//! JSON-RPC and not ACP. Commands go out with an `id`, responses come back
//! with it, and session events come unprompted, in order.
const std = @import("std");
const proc = @import("proc.zig");

/// A command's response: `data`, or `err` with its message. `data` lives in
/// `arena`, freed when the callback returns. `id` is the command's, so a
/// callback can tell its answer from one for a later command.
pub const Callback = *const fn (ctx: *anyopaque, data: ?std.json.Value, err: ?[]const u8, arena: std.mem.Allocator, id: i64) void;

const Pending = struct { ctx: *anyopaque, func: Callback };

pub const Handler = struct {
    ctx: *anyopaque,
    /// A session event (`agent_start`, `message_update`, `tool_execution_*`,
    /// …), or a request from an extension (`extension_ui_request`).
    event: *const fn (ctx: *anyopaque, record: std.json.Value, arena: std.mem.Allocator) void,
    exited: *const fn (ctx: *anyopaque, code: i32) void,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    process: proc.Process = undefined,
    handler: Handler,
    line: std.ArrayList(u8) = .empty,
    next_id: i64 = 1,
    pending: std.AutoHashMapUnmanaged(i64, Pending) = .empty,
    alive: bool = false,
    /// What Pi wrote to stderr, for errors.
    stderr: proc.Tail,

    pub fn init(gpa: std.mem.Allocator, handler: Handler) Client {
        return .{ .gpa = gpa, .handler = handler, .stderr = .{ .gpa = gpa } };
    }

    pub fn deinit(c: *Client) void {
        if (c.alive) c.process.close();
        c.alive = false;
        c.line.deinit(c.gpa);
        c.pending.deinit(c.gpa);
        c.stderr.deinit();
    }

    pub fn start(c: *Client, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8, cwd: [*:0]const u8) !void {
        try c.stderr.open();
        try proc.spawnPipesErr(&c.process, argv, envp, cwd, false, c.stderr.write_fd, .{ .ctx = c, .output = onOutput, .exited = onExited });
        c.stderr.closeWriteEnd();
        c.alive = true;
        // Pi sends no greeting: the session's state is asked for as soon as
        // it runs (the owner sends its own commands then).
    }

    fn send(c: *Client, bytes: []const u8) void {
        if (c.alive) c.process.send(bytes);
    }

    /// Sends a command; `func` gets its response, with the command's id.
    pub fn command(c: *Client, kind: []const u8, fields: anytype, ctx: *anyopaque, func: Callback) !i64 {
        const id = c.next_id;
        c.next_id += 1;
        const line = try encode(c.gpa, kind, id, fields);
        defer c.gpa.free(line);
        try c.pending.put(c.gpa, id, .{ .ctx = ctx, .func = func });
        c.send(line);
        return id;
    }

    /// A command whose response nothing needs (`get_commands`, a mode).
    pub fn commandNoReply(c: *Client, kind: []const u8, fields: anytype) void {
        const line = encode(c.gpa, kind, null, fields) catch return;
        defer c.gpa.free(line);
        c.send(line);
    }

    /// Answers an extension's UI request, whose `id` is a string.
    pub fn extensionResponse(c: *Client, id: []const u8, fields: anytype) void {
        var aw: std.Io.Writer.Allocating = .init(c.gpa);
        defer aw.deinit();
        aw.writer.writeAll("{\"type\":\"extension_ui_response\",\"id\":") catch return;
        std.json.Stringify.encodeJsonString(id, .{}, &aw.writer) catch return;
        writeFields(&aw.writer, fields) catch return;
        aw.writer.writeAll("}\n") catch return;
        c.send(aw.written());
    }

    fn onOutput(ctx: *anyopaque, bytes: []const u8) void {
        const c: *Client = @ptrCast(@alignCast(ctx));
        c.line.appendSlice(c.gpa, bytes) catch return;
        // Strict JSONL: split on LF only (strip a CR), never on U+2028/9.
        while (std.mem.indexOfScalar(u8, c.line.items, '\n')) |nl| {
            const msg = std.mem.trimEnd(u8, c.line.items[0..nl], "\r");
            if (std.mem.trim(u8, msg, " \r\t").len > 0) c.dispatch(msg);
            const rest = c.line.items.len - nl - 1;
            std.mem.copyForwards(u8, c.line.items[0..rest], c.line.items[nl + 1 ..]);
            c.line.items.len = rest;
        }
    }

    fn onExited(ctx: *anyopaque, code: i32) void {
        const c: *Client = @ptrCast(@alignCast(ctx));
        c.alive = false;
        // Commands still waiting will never be answered.
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        var it = c.pending.iterator();
        while (it.next()) |e| e.value_ptr.func(e.value_ptr.ctx, null, "the agent exited", arena.allocator(), e.key_ptr.*);
        c.pending.clearRetainingCapacity();
        c.handler.exited(c.handler.ctx, code);
    }

    fn dispatch(c: *Client, msg: []const u8) void {
        var arena: std.heap.ArenaAllocator = .init(c.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, msg, .{}) catch return;
        if (v != .object) return;
        const o = v.object;
        const kind = if (o.get("type")) |t| (if (t == .string) t.string else "") else "";
        if (!std.mem.eql(u8, kind, "response")) {
            c.handler.event(c.handler.ctx, v, a);
            return;
        }
        // A response to one of ours: by its string id. A parse error has no
        // id and no one waiting for it.
        if (o.get("id")) |i| {
            if (i != .string) return;
            const id = std.fmt.parseInt(i64, i.string, 10) catch return;
            const p = c.pending.fetchRemove(id) orelse return;
            const ok = if (o.get("success")) |s| (s == .bool and s.bool) else false;
            if (ok) return p.value.func(p.value.ctx, o.get("data") orelse .null, null, a, id);
            const text = if (o.get("error")) |e| (if (e == .string) e.string else "error") else "error";
            p.value.func(p.value.ctx, null, text, a, id);
            return;
        }
    }
};

/// One command, as JSONL: `{"id":"1","type":"prompt","message":"…"}`.
fn encode(gpa: std.mem.Allocator, kind: []const u8, id: ?i64, fields: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    try aw.writer.writeByte('{');
    if (id) |n| try aw.writer.print("\"id\":\"{d}\",", .{n});
    try aw.writer.writeAll("\"type\":");
    try std.json.Stringify.encodeJsonString(kind, .{}, &aw.writer);
    try writeFields(&aw.writer, fields);
    try aw.writer.writeAll("}\n");
    return aw.toOwnedSlice();
}

/// The rest of a command object: `fields`' names and values. A null field
/// is left out: Pi reads an absent `images` as none.
fn writeFields(w: *std.Io.Writer, fields: anytype) !void {
    const info = @typeInfo(@TypeOf(fields)).@"struct";
    inline for (info.field_names, info.field_types) |name, T| {
        const v = @field(fields, name);
        const omit = switch (T) {
            @TypeOf(null) => true,
            ?[]const u8 => v == null,
            ?[]const Image => v == null,
            else => false,
        };
        if (omit) continue;
        try w.writeAll(",\"");
        try w.writeAll(name);
        try w.writeAll("\":");
        try std.json.Stringify.value(v, .{}, w);
    }
}

/// The string field `key` of JSON object `v`, or null.
pub fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    return if (f == .string) f.string else null;
}

pub fn obj(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

/// An image in a prompt: base64, with its type. Pi takes no `uri`.
pub const Image = struct {
    data: []const u8,
    mime: []const u8,

    pub fn jsonStringify(im: Image, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("image");
        try jw.objectField("data");
        try jw.beginWriteRaw();
        try jw.writer.writeByte('"');
        try std.base64.standard.Encoder.encodeWriter(jw.writer, im.data);
        try jw.writer.writeByte('"');
        jw.endWriteRaw();
        try jw.objectField("mimeType");
        try jw.write(im.mime);
        try jw.endObject();
    }
};

test "commands are JSONL, with an id first and no null fields" {
    const gpa = std.testing.allocator;
    const prompt = try encode(gpa, "prompt", 7, .{ .message = "hi", .images = null });
    defer gpa.free(prompt);
    try std.testing.expectEqualStrings("{\"id\":\"7\",\"type\":\"prompt\",\"message\":\"hi\"}\n", prompt);
    const set = try encode(gpa, "set_model", 8, .{ .provider = "anthropic", .modelId = "sonnet" });
    defer gpa.free(set);
    try std.testing.expectEqualStrings("{\"id\":\"8\",\"type\":\"set_model\",\"provider\":\"anthropic\",\"modelId\":\"sonnet\"}\n", set);
}

test "a picture in a prompt: base64, its type, no uri" {
    const gpa = std.testing.allocator;
    var data = "\x89PNG\r\n\x1a\n".*;
    const images = [_]Image{.{ .data = &data, .mime = "image/png" }};
    const json = try std.json.Stringify.valueAlloc(gpa, images, .{});
    defer gpa.free(json);
    try std.testing.expectEqualStrings("[{\"type\":\"image\",\"data\":\"iVBORw0KGgo=\",\"mimeType\":\"image/png\"}]", json);
}

/// `provider/id` split for `set_model`; a bare id keeps `fallback`.
pub fn providerId(value: []const u8, fallback: []const u8) struct { provider: []const u8, id: []const u8 } {
    if (std.mem.indexOfScalar(u8, value, '/')) |slash| return .{ .provider = value[0..slash], .id = value[slash + 1 ..] };
    return .{ .provider = fallback, .id = value };
}

test "a model value is provider and id, as set_model wants" {
    const a = providerId("anthropic/claude-sonnet", "");
    try std.testing.expectEqualStrings("anthropic", a.provider);
    try std.testing.expectEqualStrings("claude-sonnet", a.id);
    const b = providerId("gpt-5", "openai");
    try std.testing.expectEqualStrings("openai", b.provider);
    try std.testing.expectEqualStrings("gpt-5", b.id);
}
