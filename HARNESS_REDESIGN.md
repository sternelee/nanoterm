# Nanoterm Agent Integration Redesign

## Goal

Redesign nanoterm's agent integration to follow monocode's HarnessAdapter pattern, providing:
- Uniform interface across all agents
- Proper Claude Code integration with stream-json + control channel
- Session resume with cwd/account validation
- Separation of isolated helper calls from interactive sessions

## Architecture

### HarnessAdapter Interface

```zig
pub const HarnessAdapter = struct {
    id: []const u8,
    live: bool,
    can_steer: bool = true,

    // Session lifecycle
    send_turn: *const fn (ctx: *anyopaque, input: *const SendTurnInput) anyerror!void,
    cancel_turn: *const fn (ctx: *anyopaque, session_id: []const u8) anyerror!void,
    stop_session: *const fn (ctx: *anyopaque, session_id: []const u8) anyerror!void,
    forget_session: *const fn (ctx: *anyopaque, session_id: []const u8) anyerror!void,
    bind_session: *const fn (ctx: *anyopaque, thread_id: []const u8, provider_session_id: []const u8, cwd: []const u8, provider_account_id: ?[]const u8) void,

    // Approval and questions
    respond_approval: *const fn (ctx: *anyopaque, session_id: []const u8, request_id: u32, decision: ApprovalDecision) void,
    respond_question: *const fn (ctx: *anyopaque, session_id: []const u8, request_id: u32, reply: UserQuestionReply) void,

    // Configuration
    refresh_catalog: *const fn (ctx: *anyopaque) anyerror!void,

    // Optional capabilities
    steer_turn: ?*const fn (ctx: *anyopaque, input: *const SteerTurnInput) anyerror!void = null,
    compact_context: ?*const fn (ctx: *anyopaque, input: *const CompactContextInput) anyerror!void = null,
    generate_title: ?*const fn (ctx: *anyopaque, input: *const TitleInput) anyerror!?[]const u8 = null,
    generate_commit_message: ?*const fn (ctx: *anyopaque, cwd: []const u8, paths: ?[]const []const u8) anyerror!?[]const u8 = null,
    generate_pr_content: ?*const fn (ctx: *anyopaque, cwd: []const u8) anyerror!?PrContent = null,
    generate_branch_name: ?*const fn (ctx: *anyopaque, cwd: []const u8, message: []const u8) anyerror!?[]const u8 = null,
    warmup_text: ?*const fn (ctx: *anyopaque, cwd: []const u8) anyerror!void = null,
    run_text_prompt: ?*const fn (ctx: *anyopaque, input: *const TextPromptInput) anyerror!?[]const u8 = null,
    stop_text_prompt: ?*const fn (ctx: *anyopaque) anyerror!void = null,
};
```

### Common Types

```zig
pub const ApprovalDecision = enum { allow, deny };

pub const UserQuestionReply = union(enum) {
    text: []const u8,
    choice: u32,
};

pub const HarnessEvent = union(enum) {
    session_started: void,
    session_ended: ?i32,
    session_error: []const u8,
    session_provider_bound: []const u8, // providerSessionId
    turn_started: []const u8, // providerTurnId
    turn_ready: void,
    turn_ended: []const u8, // providerTurnId
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
    background_updated: []const []const u8, // task ids
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
    on_event: *const fn (event: HarnessEvent) void,
};
```

### Registry

```zig
pub const HarnessRegistry = struct {
    adapters: std.StringHashMap(*const HarnessAdapter),
    idle_park_timers: std.StringHashMap(IdleParkTimer),
    idle_park_policy: IdleParkPolicy = .{ .max_idle = 3, .park_ms = 3 * 60 * 1000 },

    pub fn init(gpa: std.mem.Allocator) HarnessRegistry { ... }
    pub fn deinit(r: *HarnessRegistry) void { ... }
    pub fn register(r: *HarnessRegistry, adapter: *const HarnessAdapter) !void { ... }
    pub fn get(r: *HarnessRegistry, id: []const u8) ?*const HarnessAdapter { ... }
    pub fn list(r: *HarnessRegistry) []const *const HarnessAdapter { ... }

    // Dispatch methods
    pub fn send_turn(r: *HarnessRegistry, input: *const SendTurnInput, harness_id: []const u8) !void { ... }
    pub fn cancel_turn(r: *HarnessRegistry, harness_id: []const u8, session_id: []const u8) !void { ... }
    pub fn stop_session(r: *HarnessRegistry, harness_id: []const u8, session_id: []const u8) !void { ... }
    // ... other dispatch methods
};
```

