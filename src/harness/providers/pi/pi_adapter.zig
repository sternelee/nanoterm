//! The `HarnessAdapter` over Pi's RPC provider.
const std = @import("std");
const iface = @import("../../adapter.zig");
const types = @import("../../types.zig");
const provider = @import("pi_provider.zig");
const protocol = @import("pi.zig");

pub const PiAdapter = struct {
    provider: *provider.PiProvider,
    sink_ctx: *anyopaque = undefined,

    pub fn harness(self: *PiAdapter) iface.HarnessAdapter {
        return .{
            .id = protocol.id,
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
        const self: *PiAdapter = @ptrCast(@alignCast(ctx));
        try self.provider.sendTurn(input, self.sink_ctx);
    }

    fn cancelTurn(ctx: *anyopaque, session_id: []const u8) anyerror!void {
        const self: *PiAdapter = @ptrCast(@alignCast(ctx));
        try self.provider.cancelTurn(session_id);
    }

    fn stopSession(ctx: *anyopaque, session_id: []const u8) anyerror!void {
        const self: *PiAdapter = @ptrCast(@alignCast(ctx));
        self.provider.stopSession(session_id);
    }

    fn forgetSession(ctx: *anyopaque, session_id: []const u8) anyerror!void {
        const self: *PiAdapter = @ptrCast(@alignCast(ctx));
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
        _ = ctx;
        _ = session_id;
        _ = request_id;
        _ = decision;
    }

    fn respondQuestion(ctx: *anyopaque, session_id: []const u8, request_id: u32, reply: types.UserQuestionReply) void {
        const self: *PiAdapter = @ptrCast(@alignCast(ctx));
        self.provider.respondQuestion(session_id, request_id, reply);
    }

    fn refreshCatalog(ctx: *anyopaque) anyerror!void {
        _ = ctx;
    }
};
