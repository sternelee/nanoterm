//! The built-in Agent's own fx surface: the slash commands nanoterm routes
//! for it (the embedded runtime takes plain prompts), the settings it reads
//! and writes through agent's locking store (reasoning effort, permission
//! mode, additional workspaces), and the conversation handoff `/compact`
//! performs between sessions.
const std = @import("std");
const engine = @import("fx");
const agent_config = @import("agent_config.zig");
const session_mod = @import("session.zig");
const assist = @import("assist.zig");

const Session = session_mod.Session;

/// A command nanoterm knows how to run for the built-in Agent; the ones it
/// does not (status, usage, …) stay with fx itself and are not offered.
pub const Spec = struct { name: []const u8, description: []const u8, hint: []const u8 };

pub const specs = [_]Spec{
    .{ .name = "compact", .description = "summarize the conversation, then continue in a fresh session", .hint = "" },
    .{ .name = "model", .description = "choose what model the agent uses", .hint = "<id-or-query>" },
    .{ .name = "effort", .description = "the reasoning effort the model spends", .hint = "[auto|minimal|low|medium|high]" },
    .{ .name = "permissions", .description = "what fx is allowed to do without asking", .hint = "[ask|auto|full-access]" },
    .{ .name = "new", .description = "a fresh conversation, background processes kept", .hint = "" },
    .{ .name = "workspace", .description = "additional directories fx can work in", .hint = "[list|add <path>|remove <path>]" },
    .{ .name = "login", .description = "sign in to a provider (runs in the terminal)", .hint = "[codex|grok|vercel]" },
    .{ .name = "logout", .description = "sign out of a provider (runs in the terminal)", .hint = "[codex|grok|vercel]" },
};

/// The argument words a command takes, for the slash menu's next word.
pub fn words(name: []const u8) ?[]const []const u8 {
    const effort_words = [_][]const u8{ "auto", "minimal", "low", "medium", "high" };
    const permission_words = [_][]const u8{ "ask", "auto", "full-access", "reset" };
    const workspace_words = [_][]const u8{ "list", "add", "remove" };
    const login_words = [_][]const u8{ "codex", "grok", "vercel" };
    if (std.mem.eql(u8, name, "effort")) return effort_words[0..];
    if (std.mem.eql(u8, name, "permissions")) return permission_words[0..];
    if (std.mem.eql(u8, name, "workspace")) return workspace_words[0..];
    if (std.mem.eql(u8, name, "login") or std.mem.eql(u8, name, "logout")) return login_words[0..];
    return null;
}

/// Fills the agent's slash menu with the commands above; the strings are
/// copied, as Config owns (and frees) them.
pub fn seed(gpa: std.mem.Allocator, config: *agent_config.Config) void {
    config.clearCommands();
    for (specs) |spec| {
        config.commands.append(gpa, .{
            .name = gpa.dupe(u8, spec.name) catch continue,
            .description = gpa.dupe(u8, spec.description) catch continue,
            .hint = gpa.dupe(u8, spec.hint) catch continue,
        }) catch {};
    }
}

// Settings: effort and permission mode, read and written through fx's store.

/// Writes the reasoning effort ("auto", or a level such as "high").
pub fn setEffort(gpa: std.mem.Allocator, home: []const u8, level: []const u8) !void {
    const value: engine.provider_settings.UserSettingsPatch = if (std.ascii.eqlIgnoreCase(level, "auto"))
        .{ .effort = .auto }
    else blk: {
        if (level.len == 0 or level.len > 64) return error.InvalidEffort;
        for (level) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_' and byte != '.') return error.InvalidEffort;
        }
        var bytes = std.mem.zeroes([64]u8);
        @memcpy(bytes[0..level.len], level);
        break :blk .{ .effort = .{ .named = .{ .bytes = bytes, .len = @intCast(level.len) } } };
    };
    var outcome = try engine.provider_settings.setUserPreferencesAtHome(gpa, home, value);
    defer outcome.deinit(gpa);
}

/// The effort as written in settings.json, for display; "auto" shows as
/// "default", as fx itself labels it. Fills `buf` (a fallback when the
/// setting is absent).
pub fn readEffort(buf: []u8, gpa: std.mem.Allocator, home: []const u8) []const u8 {
    const raw = readSetting(gpa, home, "effort") orelse return "default";
    defer gpa.free(raw);
    const label: []const u8 = if (std.ascii.eqlIgnoreCase(raw, "auto")) "default" else raw;
    if (label.len > buf.len) return "default";
    @memcpy(buf[0..label.len], label);
    return buf[0..label.len];
}

