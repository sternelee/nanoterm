//! Configuration for the built-in Agent, used by Settings. Providers and MCP are written
//! through agent's locking, preserving stores; Skills use agent's managed installer.
const std = @import("std");
const engine = @import("fx");
const ui = @import("nanoui").ui;
const proc = @import("proc.zig");
const web = @import("web.zig");

const Allocator = std.mem.Allocator;

/// fx's own providers. They have no entry in the profile's "providers" map:
/// fx keeps their identity in its own enum and each one's preferred model in
/// the top-level "models" map, and lists what each offers through its own
/// catalog. The names are the ids fx parses.
pub const Builtin = struct { name: []const u8, label: []const u8, detail: []const u8 };

pub const builtins = [_]Builtin{
    .{ .name = "gateway", .label = "AI Gateway", .detail = "Vercel account or AI Gateway billing" },
    .{ .name = "codex", .label = "Codex", .detail = "ChatGPT subscription" },
    .{ .name = "grok", .label = "Grok", .detail = "Grok subscription" },
};

/// The built-in provider `name` names, or null when it is a configured one.
pub fn builtin(name: []const u8) ?Builtin {
    for (builtins) |entry| if (std.mem.eql(u8, entry.name, name)) return entry;
    return null;
}

/// What the panel and the picker call a provider: fx's own name for one of
/// its providers, the profile's id for a configured one.
pub fn label(name: []const u8) []const u8 {
    return if (builtin(name)) |entry| entry.label else name;
}

/// Why a provider's models could not be listed, and whether that is a failure
/// or a state to show plainly, such as not being signed in.
pub const ModelsNote = struct { text: []u8, failed: bool };

/// Notified when something the panel shows changed off its own frame.
pub const Changed = struct {
    ctx: *anyopaque,
    func: *const fn (*anyopaque) void,
};

pub const Provider = struct {
    name: []u8,
    base_url: []u8,
    model: []u8,
    auth_env: []u8,
    selected: bool,
    open: bool = false,
    /// One of fx's own providers (gateway, codex, grok): fx lists its models
    /// itself, and the profile holds only its preferred one.
    builtin: bool = false,
    /// Every model id the provider offers (its model_metadata keys, or the
    /// single preferred one when the definition carries no list).
    models: std.ArrayList([]u8) = .empty,
    /// Its models were asked for once this run.
    models_tried: bool = false,

    /// What the panel and the picker say about where the provider lives: a
    /// configured provider's endpoint, or fx's own words for a built-in one.
    pub fn detail(self: Provider) []const u8 {
        return if (builtin(self.name)) |entry| entry.detail else self.base_url;
    }

    fn deinit(self: *Provider, gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.base_url);
        gpa.free(self.model);
        gpa.free(self.auth_env);
        for (self.models.items) |model| gpa.free(model);
        self.models.deinit(gpa);
    }
};

pub const McpServer = struct {
    name: []u8,
    summary: []u8,
    open: bool = false,

    fn deinit(self: McpServer, gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.summary);
    }
};

pub const Skill = struct {
    name: []u8,
};

const PairConfig = struct {
    parsed: ?std.json.Parsed(std.json.Value) = null,
    items: []engine.mcp_config.Pair = &.{},

    fn deinit(self: *PairConfig, gpa: Allocator) void {
        if (self.items.len > 0) gpa.free(self.items);
        if (self.parsed) |*parsed| parsed.deinit();
    }
};