## Claude Integration Changes

### Spawn Args

Following monocode's `buildClaudeSpawnArgs`:

```zig
pub fn buildClaudeSpawnArgs(input: ClaudeSpawnInput) ![][]const u8 {
    var args = std.ArrayList([]const u8).init(gpa);
    try args.appendSlice(&[_][]const u8{ "--output-format", "stream-json", "--verbose", "--input-format", "stream-json" });

    if (!input.isolated) {
        try args.appendSlice(&[_][]const u8{ "--permission-prompt-tool", "stdio" });
    }

    if (input.include_partial_messages != false) {
        try args.append("--include-partial-messages");
    }

    const settings = if (input.isolated)
        .{ .disable_all_hooks = true }
    else
        input.settings orelse .{};

    if (input.isolated) {
        try args.appendSlice(&[_][]const u8{ "--no-session-persistence", "--strict-mcp-config" });
        const mcp_config = try std.json.stringifyAlloc(gpa, .{ .mcp_servers = .{} }, .{});
        try args.append("--mcp-config");
        try args.append(mcp_config);
        const settings_json = try std.json.stringifyAlloc(gpa, settings, .{});
        try args.append("--settings");
        try args.append(settings_json);
    } else {
        try args.append("--setting-sources=user,project,local");
        const settings_json = try std.json.stringifyAlloc(gpa, settings, .{});
        try args.append("--settings");
        try args.append(settings_json);
    }

    if (input.model) |m| {
        try args.append("--model");
        try args.append(m);
    }
    if (input.effort) |e| {
        try args.append("--effort");
        try args.append(e);
    }
    if (input.permission_mode) |pm| {
        try args.append("--permission-mode");
        try args.append(@tagName(pm));
    }
    if (input.permission_mode == .bypass_permissions) {
        try args.append("--allow-dangerously-skip-permissions");
    }
    if (input.resume) |r| {
        try args.append("--resume");
        try args.append(r);
    }
    if (input.session_id) |sid| {
        try args.append("--session-id");
        try args.append(sid);
    }
    if (input.max_turns) |mt| {
        try args.append("--max-turns");
        try args.append(try std.fmt.allocPrint(gpa, "{d}", .{mt}));
    }

    return args.toOwnedSlice(gpa);
}
```

### Session Lifecycle

Following monocode's `ensureLive`:

```zig
pub const ClaudeLive = struct {
    cwd: []const u8,
    claude_session_id: []const u8,
    provider_account_id: ?[]const u8,
    runtime_mode: RuntimeMode,
    planning: bool,
    settings_key: []const u8,
    on_event: *const fn (event: HarnessEvent) void,
    // ... other fields
};

pub const ClaudeResume = struct {
    session_id: []const u8,
    cwd: []const u8,
    provider_account_id: ?[]const u8,
};

var live_by_thread = std.StringHashMap(*ClaudeLive).init(gpa);
var resume_by_thread = std.StringHashMap(ClaudeResume).init(gpa);

pub async fn ensureLive(input: *const SendTurnInput) !*ClaudeLive {
    const settings_key = try settingsKeyFor(input);
    const planning = input.intent == .plan;
    const existing = live_by_thread.get(input.session_id);

    // Reuse existing live if cwd/settingsKey/planning match
    if (existing != null and
        std.mem.eql(u8, existing.?.cwd, input.cwd) and
        std.mem.eql(u8, existing.?.settings_key, settings_key) and
        existing.?.planning == planning)
    {
        existing.?.on_event = input.on_event;
        existing.?.runtime_mode = input.runtime_mode;
        return existing.?;
    }

    // Settings changed: stop and restart, but resume conversation if cwd matches
    if (existing != null) {
        if (!std.mem.eql(u8, existing.?.cwd, input.cwd)) {
            _ = resume_by_thread.remove(input.session_id);
        }
        try stopClaudeSession(input.session_id);
    }

    // Check if we can resume
    const resume = resume_by_thread.get(input.session_id);
    const can_resume = resume != null and
        std.mem.eql(u8, resume.?.cwd, input.cwd) and
        sameProviderAccountId(resume.?.provider_account_id, input.provider_account_id);

    if (resume != null and
        (!std.mem.eql(u8, resume.?.cwd, input.cwd) or
         !sameProviderAccountId(resume.?.provider_account_id, input.provider_account_id)))
    {
        _ = resume_by_thread.remove(input.session_id);
    }

    const claude_session_id = if (can_resume and resume != null)
        resume.?.session_id
    else
        try uuidAlloc(gpa);

    const launch = try launchOptions(input, if (can_resume and resume != null) resume.?.session_id else null, claude_session_id);

    const live = try gpa.create(ClaudeLive);
    live.* = .{
        .cwd = try gpa.dupe(u8, input.cwd),
        .claude_session_id = claude_session_id,
        .provider_account_id = if (input.provider_account_id != null) try gpa.dupe(u8, input.provider_account_id.?) else null,
        .runtime_mode = input.runtime_mode,
        .planning = planning,
        .settings_key = settings_key,
        .on_event = input.on_event,
        // ... init other fields
    };

    // Spawn Claude process
    const args = try buildClaudeSpawnArgs(.{
        .model = input.model,
        .effort = input.model_settings.?.effort,
        .permission_mode = runtimeModeToPermission(input.runtime_mode),
        .resume = if (can_resume and resume != null) resume.?.session_id else null,
        .session_id = if (can_resume) null else claude_session_id,
        .settings = .{ .always_thinking_enabled = input.model_settings.?.thinking == .true },
        .isolated = false,
    });

    try spawnClaudeProcess(input.session_id, args, input.cwd);

    try live_by_thread.put(input.session_id, live);
    try resume_by_thread.put(input.session_id, .{
        .session_id = claude_session_id,
        .cwd = try gpa.dupe(u8, input.cwd),
        .provider_account_id = if (input.provider_account_id != null) try gpa.dupe(u8, input.provider_account_id.?) else null,
    });

    // Send initialize control request
    try sendControlRequest(live, .{ .subtype = "initialize" });
    try waitForInit(live, 8_000); // 8 second timeout

    input.on_event(.{ .session_provider_bound = claude_session_id });
    input.on_event(.session_started);

    return live;
}
```