/// Writes the permission mode; "full-access" (also "full access", "yolo")
/// is fx's `yolo`.
pub fn setPermission(gpa: std.mem.Allocator, home: []const u8, mode: []const u8) !void {
    const value: engine.provider_settings.UserSettingsPatch = blk: {
        if (asciiEqlAny(mode, &.{ "full-access", "full access", "yolo" })) break :blk .{ .permission_mode = .yolo };
        if (std.ascii.eqlIgnoreCase(mode, "ask")) break :blk .{ .permission_mode = .ask };
        if (std.ascii.eqlIgnoreCase(mode, "auto")) break :blk .{ .permission_mode = .auto };
        return error.InvalidPermissionMode;
    };
    var outcome = try engine.provider_settings.setUserPreferencesAtHome(gpa, home, value);
    defer outcome.deinit(gpa);
}

/// The permission mode as fx resolves it for a workspace: "ask", "auto" (the
/// default), or "full-access".
pub fn readPermission(gpa: std.mem.Allocator, home: []const u8, workspace_root: []const u8) ?[]u8 {
    var status = engine.provider_settings.loadStartupStatusSettingsFromHome(gpa, home, workspace_root) catch return null;
    defer status.deinit(gpa);
    const mode = status.permission_mode orelse return gpa.dupe(u8, "auto") catch null;
    const label = switch (mode) {
        .ask => "ask",
        .auto => "auto",
        .yolo => "full-access",
    };
    return gpa.dupe(u8, label) catch null;
}

// Additional workspaces: saved per workspace root in settings.json.

/// The directories saved for `workspace_root`, absolute; free with gpa.
pub fn readDirs(gpa: std.mem.Allocator, home: []const u8, workspace_root: []const u8) []([]u8) {
    var paths: std.ArrayList([]u8) = .empty;
    errdefer for (paths.items) |path| gpa.free(path);
    const settings = joinSettings(gpa, home) catch return &.{};
    defer gpa.free(settings);
    const data = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.io(), settings, gpa, .limited(1024 * 1024)) catch return paths.toOwnedSlice(gpa) catch &.{};
    defer gpa.free(data);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch return paths.toOwnedSlice(gpa) catch &.{};
    defer parsed.deinit();
    if (parsed.value != .object) return paths.toOwnedSlice(gpa) catch &.{};
    const workspaces = parsed.value.object.get("workspaces") orelse return paths.toOwnedSlice(gpa) catch &.{};
    if (workspaces != .object) return paths.toOwnedSlice(gpa) catch &.{};
    const entry = workspaces.object.get(workspace_root) orelse return paths.toOwnedSlice(gpa) catch &.{};
    if (entry != .object) return paths.toOwnedSlice(gpa) catch &.{};
    const dirs = entry.object.get("additional_directories") orelse return paths.toOwnedSlice(gpa) catch &.{};
    if (dirs != .array) return paths.toOwnedSlice(gpa) catch &.{};
    for (dirs.array.items) |item| {
        if (item != .string) continue;
        paths.append(gpa, gpa.dupe(u8, item.string) catch continue) catch continue;
    }
    return paths.toOwnedSlice(gpa) catch &.{};
}

/// The patch shape fx's directory mutation takes, without naming its type:
/// add, remove, or clear.
pub const DirPatch = blk: {
    const Mutation = @typeInfo(@TypeOf(engine.provider_settings.mutateWorkspaceDirectory)).@"fn".param_types[1].?;
    const info = @typeInfo(Mutation).@"struct";
    for (info.field_names, info.field_types) |name, field_type| {
        if (std.mem.eql(u8, name, "patch")) break :blk field_type;
    }
    unreachable;
};

/// Saves (or drops) a directory for `workspace_root` in fx's store. `home`
/// is read from the environment, as fx's own mutation does. A remove names
/// the saved path as its observed source — fx only removes what a session
/// sees — so the entry drops even when no session is running.
pub fn changeDir(gpa: std.mem.Allocator, workspace_root: []const u8, patch: DirPatch) !void {
    var identity: [2048]u8 = undefined;
    const observed = switch (patch) {
        .remove => |path| path,
        else => null,
    };
    const sources = [_]ObservedDir{
        .{ .source = observed orelse "", .identity = observed orelse "" },
    };
    var outcome = try engine.provider_settings.mutateWorkspaceDirectory(gpa, .{
        .workspace_root = workspace_root,
        .patch = patch,
        .observed_sources = if (observed != null) sources[0..] else &.{},
    });
    defer outcome.deinit(gpa);
    _ = &identity;
}