pub const Store = struct {
    gpa: Allocator,
    io: std.Io,
    home: []u8,
    settings_path: []u8,
    mcp_path: []u8,
    skills_dir: []u8,
    providers: std.ArrayList(Provider) = .empty,
    mcp_servers: std.ArrayList(McpServer) = .empty,
    skills: std.ArrayList(Skill) = .empty,
    selected_provider: []u8,
    status: []u8,
    failed: bool = false,

    /// Sign-in, as `fx status` reports it: the providers with working
    /// credentials, refreshed when the panel opens and a login or logout
    /// finishes.
    connected: std.ArrayList([]u8) = .empty,
    auth_label: []u8 = &.{},
    signed_checked: bool = false,
    checking: bool = false,
    check_process: proc.Process = undefined,
    check_buf: std.ArrayList(u8) = .empty,
    /// The AI Gateway's API key lives in the keychain, not in fx's status
    /// (which only lists the active and standby providers).
    gateway_keychain: bool = false,
    keychain_checking: bool = false,
    keychain_process: proc.Process = undefined,
    /// A provider's model list, fetched from its own endpoint.
    models_call: web.Call,
    models_for: ?[]u8 = null,
    /// The app's environment, for a provider's token variable.
    env: ?*const std.process.Environ.Map = null,
    /// Woken when a fetch or a status check lands, to repaint.
    changed: ?Changed = null,

    provider_name: ui.TextBuffer = .{},
    provider_url: ui.TextBuffer = .{},
    provider_model: ui.TextBuffer = .{},
    provider_auth_env: ui.TextBuffer = .{},
    mcp_name: ui.TextBuffer = .{},
    mcp_target: ui.TextBuffer = .{},
    mcp_args: ui.TextBuffer = .{},
    mcp_env: ui.TextBuffer = .{},
    mcp_headers: ui.TextBuffer = .{},
    skill_source: ui.TextBuffer = .{},
    skill_name: ui.TextBuffer = .{},

    provider_form_open: bool = false,
    mcp_form_open: bool = false,
    skill_form_open: bool = false,
    config_open: bool = false,

    // fx runtime state for the built-in Agent: its dials and directories,
    // loaded for a workspace when the panel opens and after each change.
    perm_mode: []u8 = &.{},
    effort: []u8 = &.{},
    dirs: std.ArrayList([]u8) = .empty,
    dirs_cwd: []u8 = &.{},
    agents_files: std.ArrayList([]u8) = .empty,
    runtime_loaded: bool = false,
    workspace_dir: ui.TextBuffer = .{},

    mcp_query_thread: ?std.Thread = null,
    mcp_query_cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mcp_query_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    mcp_query_server: []u8 = &.{},
    mcp_query_names: std.ArrayList([]u8) = .empty,
    mcp_query_note: []u8 = &.{},
    mcp_query_failed: bool = false,
    mcp_tools_server: []u8 = &.{},
    mcp_tools: std.ArrayList([]u8) = .empty,
    mcp_tools_note: []u8 = &.{},
    mcp_tools_failed: bool = false,
    /// fx's own model list for one built-in provider, asked for off the UI
    /// thread (fx resolves that provider's credentials and reads its catalog).
    /// Nothing is asked until something shows models: see `showModels`.
    models_wanted: bool = false,
    models_thread: ?std.Thread = null,
    models_cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    models_done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    models_query: []u8 = &.{},
    models_query_ids: std.ArrayList([]u8) = .empty,
    models_query_note: []u8 = &.{},
    /// That note is a failure, as opposed to a state such as not signed in.
    models_query_failed: bool = false,
    /// Why a provider's models could not be listed, by provider name: fx's
    /// words for its own providers, the endpoint's answer for a configured
    /// one. Kept by name, not on the row, so a reload that rebuilds the rows
    /// keeps what was learned about them.
    models_notes: std.StringHashMapUnmanaged(ModelsNote) = .empty,

    pub fn init(gpa: Allocator, io: std.Io, home: []const u8, env: ?*const std.process.Environ.Map) !Store {
        engine.shared_io.setIo(io);
        const settings_path = try std.fs.path.join(gpa, &.{ home, ".fx", "settings.json" });
        errdefer gpa.free(settings_path);
        const mcp_path = try std.fs.path.join(gpa, &.{ home, ".fx", "mcp.json" });
        errdefer gpa.free(mcp_path);
        const skills_dir = try std.fs.path.join(gpa, &.{ home, ".fx", "skills" });
        errdefer gpa.free(skills_dir);
        const owned_home = try gpa.dupe(u8, home);
        errdefer gpa.free(owned_home);
        const selected_provider = try gpa.dupe(u8, "gateway");
        errdefer gpa.free(selected_provider);
        const status = try gpa.dupe(u8, "");
        errdefer gpa.free(status);
        var self: Store = .{
            .gpa = gpa,
            .io = io,
            .home = owned_home,
            .settings_path = settings_path,
            .mcp_path = mcp_path,
            .skills_dir = skills_dir,
            .models_call = .{ .gpa = gpa },
            .env = env,
            .selected_provider = selected_provider,
            .status = status,
        };
        self.reload();
        return self;
    }

    pub fn deinit(self: *Store) void {
        self.mcp_query_cancel.store(true, .release);
        if (self.mcp_query_thread) |thread| thread.join();
        self.models_cancel.store(true, .release);
        if (self.models_thread) |thread| thread.join();
        if (self.checking) self.check_process.close();
        if (self.keychain_checking) self.keychain_process.close();
        self.checking = false;
        self.keychain_checking = false;
        self.check_buf.deinit(self.gpa);
        for (self.connected.items) |name| self.gpa.free(name);
        self.connected.deinit(self.gpa);
        if (self.auth_label.len > 0) self.gpa.free(self.auth_label);
        if (self.models_for) |name| self.gpa.free(name);
        self.models_call.deinit();
        self.clearMcpQuery();
        self.clearMcpTools();
        self.mcp_query_names.deinit(self.gpa);
        self.mcp_tools.deinit(self.gpa);
        self.clearModelsQuery();
        self.models_query_ids.deinit(self.gpa);
        self.clearModelsNotes();
        self.models_notes.deinit(self.gpa);
        self.clearLists();
        self.providers.deinit(self.gpa);
        self.mcp_servers.deinit(self.gpa);
        self.skills.deinit(self.gpa);
        self.gpa.free(self.home);
        self.gpa.free(self.settings_path);
        self.gpa.free(self.mcp_path);
        self.gpa.free(self.skills_dir);
        self.gpa.free(self.selected_provider);
        self.gpa.free(self.status);
        self.freeRuntime();
        self.dirs.deinit(self.gpa);
        self.agents_files.deinit(self.gpa);
        self.workspace_dir.deinit();
        self.provider_name.deinit();
        self.provider_url.deinit();
        self.provider_model.deinit();
        self.provider_auth_env.deinit();
        self.mcp_name.deinit();
        self.mcp_target.deinit();
        self.mcp_args.deinit();
        self.mcp_env.deinit();
        self.mcp_headers.deinit();
        self.skill_source.deinit();
        self.skill_name.deinit();
    }

    fn clearMcpQuery(self: *Store) void {
        if (self.mcp_query_server.len > 0) self.gpa.free(self.mcp_query_server);
        self.mcp_query_server = &.{};
        for (self.mcp_query_names.items) |name| self.gpa.free(name);
        self.mcp_query_names.clearRetainingCapacity();
        if (self.mcp_query_note.len > 0) self.gpa.free(self.mcp_query_note);
        self.mcp_query_note = &.{};
        self.mcp_query_failed = false;
    }

    fn clearMcpTools(self: *Store) void {
        if (self.mcp_tools_server.len > 0) self.gpa.free(self.mcp_tools_server);
        self.mcp_tools_server = &.{};
        for (self.mcp_tools.items) |name| self.gpa.free(name);
        self.mcp_tools.clearRetainingCapacity();
        if (self.mcp_tools_note.len > 0) self.gpa.free(self.mcp_tools_note);
        self.mcp_tools_note = &.{};
        self.mcp_tools_failed = false;
    }

    fn hasMcpServer(self: *const Store, name: []const u8) bool {
        for (self.mcp_servers.items) |server| {
            if (std.mem.eql(u8, server.name, name)) return true;
        }
        return false;
    }

    /// Starts listing `server`'s tools off the UI thread. The UI polls
    /// `mcpQueryDone` and then calls `finishMcpQuery` on its own thread.
    pub fn startMcpQuery(self: *Store, server: []const u8) void {
        if (self.mcp_query_thread != null) return;
        self.clearMcpQuery();
        self.mcp_query_server = self.gpa.dupe(u8, server) catch {
            self.fail(error.OutOfMemory);
            return;
        };
        self.mcp_query_cancel.store(false, .release);
        self.mcp_query_done.store(false, .release);
        const thread = std.Thread.spawn(.{}, mcpQueryWorker, .{self}) catch |err| {
            self.gpa.free(self.mcp_query_server);
            self.mcp_query_server = &.{};
            self.fail(err);
            return;
        };
        self.mcp_query_thread = thread;
    }

    fn mcpQueryWorker(self: *Store) void {
        const list = engine.listMcpTools(
            self.gpa,
            self.home,
            self.mcp_path,
            self.home,
            self.mcp_query_server,
            &self.mcp_query_cancel,
        ) catch |err| {
            if (self.gpa.dupe(u8, @errorName(err))) |text| {
                self.mcp_query_note = text;
            } else |_| {}
            self.mcp_query_failed = true;
            self.mcp_query_done.store(true, .release);
            return;
        };
        self.mcp_query_failed = list.note != null;
        self.mcp_query_names = std.ArrayList([]u8).fromOwnedSlice(list.names);
        self.mcp_query_note = list.note orelse &.{};
        self.mcp_query_done.store(true, .release);
    }

    pub fn mcpQueryDone(self: *Store) bool {
        return self.mcp_query_done.load(.acquire);
    }

    /// Joins the finished worker on the UI thread and moves its result into
    /// the panel the server's collapsible shows.
    pub fn finishMcpQuery(self: *Store) void {
        if (!self.mcpQueryDone()) return;
        if (self.mcp_query_thread) |thread| {
            thread.join();
            self.mcp_query_thread = null;
        }
        self.clearMcpTools();
        if (self.hasMcpServer(self.mcp_query_server)) {
            self.mcp_tools_server = self.mcp_query_server;
            std.mem.swap(std.ArrayList([]u8), &self.mcp_tools, &self.mcp_query_names);
            self.mcp_tools_note = self.mcp_query_note;
            self.mcp_tools_failed = self.mcp_query_failed;
            self.mcp_query_server = &.{};
            self.mcp_query_names = .empty;
            self.mcp_query_note = &.{};
            self.mcp_query_failed = false;
        } else {
            self.clearMcpQuery();
        }
        self.mcp_query_done.store(false, .release);
    }

    // What a listing said about each provider, by name: a provider whose
    // models cannot be read (a subscription that is not signed in, an
    // endpoint that is down) is a fact about that provider, so the panel and
    // the picker show it there instead of as one line for the whole list.

    /// Why `name`'s models could not be listed, when they could not.
    pub fn modelsNote(self: *const Store, name: []const u8) ?ModelsNote {
        return self.models_notes.get(name);
    }

    /// Records what a listing said about `name`, and forgets it when `text`
    /// is empty: it listed its models, or nothing has been asked of it yet.
    fn setModelsNote(self: *Store, name: []const u8, text: []const u8, failed: bool) void {
        self.clearModelsNote(name);
        if (text.len == 0) return;
        const key = self.gpa.dupe(u8, name) catch return;
        const said = self.gpa.dupe(u8, text) catch {
            self.gpa.free(key);
            return;
        };
        self.models_notes.put(self.gpa, key, .{ .text = said, .failed = failed }) catch {
            self.gpa.free(key);
            self.gpa.free(said);
        };
    }

    fn clearModelsNote(self: *Store, name: []const u8) void {
        const entry = self.models_notes.fetchRemove(name) orelse return;
        self.gpa.free(entry.key);
        self.gpa.free(entry.value.text);
    }

    fn clearModelsNotes(self: *Store) void {
        var entries = self.models_notes.iterator();
        while (entries.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.text);
        }
        self.models_notes.clearRetainingCapacity();
    }

    // fx's own model lists. The profile's "providers" map carries a custom
    // provider's models as its definition's metadata, but a built-in
    // provider's are only ever fx's answer, so they are read from fx itself.

    fn clearModelsQuery(self: *Store) void {
        if (self.models_query.len > 0) self.gpa.free(self.models_query);
        self.models_query = &.{};
        for (self.models_query_ids.items) |id| self.gpa.free(id);
        self.models_query_ids.clearRetainingCapacity();
        if (self.models_query_note.len > 0) self.gpa.free(self.models_query_note);
        self.models_query_note = &.{};
        self.models_query_failed = false;
    }

    /// Asks fx what one of its own providers offers, off the UI thread: fx
    /// resolves that provider's credential and reads its catalog there. The
    /// UI calls `finishModelsQuery` when `modelsQueryDone` says it landed.
    fn startModelsQuery(self: *Store, provider: Provider) void {
        if (self.models_thread != null) return;
        self.clearModelsQuery();
        self.models_query = self.gpa.dupe(u8, provider.name) catch {
            self.fail(error.OutOfMemory);
            return;
        };
        self.models_cancel.store(false, .release);
        self.models_done.store(false, .release);
        const thread = std.Thread.spawn(.{}, modelsQueryWorker, .{self}) catch |err| {
            self.gpa.free(self.models_query);
            self.models_query = &.{};
            self.fail(err);
            return;
        };
        self.models_thread = thread;
    }

    fn modelsQueryWorker(self: *Store) void {
        const id = engine.model_provider.parse(self.models_query) orelse {
            self.models_query_note = self.gpa.dupe(u8, "unknown provider") catch &.{};
            self.models_query_failed = true;
            self.models_done.store(true, .release);
            return;
        };
        const list = engine.listProviderModels(self.gpa, id, &self.models_cancel) catch |err| {
            self.models_query_note = self.gpa.dupe(u8, @errorName(err)) catch &.{};
            self.models_query_failed = true;
            self.models_done.store(true, .release);
            return;
        };
        // The list is the worker's now: it moves into the store below.
        // A provider that is not signed in is a state to show, not a failure.
        self.models_query_failed = list.note != null and !list.needs_sign_in;
        self.models_query_ids = std.ArrayList([]u8).fromOwnedSlice(list.ids);
        self.models_query_note = list.note orelse &.{};
        self.models_done.store(true, .release);
    }

    pub fn modelsQueryDone(self: *Store) bool {
        return self.models_done.load(.acquire);
    }

    /// Joins the finished worker on the UI thread and puts its list on the
    /// provider it was asked for, then asks the next one.
    pub fn finishModelsQuery(self: *Store) void {
        if (!self.modelsQueryDone()) return;
        if (self.models_thread) |thread| {
            thread.join();
            self.models_thread = null;
        }
        const name = self.models_query;
        var found = false;
        for (self.providers.items) |*provider| {
            if (!std.mem.eql(u8, provider.name, name)) continue;
            for (provider.models.items) |model| self.gpa.free(model);
            provider.models.clearRetainingCapacity();
            std.mem.swap(std.ArrayList([]u8), &provider.models, &self.models_query_ids);
            found = true;
            break;
        }
        if (found) self.setModelsNote(name, self.models_query_note, self.models_query_failed);
        self.clearModelsQuery();
        self.models_done.store(false, .release);
        self.fetchNextModels();
    }

    fn clearLists(self: *Store) void {
        for (self.providers.items) |*item| item.deinit(self.gpa);
        self.providers.clearRetainingCapacity();
        for (self.mcp_servers.items) |item| item.deinit(self.gpa);
        self.mcp_servers.clearRetainingCapacity();
        for (self.skills.items) |item| self.gpa.free(item.name);
        self.skills.clearRetainingCapacity();
    }

    fn replace(self: *Store, field: *[]u8, value: []const u8) !void {
        const copy = try self.gpa.dupe(u8, value);
        self.gpa.free(field.*);
        field.* = copy;
    }

    fn note(self: *Store, text: []const u8) void {
        self.replace(&self.status, text) catch {};
        self.failed = false;
    }

    // The built-in Agent's fx dials: permission mode, reasoning effort,
    // additional workspaces, and the AGENTS.md files it loads.

    fn freeRuntime(self: *Store) void {
        if (self.perm_mode.len > 0) self.gpa.free(self.perm_mode);
        self.perm_mode = &.{};
        if (self.effort.len > 0) self.gpa.free(self.effort);
        self.effort = &.{};
        for (self.dirs.items) |dir| self.gpa.free(dir);
        self.dirs.clearRetainingCapacity();
        for (self.agents_files.items) |path| self.gpa.free(path);
        self.agents_files.clearRetainingCapacity();
        if (self.dirs_cwd.len > 0) self.gpa.free(self.dirs_cwd);
        self.dirs_cwd = &.{};
        self.runtime_loaded = false;
    }

    /// Loads fx's runtime state for `cwd`, unless it is already loaded for
    /// that directory (the panel holds it between frames).
    pub fn ensureRuntime(self: *Store, cwd: []const u8) void {
        if (self.runtime_loaded and std.mem.eql(u8, self.dirs_cwd, cwd)) return;
        self.freeRuntime();
        if (self.dirs_cwd.len > 0) self.gpa.free(self.dirs_cwd);
        self.dirs_cwd = self.gpa.dupe(u8, cwd) catch &.{};
        const fx = @import("agent_fx.zig");
        self.perm_mode = fx.readPermission(self.gpa, self.home, cwd) orelse (self.gpa.dupe(u8, "auto") catch &.{});
        var buf: [64]u8 = undefined;
        self.effort = self.gpa.dupe(u8, fx.readEffort(&buf, self.gpa, self.home)) catch &.{};
        const dirs = fx.readDirs(self.gpa, self.home, cwd);
        if (self.dirs.appendSlice(self.gpa, dirs)) |_| {} else |_| {
            for (dirs) |dir| self.gpa.free(dir);
        }
        self.gpa.free(dirs);
        const files = fx.instructions(self.gpa, cwd);
        if (self.agents_files.appendSlice(self.gpa, files)) |_| {} else |_| {
            for (files) |path| self.gpa.free(path);
        }
        self.gpa.free(files);
        self.runtime_loaded = true;
    }

    /// Writes the permission mode ("ask", "auto", "full-access"), then
    /// reloads what the panel shows.
    pub fn setPermissionMode(self: *Store, cwd: []const u8, mode: []const u8) void {
        @import("agent_fx.zig").setPermission(self.gpa, self.home, mode) catch |err| return self.fail(err);
        self.note("Permission mode saved");
        self.runtime_loaded = false;
        self.ensureRuntime(cwd);
    }

    /// Writes the reasoning effort ("auto", or a level such as "high").
    pub fn setEffortLevel(self: *Store, cwd: []const u8, level: []const u8) void {
        @import("agent_fx.zig").setEffort(self.gpa, self.home, level) catch |err| return self.fail(err);
        self.note("Reasoning effort saved");
        self.runtime_loaded = false;
        self.ensureRuntime(cwd);
    }

    /// Saves an additional workspace directory for `cwd`.
    pub fn addWorkspaceDir(self: *Store, cwd: []const u8) void {
        const path = std.mem.trim(u8, self.workspace_dir.text(), " \t\r\n");
        if (path.len == 0) return self.fail(error.WorkspacePathRequired);
        @import("agent_fx.zig").changeDir(self.gpa, cwd, .{ .add = path }) catch |err| return self.fail(err);
        self.note("Directory saved");
        self.workspace_dir.clear();
        self.runtime_loaded = false;
        self.ensureRuntime(cwd);
    }

    /// Drops an additional workspace directory for `cwd`.
    pub fn removeWorkspaceDir(self: *Store, cwd: []const u8, path: []const u8) void {
        @import("agent_fx.zig").changeDir(self.gpa, cwd, .{ .remove = path }) catch |err| return self.fail(err);
        self.note("Directory removed");
        self.runtime_loaded = false;
        self.ensureRuntime(cwd);
    }

    /// Reloads everything after the home's settings changed elsewhere.
    pub fn refreshRuntime(self: *Store) void {
        self.runtime_loaded = false;
    }

    fn fail(self: *Store, err: anyerror) void {
        self.replace(&self.status, @errorName(err)) catch {};
        self.failed = true;
    }

    /// Asks fx what is signed in (`fx status --json`), off the frame; the
    /// panel and the model picker read `connected` when it lands.
    pub fn refreshSignIn(self: *Store, path_env: []const u8) void {
        if (self.checking) return;
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        // The keychain says whether the gateway's key is there even when fx
        // itself is not on this PATH.
        self.checkGatewayKeychain();
        const fx = proc.which(arena, self.io, path_env, "fx") orelse {
            self.signed_checked = true;
            return;
        };
        const env = [_][]const u8{
            std.fmt.allocPrint(arena, "PATH={s}", .{path_env}) catch return,
            std.fmt.allocPrint(arena, "HOME={s}", .{self.home}) catch return,
        };
        self.check_buf.clearRetainingCapacity();
        // Spawn into the field itself: the watch callbacks keep a pointer to
        // the Process, so it must not live on this stack frame.
        proc.spawnPipes(
            &self.check_process,
            proc.cStrings(arena, &.{ fx, "status", "--json" }) catch return,
            proc.cStrings(arena, env[0..]) catch return,
            null,
            true,
            .{ .ctx = self, .output = onCheckOutput, .exited = onCheckExit },
        ) catch {
            self.signed_checked = true;
            return;
        };
        self.checking = true;
        self.check_process.closeInput();
    }

    /// Reads whether the AI Gateway's key exists, without printing it.
    fn checkGatewayKeychain(self: *Store) void {
        if (self.keychain_checking) return;
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const env = [_][]const u8{std.fmt.allocPrint(arena, "HOME={s}", .{self.home}) catch return};
        proc.spawnPipes(
            &self.keychain_process,
            proc.cStrings(arena, &.{ "/usr/bin/security", "find-generic-password", "-s", "FX_AI_GATEWAY_API_KEY" }) catch return,
            proc.cStrings(arena, env[0..]) catch return,
            null,
            true,
            .{ .ctx = self, .output = onDiscard, .exited = onKeychainExit },
        ) catch return;
        self.keychain_checking = true;
        self.keychain_process.closeInput();
    }

    fn onDiscard(_: *anyopaque, _: []const u8) void {}

    fn onKeychainExit(ctx: *anyopaque, code: i32) void {
        const self: *Store = @ptrCast(@alignCast(ctx));
        self.keychain_process.close();
        self.keychain_checking = false;
        self.gateway_keychain = code == 0;
        if (self.changed) |c| c.func(c.ctx);
    }

    fn onCheckOutput(ctx: *anyopaque, bytes: []const u8) void {
        const self: *Store = @ptrCast(@alignCast(ctx));
        if (self.check_buf.items.len < 1 << 20) self.check_buf.appendSlice(self.gpa, bytes) catch {};
    }

    fn onCheckExit(ctx: *anyopaque, code: i32) void {
        const self: *Store = @ptrCast(@alignCast(ctx));
        if (self.checking) self.check_process.close();
        if (self.keychain_checking) self.keychain_process.close();
        self.checking = false;
        self.keychain_checking = false;
        self.applyStatus(code);
    }

    /// What fx's answer says about sign-in, into the store's own fields.
    pub fn applyStatus(self: *Store, code: i32) void {
        self.signed_checked = true;
        defer if (self.changed) |c| c.func(c.ctx);
        if (code != 0) return;
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, self.check_buf.items, .{}) catch return;
        defer parsed.deinit();
        if (parsed.value != .object) return;
        for (self.connected.items) |name| self.gpa.free(name);
        self.connected.clearRetainingCapacity();
        if (self.auth_label.len > 0) self.gpa.free(self.auth_label);
        self.auth_label = &.{};
        if (parsed.value.object.get("auth")) |v| if (v == .string) {
            self.auth_label = self.gpa.dupe(u8, v.string) catch &.{};
        };
        if (parsed.value.object.get("connected_providers")) |v| if (v == .array) {
            for (v.array.items, 0..) |entry, i| {
                if (i >= 32) break;
                if (entry != .string) continue;
                self.connected.append(self.gpa, self.gpa.dupe(u8, entry.string) catch continue) catch {};
            }
        };
        self.fetchNextModels();
    }

    /// Asks each provider without a list of its own for one, one at a time:
    /// fx itself for its own providers, the provider's endpoint for a
    /// configured one. Only once something is showing models.
    fn fetchNextModels(self: *Store) void {
        if (!self.models_wanted) return;
        if (self.models_call.running or self.models_thread != null) return;
        for (self.providers.items) |*provider| {
            // Only a provider without a list of its own is asked; a saved
            // list (fx's, with its context windows) stays as it is.
            if (provider.models_tried or provider.models.items.len > 0) continue;
            if (!provider.builtin and provider.base_url.len == 0) continue;
            provider.models_tried = true;
            // A note is about the attempt that produced it, not the last one.
            self.clearModelsNote(provider.name);
            return self.fetchModels(provider.*, self.providerToken(provider.*));
        }
    }

    /// What the picker, the panel and the phone call each frame: fx is asked
    /// for its providers' model lists once, and again after a sign-in change
    /// reset them (`Session.checkSignIn`). Tests never ask: this reaches the
    /// network and the profile's credentials, and only a real window shows
    /// models.
    pub fn showModels(self: *Store) void {
        if (@import("builtin").is_test) return;
        self.models_wanted = true;
        self.fetchNextModels();
    }

    /// The picker opening, before it settles into `showModels` each frame:
    /// providers that answered with nothing are asked again, since the state
    /// behind them may have changed — a sign-in finished, a server came back.
    /// One that listed its models is left alone, so a reopen costs no request.
    pub fn retryModels(self: *Store) void {
        for (self.providers.items) |*provider| {
            if (provider.models.items.len == 0) provider.models_tried = false;
        }
        self.showModels();
    }

    /// A provider's token, from the variable its definition names.
    fn providerToken(self: *Store, provider: Provider) ?[]const u8 {
        if (provider.auth_env.len == 0) return null;
        const env = self.env orelse return null;
        return env.get(provider.auth_env);
    }

    /// Whether `name` ("codex", "grok", "vercel") has working credentials.
    /// The gateway answers to every name fx reports it under ("vercel",
    /// "gateway", "vercel-ai-gateway").
    pub fn signedIn(self: *Store, name: []const u8) bool {
        if (std.mem.eql(u8, name, "gateway") and self.gateway_keychain) return true;
        for (self.connected.items) |entry| {
            if (std.mem.eql(u8, entry, name)) return true;
            if (std.mem.eql(u8, name, "gateway") and (std.mem.eql(u8, entry, "vercel") or std.mem.eql(u8, entry, "gateway") or std.mem.eql(u8, entry, "vercel-ai-gateway"))) return true;
            if (std.mem.eql(u8, name, "vercel") and (std.mem.eql(u8, entry, "gateway") or std.mem.eql(u8, entry, "vercel-ai-gateway"))) return true;
        }
        // The active provider names itself in fx's auth line.
        if (self.auth_label.len > 0) {
            if (std.mem.eql(u8, name, "codex") and std.mem.indexOf(u8, self.auth_label, "codex") != null) return true;
            if (std.mem.eql(u8, name, "grok") and std.mem.indexOf(u8, self.auth_label, "grok") != null) return true;
            if (std.mem.eql(u8, name, "gateway") and (std.mem.indexOf(u8, self.auth_label, "gateway") != null or std.mem.indexOf(u8, self.auth_label, "vercel") != null)) return true;
        }
        return false;
    }

    /// Fetches a provider's model list. fx's own providers (gateway, codex,
    /// grok) are listed by fx itself, off the UI thread; a configured
    /// provider is asked at its own endpoint (`GET <base_url>/models`, the
    /// OpenAI-compatible shape Ollama and the rest speak), and its answer is
    /// saved as the provider's models.
    pub fn fetchModels(self: *Store, provider: Provider, bearer: ?[]const u8) void {
        if (provider.builtin) return self.startModelsQuery(provider);
        if (self.models_call.running) return;
        var url: [1024]u8 = undefined;
        const base = std.mem.trimEnd(u8, provider.base_url, "/");
        const full = std.fmt.bufPrint(&url, "{s}/models", .{base}) catch return;
        if (self.models_for) |old| self.gpa.free(old);
        self.models_for = self.gpa.dupe(u8, provider.name) catch return;
        self.models_call.start(.{ .url = full, .bearer = bearer, .max_seconds = 10, .max_bytes = 1 << 20 }, .{ .ctx = self, .func = onModels }) catch |err| {
            self.gpa.free(self.models_for.?);
            self.models_for = null;
            return self.fail(err);
        };
    }

    fn onModels(ctx: *anyopaque, code: i32, body: []const u8) void {
        const self: *Store = @ptrCast(@alignCast(ctx));
        const name = self.models_for orelse return;
        defer {
            self.gpa.free(name);
            self.models_for = null;
        }
        defer if (self.changed) |c| c.func(c.ctx);
        if (code != 0) {
            self.setModelsNote(name, "Could not reach the provider's /models", true);
            self.note("Could not reach the provider's /models");
            return self.fetchNextModels();
        }
        var parsed = std.json.parseFromSlice(std.json.Value, self.gpa, body, .{}) catch {
            self.setModelsNote(name, "Its answer could not be read", true);
            return self.fetchNextModels();
        };
        defer parsed.deinit();
        const root = parsed.value;
        const list = if (root == .object) (root.object.get("data") orelse root.object.get("models") orelse root) else root;
        if (list != .array) {
            self.setModelsNote(name, "Its answer listed no models", true);
            return self.fetchNextModels();
        }
        var ids: std.ArrayList([]const u8) = .empty;
        defer @constCast(&ids).deinit(self.gpa);
        for (list.array.items) |entry| {
            if (entry != .object) continue;
            const id = if (entry.object.get("id")) |v| (if (v == .string) v.string else null) else if (entry.object.get("name")) |v| (if (v == .string) v.string else null) else null;
            if (id == null or id.?.len == 0 or ids.items.len >= 256) continue;
            ids.append(self.gpa, id.?) catch {};
        }
        if (ids.items.len == 0) {
            self.setModelsNote(name, "Its answer listed no models", true);
            return self.fetchNextModels();
        }
        self.writeProviderModels(name, ids.items) catch |err| return self.fail(err);
        self.setModelsNote(name, "", false);
        self.reload();
        var line: [80]u8 = undefined;
        const said = std.fmt.bufPrint(&line, "{d} models from {s}", .{ ids.items.len, name }) catch return;
        self.note(said);
        self.fetchNextModels();
    }

    pub fn reload(self: *Store) void {
        self.clearLists();
        self.loadProviders() catch |err| self.fail(err);
        self.loadMcp() catch |err| self.fail(err);
        self.loadSkills() catch |err| self.fail(err);
    }

    fn loadProviders(self: *Store) !void {
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, self.settings_path, self.gpa, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => try self.gpa.dupe(u8, "{}"),
            else => return err,
        };
        defer self.gpa.free(data);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, data, .{ .duplicate_field_behavior = .@"error" });
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSettingsShape;
        const root = parsed.value.object;
        if (root.get("provider")) |value| {
            const name = switch (value) {
                .string => |text| text,
                .object => |object| if (object.get("name")) |name| if (name == .string) name.string else "gateway" else "gateway",
                else => "gateway",
            };
            try self.replace(&self.selected_provider, name);
        }
        var models: ?std.json.ObjectMap = null;
        if (root.get("models")) |value| if (value == .object) {
            models = value.object;
        };
        // fx's own providers first. They are not in the "providers" map (fx
        // knows them by its own ids), and only their preferred model is in
        // the profile; the list of what they offer comes from fx.
        for (builtins) |entry| {
            const model = if (models) |map| if (map.get(entry.name)) |value| if (value == .string) value.string else "" else "" else "";
            var provider = Provider{
                .name = try self.gpa.dupe(u8, entry.name),
                .base_url = try self.gpa.dupe(u8, ""),
                .model = try self.gpa.dupe(u8, model),
                .auth_env = try self.gpa.dupe(u8, ""),
                .selected = std.mem.eql(u8, self.selected_provider, entry.name),
                .builtin = true,
            };
            errdefer provider.deinit(self.gpa);
            try self.providers.append(self.gpa, provider);
        }
        const providers = root.get("providers") orelse return;
        if (providers != .object) return error.InvalidSettingsShape;
        var iterator = providers.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* != .object) continue;
            const definition = entry.value_ptr.object;
            const url = if (definition.get("base_url")) |value| if (value == .string) value.string else "" else "";
            var auth_env: []const u8 = "";
            if (definition.get("auth")) |value| if (value == .object) {
                if (value.object.get("env")) |env| if (env == .string) {
                    auth_env = env.string;
                };
            };
            const model = if (models) |map| if (map.get(entry.key_ptr.*)) |value| if (value == .string) value.string else "" else "" else "";
            var provider = Provider{
                .name = try self.gpa.dupe(u8, entry.key_ptr.*),
                .base_url = try self.gpa.dupe(u8, url),
                .model = try self.gpa.dupe(u8, model),
                .auth_env = try self.gpa.dupe(u8, auth_env),
                .selected = std.mem.eql(u8, self.selected_provider, entry.key_ptr.*),
            };
            errdefer provider.deinit(self.gpa);
            if (definition.get("model_metadata")) |value| if (value == .object) {
                var metadata = value.object.iterator();
                while (metadata.next()) |meta_entry| {
                    if (meta_entry.value_ptr.* != .object) continue;
                    provider.models.append(self.gpa, self.gpa.dupe(u8, meta_entry.key_ptr.*) catch continue) catch continue;
                }
            };
            // No list of its own: the one model it prefers is what it offers.
            if (provider.models.items.len == 0 and provider.model.len > 0) {
                provider.models.append(self.gpa, self.gpa.dupe(u8, provider.model) catch "") catch {};
            }
            try self.providers.append(self.gpa, provider);
        }
    }

    fn loadMcp(self: *Store) !void {
        const maybe = try engine.mcp_config.read(self.gpa, self.mcp_path);
        const data = maybe orelse return;
        defer self.gpa.free(data);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, data, .{ .duplicate_field_behavior = .@"error" });
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidMcpShape;
        const root = parsed.value.object;
        const servers_value = root.get("mcp") orelse root.get("mcpServers") orelse return;
        if (servers_value != .object) return error.InvalidMcpShape;
        var iterator = servers_value.object.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* != .object) continue;
            const object = entry.value_ptr.object;
            var summary: std.ArrayList(u8) = .empty;
            defer summary.deinit(self.gpa);
            if (object.get("url")) |value| {
                try summary.appendSlice(self.gpa, if (value == .string) value.string else "HTTP");
            } else {
                if (object.get("command")) |value| try summary.appendSlice(self.gpa, if (value == .string) value.string else "stdio");
                if (object.get("args")) |value| if (value == .array) for (value.array.items) |arg| {
                    if (arg != .string) continue;
                    try summary.append(self.gpa, ' ');
                    try summary.appendSlice(self.gpa, arg.string);
                };
            }
            const name = try self.gpa.dupe(u8, entry.key_ptr.*);
            errdefer self.gpa.free(name);
            const owned_summary = try summary.toOwnedSlice(self.gpa);
            errdefer self.gpa.free(owned_summary);
            try self.mcp_servers.append(self.gpa, .{ .name = name, .summary = owned_summary });
        }
    }

    fn loadSkills(self: *Store) !void {
        var dir = std.Io.Dir.openDirAbsolute(self.io, self.skills_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(self.io);
        var iterator = dir.iterate();
        while (try iterator.next(self.io)) |entry| {
            if (entry.kind != .directory or std.mem.startsWith(u8, entry.name, ".")) continue;
            try self.skills.append(self.gpa, .{ .name = try self.gpa.dupe(u8, entry.name) });
        }
        std.mem.sort(Skill, self.skills.items, {}, struct {
            fn less(_: void, a: Skill, b: Skill) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.less);
    }

    pub fn currentModel(self: *const Store) []const u8 {
        for (self.providers.items) |provider| {
            if (provider.selected and provider.model.len > 0) return provider.model;
        }
        return "";
    }

    pub fn saveProvider(self: *Store) void {
        const name = std.mem.trim(u8, self.provider_name.text(), " \t\r\n");
        const url = std.mem.trim(u8, self.provider_url.text(), " \t\r\n");
        const env = std.mem.trim(u8, self.provider_auth_env.text(), " \t\r\n");
        // Models, comma-separated; the first is the preferred one.
        var ids: [32][]const u8 = undefined;
        var count: usize = 0;
        var tokens = std.mem.tokenizeScalar(u8, self.provider_model.text(), ',');
        while (tokens.next()) |token| {
            const id = std.mem.trim(u8, token, " \t\r\n");
            if (id.len == 0 or count == ids.len) continue;
            var seen = false;
            for (ids[0..count]) |other| if (std.mem.eql(u8, other, id)) {
                seen = true;
            };
            if (!seen) {
                ids[count] = id;
                count += 1;
            }
        }
        if (name.len == 0 or url.len == 0 or count == 0) return self.fail(error.ProviderFieldsRequired);
        const id = engine.model_provider.parse(name) orelse return self.fail(error.InvalidProviderId);
        if (id != .configured) return self.fail(error.ReservedProviderId);
        var outcome = engine.provider_settings.setUserPreferencesAtHome(self.gpa, self.home, .{
            .provider = id,
            .provider_definition = .{ .upsert = .{
                .id = name,
                .base_url = url,
                .bearer_env = if (env.len > 0) env else null,
            } },
            .model_preference = .{ .provider = id, .model = ids[0] },
        }) catch |err| return self.fail(err);
        defer outcome.deinit(self.gpa);
        self.writeProviderModels(name, ids[0..count]) catch |err| return self.fail(err);
        self.note("Provider saved and selected");
        self.provider_form_open = false;
        self.provider_name.clear();
        self.provider_url.clear();
        self.provider_model.clear();
        self.provider_auth_env.clear();
        self.reload();
    }

    /// Writes a provider's models as its definition's model_metadata, the
    /// shape fx's own store keeps. The engine's patch carries only the URL
    /// and its auth, so this reads the settings back, adds the list, and
    /// writes through a temp file and rename, as fx commits do.
    fn writeProviderModels(self: *Store, name: []const u8, models: []const []const u8) !void {
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, self.settings_path, self.gpa, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => try self.gpa.dupe(u8, "{}"),
            else => return err,
        };
        defer self.gpa.free(data);
        var parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, data, .{ .duplicate_field_behavior = .@"error" });
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidSettingsShape;
        // The parsed tree lives in parseFromSlice's own arena; grow it there,
        // or freeing the tree would free what it never allocated.
        const arena = parsed.arena.allocator();
        var root = &parsed.value.object;
        var providers = if (root.getPtr("providers")) |value| blk: {
            if (value.* != .object) return error.InvalidSettingsShape;
            break :blk &value.object;
        } else blk: {
            try root.put(arena, "providers", .{ .object = .empty });
            break :blk &root.getPtr("providers").?.object;
        };
        const definition = providers.getPtr(name) orelse return error.ProviderNotFound;
        if (definition.* != .object) return error.InvalidSettingsShape;
        var metadata: std.json.ObjectMap = .empty;
        // The map borrows the caller's model strings; it lives only until
        // the settings are written back below. A model fx already described
        // keeps its metadata (its context window, its flags).
        const existing_metadata = if (definition.object.get("model_metadata")) |v| (if (v == .object) v.object else null) else null;
        for (models) |model| {
            const known = if (existing_metadata) |m| (if (m.get(model)) |v| (if (v == .object) v else null) else null) else null;
            try metadata.put(arena, model, known orelse .{ .object = .empty });
        }
        try definition.object.put(arena, "model_metadata", .{ .object = metadata });
        const written = try std.json.Stringify.valueAlloc(self.gpa, parsed.value, .{});
        defer self.gpa.free(written);
        var tmp: [512]u8 = undefined;
        const tmp_path = try std.fmt.bufPrint(&tmp, "{s}.tmp", .{self.settings_path});
        try std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = tmp_path, .data = written });
        try std.Io.Dir.renameAbsolute(tmp_path, self.settings_path, self.io);
    }

    /// Chooses `provider` for the built-in Agent, with the model it prefers:
    /// the one the profile saved, or the first it offers when nothing is
    /// saved yet (fx has no default for Codex or Grok).
    pub fn selectProvider(self: *Store, provider: Provider) void {
        const model = if (provider.model.len > 0)
            provider.model
        else if (provider.models.items.len > 0)
            provider.models.items[0]
        else
            "";
        self.chooseProviderModel(provider.name, model);
    }

    /// Chooses `name` as the provider and `model` as the model it prefers, as
    /// fx keeps them: fx's own providers have no "providers" entry, only the
    /// top-level "provider" and "models.<name>".
    pub fn chooseProviderModel(self: *Store, name: []const u8, model: []const u8) void {
        const id = engine.model_provider.parse(name) orelse return self.fail(error.InvalidProviderId);
        if (self.findProvider(name) == null) return self.fail(error.ProviderNotFound);
        var outcome = engine.provider_settings.setUserPreferencesAtHome(self.gpa, self.home, .{
            .provider = id,
            .model_preference = if (model.len > 0) .{ .provider = id, .model = model } else null,
        }) catch |err| return self.fail(err);
        defer outcome.deinit(self.gpa);
        self.note("Provider selected");
        self.reload();
    }

    pub fn selectProviderByName(self: *Store, name: []const u8) void {
        const provider = self.findProvider(name) orelse return self.fail(error.ProviderNotFound);
        self.selectProvider(provider.*);
    }

    fn findProvider(self: *const Store, name: []const u8) ?*const Provider {
        for (self.providers.items) |*provider| {
            if (std.mem.eql(u8, provider.name, name)) return provider;
        }
        return null;
    }

    pub fn removeProvider(self: *Store, name: []const u8) void {
        // fx's own providers are always there: there is nothing to remove.
        if (builtin(name) != null) return self.fail(error.ReservedProviderId);
        var outcome = engine.provider_settings.setUserPreferencesAtHome(self.gpa, self.home, .{
            .provider_definition = .{ .remove = name },
        }) catch |err| return self.fail(err);
        defer outcome.deinit(self.gpa);
        if (std.mem.eql(u8, self.selected_provider, name)) {
            var fallback = engine.provider_settings.setUserPreferencesAtHome(self.gpa, self.home, .{ .provider = .gateway }) catch |err| return self.fail(err);
            defer fallback.deinit(self.gpa);
        }
        self.note("Provider removed");
        self.reload();
    }

    fn parsePairs(self: *Store, text: []const u8) !PairConfig {
        var result: PairConfig = .{};
        errdefer result.deinit(self.gpa);
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return result;
        result.parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, trimmed, .{ .duplicate_field_behavior = .@"error" });
        if (result.parsed.?.value != .object) return error.ExpectedJsonObject;
        const object = result.parsed.?.value.object;
        if (object.count() == 0) return result;
        result.items = try self.gpa.alloc(engine.mcp_config.Pair, object.count());
        var iterator = object.iterator();
        var i: usize = 0;
        while (iterator.next()) |entry| : (i += 1) {
            if (entry.value_ptr.* != .string) return error.ExpectedStringValue;
            result.items[i] = .{ .key = entry.key_ptr.*, .value = entry.value_ptr.string };
        }
        return result;
    }

    pub fn addMcp(self: *Store) void {
        const name = std.mem.trim(u8, self.mcp_name.text(), " \t\r\n");
        const target = std.mem.trim(u8, self.mcp_target.text(), " \t\r\n");
        if (name.len == 0 or target.len == 0) return self.fail(error.McpFieldsRequired);
        var args: [32][]const u8 = undefined;
        var count: usize = 0;
        var tokens = std.mem.tokenizeAny(u8, self.mcp_args.text(), " \t\r\n");
        while (tokens.next()) |token| {
            if (count == args.len) return self.fail(error.TooManyArguments);
            args[count] = token;
            count += 1;
        }
        var env = self.parsePairs(self.mcp_env.text()) catch |err| return self.fail(err);
        defer env.deinit(self.gpa);
        var headers = self.parsePairs(self.mcp_headers.text()) catch |err| return self.fail(err);
        defer headers.deinit(self.gpa);
        const entry: engine.mcp_config.Entry = if (std.mem.startsWith(u8, target, "http://") or std.mem.startsWith(u8, target, "https://"))
            .{ .http = .{ .url = target, .headers = headers.items } }
        else
            .{ .stdio = .{ .command = target, .args = args[0..count], .env = env.items } };
        const updated = engine.mcp_config.update(self.gpa, self.mcp_path, .profile, self.mcp_path, .{ .add = .{ .name = name, .entry = entry } }) catch |err| return self.fail(err);
        defer switch (updated) {
            .removed => |url| if (url) |value| self.gpa.free(value),
            else => {},
        };
        self.note("MCP server added");
        self.mcp_form_open = false;
        self.mcp_name.clear();
        self.mcp_target.clear();
        self.mcp_args.clear();
        self.mcp_env.clear();
        self.mcp_headers.clear();
        self.reload();
    }

    pub fn removeMcp(self: *Store, name: []const u8) void {
        const updated = engine.mcp_config.update(self.gpa, self.mcp_path, .profile, self.mcp_path, .{ .remove = name }) catch |err| return self.fail(err);
        defer switch (updated) {
            .removed => |url| if (url) |value| self.gpa.free(value),
            else => {},
        };
        self.note("MCP server removed");
        self.reload();
    }

    pub fn installSkill(self: *Store) void {
        const source = std.mem.trim(u8, self.skill_source.text(), " \t\r\n");
        if (source.len == 0) return self.fail(error.SkillSourceRequired);
        var result = engine.skills.installFromSource(self.gpa, self.skills_dir, source, null) catch |err| return self.fail(err);
        defer result.deinit(self.gpa);
        self.note("Skill installed");
        self.skill_form_open = false;
        self.skill_source.clear();
        self.reload();
    }

    pub fn createSkill(self: *Store) void {
        const name = std.mem.trim(u8, self.skill_name.text(), " \t\r\n");
        if (name.len == 0) return self.fail(error.SkillNameRequired);
        const path = engine.skills.createSkillTemplate(self.gpa, self.skills_dir, name) catch |err| return self.fail(err);
        self.gpa.free(path);
        self.note("Skill created");
        self.skill_form_open = false;
        self.skill_name.clear();
        self.reload();
    }

    pub fn removeSkill(self: *Store, name: []const u8) void {
        engine.skills.removeSkill(self.skills_dir, name) catch |err| return self.fail(err);
        self.note("Skill removed");
        self.reload();
    }
};

