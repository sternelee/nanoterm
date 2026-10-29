//! Conversations with coding agents: the embedded native agent runtime, plus
//! external ACP agents. Updates become turns of messages, thoughts, tools,
//! plans, permission questions, and command blocks.
const std = @import("std");
const acp = @import("acp.zig");
const pi_mod = @import("pi.zig");
const blocks = @import("blocks.zig");
const host = @import("agent_host.zig");
const agent_config = @import("agent_config.zig");
const visual = @import("visual.zig");
const prompt_mod = @import("agent_prompt.zig");
const native_agent = @import("agent_native.zig");

/// Agent is built in; the other agents use ACP (`agents.zig` locates them).
pub const Which = enum {
    agent,
    claude,
    codex,
    opencode,
    grok,
    devin,
    hermes,
    pi,

    pub fn label(w: Which) []const u8 {
        return switch (w) {
            .agent => "Agent",
            .claude => "Claude Code",
            .codex => "Codex",
            .opencode => "opencode",
            .grok => "Grok",
            .devin => "Devin",
            .hermes => "Hermes",
            .pi => "Pi",
        };
    }
};

pub const Status = enum { off, starting, ready, working, failed };
pub const ToolStatus = enum { pending, in_progress, completed, failed };

pub const Tool = struct {
    id: []u8,
    title: std.ArrayList(u8) = .empty,
    kind: []u8,
    status: ToolStatus = .pending,
    /// What the tool showed: a diff's path, text output.
    detail: std.ArrayList(u8) = .empty,
    /// The command the tool runs, if it runs one in a terminal.
    block: ?*blocks.Block = null,
};

pub const PlanEntry = struct { text: []u8, status: []u8 };

pub const Option = struct { id: []u8, name: []u8, kind: []u8 };

pub const Permission = struct {
    /// The request's id as JSON, to answer it.
    rpc_id: []u8,
    title: []u8,
    options: []Option,
    chosen: ?usize = null,
};

/// A visual the agent showed (`show_visual`), live in its turn.
pub const Shown = struct { title: []u8, v: *visual.Visual };

/// Pi's model: `set_model` names it by provider and id.
pub const PiModel = struct { provider: []u8, id: []u8, name: []u8 };
pub const PiChoice = struct { value: []u8, name: []u8, description: []u8 };

fn freePiModel(gpa: std.mem.Allocator, m: ?PiModel) void {
    if (m) |x| {
        gpa.free(x.provider);
        gpa.free(x.id);
        gpa.free(x.name);
    }
}

/// An MCP server for the agent's session (ACP stdio form).
pub const McpServer = struct { name: []const u8, command: []const u8, args: []const []const u8 };

pub const Item = union(enum) {
    text: std.ArrayList(u8),
    thought: std.ArrayList(u8),
    tool: Tool,
    plan: std.ArrayList(PlanEntry),
    permission: Permission,
    command: *blocks.Block,
    note: []u8,
    visual: Shown,
};

/// A picture that goes with a prompt, as ACP sends one.
pub const Image = struct {
    name: []u8,
    /// "image/png", "image/jpeg", …: static.
    mime: []const u8,
    data: []u8,
    /// The file it is (a pasted one, saved to the uploads); empty if none.
    path: []u8 = &.{},

    pub fn free(im: Image, gpa: std.mem.Allocator) void {
        gpa.free(im.name);
        gpa.free(im.data);
        gpa.free(im.path);
    }
};

pub const Turn = struct {
    prompt: []u8,
    /// The pictures sent with the prompt, owned.
    images: []Image = &.{},
    /// What the timeline shows instead of a long prompt ("Fix `make`").
    title: ?[]u8 = null,
    agent: Which,
    items: std.ArrayList(Item) = .empty,
    /// Sent to the agent (not waiting for its session); `done` when the
    /// agent answered the prompt.
    sent: bool = false,
    done: bool = false,
    /// Pi: the `prompt` command is queued behind the turn running now.
    queued: bool = false,
    /// Pi: the id of its `prompt` command, which ties the answer to it.
    pi_cmd: i64 = 0,
    /// Pi: the items present when its current message started; the final
    /// message's content replaces the text and thoughts after it.
    pi_mark: usize = 0,
    started: f64,
    ended: f64 = 0,
    /// Which folded groups of steps are open (view_fold.zig), by order.
    open_groups: u64 = 0,
};

/// What the agent needs from the app around it.
pub const App = struct {
    ctx: *anyopaque,
    changed: *const fn (ctx: *anyopaque) void,
    /// A block for a command the agent runs, which the app keeps.
    newBlock: *const fn (ctx: *anyopaque, command: []const u8, cwd: []const u8) ?*blocks.Block,
    /// A turn ended (for the session history).
    finished: ?*const fn (ctx: *anyopaque, t: *Turn) void = null,
};

