//! Hermes Agent, over its ACP mode (`hermes acp`). Hermes takes the standard
//! ACP prompt blocks, opens a session like any other ACP agent, and exposes
//! its edit-approval modes as `default`, `accept_edits`, and `dont_ask`.
const std = @import("std");
const acp = @import("../../../acp.zig");
const proc = @import("../../../proc.zig");
const agents = @import("../../../agents.zig");
const types = @import("../../types.zig");
const provider = @import("../acp/provider.zig");

pub const id = types.ids.hermes;
pub const label = "Hermes Agent";

pub const auth_help = "Configure Hermes with `hermes model`, then check it with `hermes acp --check`.";

/// `hermes acp`, or an error when the CLI is not installed.
pub fn argv(arena: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, model: ?[]const u8) ![]const []const u8 {
    _ = model;
    const path = agents.searchPath(arena, env.get("PATH") orelse "", env.get("HOME") orelse "/");
    const bin = proc.which(arena, io, path, "hermes") orelse return error.NotInstalled;
    return arena.dupe([]const u8, &.{ bin, "acp" });
}

/// Hermes' edit-approval mode for an access level. A plan and a supervised
/// turn ask before every edit; auto accepts them.
pub fn modeId(mode: types.RuntimeMode, planning: bool) ?[]const u8 {
    if (planning or mode == .plan or mode == .supervised) return "default";
    if (mode == .auto) return "dont_ask";
    return "accept_edits";
}

/// A stderr line that is a real sign-in failure, with the fix appended, or
/// null. Hermes logs provider health to stderr, so only explicit failures
/// become notes; a broad match on words such as "credential" would catch
/// logger names and make working turns look broken.
pub fn stderrNote(gpa: std.mem.Allocator, line: []const u8) ?[]const u8 {
    const text = std.mem.trim(u8, line, " \t\r");
    if (text.len == 0) return null;
    if (std.mem.indexOf(u8, text, "[debug]") != null) return null;
    if (std.mem.indexOf(u8, text, "[info]") != null) return null;
    if (std.mem.indexOf(u8, text, "[warning]") != null) return null;
    const body = afterLevel(text);
    if (!isAuthFailure(body)) return null;
    return std.fmt.allocPrint(gpa, "{s}\n\n{s}", .{ body, auth_help }) catch null;
}

/// Drop a `2026-01-01 … [error] logger:` prefix, leaving the message.
fn afterLevel(text: []const u8) []const u8 {
    const marker = std.mem.indexOf(u8, text, "]") orelse return text;
    if (marker + 1 >= text.len) return text;
    const rest = std.mem.trimStart(u8, text[marker + 1 ..], " \t");
    // A `logger.name: ` prefix, when one is there.
    if (std.mem.indexOfScalar(u8, rest, ':')) |colon| {
        if (colon < 40 and std.mem.indexOfAny(u8, rest[0..colon], " ") == null) {
            return std.mem.trimStart(u8, rest[colon + 1 ..], " \t");
        }
    }
    return rest;
}

fn isAuthFailure(text: []const u8) bool {
    const needles = [_][]const u8{
        "not authenticated",
        "authentication required",
        "authentication failed",
        "unauthorized",
        "missing api key",
        "invalid api key",
        "expired api key",
        "revoked api key",
        "no provider is configured",
        "no llm provider configured",
        "not configured",
        "requires authentication",
    };
    for (needles) |n| if (indexOfIgnoreCase(text, n) != null) return true;
    return false;
}

/// Where `needle` first appears in `hay`, ignoring ASCII case, or null.
fn indexOfIgnoreCase(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > hay.len) return null;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        var match = true;
        for (needle, 0..) |ch, j| {
            if (std.ascii.toLower(hay[i + j]) != std.ascii.toLower(ch)) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

pub fn sessionId(result: std.json.Value) ?[]const u8 {
    return acp.str(result, "sessionId") orelse acp.str(result, "session_id") orelse acp.str(result, "id");
}

/// The models a session offers, from `session/new`'s `models.availableModels`.
pub fn models(arena: std.mem.Allocator, result: std.json.Value) ![]const types.SessionModel {
    const state = acp.obj(result, "models") orelse return &.{};
    const raw = acp.obj(state, "availableModels") orelse acp.obj(state, "available_models") orelse return &.{};
    if (raw != .array) return &.{};
    var out: std.ArrayList(types.SessionModel) = .empty;
    for (raw.array.items) |item| {
        const native = acp.str(item, "modelId") orelse acp.str(item, "model_id") orelse acp.str(item, "value") orelse acp.str(item, "id") orelse continue;
        try out.append(arena, .{ .id = native, .name = acp.str(item, "name") orelse native });
    }
    return out.items;
}

pub fn options() provider.Options {
    return .{ .id = id, .label = label, .argv = argv, .mode_id = modeId, .stderr_note = stderrNote };
}

test "hermes picks a mode per access level" {
    try std.testing.expectEqualStrings("default", modeId(.default, true).?);
    try std.testing.expectEqualStrings("default", modeId(.supervised, false).?);
    try std.testing.expectEqualStrings("dont_ask", modeId(.auto, false).?);
    try std.testing.expectEqualStrings("accept_edits", modeId(.default, false).?);
}

test "only a real sign-in failure becomes a note" {
    const gpa = std.testing.allocator;
    try std.testing.expect(stderrNote(gpa, "2026-01-01T00:00:00Z [info] agent.credential_pool: loaded") == null);
    try std.testing.expect(stderrNote(gpa, "") == null);
    const note = stderrNote(gpa, "2026-01-01T00:00:00Z [error] hermes: not authenticated").?;
    try std.testing.expect(std.mem.indexOf(u8, note, "not authenticated") != null);
    try std.testing.expect(std.mem.indexOf(u8, note, "hermes acp --check") != null);
    gpa.free(note);
}

test "the session's models are read from the ACP state" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try std.json.parseFromSliceLeaky(std.json.Value, a,
        \\{"sessionId":"s1","models":{"currentModelId":"hermes:gpt-5","availableModels":[{"modelId":"hermes:gpt-5","name":"GPT-5"}]}}
    , .{});
    try std.testing.expectEqualStrings("s1", sessionId(v).?);
    const list = try models(a, v);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("hermes:gpt-5", list[0].id);
}