test "fx's own providers are offered, and choosing one writes fx's preference" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-builtin-providers";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/.fx");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/.fx/settings.json", .data =
        \\{"provider":"magpie","models":{"codex":"gpt-6.1-sol","magpie":"auto/glm-5.3"},"providers":{"magpie":{"protocol":"openai-chat-completions","base_url":"http://127.0.0.1:3425/v1","auth":{"type":"none"}}}}
    });

    var store = try Store.init(gpa, io, home, null);
    defer store.deinit();
    // fx's own three come first, with the model the profile saved for them.
    try std.testing.expectEqual(@as(usize, 4), store.providers.items.len);
    try std.testing.expectEqualStrings("gateway", store.providers.items[0].name);
    try std.testing.expectEqualStrings("codex", store.providers.items[1].name);
    try std.testing.expectEqualStrings("grok", store.providers.items[2].name);
    try std.testing.expectEqualStrings("magpie", store.providers.items[3].name);
    try std.testing.expect(store.providers.items[0].builtin);
    try std.testing.expect(store.providers.items[1].builtin);
    try std.testing.expect(store.providers.items[2].builtin);
    try std.testing.expect(!store.providers.items[3].builtin);
    // Only the ones the profile named a model for have one.
    try std.testing.expectEqualStrings("", store.providers.items[0].model);
    try std.testing.expectEqualStrings("gpt-6.1-sol", store.providers.items[1].model);
    // A configured provider shows its endpoint; a built-in one says what fx
    // says about it.
    try std.testing.expectEqualStrings("http://127.0.0.1:3425/v1", store.providers.items[3].detail());
    try std.testing.expectEqualStrings("ChatGPT subscription", store.providers.items[1].detail());
    try std.testing.expectEqualStrings("magpie", store.selected_provider);

    // Choosing Codex writes fx's own preference: there is no "providers"
    // entry to write, only the top-level provider and models.codex.
    store.chooseProviderModel("codex", "gpt-6.1-sol");
    try std.testing.expect(!store.failed);
    try std.testing.expectEqualStrings("codex", store.selected_provider);
    try std.testing.expectEqualStrings("gpt-6.1-sol", store.currentModel());
    try std.testing.expect(store.providers.items[1].selected);
    // A model chosen for it replaces the saved one, as the picker's row does.
    store.chooseProviderModel("codex", "gpt-5.6-luna");
    try std.testing.expect(!store.failed);
    try std.testing.expectEqualStrings("gpt-5.6-luna", store.currentModel());
    {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, home ++ "/.fx/settings.json", gpa, .limited(64 * 1024));
        defer gpa.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"codex\":\"gpt-5.6-luna\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "magpie") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "\"provider\":\"codex\"") != null);
    }
    // fx's own providers cannot be removed, and an unknown name is refused.
    store.removeProvider("codex");
    try std.testing.expect(store.failed);
    try std.testing.expectEqual(@as(usize, 4), store.providers.items.len);
    store.selectProviderByName("nowhere");
    try std.testing.expect(store.failed);
    // Nothing asks fx for a model list until something shows models.
    try std.testing.expect(store.models_thread == null);
    try std.testing.expect(!store.models_wanted);
}