/// The observed-source shape fx's directory mutation takes.
pub const ObservedDir = blk: {
    const Mutation = @typeInfo(@TypeOf(engine.provider_settings.mutateWorkspaceDirectory)).@"fn".param_types[1].?;
    const info = @typeInfo(Mutation).@"struct";
    for (info.field_names, info.field_types) |name, field_type| {
        if (std.mem.eql(u8, name, "observed_sources")) {
            const Slice = @typeInfo(field_type).pointer;
            break :blk Slice.child;
        }
    }
    unreachable;
};

/// The AGENTS.md files fx loads for `cwd`: the project's root one, then any
/// between it and the directory, root-most first; free with gpa.
pub fn instructions(gpa: std.mem.Allocator, cwd: []const u8) [][]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    var found: std.ArrayList([]u8) = .empty;
    errdefer for (found.items) |path| gpa.free(path);
    var chain: [32][]const u8 = undefined;
    var depth: usize = 0;
    var rest = cwd;
    while (rest.len > 1 and depth < chain.len) {
        chain[depth] = rest;
        depth += 1;
        rest = std.fs.path.dirname(rest) orelse break;
    }
    var i: usize = depth;
    while (i > 0) {
        i -= 1;
        const path = std.fs.path.join(gpa, &.{ chain[i], "AGENTS.md" }) catch continue;
        errdefer gpa.free(path);
        std.Io.Dir.cwd().access(io, path, .{}) catch {
            gpa.free(path);
            continue;
        };
        found.append(gpa, path) catch continue;
    }
    return found.toOwnedSlice(gpa) catch &.{};
}

// Routing: run the commands above for the built-in Agent.

/// Runs a slash command nanoterm handles; false when the text should go to
/// the agent as a prompt after all (a command it never told us about).
pub fn route(s: *Session, text: []const u8) bool {
    if (s.which != .agent or text.len < 2 or text[0] != '/') return false;
    var command = text[1..];
    var arg: []const u8 = "";
    if (std.mem.indexOfScalar(u8, command, ' ')) |space| {
        command = command[0..space];
        arg = std.mem.trim(u8, command[space + 1 ..], " \t");
    }
    if (!known(command)) return false;
    _ = s.ensureAgent();
    if (std.mem.eql(u8, command, "compact")) return compact(s);
    if (std.mem.eql(u8, command, "new")) return fresh(s);
    if (std.mem.eql(u8, command, "model")) {
        if (arg.len == 0) return note(s, "⌘⇧M opens the model picker; /model <id> chooses one directly.");
        assist.chooseModel(s, arg);
        return true;
    }
    if (std.mem.eql(u8, command, "effort")) return effort(s, arg);
    if (std.mem.eql(u8, command, "permissions")) return permission(s, arg);
    if (std.mem.eql(u8, command, "workspace")) return workspace(s, arg);
    if (std.mem.eql(u8, command, "login") or std.mem.eql(u8, command, "logout")) return signInOut(s, command, arg);
    return false;
}

fn known(name: []const u8) bool {
    for (specs) |spec| if (std.mem.eql(u8, spec.name, name)) return true;
    return false;
}

/// `/compact`: the running conversation is asked for a handoff note; when it
/// answers, a fresh session continues from that note (session_agent.finished).
fn compact(s: *Session) bool {
    const ag = s.agent orelse return false;
    if (ag.status == .working) return note(s, "wait for the agent to finish, then /compact.");
    s.compact_pending = true;
    s.askAs("/compact", "Summarize this conversation so far as a handoff note for continuing the same work in a fresh session: the task, decisions made, current state of the files, and the next steps. Keep it dense and factual.");
    return true;
}

/// Continues a finished /compact: carries the handoff into a fresh session.
/// Called from session_agent.finished with the finished turn's reply.
pub fn carry(s: *Session, reply: []const u8) void {
    s.compact_pending = false;
    if (reply.len == 0) {
        _ = note(s, "nothing to carry over; the conversation continues.");
        return;
    }
    const prompt = std.fmt.allocPrint(s.gpa, "We are continuing in a fresh session. This is the handoff from the previous conversation:\n\n{s}", .{reply}) catch return;
    defer s.gpa.free(prompt);
    s.askAs("/compact", prompt);
}

/// `/new`: the next prompt opens a fresh session; what fx runs in the
/// background keeps running.
fn fresh(s: *Session) bool {
    const ag = s.agent orelse return false;
    if (ag.status == .working) return note(s, "wait for the agent to finish, then /new.");
    if (ag.native) |native| native.clearSession();
    return note(s, "a fresh conversation; the next prompt starts it.");
}

