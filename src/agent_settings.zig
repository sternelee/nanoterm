//! Configuration for the built-in Agent, used by Settings. Providers and MCP are written
//! through agent's locking, preserving stores; Skills use agent's managed installer.
const std = @import("std");
const engine = @import("fx");
const ui = @import("nanoui").ui;

const Allocator = std.mem.Allocator;

pub const Provider = struct {
    name: []u8,
    base_url: []u8,
    model: []u8,
    auth_env: []u8,
    selected: bool,
    open: bool = false,

    fn deinit(self: Provider, gpa: Allocator) void {
        gpa.free(self.name);
        gpa.free(self.base_url);
        gpa.free(self.model);
        gpa.free(self.auth_env);
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

    pub fn init(gpa: Allocator, io: std.Io, home: []const u8) !Store {
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
            .selected_provider = selected_provider,
            .status = status,
        };
        self.reload();
        return self;
    }

    pub fn deinit(self: *Store) void {
        self.mcp_query_cancel.store(true, .release);
        if (self.mcp_query_thread) |thread| thread.join();
        self.clearMcpQuery();
        self.clearMcpTools();
        self.mcp_query_names.deinit(self.gpa);
        self.mcp_tools.deinit(self.gpa);
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

    fn clearLists(self: *Store) void {
        for (self.providers.items) |item| item.deinit(self.gpa);
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

    fn fail(self: *Store, err: anyerror) void {
        self.replace(&self.status, @errorName(err)) catch {};
        self.failed = true;
    }

    pub fn reload(self: *Store) void {
        self.clearLists();
        self.loadProviders() catch |err| self.fail(err);
        self.loadMcp() catch |err| self.fail(err);
        self.loadSkills() catch |err| self.fail(err);
    }

    fn loadProviders(self: *Store) !void {
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, self.settings_path, self.gpa, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => return,
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
            try self.providers.append(self.gpa, .{
                .name = try self.gpa.dupe(u8, entry.key_ptr.*),
                .base_url = try self.gpa.dupe(u8, url),
                .model = try self.gpa.dupe(u8, model),
                .auth_env = try self.gpa.dupe(u8, auth_env),
                .selected = std.mem.eql(u8, self.selected_provider, entry.key_ptr.*),
            });
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
        const model = std.mem.trim(u8, self.provider_model.text(), " \t\r\n");
        const env = std.mem.trim(u8, self.provider_auth_env.text(), " \t\r\n");
        if (name.len == 0 or url.len == 0 or model.len == 0) return self.fail(error.ProviderFieldsRequired);
        const id = engine.model_provider.parse(name) orelse return self.fail(error.InvalidProviderId);
        if (id != .configured) return self.fail(error.ReservedProviderId);
        var outcome = engine.provider_settings.setUserPreferencesAtHome(self.gpa, self.home, .{
            .provider = id,
            .provider_definition = .{ .upsert = .{
                .id = name,
                .base_url = url,
                .bearer_env = if (env.len > 0) env else null,
            } },
            .model_preference = .{ .provider = id, .model = model },
        }) catch |err| return self.fail(err);
        defer outcome.deinit(self.gpa);
        self.note("Provider saved and selected");
        self.provider_form_open = false;
        self.provider_name.clear();
        self.provider_url.clear();
        self.provider_model.clear();
        self.provider_auth_env.clear();
        self.reload();
    }

    pub fn selectProvider(self: *Store, provider: Provider) void {
        const id = engine.model_provider.parse(provider.name) orelse return self.fail(error.InvalidProviderId);
        var outcome = engine.provider_settings.setUserPreferencesAtHome(self.gpa, self.home, .{
            .provider = id,
            .model_preference = if (provider.model.len > 0) .{ .provider = id, .model = provider.model } else null,
        }) catch |err| return self.fail(err);
        defer outcome.deinit(self.gpa);
        self.note("Provider selected");
        self.reload();
    }

    pub fn selectProviderByName(self: *Store, name: []const u8) void {
        if (std.mem.eql(u8, name, "gateway")) {
            var outcome = engine.provider_settings.setUserPreferencesAtHome(self.gpa, self.home, .{
                .provider = .gateway,
            }) catch |err| return self.fail(err);
            defer outcome.deinit(self.gpa);
            self.note("Default provider selected");
            self.reload();
            return;
        }
        for (self.providers.items) |provider| {
            if (std.mem.eql(u8, provider.name, name)) return self.selectProvider(provider);
        }
        self.fail(error.ProviderNotFound);
    }

    pub fn removeProvider(self: *Store, name: []const u8) void {
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

test "agent settings manage providers, MCP servers, and Skills in an isolated home" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-agent-config";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/.fx");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/.fx/settings.json", .data = "{\"future\":{\"keep\":true}}" });

    var store = try Store.init(gpa, io, home);
    defer store.deinit();
    try std.testing.expectEqualStrings("", store.currentModel());

    store.provider_name.set("local");
    store.provider_url.set("http://127.0.0.1:11434/v1/");
    store.provider_model.set("qwen3-coder");
    store.saveProvider();
    try std.testing.expect(!store.failed);
    try std.testing.expectEqualStrings("local", store.selected_provider);
    try std.testing.expectEqual(@as(usize, 1), store.providers.items.len);
    try std.testing.expectEqualStrings("qwen3-coder", store.providers.items[0].model);
    // Saving the same id again updates it, rather than adding a duplicate.
    store.provider_name.set("local");
    store.provider_url.set("http://127.0.0.1:11435/v1/");
    store.provider_model.set("qwen3-coder-plus");
    store.saveProvider();
    try std.testing.expect(!store.failed);
    try std.testing.expectEqual(@as(usize, 1), store.providers.items.len);
    try std.testing.expectEqualStrings("http://127.0.0.1:11435/v1/", store.providers.items[0].base_url);
    try std.testing.expectEqualStrings("qwen3-coder-plus", store.providers.items[0].model);
    store.selectProviderByName("gateway");
    try std.testing.expectEqualStrings("", store.currentModel());
    store.selectProviderByName("local");
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
    try std.testing.expectEqual(@as(usize, 0), store.providers.items.len);
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
    var store = try Store.init(gpa, io, root);
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
