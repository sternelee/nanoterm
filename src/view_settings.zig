//! Settings (⌘,): a sidebar of categories — Agents (built-in Agent
//! providers, MCP and Skills, the agents nanoterm ships, installed or
//! not, the one new tabs start with), Appearance (the theme shelf,
//! font, icons, keys, text size), Motion, Privacy, and Updates.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const agents = @import("agents.zig");
const agent_mod = @import("agent.zig");
const Workspace = @import("workspace.zig").Workspace;
const settings = @import("settings.zig");
const relay = @import("relay.zig");
const threads_mod = @import("threads.zig");

pub const Page = enum(u8) { agents = 0, appearance = 1, motion = 2, privacy = 3, updates = 4, relay = 5, threads = 6 };

pub fn card(c: *ui.Context, w: *Workspace) void {
    const panel = ui.div(c).column().w(@min(720, c.size.w - 40)).bg(theme.panel).rounded(14).border(theme.border).shadowLg().clip();
    defer panel.end();
    // Clicks inside stay inside.
    _ = panel.interaction();
    {
        const head = ui.div(c).row().wFull().itemsCenter().px(20).pt(16).pb(10);
        defer head.end();
        ui.text(c, "Settings", .{ .size = 17, .weight = .bold });
        ui.spacer(c);
        if (ui.button(c, "", .{ .variant = .ghost, .size = 11, .icon = "xmark" }).clicked) w.closeOverlay();
    }
    // As tall as the Agents page is: the panel keeps that height on
    // every other page, each of which scrolls its own content. The
    // Agents page is content-sized (up to the window's room); its
    // height is remembered and the other pages are held to it.
    const body_id = c.peekId(null);
    var body = ui.div(c).row().wFull().itemsStretch().maxH(c.size.h - 170);
    const on_agents = w.settings_page == @backingInt(Page.agents);
    if (!on_agents and w.settings_height > 0) body = body.h(@min(w.settings_height, c.size.h - 170));
    defer body.end();
    if (on_agents) {
        if (c.rects.get(body_id)) |r| w.settings_height = r.h;
    }
    {
        const side = ui.div(c).column().w(168).px(8).py(10).gap(2).maxH(c.size.h - 210);
        defer side.end();
        sideItem(c, w, .agents, "person.2", "Agents");
        sideItem(c, w, .appearance, "paintpalette", "Appearance");
        sideItem(c, w, .motion, "waveform", "Motion");
        sideItem(c, w, .privacy, "hand.raised", "Privacy");
        sideItem(c, w, .updates, "arrow.down.circle", "Updates");
        sideItem(c, w, .relay, "globe", "Relay");
        sideItem(c, w, .threads, "tray.full", "Threads");
    }
    _ = c.leaf(.{ .width = .{ .px = 1 }, .background = theme.border }, .none, null);
    {
        const page = ui.div(c).column().grow().scrollY().maxH(c.size.h - 210).px(20).py(16).gap(18);
        defer page.end();
        switch (w.settings_page) {
            @backingInt(Page.agents) => {
                agentList(c, w);
                account(c, w);
            },
            @backingInt(Page.appearance) => appearance(c, w),
            @backingInt(Page.motion) => motionPage(c, w),
            @backingInt(Page.privacy) => privacy(c, w),
            @backingInt(Page.updates) => updates(c, w),
            @backingInt(Page.relay) => relayPage(c, w),
            @backingInt(Page.threads) => threadsPage(c, w),
            else => {},
        }
    }
}

/// A category on Settings' sidebar, lit while its page is the one shown.
fn sideItem(c: *ui.Context, w: *Workspace, page: Page, icon: []const u8, label: []const u8) void {
    const sel = w.settings_page == @backingInt(page);
    const d = if (sel) ui.div(c).row().wFull().gap(8).itemsCenter().px(9).py(6).rounded(8).bg(theme.block_selected) else ui.div(c).row().wFull().gap(8).itemsCenter().px(9).py(6).rounded(8);
    defer d.end();
    if (d.clicked()) w.settings_page = @backingInt(page);
    ui.icon(c, icon, .{ .size = 12, .color = if (sel) theme.accent else theme.muted });
    ui.text(c, label, .{ .size = 12.5, .weight = if (sel) .semibold else .regular, .color = if (sel) theme.text else theme.muted });
}

fn section(c: *ui.Context, title: []const u8) ui.Div {
    const col = ui.div(c).column().wFull().gap(8);
    ui.text(c, title, .{ .size = 12, .weight = .semibold, .color = theme.muted });
    return col;
}

fn box(c: *ui.Context) ui.Div {
    return ui.div(c).column().wFull().p(14).gap(10).bg(theme.background).rounded(10).border(theme.border);
}