pub const Agent = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    app: App,
    which: Which,
    client: acp.Client,
    native: ?*native_agent.Runtime = null,
    native_turn: ?*Turn = null,
    /// Pi speaks its own RPC, not ACP; only used when `which == .pi`.
    pi_client: pi_mod.Client,
    /// Pi: the turn whose events are coming now; it can outlive `done`.
    pi_running: ?*Turn = null,
    /// Pi's model, as `get_state` reports it, for `set_model`.
    pi_model: ?PiModel = null,
    /// The `set_model` and `set_thinking_level` commands still on their way:
    /// a late answer for an older choice must not replace a newer one.
    pi_model_cmd: i64 = 0,
    /// The choice a `set_model` in flight wants; an error restores it.
    pi_wanted: ?[]u8 = null,
    pi_thinking_cmd: i64 = 0,
    /// What Pi offers: models (`provider/id`) and thinking levels.
    pi_models: std.ArrayList(PiChoice) = .empty,
    pi_levels: std.ArrayList([]u8) = .empty,
    pi_level: ?[]u8 = null,
    status: Status = .off,
    session: ?[]u8 = null,
    cwd: []u8,
    turns: std.ArrayList(*Turn) = .empty,
    terminals: host.Terminals,
    error_text: ?[]u8 = null,
    /// A prompt sent before the session was ready waits here.
    queued: ?[]u8 = null,
    /// The agent takes images in prompts (`promptCapabilities.image`).
    images_ok: bool = false,
    /// The environment of the commands it runs, "KEY=value" (the app's).
    env: []const []const u8 = &.{},
    /// What the agent lets the user choose: model, mode, slash commands.
    config: agent_config.Config,
    /// The SSH host its pane is on, if it is: its commands and files
    /// are the host's (agent_remote.zig).
    remote: ?@import("agent_remote.zig").Remote = null,
    /// nanoterm's own MCP server (show_visual), given to the session.
    mcp: ?McpServer = null,
    /// Called when the agent goes, to stop routing visuals to it.
    on_destroy: ?struct { ctx: *anyopaque, func: *const fn (ctx: *anyopaque, a: *Agent) void } = null,
    msg_buf: [512]u8 = undefined,

    pub fn create(gpa: std.mem.Allocator, io: std.Io, app: App, which: Which, cwd: []const u8) !*Agent {
        const a = try gpa.create(Agent);
        a.* = .{
            .gpa = gpa,
            .io = io,
            .app = app,
            .which = which,
            .client = undefined,
            .pi_client = undefined,
            .cwd = try gpa.dupe(u8, cwd),
            .terminals = .init(gpa),
            .config = .{ .gpa = gpa },
        };
        a.client = .init(gpa, .{ .ctx = a, .request = host.onRequest, .notification = onNotification, .exited = onExited });
        a.pi_client = .init(gpa, .{ .ctx = a, .event = piEvent, .exited = piExited });
        return a;
    }

    pub fn destroy(a: *Agent) void {
        if (a.on_destroy) |d| d.func(d.ctx, a);
        if (a.remote) |r| r.deinit(a.gpa);
        if (a.native) |native| native.deinit();
        a.client.deinit();
        a.pi_client.deinit();
        if (a.pi_wanted) |w| a.gpa.free(w);
        freePiModel(a.gpa, a.pi_model);
        for (a.pi_models.items) |m| {
            a.gpa.free(m.value);
            a.gpa.free(m.name);
            a.gpa.free(m.description);
        }
        a.pi_models.deinit(a.gpa);
        for (a.pi_levels.items) |l| a.gpa.free(l);
        a.pi_levels.deinit(a.gpa);
        if (a.pi_level) |l| a.gpa.free(l);
        a.terminals.deinit();
        a.config.deinit();
        for (a.turns.items) |t| freeTurn(a.gpa, t);
        a.turns.deinit(a.gpa);
        if (a.session) |s| a.gpa.free(s);
        if (a.error_text) |e| a.gpa.free(e);
        if (a.queued) |q| a.gpa.free(q);
        a.gpa.free(a.cwd);
        a.gpa.destroy(a);
    }

    fn freeTurn(gpa: std.mem.Allocator, t: *Turn) void {
        for (t.items.items) |*it| freeItem(gpa, it);
        t.items.deinit(gpa);
        gpa.free(t.prompt);
        for (t.images) |im| im.free(gpa);
        if (t.images.len > 0) gpa.free(t.images);
        if (t.title) |x| gpa.free(x);
        gpa.destroy(t);
    }

    fn freeItem(gpa: std.mem.Allocator, it: *Item) void {
        switch (it.*) {
            .text, .thought => |*l| l.deinit(gpa),
            .tool => |*tl| {
                gpa.free(tl.id);
                gpa.free(tl.kind);
                tl.title.deinit(gpa);
                tl.detail.deinit(gpa);
            },
            .plan => |*p| {
                for (p.items) |e| {
                    gpa.free(e.text);
                    gpa.free(e.status);
                }
                p.deinit(gpa);
            },
            .permission => |p| {
                gpa.free(p.rpc_id);
                gpa.free(p.title);
                for (p.options) |o| {
                    gpa.free(o.id);
                    gpa.free(o.name);
                    gpa.free(o.kind);
                }
                gpa.free(p.options);
            },
            .note => |n| gpa.free(n),
            .visual => |sv| {
                gpa.free(sv.title);
                sv.v.destroy();
            },
            .command => {},
        }
    }

    /// Starts the agent's process with `argv` and opens a session.
    pub fn start(a: *Agent, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) !void {
        if (a.which == .agent) return a.startNative(a.cwd, null);
        a.status = .starting;
        const cwd_z = try a.gpa.dupeSentinel(u8, a.cwd, 0);
        defer a.gpa.free(cwd_z);
        if (a.which == .pi) {
            // `pi --mode rpc` opens its session itself; there is no handshake
            // to learn its capabilities from. Pi takes images in a prompt and
            // leaves them out for models that cannot see them.
            a.images_ok = true;
            a.pi_client.start(argv, envp, cwd_z) catch |err| {
                a.fail("could not start the agent: {s}", .{@errorName(err)});
                return err;
            };
            // What it has to offer: its model, the models and thinking
            // levels it offers, its slash commands.
            a.pi_running = null;
            _ = a.pi_client.command("get_state", .{}, a, onPiState) catch 0;
            _ = a.pi_client.command("get_available_models", .{}, a, onPiModels) catch 0;
            _ = a.pi_client.command("get_available_thinking_levels", .{}, a, onPiLevels) catch 0;
            _ = a.pi_client.command("get_commands", .{}, a, onPiCommands) catch 0;
            return;
        }
        a.client.start(argv, envp, cwd_z) catch |err| {
            a.fail("could not start the agent: {s}", .{@errorName(err)});
            return err;
        };
        try a.client.request("initialize", .{
            .protocolVersion = acp.protocol_version,
            .clientCapabilities = .{ .fs = .{ .readTextFile = true, .writeTextFile = true }, .terminal = true },
            .clientInfo = .{ .name = "nanoterm", .version = "0.1.0" },
        }, a, onInitialized);
    }

    pub fn startNative(a: *Agent, cwd: []const u8, model: ?[]const u8) !void {
        std.debug.assert(a.which == .agent);
        const extra: ?native_agent.ExtraStdioServer = if (a.mcp) |m| .{ .name = m.name, .command = m.command, .args = m.args } else null;
        a.native = try native_agent.Runtime.create(cwd, model, extra);
        a.native.?.setCallback(a, onNativeEvent);
        a.status = .ready;
        a.app.changed(a.app.ctx);
    }

    fn fail(a: *Agent, comptime fmt: []const u8, args: anytype) void {
        a.status = .failed;
        if (a.error_text) |e| a.gpa.free(e);
        // The agent's own last words say most: add them.
        const said = if (a.which == .pi)
            a.pi_client.stderr.lastLine()
        else if (a.native == null)
            a.client.stderr.lastLine()
        else
            "";
        a.error_text = if (said.len > 0)
            std.fmt.allocPrint(a.gpa, fmt ++ ": {s}", args ++ .{said}) catch null
        else
            std.fmt.allocPrint(a.gpa, fmt, args) catch null;
        if (a.turns.items.len > 0) {
            const t = a.turns.items[a.turns.items.len - 1];
            if (!t.done) {
                if (a.error_text) |e| a.addItem(t, .{ .note = a.gpa.dupe(u8, e) catch return });
                t.done = true;
                t.ended = blocks.now();
            }
        }
        a.app.changed(a.app.ctx);
    }

    fn onInitialized(ctx: *anyopaque, result: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (err) |e| return a.fail("the agent did not start: {s}", .{e});
        const caps = acp.obj(acp.obj(result orelse .null, "agentCapabilities") orelse .null, "promptCapabilities") orelse .null;
        if (acp.obj(caps, "image")) |v| a.images_ok = v == .bool and v.bool;
        const Env = struct { name: []const u8, value: []const u8 };
        const Server = struct { name: []const u8, command: []const u8, args: []const []const u8, env: []const Env = &.{} };
        const servers: []const Server = if (a.mcp) |m| &.{.{ .name = m.name, .command = m.command, .args = m.args }} else &.{};
        a.client.request("session/new", .{ .cwd = a.cwd, .mcpServers = servers }, a, onSession) catch {};
    }

    fn onSession(ctx: *anyopaque, result: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (err) |e| return a.fail("no session: {s} (is the agent signed in?)", .{e});
        const id = acp.str(result orelse .null, "sessionId") orelse return a.fail("no session id", .{});
        a.session = a.gpa.dupe(u8, id) catch return;
        if (acp.obj(result.?, "configOptions")) |opts| a.config.setOptions(opts);
        a.status = .ready;
        if (a.queued) |q| {
            a.queued = null;
            defer a.gpa.free(q);
            a.send(q, if (a.current()) |t| t.images else &.{});
        }
        a.app.changed(a.app.ctx);
    }

    /// Starts a turn with `text`; it runs once the session is open.
    pub fn prompt(a: *Agent, text: []const u8) !void {
        return a.promptAs(null, text);
    }

    /// A turn whose timeline shows `title` rather than all of `text`.
    pub fn promptAs(a: *Agent, title: ?[]const u8, text: []const u8) !void {
        return a.promptWith(title, text, &.{});
    }

    /// A turn with pictures; it owns `images` (allocated with `gpa`), even
    /// when it fails.
    pub fn promptWith(a: *Agent, title: ?[]const u8, text: []const u8, images: []Image) !void {
        const t = a.gpa.create(Turn) catch |err| {
            for (images) |im| im.free(a.gpa);
            if (images.len > 0) a.gpa.free(images);
            return err;
        };
        t.* = .{
            .prompt = &.{},
            .images = images,
            .agent = a.which,
            .started = blocks.now(),
        };
        {
            errdefer freeTurn(a.gpa, t);
            t.prompt = try a.gpa.dupe(u8, text);
            if (title) |x| t.title = try a.gpa.dupe(u8, x);
            try a.turns.append(a.gpa, t);
        }
        if (a.status == .failed) {
            a.addItem(t, .{ .note = try a.gpa.dupe(u8, a.error_text orelse "the agent is not running") });
            t.done = true;
            return;
        }
        if (a.session == null and a.native == null) {
            if (a.queued) |q| a.gpa.free(q);
            a.queued = try a.gpa.dupe(u8, text);
            return;
        }
        a.send(text, images);
    }

    fn send(a: *Agent, text: []const u8, images: []const Image) void {
        // A prompt sent while Pi streams is a follow-up: it has to say so.
        const streaming = a.status == .working;
        a.status = .working;
        if (a.native) |native| {
            // agent runs one native turn at a time. Turns already own their text
            // and images, so leave newer ones pending until the answer ends.
            if (a.native_turn != null or native.busy()) return;
            const t = a.current() orelse return;
            a.startNativeTurn(t);
            return;
        }
        if (a.current()) |t| t.sent = true;
        var arena: std.heap.ArenaAllocator = .init(a.gpa);
        defer arena.deinit();
        if (a.which == .pi) {
            if (!a.piImages(arena.allocator(), text, images, streaming)) return;
            if (streaming) {
                if (a.current()) |t| t.queued = true;
            } else if (a.current()) |t| a.pi_running = t;
            return;
        }
        const parts = prompt_mod.parts(arena.allocator(), text, images, a.images_ok) catch return;
        // Neither inline nor a file: the agent can't have it.
        var lost: usize = 0;
        for (images) |im| lost += @intFromBool(im.path.len == 0 and !(a.images_ok and im.data.len <= prompt_mod.max_inline_bytes));
        if (lost > 0) if (a.current()) |t| a.addItem(t, .{ .note = std.fmt.allocPrint(a.gpa, "{d} picture(s) could not be sent to {s}", .{ lost, a.which.label() }) catch return });
        a.client.request("session/prompt", .{ .sessionId = a.session.?, .prompt = parts }, a, onPromptDone) catch {};
    }

    fn startNativeTurn(a: *Agent, t: *Turn) void {
        const native = a.native orelse return;
        a.native_turn = t;
        var images: std.ArrayList(native_agent.ImageAttachment) = .empty;
        defer images.deinit(a.gpa);
        for (t.images) |image| {
            images.append(a.gpa, .{ .path = image.name, .media_type = @constCast(image.mime), .inline_data = image.data }) catch {
                a.native_turn = null;
                a.fail("out of memory", .{});
                return;
            };
        }
        native.start(t.prompt, images.items) catch |err| {
            a.native_turn = null;
            // A done event can reach the UI just before the worker clears its
            // running flag. The runtime's idle pump retries this pending turn.
            if (err == error.Busy) {
                a.status = .working;
                return;
            }
            a.fail("could not start agent: {s}", .{@errorName(err)});
            return;
        };
        t.sent = true;
    }

    fn startNextNativeTurn(a: *Agent) void {
        if (a.native == null or a.native_turn != null) return;
        for (a.turns.items) |t| {
            if (t.sent or t.done) continue;
            a.status = .working;
            a.startNativeTurn(t);
            return;
        }
    }

    /// Sends the turn's prompt as Pi's RPC takes it: the text, each picture
    /// base64, and the pictures' files named in the text, as ACP's trailer
    /// does (a model that cannot see them can still open them).
    fn piImages(a: *Agent, arena: std.mem.Allocator, text: []const u8, images: []const Image, streaming: bool) bool {
        const parts = prompt_mod.parts(arena, text, images, false) catch return false;
        const said = if (parts.len > 0) parts[0].text else text;
        var pics: std.ArrayList(pi_mod.Image) = .empty;
        var lost: usize = 0;
        for (images) |im| {
            if (im.data.len > prompt_mod.max_inline_bytes) {
                lost += 1;
                continue;
            }
            pics.append(arena, .{ .data = im.data, .mime = im.mime }) catch return false;
        }
        if (lost > 0) if (a.current()) |t| a.addItem(t, .{ .note = std.fmt.allocPrint(a.gpa, "{d} picture(s) were too large to send", .{lost}) catch return false });
        const cmd = a.pi_client.command("prompt", .{ .message = said, .images = if (pics.items.len > 0) pics.items else null, .streamingBehavior = if (streaming) "followUp" else null }, a, onPiPrompt) catch return false;
        if (a.current()) |t| t.pi_cmd = cmd;
        return true;
    }

    fn onPiPrompt(ctx: *anyopaque, data: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator, cmd: i64) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        var t: *Turn = a.current() orelse return;
        for (a.turns.items) |candidate| if (candidate.pi_cmd == cmd) {
            t = candidate;
            break;
        };
        if (err) |e| {
            a.addItem(t, .{ .note = std.fmt.allocPrint(a.gpa, "error: {s}", .{e}) catch return });
            t.done = true;
            t.ended = blocks.now();
            if (a.pi_running == t) a.pi_running = null;
            if (a.pi_running == null and a.status == .working) a.status = .ready;
            if (a.app.finished) |f| f(a.app.ctx, t);
        } else if (pi_mod.str(data orelse .null, "disposition")) |d| {
            // A prompt Pi turned down leaves no turn running.
            if (std.mem.eql(u8, d, "handled")) {
                t.done = true;
                t.ended = blocks.now();
                if (a.pi_running == t) a.pi_running = null;
                if (a.pi_running == null and a.status == .working) a.status = .ready;
                if (a.app.finished) |f| f(a.app.ctx, t);
            } else if (std.mem.eql(u8, d, "queued")) {
                t.queued = true;
            } else if (std.mem.eql(u8, d, "started")) {
                t.queued = false;
                a.pi_running = t;
            }
        }
        a.app.changed(a.app.ctx);
    }

    /// The oldest prompt the agent hasn't answered: answers come in the
    /// order prompts went, and one may come late, after the next prompt
    /// was sent, so it isn't always the newest turn's.
    fn unanswered(a: *Agent) ?*Turn {
        for (a.turns.items) |t| if (t.sent and !t.done and !t.queued) return t;
        return null;
    }

    /// The Pi turn events belong to: the one Pi is running now. `agent_end`
    /// may come before the last content, so a done turn keeps that place
    /// until `agent_settled`.
    fn piTurn(a: *Agent) ?*Turn {
        return a.pi_running orelse a.unanswered();
    }

    fn onPromptDone(ctx: *anyopaque, result: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        const t = a.unanswered() orelse return;
        if (err) |e| a.addItem(t, .{ .note = std.fmt.allocPrint(a.gpa, "error: {s}", .{e}) catch return });
        if (acp.str(result orelse .null, "stopReason")) |r| {
            if (std.mem.eql(u8, r, "cancelled")) a.addItem(t, .{ .note = a.gpa.dupe(u8, "cancelled") catch return });
        }
        t.done = true;
        t.ended = blocks.now();
        if (a.status == .working and a.unanswered() == null) a.status = .ready;
        if (a.app.finished) |f| f(a.app.ctx, t);
        a.app.changed(a.app.ctx);
    }

    fn onNativeEvent(context: ?*anyopaque, event: native_agent.Event) void {
        const a: *Agent = @ptrCast(@alignCast(context.?));
        const t = switch (event) {
            // The worker just cleared its running flag: retry a turn whose
            // start raced with the previous done event.
            .idle => {
                a.startNextNativeTurn();
                a.app.changed(a.app.ctx);
                return;
            },
            else => a.native_turn orelse return,
        };
        switch (event) {
            .text => |text| {
                if (t.items.items.len > 0 and t.items.items[t.items.items.len - 1] == .text) {
                    t.items.items[t.items.items.len - 1].text.appendSlice(a.gpa, text) catch {};
                } else {
                    var line: std.ArrayList(u8) = .empty;
                    line.appendSlice(a.gpa, text) catch return;
                    a.addItem(t, .{ .text = line });
                }
            },
            .diagnostic => |text| if (text.len > 0) a.addItem(t, .{ .note = a.gpa.dupe(u8, text) catch return }),
            .tool => |call| a.addItem(t, .{ .tool = .{
                .id = a.gpa.dupe(u8, call.name) catch return,
                .kind = a.gpa.dupe(u8, call.name) catch return,
                .title = std.ArrayList(u8).fromOwnedSlice(a.gpa.dupe(u8, call.name) catch return),
                .detail = std.ArrayList(u8).fromOwnedSlice(a.gpa.dupe(u8, call.output) catch return),
                .status = if (std.mem.eql(u8, call.status, "completed") or std.mem.eql(u8, call.status, "success")) .completed else .failed,
            } }),
            .done => |done| {
                t.done = true;
                t.ended = blocks.now();
                a.native_turn = null;
                a.status = .ready;
                if (done.session_id.len > 0) if (a.gpa.dupe(u8, done.session_id) catch null) |session| {
                    if (a.session) |old| a.gpa.free(old);
                    a.session = session;
                };
                if (done.interrupted) a.addItem(t, .{ .note = a.gpa.dupe(u8, "cancelled") catch return });
                if (a.app.finished) |finished| finished(a.app.ctx, t);
                a.startNextNativeTurn();
            },
            .failed => |message| {
                a.addItem(t, .{ .note = std.fmt.allocPrint(a.gpa, "agent: {s}", .{message}) catch return });
                t.done = true;
                t.ended = blocks.now();
                a.native_turn = null;
                a.status = .ready;
                if (a.app.finished) |finished| finished(a.app.ctx, t);
                a.startNextNativeTurn();
            },
            .idle => {},
        }
        a.app.changed(a.app.ctx);
    }

    /// Selects a native agent model, or an ACP config option.
    pub fn setOption(a: *Agent, id: []const u8, value: []const u8) void {
        if (a.which == .pi) return a.setPiOption(id, value);
        if (a.native) |native| {
            if (std.mem.eql(u8, id, "model")) native.setModel(value) catch {};
            a.app.changed(a.app.ctx);
            return;
        }
        const s = a.session orelse return;
        a.config.setCurrent(id, value);
        a.client.request("session/set_config_option", .{ .sessionId = s, .configId = id, .value = value }, a, onOptionSet) catch {};
        a.app.changed(a.app.ctx);
    }

    /// Pi's own commands: `set_model` names a provider and an id,
    /// `set_thinking_level` a level.
    fn setPiOption(a: *Agent, id: []const u8, value: []const u8) void {
        a.config.setCurrent(id, value);
        if (std.mem.eql(u8, id, "model")) {
            const p = pi_mod.providerId(value, if (a.pi_model) |m| m.provider else "");
            a.pi_wanted = a.gpa.dupe(u8, value) catch null;
            a.pi_model_cmd = a.pi_client.command("set_model", .{ .provider = p.provider, .modelId = p.id }, a, onPiModel) catch {
                if (a.pi_wanted) |w| a.gpa.free(w);
                a.pi_wanted = null;
                a.buildPiOptions();
                return;
            };
        } else if (std.mem.eql(u8, id, "thought_level")) {
            a.pi_thinking_cmd = a.pi_client.command("set_thinking_level", .{ .level = value }, a, onPiThinking) catch 0;
        }
        a.app.changed(a.app.ctx);
    }

    fn onPiModel(ctx: *anyopaque, data: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator, cmd: i64) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        // An answer for an older choice loses to the one chosen after it.
        if (cmd != a.pi_model_cmd) return;
        a.pi_model_cmd = 0;
        if (err) |e| {
            // Undo the choice: the model it named was not taken.
            if (a.pi_wanted) |w| {
                a.pi_wanted = null;
                defer a.gpa.free(w);
                a.buildPiOptions();
            } else a.buildPiOptions();
            return a.note(std.fmt.allocPrint(a.gpa, "the model was not set: {s}", .{e}) catch return);
        }
        if (a.pi_wanted) |w| {
            a.pi_wanted = null;
            a.gpa.free(w);
        }
        a.setPiModel(data orelse .null);
        a.app.changed(a.app.ctx);
    }

    fn onPiThinking(ctx: *anyopaque, _: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator, cmd: i64) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (cmd != a.pi_thinking_cmd) return;
        a.pi_thinking_cmd = 0;
        if (err) |e| {
            a.buildPiOptions();
            return a.note(std.fmt.allocPrint(a.gpa, "the thinking level was not set: {s}", .{e}) catch return);
        }
        a.buildPiOptions();
        a.app.changed(a.app.ctx);
    }

    /// A note on the latest turn, for something Pi refused but survived.
    fn note(a: *Agent, text: []u8) void {
        const t = a.current() orelse {
            a.gpa.free(text);
            return;
        };
        t.items.append(a.gpa, .{ .note = text }) catch {
            a.gpa.free(text);
            return;
        };
        a.app.changed(a.app.ctx);
    }

    /// Pi's model, as `get_state` or `set_model` gives it.
    fn setPiModel(a: *Agent, data: std.json.Value) void {
        const m = pi_mod.obj(data, "model") orelse data;
        if (m != .object) return;
        const provider = pi_mod.str(m, "provider") orelse "";
        const id = pi_mod.str(m, "id") orelse return;
        const name = pi_mod.str(m, "name") orelse id;
        freePiModel(a.gpa, a.pi_model);
        a.pi_model = .{
            .provider = a.gpa.dupe(u8, provider) catch return,
            .id = a.gpa.dupe(u8, id) catch return,
            .name = a.gpa.dupe(u8, name) catch return,
        };
        a.buildPiOptions();
    }

    /// The picker's options from what Pi has told us: every model it
    /// offers (`provider/id`, the way `set_model` names one), and its
    /// thinking levels.
    fn buildPiOptions(a: *Agent) void {
        a.config.clearOptions();
        const model = a.pi_model orelse return;
        var choices: std.ArrayList(agent_config.Choice) = .empty;
        defer choices.deinit(a.gpa);
        if (a.pi_models.items.len > 0) {
            for (a.pi_models.items) |m| choices.append(a.gpa, .{
                .value = a.gpa.dupe(u8, m.value) catch continue,
                .name = a.gpa.dupe(u8, m.name) catch continue,
                .description = a.gpa.dupe(u8, m.description) catch continue,
            }) catch {};
        } else {
            const value = std.fmt.allocPrint(a.gpa, "{s}/{s}", .{ model.provider, model.id }) catch return;
            defer a.gpa.free(value);
            choices.append(a.gpa, .{
                .value = a.gpa.dupe(u8, value) catch return,
                .name = a.gpa.dupe(u8, model.name) catch return,
                .description = a.gpa.dupe(u8, model.provider) catch return,
            }) catch return;
        }
        const now = std.fmt.allocPrint(a.gpa, "{s}/{s}", .{ model.provider, model.id }) catch return;
        defer a.gpa.free(now);
        a.config.append("model", "Model", "model", now, choices.toOwnedSlice(a.gpa) catch return) catch return;
        if (a.pi_levels.items.len >= 2 and a.pi_level != null) {
            const lv = a.gpa.alloc(agent_config.Choice, a.pi_levels.items.len) catch return;
            for (a.pi_levels.items, 0..) |l, i| lv[i] = .{
                .value = a.gpa.dupe(u8, l) catch return,
                .name = a.gpa.dupe(u8, l) catch return,
                .description = "",
            };
            a.config.append("thought_level", "Thinking", "thought_level", a.pi_level.?, lv) catch return;
        }
    }

    fn onPiState(ctx: *anyopaque, data: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator, _: i64) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (err) |e| return a.fail("the agent did not start: {s}", .{e});
        const d = data orelse return a.fail("no state from the agent", .{});
        if (pi_mod.obj(d, "model")) |m| a.setPiModel(m);
        if (pi_mod.str(d, "thinkingLevel")) |lv| a.setPiThinking(lv);
        const id = pi_mod.str(d, "sessionId") orelse "";
        if (a.session == null) a.session = a.gpa.dupe(u8, id) catch return;
        a.status = .ready;
        if (a.queued) |q| {
            a.queued = null;
            defer a.gpa.free(q);
            // A turn already answered (`handled`) does not go again.
            const answered = if (a.current()) |t| (t.done and std.mem.eql(u8, t.prompt, q)) else false;
            if (!answered) a.send(q, if (a.current()) |t| t.images else &.{});
        }
        a.app.changed(a.app.ctx);
    }

    fn setPiThinking(a: *Agent, level: []const u8) void {
        if (a.pi_level) |l| a.gpa.free(l);
        a.pi_level = a.gpa.dupe(u8, level) catch null;
        a.buildPiOptions();
    }

    fn onPiModels(ctx: *anyopaque, data: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator, _: i64) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (err != null) return;
        const list = pi_mod.obj(data orelse .null, "models") orelse return;
        if (list != .array) return;
        for (a.pi_models.items) |m| {
            a.gpa.free(m.value);
            a.gpa.free(m.name);
            a.gpa.free(m.description);
        }
        a.pi_models.clearRetainingCapacity();
        for (list.array.items) |m| {
            const provider = pi_mod.str(m, "provider") orelse continue;
            const id = pi_mod.str(m, "id") orelse continue;
            const value = std.fmt.allocPrint(a.gpa, "{s}/{s}", .{ provider, id }) catch continue;
            const name = pi_mod.str(m, "name") orelse id;
            a.pi_models.append(a.gpa, .{
                .value = value,
                .name = a.gpa.dupe(u8, name) catch continue,
                .description = a.gpa.dupe(u8, provider) catch continue,
            }) catch {};
        }
        a.buildPiOptions();
        a.app.changed(a.app.ctx);
    }

    fn onPiLevels(ctx: *anyopaque, data: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator, _: i64) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (err != null) return;
        const list = pi_mod.obj(data orelse .null, "levels") orelse return;
        if (list != .array) return;
        for (a.pi_levels.items) |l| a.gpa.free(l);
        a.pi_levels.clearRetainingCapacity();
        for (list.array.items) |l| {
            if (l != .string) continue;
            a.pi_levels.append(a.gpa, a.gpa.dupe(u8, l.string) catch continue) catch {};
        }
        a.buildPiOptions();
        a.app.changed(a.app.ctx);
    }

    fn onPiCommands(ctx: *anyopaque, data: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator, _: i64) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (err != null) return;
        if (pi_mod.obj(data orelse .null, "commands")) |list| a.config.setCommands(list);
        a.app.changed(a.app.ctx);
    }

    fn onOptionSet(ctx: *anyopaque, result: ?std.json.Value, err: ?[]const u8, _: std.mem.Allocator) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (err == null) if (acp.obj(result orelse .null, "configOptions")) |opts| a.config.setOptions(opts);
        a.app.changed(a.app.ctx);
    }

    /// Stops the turn running.
    pub fn cancel(a: *Agent) void {
        if (a.which == .pi) return a.pi_client.commandNoReply("abort", .{});
        if (a.native) |native| return native.cancel();
        const s = a.session orelse return;
        a.client.notify("session/cancel", .{ .sessionId = s }) catch {};
    }

    pub fn current(a: *Agent) ?*Turn {
        if (a.turns.items.len == 0) return null;
        return a.turns.items[a.turns.items.len - 1];
    }

    pub fn addItem(a: *Agent, t: *Turn, item: Item) void {
        t.items.append(a.gpa, item) catch {};
    }

    /// Shows a visual in the turn running; null, or why it was not shown.
    /// Setup and the first render must work, as Harness checks.
    pub fn showVisual(a: *Agent, title: []const u8, script: []const u8) ?[]const u8 {
        if (visual.validate(title, script)) |e| return e;
        const t = a.current() orelse return "show_visual needs an active turn";
        if (t.done) return "show_visual needs an active turn";
        const v = visual.Visual.create(a.gpa, script) catch return "out of memory";
        if (v.err) |e| {
            const msg = std.fmt.bufPrint(&a.msg_buf, "the visual did not render: {s}", .{e}) catch "the visual did not render";
            v.destroy();
            return msg;
        }
        const owned = a.gpa.dupe(u8, std.mem.trim(u8, title, " \t\r\n")) catch {
            v.destroy();
            return "out of memory";
        };
        t.items.append(a.gpa, .{ .visual = .{ .title = owned, .v = v } }) catch {
            a.gpa.free(owned);
            v.destroy();
            return "out of memory";
        };
        a.app.changed(a.app.ctx);
        return null;
    }

    /// Answers a permission question with option `index`.
    pub fn answer(a: *Agent, p: *Permission, index: usize) void {
        if (p.chosen != null or index >= p.options.len) return;
        p.chosen = index;
        a.client.respond(p.rpc_id, .{ .outcome = .{ .outcome = "selected", .optionId = p.options[index].id } });
        a.app.changed(a.app.ctx);
    }

    fn onExited(ctx: *anyopaque, code: i32) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (a.session) |s| a.gpa.free(s);
        a.session = null;
        a.fail("the agent exited (code {d})", .{code});
    }

    fn piExited(ctx: *anyopaque, code: i32) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (a.session) |s| a.gpa.free(s);
        a.session = null;
        a.pi_running = null;
        a.fail("the agent exited (code {d})", .{code});
    }

    /// Pi's session, event by event (`pi.zig` hands them over as they come).
    fn piEvent(ctx: *anyopaque, record: std.json.Value, _: std.mem.Allocator) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        const kind = pi_mod.str(record, "type") orelse return;
        defer a.app.changed(a.app.ctx);
        if (piAction(a, record, kind)) return;
        const t = a.piTurn() orelse return;
        if (std.mem.eql(u8, kind, "message_start")) {
            a.piMessageStart(t);
        } else if (std.mem.eql(u8, kind, "message_update")) {
            const ev = pi_mod.obj(record, "assistantMessageEvent") orelse return;
            const detail = pi_mod.str(ev, "type") orelse return;
            if (std.mem.eql(u8, detail, "text_delta")) {
                if (pi_mod.str(ev, "delta")) |d| a.appendChunk(t, false, d);
            } else if (std.mem.eql(u8, detail, "thinking_delta")) {
                if (pi_mod.str(ev, "delta")) |d| a.appendChunk(t, true, d);
            } else if (std.mem.eql(u8, detail, "text_end")) {
                // The whole block: the deltas before it drew the same text.
                if (pi_mod.str(ev, "content")) |c| a.piTextEnd(t, false, c);
            } else if (std.mem.eql(u8, detail, "thinking_end")) {
                if (pi_mod.str(ev, "content")) |c| a.piTextEnd(t, true, c);
            } else if (std.mem.eql(u8, detail, "toolcall_start")) {
                a.piToolStart(t, ev);
            } else if (std.mem.eql(u8, detail, "toolcall_end")) {
                if (pi_mod.obj(ev, "toolCall")) |c| a.piToolEnd(t, c);
            }
        } else if (std.mem.eql(u8, kind, "message_end")) {
            if (pi_mod.obj(record, "message")) |m| a.piMessageEnd(t, m);
        } else if (std.mem.eql(u8, kind, "tool_execution_start")) {
            a.piToolRun(t, record, .running);
        } else if (std.mem.eql(u8, kind, "tool_execution_update")) {
            a.piToolRun(t, record, .partial);
        } else if (std.mem.eql(u8, kind, "tool_execution_end")) {
            a.piToolRun(t, record, .done);
        } else if (std.mem.eql(u8, kind, "agent_settled")) {
            a.piSettled(t);
        }
    }

    /// Session-wide events: state that isn't a turn's, and extension UI.
    fn piAction(a: *Agent, record: std.json.Value, kind: []const u8) bool {
        if (std.mem.eql(u8, kind, "thinking_level_changed")) {
            if (pi_mod.str(record, "level")) |lv| a.setPiThinking(lv);
            return true;
        } else if (std.mem.eql(u8, kind, "extension_ui_request")) {
            // Dialogs need the user; this pane has no dialog yet, so they
            // are declined at once rather than left hanging. Notices,
            // titles and widgets are fire-and-forget.
            const method = pi_mod.str(record, "method") orelse return true;
            const id = pi_mod.str(record, "id") orelse return true;
            if (std.mem.eql(u8, method, "confirm")) {
                a.pi_client.extensionResponse(id, .{ .confirmed = false });
                if (a.piTurn()) |t| a.addItem(t, .{ .note = a.gpa.dupe(u8, "an extension asked for confirmation; nanoterm has no dialog for it yet, so it was declined") catch return true });
            } else if (std.mem.eql(u8, method, "select") or std.mem.eql(u8, method, "input") or std.mem.eql(u8, method, "editor")) {
                a.pi_client.extensionResponse(id, .{ .cancelled = true });
                if (a.piTurn()) |t| a.addItem(t, .{ .note = a.gpa.dupe(u8, "an extension asked for input; nanoterm has no dialog for it yet, so it was cancelled") catch return true });
            } else if (std.mem.eql(u8, method, "notify")) {
                if (pi_mod.str(record, "message")) |m| if (a.piTurn()) |t| a.addItem(t, .{ .note = a.gpa.dupe(u8, m) catch return true });
            }
            return true;
        } else if (std.mem.eql(u8, kind, "agent_start")) {
            a.status = .working;
            return true;
        }
        return false;
    }

    /// A tool call as it starts streaming in (`toolcall_start`): its row is
    /// made here, with the id the execution events use. The call's own
    /// arguments finish it (`toolcall_end`).
    fn piToolStart(a: *Agent, t: *Turn, ev: std.json.Value) void {
        const id = pi_mod.str(ev, "id") orelse return;
        if (tool(t, id)) |tl| return a.updatePiTool(tl, ev);
        const name = pi_mod.str(ev, "toolName") orelse "tool";
        const tl = a.piAddTool(t, id, name) orelse return;
        a.updatePiTool(tl, ev);
    }

    /// A new tool row; it owns copies of `id` and `name`.
    fn piAddTool(a: *Agent, t: *Turn, id: []const u8, name: []const u8) ?*Tool {
        const new: Tool = .{
            .id = a.gpa.dupe(u8, id) catch return null,
            .kind = a.gpa.dupe(u8, name) catch return null,
        };
        t.items.append(a.gpa, .{ .tool = new }) catch {
            a.gpa.free(new.id);
            a.gpa.free(new.kind);
            return null;
        };
        return &t.items.items[t.items.items.len - 1].tool;
    }

    fn piToolEnd(a: *Agent, t: *Turn, call: std.json.Value) void {
        const id = pi_mod.str(call, "id") orelse return;
        if (tool(t, id)) |tl| a.updatePiTool(tl, call);
    }

    fn updatePiTool(a: *Agent, tl: *Tool, v: std.json.Value) void {
        if (pi_mod.str(v, "toolName")) |name| {
            tl.title.clearRetainingCapacity();
            tl.title.appendSlice(a.gpa, name) catch {};
        }
        if (pi_mod.obj(v, "arguments")) |args| a.piToolDetail(tl, args);
    }

    /// A tool's command, or the file it changes: what its row shows.
    fn piToolDetail(a: *Agent, tl: *Tool, args: std.json.Value) void {
        const text = pi_mod.str(args, "command") orelse pi_mod.str(args, "path") orelse pi_mod.str(args, "file_path") orelse return;
        tl.detail.clearRetainingCapacity();
        tl.detail.appendSlice(a.gpa, text[0..@min(text.len, 2000)]) catch {};
    }

    const Run = enum { running, partial, done };

    /// Pi's own execution of a tool: its row's status and what it printed.
    fn piToolRun(a: *Agent, t: *Turn, record: std.json.Value, state: Run) void {
        const id = pi_mod.str(record, "toolCallId") orelse return;
        const tl = tool(t, id) orelse blk: {
            const name = pi_mod.str(record, "toolName") orelse "tool";
            const row = a.piAddTool(t, id, name) orelse return;
            row.status = .pending;
            break :blk row;
        };
        if (state == .running) {
            tl.status = .in_progress;
            if (pi_mod.obj(record, "args")) |args| a.piToolDetail(tl, args);
        } else if (state == .done) {
            const failed = if (pi_mod.obj(record, "isError")) |e| (e == .bool and e.bool) else false;
            tl.status = if (failed) .failed else .completed;
            if (pi_mod.obj(record, "result")) |r| a.piToolContent(tl, r);
        } else if (pi_mod.obj(record, "partialResult")) |r| {
            a.piToolContent(tl, r);
        }
    }

    /// A tool result's text: all its text blocks, joined, cut at 2000 bytes.
    fn piToolContent(a: *Agent, tl: *Tool, result: std.json.Value) void {
        const content = pi_mod.obj(result, "content") orelse return;
        if (content != .array) return;
        tl.detail.clearRetainingCapacity();
        for (content.array.items) |c| {
            if (!std.mem.eql(u8, pi_mod.str(c, "type") orelse "", "text")) continue;
            const text = pi_mod.str(c, "text") orelse continue;
            if (tl.detail.items.len > 0) tl.detail.append(a.gpa, '\n') catch return;
            const room = 2000 - @min(tl.detail.items.len, 2000);
            tl.detail.appendSlice(a.gpa, text[0..@min(text.len, room)]) catch return;
        }
    }
    /// The final message, which is authoritative: its content replaces the
    /// text and thoughts streamed so far.
    fn piMessageEnd(a: *Agent, t: *Turn, m: std.json.Value) void {
        const role = pi_mod.str(m, "role") orelse return;
        if (!std.mem.eql(u8, role, "assistant")) return;
        a.piMessageContent(t, m);
        const stop = pi_mod.str(m, "stopReason") orelse return;
        if (std.mem.eql(u8, stop, "error")) {
            const msg = pi_mod.str(m, "errorMessage") orelse "the model failed";
            a.addItem(t, .{ .note = std.fmt.allocPrint(a.gpa, "error: {s}", .{msg}) catch return });
        } else if (std.mem.eql(u8, stop, "aborted")) {
            a.addItem(t, .{ .note = a.gpa.dupe(u8, "cancelled") catch return });
        }
    }

    fn piMessageStart(a: *Agent, t: *Turn) void {
        _ = a;
        t.pi_mark = t.items.items.len;
    }

    /// One content block ended: its whole text replaces the deltas.
    fn piTextEnd(a: *Agent, t: *Turn, thought: bool, content: []const u8) void {
        var at: ?usize = null;
        var i = t.items.items.len;
        while (i > 0) {
            i -= 1;
            switch (t.items.items[i]) {
                .text => if (thought) break else {
                    at = i;
                    break;
                },
                .thought => if (thought) {
                    at = i;
                    break;
                } else break,
                else => break,
            }
        }
        const spot = at orelse t.items.items.len;
        if (at != null) {
            freeItem(a.gpa, &t.items.items[spot]);
            _ = t.items.orderedRemove(spot);
        }
        var l: std.ArrayList(u8) = .empty;
        l.appendSlice(a.gpa, content) catch return;
        t.items.insert(a.gpa, spot, if (thought) .{ .thought = l } else .{ .text = l }) catch {
            l.deinit(a.gpa);
            return;
        };
    }

    /// The final message's content, replacing this message's streamed text.
    /// Blocks are matched by kind, so a tool row keeps its place between
    /// them instead of the text being gathered around it.
    fn piMessageContent(a: *Agent, t: *Turn, m: std.json.Value) void {
        const content = pi_mod.obj(m, "content") orelse return;
        if (content != .array) return;
        const final = content.array.items;
        const used = a.gpa.alloc(bool, final.len) catch return;
        defer a.gpa.free(used);
        @memset(used, false);
        var i = @min(t.pi_mark, t.items.items.len);
        while (i < t.items.items.len) {
            const thought = switch (t.items.items[i]) {
                .text => false,
                .thought => true,
                else => {
                    i += 1;
                    continue;
                },
            };
            var found = false;
            for (final, 0..) |c, n| {
                if (used[n]) continue;
                const kind = pi_mod.str(c, "type") orelse continue;
                const matches = if (thought) std.mem.eql(u8, kind, "thinking") else std.mem.eql(u8, kind, "text");
                if (!matches) continue;
                const text = if (thought) pi_mod.str(c, "thinking") orelse "" else pi_mod.str(c, "text") orelse "";
                switch (t.items.items[i]) {
                    .text => |*l| {
                        l.clearRetainingCapacity();
                        l.appendSlice(a.gpa, text) catch {};
                    },
                    .thought => |*l| {
                        l.clearRetainingCapacity();
                        l.appendSlice(a.gpa, text) catch {};
                    },
                    else => {},
                }
                used[n] = true;
                found = true;
                break;
            }
            if (!found) {
                freeItem(a.gpa, &t.items.items[i]);
                _ = t.items.orderedRemove(i);
                continue;
            }
            i += 1;
        }
        // What the stream did not draw yet (a retried message's blocks).
        for (final, 0..) |c, n| {
            if (used[n]) continue;
            const kind = pi_mod.str(c, "type") orelse continue;
            const text = if (std.mem.eql(u8, kind, "text"))
                pi_mod.str(c, "text") orelse ""
            else if (std.mem.eql(u8, kind, "thinking"))
                pi_mod.str(c, "thinking") orelse ""
            else
                continue;
            var l: std.ArrayList(u8) = .empty;
            l.appendSlice(a.gpa, text) catch return;
            t.items.append(a.gpa, if (std.mem.eql(u8, kind, "text")) .{ .text = l } else .{ .thought = l }) catch {
                l.deinit(a.gpa);
                return;
            };
        }
    }

    /// `agent_settled` is the end of a turn: nothing automatic follows it;
    /// a follow-up queued behind it runs next.
    fn piSettled(a: *Agent, t: *Turn) void {
        if (t.done) return;
        t.done = true;
        t.ended = blocks.now();
        a.pi_running = null;
        if (a.nextQueued()) |q| {
            q.queued = false;
            a.pi_running = q;
        } else {
            a.status = .ready;
        }
        if (a.app.finished) |f| f(a.app.ctx, t);
    }

    fn nextQueued(a: *Agent) ?*Turn {
        for (a.turns.items) |t| if (t.sent and !t.done and t.queued) return t;
        return null;
    }

    fn appendChunk(a: *Agent, t: *Turn, thought: bool, text: []const u8) void {
        if (t.items.items.len > 0) {
            const last = &t.items.items[t.items.items.len - 1];
            switch (last.*) {
                .text => |*l| if (!thought) return l.appendSlice(a.gpa, text) catch {},
                .thought => |*l| if (thought) return l.appendSlice(a.gpa, text) catch {},
                else => {},
            }
        }
        var l: std.ArrayList(u8) = .empty;
        l.appendSlice(a.gpa, text) catch return;
        a.addItem(t, if (thought) .{ .thought = l } else .{ .text = l });
    }

    fn tool(t: *Turn, id: []const u8) ?*Tool {
        for (t.items.items) |*it| switch (it.*) {
            .tool => |*tl| if (std.mem.eql(u8, tl.id, id)) return tl,
            else => {},
        };
        return null;
    }

    fn updateTool(a: *Agent, tl: *Tool, u: std.json.Value) void {
        if (acp.str(u, "title")) |title| {
            tl.title.clearRetainingCapacity();
            tl.title.appendSlice(a.gpa, title) catch {};
        }
        if (acp.str(u, "status")) |s| tl.status = std.meta.stringToEnum(ToolStatus, s) orelse tl.status;
        const content = acp.obj(u, "content") orelse return;
        if (content != .array) return;
        for (content.array.items) |c| {
            const kind = acp.str(c, "type") orelse continue;
            if (std.mem.eql(u8, kind, "terminal")) {
                if (acp.str(c, "terminalId")) |tid| tl.block = a.terminals.block(tid);
            } else if (std.mem.eql(u8, kind, "diff")) {
                tl.detail.clearRetainingCapacity();
                tl.detail.appendSlice(a.gpa, acp.str(c, "path") orelse "") catch {};
            } else if (std.mem.eql(u8, kind, "content")) {
                if (acp.str(acp.obj(c, "content") orelse .null, "text")) |text| {
                    tl.detail.clearRetainingCapacity();
                    tl.detail.appendSlice(a.gpa, text[0..@min(text.len, 2000)]) catch {};
                }
            }
        }
    }

    fn onNotification(ctx: *anyopaque, method: []const u8, params: std.json.Value, _: std.mem.Allocator) void {
        const a: *Agent = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, method, "session/update")) return;
        const u = acp.obj(params, "update") orelse return;
        const kind = acp.str(u, "sessionUpdate") orelse return;
        defer a.app.changed(a.app.ctx);
        // What the agent offers comes before any turn.
        if (std.mem.eql(u8, kind, "available_commands_update")) {
            if (acp.obj(u, "availableCommands")) |list| a.config.setCommands(list);
            return;
        } else if (std.mem.eql(u8, kind, "config_option_update")) {
            if (acp.obj(u, "configOptions")) |opts| a.config.setOptions(opts);
            return;
        } else if (std.mem.eql(u8, kind, "current_mode_update")) {
            if (a.config.find("mode")) |o| if (acp.str(u, "currentModeId")) |m| a.config.setCurrent(o.id, m);
            return;
        }
        const t = a.current() orelse return;
        if (std.mem.eql(u8, kind, "agent_message_chunk") or std.mem.eql(u8, kind, "agent_thought_chunk")) {
            const text = acp.str(acp.obj(u, "content") orelse .null, "text") orelse return;
            a.appendChunk(t, kind[6] == 't', text);
        } else if (std.mem.eql(u8, kind, "tool_call")) {
            const id = acp.str(u, "toolCallId") orelse return;
            if (tool(t, id)) |tl| return a.updateTool(tl, u);
            const new: Tool = .{
                .id = a.gpa.dupe(u8, id) catch return,
                .kind = a.gpa.dupe(u8, acp.str(u, "kind") orelse "other") catch return,
            };
            a.addItem(t, .{ .tool = new });
            a.updateTool(&t.items.items[t.items.items.len - 1].tool, u);
        } else if (std.mem.eql(u8, kind, "tool_call_update")) {
            const id = acp.str(u, "toolCallId") orelse return;
            if (tool(t, id)) |tl| a.updateTool(tl, u);
        } else if (std.mem.eql(u8, kind, "plan")) {
            const entries = acp.obj(u, "entries") orelse return;
            if (entries != .array) return;
            var list: std.ArrayList(PlanEntry) = .empty;
            for (entries.array.items) |e| list.append(a.gpa, .{
                .text = a.gpa.dupe(u8, acp.str(e, "content") orelse "") catch continue,
                .status = a.gpa.dupe(u8, acp.str(e, "status") orelse "pending") catch continue,
            }) catch {};
            // One plan per turn, replaced as it changes.
            for (t.items.items) |*it| switch (it.*) {
                .plan => |*p| {
                    for (p.items) |e| {
                        a.gpa.free(e.text);
                        a.gpa.free(e.status);
                    }
                    p.deinit(a.gpa);
                    p.* = list;
                    return;
                },
                else => {},
            };
            a.addItem(t, .{ .plan = list });
        }
    }
};
