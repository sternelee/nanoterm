const std = @import("std");
const nanoui = @import("nanoui");
const engine = @import("fx");

var threaded_io: std.Io.Threaded = undefined;
var io_ready = false;

/// agent and its session manager need an explicit std.Io implementation.
pub fn init() void {
    if (io_ready) return;
    threaded_io = .init(std.heap.c_allocator, .{});
    engine.shared_io.setIo(threaded_io.io());
    io_ready = true;
}

pub const Event = union(enum) {
    text: []u8,
    diagnostic: []u8,
    tool: Tool,
    /// A command's output as it arrives, so a long call shows progress.
    output: Output,
    /// A tool call waiting for a person's answer. The worker blocks until
    /// `Runtime.answerPermission` is called with `id`.
    permission: Permission,
    done: Done,
    failed: []u8,
    /// The worker left the busy state; a queued turn may now start.
    idle,

    pub const Tool = struct {
        /// The call's id, shared by its start event and its completion.
        id: []u8,
        name: []u8,
        /// "start", "completed" or "failed".
        status: []u8,
        /// read | edit | delete | move | search | execute | think | fetch | other.
        kind: []u8,
        /// A human-readable action, such as "Reading src/main.zig".
        label: []u8,
        /// The command a shell call runs; empty for every other tool.
        command: []u8,
        /// The call's exit code, when it has one.
        exit_code: ?i64,
        /// How long the call took, in milliseconds.
        duration_ms: ?u64,
        /// What the tool printed, as the host should show it.
        output: []u8,
        /// Whether `output` is the head of more the host did not get.
        truncated: bool,
    };
    pub const Output = struct {
        /// The id of the call whose row this output belongs to.
        call_id: []u8,
        /// True for the command's error stream.
        stderr: bool,
        bytes: []u8,
    };
    pub const Permission = struct {
        /// The question's id, to answer it.
        id: u64,
        label: []u8,
        command: []u8,
        explanation: []u8,
        arguments_preview: []u8,
    };
    pub const Done = struct {
        session_id: []u8,
        model: []u8,
        interrupted: bool,
    };
};

/// One native agent conversation. The worker only owns this queue; Agent applies
/// events to its Turn on nanoterm's UI thread.
pub const ImageAttachment = engine.ImageAttachment;
pub const ExtraStdioServer = engine.ExtraStdioServer;
pub const PermissionAnswer = engine.PermissionAnswer;