pub fn account(c: *ui.Context, w: *Workspace) void {
    const kit = nanoui.kit;
    const store = w.shared.agent_store orelse {
        const s = section(c, "Agent · built in");
        defer s.end();
        ui.text(c, "Agent configuration needs a home directory.", .{ .color = theme.failure });
        return;
    };
    if (kit.collapsible(c, "agent-builtin", "Agent · built in", &store.config_open)) |config| {
        defer config.end();
        {
            const b = box(c);
            defer b.end();
            ui.text(c, "Providers", .{ .size = 14, .weight = .semibold });
            ui.text(c, "fx's own providers, and custom OpenAI-compatible ones with their model and optional bearer token variable.", .{ .size = 12, .color = theme.muted, .wrap = true });
            for (store.providers.items) |*provider| {
                const name = @import("agent_settings.zig").label(provider.name);
                const open = kit.collapsible(
                    c,
                    c.print("provider-{s}", .{provider.name}),
                    if (provider.selected) c.print("{s} · selected", .{name}) else name,
                    &provider.open,
                ) orelse continue;
                defer open.end();
                ui.text(c, if (provider.models.items.len > 1)
                    c.print("{s} · {s} +{d}", .{ provider.detail(), provider.models.items[0], provider.models.items.len - 1 })
                else
                    c.print("{s} · {s}", .{ provider.detail(), provider.model }), .{ .size = 11.5, .color = theme.muted, .wrap = true });
                if (provider.auth_env.len > 0) ui.text(c, c.print("Token variable: {s}", .{provider.auth_env}), .{ .size = 11, .color = theme.faint });
                const listing = store.models_thread != null and std.mem.eql(u8, store.models_query, provider.name);
                {
                    const actions = ui.div(c).row().wFull().gap(8);
                    defer actions.end();
                    if (!provider.selected and ui.button(c, "Select", .{ .size = 12 }).clicked) {
                        store.selectProvider(provider.*);
                        syncAgentModel(w);
                        // selectProvider reloads the list this loop borrows from.
                        break;
                    }
                    const fetch_label = if (listing)
                        "Listing…"
                    else if (provider.builtin)
                        "List models"
                    else if (store.models_call.running and store.models_for != null and std.mem.eql(u8, store.models_for.?, provider.name))
                        "Fetching…"
                    else
                        "Fetch models";
                    if (ui.button(c, fetch_label, .{ .variant = .ghost, .size = 12 }).clicked) {
                        store.fetchModels(provider.*, if (provider.auth_env.len > 0) w.shared.env.get(provider.auth_env) else null);
                    }
                    // fx's own providers cannot be removed: fx always has them.
                    if (!provider.builtin) if (ui.button(c, "Remove", .{ .variant = .ghost, .size = 12 }).clicked) {
                        const owned = c.gpa.dupe(u8, provider.name) catch break;
                        defer c.gpa.free(owned);
                        store.removeProvider(owned);
                        syncAgentModel(w);
                        break;
                    };
                }
                // Why this provider's models could not be listed, if they
                // could not: said here, under the provider it is about.
                if (store.modelsNote(provider.name)) |said| ui.text(c, said.text, .{ .size = 11.5, .color = if (said.failed) theme.failure else theme.muted, .wrap = true });
            }
            if (kit.collapsible(c, "provider-add", "Add provider", &store.provider_form_open)) |open| {
                defer open.end();
                _ = ui.textField(c, &store.provider_name, .{ .placeholder = "Provider id (for example local)", .width = .fill });
                _ = ui.textField(c, &store.provider_url, .{ .placeholder = "Base URL, including /v1/", .width = .fill });
                _ = ui.textField(c, &store.provider_model, .{ .placeholder = "Models, comma-separated (qwen3-coder, llama-x)", .width = .fill });
                _ = ui.textField(c, &store.provider_auth_env, .{ .placeholder = "Bearer token environment variable (optional)", .width = .fill });
                if (ui.button(c, "Save and select provider", .{ .variant = .primary, .size = 12 }).clicked) {
                    store.saveProvider();
                    syncAgentModel(w);
                }
            }
        }
        // fx's own dials: sign-in, permissions, effort, directories, and
        // the instructions it reads — for the pane the panel is over.
        {
            const focused = w.focused();
            const cwd = focused.cwd();
            store.ensureRuntime(cwd);
            // The panel shows the providers' models, so fx is asked for them.
            store.showModels();
            // Sign-in state, as fx sees it, once each time the panel opens.
            if (!store.signed_checked and !store.checking) {
                store.refreshSignIn(w.shared.env.get("PATH") orelse "/usr/bin:/bin");
            }
            {
                const b = box(c);
                defer b.end();
                ui.text(c, "Sign in", .{ .size = 14, .weight = .semibold });
                const provider_label: []const u8 = if (std.mem.eql(u8, store.selected_provider, "gateway")) "AI Gateway" else store.selected_provider;
                const state = if (store.checking) "checking…" else if (store.auth_label.len > 0) store.auth_label else "not signed in";
                ui.text(c, c.print("Provider: {s} · {s}. Sign-in runs in the terminal, as fx does.", .{ provider_label, state }), .{ .size = 12, .color = theme.muted, .wrap = true });
                const SignIn = struct { label: []const u8, note: []const u8, name: []const u8, sign_in: []const u8, sign_out: []const u8 };
                const rows = [_]SignIn{
                    .{ .label = "Codex", .note = "ChatGPT subscription", .name = "codex", .sign_in = "fx login codex", .sign_out = "fx logout codex" },
                    .{ .label = "Grok", .note = "Grok subscription", .name = "grok", .sign_in = "fx login grok", .sign_out = "fx logout grok" },
                    .{ .label = "AI Gateway", .note = "Vercel account or API key", .name = "gateway", .sign_in = "fx setup", .sign_out = "fx logout vercel" },
                };
                for (rows) |row| {
                    const r = ui.div(c).row().wFull().gap(10).itemsCenter();
                    defer r.end();
                    ui.text(c, row.label, .{ .size = 13, .weight = .semibold });
                    if (store.signedIn(row.name)) ui.icon(c, "checkmark.circle.fill", .{ .size = 12, .color = theme.accent });
                    ui.text(c, row.note, .{ .size = 11.5, .color = theme.muted });
                    ui.spacer(c);
                    const label: []const u8 = if (store.signedIn(row.name)) "Sign out" else "Sign in";
                    if (ui.button(c, label, .{ .size = 12 }).clicked) {
                        const line = c.gpa.dupe(u8, if (store.signedIn(row.name)) row.sign_out else row.sign_in) catch continue;
                        defer c.gpa.free(line);
                        focused.input.clear();
                        focused.run(line);
                        w.closeOverlay();
                    }
                }
            }
            {
                const b = box(c);
                defer b.end();
                ui.text(c, "Permissions", .{ .size = 14, .weight = .semibold });
                const names = [_][]const u8{ "Ask", "Auto", "Full access" };
                const values = [_][]const u8{ "ask", "auto", "full-access" };
                var selected: usize = 1;
                for (values, 0..) |value, i| if (std.mem.eql(u8, store.perm_mode, value)) {
                    selected = i;
                };
                {
                    const r = ui.div(c).row().wFull().gap(10).itemsCenter();
                    defer r.end();
                    if (ui.segmented(c, names[0..], &selected)) store.setPermissionMode(cwd, values[selected]);
                    ui.spacer(c);
                    ui.text(c, store.perm_mode, .{ .size = 11.5, .color = theme.muted });
                }
                ui.text(c, "What fx may do without asking. The built-in agent runs auto inside nanoterm; fx in the terminal and its new sessions follow this.", .{ .size = 11.5, .color = theme.muted, .wrap = true });
            }
            {
                const b = box(c);
                defer b.end();
                ui.text(c, "Reasoning effort", .{ .size = 14, .weight = .semibold });
                const names = [_][]const u8{ "Default", "Minimal", "Low", "Medium", "High" };
                const values = [_][]const u8{ "auto", "minimal", "low", "medium", "high" };
                var selected: usize = 0;
                for (values, 0..) |value, i| if (std.mem.eql(u8, store.effort, value)) {
                    selected = i;
                };
                if (ui.segmented(c, names[0..], &selected)) store.setEffortLevel(cwd, values[selected]);
                ui.text(c, "How much room the model is given to reason; higher takes longer. Applies from the next turn, and to fx in the terminal.", .{ .size = 11.5, .color = theme.muted, .wrap = true });
            }
            {
                const b = box(c);
                defer b.end();
                ui.text(c, "Additional workspaces", .{ .size = 14, .weight = .semibold });
                ui.text(c, "Other directories this workspace's fx may work in.", .{ .size = 12, .color = theme.muted, .wrap = true });
                for (store.dirs.items) |dir| {
                    const r = ui.div(c).row().wFull().gap(10).itemsCenter();
                    defer r.end();
                    ui.text(c, dir, .{ .size = 12.5, .mono = true });
                    ui.spacer(c);
                    if (ui.button(c, "Remove", .{ .variant = .ghost, .size = 12 }).clicked) {
                        const path = c.gpa.dupe(u8, dir) catch continue;
                        defer c.gpa.free(path);
                        store.removeWorkspaceDir(cwd, path);
                        break;
                    }
                }
                const add = ui.div(c).row().wFull().gap(8).itemsCenter();
                defer add.end();
                _ = ui.textField(c, &store.workspace_dir, .{ .placeholder = "/another/project", .width = .fill });
                if (ui.button(c, "Add", .{ .variant = .primary, .size = 12 }).clicked) store.addWorkspaceDir(cwd);
            }
            {
                const b = box(c);
                defer b.end();
                ui.text(c, "Project instructions", .{ .size = 14, .weight = .semibold });
                if (store.agents_files.items.len == 0) {
                    ui.text(c, "No AGENTS.md found; fx reads one at the project's root, and nested ones beside the files it works on.", .{ .size = 11.5, .color = theme.faint, .wrap = true });
                }
                for (store.agents_files.items) |path| {
                    const r = ui.div(c).row().wFull().gap(10).itemsCenter();
                    defer r.end();
                    ui.text(c, path, .{ .size = 12.5, .mono = true });
                    ui.spacer(c);
                    if (ui.button(c, "Open", .{ .variant = .ghost, .size = 12 }).clicked) {
                        const line = std.fmt.allocPrint(c.gpa, "open \"{s}\"", .{path}) catch continue;
                        defer c.gpa.free(line);
                        focused.input.clear();
                        focused.run(line);
                        w.closeOverlay();
                    }
                }
            }
        }
        {
            const b = box(c);
            defer b.end();
            ui.text(c, "MCP servers", .{ .size = 14, .weight = .semibold });
            ui.text(c, "stdio and HTTP servers in Agent's own MCP profile.", .{ .size = 12, .color = theme.muted, .wrap = true });
            for (store.mcp_servers.items) |*server| {
                const open = kit.collapsible(c, c.print("mcp-{s}", .{server.name}), server.name, &server.open) orelse continue;
                defer open.end();
                ui.text(c, server.summary, .{ .size = 11.5, .color = theme.muted, .wrap = true });
                const actions = ui.div(c).row().wFull().gap(8);
                defer actions.end();
                if (ui.button(c, if (store.mcp_query_thread == null) "List tools" else "Listing…", .{ .size = 12 }).clicked) {
                    store.startMcpQuery(server.name);
                    pollMcpTools(w);
                }
                if (ui.button(c, "Remove", .{ .variant = .ghost, .size = 12 }).clicked) {
                    const name = c.gpa.dupe(u8, server.name) catch break;
                    defer c.gpa.free(name);
                    store.removeMcp(name);
                    break;
                }
                if (store.mcp_query_thread != null and std.mem.eql(u8, store.mcp_query_server, server.name)) {
                    ui.text(c, "Starting the server and asking for its tools…", .{ .size = 11, .color = theme.faint });
                }
                if (std.mem.eql(u8, store.mcp_tools_server, server.name)) {
                    if (store.mcp_tools_note.len > 0) {
                        ui.text(c, store.mcp_tools_note, .{ .size = 11, .color = if (store.mcp_tools_failed) theme.failure else theme.muted, .wrap = true });
                    }
                    if (store.mcp_tools.items.len > 0) {
                        ui.text(c, c.print("{d} tools", .{store.mcp_tools.items.len}), .{ .size = 11.5, .weight = .semibold, .color = theme.muted });
                        for (store.mcp_tools.items) |tool| {
                            const row = ui.div(c).row().wFull().gap(6).itemsCenter();
                            defer row.end();
                            ui.icon(c, "wrench.and.screwdriver", .{ .size = 11, .color = theme.agent });
                            ui.text(c, tool, .{ .size = 12 });
                        }
                    }
                }
            }
            if (store.mcp_servers.items.len == 0) ui.text(c, "No MCP servers yet.", .{ .size = 11.5, .color = theme.faint });
            if (kit.collapsible(c, "mcp-add", "Add MCP server", &store.mcp_form_open)) |open| {
                defer open.end();
                _ = ui.textField(c, &store.mcp_name, .{ .placeholder = "Server name", .width = .fill });
                _ = ui.textField(c, &store.mcp_target, .{ .placeholder = "https://… or executable command", .width = .fill });
                _ = ui.textField(c, &store.mcp_args, .{ .placeholder = "Space-separated arguments for stdio command (optional)", .width = .fill });
                _ = ui.textField(c, &store.mcp_env, .{ .placeholder = "stdio environment JSON (optional)", .width = .fill });
                _ = ui.textField(c, &store.mcp_headers, .{ .placeholder = "HTTP headers JSON (optional)", .width = .fill });
                ui.text(c, "Environment and headers are JSON objects, for example {\"TOKEN\":\"…\"}.", .{ .size = 11, .color = theme.faint });
                if (ui.button(c, "Add MCP server", .{ .size = 12 }).clicked) store.addMcp();
            }
        }
        {
            const b = box(c);
            defer b.end();
            ui.text(c, "Skills", .{ .size = 14, .weight = .semibold });
            ui.text(c, "Procedures Agent can load from its Skills roots.", .{ .size = 12, .color = theme.muted, .wrap = true });
            for (store.skills.items) |skill| {
                const r = ui.div(c).row().wFull().gap(8).itemsCenter();
                defer r.end();
                ui.icon(c, "puzzlepiece", .{ .size = 13, .color = theme.agent });
                ui.text(c, skill.name, .{ .size = 12.5 });
                ui.spacer(c);
                if (ui.button(c, "Remove", .{ .variant = .ghost, .size = 11.5 }).clicked) {
                    const name = c.gpa.dupe(u8, skill.name) catch break;
                    defer c.gpa.free(name);
                    store.removeSkill(name);
                    break;
                }
            }
            if (store.skills.items.len == 0) ui.text(c, "No Skills yet.", .{ .size = 11.5, .color = theme.faint });
            if (kit.collapsible(c, "skill-add", "Add Skill", &store.skill_form_open)) |open| {
                defer open.end();
                ui.text(c, "Install a git repository, or start a new Skill from nanoterm's template.", .{ .size = 11.5, .color = theme.muted, .wrap = true });
                _ = ui.textField(c, &store.skill_source, .{ .placeholder = "Install from git URL or local path", .width = .fill });
                if (ui.button(c, "Install Skill", .{ .size = 12 }).clicked) store.installSkill();
                _ = ui.textField(c, &store.skill_name, .{ .placeholder = "New Skill name", .width = .fill });
                if (ui.button(c, "Create Skill template", .{ .size = 12 }).clicked) store.createSkill();
            }
        }
    }
    if (store.status.len > 0) ui.text(c, store.status, .{ .size = 11.5, .color = if (store.failed) theme.failure else theme.success });
}