fn effort(s: *Session, arg: []const u8) bool {
    if (arg.len == 0) {
        var buf: [64]u8 = undefined;
        const now = readEffort(&buf, s.gpa, s.home);
        return say(s, "effort is {s}; /effort <level> changes it.", .{now});
    }
    setEffort(s.gpa, s.home, arg) catch |err| {
        return say(s, "could not set effort: {s}", .{@errorName(err)});
    };
    return say(s, "effort set to {s}; it applies from the next turn.", .{arg});
}

fn permission(s: *Session, arg: []const u8) bool {
    if (arg.len == 0) {
        const mode = readPermission(s.gpa, s.home, s.cwd()) orelse return say(s, "permission mode could not be read.", .{});
        defer s.gpa.free(mode);
        return say(s, "permission mode is {s}; /permissions <mode> changes it. The built-in agent runs auto inside nanoterm.", .{mode});
    }
    if (std.mem.eql(u8, arg, "reset")) {
        setPermission(s.gpa, s.home, "ask") catch {};
        return say(s, "permission mode reset to ask.", .{});
    }
    setPermission(s.gpa, s.home, arg) catch |err| {
        return say(s, "could not set permissions: {s}", .{@errorName(err)});
    };
    return say(s, "permission mode set to {s}; fx in the terminal follows it, and so do new fx sessions.", .{arg});
}

fn workspace(s: *Session, arg: []const u8) bool {
    if (arg.len == 0 or std.mem.eql(u8, arg, "list")) {
        const dirs = readDirs(s.gpa, s.home, s.cwd());
        defer {
            for (dirs) |dir| s.gpa.free(dir);
            s.gpa.free(dirs);
        }
        if (dirs.len == 0) return say(s, "no additional directories; /workspace add <path> saves one.", .{});
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(s.gpa);
        for (dirs) |dir| list.print(s.gpa, "{s}\n", .{dir}) catch break;
        return note(s, list.items);
    }
    var verb: []const u8 = "";
    var path: []const u8 = "";
    if (std.mem.indexOfScalar(u8, arg, ' ')) |space| {
        verb = arg[0..space];
        path = std.mem.trim(u8, arg[space + 1 ..], " \t");
    }
    if (std.mem.eql(u8, verb, "clear")) {
        changeDir(s.gpa, s.cwd(), .clear) catch return say(s, "could not change additional directories.", .{});
        return say(s, "additional directories cleared.", .{});
    }
    if (path.len == 0) return say(s, "/workspace add <path>, /workspace remove <path>, or /workspace clear.", .{});
    if (std.mem.eql(u8, verb, "add")) {
        changeDir(s.gpa, s.cwd(), .{ .add = path }) catch return say(s, "could not save {s}.", .{path});
        return say(s, "{s} saved; fx can work in it.", .{path});
    }
    if (std.mem.eql(u8, verb, "remove")) {
        changeDir(s.gpa, s.cwd(), .{ .remove = path }) catch return say(s, "could not remove {s}.", .{path});
        return say(s, "{s} removed.", .{path});
    }
    return say(s, "/workspace add <path>, /workspace remove <path>, or /workspace clear.", .{});
}

fn signInOut(s: *Session, command: []const u8, arg: []const u8) bool {
    if (arg.len == 0) return say(s, "/{s} codex, /{s} grok, or /{s} vercel — it runs in the terminal.", .{ command, command, command });
    if (!asciiEqlAny(arg, &.{ "codex", "grok", "vercel" })) return say(s, "providers: codex, grok, vercel.", .{});
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "fx {s} {s}", .{ command, arg }) catch return false;
    s.input.clear();
    s.run(line);
    return true;
}

/// Shows `text` (printed with `args`) as a turn of its own, done the moment
/// it is made.
fn say(s: *Session, comptime fmt: []const u8, args: anytype) bool {
    const text = std.fmt.allocPrint(s.gpa, fmt, args) catch return true;
    defer s.gpa.free(text);
    return note(s, text);
}

/// Shows `text` as a turn of its own, done the moment it is made.
fn note(s: *Session, text: []const u8) bool {
    if (s.agent) |ag| ag.note(text);
    return true;
}

// Helpers.

fn asciiEqlAny(text: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| if (std.ascii.eqlIgnoreCase(text, candidate)) return true;
    return false;
}

fn joinSettings(gpa: std.mem.Allocator, home: []const u8) ![]u8 {
    return std.fs.path.join(gpa, &.{ home, ".fx", "settings.json" });
}