### Control Channel

```zig
pub fn buildControlRequest(request_id: []const u8, request: ControlRequest) ![]const u8 {
    return std.json.stringifyAlloc(gpa, .{
        .type = "control_request",
        .request_id = request_id,
        .request = request,
    }, .{});
}

pub fn parseControlResponse(v: std.json.Value) ?ControlResponse {
    if (v != .object) return null;
    if (!std.mem.eql(u8, str(v, "type") orelse "", "control_response")) return null;
    return .{
        .request_id = str(v, "request_id") orelse "",
        .response = obj(v, "response") orelse .null,
    };
}

pub fn listModelsFromControlResponse(v: std.json.Value, request_id: []const u8) ?[]std.json.Value {
    const resp = parseControlResponse(v) orelse return null;
    if (!std.mem.eql(u8, resp.request_id, request_id)) return null;
    const response = resp.response orelse return null;
    if (response != .object) return null;
    const data = obj(response, "data") orelse return null;
    if (data != .array) return null;
    return data.array.items;
}
```

## Implementation Plan

### Phase 1: Core Infrastructure
1. Create `src/harness/types.zig` - Common types (HarnessEvent, SendTurnInput, etc.)
2. Create `src/harness/registry.zig` - HarnessRegistry implementation
3. Create `src/harness/adapter.zig` - HarnessAdapter interface definition

### Phase 2: Claude Refactor
1. Create `src/harness/providers/claude/claude_protocol.zig` - Protocol parsing, spawn args, control channel
2. Create `src/harness/providers/claude/claude.zig` - Main Claude implementation with ensureLive
3. Create `src/harness/providers/claude/claude_adapter.zig` - HarnessAdapter wrapper
4. Update `src/agent_claude.zig` to use new protocol

### Phase 3: Other Providers
1. Create `src/harness/providers/fx/` - fx adapter (ACP-based)
2. Create `src/harness/providers/codex/` - codex adapter
3. Create `src/harness/providers/opencode/` - opencode adapter
4. ... (grok, devin, hermes, pi)

### Phase 4: Integration
1. Update `src/agent.zig` to use HarnessRegistry
2. Migrate existing Agent struct to use HarnessAdapter dispatch
3. Update UI layer to handle new HarnessEvent types
4. Remove old agent-specific code paths

### Phase 5: Testing
1. Add tests for protocol parsing
2. Add tests for session resume logic
3. Integration tests for each provider
4. Manual testing with real agents

## Migration Notes

- The existing `agent_claude.zig` Client struct can be reused for the low-level stream handling
- The control channel adds new capability (model switching, list_models) that was missing
- Session resume becomes more robust with cwd/account validation
- Isolated helper calls (titles, summaries) can share the same infrastructure with `isolated=true`