fn pollMcpTools(w: *Workspace) void {
    nanoui.App.after(30, w, struct {
        fn step(context: ?*anyopaque) callconv(.c) void {
            const workspace: *Workspace = @ptrCast(@alignCast(context));
            const store = workspace.shared.agent_store orelse return;
            if (!store.mcpQueryDone()) {
                nanoui.App.after(30, workspace, step);
                return;
            }
            store.finishMcpQuery();
            workspace.shared.redraw();
        }
    }.step);
}

fn syncAgentModel(w: *Workspace) void {
    const s = w.focused();
    if (s.which != .agent) return;
    const store = s.shared.agent_store orelse return;
    @import("assist.zig").chooseModel(s, store.currentModel());
}

pub fn agentList(c: *ui.Context, w: *Workspace) void {
    const s = section(c, "Agents");
    defer s.end();
    const b = box(c);
    const prefs = &w.shared.prefs;
    {
        // Off: a terminal and nothing else.
        const r = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer r.end();
        const t = ui.div(c).column().grow().gap(2);
        {
            defer t.end();
            ui.text(c, "Coding agents", .{ .size = 13 });
            ui.text(c, if (prefs.agents) "Questions go to your agent; commands run." else "Off: a terminal and nothing else. Everything typed runs; nothing is sent to an agent.", .{ .size = 11.5, .color = theme.muted, .wrap = true });
        }
        var on = prefs.agents;
        if (ui.toggle(c, "", &on)) prefs.setAgents(on);
    }
    if (!prefs.agents) return b.end();
    for (agents.all, 0..) |info, i| {
        ui.key(c, c.print("agent-{d}", .{i}));
        _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = theme.border }, .none, null);
        const r = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer r.end();
        const have = prefs.installed.get(info.which);
        _ = c.leaf(.{ .width = .{ .px = 7 }, .height = .{ .px = 7 }, .radius = 3.5, .background = if (have) theme.success else theme.faint }, .none, null);
        {
            const f = ui.div(c).w(22).h(22).center();
            defer f.end();
            _ = ui.image(c, .{ .key = c.print("agent-mark-{s}", .{@tagName(info.which)}), .bytes = @import("marks.zig").agent(info.which), .max_width = 20, .max_height = 20, .radius = 0, .tint = if (have) theme.text else theme.faint });
        }
        {
            const t = ui.div(c).column().grow().gap(2);
            defer t.end();
            ui.text(c, info.which.label(), .{ .size = 13.5, .weight = .semibold });
            ui.text(c, if (have) info.blurb else c.print("Not installed · {s}", .{info.blurb}), .{ .size = 11.5, .color = theme.muted, .wrap = true });
        }
        if (!have) {
            if (ui.button(c, "Install", .{ .size = 12, .icon = "arrow.down.circle" }).clicked) runInTab(w, info.install);
            continue;
        }
        if (info.login.len > 0 and info.which != .agent) {
            if (ui.button(c, "Sign in", .{ .variant = .ghost, .size = 12 }).clicked) runInTab(w, info.login);
        }
        if (prefs.agent == info.which) {
            const d = ui.div(c).row().gap(5).itemsCenter().px(10).py(4).rounded(7).bg(theme.agent.alpha(0.12));
            defer d.end();
            ui.icon(c, "checkmark", .{ .size = 10, .weight = .bold, .color = theme.agent });
            ui.text(c, "Default", .{ .size = 12, .color = theme.agent });
        } else if (ui.button(c, "Make default", .{ .variant = .ghost, .size = 12 }).clicked) {
            prefs.setAgent(info.which);
            w.focused().choose(info.which);
        }
    }
    _ = c.leaf(.{ .width = .fill, .height = .{ .px = 1 }, .background = theme.border }, .none, null);
    {
        const r = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer r.end();
        const t = ui.div(c).column().grow().gap(2);
        {
            defer t.end();
            ui.text(c, "Default model", .{ .size = 13 });
            ui.text(c, "New tabs and Thread tasks ask for it. Empty leaves each agent's own choice; the agent's own settings are not changed.", .{ .size = 11.5, .color = theme.muted, .wrap = true });
        }
        const result = ui.textField(c, &w.model_buffer, .{ .placeholder = "The agent's own model", .width = .{ .px = 240 } });
        if (result.changed or result.submitted) prefs.setModel(w.model_buffer.text());
        if (result.submitted) {
            // As "Make default" does for the agent: the pane that follows
            // the default starts on its model too.
            const model = std.mem.trim(u8, w.model_buffer.text(), " \t\r\n");
            const pane = w.focused();
            if (model.len > 0 and pane.which == prefs.agent) @import("assist.zig").chooseModel(pane, model);
        }
    }
    ui.text(c, "New tabs start with the default agent; ⌘⇧M switches the one a pane uses.", .{ .size = 11.5, .color = theme.faint });
    b.end();
}

