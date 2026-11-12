//! Common types for the harness adapter system.
const std = @import("std");

/// The provider ids a harness adapter is registered under. They match the
/// `Agent.Which` names, so the UI can map one to the other.
pub const ids = struct {
    pub const claude = "claude";
    pub const codex = "codex";
    pub const opencode = "opencode";
    pub const grok = "grok";
    pub const devin = "devin";
    pub const hermes = "hermes";
    pub const pi = "pi";
};

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

/// ACP tool-call kinds as words; anything unknown is `other`.
pub fn toolKindFromName(name: []const u8) ToolKind {
    const eq = std.mem.eql;
    if (eq(u8, name, "execute")) return .execute;
    if (eq(u8, name, "read")) return .read;
    if (eq(u8, name, "edit")) return .edit;
    if (eq(u8, name, "search")) return .search;
    if (eq(u8, name, "fetch")) return .fetch;
    if (eq(u8, name, "think")) return .think;
    return .other;
}

pub fn toolKindName(kind: ToolKind) []const u8 {
    return @tagName(kind);
}

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

/// One entry of a plan the agent keeps for the turn.
pub const PlanEntry = struct {
    text: []const u8,
    status: []const u8 = "pending",
};

/// A slash command an agent advertises (`available_commands_update`).
pub const CommandInfo = struct {
    name: []const u8,
    description: []const u8 = "",
};

/// One value of a config option an agent offers.
pub const ConfigValue = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8 = "",
};

/// A choice an agent offers (model, mode, thinking level), as ACP's
/// `configOptions` gives it.
pub const ConfigOption = struct {
    id: []const u8,
    name: []const u8,
    category: []const u8 = "",
    current: []const u8 = "",
    values: []const ConfigValue = &.{},
};

/// What an agent said about its own configuration. Each variant replaces
/// the matching part of the client's view, as the ACP updates do.
pub const ConfigUpdate = union(enum) {
    commands: []const CommandInfo,
    options: []const ConfigOption,
    current_mode: struct { id: []const u8, value: []const u8 },
};

/// A model an agent offers in its session state (`session/new`'s `models`).
pub const SessionModel = struct {
    id: []const u8,
    name: []const u8,
};

/// A mode an agent offers in its session state (`modes`).
pub const SessionMode = struct {
    id: []const u8,
    name: []const u8,
};

/// The choices a session opened with, taken from `session/new`'s result.
pub const SessionInfo = struct {
    session_id: []const u8 = "",
    models: []const SessionModel = &.{},
    current_model: ?[]const u8 = null,
    modes: []const SessionMode = &.{},
    current_mode: ?[]const u8 = null,
    options: []const ConfigOption = &.{},
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
    /// A line an agent wrote to stderr that a turn should show as a note.
    note: []const u8,
    message_delta: []const u8,
    message_completed: void,
    reasoning_delta: []const u8,
    reasoning_completed: void,
    tool_start: ToolStart,
    tool_delta: ToolDelta,
    tool_result: ToolResult,
    plan: []const PlanEntry,
    config: ConfigUpdate,
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
