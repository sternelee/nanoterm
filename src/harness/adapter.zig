//! Harness adapter interface and registry.
const std = @import("std");
const types = @import("types.zig");

pub const HarnessAdapter = struct {
    id: []const u8,
    live: bool,
    can_steer: bool = true,
    ctx: *anyopaque,

    // Session lifecycle
    send_turn: *const fn (ctx: *anyopaque, input: *const types.SendTurnInput) anyerror!void,
    cancel_turn: *const fn (ctx: *anyopaque, session_id: []const u8) anyerror!void,
    stop_session: *const fn (ctx: *anyopaque, session_id: []const u8) anyerror!void,
    forget_session: *const fn (ctx: *anyopaque, session_id: []const u8) anyerror!void,
    bind_session: *const fn (ctx: *anyopaque, thread_id: []const u8, provider_session_id: []const u8, cwd: []const u8, provider_account_id: ?[]const u8) void,

    // Approval and questions
    respond_approval: *const fn (ctx: *anyopaque, session_id: []const u8, request_id: u32, decision: types.ApprovalDecision) void,
    respond_question: *const fn (ctx: *anyopaque, session_id: []const u8, request_id: u32, reply: types.UserQuestionReply) void,

    // Configuration
    refresh_catalog: *const fn (ctx: *anyopaque) anyerror!void,

    // Optional capabilities
    steer_turn: ?*const fn (ctx: *anyopaque, input: *const types.SteerTurnInput) anyerror!void = null,
    compact_context: ?*const fn (ctx: *anyopaque, input: *const types.CompactContextInput) anyerror!void = null,
    generate_title: ?*const fn (ctx: *anyopaque, input: *const types.TitleInput) anyerror!?[]const u8 = null,
    generate_commit_message: ?*const fn (ctx: *anyopaque, cwd: []const u8, paths: ?[]const []const u8) anyerror!?[]const u8 = null,
    generate_pr_content: ?*const fn (ctx: *anyopaque, cwd: []const u8) anyerror!?types.PrContent = null,
    generate_branch_name: ?*const fn (ctx: *anyopaque, cwd: []const u8, message: []const u8) anyerror!?[]const u8 = null,
    warmup_text: ?*const fn (ctx: *anyopaque, cwd: []const u8) anyerror!void = null,
    run_text_prompt: ?*const fn (ctx: *anyopaque, input: *const types.TextPromptInput) anyerror!?[]const u8 = null,
    stop_text_prompt: ?*const fn (ctx: *anyopaque) anyerror!void = null,
};

pub const IdleParkPolicy = struct {
    max_idle: usize = 3,
    park_ms: u64 = 3 * 60 * 1000,
};

pub const IdleParkTimer = struct {
    harness_id: []const u8,
    start_time: u64,
};