/// Runs `command` in a new tab (an installer, a sign-in), and closes Settings.
pub fn runInTab(w: *Workspace, command: []const u8) void {
    const s = w.newTab(w.shared.home) catch return;
    s.run(command);
    w.closeOverlay();
}

fn indexOfString(options: [][]const u8, want: []const u8) ?usize {
    for (options, 0..) |option, i| if (std.mem.eql(u8, option, want)) return i;
    return null;
}

/// What the select shows a family as: the whole name while it fits, else
/// as much as does with an ellipsis, so no long family overflows the list.
pub fn fontOptionLabel(c: *ui.Context, name: []const u8) []const u8 {
    const max: f32 = 200;
    const style = ui.TextStyle{ .size = 13 };
    if (c.text.width(name, style) <= max) return name;
    const ellipsis = "…";
    var end = name.len;
    while (end > 0) {
        while (end > 0 and (name[end - 1] & 0xc0) == 0x80) end -= 1;
        if (c.text.width(name[0..end], style) + c.text.width(ellipsis, style) <= max) return c.print("{s}{s}", .{ name[0..end], ellipsis });
        end -= 1;
    }
    return ellipsis;
}

fn fontOptionLabels(c: *ui.Context, options: [][]const u8) [][]const u8 {
    const labels = c.alloc().alloc([]const u8, options.len) catch return options;
    for (options, 0..) |option, i| labels[i] = fontOptionLabel(c, option);
    return labels;
}