pub const Runtime = struct {
    const allocator = std.heap.c_allocator;

    mutex: std.Io.Mutex = .init,
    events: std.ArrayListUnmanaged(Event) = .empty,
    worker: ?std.Thread = null,
    prompt: ?[]u8 = null,
    images: []engine.ImageAttachment = &.{},
    cwd: []u8,
    model: ?[]u8,
    pending_cwd: ?[]u8 = null,
    pending_model: ?[]u8 = null,
    /// A clearSession while busy: the next start opens a fresh session.
    pending_clear: bool = false,
    /// The conversation so far, as fx names it; null opens a fresh one.
    session_id: ?[]u8 = null,
    /// Borrowed from Agent.mcp, which outlives every worker turn.
    extra_mcp: ?ExtraStdioServer = null,
    cancelled: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(false),
    scheduled: std.atomic.Value(bool) = .init(false),
    /// Main-thread view of `running`, to notice the busy -> idle edge.
    was_busy: bool = false,
    refs: std.atomic.Value(usize) = .init(1),
    callback: ?*const fn (?*anyopaque, Event) void = null,
    callback_context: ?*anyopaque = null,
    /// The permission question the worker is blocked on, if any. Guarded by
    /// `permission_mutex`; the worker waits on `permission_changed` until an
    /// answer or a cancel arrives.
    permission_mutex: std.Io.Mutex = .init,
    permission_changed: std.Io.Condition = .init,
    permission_pending: ?u64 = null,
    permission_answer: ?engine.PermissionAnswer = null,
    /// Set when the turn is cancelled while a question is open, so the worker
    /// stops waiting instead of hanging on a card nobody will answer.
    permission_abandoned: bool = false,

    pub fn create(cwd: []const u8, model: ?[]const u8, extra_mcp: ?ExtraStdioServer) !*Runtime {
        init();
        const self = try allocator.create(Runtime);
        errdefer allocator.destroy(self);
        self.* = .{ .cwd = try allocator.dupe(u8, cwd), .model = null, .extra_mcp = extra_mcp };
        errdefer allocator.free(self.cwd);
        if (model) |value| self.model = try allocator.dupe(u8, value);
        return self;
    }

    pub fn setCallback(self: *Runtime, context: ?*anyopaque, callback: *const fn (?*anyopaque, Event) void) void {
        self.callback_context = context;
        self.callback = callback;
    }

    /// Drains the queue the way the app's frame pump does. Tests have no frame
    /// loop, so they call this to see what the worker queued; the app never
    /// does, because `drainMain` already runs on its own schedule.
    fn drainForTest(self: *Runtime) void {
        while (true) {
            const event = blk: {
                self.mutex.lockUncancelable(threaded_io.io());
                defer self.mutex.unlock(threaded_io.io());
                if (self.events.items.len == 0) break :blk null;
                break :blk self.events.orderedRemove(0);
            } orelse break;
            if (self.callback) |callback| callback(self.callback_context, event);
            freeEvent(event);
        }
    }

    pub fn start(self: *Runtime, prompt: []const u8, images: []const engine.ImageAttachment) !void {
        if (self.busy()) return error.Busy;
        if (self.worker) |worker| worker.join();
        self.worker = null;
        self.applyPending();
        const owned_prompt = try allocator.dupe(u8, prompt);
        errdefer allocator.free(owned_prompt);
        const owned_images = try cloneImages(images);
        errdefer freeImages(owned_images);
        if (self.prompt) |old| allocator.free(old);
        self.prompt = owned_prompt;
        freeImages(self.images);
        self.images = owned_images;
        self.cancelled.store(false, .release);
        self.running.store(true, .release);
        self.was_busy = true;
        // Arm the main-thread pump here, not from the worker: Windows timers
        // must be created on the UI thread.
        self.schedule();
        self.worker = std.Thread.spawn(.{}, threadMain, .{self}) catch |err| {
            self.running.store(false, .release);
            return err;
        };
    }

    pub fn cancel(self: *Runtime) void {
        self.cancelled.store(true, .release);
        // A worker blocked on a permission card has no other way out: release
        // it, and the answer it gets is a refusal.
        const zio = threaded_io.io();
        self.permission_mutex.lockUncancelable(zio);
        defer self.permission_mutex.unlock(zio);
        self.permission_abandoned = true;
        self.permission_changed.broadcast(zio);
    }

    /// Answers the open permission question. Ignored when `id` is not the
    /// question the worker is waiting on, so a late click cannot decide the
    /// next one.
    pub fn answerPermission(self: *Runtime, id: u64, answer: engine.PermissionAnswer) void {
        const zio = threaded_io.io();
        self.permission_mutex.lockUncancelable(zio);
        defer self.permission_mutex.unlock(zio);
        if (self.permission_pending != id) return;
        self.permission_answer = answer;
        self.permission_changed.broadcast(zio);
    }

    pub fn busy(self: *Runtime) bool {
        return self.running.load(.acquire);
    }

    pub fn setCwd(self: *Runtime, cwd: []const u8) !void {
        const copy = try allocator.dupe(u8, cwd);
        if (self.busy()) {
            if (self.pending_cwd) |old| allocator.free(old);
            self.pending_cwd = copy;
        } else {
            allocator.free(self.cwd);
            self.cwd = copy;
        }
    }

    pub fn setModel(self: *Runtime, model: []const u8) !void {
        const copy = try allocator.dupe(u8, model);
        if (self.busy()) {
            if (self.pending_model) |old| allocator.free(old);
            self.pending_model = copy;
        } else {
            if (self.model) |old| allocator.free(old);
            self.model = copy;
        }
    }

    /// Drops the session, so the next prompt opens a fresh conversation.
    /// A clear asked while a turn runs (or its worker is still ending)
    /// waits for the next start, as a pending cwd or model does.
    pub fn clearSession(self: *Runtime) void {
        if (self.busy()) {
            self.pending_clear = true;
            return;
        }
        const id = self.session_id orelse return;
        self.session_id = null;
        allocator.free(id);
    }

    fn applyPending(self: *Runtime) void {
        if (self.pending_clear) {
            self.pending_clear = false;
            if (self.session_id) |id| {
                self.session_id = null;
                allocator.free(id);
            }
        }
        if (self.pending_cwd) |cwd| {
            allocator.free(self.cwd);
            self.cwd = cwd;
            self.pending_cwd = null;
        }
        if (self.pending_model) |model| {
            if (self.model) |old| allocator.free(old);
            self.model = model;
            self.pending_model = null;
        }
    }

    pub fn deinit(self: *Runtime) void {
        self.cancel();
        if (self.worker) |worker| worker.join();
        self.worker = null;
        self.callback = null;
        self.callback_context = null;
        self.release();
    }

    fn retain(self: *Runtime) void {
        _ = self.refs.fetchAdd(1, .acq_rel);
    }

    fn release(self: *Runtime) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        for (self.events.items) |event| freeEvent(event);
        self.events.deinit(allocator);
        if (self.prompt) |prompt| allocator.free(prompt);
        freeImages(self.images);
        if (self.session_id) |id| allocator.free(id);
        if (self.model) |model| allocator.free(model);
        if (self.pending_model) |model| allocator.free(model);
        if (self.pending_cwd) |cwd| allocator.free(cwd);
        allocator.free(self.cwd);
        allocator.destroy(self);
    }

    fn schedule(self: *Runtime) void {
        if (self.scheduled.swap(true, .acq_rel)) return;
        self.retain();
        nanoui.App.after(8, self, drainMain);
    }

    fn drainMain(context: ?*anyopaque) callconv(.c) void {
        const self: *Runtime = @ptrCast(@alignCast(context.?));
        self.scheduled.store(false, .release);
        // Drain first, then announce idle: a done event still in the queue must
        // not land on a turn the idle callback starts.
        while (true) {
            const event = blk: {
                self.mutex.lockUncancelable(threaded_io.io());
                defer self.mutex.unlock(threaded_io.io());
                if (self.events.items.len == 0) break :blk null;
                break :blk self.events.orderedRemove(0);
            } orelse break;
            if (self.callback) |callback| callback(self.callback_context, event);
            freeEvent(event);
        }
        if (self.was_busy and !self.busy()) {
            self.was_busy = false;
            if (self.callback) |callback| callback(self.callback_context, .idle);
        }
        self.was_busy = self.busy();
        if (self.busy() or self.hasEvents()) self.schedule();
        self.release();
    }

    fn hasEvents(self: *Runtime) bool {
        self.mutex.lockUncancelable(threaded_io.io());
        defer self.mutex.unlock(threaded_io.io());
        return self.events.items.len != 0;
    }

    fn emit(self: *Runtime, event: Event) !void {
        self.mutex.lockUncancelable(threaded_io.io());
        defer self.mutex.unlock(threaded_io.io());
        try self.events.append(allocator, event);
    }

    fn text(context: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *Runtime = @ptrCast(@alignCast(context.?));
        const copy = try allocator.dupe(u8, bytes);
        errdefer allocator.free(copy);
        try self.emit(.{ .text = copy });
    }

    fn diagnostic(context: ?*anyopaque, bytes: []const u8) anyerror!void {
        const self: *Runtime = @ptrCast(@alignCast(context.?));
        const copy = try allocator.dupe(u8, bytes);
        errdefer allocator.free(copy);
        try self.emit(.{ .diagnostic = copy });
    }

    fn tool(context: ?*anyopaque, event: engine.ToolEvent) anyerror!void {
        const self: *Runtime = @ptrCast(@alignCast(context.?));
        // Every string is copied: fx's arena for the event is freed as soon as
        // this returns, while the queue outlives it.
        const owned_id = try allocator.dupe(u8, event.id);
        errdefer allocator.free(owned_id);
        const owned_name = try allocator.dupe(u8, event.name);
        errdefer allocator.free(owned_name);
        const owned_status = try allocator.dupe(u8, event.status);
        errdefer allocator.free(owned_status);
        const owned_kind = try allocator.dupe(u8, event.kind);
        errdefer allocator.free(owned_kind);
        const owned_label = try allocator.dupe(u8, event.label);
        errdefer allocator.free(owned_label);
        const owned_command = try allocator.dupe(u8, event.command);
        errdefer allocator.free(owned_command);
        const owned_output = try allocator.dupe(u8, event.output);
        errdefer allocator.free(owned_output);
        try self.emit(.{ .tool = .{
            .id = owned_id,
            .name = owned_name,
            .status = owned_status,
            .kind = owned_kind,
            .label = owned_label,
            .command = owned_command,
            .exit_code = event.exit_code,
            .duration_ms = event.duration_ms,
            .output = owned_output,
            .truncated = event.truncated,
        } });
    }

    /// A command's output as it arrives. Copied like every other event, because
    /// fx's buffer is borrowed only for the length of this call.
    fn output(context: ?*anyopaque, call_id: []const u8, stream: engine.OutputStream, bytes: []const u8) anyerror!void {
        const self: *Runtime = @ptrCast(@alignCast(context.?));
        const owned_id = try allocator.dupe(u8, call_id);
        errdefer allocator.free(owned_id);
        const owned_bytes = try allocator.dupe(u8, bytes);
        errdefer allocator.free(owned_bytes);
        try self.emit(.{ .output = .{
            .call_id = owned_id,
            .stderr = stream == .stderr,
            .bytes = owned_bytes,
        } });
    }

    /// fx asks whether a tool may run. The question goes to the UI thread and
    /// this worker blocks until a person answers or the turn is cancelled: fx
    /// cannot go on without a decision, and a refusal is the safe default.
    fn permission(context: ?*anyopaque, request: engine.PermissionRequest) anyerror!engine.PermissionAnswer {
        const self: *Runtime = @ptrCast(@alignCast(context.?));
        const zio = threaded_io.io();
        const owned_label = try allocator.dupe(u8, request.label);
        errdefer allocator.free(owned_label);
        const owned_command = try allocator.dupe(u8, request.command);
        errdefer allocator.free(owned_command);
        const owned_explanation = try allocator.dupe(u8, request.explanation);
        errdefer allocator.free(owned_explanation);
        const owned_preview = try allocator.dupe(u8, request.arguments_preview);
        errdefer allocator.free(owned_preview);

        self.permission_mutex.lockUncancelable(zio);
        self.permission_pending = request.id;
        self.permission_answer = null;
        // A cancel that landed before this question opened has already fired
        // its broadcast, so it would be missed by the wait below. Reading the
        // flag here is what keeps that cancel from leaving the worker waiting
        // on a card nobody will answer.
        self.permission_abandoned = self.cancelled.load(.acquire);
        self.permission_mutex.unlock(zio);

        // Queue the card before waiting, so the UI thread can draw it.
        self.emit(.{ .permission = .{
            .id = request.id,
            .label = owned_label,
            .command = owned_command,
            .explanation = owned_explanation,
            .arguments_preview = owned_preview,
        } }) catch |err| {
            // The card never reached the UI, so no answer can come. Clear the
            // question and let fx treat the call as unavailable.
            self.permission_mutex.lockUncancelable(zio);
            self.permission_pending = null;
            self.permission_mutex.unlock(zio);
            return err;
        };

        self.permission_mutex.lockUncancelable(zio);
        defer self.permission_mutex.unlock(zio);
        while (self.permission_answer == null and
            !self.permission_abandoned and
            !self.cancelled.load(.acquire))
        {
            self.permission_changed.waitUncancelable(zio, &self.permission_mutex);
        }
        const answer = self.permission_answer orelse .deny;
        self.permission_pending = null;
        self.permission_answer = null;
        self.permission_abandoned = false;
        return answer;
    }

    fn threadMain(self: *Runtime) void {
        defer self.running.store(false, .release);
        const result = engine.run(allocator, self.prompt.?, self.cwd, self.session_id, self.model, self.images, &self.cancelled, .{
            .context = self,
            .text = text,
            .diagnostic = diagnostic,
            .tool = tool,
            .permission = permission,
            .output = output,
        }, self.extra_mcp) catch |err| {
            const message = allocator.dupe(u8, @errorName(err)) catch return;
            self.emit(.{ .failed = message }) catch allocator.free(message);
            return;
        };
        defer result.deinit(allocator);

        if (result.model.len > 0) {
            if (self.model) |old| allocator.free(old);
            self.model = allocator.dupe(u8, result.model) catch null;
        }
        if (result.session_id.len > 0) {
            if (self.session_id) |old| allocator.free(old);
            self.session_id = allocator.dupe(u8, result.session_id) catch null;
        }
        self.emitDone(result.session_id, result.model, result.interrupted) catch {};
    }

    fn emitDone(self: *Runtime, session_id: []const u8, model: []const u8, interrupted: bool) !void {
        const owned_session = try allocator.dupe(u8, session_id);
        errdefer allocator.free(owned_session);
        const owned_model = try allocator.dupe(u8, model);
        errdefer allocator.free(owned_model);
        try self.emit(.{ .done = .{
            .session_id = owned_session,
            .model = owned_model,
            .interrupted = interrupted,
        } });
    }

    fn cloneImages(images: []const engine.ImageAttachment) ![]engine.ImageAttachment {
        const copies = try allocator.alloc(engine.ImageAttachment, images.len);
        var initialized: usize = 0;
        errdefer {
            for (copies[0..initialized]) |image| {
                allocator.free(image.path);
                allocator.free(image.media_type);
                if (image.inline_data) |data| allocator.free(data);
            }
            allocator.free(copies);
        }
        for (images, 0..) |image, i| {
            copies[i] = try cloneImage(image);
            initialized += 1;
        }
        return copies;
    }

    fn cloneImage(image: engine.ImageAttachment) !engine.ImageAttachment {
        const path = try allocator.dupe(u8, image.path);
        errdefer allocator.free(path);
        const media_type = try allocator.dupe(u8, image.media_type);
        errdefer allocator.free(media_type);
        const data = if (image.inline_data) |bytes| try allocator.dupe(u8, bytes) else null;
        return .{ .path = path, .media_type = media_type, .inline_data = data };
    }

    fn freeImages(images: []const engine.ImageAttachment) void {
        for (images) |image| {
            allocator.free(image.path);
            allocator.free(image.media_type);
            if (image.inline_data) |data| allocator.free(data);
        }
        if (images.len > 0) allocator.free(images);
    }

    pub fn freeEvent(event: Event) void {
        switch (event) {
            .text, .diagnostic, .failed => |value| allocator.free(value),
            .tool => |call| {
                allocator.free(call.id);
                allocator.free(call.name);
                allocator.free(call.status);
                allocator.free(call.kind);
                allocator.free(call.label);
                allocator.free(call.command);
                allocator.free(call.output);
            },
            .done => |done| {
                allocator.free(done.session_id);
                allocator.free(done.model);
            },
            .output => |chunk| {
                allocator.free(chunk.call_id);
                allocator.free(chunk.bytes);
            },
            .permission => |ask| {
                allocator.free(ask.label);
                allocator.free(ask.command);
                allocator.free(ask.explanation);
                allocator.free(ask.arguments_preview);
            },
            .idle => {},
        }
    }
};

