//! Common types for the harness adapter system.
const std = @import("std");

pub const ApprovalDecision = enum { allow, deny };

pub const UserQuestionReply = union(enum) {
    text: []const u8,
    choice: u32,
};

pub const RuntimeMode = enum {
    default,
    supervised,
    plan,
    auto,
};

pub const TurnIntent = enum {
    default,
    plan,
};

pub const ToolKind = enum {
    execute,
    read,
    edit,
    search,
    fetch,
    think,
    other,
};

pub const ToolStatus = enum {
    pending,
    in_progress,
    completed,
    failed,
};

pub const Image = struct {
    name: []const u8,
    mime: []const u8,
    data: []const u8,
    path: []const u8 = &.{},
};

pub const ModelSettings = struct {
    effort: ?[]const u8 = null,
    thinking: ?enum { true, false } = null,
    fast: ?enum { true, false } = null,
    context: ?[]const u8 = null,
};

pub const ToolStart = struct {
    id: []const u8,
    name: []const u8,
    kind: ToolKind,
    input: ?[]const u8 = null,
};

pub const ToolDelta = struct {
    id: []const u8,
    kind: ToolKind,
    delta: []const u8,
};

pub const ToolResult = struct {
    id: []const u8,
    kind: ToolKind,
    output: []const u8,
    status: ToolStatus,
    error_msg: ?[]const u8 = null,
};

pub const QuestionAsked = struct {
    request_id: u32,
    title: []const u8,
    options: []const QuestionOption,
};

pub const QuestionOption = struct {
    id: []const u8,
    name: []const u8,
};

pub const PermissionRequest = struct {
    request_id: u32,
    title: []const u8,
    tool_name: []const u8,
    input: ?[]const u8 = null,
};

pub const ContextLevel = struct {
    used: ?u32 = null,
    window: ?u32 = null,
};

pub const TurnMetrics = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

pub const HarnessEvent = union(enum) {
    session_started: void,
    session_ended: ?i32,
    session_error: []const u8,
    session_provider_bound: []const u8,
    turn_started: []const u8,
    turn_ready: void,
    turn_ended: []const u8,
    turn_cancelled: void,
    status: []const u8,
    message_delta: []const u8,
    message_completed: void,
    reasoning_delta: []const u8,
    reasoning_completed: void,
    tool_start: ToolStart,
    tool_delta: ToolDelta,
    tool_result: ToolResult,
    question_asked: QuestionAsked,
    permission_request: PermissionRequest,
    background_updated: []const []const u8,
    context: ContextLevel,
    turn_metrics: TurnMetrics,
};

pub const SendTurnInput = struct {
    session_id: []const u8,
    cwd: []const u8,
    prompt: []const u8,
    images: []const Image = &.{},
    model: ?[]const u8 = null,
    runtime_mode: RuntimeMode = .default,
    intent: TurnIntent = .default,
    model_settings: ?ModelSettings = null,
    provider_account_id: ?[]const u8 = null,
    on_event: *const fn (ctx: *anyopaque, event: HarnessEvent) void,
};

pub const CompactContextInput = struct {
    session_id: []const u8,
    cwd: []const u8,
    on_event: *const fn (ctx: *anyopaque, event: HarnessEvent) void,
};

pub const SteerTurnInput = struct {
    session_id: []const u8,
    cwd: []const u8,
    text: []const u8,
    on_event: *const fn (ctx: *anyopaque, event: HarnessEvent) void,
};

pub const TitleInput = struct {
    session_id: []const u8,
    cwd: []const u8,
    transcript: []const []const u8,
    on_event: *const fn (ctx: *anyopaque, event: HarnessEvent) void,
};

pub const TextPromptInput = struct {
    session_id: []const u8,
    cwd: []const u8,
    prompt: []const u8,
    on_event: *const fn (ctx: *anyopaque, event: HarnessEvent) void,
};

pub const PrContent = struct {
    title: []const u8,
    body: []const u8,
};