fn appearance(c: *ui.Context, w: *Workspace) void {
    themePicker(c, w);
    const s = section(c, "Terminal");
    defer s.end();
    const b = box(c);
    defer b.end();
    {
        const r = ui.div(c).row().wFull().itemsCenter();
        defer r.end();
        ui.text(c, "Terminal font", .{ .size = 13 });
        ui.spacer(c);
        const kit = nanoui.kit;
        const options = w.shared.fonts.options.items;
        const current = w.shared.prefs.terminal_font;
        var picked: ?usize = if (current.len == 0) 0 else indexOfString(options, current);
        const labels = fontOptionLabels(c, options);
        if (kit.select(c, "terminal-font", labels, &picked, .{ .placeholder = "System", .width = 240 })) {
            if (picked) |index| w.shared.prefs.setTerminalFont(if (index == 0) "" else options[index]);
        }
    }
    ui.text(c, "A Nerd Font (JetBrainsMono Nerd Font, MesloLGS NF) has the glyphs for the file icons below.", .{ .size = 11.5, .color = theme.muted, .wrap = true });
    {
        const r = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer r.end();
        const t = ui.div(c).column().grow().gap(2);
        {
            defer t.end();
            ui.text(c, "File icons in ls", .{ .size = 13 });
            ui.text(c, "A Nerd Font icon before each file an ls prints: folders, pictures, archives, programs.", .{ .size = 11.5, .color = theme.muted, .wrap = true });
        }
        var on = w.shared.prefs.file_icons;
        if (ui.toggle(c, "", &on)) w.shared.prefs.setFileIcons(on);
    }
    {
        const r = ui.div(c).row().wFull().itemsCenter();
        defer r.end();
        ui.text(c, "Keys in the input", .{ .size = 13 });
        ui.spacer(c);
        const names = [_][]const u8{ "Standard", "Emacs", "Vim" };
        const order = [_]ui.Keymap{ .system, .emacs, .vim };
        var picked: usize = std.mem.indexOfScalar(ui.Keymap, &order, w.shared.prefs.keys) orelse 0;
        if (ui.segmented(c, &names, &picked)) w.shared.prefs.setKeys(order[picked]);
    }
    {
        const r = ui.div(c).row().wFull().gap(8).itemsCenter();
        defer r.end();
        ui.text(c, "Text size", .{ .size = 13 });
        ui.spacer(c);
        if (ui.button(c, "", .{ .size = 11, .icon = "minus" }).clicked) w.zoomBy(-0.1);
        ui.text(c, c.print("{d:.0}%", .{w.zoom * 100}), .{ .size = 12.5, .mono = true, .color = theme.muted });
        if (ui.button(c, "", .{ .size = 11, .icon = "plus" }).clicked) w.zoomBy(0.1);
        if (ui.button(c, "Reset", .{ .variant = .ghost, .size = 12 }).clicked) w.zoom = 1;
    }
}

