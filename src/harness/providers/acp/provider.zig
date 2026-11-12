//! A harness provider backed by an ACP agent: it owns the child process, the
//! JSON-RPC session, and the mapping of the agent's updates onto harness
//! events. Every ACP agent (codex, opencode, grok, devin, hermes) is this
//! provider with its own `Options`: how to start it, which mode it takes, and
//! what its stderr means.
//!
//! The provider declares no filesystem or terminal capabilities, so the agent
//! never asks nanoterm to run anything; the only request it makes is a
//! permission prompt, which becomes a harness event and is answered by
//! `respond_approval`.
const std = @import("std");
const acp = @import("../../../acp.zig");
const proc = @import("../../../proc.zig");
const prompt_mod = @import("../../../agent_prompt.zig");
const types = @import("../../types.zig");
const events = @import("events.zig");

/// How one ACP agent is started and understood.
pub const Options = struct {
    /// The harness id it registers under.
    id: []const u8,
    /// Its name in errors.
    label: []const u8,
    /// The program and arguments to start it, built in the arena.
    argv: *const fn (arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, model: ?[]const u8) anyerror![]const []const u8,
    /// The ACP mode id this access level takes, or null to leave the mode be.
    mode_id: ?*const fn (runtime_mode: types.RuntimeMode, planning: bool) ?[]const u8 = null,
    /// A note for a stderr line that says something a turn should show
    /// (a sign-in failure), or null. The result is owned and freed by the
    /// provider once the event has been delivered.
    stderr_note: ?*const fn (gpa: std.mem.Allocator, line: []const u8) ?[]const u8 = null,
};

const Approval = struct {
    allow: ?[]const u8,
    deny: ?[]const u8,
};

const Live = struct {
    provider: *Provider,
    client: acp.Client,
    /// The session id this live is filed under (owned).
    key: []const u8 = "",
    session_id: []const u8 = "",
    cwd: []const u8 = "",
    model: ?[]const u8 = null,
    mode: ?[]const u8 = null,
    runtime_mode: types.RuntimeMode = .default,
    planning: bool = false,
    images_ok: bool = false,
    sink_ctx: *anyopaque = undefined,
    sink: ?*const fn (ctx: *anyopaque, event: types.HarnessEvent) void = null,
    approvals: std.AutoHashMapUnmanaged(u32, Approval) = .empty,
    /// Bytes of stderr already shown as notes.
    stderr_shown: usize = 0,
    /// The prompt waiting for the session to open.
    pending_text: ?[]const u8 = null,
    pending_images: []const types.Image = &.{},
    turn_open: bool = false,
    /// The agent refused or failed to open its session: the live is torn down
    /// when the process reports its end, never from inside a callback.
    failed: bool = false,
};

const Resume = struct {
    cwd: []const u8,
    model: ?[]const u8,
};