fn readSetting(gpa: std.mem.Allocator, home: []const u8, key: []const u8) ?[]u8 {
    const settings = joinSettings(gpa, home) catch return null;
    defer gpa.free(settings);
    const io = std.Io.Threaded.global_single_threaded.io();
    const data = std.Io.Dir.cwd().readFileAlloc(io, settings, gpa, .limited(1024 * 1024)) catch return null;
    defer gpa.free(data);
    const parsed = std.json.parseFromSlice(std.json.Value, gpa, data, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const value = parsed.value.object.get(key) orelse return null;
    if (value != .string) return null;
    return gpa.dupe(u8, value.string) catch null;
}

test "fx dials: effort, permission mode, and directories round-trip through fx's store" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    engine.shared_io.setIo(io);
    const home = "/tmp/nanoterm-test-agent-fx";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    const root = try std.fs.path.join(gpa, &.{ home, "project" });
    defer gpa.free(root);
    try std.Io.Dir.cwd().createDirPath(io, root);

    // Effort: a named level, then back to auto.
    try setEffort(gpa, home, "high");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("high", readEffort(&buf, gpa, home));
    try setEffort(gpa, home, "auto");
    try std.testing.expectEqualStrings("default", readEffort(&buf, gpa, home));
    try std.testing.expectError(error.InvalidEffort, setEffort(gpa, home, "not a level!"));

    // Permission mode: full-access is fx's yolo, read back by its label.
    try setPermission(gpa, home, "full-access");
    const full = readPermission(gpa, home, root).?;
    defer gpa.free(full);
    try std.testing.expectEqualStrings("full-access", full);
    try setPermission(gpa, home, "ask");
    const asking = readPermission(gpa, home, root).?;
    defer gpa.free(asking);
    try std.testing.expectEqualStrings("ask", asking);

    // Directories: saved for one workspace root, not another; removed.
    // mutateWorkspaceDirectory reads HOME from the environment, so point it
    // at the test home for this stretch.
    var setenv: std.process.Environ.Map = .init(gpa);
    defer setenv.deinit();
    try setenv.put("HOME", home);
    engine.shared_io.setEnvironMap(&setenv);
    // The map lives on this stack frame only: clear fx's pointer when the
    // test returns, or a later test reads freed memory (io.zig's test reset).
    defer engine.shared_io.resetEnvironForTest();
    try changeDir(gpa, root, .{ .add = "/elsewhere" });
    const dirs = readDirs(gpa, home, root);
    defer {
        for (dirs) |dir| gpa.free(dir);
        gpa.free(dirs);
    }
    try std.testing.expectEqual(@as(usize, 1), dirs.len);
    try std.testing.expectEqualStrings("/elsewhere", dirs[0]);
    const other = try std.fs.path.join(gpa, &.{ home, "other" });
    defer gpa.free(other);
    const none = readDirs(gpa, home, other);
    defer {
        for (none) |dir| gpa.free(dir);
        gpa.free(none);
    }
    try std.testing.expectEqual(@as(usize, 0), none.len);
    try changeDir(gpa, root, .{ .remove = "/elsewhere" });
    const after = readDirs(gpa, home, root);
    defer {
        for (after) |dir| gpa.free(dir);
        gpa.free(after);
    }
    try std.testing.expectEqual(@as(usize, 0), after.len);
}

test "the slash menu is seeded with the built-in Agent's commands" {
    const gpa = std.testing.allocator;
    var config: agent_config.Config = .{ .gpa = gpa };
    defer config.deinit();
    seed(gpa, &config);
    try std.testing.expectEqual(specs.len, config.commands.items.len);
    try std.testing.expect(config.hasCommand("compact"));
    try std.testing.expect(config.hasCommand("permissions"));
    // Seeding twice replaces rather than doubling, as startNative may.
    seed(gpa, &config);
    try std.testing.expectEqual(specs.len, config.commands.items.len);
    for (config.commands.items) |command| {
        if (std.mem.eql(u8, command.name, "effort")) try std.testing.expectEqualStrings("[auto|minimal|low|medium|high]", command.hint);
    }
}

test "the built-in Agent's command words, and AGENTS.md found root-first" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try std.testing.expectEqual(@as(usize, 5), words("effort").?.len);
    try std.testing.expect(words("model") == null);

    const home = "/tmp/nanoterm-test-agent-fx-md";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/AGENTS.md", .data = "root" });
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/nested");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/nested/AGENTS.md", .data = "nested" });
    const found = instructions(gpa, home ++ "/nested");
    defer {
        for (found) |path| gpa.free(path);
        gpa.free(found);
    }
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expect(std.mem.endsWith(u8, found[0], "/AGENTS.md"));
    try std.testing.expect(std.mem.endsWith(u8, found[1], "/nested/AGENTS.md"));
}