/// The theme shelf, as Metalterm's settings lay it out: System first —
/// light or dark, as the system is — then every named theme, a row of
/// its name, its line, and a row of its colors.
fn themePicker(c: *ui.Context, w: *Workspace) void {
    const s = section(c, "Theme");
    defer s.end();
    const b = box(c);
    defer b.end();
    const prefs = &w.shared.prefs;
    // System: follows the appearance the palette sets.
    {
        const sel = prefs.theme.len == 0;
        const r = if (sel) ui.div(c).row().wFull().gap(10).itemsCenter().px(4).py(3).rounded(8).bg(theme.block_selected) else ui.div(c).row().wFull().gap(10).itemsCenter().px(4).py(3).rounded(8);
        defer r.end();
        if (r.clicked()) prefs.setTheme("");
        {
            const t = ui.div(c).column().grow().gap(2);
            defer t.end();
            ui.text(c, "System", .{ .size = 13, .weight = .semibold });
            ui.text(c, "Light or dark, as the system is.", .{ .size = 11.5, .color = theme.muted });
        }
        ui.icon(c, "circle.lefthalf.filled", .{ .size = 14, .color = theme.muted });
        if (sel) ui.icon(c, "checkmark", .{ .size = 11, .weight = .bold, .color = theme.accent });
    }
    for (&theme.list) |*e| {
        const sel = std.mem.eql(u8, prefs.theme, e.id);
        const r = if (sel) ui.div(c).row().wFull().gap(10).itemsCenter().px(4).py(3).rounded(8).bg(theme.block_selected) else ui.div(c).row().wFull().gap(10).itemsCenter().px(4).py(3).rounded(8);
        defer r.end();
        if (r.clicked()) prefs.setTheme(e.id);
        {
            const t = ui.div(c).column().grow().gap(2);
            defer t.end();
            ui.text(c, e.name, .{ .size = 13, .weight = .semibold });
            ui.text(c, e.note, .{ .size = 11.5, .color = theme.muted });
        }
        {
            const dots = ui.div(c).row().gap(5).itemsCenter();
            defer dots.end();
            const colors = [5]u24{ e.seeds.background, e.seeds.text, e.seeds.accent, e.seeds.danger, e.seeds.success };
            for (colors) |col| _ = c.leaf(.{ .width = .{ .px = 12 }, .height = .{ .px = 12 }, .radius = 6, .background = ui.Color.hex(col) }, .none, null);
        }
        if (sel) ui.icon(c, "checkmark", .{ .size = 11, .weight = .bold, .color = theme.accent });
    }
    ui.text(c, "The System theme follows the appearance the palette (⌘P) sets.", .{ .size = 11.5, .color = theme.faint, .wrap = true });
}

/// Motion's page: one speed every effect's timing scales by, one amount
/// for how far each goes; Reduce Motion turns them off.
fn motionPage(c: *ui.Context, w: *Workspace) void {
    const s = section(c, "Motion");
    defer s.end();
    const b = box(c);
    defer b.end();
    ui.text(c, "How new output settles in, glyph at a time, and the cursor springs between cells. The system's Reduce Motion turns all of it off.", .{ .size = 12, .color = theme.muted, .wrap = true });
    {
        const r = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer r.end();
        ui.text(c, "Speed", .{ .size = 13 });
        ui.spacer(c);
        var dur = w.shared.prefs.motion_duration;
        if (ui.slider(c, &dur, .{ .min = 0.25, .max = 2, .width = .{ .px = 180 } })) w.shared.prefs.setMotion(dur, w.shared.prefs.motion_intensity);
        ui.text(c, c.print("{d:.2}×", .{w.shared.prefs.motion_duration}), .{ .size = 12.5, .mono = true, .color = theme.muted });
    }
    {
        const r = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer r.end();
        ui.text(c, "Amount", .{ .size = 13 });
        ui.spacer(c);
        var inten = w.shared.prefs.motion_intensity;
        if (ui.slider(c, &inten, .{ .min = 0, .max = 1.5, .width = .{ .px = 180 } })) w.shared.prefs.setMotion(w.shared.prefs.motion_duration, inten);
        ui.text(c, c.print("{d:.2}×", .{w.shared.prefs.motion_intensity}), .{ .size = 12.5, .mono = true, .color = theme.muted });
    }
}

/// Anonymous usage analytics: shared or not, under the privacy policy.
fn privacy(c: *ui.Context, w: *Workspace) void {
    const s = section(c, "Privacy");
    defer s.end();
    const b = box(c);
    defer b.end();
    const an = @import("analytics.zig");
    {
        const r = ui.div(c).row().wFull().gap(10).itemsCenter();
        defer r.end();
        const t = ui.div(c).column().grow().gap(2);
        {
            defer t.end();
            ui.text(c, "Share anonymous usage", .{ .size = 13 });
            ui.text(c, "Which features you use, the app's version and your OS. Never your commands, prompts, files or output.", .{ .size = 11.5, .color = theme.muted, .wrap = true });
        }
        var on = w.shared.prefs.analytics == .on;
        if (ui.toggle(c, "", &on)) w.shared.prefs.setAnalytics(if (on) .on else .off, w.shared.io);
    }
    // The id events carry, to ask for them to be deleted.
    const id = &w.shared.prefs.install_id;
    if (!std.mem.allEqual(u8, id, '0')) ui.text(c, c.print("Install ID: {s}", .{id}), .{ .size = 11.5, .mono = true, .color = theme.muted });
    const links = ui.div(c).row().gap(14);
    defer links.end();
    if (ui.button(c, "Privacy Policy", .{ .variant = .ghost, .size = 11.5, .icon = "hand.raised" }).clicked) _ = nanoui.shell.openUrl(an.privacy_url);
    if (ui.button(c, "Terms", .{ .variant = .ghost, .size = 11.5, .icon = "doc.text" }).clicked) _ = nanoui.shell.openUrl(an.terms_url);
}

