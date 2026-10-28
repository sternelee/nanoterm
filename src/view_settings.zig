//! Settings (⌘,): built-in Agent providers, MCP and Skills, the agents
//! Harness ships (installed or not, the one new tabs
//! start with, an installer run in a new tab), appearance, text size,
//! updates, and about.
const std = @import("std");
const nanoui = @import("nanoui");
const ui = nanoui.ui;
const theme = @import("theme.zig");
const agents = @import("agents.zig");
const agent_mod = @import("agent.zig");
const Workspace = @import("workspace.zig").Workspace;

pub fn card(c: *ui.Context, w: *Workspace) void {
    const panel = ui.div(c).column().w(@min(680, c.size.w - 40)).bg(theme.panel).rounded(14).border(theme.border).shadowLg().clip();
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
    // As tall as it is, up to the window's room; then it scrolls.
    const body = ui.div(c).column().wFull().scrollY().maxH(c.size.h - 170).px(20).pb(20).gap(18);
    defer body.end();
    agentList(c, w);
    account(c, w);
    look(c, w);
    privacy(c, w);
    updates(c, w);
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
            ui.text(c, "Custom OpenAI-compatible providers, with their model and optional bearer token variable.", .{ .size = 12, .color = theme.muted, .wrap = true });
            for (store.providers.items) |*provider| {
                const open = kit.collapsible(
                    c,
                    c.print("provider-{s}", .{provider.name}),
                    if (provider.selected) c.print("{s} · selected", .{provider.name}) else provider.name,
                    &provider.open,
                ) orelse continue;
                defer open.end();
                ui.text(c, c.print("{s} · {s}", .{ provider.base_url, provider.model }), .{ .size = 11.5, .color = theme.muted, .wrap = true });
                if (provider.auth_env.len > 0) ui.text(c, c.print("Token variable: {s}", .{provider.auth_env}), .{ .size = 11, .color = theme.faint });
                const actions = ui.div(c).row().wFull().gap(8);
                defer actions.end();
                if (!provider.selected and ui.button(c, "Select", .{ .size = 12 }).clicked) {
                    store.selectProvider(provider.*);
                    syncAgentModel(w);
                    // selectProvider reloads the list this loop borrows from.
                    break;
                }
                if (ui.button(c, "Remove", .{ .variant = .ghost, .size = 12 }).clicked) {
                    const name = c.gpa.dupe(u8, provider.name) catch break;
                    defer c.gpa.free(name);
                    store.removeProvider(name);
                    syncAgentModel(w);
                    break;
                }
            }
            if (store.providers.items.len == 0) ui.text(c, "No custom providers yet.", .{ .size = 11.5, .color = theme.faint });
            if (kit.collapsible(c, "provider-add", "Add provider", &store.provider_form_open)) |open| {
                defer open.end();
                _ = ui.textField(c, &store.provider_name, .{ .placeholder = "Provider id (for example local)", .width = .fill });
                _ = ui.textField(c, &store.provider_url, .{ .placeholder = "Base URL, including /v1/", .width = .fill });
                _ = ui.textField(c, &store.provider_model, .{ .placeholder = "Model", .width = .fill });
                _ = ui.textField(c, &store.provider_auth_env, .{ .placeholder = "Bearer token environment variable (optional)", .width = .fill });
                if (ui.button(c, "Save and select provider", .{ .variant = .primary, .size = 12 }).clicked) {
                    store.saveProvider();
                    syncAgentModel(w);
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

fn look(c: *ui.Context, w: *Workspace) void {
    const s = section(c, "Appearance");
    defer s.end();
    const b = box(c);
    defer b.end();
    {
        const r = ui.div(c).row().wFull().itemsCenter();
        defer r.end();
        ui.text(c, "Theme", .{ .size = 13 });
        ui.spacer(c);
        const names = [_][]const u8{ "System", "Light", "Dark" };
        const order = [_]@TypeOf(w.shared.appearance){ .system, .light, .dark };
        var picked: usize = std.mem.indexOfScalar(@TypeOf(w.shared.appearance), &order, w.shared.appearance) orelse 0;
        if (ui.segmented(c, &names, &picked)) w.shared.setAppearance(order[picked]);
    }
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
        defer t.end();
        ui.text(c, "File icons in ls", .{ .size = 13 });
        ui.text(c, "A Nerd Font icon before each file an ls prints: folders, pictures, archives, programs.", .{ .size = 11.5, .color = theme.muted, .wrap = true });
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
