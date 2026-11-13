//! Codex's app-server as a harness provider: it owns the `codex app-server`
//! child, the headerless JSON-RPC session, the thread, and the turn.
//!
//! The app-server also asks the client things (approve a command, answer a
//! question, read the clock), so this provider answers those requests rather
//! than declaring capabilities it does not have.
const std = @import("std");
const acp = @import("../../../acp.zig");
const proc = @import("../../../proc.zig");
const agents = @import("../../../agents.zig");
const types = @import("../../types.zig");
const protocol = @import("codex.zig");

/// A server request the turn is waiting on.
const Pending = struct {
    /// "command", "fileChange", "permissions", or "" for the ones answered
    /// without the user (a clock read, a declined question).
    kind: []const u8,
    /// The request's own parameters, to echo back what an allow needs.
    params_json: []const u8,
    /// A question's own `id`, which is the key its answer is filed under.
    question_id: ?[]const u8 = null,
};

const Live = struct {
    provider: *CodexProvider,
    client: acp.Client,
    key: []const u8 = "",
    cwd: []const u8 = "",
    thread_id: []const u8 = "",
    model: ?[]const u8 = null,
    runtime_mode: types.RuntimeMode = .default,
    planning: bool = false,
    ready: bool = false,
    failed: bool = false,
    /// The turn running now, as `turn/started` named it.
    turn_id: []const u8 = "",
    sink_ctx: *anyopaque = undefined,
    sink: ?*const fn (ctx: *anyopaque, event: types.HarnessEvent) void = null,
    pending_text: ?[]const u8 = null,
    pending_images: []const types.Image = &.{},
    pending_effort: ?[]const u8 = null,
    approvals: std.AutoHashMapUnmanaged(u32, Pending) = .empty,
};

const Resume = struct {
    thread_id: []const u8,
    cwd: []const u8,
};