/// The phone's relay: off, on the LAN, or over Tailscale — the addresses a
/// phone must be told, and the token it has to say when it connects.
fn relayPage(c: *ui.Context, w: *Workspace) void {
    const p = &w.shared.prefs;
    const s = section(c, "Phone · relay");
    defer s.end();
    {
        const b = box(c);
        defer b.end();
        ui.text(c, "A phone reads this machine's tabs through the relay, and runs in them too.", .{ .size = 12, .color = theme.muted, .wrap = true });

        const order = [_][]const u8{ "Off", "LAN", "Tailscale" };
        var picked: usize = @backingInt(p.relay);
        if (ui.segmented(c, &order, &picked)) {
            p.relay = @as(settings.Relay, @fromBackingInt(@intCast(picked)));
            w.shared.setRelay(p.relay, p.relay_port) catch |err| {
                ui.text(c, c.print("The relay did not start: {s}", .{@errorName(err)}), .{ .size = 11, .color = theme.failure, .wrap = true });
            };
        }

        const h = w.shared.relay;
        const port = if (h) |x| x.port() else p.relay_port;
        ui.text(c, c.print("Port   {d}", .{port}), .{ .size = 12.5 });

        const addr = if (h) |hub|
            if (p.relay == .lan) hub.lan else hub.ts
        else
            "";
        if (addr.len > 0) {
            const line = c.print("{s}:{d}", .{ addr, port });
            ui.text(c, c.print("Open     {s}", .{line}), .{ .size = 12.5, .weight = .semibold });
            if (ui.button(c, "Copy", .{ .size = 12 }).clicked) c.clipboard.write(c.clipboard.ctx, line);
        } else if (p.relay != .off) {
            ui.text(c, "No address found yet.", .{ .size = 12, .color = theme.muted });
        }

        if (h) |hub| {
            const token = relay.Hub.tokenHex(hub);
            ui.text(c, c.print("Token   {s}", .{token}), .{ .size = 12.5, .weight = .semibold });
            if (ui.button(c, "Copy", .{ .size = 12 }).clicked) c.clipboard.write(c.clipboard.ctx, token);
            ui.text(c, "Paste it into the phone's Connect screen.", .{ .size = 11, .color = theme.muted });
        } else if (p.relay == .off) {
            ui.text(c, "The relay is off.", .{ .size = 12, .color = theme.muted });
        }
    }
}

fn threadsPage(c: *ui.Context, w: *Workspace) void {
    const th = &w.shared.threads;
    const kit = nanoui.kit;
    const now = @import("blocks.zig").now();
    const s = section(c, "Github threads");
    defer s.end();
    {
        const b = box(c);
        defer b.end();
        ui.text(c, "Issues, pull requests, mentions, review decisions, failing checks and notifications: whatever you switch on below is what the poll reads. An agent reads each thread in its own tab and proposes a plan; nothing changes until you press Run.", .{ .size = 12, .color = theme.muted, .wrap = true });
        {
            const r = ui.div(c).row().wFull().gap(10).itemsCenter();
            defer r.end();
            const t = ui.div(c).column().grow().gap(2);
            {
                defer t.end();
                ui.text(c, "Watch Github threads", .{ .size = 13 });
                ui.text(c, "Polls with the Github CLI (gh) in the background.", .{ .size = 11.5, .color = theme.muted, .wrap = true });
            }
            var on = th.enabled();
            if (ui.toggle(c, "", &on)) th.setEnabled(on);
        }
        {
            // noop's routines run on their own or wait for approval; a
            // thread here is listed first and read when asked.
            const r = ui.div(c).row().wFull().gap(10).itemsCenter().pt(6);
            defer r.end();
            const t = ui.div(c).column().grow().gap(2);
            {
                defer t.end();
                ui.text(c, "Read new threads as they arrive", .{ .size = 13 });
                ui.text(c, "Off, each waits for Read in the sidebar.", .{ .size = 11.5, .color = theme.muted, .wrap = true });
            }
            var auto = th.autoStart();
            if (ui.toggle(c, "", &auto)) th.setAutoStart(auto);
        }
    }
    watchSources(c, th);
    {
        const b = box(c);
        defer b.end();
        ui.text(c, "Projects", .{ .size = 14, .weight = .semibold });
        ui.text(c, "The repository checkouts gh reads. A folder's tasks start an agent in that folder, and only once gh confirms the repository it holds.", .{ .size = 12, .color = theme.muted, .wrap = true });
        const listed = th.projects();
        if (listed.len == 0) ui.text(c, "No folder is watched yet: add a checkout below.", .{ .size = 12, .color = theme.muted, .wrap = true });
        var remove_at: ?usize = null;
        var switch_at: ?usize = null;
        for (listed, 0..) |p, i| {
            const r = ui.div(c).row().wFull().gap(10).itemsCenter().py(2);
            {
                defer r.end();
                const t = ui.div(c).column().grow().gap(2);
                {
                    defer t.end();
                    if (p.repo.len > 0) {
                        ui.text(c, p.repo, .{ .size = 12.5, .weight = .semibold });
                    } else {
                        ui.text(c, "Checking this folder's repository…", .{ .size = 12.5, .color = theme.muted });
                    }
                    ui.text(c, p.cwd, .{ .size = 11.5, .mono = true, .color = theme.muted, .truncate = .ellipsis });
                    if (!p.verified and p.repo.len > 0 and p.found.len == 0) ui.text(c, "Waiting for gh to confirm this folder.", .{ .size = 11.5, .color = theme.muted, .wrap = true });
                    if (p.found.len > 0) {
                        const h = ui.div(c).row().wFull().gap(8).itemsCenter();
                        defer h.end();
                        ui.text(c, c.print("This folder holds {s}, not {s}.", .{ p.found, p.repo }), .{ .size = 11.5, .color = theme.warning, .wrap = true });
                        if (ui.button(c, c.print("Watch {s}", .{p.found}), .{ .variant = .ghost, .size = 11.5 }).clicked) switch_at = i;
                    }
                }
                if (ui.button(c, "Remove", .{ .variant = .ghost, .size = 12 }).clicked) remove_at = i;
            }
        }
        if (switch_at) |i| if (th.watchFound(i)) th.pollNow();
        if (remove_at) |i| _ = th.removeProject(i);
        {
            const add = ui.div(c).row().wFull().gap(8).itemsCenter();
            defer add.end();
            _ = ui.textField(c, &w.repo_buffer, .{ .placeholder = "/path/to/checkout", .width = .fill });
            if (ui.button(c, "Add folder", .{ .variant = .primary, .size = 12 }).clicked) {
                if (th.addProject(w.repo_buffer.text())) {
                    w.repo_buffer.clear();
                    th.setEnabled(true);
                    th.pollNow();
                }
            }
            if (ui.button(c, "Use focused pane", .{ .variant = .ghost, .size = 12 }).clicked) {
                if (th.watchCurrent()) w.repo_buffer.clear();
            }
            // A poll out at gh says so, and cannot be asked twice.
            const busy = th.checking();
            if (busy) kit.spinner(c, .{ .size = 12 });
            if (ui.button(c, if (busy) "Checking…" else "Check now", .{ .variant = .ghost, .size = 12, .disabled = busy }).clicked) th.pollNow();
        }
        ui.text(c, "Only issues and pull requests from these folders' repositories start an agent. Until gh confirms a folder holds its repository, none do.", .{ .size = 11.5, .color = theme.muted, .wrap = true });
        if (th.errorText().len > 0) ui.text(c, th.errorText(), .{ .size = 11.5, .color = theme.failure, .wrap = true });
    }
    {
        const b = box(c);
        defer b.end();
        ui.text(c, "How often", .{ .size = 14, .weight = .semibold });
        const labels = [_][]const u8{ "1 min", "5 min", "15 min", "30 min", "1 h" };
        const values = [_]u32{ 60, 300, 900, 1800, 3600 };
        var picked: usize = 1;
        for (values, 0..) |v, i| if (th.every() == v) {
            picked = i;
        };
        if (ui.segmented(c, &labels, &picked)) th.setEvery(values[picked]);
        {
            var buf: [16]u8 = undefined;
            const last = th.lastOk();
            const when: []const u8 = if (th.checking())
                "Checking now"
            else if (last <= 0)
                "Not checked yet"
            else if (last > now)
                "Checked just now"
            else
                c.print("Last check {s} ago", .{@import("view_sidebar.zig").ago(&buf, now, last)});
            ui.text(c, c.print("{s}. Reads only what gh reports; Run is the only step that writes.", .{when}), .{ .size = 11.5, .color = theme.muted, .wrap = true });
        }
    }
}