pub const Provider = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    opts: Options,
    live: std.StringHashMapUnmanaged(*Live) = .empty,
    resume_map: std.StringHashMapUnmanaged(Resume) = .empty,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, opts: Options) Provider {
        return .{ .gpa = gpa, .io = io, .env = env, .opts = opts };
    }

    pub fn deinit(p: *Provider) void {
        var keys: std.ArrayList([]const u8) = .empty;
        defer keys.deinit(p.gpa);
        var it = p.live.iterator();
        while (it.next()) |e| keys.append(p.gpa, e.key_ptr.*) catch {};
        for (keys.items) |k| p.stopSession(k);
        p.live.deinit(p.gpa);
        var rit = p.resume_map.iterator();
        while (rit.next()) |e| {
            p.gpa.free(e.key_ptr.*);
            p.freeResume(e.value_ptr.*);
        }
        p.resume_map.deinit(p.gpa);
    }

    fn freeResume(p: *Provider, r: Resume) void {
        p.gpa.free(r.cwd);
        if (r.model) |m| p.gpa.free(m);
    }

    /// Sends a turn, opening the agent first if it is not running. `sink_ctx`
    /// is the adapter's context; `input.on_event` is called with it.
    pub fn sendTurn(p: *Provider, input: *const types.SendTurnInput, sink_ctx: *anyopaque) !void {
        const live = try p.ensureLive(input, sink_ctx);
        live.sink_ctx = sink_ctx;
        live.sink = input.on_event;
        live.runtime_mode = input.runtime_mode;
        live.planning = input.intent == .plan;
        if (live.client.alive and live.session_id.len > 0) return p.prompt(live, input);
        // The session is opening; the prompt waits for it.
        if (live.pending_text) |t| p.gpa.free(t);
        live.pending_text = try p.gpa.dupe(u8, input.prompt);
        live.pending_images = input.images;
    }

    pub fn cancelTurn(p: *Provider, session_id: []const u8) !void {
        const live = p.live.get(session_id) orelse return error.SessionNotFound;
        if (!live.client.alive or live.session_id.len == 0) return;
        try live.client.notify("session/cancel", .{ .sessionId = live.session_id });
        p.emit(live, .turn_cancelled);
    }

    /// Kills the child but keeps the session's place, so the next turn starts
    /// a fresh ACP session in the same cwd.
    pub fn stopSession(p: *Provider, session_id: []const u8) void {
        const key = p.live.getKey(session_id) orelse return;
        const live = p.live.fetchRemove(key).?.value;
        p.destroyLive(live);
    }

    /// Kills the child and forgets where it was, so nothing resumes.
    pub fn forgetSession(p: *Provider, session_id: []const u8) void {
        p.stopSession(session_id);
        if (p.resume_map.fetchRemove(session_id)) |e| {
            p.gpa.free(e.key);
            p.freeResume(e.value);
        }
    }

    pub fn respondApproval(p: *Provider, session_id: []const u8, request_id: u32, decision: types.ApprovalDecision) void {
        const live = p.live.get(session_id) orelse return;
        const a = live.approvals.fetchRemove(request_id) orelse return;
        if (a.value.allow) |v| p.gpa.free(v);
        if (a.value.deny) |v| p.gpa.free(v);
        var buf: [32]u8 = undefined;
        const id_json = std.fmt.bufPrint(&buf, "{d}", .{request_id}) catch return;
        const chosen = switch (decision) {
            .allow => a.value.allow,
            .deny => a.value.deny,
        };
        if (chosen) |option| {
            live.client.respond(id_json, .{ .outcome = .{ .outcome = "selected", .optionId = option } });
        } else {
            live.client.respond(id_json, .{ .outcome = .{ .outcome = "cancelled" } });
        }
    }

    fn destroyLive(p: *Provider, live: *Live) void {
        live.client.deinit();
        var ait = live.approvals.iterator();
        while (ait.next()) |e| {
            if (e.value_ptr.allow) |v| p.gpa.free(v);
            if (e.value_ptr.deny) |v| p.gpa.free(v);
        }
        live.approvals.deinit(p.gpa);
        p.gpa.free(live.cwd);
        if (live.model) |m| p.gpa.free(m);
        if (live.mode) |m| p.gpa.free(m);
        if (live.session_id.len > 0) p.gpa.free(live.session_id);
        if (live.pending_text) |t| p.gpa.free(t);
        p.gpa.free(live.key);
        p.gpa.destroy(live);
    }

    fn ensureLive(p: *Provider, input: *const types.SendTurnInput, sink_ctx: *anyopaque) !*Live {
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
        try p.live.put(p.gpa, key, live);
        p.start(live) catch |err| {
            p.stopSession(input.session_id);
            return err;
        };
        return live;
    }

    fn start(p: *Provider, live: *Live) !void {
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const items = try p.opts.argv(arena, p.io, p.env, live.model);
        const argv = try proc.cStrings(arena, items);
        const env_strings = try p.envp(arena);
        const cwd_z = try arena.dupeSentinel(u8, live.cwd, 0);
        try live.client.start(argv, env_strings, cwd_z);
        try live.client.request("initialize", .{
            .protocolVersion = acp.protocol_version,
            .clientCapabilities = .{ .fs = .{ .readTextFile = false, .writeTextFile = false }, .terminal = false },
            .clientInfo = .{ .name = "nanoterm", .version = "0.1.0" },
        }, live, onInitialized);
    }

    /// The environment the child gets: the app's, with PATH extended by the
    /// folders installers put agents in.
    fn envp(p: *Provider, arena: std.mem.Allocator) ![*:null]const ?[*:0]const u8 {
        const agents = @import("../../../agents.zig");
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

    fn prompt(p: *Provider, live: *Live, input: *const types.SendTurnInput) !void {
        live.turn_open = true;
        p.emit(live, .{ .turn_started = live.session_id });
        var arena_state: std.heap.ArenaAllocator = .init(p.gpa);
        defer arena_state.deinit();
        const parts = try prompt_mod.partsOf(types.Image, arena_state.allocator(), input.prompt, input.images, live.images_ok);
        try live.client.request("session/prompt", .{ .sessionId = live.session_id, .prompt = parts }, live, onPromptDone);
    }

    fn emit(p: *Provider, live: *Live, event: types.HarnessEvent) void {
        _ = p;
        if (live.sink) |s| s(live.sink_ctx, event);
    }

    /// A note per new stderr line the agent wrote, so a sign-in failure shows
    /// in the turn instead of only in a log.
    fn drainStderr(p: *Provider, live: *Live) void {
        const note = p.opts.stderr_note orelse return;
        const text = live.client.stderr.bytes.items;
        while (std.mem.indexOfScalarPos(u8, text, live.stderr_shown, '\n')) |nl| {
            const line = text[live.stderr_shown..nl];
            live.stderr_shown = nl + 1;
            if (note(p.gpa, line)) |text_note| {
                defer p.gpa.free(text_note);
                p.emit(live, .{ .note = text_note });
            }
        }
    }

    // --- ACP callbacks ---

    fn onInitialized(ctx: *anyopaque, result: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        const p = live.provider;
        if (err) |e| {
            live.failed = true;
            p.emit(live, .{ .session_error = e });
            return;
        }
        const caps = acp.obj(acp.obj(result orelse .null, "agentCapabilities") orelse .null, "promptCapabilities") orelse .null;
        if (acp.obj(caps, "image")) |v| live.images_ok = v == .bool and v.bool;
        live.client.request("session/new", .{ .cwd = live.cwd, .mcpServers = @as([]const u8, &.{}) }, live, onSession) catch {};
    }

    fn onSession(ctx: *anyopaque, result: ?std.json.Value, err: ?[]const u8, arena: std.mem.Allocator) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        const p = live.provider;
        if (err) |e| {
            live.failed = true;
            p.emit(live, .{ .session_error = e });
            return;
        }
        const value = result orelse .null;
        const id = acp.str(value, "sessionId") orelse acp.str(value, "session_id") orelse acp.str(value, "id") orelse {
            live.failed = true;
            p.emit(live, .{ .session_error = "the agent opened no session" });
            return;
        };
        live.session_id = p.gpa.dupe(u8, id) catch return;
        p.emit(live, .{ .session_provider_bound = live.session_id });
        p.emit(live, .{ .session_started = {} });
        // Remember where this session lives, so a later turn restarts here.
        if (p.resume_map.fetchRemove(live.key)) |old| {
            p.gpa.free(old.key);
            p.freeResume(old.value);
        }
        p.resume_map.put(p.gpa, p.gpa.dupe(u8, live.key) catch return, .{
            .cwd = p.gpa.dupe(u8, live.cwd) catch return,
            .model = if (live.model) |m| p.gpa.dupe(u8, m) catch null else null,
        }) catch {};
        // The access level picks a mode, when the agent has one.
        if (p.opts.mode_id) |mode_id| if (mode_id(live.runtime_mode, live.planning)) |wanted| {
            // Only a mode the agent advertised is set; an unknown id is left
            // alone rather than refused by the agent.
            if (advertisesMode(value, wanted)) {
                live.client.request("session/set_mode", .{ .sessionId = live.session_id, .modeId = wanted }, live, onNoReply) catch {};
            }
        };
        if (live.pending_text) |text| {
            live.pending_text = null;
            const images = live.pending_images;
            live.pending_images = &.{};
            defer p.gpa.free(text);
            const sink = live.sink orelse return;
            const input = types.SendTurnInput{
                .session_id = live.key,
                .cwd = live.cwd,
                .prompt = text,
                .images = images,
                .on_event = sink,
            };
            _ = arena;
            p.prompt(live, &input) catch |e| p.emit(live, .{ .session_error = @errorName(e) });
        }
    }

    fn onPromptDone(ctx: *anyopaque, _: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        live.turn_open = false;
        live.provider.drainStderr(live);
        if (err) |e| live.provider.emit(live, .{ .session_error = e });
        live.provider.emit(live, .{ .turn_ready = {} });
        live.provider.emit(live, .{ .turn_ended = live.session_id });
    }

    fn onNoReply(_: *anyopaque, _: ?std.json.Value, _: ?[]const u8, _: std.mem.Allocator) void {}

    /// Whether `session/new`'s result listed `wanted` among its modes.
    fn advertisesMode(result: std.json.Value, wanted: []const u8) bool {
        const state = acp.obj(result, "modes") orelse return false;
        const list = acp.obj(state, "availableModes") orelse acp.obj(state, "available_modes") orelse return false;
        if (list != .array) return false;
        for (list.array.items) |m| {
            const id = acp.str(m, "id") orelse acp.str(m, "modeId") orelse continue;
            if (std.mem.eql(u8, id, wanted)) return true;
        }
        return false;
    }

    fn onExited(ctx: *anyopaque, code: i32) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        const p = live.provider;
        if (live.failed) {
            // The session never opened; nothing waits on it. The client's own
            // callback is done with its state, so the live can go now.
            p.stopSession(live.key);
            return;
        }
        p.emit(live, .{ .session_ended = code });
    }

    fn onNotification(ctx: *anyopaque, method: []const u8, params: std.json.Value, arena: std.mem.Allocator) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, method, "session/update")) return;
        const update = acp.obj(params, "update") orelse return;
        for (events.map(arena, update)) |event| live.provider.emit(live, event);
    }

    fn onRequest(ctx: *anyopaque, id: []const u8, method: []const u8, params: std.json.Value, arena: std.mem.Allocator) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, method, "session/request_permission")) {
            return onPermission(live, id, params, arena);
        }
        // Nothing else was advertised: answer with a refusal, so the agent
        // does not wait on a request that will never be handled.
        live.client.respondError(id, -32601, "nanoterm does not support this request");
    }

    fn onPermission(live: *Live, id: []const u8, params: std.json.Value, _: std.mem.Allocator) void {
        const p = live.provider;
        const rpc_id = std.fmt.parseInt(u32, id, 10) catch return;
        const options = acp.obj(params, "options") orelse std.json.Value{ .null = {} };
        var allow: ?[]const u8 = null;
        var deny: ?[]const u8 = null;
        var title: []const u8 = "";
        if (options == .array) for (options.array.items) |o| {
            const option_id = acp.str(o, "optionId") orelse acp.str(o, "option_id") orelse continue;
            const kind = acp.str(o, "kind") orelse "";
            if (std.mem.startsWith(u8, kind, "allow")) {
                if (allow == null) allow = p.gpa.dupe(u8, option_id) catch null;
            } else if (deny == null) deny = p.gpa.dupe(u8, option_id) catch null;
            if (title.len == 0) title = acp.str(o, "name") orelse "";
        };
        const tool = acp.obj(params, "toolCall") orelse .null;
        const tool_name = acp.str(tool, "title") orelse acp.str(tool, "toolCallId") orelse "";
        if (title.len == 0) title = tool_name;
        live.approvals.put(p.gpa, rpc_id, .{ .allow = allow, .deny = deny }) catch {};
        p.emit(live, .{ .permission_request = .{
            .request_id = rpc_id,
            .title = title,
            .tool_name = tool_name,
        } });
    }

};
