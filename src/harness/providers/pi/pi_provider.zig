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
        for (protocol.mapEvent(arena, record)) |event| live.provider.emit(live, event);
        if (std.mem.eql(u8, kind, "agent_settled")) live.provider.emit(live, .{ .turn_ready = {} });
    }

    fn onExited(ctx: *anyopaque, code: i32) void {
        const live: *Live = @ptrCast(@alignCast(ctx));
        live.provider.emit(live, .{ .session_ended = code });
    }
};