/// What to watch: one switch per `gh` query the poll can run.
fn watchSources(c: *ui.Context, th: *threads_mod.Watcher) void {
    const b = box(c);
    defer b.end();
    const head = ui.div(c).row().wFull().itemsCenter().gap(8);
    {
        defer head.end();
        ui.text(c, "What to watch", .{ .size = 14, .weight = .semibold });
        ui.spacer(c);
        ui.text(c, c.print("{d} of {d} on", .{ th.watchedCount(), threads_mod.Source.all.len }), .{ .size = 11.5, .color = theme.muted });
    }
    sourceRow(c, th, .issues, "Issues assigned to me", "Issues on these repositories that gh says are assigned to you.");
    sourceRow(c, th, .reviews, "Pull requests asking for my review", "Review requests that are still waiting on you.");
    sourceRow(c, th, .assigned_prs, "Pull requests assigned to me", "Pull requests where you are the assignee.");
    sourceRow(c, th, .mentions, "Comments that mention me", "Issues and pull requests where someone mentions you.");
    sourceRow(c, th, .my_reviews, "Review decisions on my pull requests", "Changes requested, or an approval, on the pull requests you opened.");
    sourceRow(c, th, .ci, "Failing checks on my pull requests", "A failing check on a pull request you opened, once per failing run.");
    sourceRow(c, th, .notifications, "Github notifications", "Whatever else gh's unread notification list shows for these repositories.");
}

/// One switch and what it listens for: the switch sits at the row's right
/// edge, the label and hint read from the left, and the whole row toggles.
fn sourceRow(c: *ui.Context, th: *threads_mod.Watcher, source: threads_mod.Source, label: []const u8, hint: []const u8) void {
    var on = th.source(source);
    var toggled = false;
    const row = ui.div(c).row().wFull().gap(12).itemsCenter().py(4).rounded(8).hover(theme.block_hover);
    {
        defer row.end();
        if (row.clicked()) toggled = true;
        const col = ui.div(c).column().grow().gap(2);
        {
            defer col.end();
            ui.text(c, label, .{ .size = 13 });
            ui.text(c, hint, .{ .size = 11.5, .color = theme.muted, .wrap = true });
        }
        if (ui.toggle(c, "", &on)) toggled = true;
    }
    // The switch flips `on` itself; a click elsewhere on the row flips what
    // is saved, and never both.
    if (toggled and on == th.source(source)) on = !on;
    if (on != th.source(source)) th.setSource(source, on);
}

fn updates(c: *ui.Context, w: *Workspace) void {
    const s = section(c, "Updates");
    defer s.end();
    const b = box(c);
    defer b.end();
    const r = ui.div(c).row().wFull().gap(10).itemsCenter();
    defer r.end();
    const u = w.updater orelse {
        ui.text(c, "This build doesn't update itself (it isn't an installed app).", .{ .size = 12.5, .color = theme.muted });
        return;
    };
    {
        const t = ui.div(c).column().grow().gap(2);
        defer t.end();
        ui.text(c, c.print("nanoterm {s}", .{if (u.current.len > 0) u.current else "dev"}), .{ .size = 13.5, .weight = .semibold });
        const note: []const u8 = if (u.ready()) |v| c.print("Version {s} is ready to install.", .{v}) else if (u.checking()) "Checking for updates…" else switch (u.phase.load(.acquire)) {
            .installed => "Updated: it runs from the next launch.",
            else => "Checks for updates every few hours, and installs them when you quit.",
        };
        ui.text(c, note, .{ .size = 12, .color = theme.muted, .wrap = true });
    }
    if (u.ready() != null) {
        if (ui.button(c, "Restart to update", .{ .variant = .primary, .size = 12 }).clicked) if (u.restart()) w.nanoapp.quit();
    } else if (ui.button(c, "Check now", .{ .size = 12 }).clicked) u.checkNow();
}