test "fx's own providers are offered even with no profile settings" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-builtin-providers-empty";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/.fx");

    var store = try Store.init(gpa, io, home, null);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 3), store.providers.items.len);
    try std.testing.expectEqualStrings("gateway", store.providers.items[0].name);
    try std.testing.expectEqualStrings("gateway", store.selected_provider);
    try std.testing.expectEqualStrings("", store.currentModel());
    try std.testing.expect(store.providers.items[0].selected);
}

test "sign-in state is read from fx status, under fx's own names" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-signin";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/.fx");
    var store = try Store.init(gpa, io, home, null);
    defer store.deinit();
    try std.testing.expect(!store.signedIn("codex"));

    store.check_buf.appendSlice(gpa, "{\"auth\":\"configured provider\",\"connected_providers\":[\"magpie\",\"vercel\"]}") catch {};
    store.applyStatus(0);
    try std.testing.expect(store.signed_checked);
    try std.testing.expect(store.signedIn("magpie"));
    // The gateway answers to either name fx gives it.
    try std.testing.expect(store.signedIn("gateway"));
    try std.testing.expect(store.signedIn("vercel"));
    try std.testing.expect(!store.signedIn("codex"));
    try std.testing.expectEqualStrings("configured provider", store.auth_label);

    // fx reports a signed-in gateway as "vercel-ai-gateway", as `fx login`
    // signs into it: the row answers to that name too.
    store.check_buf.clearRetainingCapacity();
    store.check_buf.appendSlice(gpa, "{\"auth\":\"fx login\",\"connected_providers\":[\"vercel-ai-gateway\"]}") catch {};
    store.applyStatus(0);
    try std.testing.expect(store.signedIn("gateway"));
    try std.testing.expect(store.signedIn("vercel"));
    try std.testing.expect(!store.signedIn("codex"));

    // A fresh report replaces the old one.
    store.check_buf.clearRetainingCapacity();
    store.check_buf.appendSlice(gpa, "{\"auth\":\"codex\",\"connected_providers\":[\"codex\"]}") catch {};
    store.applyStatus(0);
    try std.testing.expect(store.signedIn("codex"));
    try std.testing.expect(!store.signedIn("vercel"));
}

