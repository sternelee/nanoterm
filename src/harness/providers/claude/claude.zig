//! Claude Code as a harness provider: the real CLI in stream-json mode
//! (`claude -p --input-format stream-json --output-format stream-json
//! --verbose`), not a third-party ACP adapter. Turns go in as JSON lines,
//! every event comes back as one, and a permission request is answered with
//! a `control_response` on the same stdin.
const std = @import("std");
const proc = @import("../../../proc.zig");
const agents = @import("../../../agents.zig");
const agent_claude = @import("../../../agent_claude.zig");
const types = @import("../../types.zig");
const protocol = @import("claude_protocol.zig");

pub const id = types.ids.claude;
pub const label = "Claude Code";

const Live = struct {
    provider: *ClaudeProvider,
    client: agent_claude.Client,
    /// The session id this live is filed under (owned).
    key: []const u8 = "",
    /// The provider's session id, once `system/init` named it.
    session_id: []const u8 = "",
    cwd: []const u8 = "",
    model: ?[]const u8 = null,
    runtime_mode: types.RuntimeMode = .default,
    planning: bool = false,
    /// True once `system/init` arrived: the CLI is promptable.
    promptable: bool = false,
    sink_ctx: *anyopaque = undefined,
    sink: ?*const fn (ctx: *anyopaque, event: types.HarnessEvent) void = null,
    pending_text: ?[]const u8 = null,
    pending_images: []const types.Image = &.{},
    /// A permission request awaiting an answer: rpc id → its tool input.
    approvals: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    stderr_shown: usize = 0,
};

const Resume = struct {
    cwd: []const u8,
    session_id: []const u8,
};