test "a permission question blocks its worker until an answer arrives" {
    const r = try Runtime.create("/tmp", null, null);
    defer r.deinit();
    const Saw = struct {
        /// Only the id is kept: `freeEvent` frees the strings when the drain
        /// returns, so holding the whole event would be a dangling read.
        var got_id: ?u64 = null;
        fn on(_: ?*anyopaque, event: Event) void {
            if (event == .permission) got_id = event.permission.id;
        }
    };
    r.setCallback(@constCast(&Saw), Saw.on);

    // The worker asks; the answer comes from another thread, as a click does.
    const Worker = struct {
        fn run(rt: *Runtime) void {
            const answer = Runtime.permission(@ptrCast(rt), .{
                .id = 7,
                .label = "Write src/main.zig",
                .command = "",
                .explanation = "",
                .arguments_preview = "",
            }) catch .deny;
            answered.store(answer == .always, .release);
        }
        var answered = std.atomic.Value(bool).init(false);
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{r});
    // Give the worker time to queue its card, draining as the frame pump would:
    // `emit` only enqueues, so without a drain the callback never runs.
    var spins: usize = 0;
    while (Saw.got_id == null and spins < 2000) : (spins += 1) {
        r.drainForTest();
        std.Io.sleep(threaded_io.io(), .fromMilliseconds(1), .awake) catch {};
    }
    try std.testing.expect(Saw.got_id != null);
    try std.testing.expectEqual(@as(u64, 7), Saw.got_id.?);
    // A click for a different question must not decide this one.
    r.answerPermission(99, .deny);
    std.Io.sleep(threaded_io.io(), .fromMilliseconds(2), .awake) catch {};
    try std.testing.expect(!Worker.answered.load(.acquire));
    r.answerPermission(7, .always);
    worker.join();
    try std.testing.expect(Worker.answered.load(.acquire));
}