test "agent settings manage providers, MCP servers, and Skills in an isolated home" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-agent-config";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/.fx");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/.fx/settings.json", .data = "{\"future\":{\"keep\":true}}" });

    var store = try Store.init(gpa, io, home, null);
    defer store.deinit();
    try std.testing.expectEqualStrings("", store.currentModel());

    store.provider_name.set("local");
    store.provider_url.set("http://127.0.0.1:11434/v1/");
    store.provider_model.set("qwen3-coder");
    store.saveProvider();
    try std.testing.expect(!store.failed);
    try std.testing.expectEqualStrings("local", store.selected_provider);
    // fx's own three, then the one just saved.
    try std.testing.expectEqual(@as(usize, 4), store.providers.items.len);
    try std.testing.expectEqualStrings("qwen3-coder", store.findProvider("local").?.model);
    // Saving the same id again updates it, rather than adding a duplicate.
    store.provider_name.set("local");
    store.provider_url.set("http://127.0.0.1:11435/v1/");
    store.provider_model.set("qwen3-coder-plus");
    store.saveProvider();
    try std.testing.expect(!store.failed);
    try std.testing.expectEqual(@as(usize, 4), store.providers.items.len);
    try std.testing.expectEqualStrings("http://127.0.0.1:11435/v1/", store.findProvider("local").?.base_url);
    try std.testing.expectEqualStrings("qwen3-coder-plus", store.findProvider("local").?.model);
    store.selectProviderByName("gateway");
    try std.testing.expectEqualStrings("", store.currentModel());
    store.selectProviderByName("local");
    try std.testing.expectEqualStrings("qwen3-coder-plus", store.currentModel());

    // A comma-separated list saves every model; the first is preferred.
    store.provider_name.set("local");
    store.provider_url.set("http://127.0.0.1:11435/v1/");
    store.provider_model.set("qwen3-coder, qwen3-max, llama-x");
    store.saveProvider();
    try std.testing.expect(!store.failed);
    try std.testing.expectEqual(@as(usize, 3), store.findProvider("local").?.models.items.len);
    try std.testing.expectEqualStrings("qwen3-coder", store.findProvider("local").?.model);
    try std.testing.expectEqualStrings("qwen3-max", store.findProvider("local").?.models.items[1]);
    {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, home ++ "/.fx/settings.json", gpa, .limited(64 * 1024));
        defer gpa.free(bytes);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "model_metadata") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "llama-x") != null);
    }
    // The old single-model save survives too: one id, one entry.
    store.provider_name.set("local");
    store.provider_url.set("http://127.0.0.1:11435/v1/");
    store.provider_model.set(" qwen3-coder-plus ,");
    store.saveProvider();
    try std.testing.expect(!store.failed);
    try std.testing.expectEqual(@as(usize, 1), store.findProvider("local").?.models.items.len);
    try std.testing.expectEqualStrings("qwen3-coder-plus", store.currentModel());

    store.mcp_name.set("local-tools");
    store.mcp_target.set("/usr/local/bin/example-mcp");
    store.mcp_args.set("--stdio --verbose");
    store.mcp_env.set("{\"MCP_TOKEN\":\"stdio-secret\"}");
    store.addMcp();
    try std.testing.expect(!store.failed);
    try std.testing.expectEqual(@as(usize, 1), store.mcp_servers.items.len);
    try std.testing.expect(std.mem.indexOf(u8, store.mcp_servers.items[0].summary, "--stdio") != null);
    store.mcp_name.set("remote-tools");
    store.mcp_target.set("https://example.com/mcp");
    store.mcp_headers.set("{\"Authorization\":\"Bearer secret\"}");
    store.addMcp();
    try std.testing.expect(!store.failed);
    try std.testing.expectEqual(@as(usize, 2), store.mcp_servers.items.len);
    const mcp_bytes = try std.Io.Dir.cwd().readFileAlloc(io, home ++ "/.fx/mcp.json", gpa, .limited(64 * 1024));
    defer gpa.free(mcp_bytes);
    try std.testing.expect(std.mem.indexOf(u8, mcp_bytes, "\"MCP_TOKEN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mcp_bytes, "stdio-secret") != null);
    try std.testing.expect(std.mem.indexOf(u8, mcp_bytes, "\"Authorization\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, mcp_bytes, "Bearer secret") != null);

    store.skill_name.set("review-helper");
    store.createSkill();
    try std.testing.expect(!store.failed);
    try std.testing.expectEqual(@as(usize, 1), store.skills.items.len);
    try std.testing.expectEqualStrings("review-helper", store.skills.items[0].name);

    store.removeMcp("local-tools");
    store.removeMcp("remote-tools");
    store.removeSkill("review-helper");
    store.removeProvider("local");
    try std.testing.expect(!store.failed);
    try std.testing.expectEqual(@as(usize, 0), store.mcp_servers.items.len);
    try std.testing.expectEqual(@as(usize, 0), store.skills.items.len);
    // fx's own three are still there; the configured one is gone.
    try std.testing.expectEqual(@as(usize, 3), store.providers.items.len);
    try std.testing.expect(store.findProvider("local") == null);
    try std.testing.expectEqualStrings("gateway", store.selected_provider);
    try std.testing.expectEqualStrings("", store.currentModel());

    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, home ++ "/.fx/settings.json", gpa, .limited(64 * 1024));
    defer gpa.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"future\"") != null);
}