pub const CodexProvider = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    live: std.StringHashMapUnmanaged(*Live) = .empty,
    resume_map: std.StringHashMapUnmanaged(Resume) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) CodexProvider {
        return .{ .gpa = gpa, .io = io, .env = env };
    }

    pub fn deinit(p: *CodexProvider) void {
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(p.gpa);
        var it = p.live.iterator();
        while (it.next()) |e| keys.append(p.gpa, e.key_ptr.*) catch {};
        for (keys.items) |k| p.stopSession(k);
        p.live.deinit(p.gpa);
        var rit = p.resume_map.iterator();
        while (rit.next()) |e| {
            p.gpa.free(e.key_ptr.*);
            p.gpa.free(e.value_ptr.thread_id);
            p.gpa.free(e.value_ptr.cwd);
        }
        p.resume_map.deinit(p.gpa);
    }

    pub fn sendTurn(p: *CodexProvider, input: *const types.SendTurnInput, sink_ctx: *anyopaque) !void {
        const live = try p.ensureLive(input, sink_ctx);
        live.sink_ctx = sink_ctx;
        live.sink = input.on_event;
        live.runtime_mode = input.runtime_mode;
        live.planning = input.intent == .plan;
        if (live.ready) return p.prompt(live, input);
        if (live.pending_text) |t| p.gpa.free(t);
        live.pending_text = try p.gpa.dupe(u8, input.prompt);
        live.pending_images = input.images;
    }

    pub fn cancelTurn(p: *CodexProvider, session_id: []const u8) !void {
        const live = p.live.get(session_id) orelse return error.SessionNotFound;
        if (!live.client.alive or live.thread_id.len == 0) return;
        if (live.turn_id.len == 0) return;
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var map = std.json.ObjectMap.empty;
        try map.put(arena, "threadId", .{ .string = live.thread_id });
        try map.put(arena, "turnId", .{ .string = live.turn_id });
        live.client.request("turn/interrupt", std.json.Value{ .object = map }, live, onNoReply) catch {};
        p.emit(live, .{ .turn_cancelled = {} });
    }

    /// Folds a follow-up into the turn already running. Codex refuses a steer
    /// whose turn has ended, which is what makes a late one safe: it fails
    /// rather than landing in some other turn.
    pub fn steerTurn(p: *CodexProvider, input: *const types.SteerTurnInput) !void {
        const live = p.live.get(input.session_id) orelse return error.SessionNotFound;
        if (!live.client.alive or live.thread_id.len == 0) return error.SessionNotReady;
        if (live.turn_id.len == 0) return error.TurnNotReady;
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const params = try protocol.steerParams(arena_state.allocator(), live.thread_id, live.turn_id, input.text, &.{});
        try live.client.request("turn/steer", params, live, onNoReply);
    }

    pub fn stopSession(p: *CodexProvider, session_id: []const u8) void {
        const key = p.live.getKey(session_id) orelse return;
        const live = p.live.fetchRemove(key).?.value;
        p.destroyLive(live);
    }

    pub fn forgetSession(p: *CodexProvider, session_id: []const u8) void {
        p.stopSession(session_id);
        if (p.resume_map.fetchRemove(session_id)) |e| {
            p.gpa.free(e.key);
            p.gpa.free(e.value.thread_id);
            p.gpa.free(e.value.cwd);
        }
    }

    pub fn respondApproval(p: *CodexProvider, session_id: []const u8, request_id: u32, decision: types.ApprovalDecision) void {
        const live = p.live.get(session_id) orelse return;
        const pending = live.approvals.fetchRemove(request_id) orelse return;
        defer p.gpa.free(pending.value.kind);
        defer p.gpa.free(pending.value.params_json);
        var buf: [32]u8 = undefined;
        const id_json = std.fmt.bufPrint(&buf, "{d}", .{request_id}) catch return;
        if (std.mem.eql(u8, pending.value.kind, "permissions")) {
            // A permission grant is echoed back whole; a denial grants nothing.
            if (decision == .allow) {
                var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
                defer arena_state.deinit();
                const arena = arena_state.allocator();
                const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, pending.value.params_json, .{}) catch return;
                const permissions = protocolObj(parsed, "permissions") orelse std.json.Value{ .object = std.json.ObjectMap.empty };
                var map = std.json.ObjectMap.empty;
                map.put(arena, "scope", .{ .string = "session" }) catch return;
                map.put(arena, "permissions", permissions) catch return;
                live.client.respond(id_json, std.json.Value{ .object = map });
            } else {
                live.client.respond(id_json, .{ .permissions = .{} });
            }
            return;
        }
        live.client.respond(id_json, .{ .decision = protocol.approvalDecision(decision) });
    }

    /// A question the agent wants a person to answer. Its options are the
    /// answers, so it is a question card rather than an approval one, and it
    /// is kept until `respond_question` names it.
    fn askQuestion(p: *CodexProvider, live: *Live, id: []const u8, params: std.json.Value, arena: std.mem.Allocator) void {
        const rpc_id = std.fmt.parseInt(u32, id, 10) catch return;
        const questions = protocolObj(params, "questions") orelse {
            live.client.respond(id, .{ .answers = .{} });
            return;
        };
        if (questions != .array or questions.array.items.len == 0) {
            live.client.respond(id, .{ .answers = .{} });
            return;
        }
        // One card per question, so a request carrying several asks them in
        // turn; the first is the one the card shows.
        const first = questions.array.items[0];
        const question_id = protocolStr(first, "id") orelse "";
        const text = protocolStr(first, "question") orelse "";
        const header = protocolStr(first, "header") orelse "";
        const title = if (header.len > 0) header else text;
        const options = p.gpa.alloc(types.QuestionOption, countOptions(first)) catch return;
        var filled: usize = 0;
        if (protocolObj(first, "options")) |opts| {
            if (opts == .array) for (opts.array.items) |o| {
                const label = protocolStr(o, "label") orelse continue;
                options[filled] = .{
                    .id = p.gpa.dupe(u8, label) catch break,
                    .name = p.gpa.dupe(u8, label) catch break,
                };
                filled += 1;
            };
        }
        if (filled == 0) {
            p.gpa.free(options);
            // Nothing to pick from: the question can only be typed, and the
            // card has no field for that, so it is declined rather than left
            // waiting on a person who cannot answer it.
            live.client.respond(id, .{ .answers = .{} });
            return;
        }
        const params_json = std.json.Stringify.valueAlloc(p.gpa, params, .{}) catch {
            for (options[0..filled]) |o| {
                p.gpa.free(o.id);
                p.gpa.free(o.name);
            }
            p.gpa.free(options);
            return;
        };
        live.approvals.put(p.gpa, rpc_id, .{
            .kind = p.gpa.dupe(u8, "question") catch {
                p.gpa.free(params_json);
                for (options[0..filled]) |o| {
                    p.gpa.free(o.id);
                    p.gpa.free(o.name);
                }
                p.gpa.free(options);
                return;
            },
            .params_json = params_json,
            .question_id = p.gpa.dupe(u8, question_id) catch null,
        }) catch {
            p.gpa.free(params_json);
            for (options[0..filled]) |o| {
                p.gpa.free(o.id);
                p.gpa.free(o.name);
            }
            p.gpa.free(options);
            return;
        };
        _ = arena;
        p.emit(live, .{ .question_asked = .{
            .request_id = rpc_id,
            .title = title,
            .options = options[0..filled],
        } });
    }

    /// Answers a question with the pick at `reply`. Codex files an answer
    /// under the question's own `id` as a list of strings, which is not the
    /// shape claude takes, so the two providers build their own reply.
    pub fn respondQuestion(p: *CodexProvider, session_id: []const u8, request_id: u32, reply: types.UserQuestionReply) void {
        const live = p.live.get(session_id) orelse return;
        const pending = live.approvals.fetchRemove(request_id) orelse return;
        defer p.gpa.free(pending.value.kind);
        defer p.gpa.free(pending.value.params_json);
        if (pending.value.question_id) |qid| p.gpa.free(qid);
        var buf: [32]u8 = undefined;
        const id_json = std.fmt.bufPrint(&buf, "{d}", .{request_id}) catch return;
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const answer = switch (reply) {
            .text => |t| t,
            .choice => |i| blk: {
                // The card sends the option's index; codex wants the label.
                const label = questionLabel(arena, pending.value.params_json, i) orelse break :blk "";
                break :blk label;
            },
        };
        const qid = pending.value.question_id orelse "";
        var one = std.json.Array.init(arena);
        one.append(.{ .string = answer }) catch return;
        var entry = std.json.ObjectMap.empty;
        entry.put(arena, "answers", .{ .array = one }) catch return;
        var map = std.json.ObjectMap.empty;
        map.put(arena, qid, .{ .object = entry }) catch return;
        live.client.respond(id_json, .{ .answers = std.json.Value{ .object = map } });
    }

    fn destroyLive(p: *CodexProvider, live: *Live) void {
        live.client.deinit();
        var ait = live.approvals.iterator();
        while (ait.next()) |e| {
            p.gpa.free(e.value_ptr.kind);
            p.gpa.free(e.value_ptr.params_json);
            if (e.value_ptr.question_id) |q| p.gpa.free(q);
        }
        live.approvals.deinit(p.gpa);
        p.gpa.free(live.cwd);
        if (live.model) |m| p.gpa.free(m);
        if (live.thread_id.len > 0) p.gpa.free(live.thread_id);
        if (live.turn_id.len > 0) p.gpa.free(live.turn_id);
        if (live.pending_text) |t| p.gpa.free(t);
        p.gpa.free(live.key);
        p.gpa.destroy(live);
    }

    fn ensureLive(p: *CodexProvider, input: *const types.SendTurnInput, sink_ctx: *anyopaque) !*Live {
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
        live.client = acp.Client.init(p.gpa, .{ .ctx = live, .request = onRequest, .notification = onNotification, .exited = onExited });
        // Codex's app-server frames carry no `jsonrpc` member.
        live.client.headerless = true;
        try p.live.put(p.gpa, key, live);
        p.start(live) catch |err| {
            p.stopSession(input.session_id);
            return err;
        };
        return live;
    }

    fn start(p: *CodexProvider, live: *Live) !void {
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const items = try protocol.argv(arena, p.io, p.env, live.model);
        const argv = try proc.cStrings(arena, items);
        const env_strings = try p.envp(arena);
        const cwd_z = try arena.dupeSentinel(u8, live.cwd, 0);
        try live.client.start(argv, env_strings, cwd_z);
        var params = std.json.ObjectMap.empty;
        var client_info = std.json.ObjectMap.empty;
        try client_info.put(arena, "name", .{ .string = "nanoterm" });
        try client_info.put(arena, "title", .{ .string = "nanoterm" });
        try client_info.put(arena, "version", .{ .string = "0.1.0" });
        var capabilities = std.json.ObjectMap.empty;
        try capabilities.put(arena, "experimentalApi", .{ .bool = true });
        try params.put(arena, "clientInfo", .{ .object = client_info });
        try params.put(arena, "capabilities", .{ .object = capabilities });
        try live.client.request("initialize", std.json.Value{ .object = params }, live, onInitialized);
    }

    fn envp(p: *CodexProvider, arena: std.mem.Allocator) ![*:null]const ?[*:0]const u8 {
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

    fn prompt(p: *CodexProvider, live: *Live, input: *const types.SendTurnInput) !void {
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const params = try protocol.turnStartParams(
            arena_state.allocator(),
            live.thread_id,
            live.runtime_mode,
            live.planning,
            live.model,
            if (input.model_settings) |s| s.effort else null,
            input.prompt,
            input.images,
        );
        try live.client.request("turn/start", params, live, onTurnStarted);
    }

    fn emit(p: *CodexProvider, live: *Live, event: types.HarnessEvent) void {
        _ = p;
        if (live.sink) |s| s(live.sink_ctx, event);
    }

    // --- app-server callbacks ---

    fn onInitialized(ctx: *anyopaque, _: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        const p = live.provider;
        if (err) |e| {
            live.failed = true;
            p.emit(live, .{ .session_error = e });
            return;
        }
        live.client.notify("initialized", .{}) catch {};
        p.openThread(live) catch |e| {
            live.failed = true;
            p.emit(live, .{ .session_error = @errorName(e) });
        };
    }

    /// Resumes this pane's thread when it had one, else starts a new one.
    fn openThread(p: *CodexProvider, live: *Live) !void {
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const params = try protocol.threadStartParams(arena, live.cwd, live.runtime_mode, live.planning, live.model);
        if (p.resume_map.get(live.key)) |parked| {
            var map = std.json.ObjectMap.empty;
            var it = params.object.iterator();
            while (it.next()) |e| try map.put(arena, e.key_ptr.*, e.value_ptr.*);
            try map.put(arena, "threadId", .{ .string = parked.thread_id });
            return live.client.request("thread/resume", std.json.Value{ .object = map }, live, onThread);
        }
        return live.client.request("thread/start", params, live, onThread);
    }

    fn onThread(ctx: *anyopaque, result: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        const p = live.provider;
        if (err) |e| {
            live.failed = true;
            p.emit(live, .{ .session_error = e });
            return;
        }
        const value = result orelse .null;
        const thread = protocolObj(value, "thread") orelse value;
        const id = protocolStr(thread, "id") orelse {
            live.failed = true;
            p.emit(live, .{ .session_error = "Codex did not return a thread id" });
            return;
        };
        if (live.thread_id.len > 0) p.gpa.free(live.thread_id);
        live.thread_id = p.gpa.dupe(u8, id) catch return;
        live.ready = true;
        p.emit(live, .{ .session_provider_bound = live.thread_id });
        p.emit(live, .{ .session_started = {} });
        if (p.resume_map.fetchRemove(live.key)) |old| {
            p.gpa.free(old.key);
            p.gpa.free(old.value.thread_id);
            p.gpa.free(old.value.cwd);
        }
        p.resume_map.put(p.gpa, p.gpa.dupe(u8, live.key) catch return, .{
            .thread_id = p.gpa.dupe(u8, live.thread_id) catch return,
            .cwd = p.gpa.dupe(u8, live.cwd) catch return,
        }) catch {};
        if (live.pending_text) |text| {
            live.pending_text = null;
            const images = live.pending_images;
            live.pending_images = &.{};
            defer p.gpa.free(text);
            const sink = live.sink orelse return;
            const input = types.SendTurnInput{ .session_id = live.key, .cwd = live.cwd, .prompt = text, .images = images, .on_event = sink };
            p.prompt(live, &input) catch |e| p.emit(live, .{ .session_error = @errorName(e) });
        }
    }

    fn onTurnStarted(ctx: *anyopaque, _: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        if (err) |e| {
            live.provider.emit(live, .{ .session_error = e });
            return;
        }
        live.provider.emit(live, .{ .turn_started = live.turn_id });
    }

    fn onNoReply(_: *anyopaque, _: ?std.json.Value, _: ?[]const u8, _: std.mem.Allocator) void {}

    fn onExited(ctx: *anyopaque, code: i32) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        const p = live.provider;
        if (live.failed) {
            p.stopSession(live.key);
            return;
        }
        p.emit(live, .{ .session_ended = code });
    }

    fn onNotification(ctx: *anyopaque, method: []const u8, params: std.json.Value, arena: std.mem.Allocator) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        const p = live.provider;
        if (std.mem.eql(u8, method, "turn/started")) {
            const turn = protocolObj(params, "turn") orelse return;
            const id = protocolStr(turn, "id") orelse return;
            if (live.turn_id.len > 0) p.gpa.free(live.turn_id);
            live.turn_id = p.gpa.dupe(u8, id) catch return;
            return;
        }
        for (protocol.mapNotification(arena, method, params)) |event| p.emit(live, event);
        if (std.mem.eql(u8, method, "turn/completed") or std.mem.eql(u8, method, "turn/aborted")) {
            if (live.turn_id.len > 0) {
                p.gpa.free(live.turn_id);
                live.turn_id = "";
            }
            p.emit(live, .{ .turn_ready = {} });
        }
    }

    fn onRequest(ctx: *anyopaque, id: []const u8, method: []const u8, params: std.json.Value, arena: std.mem.Allocator) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        const p = live.provider;
        // The clock can be asked before the thread exists.
        if (std.mem.eql(u8, method, "currentTime/read")) {
            const now: i64 = @intFromFloat(@import("../../../blocks.zig").now());
            live.client.respond(id, .{ .currentTimeAt = now });
            return;
        }
        if (std.mem.eql(u8, method, "item/commandExecution/requestApproval") or std.mem.eql(u8, method, "item/fileChange/requestApproval")) {
            return p.askApproval(live, id, method, params, arena);
        }
        if (std.mem.eql(u8, method, "item/permissions/requestApproval")) {
            return p.askApproval(live, id, method, params, arena);
        }
        if (std.mem.eql(u8, method, "item/tool/requestUserInput")) {
            return p.askQuestion(live, id, params, arena);
        }
        if (std.mem.eql(u8, method, "mcpServer/elicitation/request")) {
            p.emit(live, .{ .note = "An MCP server asked for a form nanoterm cannot show; it was cancelled" });
            live.client.respond(id, .{ .action = "cancel", .content = null, ._meta = null });
            return;
        }
        live.client.respondError(id, -32601, "nanoterm does not support this request");
    }

    /// A command, a file change, or a broader permission: a card the user
    /// answers, kept until `respond_approval` names it.
    fn askApproval(p: *CodexProvider, live: *Live, id: []const u8, method: []const u8, params: std.json.Value, arena: std.mem.Allocator) void {
        const rpc_id = std.fmt.parseInt(u32, id, 10) catch return;
        const kind = if (std.mem.eql(u8, method, "item/fileChange/requestApproval"))
            "fileChange"
        else if (std.mem.eql(u8, method, "item/permissions/requestApproval"))
            "permissions"
        else
            "command";
        const title = protocolStr(params, "reason") orelse protocolStr(params, "command") orelse protocolStr(params, "title") orelse switch (kind[0]) {
            'f' => "Change files",
            'p' => "Grant permissions",
            else => "Run a command",
        };
        const params_json = std.json.Stringify.valueAlloc(p.gpa, params, .{}) catch return;
        live.approvals.put(p.gpa, rpc_id, .{
            .kind = p.gpa.dupe(u8, kind) catch {
                p.gpa.free(params_json);
                return;
            },
            .params_json = params_json,
        }) catch {
            p.gpa.free(params_json);
            return;
        };
        _ = arena;
        p.emit(live, .{ .permission_request = .{
            .request_id = rpc_id,
            .title = title,
            .tool_name = kind,
            .input = params_json,
        } });
    }
};

