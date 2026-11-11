//! Claude Code harness adapter wrapper.
const std = @import("std");
const harness_types = @import("../../types.zig");
const harness_adapter = @import("../../adapter.zig");
const claude_provider = @import("claude.zig");

pub const ClaudeAdapter = struct {
    provider: *claude_provider.ClaudeProvider,
    thread_id: []const u8,

    pub fn asHarnessAdapter(adapter: *ClaudeAdapter) harness_adapter.HarnessAdapter {
        return .{
            .id = "claude",
            .live = true,
            .can_steer = true,
            .ctx = adapter,
            .send_turn = sendTurn,
            .cancel_turn = cancelTurn,
            .stop_session = stopSession,
            .forget_session = forgetSession,
            .bind_session = bindSession,
            .respond_approval = respondApproval,
            .respond_question = respondQuestion,
            .refresh_catalog = refreshCatalog,
            .steer_turn = null,
            .compact_context = null,
            .generate_title = null,
            .generate_commit_message = null,
            .generate_pr_content = null,
            .generate_branch_name = null,
            .warmup_text = null,
            .run_text_prompt = null,
            .stop_text_prompts = null,
        };
    }

    fn sendTurn(ctx: *anyopaque, thread_id: []const u8, input: harness_types.SendTurnInput) !void {
        const adapter: *ClaudeAdapter = @ptrCast(@alignCast(ctx));
        try adapter.provider.sendTurn(thread_id, input);
    }

    fn cancelTurn(ctx: *anyopaque, thread_id: []const u8) !void {
        const adapter: *ClaudeAdapter = @ptrCast(@alignCast(ctx));
        try adapter.provider.cancelTurn(thread_id);
    }

    fn stopSession(ctx: *anyopaque, thread_id: []const u8) void {
        const adapter: *ClaudeAdapter = @ptrCast(@alignCast(ctx));
        adapter.provider.stopSession(thread_id);
    }

    fn forgetSession(ctx: *anyopaque, thread_id: []const u8) void {
        const adapter: *ClaudeAdapter = @ptrCast(@alignCast(ctx));
        adapter.provider.forgetSession(thread_id);
    }

    fn bindSession(ctx: *anyopaque, thread_id: []const u8, session_id: []const u8) !void {
        const adapter: *ClaudeAdapter = @ptrCast(@alignCast(ctx));
        try adapter.provider.bindSession(thread_id, session_id);
    }

    fn respondApproval(ctx: *anyopaque, thread_id: []const u8, input: harness_types.ApprovalDecision) !void {
        const adapter: *ClaudeAdapter = @ptrCast(@alignCast(ctx));
        try adapter.provider.respondApproval(thread_id, input);
    }

    fn respondQuestion(ctx: *anyopaque, thread_id: []const u8, input: harness_types.UserQuestionReply) !void {
        const adapter: *ClaudeAdapter = @ptrCast(@alignCast(ctx));
        try adapter.provider.respondQuestion(thread_id, input);
    }

    fn refreshCatalog(ctx: *anyopaque) !void {
        const adapter: *ClaudeAdapter = @ptrCast(@alignCast(ctx));
        try adapter.provider.refreshCatalog();
    }
};