test "MCP tool listing starts a server and returns its tools" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    engine.shared_io.setIo(io);
    const root = "/tmp/nanoterm-agent-mcp-tools";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    const server = try std.fs.path.join(gpa, &.{ root, "server.sh" });
    defer gpa.free(server);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = server, .flags = .{ .permissions = .executable_file }, .data =
        \\#!/bin/sh
        \\while IFS= read -r line; do
        \\  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
        \\  case "$line" in
        \\    *'"method":"server/discover"'*) printf '{"jsonrpc":"2.0","id":%s,"error":{"code":-32601,"message":"Method not found"}}\n' "$id" ;;
        \\    *'"method":"initialize"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"protocolVersion":"2025-11-25","capabilities":{"tools":{}},"serverInfo":{"name":"fake","version":"1"}}}\n' "$id" ;;
        \\    *'"method":"tools/list"'*) printf '{"jsonrpc":"2.0","id":%s,"result":{"tools":[{"name":"echo","description":"Echoes","inputSchema":{"type":"object"}},{"name":"stamp","description":"Stamps","inputSchema":{"type":"object"}}]}}\n' "$id" ;;
        \\  esac
        \\done
        \\n,
    });
    const config = try std.fs.path.join(gpa, &.{ root, ".fx", "mcp.json" });
    defer gpa.free(config);
    try std.Io.Dir.cwd().createDirPath(io, root ++ "/.fx");
    const document = try std.fmt.allocPrint(gpa, "{{\"mcp\":{{\"fake\":{{\"command\":\"{s}\"}}}}}}", .{server});
    defer gpa.free(document);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config, .data = document });
    var tools = try engine.listMcpTools(gpa, root, config, root, "fake", null);
    defer tools.deinit(gpa);
    try std.testing.expect(tools.note == null);
    try std.testing.expectEqual(@as(usize, 2), tools.names.len);
    try std.testing.expectEqualStrings("echo", tools.names[0]);
    try std.testing.expectEqualStrings("stamp", tools.names[1]);

    // The Settings panel asks through the Store's worker, not on the UI thread.
    var store = try Store.init(gpa, io, root, null);
    defer store.deinit();
    try std.testing.expectEqual(@as(usize, 1), store.mcp_servers.items.len);
    store.startMcpQuery("fake");
    var waited_ms: usize = 0;
    while (!store.mcpQueryDone()) : (waited_ms += 10) {
        if (waited_ms > 10_000) return error.Timeout;
        std.Io.sleep(io, .fromMilliseconds(10), .awake) catch {};
    }
    store.finishMcpQuery();
    try std.testing.expectEqualStrings("fake", store.mcp_tools_server);
    try std.testing.expectEqual(@as(usize, 2), store.mcp_tools.items.len);
    try std.testing.expectEqualStrings("echo", store.mcp_tools.items[0]);
    try std.testing.expectEqualStrings("stamp", store.mcp_tools.items[1]);
}