fn protocolStr(v: std.json.Value, key: []const u8) ?[]const u8 {
    const f = protocolObj(v, key) orelse return null;
    return if (f == .string) f.string else null;
}

fn protocolObj(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

/// How many options a question offers, so one allocation holds them all.
fn countOptions(question: std.json.Value) usize {
    const opts = protocolObj(question, "options") orelse return 0;
    if (opts != .array) return 0;
    return opts.array.items.len;
}

/// The label of a question's option at `index`, which is what codex expects
/// back rather than the option's position.
fn questionLabel(arena: std.mem.Allocator, params_json: []const u8, index: u32) ?[]const u8 {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, params_json, .{}) catch return null;
    const questions = protocolObj(parsed, "questions") orelse return null;
    if (questions != .array or questions.array.items.len == 0) return null;
    const opts = protocolObj(questions.array.items[0], "options") orelse return null;
    if (opts != .array or index >= opts.array.items.len) return null;
    return protocolStr(opts.array.items[index], "label");
}

test "codex's question offers its labels as the answers" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The real shape, from `codex app-server generate-json-schema`.
    const params = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"isBlocking":true,"itemId":"i1","threadId":"t1","turnId":"u1","questions":[
        \\{"header":"Color","id":"q1","question":"Which color do you prefer?","isOther":false,"isSecret":false,
        \\ "options":[{"label":"Red","description":"Red"},{"label":"Blue","description":"Blue"}]}]}
    , .{});
    const questions = protocolObj(params, "questions").?;
    const first = questions.array.items[0];
    try std.testing.expectEqual(@as(usize, 2), countOptions(first));
    // The answer is filed under the question's id, and its value is the
    // option's label, not its position.
    try std.testing.expectEqualStrings("q1", protocolStr(first, "id").?);
    try std.testing.expectEqualStrings("Blue", questionLabel(arena, std.json.Stringify.valueAlloc(arena, params, .{}) catch unreachable, 1).?);
}