pub const HarnessRegistry = struct {
    gpa: std.mem.Allocator,
    adapters: std.StringHashMap(*const HarnessAdapter),
    idle_park_timers: std.StringHashMap(IdleParkTimer),
    idle_park_policy: IdleParkPolicy,

    pub fn init(gpa: std.mem.Allocator) HarnessRegistry {
        return .{
            .gpa = gpa,
            .adapters = std.StringHashMap(*const HarnessAdapter).init(gpa),
            .idle_park_timers = std.StringHashMap(IdleParkTimer).init(gpa),
            .idle_park_policy = .{},
        };
    }

    pub fn deinit(r: *HarnessRegistry) void {
        var iter = r.idle_park_timers.iterator();
        while (iter.next()) |entry| {
            r.gpa.free(entry.key_ptr.*);
        }
        r.idle_park_timers.deinit();
        r.adapters.deinit();
    }

    pub fn register(r: *HarnessRegistry, adapter: *const HarnessAdapter) !void {
        const id = try r.gpa.dupe(u8, adapter.id);
        try r.adapters.put(id, adapter);
    }

    pub fn get(r: *HarnessRegistry, id: []const u8) ?*const HarnessAdapter {
        return r.adapters.get(id);
    }

    pub fn list(r: *HarnessRegistry) ![]const *const HarnessAdapter {
        const adapters = try r.gpa.alloc(*const HarnessAdapter, r.adapters.count());
        var i: usize = 0;
        var iter = r.adapters.iterator();
        while (iter.next()) |entry| {
            adapters[i] = entry.value_ptr.*;
            i += 1;
        }
        return adapters;
    }

    pub fn isLive(r: *HarnessRegistry, id: []const u8) bool {
        return r.adapters.get(id) != null and r.adapters.get(id).?.live;
    }

    // Dispatch methods
    pub fn sendTurn(r: *HarnessRegistry, input: *const types.SendTurnInput, harness_id: []const u8) !void {
        const adapter = r.get(harness_id) orelse return error.HarnessNotFound;
        try adapter.send_turn(adapter.ctx, input);
    }

    pub fn cancelTurn(r: *HarnessRegistry, harness_id: []const u8, session_id: []const u8) !void {
        const adapter = r.get(harness_id) orelse return error.HarnessNotFound;
        try adapter.cancel_turn(adapter.ctx, session_id);
    }

    pub fn stopSession(r: *HarnessRegistry, harness_id: []const u8, session_id: []const u8) !void {
        const adapter = r.get(harness_id) orelse return error.HarnessNotFound;
        try adapter.stop_session(adapter.ctx, session_id);
    }

    pub fn forgetSession(r: *HarnessRegistry, harness_id: []const u8, session_id: []const u8) !void {
        const adapter = r.get(harness_id) orelse return error.HarnessNotFound;
        try adapter.forget_session(adapter.ctx, session_id);
    }

    pub fn bindSession(r: *HarnessRegistry, harness_id: []const u8, thread_id: []const u8, provider_session_id: []const u8, cwd: []const u8, provider_account_id: ?[]const u8) !void {
        const adapter = r.get(harness_id) orelse return error.HarnessNotFound;
        adapter.bind_session(adapter.ctx, thread_id, provider_session_id, cwd, provider_account_id);
    }

    pub fn respondApproval(r: *HarnessRegistry, harness_id: []const u8, session_id: []const u8, request_id: u32, decision: types.ApprovalDecision) !void {
        const adapter = r.get(harness_id) orelse return error.HarnessNotFound;
        adapter.respond_approval(adapter.ctx, session_id, request_id, decision);
    }

    pub fn respondQuestion(r: *HarnessRegistry, harness_id: []const u8, session_id: []const u8, request_id: u32, reply: types.UserQuestionReply) !void {
        const adapter = r.get(harness_id) orelse return error.HarnessNotFound;
        if (adapter.respond_question) |fn_| {
            fn_(adapter.ctx, session_id, request_id, reply);
        }
    }

    pub fn refreshCatalog(r: *HarnessRegistry, harness_id: []const u8) !void {
        const adapter = r.get(harness_id) orelse return error.HarnessNotFound;
        try adapter.refresh_catalog(adapter.ctx);
    }

    pub fn canSteer(r: *HarnessRegistry, harness_id: []const u8) bool {
        const adapter = r.get(harness_id) orelse return false;
        return adapter.can_steer and adapter.steer_turn != null;
    }

    pub fn steerTurn(r: *HarnessRegistry, input: *const types.SteerTurnInput, harness_id: []const u8) !void {
        const adapter = r.get(harness_id) orelse return error.HarnessNotFound;
        const fn_ = adapter.steer_turn orelse return error.SteeringNotSupported;
        try fn_(adapter.ctx, input);
    }

    pub fn canCompactContext(r: *HarnessRegistry, harness_id: []const u8) bool {
        const adapter = r.get(harness_id) orelse false;
        return adapter.compact_context != null;
    }

    pub fn compactContext(r: *HarnessRegistry, input: *const types.CompactContextInput, harness_id: []const u8) !void {
        const adapter = r.get(harness_id) orelse return error.HarnessNotFound;
        const fn_ = adapter.compact_context orelse return error.CompactNotSupported;
        try fn_(adapter.ctx, input);
    }

    pub fn generateTitle(r: *HarnessRegistry, input: *const types.TitleInput, harness_id: []const u8) !?[]const u8 {
        const adapter = r.get(harness_id) orelse return error.HarnessNotFound;
        const fn_ = adapter.generate_title orelse return null;
        return try fn_(adapter.ctx, input);
    }

    pub fn generateCommitMessage(r: *HarnessRegistry, harness_id: []const u8, cwd: []const u8, paths: ?[]const []const u8) !?[]const u8 {
        const adapter = r.get(harness_id) orelse return error.HarnessNotFound;
        const fn_ = adapter.generate_commit_message orelse return null;
        return try fn_(adapter.ctx, cwd, paths);
    }

    pub fn generatePrContent(r: *HarnessRegistry, harness_id: []const u8, cwd: []const u8) !?types.PrContent {
        const adapter = r.get(harness_id) orelse return error.HarnessNotFound;
        const fn_ = adapter.generate_pr_content orelse return null;
        return try fn_(adapter.ctx, cwd);
    }

    pub fn generateBranchName(r: *HarnessRegistry, harness_id: []const u8, cwd: []const u8, message: []const u8) !?[]const u8 {
        const adapter = r.get(harness_id) orelse return error.HarnessNotFound;
        const fn_ = adapter.generate_branch_name orelse return null;
        return try fn_(adapter.ctx, cwd, message);
    }

    pub fn warmupText(r: *HarnessRegistry, harness_id: []const u8, cwd: []const u8) !void {
        const adapter = r.get(harness_id) orelse return error.HarnessNotFound;
        const fn_ = adapter.warmup_text orelse return;
        try fn_(adapter.ctx, cwd);
    }

    pub fn canRunTextPrompt(r: *HarnessRegistry, harness_id: []const u8) bool {
        const adapter = r.get(harness_id) orelse false;
        return adapter.run_text_prompt != null;
    }

    pub fn runTextPrompt(r: *HarnessRegistry, input: *const types.TextPromptInput, harness_id: []const u8) !?[]const u8 {
        const adapter = r.get(harness_id) orelse return error.HarnessNotFound;
        const fn_ = adapter.run_text_prompt orelse return null;
        return try fn_(adapter.ctx, input);
    }

    pub fn stopTextPrompts(r: *HarnessRegistry) !void {
        var iter = r.adapters.iterator();
        while (iter.next()) |entry| {
            const adapter = entry.value_ptr.*;
            if (adapter.stop_text_prompt) |fn_| {
                try fn_(adapter.ctx);
            }
        }
    }
};