test "a provider that cannot be listed says so, and only about itself" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-provider-notes";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/.fx");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/.fx/settings.json", .data =
        \\{"provider":"magpie","providers":{"magpie":{"protocol":"openai-chat-completions","base_url":"http://127.0.0.1:3425/v1","auth":{"type":"none"}}}}
    });

    var store = try Store.init(gpa, io, home, null);
    defer store.deinit();
    // Nothing has been asked yet: no provider has anything to say.
    for (store.providers.items) |provider| try std.testing.expect(store.modelsNote(provider.name) == null);

    // fx answers for the provider it was asked about, and what it says lands
    // on that provider alone: the one below it is not blamed for it.
    store.models_query = try gpa.dupe(u8, "codex");
    store.models_query_note = try gpa.dupe(u8, "not signed in");
    store.models_query_failed = false;
    store.models_done.store(true, .release);
    store.finishModelsQuery();
    const said = store.modelsNote("codex").?;
    try std.testing.expectEqualStrings("not signed in", said.text);
    // Not being signed in is a state to show plainly, not a failure.
    try std.testing.expect(!said.failed);
    try std.testing.expect(store.modelsNote("gateway") == null);
    try std.testing.expect(store.modelsNote("grok") == null);
    try std.testing.expect(store.modelsNote("magpie") == null);

    // A reload rebuilds the rows, and keeps what was learned about them.
    store.reload();
    try std.testing.expectEqualStrings("not signed in", store.modelsNote("codex").?.text);
    try std.testing.expect(store.modelsNote("magpie") == null);

    // An endpoint that cannot be reached is a failure, and says so where it
    // happened.
    store.models_query = try gpa.dupe(u8, "magpie");
    store.models_query_note = try gpa.dupe(u8, "Could not reach the provider's /models");
    store.models_query_failed = true;
    store.models_done.store(true, .release);
    store.finishModelsQuery();
    const failed = store.modelsNote("magpie").?;
    try std.testing.expectEqualStrings("Could not reach the provider's /models", failed.text);
    try std.testing.expect(failed.failed);
    try std.testing.expectEqualStrings("not signed in", store.modelsNote("codex").?.text);

    // Listing its models takes the note away again.
    store.models_query = try gpa.dupe(u8, "magpie");
    store.models_done.store(true, .release);
    store.finishModelsQuery();
    try std.testing.expect(store.modelsNote("magpie") == null);
    try std.testing.expectEqualStrings("not signed in", store.modelsNote("codex").?.text);
}