test "cancelling a turn releases a worker waiting on a permission question" {
    const r = try Runtime.create("/tmp", null, null);
    defer r.deinit();
    const Worker = struct {
        fn run(rt: *Runtime) void {
            const answer = Runtime.permission(@ptrCast(rt), .{
                .id = 3,
                .label = "Run rm -rf build",
                .command = "rm -rf build",
                .explanation = "",
                .arguments_preview = "",
            }) catch .once;
            // A cancelled turn must not leave the worker blocked, and what it
            // gets back has to be a refusal rather than a silent allow.
            refused.store(answer == .deny, .release);
        }
        var refused = std.atomic.Value(bool).init(false);
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{r});
    std.Io.sleep(threaded_io.io(), .fromMilliseconds(5), .awake) catch {};
    r.cancel();
    worker.join();
    try std.testing.expect(Worker.refused.load(.acquire));
}

test "a cancel that lands before the question opens still releases the worker" {
    const r = try Runtime.create("/tmp", null, null);
    defer r.deinit();
    // The turn is cancelled while the worker is still between tool calls, so
    // the cancel's broadcast fires before this question exists. Without the
    // flag read at the start of `permission`, the worker would wait forever.
    r.cancel();
    const Worker = struct {
        fn run(rt: *Runtime) void {
            const answer = Runtime.permission(@ptrCast(rt), .{
                .id = 11,
                .label = "Write src/main.zig",
                .command = "",
                .explanation = "",
                .arguments_preview = "",
            }) catch .once;
            refused.store(answer == .deny, .release);
        }
        var refused = std.atomic.Value(bool).init(false);
    };
    const worker = try std.Thread.spawn(.{}, Worker.run, .{r});
    worker.join();
    try std.testing.expect(Worker.refused.load(.acquire));
}

