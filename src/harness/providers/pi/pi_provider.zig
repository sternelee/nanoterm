//! Pi's harness provider. It owns the `pi --mode rpc` child and turns its
//! events into harness events; `--no-session` means each start is a fresh
//! conversation, so stopping and forgetting are the same.
const std = @import("std");
const proc = @import("../../../proc.zig");
const agents = @import("../../../agents.zig");
const pi_rpc = @import("../../../pi.zig");
const types = @import("../../types.zig");
const protocol = @import("pi.zig");

const Live = struct {
    provider: *PiProvider,
    client: pi_rpc.Client,
    key: []const u8 = "",
    cwd: []const u8 = "",
    model: ?[]const u8 = null,
    sink_ctx: *anyopaque = undefined,
    sink: ?*const fn (ctx: *anyopaque, event: types.HarnessEvent) void = null,
    pending_text: ?[]const u8 = null,
    pending_images: []const types.Image = &.{},
    /// Pi names an extension's UI request with a string; the harness names a
    /// question with a number, so each open question keeps its own id here
    /// along with the options it offered.
    questions: std.AutoHashMapUnmanaged(u32, OpenQuestion) = .empty,
    next_question_id: u32 = 1,
};

/// A `select` waiting on a person: pi's own request id, and the choices it
/// offered, which is what an answer has to name.
const OpenQuestion = struct {
    raw_id: []const u8,
    options: [][]const u8,
};

/// The `prompt` command's fields, as `pi.zig` encodes them.
const PromptFields = struct {
    message: []const u8,
    images: ?[]pi_rpc.Image = null,
    streamingBehavior: ?[]const u8 = null,
};