/// A loopback answer to the model-catalog requests, so a test hears fx's real
/// Gateway path without a network or a real credential.
const FakeModelCatalog = struct {
    io_backend: std.Io.Threaded = .init_single_threaded,
    server: std.Io.net.Server = undefined,
    thread: ?std.Thread = null,
    body: []const u8,
    served: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn start(self: *FakeModelCatalog) !void {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.server = try address.listen(self.io(), .{ .reuse_address = true });
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn io(self: *FakeModelCatalog) std.Io {
        return self.io_backend.io();
    }

    fn port(self: *FakeModelCatalog) u16 {
        return self.server.socket.address.getPort();
    }

    fn serve(self: *FakeModelCatalog) void {
        const zio = self.io();
        while (true) {
            var stream = self.server.accept(zio) catch return;
            const answered = self.answer(zio, &stream);
            stream.close(zio);
            if (!answered) return;
            self.served.store(true, .release);
        }
    }

    fn answer(self: *FakeModelCatalog, zio: std.Io, stream: *std.Io.net.Stream) bool {
        var socket_buffer: [4096]u8 = undefined;
        var reader = stream.reader(zio, &socket_buffer);
        var head: [16 * 1024]u8 = undefined;
        var len: usize = 0;
        while (len < head.len) {
            head[len] = reader.interface.takeByte() catch return false;
            len += 1;
            if (std.mem.endsWith(u8, head[0..len], "\r\n\r\n")) break;
        }
        var write_buffer: [4096]u8 = undefined;
        var writer = stream.writer(zio, &write_buffer);
        writer.interface.writeAll("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n") catch return false;
        writer.interface.writeAll(self.body) catch return false;
        writer.interface.flush() catch return false;
        return true;
    }

    fn deinit(self: *FakeModelCatalog) void {
        if (self.thread) |thread| {
            // Wake a waiting accept, so a test that never reached the network
            // still ends.
            var address = std.Io.net.IpAddress{ .ip4 = .loopback(self.port()) };
            if (address.connect(self.io(), .{ .mode = .stream })) |wake| {
                var stream = wake;
                stream.close(self.io());
            } else |_| {}
            thread.join();
            self.thread = null;
        }
        self.server.deinit(self.io());
    }
};

test "a signed-in Gateway's models reach the picker" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-gateway-models";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/.fx");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/.fx/settings.json", .data = "{\"provider\":\"gateway\",\"model\":\"anthropic/claude-sonnet-4\"}" });

    var gateway: FakeModelCatalog = .{ .body =
        \\{"data":[{"id":"anthropic/claude-sonnet-4","type":"language","tags":["tool-use"],"context_window":200000},{"id":"openai/gpt-5","type":"language","tags":["tool-use"],"context_window":256000}]}
    };
    try gateway.start();
    defer gateway.deinit();

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();
    try env.put("HOME", home);
    try env.put("PATH", "/usr/bin:/bin");
    try env.put("FX_DISABLE_KEYCHAIN", "1");
    try env.put("AI_GATEWAY_API_KEY", "test-key");
    const url = try std.fmt.allocPrint(gpa, "http://127.0.0.1:{d}/v1/models", .{gateway.port()});
    defer gpa.free(url);
    try env.put("FX_TEST_GATEWAY_MODELS_URL", url);
    engine.shared_io.setIo(io);
    engine.shared_io.setEnvironMap(&env);
    defer engine.shared_io.resetEnvironForTest();

    // What the picker's worker asks fx: the Gateway's own catalog, read with
    // the credential the profile signed in with.
    var list = try engine.listProviderModels(gpa, .gateway, null);
    defer list.deinit(gpa);
    try std.testing.expect(gateway.served.load(.acquire));
    try std.testing.expect(list.note == null);
    try std.testing.expectEqual(@as(usize, 2), list.ids.len);
    // The picker view orders the catalog itself; both ids are listed.
    try std.testing.expect(hasId(list.ids, "anthropic/claude-sonnet-4"));
    try std.testing.expect(hasId(list.ids, "openai/gpt-5"));

    // The store runs that same call off the UI thread and publishes the list
    // on the Gateway row the picker lists.
    var store = try Store.init(gpa, io, home, null);
    defer store.deinit();
    try std.testing.expectEqualStrings("gateway", store.providers.items[0].name);
    store.startModelsQuery(store.providers.items[0]);
    var waited: usize = 0;
    while (!store.modelsQueryDone()) : (waited += 1) {
        if (waited > 2000) return error.TimedOut;
        std.Io.Threaded.global_single_threaded.io().sleep(.fromMilliseconds(5), .awake) catch {};
    }
    store.finishModelsQuery();
    try std.testing.expect(store.modelsNote("gateway") == null);
    try std.testing.expectEqual(@as(usize, 2), store.providers.items[0].models.items.len);
    try std.testing.expect(hasId(store.providers.items[0].models.items, "anthropic/claude-sonnet-4"));
    try std.testing.expect(hasId(store.providers.items[0].models.items, "openai/gpt-5"));

    // Choosing one writes fx's own preference, as the picker's row does.
    store.chooseProviderModel("gateway", "openai/gpt-5");
    try std.testing.expect(!store.failed);
    try std.testing.expectEqualStrings("openai/gpt-5", store.currentModel());
}

test "reopening the picker asks a provider that answered with nothing again" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-models-retry";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/.fx");

    var store = try Store.init(gpa, io, home, null);
    defer store.deinit();
    const gateway = &store.providers.items[0];
    try std.testing.expectEqualStrings("gateway", gateway.name);
    // An attempt made before signing in left nothing to list.
    gateway.models_tried = true;

    store.retryModels();
    try std.testing.expect(!gateway.models_tried);

    // One that listed its models is not asked again: a reopen costs no
    // request.
    try gateway.models.append(gpa, try gpa.dupe(u8, "anthropic/claude-sonnet-4"));
    gateway.models_tried = true;
    store.retryModels();
    try std.testing.expect(gateway.models_tried);
}

fn hasId(ids: anytype, id: []const u8) bool {
    for (ids) |candidate| if (std.mem.eql(u8, candidate, id)) return true;
    return false;
}