test "a session clear asked while a turn runs waits for the next start" {
    const r = try Runtime.create("/tmp", null, null);
    defer r.deinit();
    r.session_id = try std.heap.c_allocator.dupe(u8, "old");
    // The worker is still ending: the clear cannot take hold yet, but it
    // must not be lost either.
    r.running.store(true, .release);
    r.clearSession();
    r.running.store(false, .release);
    r.applyPending();
    try std.testing.expect(r.session_id == null);
}

test "queued events land before idle is announced" {
    const gpa = std.testing.allocator;
    const r = try Runtime.create("/tmp", null, null);
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(gpa);
    const Seen = struct {
        fn on(context: ?*anyopaque, event: Event) void {
            const list: *std.ArrayList([]const u8) = @ptrCast(@alignCast(context.?));
            const kind = switch (event) {
                .text => "text",
                .diagnostic => "diagnostic",
                .tool => "tool",
                .output => "output",
                .permission => "permission",
                .done => "done",
                .failed => "failed",
                .idle => "idle",
            };
            list.append(std.testing.allocator, kind) catch {};
        }
    };
    r.setCallback(&seen, Seen.on);
    // A worker mid-flight whose answer is already queued, then it leaves
    // busy: everything it said arrives before the next turn may start.
    r.running.store(true, .release);
    r.was_busy = true;
    try r.emit(.{ .text = "" });
    try r.emit(.{ .done = .{ .session_id = "", .model = "", .interrupted = false } });
    r.running.store(false, .release);
    r.retain();
    Runtime.drainMain(@ptrCast(r));
    r.deinit();
    try std.testing.expectEqual(@as(usize, 3), seen.items.len);
    try std.testing.expectEqualStrings("text", seen.items[0]);
    try std.testing.expectEqualStrings("done", seen.items[1]);
    try std.testing.expectEqualStrings("idle", seen.items[2]);
}
