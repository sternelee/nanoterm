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
    done: Done,
    failed: []u8,
    /// The worker left the busy state; a queued turn may now start.
    idle,

    pub const Tool = struct {
        name: []u8,
        status: []u8,
        output: []u8,
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

    /// Drops the session, so the next prompt opens a fresh conversation;
    /// call between turns, never while one runs (a done event would race).
    pub fn clearSession(self: *Runtime) void {
        if (self.busy()) return;
        const id = self.session_id orelse return;
        self.session_id = null;
        allocator.free(id);
    }

    fn applyPending(self: *Runtime) void {
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

    fn tool(context: ?*anyopaque, name: []const u8, status: []const u8, output: []const u8) anyerror!void {
        const self: *Runtime = @ptrCast(@alignCast(context.?));
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_status = try allocator.dupe(u8, status);
        errdefer allocator.free(owned_status);
        const owned_output = try allocator.dupe(u8, output);
        errdefer allocator.free(owned_output);
        try self.emit(.{ .tool = .{ .name = owned_name, .status = owned_status, .output = owned_output } });
    }

    fn threadMain(self: *Runtime) void {
        defer self.running.store(false, .release);
        const result = engine.run(allocator, self.prompt.?, self.cwd, self.session_id, self.model, self.images, &self.cancelled, .{
            .context = self,
            .text = text,
            .diagnostic = diagnostic,
            .tool = tool,
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
                allocator.free(call.name);
                allocator.free(call.status);
                allocator.free(call.output);
            },
            .done => |done| {
                allocator.free(done.session_id);
                allocator.free(done.model);
            },
            .idle => {},
        }
    }
};