pub const PiProvider = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    live: std.StringHashMapUnmanaged(*Live) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) PiProvider {
        return .{ .gpa = gpa, .io = io, .env = env };
    }

    pub fn deinit(p: *PiProvider) void {
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(p.gpa);
        var it = p.live.iterator();
        while (it.next()) |e| keys.append(p.gpa, e.key_ptr.*) catch {};
        for (keys.items) |k| p.stopSession(k);
        p.live.deinit(p.gpa);
    }

    pub fn sendTurn(p: *PiProvider, input: *const types.SendTurnInput, sink_ctx: *anyopaque) !void {
        const live = try p.ensureLive(input, sink_ctx);
        live.sink_ctx = sink_ctx;
        live.sink = input.on_event;
        try p.prompt(live, input);
    }

    pub fn cancelTurn(p: *PiProvider, session_id: []const u8) !void {
        const live = p.live.get(session_id) orelse return error.SessionNotFound;
        if (!live.client.alive) return;
        live.client.commandNoReply("abort", .{});
        p.emit(live, .{ .turn_cancelled = {} });
    }

    pub fn stopSession(p: *PiProvider, session_id: []const u8) void {
        const key = p.live.getKey(session_id) orelse return;
        const live = p.live.fetchRemove(key).?.value;
        p.destroyLive(live);
    }

    pub fn forgetSession(p: *PiProvider, session_id: []const u8) void {
        p.stopSession(session_id);
    }

    fn destroyLive(p: *PiProvider, live: *Live) void {
        live.client.deinit();
        var qit = live.questions.iterator();
        while (qit.next()) |e| {
            for (e.value_ptr.options) |t| p.gpa.free(t);
            p.gpa.free(e.value_ptr.options);
            p.gpa.free(e.value_ptr.raw_id);
        }
        live.questions.deinit(p.gpa);
        p.gpa.free(live.cwd);
        if (live.model) |m| p.gpa.free(m);
        if (live.pending_text) |t| p.gpa.free(t);
        p.gpa.free(live.key);
        p.gpa.destroy(live);
    }

    fn ensureLive(p: *PiProvider, input: *const types.SendTurnInput, sink_ctx: *anyopaque) !*Live {
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
        live.client = pi_rpc.Client.init(p.gpa, .{ .ctx = live, .event = onEvent, .exited = onExited });
        try p.live.put(p.gpa, key, live);
        p.start(live) catch |err| {
            p.stopSession(input.session_id);
            return err;
        };
        return live;
    }

    fn start(p: *PiProvider, live: *Live) !void {
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const items = try protocol.argv(arena, p.io, p.env, live.model);
        const argv = try proc.cStrings(arena, items);
        const env_strings = try p.envp(arena);
        const cwd_z = try arena.dupeSentinel(u8, live.cwd, 0);
        try live.client.start(argv, env_strings, cwd_z);
    }

    fn envp(p: *PiProvider, arena: std.mem.Allocator) ![*:null]const ?[*:0]const u8 {
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

    fn prompt(p: *PiProvider, live: *Live, input: *const types.SendTurnInput) !void {
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var pics: std.ArrayList(pi_rpc.Image) = .empty;
        for (input.images) |im| {
            if (im.data.len == 0) continue;
            try pics.append(arena, .{ .data = im.data, .mime = im.mime });
        }
        p.emit(live, .{ .turn_started = "" });
        _ = try live.client.command("prompt", PromptFields{
            .message = input.prompt,
            .images = if (pics.items.len > 0) pics.items else null,
        }, live, onPromptReply);
    }

    fn emit(p: *PiProvider, live: *Live, event: types.HarnessEvent) void {
        _ = p;
        if (live.sink) |s| s(live.sink_ctx, event);
    }

    fn onPromptReply(_: *anyopaque, _: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator, _: i64) void {
        _ = err;
    }

    fn onEvent(ctx: *anyopaque, record: std.json.Value, arena: std.mem.Allocator) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        const kind = pi_rpc.str(record, "type") orelse return;
        // An extension's dialog needs a person, so it becomes a card rather
        // than being dropped: a dropped request leaves the extension waiting
        // for an answer that never comes.
        if (std.mem.eql(u8, kind, "extension_ui_request")) {
            live.provider.extensionUi(live, record, arena);
            return;
        }
        for (protocol.mapEvent(arena, record)) |event| live.provider.emit(live, event);
        if (std.mem.eql(u8, kind, "agent_settled")) live.provider.emit(live, .{ .turn_ready = {} });
    }

    /// An extension asking the client for something. `select` offers a list,
    /// which is a question; the rest have no card, so they are declined the
    /// way the direct path declines them, and a notice is shown.
    fn extensionUi(p: *PiProvider, live: *Live, record: std.json.Value, arena: std.mem.Allocator) void {
        const method = pi_rpc.str(record, "method") orelse return;
        const raw_id = pi_rpc.str(record, "id") orelse return;
        if (std.mem.eql(u8, method, "select")) {
            const options = pi_rpc.obj(record, "options") orelse return;
            if (options != .array or options.array.items.len == 0) return;
            const title = pi_rpc.str(record, "title") orelse "Choose";
            const id = live.next_question_id;
            live.next_question_id += 1;
            const owned = p.gpa.dupe(u8, raw_id) catch return;
            const texts = p.gpa.alloc([]const u8, options.array.items.len) catch {
                p.gpa.free(owned);
                return;
            };
            var filled: usize = 0;
            for (options.array.items) |o| {
                if (o != .string) continue;
                texts[filled] = p.gpa.dupe(u8, o.string) catch break;
                filled += 1;
            }
            if (filled == 0) {
                p.gpa.free(texts);
                p.gpa.free(owned);
                return;
            }
            live.questions.put(p.gpa, id, .{ .raw_id = owned, .options = texts[0..filled] }) catch {
                for (texts[0..filled]) |t| p.gpa.free(t);
                p.gpa.free(texts);
                p.gpa.free(owned);
                return;
            };
            const list = p.gpa.alloc(types.QuestionOption, filled) catch {
                _ = live.questions.remove(id);
                for (texts[0..filled]) |t| p.gpa.free(t);
                p.gpa.free(texts);
                p.gpa.free(owned);
                return;
            };
            for (texts[0..filled], 0..) |t, i| {
                list[i] = .{ .id = t, .name = t };
            }
            _ = arena;
            p.emit(live, .{ .question_asked = .{
                .request_id = id,
                .title = title,
                .options = list,
            } });
            return;
        }
        if (std.mem.eql(u8, method, "confirm")) {
            live.client.extensionResponse(raw_id, .{ .confirmed = false });
            p.emit(live, .{ .note = "an extension asked for confirmation; nanoterm has no dialog for it, so it was declined" });
            return;
        }
        if (std.mem.eql(u8, method, "input") or std.mem.eql(u8, method, "editor")) {
            live.client.extensionResponse(raw_id, .{ .cancelled = true });
            p.emit(live, .{ .note = "an extension asked for input; nanoterm has no dialog for it, so it was cancelled" });
            return;
        }
        if (std.mem.eql(u8, method, "notify")) {
            if (pi_rpc.str(record, "message")) |m| p.emit(live, .{ .note = m });
        }
    }

    /// Answers a `select` with the pick at `reply`, as the option's own text.
    pub fn respondQuestion(p: *PiProvider, session_id: []const u8, request_id: u32, reply: types.UserQuestionReply) void {
        const live = p.live.get(session_id) orelse return;
        const open = live.questions.fetchRemove(request_id) orelse return;
        defer {
            for (open.value.options) |t| p.gpa.free(t);
            p.gpa.free(open.value.options);
            p.gpa.free(open.value.raw_id);
        }
        const value = switch (reply) {
            .text => |t| t,
            .choice => |i| if (i < open.value.options.len) open.value.options[i] else "",
        };
        live.client.extensionResponse(open.value.raw_id, .{ .value = value });
    }

    fn onExited(ctx: *anyopaque, code: i32) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        live.provider.emit(live, .{ .session_ended = code });
    }
};
