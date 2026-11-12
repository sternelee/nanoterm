//! The `HarnessAdapter` over the Claude Code provider. Like the ACP wrapper,
//! it is the adapter's `ctx` and carries the sink context.
const std = @import("std");
const iface = @import("../../adapter.zig");
const types = @import("../../types.zig");
const claude = @import("claude.zig");

pub const ClaudeAdapter = struct {
    provider: *claude.ClaudeProvider,
    sink_ctx: *anyopaque = undefined,

    pub fn harness(self: *ClaudeAdapter) iface.HarnessAdapter {
        return .{
            .id = claude.id,
            .live = true,
            .can_steer = false,
            .ctx = self,
            .send_turn = sendTurn,
            .cancel_turn = cancelTurn,
            .stop_session = stopSession,
            .forget_session = forgetSession,
            .bind_session = bindSession,
            .respond_approval = respondApproval,
            .respond_question = respondQuestion,
            .refresh_catalog = refreshCatalog,
        };
    }

    fn sendTurn(ctx: *anyopaque, input: *const types.SendTurnInput) anyerror!void {
        const self: *ClaudeAdapter = @ptrCast(@alignCast(ctx));
        try self.provider.sendTurn(input, self.sink_ctx);
    }

    fn cancelTurn(ctx: *anyopaque, session_id: []const u8) anyerror!void {
        const self: *ClaudeAdapter = @ptrCast(@alignCast(ctx));
        try self.provider.cancelTurn(session_id);
    }

    fn stopSession(ctx: *anyopaque, session_id: []const u8) anyerror!void {
        const self: *ClaudeAdapter = @ptrCast(@alignCast(ctx));
        self.provider.stopSession(session_id);
    }

    fn forgetSession(ctx: *anyopaque, session_id: []const u8) anyerror!void {
        const self: *ClaudeAdapter = @ptrCast(@alignCast(ctx));
        self.provider.forgetSession(session_id);
    }

    fn bindSession(ctx: *anyopaque, thread_id: []const u8, provider_session_id: []const u8, cwd: []const u8, provider_account_id: ?[]const u8) void {
        _ = ctx;
        _ = thread_id;
        _ = provider_session_id;
        _ = cwd;
        _ = provider_account_id;
    }

    fn respondApproval(ctx: *anyopaque, session_id: []const u8, request_id: u32, decision: types.ApprovalDecision) void {
        const self: *ClaudeAdapter = @ptrCast(@alignCast(ctx));
        self.provider.respondApproval(session_id, request_id, decision);
    }

    fn respondQuestion(ctx: *anyopaque, session_id: []const u8, request_id: u32, reply: types.UserQuestionReply) void {
        _ = ctx;
        _ = session_id;
        _ = request_id;
        _ = reply;
    }

    fn refreshCatalog(ctx: *anyopaque) anyerror!void {
        _ = ctx;
    }
};