pub const ClaudeProvider = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    live: std.StringHashMapUnmanaged(*Live) = .empty,
    resume_map: std.StringHashMapUnmanaged(Resume) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) ClaudeProvider {
        return .{ .gpa = gpa, .io = io, .env = env };
    }

    pub fn deinit(p: *ClaudeProvider) void {
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(p.gpa);
        var it = p.live.iterator();
        while (it.next()) |e| keys.append(p.gpa, e.key_ptr.*) catch {};
        for (keys.items) |k| p.stopSession(k);
        p.live.deinit(p.gpa);
        var rit = p.resume_map.iterator();
        while (rit.next()) |e| {
            p.gpa.free(e.key_ptr.*);
            p.gpa.free(e.value_ptr.cwd);
            p.gpa.free(e.value_ptr.session_id);
        }
        p.resume_map.deinit(p.gpa);
    }

    pub fn sendTurn(p: *ClaudeProvider, input: *const types.SendTurnInput, sink_ctx: *anyopaque) !void {
        const live = try p.ensureLive(input, sink_ctx);
        live.sink_ctx = sink_ctx;
        live.sink = input.on_event;
        live.runtime_mode = input.runtime_mode;
        live.planning = input.intent == .plan;
        if (live.promptable) return p.prompt(live, input);
        if (live.pending_text) |t| p.gpa.free(t);
        live.pending_text = try p.gpa.dupe(u8, input.prompt);
        live.pending_images = input.images;
    }

    pub fn cancelTurn(p: *ClaudeProvider, session_id: []const u8) !void {
        const live = p.live.get(session_id) orelse return error.SessionNotFound;
        if (!live.client.alive) return;
        // Claude takes an interrupt as a control request on stdin.
        live.client.sendRaw("{\"type\":\"control_request\",\"request_id\":\"nanoterm-interrupt\",\"request\":{\"subtype\":\"interrupt\"}}\n");
        p.emit(live, .{ .turn_cancelled = {} });
    }

    pub fn stopSession(p: *ClaudeProvider, session_id: []const u8) void {
        const key = p.live.getKey(session_id) orelse return;
        const live = p.live.fetchRemove(key).?.value;
        p.destroyLive(live);
    }

    pub fn forgetSession(p: *ClaudeProvider, session_id: []const u8) void {
        p.stopSession(session_id);
        if (p.resume_map.fetchRemove(session_id)) |e| {
            p.gpa.free(e.key);
            p.gpa.free(e.value.cwd);
            p.gpa.free(e.value.session_id);
        }
    }

    pub fn respondApproval(p: *ClaudeProvider, session_id: []const u8, request_id: u32, decision: types.ApprovalDecision) void {
        const live = p.live.get(session_id) orelse return;
        const input = live.approvals.fetchRemove(request_id) orelse return;
        defer p.gpa.free(input.value);
        var aw: std.Io.Writer.Allocating = .init(p.gpa);
        defer aw.deinit();
        const w = &aw.writer;
        w.writeAll("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"") catch return;
        w.print("{d}", .{request_id}) catch return;
        w.writeAll("\",\"response\":") catch return;
        switch (decision) {
            .allow => {
                w.writeAll("{\"behavior\":\"allow\",\"updatedInput\":") catch return;
                w.writeAll(if (input.value.len > 0) input.value else "{}") catch return;
                w.writeAll("}") catch return;
            },
            .deny => w.writeAll("{\"behavior\":\"deny\",\"message\":\"denied in nanoterm\"}") catch return,
        }
        w.writeAll("}}\n") catch return;
        live.client.sendRaw(aw.written());
    }

    /// Answers an `AskUserQuestion`. Claude reads the picks out of
    /// `updatedInput.answers`, keyed by the question's own text, so the stored
    /// input is re-sent with that map added rather than replaced: the tool
    /// still needs its `questions` to know what was asked.
    pub fn respondQuestion(p: *ClaudeProvider, session_id: []const u8, request_id: u32, reply: types.UserQuestionReply) void {
        const live = p.live.get(session_id) orelse return;
        const stored = live.approvals.fetchRemove(request_id) orelse return;
        defer p.gpa.free(stored.value);
        const answer = switch (reply) {
            .text => |t| t,
            .choice => |i| blk: {
                // The card sends the option's index; claude wants the label.
                const picked = questionLabel(p.gpa, stored.value, i) orelse return;
                defer p.gpa.free(picked);
                break :blk picked;
            },
        };
        const question = questionText(p.gpa, stored.value) orelse return;
        defer p.gpa.free(question);
        const line = buildQuestionResponse(p.gpa, request_id, stored.value, question, answer) orelse return;
        defer p.gpa.free(line);
        live.client.sendRaw(line);
    }

    /// The `question` text of a stored `AskUserQuestion` input, which is the
    /// key claude files the answer under.
    fn questionText(gpa: std.mem.Allocator, input_json: []const u8) ?[]u8 {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, input_json, .{}) catch return null;
        const questions = protocol.obj(v, "questions") orelse return null;
        if (questions != .array or questions.array.items.len == 0) return null;
        const first = questions.array.items[0];
        const text = protocol.str(first, "question") orelse protocol.str(first, "header") orelse return null;
        return gpa.dupe(u8, text) catch null;
    }

    /// The label of the option at `index` in a stored `AskUserQuestion` input.
    fn questionLabel(gpa: std.mem.Allocator, input_json: []const u8, index: u32) ?[]u8 {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, input_json, .{}) catch return null;
        const questions = protocol.obj(v, "questions") orelse return null;
        if (questions != .array or questions.array.items.len == 0) return null;
        const options = protocol.obj(questions.array.items[0], "options") orelse return null;
        if (options != .array or index >= options.array.items.len) return null;
        const text = protocol.str(options.array.items[index], "label") orelse return null;
        return gpa.dupe(u8, text) catch null;
    }

    fn destroyLive(p: *ClaudeProvider, live: *Live) void {
        live.client.deinit();
        var ait = live.approvals.iterator();
        while (ait.next()) |e| p.gpa.free(e.value_ptr.*);
        live.approvals.deinit(p.gpa);
        p.gpa.free(live.cwd);
        if (live.model) |m| p.gpa.free(m);
        if (live.session_id.len > 0) p.gpa.free(live.session_id);
        if (live.pending_text) |t| p.gpa.free(t);
        p.gpa.free(live.key);
        p.gpa.destroy(live);
    }

    fn ensureLive(p: *ClaudeProvider, input: *const types.SendTurnInput, sink_ctx: *anyopaque) !*Live {
        if (p.live.get(input.session_id)) |live| {
            if (std.mem.eql(u8, live.cwd, input.cwd)) return live;
            p.stopSession(input.session_id);
        }
        const live = try p.gpa.create(Live);
        const key = try p.gpa.dupe(u8, input.session_id);
        live.* = .{
            .provider = p,
            .client = undefined,
            .key = key,
            .cwd = try p.gpa.dupe(u8, input.cwd),
            .model = if (input.model) |m| try p.gpa.dupe(u8, m) else null,
            .sink_ctx = sink_ctx,
            .sink = input.on_event,
        };
        errdefer p.destroyLive(live);
        live.client = agent_claude.Client.init(p.gpa, .{ .ctx = live, .message = onMessage, .exited = onExited });
        try p.live.put(p.gpa, key, live);
        p.start(live, input) catch |err| {
            p.stopSession(input.session_id);
            return err;
        };
        return live;
    }

    fn start(p: *ClaudeProvider, live: *Live, input: *const types.SendTurnInput) !void {
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const path = agents.searchPath(arena, p.env.get("PATH") orelse "", p.env.get("HOME") orelse "/");
        const bin = proc.which(arena, p.io, path, "claude") orelse return error.NotInstalled;
        const parked = p.resume_map.get(live.key);
        const args = try protocol.buildClaudeSpawnArgs(arena, .{
            .model = live.model,
            .effort = if (input.model_settings) |s| s.effort else null,
            .resume_session = if (parked) |r| r.session_id else null,
            .isolated = false,
            .permission_mode = protocol.runtimeModeToPermission(live.runtime_mode),
        });
        var items: std.ArrayList([]const u8) = .empty;
        try items.append(arena, bin);
        try items.appendSlice(arena, args);
        const argv = try proc.cStrings(arena, items.items);
        const env_strings = try p.envp(arena);
        const cwd_z = try arena.dupeSentinel(u8, live.cwd, 0);
        try live.client.start(argv, env_strings, cwd_z);
    }

    fn envp(p: *ClaudeProvider, arena: std.mem.Allocator) ![*:null]const ?[*:0]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        var it = p.env.iterator();
        while (it.next()) |e| {
            if (std.mem.eql(u8, e.key_ptr.*, "PATH")) continue;
            list.append(arena, try std.fmt.allocPrint(arena, "{s}={s}", .{ e.key_ptr.*, e.value_ptr.* })) catch {};
        }
        const path = agents.searchPath(arena, p.env.get("PATH") orelse "", p.env.get("HOME") orelse "/");
        try list.append(arena, try std.fmt.allocPrint(arena, "PATH={s}", .{path}));
        return proc.cStrings(arena, list.items);
    }

    fn prompt(p: *ClaudeProvider, live: *Live, input: *const types.SendTurnInput) !void {
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        var line: std.Io.Writer.Allocating = .init(p.gpa);
        defer line.deinit();
        try protocol.writeUserLine(&line.writer, input.prompt, input.images);
        p.emit(live, .{ .turn_started = live.session_id });
        live.client.sendRaw(line.written());
    }

    fn emit(p: *ClaudeProvider, live: *Live, event: types.HarnessEvent) void {
        _ = p;
        if (live.sink) |s| s(live.sink_ctx, event);
    }

    fn drainStderr(p: *ClaudeProvider, live: *Live) void {
        const text = live.client.stderr.bytes.items;
        while (std.mem.indexOfScalarPos(u8, text, live.stderr_shown, '\n')) |nl| {
            const line = std.mem.trim(u8, text[live.stderr_shown..nl], " \t\r");
            live.stderr_shown = nl + 1;
            if (line.len > 0) p.emit(live, .{ .note = line });
        }
    }

    fn onMessage(ctx: *anyopaque, v: std.json.Value, arena: std.mem.Allocator) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        const p = live.provider;
        if (protocol.isInitMessage(v)) {
            if (protocol.str(v, "session_id")) |sid| {
                if (live.session_id.len == 0) live.session_id = p.gpa.dupe(u8, sid) catch "";
                if (p.resume_map.fetchRemove(live.key)) |old| {
                    p.gpa.free(old.key);
                    p.gpa.free(old.value.cwd);
                    p.gpa.free(old.value.session_id);
                }
                p.resume_map.put(p.gpa, p.gpa.dupe(u8, live.key) catch return, .{
                    .cwd = p.gpa.dupe(u8, live.cwd) catch return,
                    .session_id = p.gpa.dupe(u8, sid) catch return,
                }) catch {};
            }
            live.promptable = true;
        }
        // Remember a permission request's tool input, to echo back on allow.
        if (std.mem.eql(u8, protocol.str(v, "type") orelse "", "control_request")) {
            if (protocol.obj(v, "request")) |request| {
                if (std.mem.eql(u8, protocol.str(request, "subtype") orelse "", "can_use_tool")) {
                    const request_id = std.fmt.parseInt(u32, protocol.str(v, "request_id") orelse "", 10) catch 0;
                    if (request_id != 0) {
                        const input = if (protocol.obj(request, "input")) |i| std.json.Stringify.valueAlloc(p.gpa, i, .{}) catch null else null;
                        live.approvals.put(p.gpa, request_id, input orelse p.gpa.dupe(u8, "{}") catch "{}") catch {};
                    }
                }
            }
        }
        for (protocol.mapMessage(arena, v)) |event| p.emit(live, event);
        // The turn ended with a result; anything waiting in the session runs now.
        if (live.pending_text) |text| {
            live.promptable = true;
            live.pending_text = null;
            const images = live.pending_images;
            live.pending_images = &.{};
            defer p.gpa.free(text);
            const sink = live.sink orelse return;
            const input = types.SendTurnInput{ .session_id = live.key, .cwd = live.cwd, .prompt = text, .images = images, .on_event = sink };
            p.prompt(live, &input) catch |e| p.emit(live, .{ .session_error = @errorName(e) });
        }
    }

    fn onExited(ctx: *anyopaque, code: i32) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        live.provider.drainStderr(live);
        live.provider.emit(live, .{ .session_ended = code });
    }
};
/// The `control_response` that answers an `AskUserQuestion`: the stored
/// input re-sent with an `answers` map beside its `questions`, because
/// claude reads the picks out of `updatedInput.answers` and still needs
/// the questions to know what they answer.
fn buildQuestionResponse(gpa: std.mem.Allocator, request_id: u32, input_json: []const u8, question: []const u8, answer: []const u8) ?[]u8 {
    var aw: std.Io.Writer.Allocating = .init(gpa);
    errdefer aw.deinit();
    const w = &aw.writer;
    w.writeAll("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"") catch return null;
    w.print("{d}", .{request_id}) catch return null;
    w.writeAll("\",\"response\":{\"behavior\":\"allow\",\"updatedInput\":") catch return null;
    const body = std.mem.trim(u8, input_json, " \t\r\n");
    if (body.len >= 2 and body[0] == '{' and body[body.len - 1] == '}') {
        const inner = std.mem.trim(u8, body[1 .. body.len - 1], " \t\r\n");
        w.writeAll("{") catch return null;
        if (inner.len > 0) {
            w.writeAll(inner) catch return null;
            w.writeAll(",") catch return null;
        }
        w.writeAll("\"answers\":{") catch return null;
        std.json.Stringify.encodeJsonString(question, .{}, w) catch return null;
        w.writeAll(":") catch return null;
        std.json.Stringify.encodeJsonString(answer, .{}, w) catch return null;
        w.writeAll("}}") catch return null;
    } else {
        w.writeAll(body) catch return null;
    }
    w.writeAll("}}}\n") catch return null;
    return aw.toOwnedSlice() catch null;
}


test "a question's answer keeps the questions and adds the picks" {
    const gpa = std.testing.allocator;
    const input =
        \\{"questions":[{"question":"Which color do you prefer?","header":"Color","options":[{"label":"Red","description":"Red"},{"label":"Blue","description":"Blue"}],"multiSelect":false}]}
    ;
    const line = buildQuestionResponse(gpa, 9, input, "Which color do you prefer?", "Blue") orelse return error.NoLine;
    defer gpa.free(line);

    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
    defer parsed.deinit();
    const response = parsed.value.object.get("response").?.object;
    try std.testing.expectEqualStrings("success", response.get("subtype").?.string);
    try std.testing.expectEqualStrings("9", response.get("request_id").?.string);
    const inner = response.get("response").?.object;
    try std.testing.expectEqualStrings("allow", inner.get("behavior").?.string);

    // The tool's own input survives, and the answer is filed under the
    // question's text, which is the key claude looks it up by.
    const updated = inner.get("updatedInput").?.object;
    try std.testing.expectEqual(@as(usize, 1), updated.get("questions").?.array.items.len);
    try std.testing.expectEqualStrings("Blue", updated.get("answers").?.object.get("Which color do you prefer?").?.string);
}
