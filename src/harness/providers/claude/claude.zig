//! Claude Code harness provider implementation.
const std = @import("std");
const harness_types = @import("../../types.zig");
const claude_protocol = @import("claude_protocol.zig");
const proc = @import("../../../proc.zig");

const ClaudeContext = struct {
    gpa: std.mem.Allocator,
    cwd: []const u8,
    claude_session_id: ?[]const u8 = null,
    provider_account_id: ?[]const u8 = null,
    runtime_mode: harness_types.RuntimeMode = .default,
    planning: bool = false,
    settings_key: []const u8 = "",
    on_event: ?*const fn (ctx: *anyopaque, event: harness_types.HarnessEvent) void = null,
    process: proc.Process = undefined,
    alive: bool = false,
    next_control_id: u32 = 0,
    initialized: bool = false,
    output_buffer: std.ArrayList(u8),
};

const ClaudeResume = struct {
    cwd: []const u8,
    provider_account_id: ?[]const u8 = null,
    session_id: []const u8,
};

pub const ClaudeProvider = struct {
    gpa: std.mem.Allocator,
    live_by_thread: std.StringHashMap(*ClaudeContext),
    resume_by_thread: std.StringHashMap(ClaudeResume),
    binary_path: []const u8,

    pub fn init(gpa: std.mem.Allocator, binary_path: []const u8) ClaudeProvider {
        return .{
            .gpa = gpa,
            .live_by_thread = std.StringHashMap(*ClaudeContext).init(gpa),
            .resume_by_thread = std.StringHashMap(ClaudeResume).init(gpa),
            .binary_path = binary_path,
        };
    }

    pub fn deinit(p: *ClaudeProvider) void {
        var iter = p.live_by_thread.iterator();
        while (iter.next()) |entry| {
            const ctx = entry.value_ptr.*;
            ctx.output_buffer.deinit(p.gpa);
            p.gpa.free(ctx.cwd);
            if (ctx.claude_session_id) |sid| p.gpa.free(sid);
            if (ctx.provider_account_id) |aid| p.gpa.free(aid);
            p.gpa.free(ctx.settings_key);
            p.gpa.destroy(ctx);
        }
        p.live_by_thread.deinit();
        var iter2 = p.resume_by_thread.iterator();
        while (iter2.next()) |entry| {
            const r = entry.value_ptr.*;
            p.gpa.free(r.cwd);
            if (r.provider_account_id) |aid| p.gpa.free(aid);
            p.gpa.free(r.session_id);
        }
        p.resume_by_thread.deinit();
    }

    fn settingsKeyFor(provider: *const ClaudeProvider, model: ?[]const u8, effort: ?[]const u8, runtime_mode: harness_types.RuntimeMode, intent: ?harness_types.TurnIntent) ![]const u8 {
        var buf = std.ArrayList(u8).init(provider.gpa);
        defer buf.deinit();
        if (model) |m| try buf.appendSlice(m);
        try buf.appendSlice("|");
        if (effort) |e| try buf.appendSlice(e);
        try buf.appendSlice("|");
        try buf.appendSlice(@tagName(runtime_mode));
        if (intent) |i| {
            try buf.appendSlice("|");
            try buf.appendSlice(@tagName(i));
        }
        return buf.toOwnedSlice();
    }

    fn sameProviderAccountId(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return std.mem.eql(u8, a.?, b.?);
    }

    fn providerAccountIdFor(input: claude_protocol.ClaudeSpawnInput) []const u8 {
        _ = input;
        // TODO: implement provider account ID logic
        return "";
    }

    fn ensureLive(provider: *ClaudeProvider, thread_id: []const u8, input: claude_protocol.ClaudeSpawnInput, cwd: []const u8, runtime_mode: harness_types.RuntimeMode, planning: bool, on_event: ?*const fn (ctx: *anyopaque, event: harness_types.HarnessEvent) void) !*ClaudeContext {
        const settings_key = try provider.settingsKeyFor(input.model, input.effort, runtime_mode, null);
        defer provider.gpa.free(settings_key);

        // Check for existing live context with matching settings
        if (provider.live_by_thread.get(thread_id)) |ctx| {
            if (std.mem.eql(u8, ctx.cwd, cwd) and
                std.mem.eql(u8, ctx.settings_key, settings_key) and
                ctx.planning == planning)
            {
                return ctx;
            }
            // Settings changed: stop existing session
            provider.stopSession(thread_id);
        }

        // Check resume state if session_id provided
        if (input.resume_session) |resume_session_id| {
            if (provider.resume_by_thread.get(thread_id)) |r| {
                const provider_account_id = if (input.isolated) null else providerAccountIdFor(input);
                if (std.mem.eql(u8, r.session_id, resume_session_id) and
                    std.mem.eql(u8, r.cwd, cwd) and
                    sameProviderAccountId(r.provider_account_id, provider_account_id))
                {
                    // Resume existing session
                    input.resume_session = resume_session_id;
                } else {
                    // Different session: stop and forget
                    provider.forgetSession(thread_id);
                }
            }
        }

        // Spawn new Claude process
        const ctx = try provider.gpa.create(ClaudeContext);
        ctx.* = .{
            .gpa = provider.gpa,
            .cwd = try provider.gpa.dupe(u8, cwd),
            .claude_session_id = if (input.session_id) |sid| try provider.gpa.dupe(u8, sid) else null,
            .provider_account_id = if (!input.isolated) try provider.gpa.dupe(u8, providerAccountIdFor(input)) else null,
            .runtime_mode = runtime_mode,
            .planning = planning,
            .settings_key = try provider.gpa.dupe(u8, settings_key),
            .on_event = on_event,
            .output_buffer = std.ArrayList(u8).init(provider.gpa),
        };
        errdefer {
            ctx.output_buffer.deinit(provider.gpa);
            provider.gpa.free(ctx.cwd);
            if (ctx.claude_session_id) |sid| provider.gpa.free(sid);
            if (ctx.provider_account_id) |aid| provider.gpa.free(aid);
            provider.gpa.free(ctx.settings_key);
            provider.gpa.destroy(ctx);
        }

        try provider.spawnClaude(ctx, input);
        try provider.live_by_thread.put(provider.gpa, thread_id, ctx);

        // Store resume state if session_id provided
        if (input.session_id) |sid| {
            const r = ClaudeResume{
                .cwd = try provider.gpa.dupe(u8, cwd),
                .provider_account_id = if (!input.isolated) try provider.gpa.dupe(u8, ctx.provider_account_id.?) else null,
                .session_id = try provider.gpa.dupe(u8, sid),
            };
            try provider.resume_by_thread.put(provider.gpa, thread_id, r);
        }

        return ctx;
    }

    fn spawnClaude(provider: *ClaudeProvider, ctx: *ClaudeContext, input: claude_protocol.ClaudeSpawnInput) !void {
        const args = try claude_protocol.buildClaudeSpawnArgs(provider.gpa, input);
        defer {
            for (args) |arg| provider.gpa.free(arg);
            provider.gpa.free(args);
        }

        // Build argv for proc.spawnPipesErr
        var argv_list = try std.ArrayList([]const u8).initCapacity(provider.gpa, args.len + 1);
        defer {
            for (argv_list.items) |arg| provider.gpa.free(arg);
            argv_list.deinit(provider.gpa);
        }
        try argv_list.append(try provider.gpa.dupe(u8, provider.binary_path));
        for (args) |arg| {
            try argv_list.append(try provider.gpa.dupe(u8, arg));
        }

        // Convert to C-style argv
        const argv = try proc.cStrings(provider.gpa, argv_list.items);
        defer provider.gpa.free(argv);

        // Null-terminated cwd for spawnPipesErr
        const cwd_z = try provider.gpa.dupeZ(u8, ctx.cwd);
        defer provider.gpa.free(cwd_z);

        // Create sink for process output
        const sink = proc.Sink{
            .ctx = ctx,
            .output = onOutput,
            .exited = onExited,
        };

        // Spawn the process with pipes (merge stderr into stdout)
        try proc.spawnPipesErr(&ctx.process, argv, null, cwd_z, true, null, sink);
        ctx.alive = true;
    }

    pub fn stopSession(provider: *ClaudeProvider, thread_id: []const u8) void {
        if (provider.live_by_thread.fetchRemove(thread_id)) |entry| {
            const ctx = entry.value;
            if (ctx.alive) {
                ctx.process.close();
                ctx.alive = false;
            }
            ctx.output_buffer.deinit(provider.gpa);
            provider.gpa.free(ctx.cwd);
            if (ctx.claude_session_id) |sid| provider.gpa.free(sid);
            if (ctx.provider_account_id) |aid| provider.gpa.free(aid);
            provider.gpa.free(ctx.settings_key);
            provider.gpa.destroy(ctx);
        }
    }

    pub fn forgetSession(provider: *ClaudeProvider, thread_id: []const u8) void {
        provider.stopSession(thread_id);
        if (provider.resume_by_thread.fetchRemove(thread_id)) |entry| {
            const r = entry.value;
            provider.gpa.free(r.cwd);
            if (r.provider_account_id) |aid| provider.gpa.free(aid);
            provider.gpa.free(r.session_id);
        }
    }

    pub fn sendTurn(provider: *ClaudeProvider, thread_id: []const u8, input: harness_types.SendTurnInput) !void {
        const ctx = provider.live_by_thread.get(thread_id) orelse return error.SessionNotFound;
        if (!ctx.alive) return error.SessionNotAlive;

        // Emit turn_started event
        if (ctx.on_event) |cb| {
            const event = harness_types.HarnessEvent{ .turn_started = input.session_id };
            cb(ctx, event);
        }

        // Send prompt to Claude process via harness protocol JSON
        var json_buf = std.ArrayList(u8).init(provider.gpa);
        defer json_buf.deinit();

        try json_buf.appendSlice("{\"event\":\"turn_input\",\"data\":{\"session_id\":\"");
        try std.json.Stringify.encodeJsonString(input.session_id, .{}, json_buf.writer());
        try json_buf.appendSlice("\",\"prompt\":");
        try std.json.Stringify.encodeJsonString(input.prompt, .{}, json_buf.writer());
        
        // Add images if present
        if (input.images.len > 0) {
            try json_buf.appendSlice(",\"images\":[");
            for (input.images, 0..) |img, i| {
                if (i > 0) try json_buf.appendSlice(",");
                try json_buf.appendSlice("{\"name\":");
                try std.json.Stringify.encodeJsonString(img.name, .{}, json_buf.writer());
                try json_buf.appendSlice(",\"mime\":");
                try std.json.Stringify.encodeJsonString(img.mime, .{}, json_buf.writer());
                try json_buf.appendSlice(",\"data\":");
                try std.json.Stringify.encodeJsonString(img.data, .{}, json_buf.writer());
                try json_buf.appendSlice("}");
            }
            try json_buf.appendSlice("]");
        }
        
        try json_buf.appendSlice("}}\n");

        // Send to Claude process stdin
        ctx.process.send(json_buf.items);

        // Emit turn_ready event
        if (ctx.on_event) |cb| {
            const event = harness_types.HarnessEvent{ .turn_ready = {} };
            cb(ctx, event);
        }
    }

    pub fn cancelTurn(provider: *ClaudeProvider, thread_id: []const u8) !void {
        const ctx = provider.live_by_thread.get(thread_id) orelse return error.SessionNotFound;
        if (!ctx.alive) return error.SessionNotAlive;

        // Send interrupt signal (SIGINT)
        ctx.process.signal(proc.SIGINT);

        // Emit turn_cancelled event
        if (ctx.on_event) |cb| {
            const event = harness_types.HarnessEvent{ .turn_cancelled = {} };
            cb(ctx, event);
        }
    }

    pub fn bindSession(provider: *ClaudeProvider, thread_id: []const u8, session_id: []const u8) !void {
        _ = provider;
        _ = thread_id;
        _ = session_id;
        return error.NotImplemented;
    }

    pub fn respondApproval(provider: *ClaudeProvider, thread_id: []const u8, input: harness_types.ApprovalDecision) !void {
        const ctx = provider.live_by_thread.get(thread_id) orelse return error.SessionNotFound;
        if (!ctx.alive) return error.SessionNotAlive;

        // Build JSON response
        var json_buf = std.ArrayList(u8).init(provider.gpa);
        defer json_buf.deinit();

        try json_buf.appendSlice("{\"event\":\"approval\",\"data\":{\"request_id\":");
        try std.json.writeUint(@intFromEnum(input.request_id), json_buf.writer());
        try json_buf.appendSlice(",\"decision\":\"");
        try json_buf.appendSlice(@tagName(input.decision));
        try json_buf.appendSlice("\"}}\n");

        // Send to Claude process stdin
        ctx.process.send(json_buf.items);
    }

    pub fn respondQuestion(provider: *ClaudeProvider, thread_id: []const u8, input: harness_types.UserQuestionReply) !void {
        const ctx = provider.live_by_thread.get(thread_id) orelse return error.SessionNotFound;
        if (!ctx.alive) return error.SessionNotAlive;

        // Build JSON response
        var json_buf = std.ArrayList(u8).init(provider.gpa);
        defer json_buf.deinit();

        try json_buf.appendSlice("{\"event\":\"question_reply\",\"data\":{\"request_id\":");
        try std.json.writeUint(@intFromEnum(input.request_id), json_buf.writer());
        try json_buf.appendSlice(",\"option_id\":\"");
        try json_buf.appendSlice(input.option_id);
        try json_buf.appendSlice("\"}}\n");

        // Send to Claude process stdin
        ctx.process.send(json_buf.items);
    }

    pub fn refreshCatalog(provider: *ClaudeProvider) !void {
        _ = provider;
        // TODO: implement catalog refresh
        return error.NotImplemented;
    }

    fn onOutput(ctx: *anyopaque, bytes: []const u8) void {
        const c: *ClaudeContext = @ptrCast(@alignCast(ctx));
        // Append bytes to buffer and parse complete JSON lines
        c.output_buffer.appendSlice(c.gpa, bytes) catch return;
        parseHarnessProtocol(c);
    }

    fn onExited(ctx: *anyopaque, code: i32) void {
        const c: *ClaudeContext = @ptrCast(@alignCast(ctx));
        c.alive = false;
        if (c.on_event) |cb| {
            const event = harness_types.HarnessEvent{ .session_ended = code };
            cb(c, event);
        }
    }

    fn parseHarnessProtocol(ctx: *ClaudeContext) void {
        // Parse JSON lines from buffer
        while (true) {
            const newline_idx = std.mem.indexOfScalar(u8, ctx.output_buffer.items, '\n') orelse break;
            const line = ctx.output_buffer.items[0..newline_idx];
            
            // Skip empty lines
            if (line.len == 0) {
                ctx.output_buffer.items = ctx.output_buffer.items[newline_idx + 1 ..];
                continue;
            }

            // Try to parse JSON line
            if (parseJsonLine(ctx, line)) {
                // Successfully parsed, remove line from buffer
                ctx.output_buffer.items = ctx.output_buffer.items[newline_idx + 1 ..];
            } else {
                // Parse failed, might be incomplete, wait for more data
                break;
            }
        }
    }

    fn parseJsonLine(ctx: *ClaudeContext, line: []const u8) bool {
        const parsed = std.json.parseFromSlice(struct {
            event: []const u8,
            data: ?std.json.Value = null,
        }, ctx.gpa, line, .{}) catch |err| {
            // Not valid JSON or incomplete line
            if (err == error.UnexpectedEnd) return false;
            // Not JSON - skip
            return true;
        };
        defer parsed.deinit();

        // Emit event based on parsed JSON
        if (ctx.on_event) |cb| {
            const event = jsonToHarnessEvent(ctx, parsed.value.event, parsed.value.data) catch {
                // Invalid event format - skip
                return true;
            };
            cb(ctx, event);
        }

        return true;
    }

    fn jsonToHarnessEvent(ctx: *ClaudeContext, event_name: []const u8, data: ?std.json.Value) !harness_types.HarnessEvent {
        _ = ctx;
        // Map event names to HarnessEvent variants
        if (std.mem.eql(u8, event_name, "session_started")) {
            return .{ .session_started = {} };
        } else if (std.mem.eql(u8, event_name, "session_ended")) {
            const code = if (data) |d| blk: {
                if (d != .object) break :blk null;
                const obj = d.object;
                if (obj.get("code")) |c| {
                    if (c == .integer) break :blk @as(i32, @intFromFloat(c.integer));
                }
                break :blk null;
            } else null;
            return .{ .session_ended = code };
        } else if (std.mem.eql(u8, event_name, "session_error")) {
            const msg = if (data) |d| blk: {
                if (d != .object) break :blk "";
                const obj = d.object;
                if (obj.get("message")) |m| {
                    if (m == .string) break :blk m.string;
                }
                break :blk "";
            } else "";
            return .{ .session_error = msg };
        } else if (std.mem.eql(u8, event_name, "turn_started")) {
            const session_id = if (data) |d| blk: {
                if (d != .object) break :blk "";
                const obj = d.object;
                if (obj.get("session_id")) |s| {
                    if (s == .string) break :blk s.string;
                }
                break :blk "";
            } else "";
            return .{ .turn_started = session_id };
        } else if (std.mem.eql(u8, event_name, "turn_ready")) {
            return .{ .turn_ready = {} };
        } else if (std.mem.eql(u8, event_name, "turn_ended")) {
            return .{ .turn_ended = {} };
        } else if (std.mem.eql(u8, event_name, "turn_cancelled")) {
            return .{ .turn_cancelled = {} };
        } else if (std.mem.eql(u8, event_name, "message_delta")) {
            const text = if (data) |d| blk: {
                if (d != .object) break :blk "";
                const obj = d.object;
                if (obj.get("text")) |t| {
                    if (t == .string) break :blk t.string;
                }
                break :blk "";
            } else "";
            return .{ .message_delta = text };
        } else if (std.mem.eql(u8, event_name, "message_completed")) {
            return .{ .message_completed = {} };
        } else if (std.mem.eql(u8, event_name, "tool_start")) {
            const id = if (data) |d| blk: {
                if (d != .object) break :blk "";
                const obj = d.object;
                if (obj.get("id")) |i| {
                    if (i == .string) break :blk i.string;
                }
                break :blk "";
            } else "";
            const name = if (data) |d| blk: {
                if (d != .object) break :blk "";
                const obj = d.object;
                if (obj.get("name")) |n| {
                    if (n == .string) break :blk n.string;
                }
                break :blk "";
            } else "";
            const kind = if (data) |d| blk: {
                if (d != .object) break :blk "";
                const obj = d.object;
                if (obj.get("kind")) |k| {
                    if (k == .string) break :blk k.string;
                }
                break :blk "";
            } else "";
            return .{ .tool_start = .{ .id = id, .name = name, .kind = kind } };
        } else if (std.mem.eql(u8, event_name, "tool_delta")) {
            const id = if (data) |d| blk: {
                if (d != .object) break :blk "";
                const obj = d.object;
                if (obj.get("id")) |i| {
                    if (i == .string) break :blk i.string;
                }
                break :blk "";
            } else "";
            const delta = if (data) |d| blk: {
                if (d != .object) break :blk "";
                const obj = d.object;
                if (obj.get("delta")) |d_| {
                    if (d_ == .string) break :blk d_.string;
                }
                break :blk "";
            } else "";
            return .{ .tool_delta = .{ .id = id, .delta = delta } };
        } else if (std.mem.eql(u8, event_name, "tool_result")) {
            const id = if (data) |d| blk: {
                if (d != .object) break :blk "";
                const obj = d.object;
                if (obj.get("id")) |i| {
                    if (i == .string) break :blk i.string;
                }
                break :blk "";
            } else "";
            const status = if (data) |d| blk: {
                if (d != .object) break :blk .completed;
                const obj = d.object;
                if (obj.get("status")) |s| {
                    if (s == .string) {
                        if (std.mem.eql(u8, s.string, "pending")) break :blk .pending;
                        if (std.mem.eql(u8, s.string, "in_progress")) break :blk .in_progress;
                        if (std.mem.eql(u8, s.string, "completed")) break :blk .completed;
                        if (std.mem.eql(u8, s.string, "failed")) break :blk .failed;
                    }
                }
                break :blk .completed;
            } else .completed;
            const output = if (data) |d| blk: {
                if (d != .object) break :blk "";
                const obj = d.object;
                if (obj.get("output")) |o| {
                    if (o == .string) break :blk o.string;
                }
                break :blk "";
            } else "";
            return .{ .tool_result = .{ .id = id, .status = status, .output = output } };
        } else if (std.mem.eql(u8, event_name, "question_asked")) {
            const request_id = if (data) |d| blk: {
                if (d != .object) break :blk 0;
                const obj = d.object;
                if (obj.get("request_id")) |r| {
                    if (r == .integer) break :blk @as(u32, @intFromFloat(r.integer));
                }
                break :blk 0;
            } else 0;
            const title = if (data) |d| blk: {
                if (d != .object) break :blk "";
                const obj = d.object;
                if (obj.get("title")) |t| {
                    if (t == .string) break :blk t.string;
                }
                break :blk "";
            } else "";
            return .{ .question_asked = .{ .request_id = request_id, .title = title } };
        } else if (std.mem.eql(u8, event_name, "permission_request")) {
            const request_id = if (data) |d| blk: {
                if (d != .object) break :blk 0;
                const obj = d.object;
                if (obj.get("request_id")) |r| {
                    if (r == .integer) break :blk @as(u32, @intFromFloat(r.integer));
                }
                break :blk 0;
            } else 0;
            const title = if (data) |d| blk: {
                if (d != .object) break :blk "";
                const obj = d.object;
                if (obj.get("title")) |t| {
                    if (t == .string) break :blk t.string;
                }
                break :blk "";
            } else "";
            const tool_name = if (data) |d| blk: {
                if (d != .object) break :blk "";
                const obj = d.object;
                if (obj.get("tool_name")) |tn| {
                    if (tn == .string) break :blk tn.string;
                }
                break :blk "";
            } else "";
            return .{ .permission_request = .{ .request_id = request_id, .title = title, .tool_name = tool_name } };
        } else if (std.mem.eql(u8, event_name, "context")) {
            const used = if (data) |d| blk: {
                if (d != .object) break :blk 0;
                const obj = d.object;
                if (obj.get("used")) |u| {
                    if (u == .integer) break :blk @as(u32, @intFromFloat(u.integer));
                }
                break :blk 0;
            } else 0;
            const window = if (data) |d| blk: {
                if (d != .object) break :blk 0;
                const obj = d.object;
                if (obj.get("window")) |w| {
                    if (w == .integer) break :blk @as(u32, @intFromFloat(w.integer));
                }
                break :blk 0;
            } else 0;
            return .{ .context = .{ .used = used, .window = window } };
        } else if (std.mem.eql(u8, event_name, "turn_metrics")) {
            const prompt_tokens = if (data) |d| blk: {
                if (d != .object) break :blk 0;
                const obj = d.object;
                if (obj.get("prompt_tokens")) |pt| {
                    if (pt == .integer) break :blk @as(u32, @intFromFloat(pt.integer));
                }
                break :blk 0;
            } else 0;
            const completion_tokens = if (data) |d| blk: {
                if (d != .object) break :blk 0;
                const obj = d.object;
                if (obj.get("completion_tokens")) |ct| {
                    if (ct == .integer) break :blk @as(u32, @intFromFloat(ct.integer));
                }
                break :blk 0;
            } else 0;
            return .{ .turn_metrics = .{ .prompt_tokens = prompt_tokens, .completion_tokens = completion_tokens } };
        }

        return error.UnknownEvent;
    }
};
