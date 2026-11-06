//! Github threads nanoterm watches: whatever the switches in Settings →
//! Threads say — issues, review requests, assigned pull requests, mentions,
//! review decisions on your own pull requests, their failing checks, and
//! notifications. A poll (a short thread, as the updater's checks are)
//! reads them through `gh`, figures out what is new, and hands each one
//! to an agent in a tab of its own. The agent reads and proposes; nothing
//! is changed until you press Run in the sidebar, which starts a branch
//! for that thread and asks the agent to do the work. Like noop's
//! `triage-inbound`: dedupe, route, and leave the decisions to you.
const std = @import("std");
const nanoui = @import("nanoui");
const agent_mod = @import("agent.zig");
const agents = @import("agents.zig");
const blocks = @import("blocks.zig");
const proc = @import("proc.zig");

pub const Kind = enum { issue, pr, ci };

/// What the watcher listens for: one switch in Settings → Threads each, and
/// one `gh` query (or the notification list) on every poll.
pub const Source = enum {
    /// Issues assigned to you.
    issues,
    /// Pull requests asking for your review.
    reviews,
    /// Pull requests assigned to you.
    assigned_prs,
    /// Issues and pull requests where someone mentions you.
    mentions,
    /// Review decisions on the pull requests you opened: changes requested,
    /// or an approval.
    my_reviews,
    /// Failing checks on the pull requests you opened.
    ci,
    /// Unread Github notifications, filtered to the watched repositories.
    notifications,

    pub const all = std.enums.values(Source);
};

pub const State = enum {
    /// Found, waiting for its analysis turn.
    queued,
    /// The reading turn is open.
    analyzing,
    /// The agent proposed a plan; Run starts it.
    proposed,
    /// You approved it: the agent is working on a branch.
    running,
    done,
    failed,
    /// Put away; a newer version of it comes back.
    dismissed,
};

pub const Thread = struct {
    id: u64 = 0,
    key: []u8,
    kind: Kind,
    number: u32,
    title: []u8,
    url: []u8,
    updated: []u8 = &.{},
    /// What makes this version different: updatedAt, or CI's failing checks.
    fingerprint: []u8 = &.{},
    state: State = .queued,
    branch: []u8 = &.{},
    /// What the agent proposed (the analysis turn's answer).
    proposal: []u8 = &.{},
    /// Why it failed, or what happened to it.
    note: []u8 = &.{},
    /// The tab doing its work, 0 when none (or after a restart).
    session: u64 = 0,
    created: f64 = 0,
    changed: f64 = 0,
    seen: bool = false,
    /// Asked for by hand, as the switch that starts agents automatically is
    /// off: the poll queues it and this thread says to read it anyway.
    asked: bool = false,
    /// The proposal's tail, as the prompt asks the agent to write it: one line
    /// of plan, how many files it would touch, the command that proves it, and
    /// the one question it wants answered (empty when it has none).
    plan: []u8 = &.{},
    files: u32 = 0,
    verify: []u8 = &.{},
    question: []u8 = &.{},

    fn deinit(t: *Thread, gpa: std.mem.Allocator) void {
        gpa.free(t.key);
        gpa.free(t.title);
        gpa.free(t.url);
        freeIf(gpa, t.updated);
        freeIf(gpa, t.fingerprint);
        freeIf(gpa, t.branch);
        freeIf(gpa, t.proposal);
        freeIf(gpa, t.note);
        freeIf(gpa, t.plan);
        freeIf(gpa, t.verify);
        freeIf(gpa, t.question);
    }

    pub fn label(t: *const Thread) []const u8 {
        return switch (t.kind) {
            .issue => "Issue",
            .pr => "PR",
            .ci => "CI",
        };
    }

    /// "#42": the number as a thread reads.
    pub fn numberLabel(t: *const Thread, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "#{d}", .{t.number}) catch "";
    }
};

/// The tail a proposal ends with, as the prompt asks for it:
///
///     plan: what it would do, in one line
///     files: src/a.zig, src/b.zig      (or `none`)
///     verify: zig build test
///     question: none                   (or the one thing it must ask)
///
/// Borrowed from the reply unless the Watcher copies it into a Thread.
pub const Plan = struct {
    plan: []const u8 = "",
    files: u32 = 0,
    verify: []const u8 = "",
    question: []const u8 = "",

    pub fn of(reply: []const u8) Plan {
        var out: Plan = .{};
        var lines = std.mem.splitScalar(u8, reply, '\n');
        while (lines.next()) |raw| {
            const line = clean(raw);
            if (after(line, "plan:")) |v| {
                out.plan = orNothing(v);
            } else if (after(line, "files:")) |v| {
                out.files = countFiles(v);
            } else if (after(line, "verify:")) |v| {
                out.verify = orNothing(v);
            } else if (after(line, "question:")) |v| {
                out.question = orNothing(v);
            }
        }
        return out;
    }

    /// A line of the tail without the markdown around it, so `- **plan:** …`,
    /// `1. plan: …` and `### plan: …` all read as `plan: …`.
    fn clean(raw: []const u8) []const u8 {
        var line = std.mem.trim(u8, raw, " \t\r");
        for ([_][]const u8{ "#", ">", "- ", "* ", "+ " }) |mark| {
            if (std.mem.startsWith(u8, line, mark)) {
                line = std.mem.trimStart(u8, line[mark.len..], " ");
                break;
            }
        }
        var digits: usize = 0;
        while (digits < line.len and std.ascii.isDigit(line[digits])) digits += 1;
        if (digits > 0 and digits < line.len and (line[digits] == '.' or line[digits] == ')')) {
            line = std.mem.trimStart(u8, line[digits + 1 ..], " ");
        }
        return std.mem.trim(u8, line, " \t`*_");
    }

    /// `none` is how an agent says there is nothing to say.
    fn orNothing(value: []const u8) []const u8 {
        if (value.len == 0 or std.mem.eql(u8, value, "-")) return "";
        if (std.ascii.eqlIgnoreCase(value, "none")) return "";
        return value;
    }

    /// The text after `key`, or null when the line does not start with it.
    fn after(line: []const u8, key: []const u8) ?[]const u8 {
        if (line.len < key.len) return null;
        if (!std.ascii.eqlIgnoreCase(line[0..key.len], key)) return null;
        return std.mem.trim(u8, line[key.len..], " \t`*_");
    }

    /// "src/a.zig, src/b.zig" is two; "none", or nothing, is nil.
    fn countFiles(value: []const u8) u32 {
        var n: u32 = 0;
        var paths = std.mem.splitScalar(u8, value, ',');
        while (paths.next()) |path| {
            const one = std.mem.trim(u8, path, " \t`()");
            if (one.len == 0 or std.ascii.eqlIgnoreCase(one, "none")) continue;
            n += 1;
        }
        return n;
    }
};

fn freeIf(gpa: std.mem.Allocator, s: []u8) void {
    if (s.len > 0) gpa.free(s);
}

/// Sets an owned string field, freeing what it held.
fn set(gpa: std.mem.Allocator, field: *[]u8, text: []const u8) void {
    const copy: []u8 = if (text.len == 0) &.{} else gpa.dupe(u8, text) catch return;
    freeIf(gpa, field.*);
    field.* = copy;
}

/// A checkout whose repository the watcher reads: the folder a task's tab
/// works in, and the repo `gh` says it holds.
pub const Project = struct {
    cwd: []u8 = &.{},
    /// The repository watched in `cwd`; empty until a poll has asked gh.
    repo: []u8 = &.{},
    /// gh confirmed `cwd` holds `repo`; only then may an agent be called.
    verified: bool = false,
    /// What gh found when it is not `repo`: the person may switch to it.
    found: []u8 = &.{},

    fn deinit(p: *Project, gpa: std.mem.Allocator) void {
        freeIf(gpa, p.cwd);
        freeIf(gpa, p.repo);
        freeIf(gpa, p.found);
    }
};

/// What the watcher reads, and how often: kept in threads.json with the
/// threads themselves.
pub const Config = struct {
    enabled: bool = false,
    every_seconds: u32 = 5 * 60,
    issues: bool = true,
    reviews: bool = true,
    assigned_prs: bool = true,
    mentions: bool = true,
    my_reviews: bool = true,
    ci: bool = true,
    notifications: bool = true,
    /// Whether a thread that arrives is read at once. Off, the poll lists it
    /// and the person asks for its plan (the sidebar's Read), as noop's
    /// routines may wait for approval.
    auto_start: bool = true,
    /// How many turns the watcher may start in any hour, all threads
    /// together. noop budgets a routine by the hour; a night of retries that
    /// reads the same issue again and again costs the person money.
    turns_per_hour: u32 = 12,
    /// The checkouts watched, each with the repository it holds.
    projects: std.ArrayListUnmanaged(Project) = .empty,

    fn deinit(c: *Config, gpa: std.mem.Allocator) void {
        for (c.projects.items) |*p| p.deinit(gpa);
        c.projects.deinit(gpa);
    }
};

/// What the watcher needs from the window: a tab to work in, a way to ask
/// its agent, and where the person is looking. workspace.zig supplies it.
/// Which turn a thread's tab is asked: a reading turn reads, so the tab's
/// agent may read; a working one edits this checkout, and only this one.
pub const Mode = enum { read, work };

pub const Host = struct {
    ctx: *anyopaque,
    /// A background tab in `cwd`, asked `prompt`; its session id, or null.
    start: *const fn (ctx: *anyopaque, cwd: []const u8, thread: u64, mode: Mode, heading: []const u8, prompt: []const u8) ?u64,
    /// Ask the tab's agent a follow-up; false when the tab is gone.
    ask: *const fn (ctx: *anyopaque, session: u64, mode: Mode, heading: []const u8, prompt: []const u8) bool,
    /// Focus the thread's tab.
    focus: *const fn (ctx: *anyopaque, session: u64) bool,
    /// Close the thread's tab without asking, as a finished thread has no
    /// reason to keep one open.
    close: *const fn (ctx: *anyopaque, session: u64) void,
    /// Whether the tab still exists.
    alive: *const fn (ctx: *anyopaque, session: u64) bool,
    /// The focused pane's directory: the repository to watch by default.
    cwd: *const fn (ctx: *anyopaque) []const u8,
    redraw: *const fn (ctx: *anyopaque) void,
};

/// The largest proposal kept (the turn itself lives in the session log).
const proposal_max = 16 * 1024;
const note_max = 600;

pub const Watcher = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    home: []const u8,
    path: []u8 = &.{},
    cfg: Config = .{},
    threads: std.ArrayListUnmanaged(Thread) = .empty,
    next_id: u64 = 1,
    /// A poll, an analysis, or an approved run is at work: one each, in
    /// order, so threads never fight over the checkout.
    working: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// A poll is out asking gh: what "Checking…" shows while it waits.
    polling: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    active_analysis: u64 = 0,
    active_run: u64 = 0,
    /// When this hour's turns were started, oldest first: the budget's ledger.
    turns: std.ArrayListUnmanaged(f64) = .empty,
    started: bool = false,
    last_check: f64 = 0,
    last_ok: f64 = 0,
    last_error: []u8 = &.{},
    /// The app's environment, including the tool folders a Finder launch
    /// would leave off PATH, for Thread child processes.
    env: ?*const std.process.Environ.Map = null,
    app: ?*nanoui.App = null,
    host: ?Host = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, home: []const u8) Watcher {
        return initWithEnv(gpa, io, home, null);
    }

    pub fn initWithEnv(gpa: std.mem.Allocator, io: std.Io, home: []const u8, env: ?*const std.process.Environ.Map) Watcher {
        var s: Watcher = .{ .gpa = gpa, .io = io, .home = home, .env = env };
        s.path = std.fs.path.join(gpa, &.{ home, "Library", "Application Support", "nanoterm", "threads.json" }) catch "";
        s.load();
        return s;
    }

    /// `argv` for a tool child process. Zig resolves `argv[0]` from the OS
    /// environment even when `environ_map` is passed, so give the child the
    /// absolute path found on the app's augmented PATH.
    fn toolArgv(self: *Watcher, a: std.mem.Allocator, argv: []const []const u8) []const []const u8 {
        if (argv.len == 0) return argv;
        const out = a.alloc([]const u8, argv.len) catch return argv;
        @memcpy(out[1..], argv[1..]);
        out[0] = argv[0];
        if (self.env) |env| {
            const path = agents.searchPath(a, env.get("PATH") orelse "", self.home);
            if (proc.which(a, self.io, path, argv[0])) |exe| out[0] = exe;
        }
        return out;
    }

    pub fn deinit(self: *Watcher) void {
        // A poll's thread is still at work while the app ends: its job is
        // leaked, as the updater's is.
        if (self.working.load(.acquire)) return;
        for (self.threads.items) |*t| t.deinit(self.gpa);
        self.threads.deinit(self.gpa);
        self.turns.deinit(self.gpa);
        self.cfg.deinit(self.gpa);
        freeIf(self.gpa, self.last_error);
        freeIf(self.gpa, self.path);
    }

    /// Points the watcher at the window and starts its clock. Call once,
    /// after the workspace exists.
    pub fn bind(self: *Watcher, host: Host, app: *nanoui.App) void {
        self.host = host;
        self.app = app;
        if (self.started) return;
        self.started = true;
        nanoui.App.after(4_000, self, tick);
    }

    fn tick(ctx: ?*anyopaque) callconv(.c) void {
        const self: *Watcher = @ptrCast(@alignCast(ctx.?));
        self.reap();
        if (self.cfg.enabled) self.poll(false);
        const secs: u64 = @max(30, self.cfg.every_seconds);
        nanoui.App.after(secs * 1000, self, tick);
    }

    // ---------------------------------------------------------------- reading

    fn poll(self: *Watcher, force: bool) void {
        if (self.working.load(.acquire)) return;
        if (!force and self.last_check > 0 and blocks.now() - self.last_check < 15) return;
        const job = self.gpa.create(Job) catch return;
        job.* = .{ .owner = self, .arena = .init(self.gpa), .io = self.io };
        const a = job.arena.allocator();
        const plan = a.alloc(JobProject, self.cfg.projects.items.len) catch {
            job.destroy();
            return;
        };
        for (self.cfg.projects.items, 0..) |p, i| plan[i] = .{
            .cwd = a.dupe(u8, p.cwd) catch "",
            .repo = a.dupe(u8, p.repo) catch "",
            .check = !p.verified,
        };
        job.projects = plan;
        job.want = self.watched();
        // Only now is it work: from here on a poll is out, and the pane
        // shows it until adopt takes what it found.
        self.working.store(true, .release);
        self.polling.store(true, .release);
        const th = std.Thread.spawn(.{}, Job.run, .{job}) catch {
            job.destroy();
            self.working.store(false, .release);
            self.polling.store(false, .release);
            return;
        };
        th.detach();
        if (self.host) |h| h.redraw(h.ctx);
    }

    /// From the poll's thread, on the main thread: take what it found.
    fn adopt(ctx: ?*anyopaque) callconv(.c) void {
        const job: *Job = @ptrCast(@alignCast(ctx.?));
        const self = job.owner;
        self.working.store(false, .release);
        self.polling.store(false, .release);
        const now = blocks.now();
        self.last_check = now;
        var first_error: ?[]const u8 = if (job.errors.items.len > 0) job.errors.items[0] else null;
        for (job.projects) |jp| {
            const p = self.projectByCwdMutable(jp.cwd) orelse continue;
            if (jp.found.len > 0 and !jp.checked) {
                // The folder holds another repository: the one chosen stays,
                // and the person may switch to what is there.
                set(self.gpa, &p.found, jp.found);
                p.verified = false;
                continue;
            }
            if (!jp.checked or jp.repo.len == 0) continue;
            if (!std.mem.eql(u8, p.repo, jp.repo) and self.otherProjectHasRepo(p, jp.repo)) {
                set(self.gpa, &p.repo, jp.repo);
                p.verified = false;
                if (first_error == null) first_error = "that repository is already watched from another folder";
                continue;
            }
            if (!std.mem.eql(u8, p.repo, jp.repo)) set(self.gpa, &p.repo, jp.repo);
            p.verified = true;
            freeIf(self.gpa, p.found);
            p.found = &.{};
        }
        if (first_error) |e| {
            set(self.gpa, &self.last_error, e);
        } else {
            self.last_ok = now;
            freeIf(self.gpa, self.last_error);
            self.last_error = &.{};
        }
        for (job.items.items) |item| self.absorb(item, now);
        self.save();
        self.pump();
        if (self.host) |h| h.redraw(h.ctx);
        job.destroy();
    }

    /// A new item, or a newer version of one already known.
    fn absorb(self: *Watcher, it: Item, now: f64) void {
        if (self.findKey(it.key)) |t| {
            set(self.gpa, &t.title, it.title);
            set(self.gpa, &t.url, it.url);
            set(self.gpa, &t.updated, it.updated);
            if (!std.mem.eql(u8, t.fingerprint, it.fingerprint)) {
                set(self.gpa, &t.fingerprint, it.fingerprint);
                // Finished or put away, and the GitHub side moved: read it
                // again. One being read or run keeps its turn.
                switch (t.state) {
                    .done, .failed, .dismissed => {
                        t.state = .queued;
                        t.changed = now;
                        // A row that came back has to say why it did.
                        set(self.gpa, &t.note, "it moved on Github: reading it again");
                    },
                    else => {},
                }
            }
            return;
        }
        const t: Thread = .{
            .id = self.next_id,
            .key = self.gpa.dupe(u8, it.key) catch return,
            .kind = it.kind,
            .number = it.number,
            .title = self.gpa.dupe(u8, it.title) catch return,
            .url = self.gpa.dupe(u8, it.url) catch return,
            .updated = if (it.updated.len > 0) self.gpa.dupe(u8, it.updated) catch &.{} else &.{},
            .fingerprint = if (it.fingerprint.len > 0) self.gpa.dupe(u8, it.fingerprint) catch &.{} else &.{},
            .created = now,
            .changed = now,
        };
        self.threads.append(self.gpa, t) catch {
            var owned = t;
            owned.deinit(self.gpa);
            return;
        };
        self.next_id += 1;
        self.evict();
    }

    /// Keeps the ledger bounded: the oldest finished or dismissed go first.
    fn evict(self: *Watcher) void {
        while (self.threads.items.len > 200) {
            var at: ?usize = null;
            for (self.threads.items, 0..) |t, i| {
                if (t.state != .done and t.state != .dismissed) continue;
                if (at == null or t.changed < self.threads.items[at.?].changed) at = i;
            }
            var t = self.threads.orderedRemove(at orelse return);
            t.deinit(self.gpa);
        }
    }

    /// A thread whose tab was closed: the person cancelled it, they did not
    /// ask it to fail.
    pub fn reap(self: *Watcher) void {
        const h = self.host orelse return;
        for (self.threads.items) |*t| {
            if (t.state != .analyzing and t.state != .running) continue;
            if (t.session != 0 and h.alive(h.ctx, t.session)) continue;
            if (self.active_analysis == t.id) self.active_analysis = 0;
            if (self.active_run == t.id) self.active_run = 0;
            t.state = .dismissed;
            t.session = 0;
            set(self.gpa, &t.note, "cancelled: its tab was closed");
            t.changed = blocks.now();
        }
    }

    // ---------------------------------------------------------------- agents

    /// The next thread waiting for a reading turn gets one. One at a time:
    /// the tabs may share a checkout.
    fn pump(self: *Watcher) void {
        if (self.active_analysis != 0) return;
        const h = self.host orelse return;
        if (self.atLimit()) return;
        for (self.threads.items) |*t| {
            if (t.state != .queued) continue;
            // The poll only lists what it found when agents start on their
            // own; otherwise the person asks for this one's plan.
            if (!self.cfg.auto_start and !t.asked) continue;
            const p = self.projectFor(threadRepo(t)) orelse continue;
            if (!p.verified) continue;
            const text = self.prompt(t, .analysis, p, p.cwd) catch continue;
            defer self.gpa.free(text);
            const label_text = self.heading(t) catch continue;
            defer self.gpa.free(label_text);
            t.state = .analyzing;
            t.asked = false;
            t.changed = blocks.now();
            if (t.session != 0 and h.alive(h.ctx, t.session)) {
                if (!h.ask(h.ctx, t.session, .read, label_text, text)) {
                    self.failed(t, "its tab is gone");
                    continue;
                }
            } else {
                t.session = h.start(h.ctx, p.cwd, t.id, .read, label_text, text) orelse 0;
                if (t.session == 0) {
                    self.failed(t, "the agent tab could not start");
                    continue;
                }
            }
            self.active_analysis = t.id;
            self.spend();
            self.save();
            return;
        }
    }

    /// Run (or finish) a reading or working turn: the session's agent said
    /// what it did.
    pub fn turnFinished(self: *Watcher, session: u64, turn: *agent_mod.Turn, did_fail: bool) void {
        var found: ?*Thread = null;
        for (self.threads.items) |*t| {
            if (t.session == session) {
                found = t;
                break;
            }
        }
        const t = found orelse return;
        const now = blocks.now();
        const reply: []u8 = turnReply(self.gpa, turn) catch return;
        defer self.gpa.free(reply);
        switch (t.state) {
            .analyzing => {
                if (self.active_analysis == t.id) self.active_analysis = 0;
                if (did_fail or reply.len == 0) {
                    self.failed(t, if (did_fail) "the reading turn failed" else "the agent said nothing");
                } else {
                    set(self.gpa, &t.proposal, reply[0..@min(reply.len, proposal_max)]);
                    const plan = Plan.of(reply);
                    set(self.gpa, &t.plan, plan.plan);
                    set(self.gpa, &t.verify, plan.verify);
                    set(self.gpa, &t.question, plan.question);
                    t.files = plan.files;
                    t.state = .proposed;
                    t.seen = false;
                    t.changed = now;
                }
            },
            .running => {
                if (self.active_run == t.id) self.active_run = 0;
                t.state = if (did_fail) .failed else .done;
                if (did_fail) set(self.gpa, &t.note, "the working turn failed");
                t.seen = false;
                t.changed = now;
            },
            else => return,
        }
        self.save();
        self.pump();
        if (self.host) |h| h.redraw(h.ctx);
    }

    /// The worktree a working turn edits: `<project>/.nanoterm/worktrees/<thread>`,
    /// on the thread's branch. Made once per thread; a second approval of the
    /// same thread carries on in the worktree the first one left behind.
    fn worktree(self: *Watcher, t: *Thread, p: *const Project) ?[]u8 {
        var name_buf: [24]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{d}", .{t.id}) catch return null;
        const path = std.fs.path.join(self.gpa, &.{ p.cwd, ".nanoterm", "worktrees", name }) catch return null;
        const dir = std.Io.Dir.cwd();
        if (dir.access(self.io, path, .{})) |_| {
            // A folder left by an older branch, or emptied by hand, is made
            // again rather than trusted for the worktree it is not.
            if (self.isWorktree(path, t.branch)) return path;
            dir.deleteTree(self.io, path) catch {
                self.failed(t, "the worktree left behind could not be cleared");
                self.gpa.free(path);
                return null;
            };
        } else |_| {}

        self.exclude(p.cwd);
        if (std.fs.path.dirname(path)) |base| dir.createDirPath(self.io, base) catch {
            self.failed(t, "the worktree folder could not be made");
            self.gpa.free(path);
            return null;
        };

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        // `-b` makes the branch; when a branch of that name is already there,
        // a plain `worktree add` checks it out instead.
        if (!self.git(a, t, p.cwd, &.{ "git", "-C", p.cwd, "worktree", "add", path, "-b", t.branch })) {
            if (!self.git(a, t, p.cwd, &.{ "git", "-C", p.cwd, "worktree", "add", path, t.branch })) {
                self.gpa.free(path);
                return null;
            }
            set(self.gpa, &t.note, "");
        }
        return path;
    }

    /// Whether `path` is a worktree checked out on `branch`, which is what a
    /// folder left from an earlier approval has to be to be carried on with.
    fn isWorktree(self: *Watcher, path: []const u8, branch: []const u8) bool {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const a = arena_state.allocator();
        const result = std.process.run(a, self.io, .{
            .argv = self.toolArgv(a, &.{ "git", "-C", path, "rev-parse", "--abbrev-ref", "HEAD" }),
            .environ_map = self.env,
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
            .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(30), .clock = .boot } },
        }) catch return false;
        if (!result.term.success()) return false;
        return std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \t\r\n"), branch);
    }

    /// Runs git in the person's own checkout. False, with git's first line of
    /// complaint in the thread's note, when it fails.
    fn git(self: *Watcher, a: std.mem.Allocator, t: *Thread, cwd: []const u8, argv: []const []const u8) bool {
        _ = cwd;
        const result = std.process.run(a, self.io, .{
            .argv = self.toolArgv(a, argv),
            .environ_map = self.env,
            .stdout_limit = .limited(1024 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(120), .clock = .boot } },
        }) catch |err| {
            if (std.fmt.allocPrint(self.gpa, "git failed: {s}", .{@errorName(err)})) |why| {
                set(self.gpa, &t.note, why);
                self.gpa.free(why);
            } else |_| set(self.gpa, &t.note, "git failed");
            return false;
        };
        if (!result.term.success()) {
            const text = std.mem.trim(u8, result.stderr, " \t\r\n");
            const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
            set(self.gpa, &t.note, if (line.len > 0) line else "git returned an error");
            return false;
        }
        return true;
    }

    /// Keeps `.nanoterm/` out of the project's own `git status`: the entry goes
    /// into the checkout's `.git/info/exclude`, which is nobody else's business.
    fn exclude(self: *Watcher, repo_cwd: []const u8) void {
        var buf: [4096]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/.git/info/exclude", .{repo_cwd}) catch return;
        const dir = std.Io.Dir.cwd();
        const old = dir.readFileAlloc(self.io, path, self.gpa, .limited(64 * 1024)) catch "";
        defer if (old.len > 0) self.gpa.free(old);
        if (std.mem.indexOf(u8, old, ".nanoterm/") != null) return;
        // Written whole: the file is the checkout's own, kept as it was with
        // one line more, rather than overwritten from its first byte.
        const text = std.fmt.allocPrint(self.gpa, "{s}\n.nanoterm/\n", .{std.mem.trimEnd(u8, old, "\r\n")}) catch return;
        defer self.gpa.free(text);
        dir.writeFile(self.io, .{ .sub_path = path, .data = text }) catch return;
    }

    fn failed(self: *Watcher, t: *Thread, why: []const u8) void {
        t.state = .failed;
        set(self.gpa, &t.note, why);
        t.changed = blocks.now();
    }

    /// You approved a proposal: the agent works on a branch for it.
    pub fn run(self: *Watcher, id: u64) bool {
        const t = self.findId(id) orelse return false;
        if (t.state != .proposed or self.active_run != 0) return false;
        if (self.atLimit()) {
            set(self.gpa, &t.note, "the hour's turns are spent; it waits for the next one");
            if (self.host) |h| h.redraw(h.ctx);
            return false;
        }
        const p = self.projectFor(threadRepo(t)) orelse return false;
        if (!p.verified) return false;
        const h = self.host orelse return false;
        var branch_buf: [96]u8 = undefined;
        set(self.gpa, &t.branch, branchFor(t, &branch_buf));
        // A worktree of its own, inside the project: the person's checkout is
        // theirs, and the thread's work is a branch they can look at later.
        const at = self.worktree(t, p) orelse return false;
        defer self.gpa.free(at);
        const text = self.prompt(t, .work, p, at) catch return false;
        defer self.gpa.free(text);
        const label_text = self.heading(t) catch return false;
        defer self.gpa.free(label_text);
        // The reading tab sits in the person's own checkout: the work goes on
        // in a tab of its own, in the worktree, so no prompt is left half done
        // and nothing edits the checkout the person is looking at.
        if (t.session != 0) {
            if (h.alive(h.ctx, t.session)) h.close(h.ctx, t.session);
            t.session = 0;
        }
        t.state = .running;
        t.changed = blocks.now();
        t.session = h.start(h.ctx, at, t.id, .work, label_text, text) orelse 0;
        if (t.session == 0) {
            self.failed(t, "the agent tab could not start");
            self.save();
            return false;
        }
        // A turn is spent when it has somewhere to run.
        self.spend();
        self.active_run = t.id;
        self.save();
        if (self.host) |x| x.redraw(x.ctx);
        return true;
    }

    pub fn dismiss(self: *Watcher, id: u64) void {
        const t = self.findId(id) orelse return;
        // A working thread is ended by closing its tab, which `reap` sees.
        if (t.state == .analyzing or t.state == .running) return;
        t.state = .dismissed;
        t.changed = blocks.now();
        // The thread is gone: so is the tab that showed it. Its transcript
        // stays in the session log, where the log viewer finds it.
        self.closeSession(t);
        self.save();
        if (self.host) |h| h.redraw(h.ctx);
    }

    /// Takes the thread's tab away, if one is still open.
    fn closeSession(self: *Watcher, t: *Thread) void {
        if (t.session == 0) return;
        const h = self.host orelse {
            t.session = 0;
            return;
        };
        h.close(h.ctx, t.session);
        t.session = 0;
    }

    /// Focus the thread's tab, if it has one.
    pub fn focus(self: *Watcher, id: u64) bool {
        const t = self.findId(id) orelse return false;
        const h = self.host orelse return false;
        if (t.session == 0) return false;
        return h.focus(h.ctx, t.session);
    }

    /// The person looked at the thread: its row is no longer unread, and
    /// its tab comes forward.
    pub fn open(self: *Watcher, id: u64) bool {
        const t = self.findId(id) orelse return false;
        if (!t.seen) {
            t.seen = true;
            self.save();
        }
        return self.focus(id);
    }

    // ---------------------------------------------------------------- settings

    pub fn setEnabled(self: *Watcher, on: bool) void {
        if (self.cfg.enabled == on) return;
        self.cfg.enabled = on;
        self.save();
        if (on) {
            freeIf(self.gpa, self.last_error);
            self.last_error = &.{};
            self.poll(true);
        }
        if (self.host) |h| h.redraw(h.ctx);
    }

    // ---------------------------------------------------------------- projects

    pub fn projects(self: *const Watcher) []const Project {
        return self.cfg.projects.items;
    }

    pub fn projectAt(self: *Watcher, index: usize) ?*Project {
        if (index >= self.cfg.projects.items.len) return null;
        return &self.cfg.projects.items[index];
    }

    /// Adds a folder to watch. Its repository is learned by the next poll;
    /// until then its tasks show but cannot start an agent.
    pub fn addProject(self: *Watcher, text: []const u8) bool {
        var buf: [4096]u8 = undefined;
        const dir = expandPath(self.home, text, &buf) orelse {
            set(self.gpa, &self.last_error, "use an absolute folder path, or one starting with ~/");
            if (self.host) |h| h.redraw(h.ctx);
            return false;
        };
        var opened = std.Io.Dir.openDirAbsolute(self.io, dir, .{}) catch {
            set(self.gpa, &self.last_error, "that folder is not there");
            if (self.host) |h| h.redraw(h.ctx);
            return false;
        };
        opened.close(self.io);
        if (self.projectByCwd(dir) != null) {
            set(self.gpa, &self.last_error, "that folder is already watched");
            if (self.host) |h| h.redraw(h.ctx);
            return false;
        }
        const cwd = self.gpa.dupe(u8, dir) catch return false;
        self.cfg.projects.append(self.gpa, .{ .cwd = cwd }) catch {
            self.gpa.free(cwd);
            return false;
        };
        freeIf(self.gpa, self.last_error);
        self.last_error = &.{};
        self.save();
        if (self.host) |h| h.redraw(h.ctx);
        return true;
    }

    pub fn removeProject(self: *Watcher, index: usize) bool {
        if (index >= self.cfg.projects.items.len) return false;
        var p = self.cfg.projects.orderedRemove(index);
        p.deinit(self.gpa);
        self.save();
        if (self.host) |h| h.redraw(h.ctx);
        return true;
    }

    /// Watch the focused pane's folder, from now on.
    pub fn watchCurrent(self: *Watcher) bool {
        const h = self.host orelse return false;
        const dir = h.cwd(h.ctx);
        if (self.projectByCwd(dir) == null and !self.addProject(dir)) return false;
        self.cfg.enabled = true;
        self.save();
        self.poll(true);
        h.redraw(h.ctx);
        return true;
    }

    /// Appends a project read from disk (or the one folder an older
    /// threads.json held).
    fn appendProject(self: *Watcher, cwd: []const u8, repo: []const u8, verified: bool, found: []const u8) void {
        if (cwd.len == 0) return;
        var p: Project = .{ .verified = verified and repo.len > 0 };
        p.cwd = self.gpa.dupe(u8, cwd) catch return;
        if (repo.len > 0) p.repo = self.gpa.dupe(u8, repo) catch {
            self.gpa.free(p.cwd);
            return;
        };
        if (found.len > 0) p.found = self.gpa.dupe(u8, found) catch &.{};
        self.cfg.projects.append(self.gpa, p) catch p.deinit(self.gpa);
    }

    pub fn pollNow(self: *Watcher) void {
        self.poll(true);
    }

    /// A poll is out asking gh: what the button says while it waits.
    pub fn checking(self: *const Watcher) bool {
        return self.polling.load(.acquire);
    }

    /// Watches the repository a project's folder holds, instead of the one
    /// that was there: an explicit switch, never automatic.
    pub fn watchFound(self: *Watcher, index: usize) bool {
        if (index >= self.cfg.projects.items.len) return false;
        const p = &self.cfg.projects.items[index];
        if (p.found.len == 0) return false;
        set(self.gpa, &p.repo, p.found);
        p.verified = true;
        freeIf(self.gpa, p.found);
        p.found = &.{};
        freeIf(self.gpa, self.last_error);
        self.last_error = &.{};
        self.save();
        if (self.host) |h| h.redraw(h.ctx);
        return true;
    }

    pub fn setEvery(self: *Watcher, seconds: u32) void {
        self.cfg.every_seconds = std.math.clamp(seconds, 60, 3600);
        self.save();
        if (self.host) |h| h.redraw(h.ctx);
    }

    pub fn setSource(self: *Watcher, which: Source, on: bool) void {
        if (self.source(which) == on) return;
        switch (which) {
            .issues => self.cfg.issues = on,
            .reviews => self.cfg.reviews = on,
            .assigned_prs => self.cfg.assigned_prs = on,
            .mentions => self.cfg.mentions = on,
            .my_reviews => self.cfg.my_reviews = on,
            .ci => self.cfg.ci = on,
            .notifications => self.cfg.notifications = on,
        }
        self.save();
        // What is switched on is read now, not at the next tick.
        if (on and self.cfg.enabled and self.host != null) self.pollNow();
        if (self.host) |h| h.redraw(h.ctx);
    }

    pub fn setNotifications(self: *Watcher, on: bool) void {
        self.setSource(.notifications, on);
    }

    pub fn autoStart(self: *const Watcher) bool {
        return self.cfg.auto_start;
    }

    /// Off, a thread that arrives is listed and waits for its Read; the one
    /// being read keeps its turn (noop's routines may wait for approval).
    pub fn setAutoStart(self: *Watcher, on: bool) void {
        if (self.cfg.auto_start == on) return;
        self.cfg.auto_start = on;
        self.save();
        if (on and self.cfg.enabled) self.pollNow();
        if (self.host) |h| h.redraw(h.ctx);
    }

    /// Asked by hand, as agents start on their own only when that switch says
    /// so: read this thread now.
    pub fn analyze(self: *Watcher, id: u64) bool {
        const t = self.findId(id) orelse return false;
        if (t.state != .queued) return false;
        t.asked = true;
        self.pump();
        if (self.host) |h| h.redraw(h.ctx);
        return true;
    }

    // ---------------------------------------------------------------- lookups

    pub fn watching(self: *const Watcher) bool {
        return self.cfg.enabled or self.visible() > 0;
    }

    pub fn visible(self: *const Watcher) usize {
        var n: usize = 0;
        for (self.threads.items) |t| {
            if (t.state != .dismissed and self.belongs(&t)) n += 1;
        }
        return n;
    }

    pub fn needsYou(self: *const Watcher) usize {
        var n: usize = 0;
        for (self.threads.items) |t| {
            if (t.state == .proposed and self.belongs(&t)) n += 1;
        }
        return n;
    }

    /// Whether an agent may be called for this thread: its project's folder
    /// is linked, and gh has confirmed the folder holds its repository.
    pub fn canTrigger(self: *const Watcher, t: *const Thread) bool {
        const p = self.projectFor(threadRepo(t)) orelse return false;
        return p.verified;
    }

    /// Turns started in the last hour, the budget's ledger pruned as it is read.
    pub fn turnsThisHour(self: *Watcher) u32 {
        const now = blocks.now();
        var live: usize = 0;
        for (self.turns.items) |at| {
            if (now - at >= 3600) continue;
            self.turns.items[live] = at;
            live += 1;
        }
        self.turns.shrinkRetainingCapacity(live);
        return @intCast(live);
    }

    pub fn turnBudget(self: *const Watcher) u32 {
        return self.cfg.turns_per_hour;
    }

    pub fn setTurnBudget(self: *Watcher, n: u32) void {
        const clamped = std.math.clamp(n, 1, 120);
        if (clamped == self.cfg.turns_per_hour) return;
        self.cfg.turns_per_hour = clamped;
        self.save();
        if (self.host) |h| h.redraw(h.ctx);
    }

    /// The hour's turns are spent: nothing new starts until one falls out of
    /// the hour, whichever thread it is or whoever asked for it.
    pub fn atLimit(self: *Watcher) bool {
        return self.turnsThisHour() >= self.cfg.turns_per_hour;
    }

    /// A turn is about to start: note it against the hour.
    fn spend(self: *Watcher) void {
        self.turns.append(self.gpa, blocks.now()) catch {};
    }

    /// Whether the thread is from a project watched now. A ledger can hold
    /// threads from a folder that was removed; they are not shown or run.
    pub fn belongs(self: *const Watcher, t: *const Thread) bool {
        return self.projectFor(threadRepo(t)) != null;
    }

    /// The repository a thread's key names: `kind:repo#number`.
    pub fn threadRepo(t: *const Thread) []const u8 {
        const colon = std.mem.indexOfScalar(u8, t.key, ':') orelse return "";
        const hash = std.mem.lastIndexOfScalar(u8, t.key, '#') orelse return "";
        if (hash <= colon + 1) return "";
        return t.key[colon + 1 .. hash];
    }

    fn projectFor(self: *const Watcher, repo: []const u8) ?*const Project {
        if (repo.len == 0) return null;
        for (self.cfg.projects.items) |*p| {
            if (std.mem.eql(u8, p.repo, repo)) return p;
        }
        return null;
    }

    fn projectByCwd(self: *const Watcher, cwd: []const u8) ?*const Project {
        if (cwd.len == 0) return null;
        for (self.cfg.projects.items) |*p| {
            if (std.mem.eql(u8, p.cwd, cwd)) return p;
        }
        return null;
    }

    fn projectByCwdMutable(self: *Watcher, cwd: []const u8) ?*Project {
        if (cwd.len == 0) return null;
        for (self.cfg.projects.items) |*p| {
            if (std.mem.eql(u8, p.cwd, cwd)) return p;
        }
        return null;
    }

    /// A verified project other than `skip` already watches `repo`: one
    /// folder per repository, so its tasks have one place to run.
    fn otherProjectHasRepo(self: *const Watcher, skip: *const Project, repo: []const u8) bool {
        for (self.cfg.projects.items) |*p| {
            if (p == skip or !p.verified or p.cwd.len == 0) continue;
            if (std.mem.eql(u8, p.repo, repo)) return true;
        }
        return false;
    }

    pub fn findId(self: *Watcher, id: u64) ?*Thread {
        for (self.threads.items) |*t| {
            if (t.id == id) return t;
        }
        return null;
    }

    fn findKey(self: *Watcher, key: []const u8) ?*Thread {
        for (self.threads.items) |*t| {
            if (std.mem.eql(u8, t.key, key)) return t;
        }
        return null;
    }

    pub fn enabled(self: *const Watcher) bool {
        return self.cfg.enabled;
    }

    /// What the poll reads, as the switches set it.
    pub fn watched(self: *const Watcher) std.EnumSet(Source) {
        return .init(.{
            .issues = self.cfg.issues,
            .reviews = self.cfg.reviews,
            .assigned_prs = self.cfg.assigned_prs,
            .mentions = self.cfg.mentions,
            .my_reviews = self.cfg.my_reviews,
            .ci = self.cfg.ci,
            .notifications = self.cfg.notifications,
        });
    }

    /// How many switches are on: the pane's summary line.
    pub fn watchedCount(self: *const Watcher) usize {
        return self.watched().count();
    }

    pub fn source(self: *const Watcher, which: Source) bool {
        return switch (which) {
            .issues => self.cfg.issues,
            .reviews => self.cfg.reviews,
            .assigned_prs => self.cfg.assigned_prs,
            .mentions => self.cfg.mentions,
            .my_reviews => self.cfg.my_reviews,
            .ci => self.cfg.ci,
            .notifications => self.cfg.notifications,
        };
    }

    pub fn notifications(self: *const Watcher) bool {
        return self.source(.notifications);
    }

    pub fn every(self: *const Watcher) u32 {
        return self.cfg.every_seconds;
    }

    pub fn lastOk(self: *const Watcher) f64 {
        return self.last_ok;
    }

    pub fn errorText(self: *const Watcher) []const u8 {
        return self.last_error;
    }

    // ---------------------------------------------------------------- prompts

    const Phase = enum { analysis, work };

    fn heading(self: *const Watcher, t: *const Thread) ![]u8 {
        return std.fmt.allocPrint(self.gpa, "{s} {s}", .{ t.label(), t.key });
    }

    /// What the agent is asked. The reading turn is read-only; the working
    /// turn gets a branch of its own and the rules noop's policy keeps.
    fn prompt(self: *const Watcher, t: *const Thread, phase: Phase, p: *const Project, at: []const u8) ![]u8 {
        const repo_name = p.repo;
        const where = p.cwd;
        var branch_buf: [96]u8 = undefined;
        const branch = branchFor(t, &branch_buf);
        return switch (phase) {
            .analysis => std.fmt.allocPrint(self.gpa,
                \\[nanoterm thread: read-only triage]
                \\Github {s} {s}#{d}: {s}
                \\{s}
                \\
                \\The repository is checked out at {s}. The user asked nanoterm to watch this thread. This turn is read-only:
                \\- Read it with `gh {s} view {d} --repo {s} --comments`{s}.
                \\- Inspect the code and tests it touches.
                \\- Do not edit files, commit, push, comment, switch branches, or change anything on Github.
                \\- Answer with a compact proposal: what is being asked, the files you would change, the steps, how to verify, and the risks. Ask a question only when a product decision is truly needed. End with the branch you would use, as `branch: {s}`.
                \\- Finish with these four lines and nothing after them, so nanoterm can read the proposal without guessing:
                \\    plan: what you would do, in one line
                \\    files: the paths you would change, comma separated, or `none`
                \\    verify: the one command that proves the change works
                \\    question: none, or the single question you need answered
            , .{
                t.label(),
                repo_name,
                t.number,
                t.title,
                t.url,
                at,
                if (t.kind == .issue) "issue" else "pr",
                t.number,
                repo_name,
                if (t.kind == .ci) " (and its failing checks)" else "",
                branch,
            }),
            .work => std.fmt.allocPrint(self.gpa,
                \\[nanoterm thread: approved]
                \\The user approved your proposal for Github {s} {s}#{d}: {s}
                \\{s}
                \\
                \\You are in {s}: a git worktree of the repository at {s}, on the branch `{s}`, made for this thread. The person's own checkout is elsewhere and you do not go near it.
                \\1. Run `git status --porcelain`. If it is not clean, stop and say so instead of touching the files.
                \\2. Make the change and commit on this branch with a clear message.
                \\3. Run `{s}` and the repository's own tests, and report what they printed.
                \\
                \\Do not push, merge, force-push, close the issue or pull request, or comment on Github. Those need the user's word in a later turn.
                \\Finish with a short summary: what changed, what you ran, and anything the user must decide.
            , .{
                t.label(),
                repo_name,
                t.number,
                t.title,
                t.url,
                at,
                where,
                t.branch,
                if (t.verify.len > 0) t.verify else "the repository's build and tests",
            }),
        };
    }

    // ---------------------------------------------------------------- save/load

    fn save(self: *Watcher) void {
        if (self.path.len == 0) return;
        const SavedThread = struct {
            id: u64,
            key: []const u8,
            kind: []const u8,
            number: u32,
            title: []const u8,
            url: []const u8,
            updated: []const u8,
            fingerprint: []const u8,
            state: []const u8,
            branch: []const u8,
            proposal: []const u8,
            note: []const u8,
            plan: []const u8,
            files: u32,
            verify: []const u8,
            question: []const u8,
            created: f64,
            changed: f64,
        };
        const SavedProject = struct {
            cwd: []const u8,
            repo: []const u8,
            verified: bool,
            found: []const u8,
        };
        const Saved = struct {
            enabled: bool,
            every_seconds: u32,
            issues: bool,
            reviews: bool,
            assigned_prs: bool,
            mentions: bool,
            my_reviews: bool,
            ci: bool,
            notifications: bool,
            auto_start: bool,
            turns_per_hour: u32,
            projects: []const SavedProject,
            next_id: u64,
            turns: []const f64,
            threads: []const SavedThread,
        };
        var list: std.ArrayListUnmanaged(SavedThread) = .empty;
        defer list.deinit(self.gpa);
        var saved_projects: std.ArrayListUnmanaged(SavedProject) = .empty;
        defer saved_projects.deinit(self.gpa);
        for (self.cfg.projects.items) |p| saved_projects.append(self.gpa, .{
            .cwd = p.cwd,
            .repo = p.repo,
            .verified = p.verified,
            .found = p.found,
        }) catch return;
        for (self.threads.items) |t| list.append(self.gpa, .{
            .id = t.id,
            .key = t.key,
            .kind = @tagName(t.kind),
            .number = t.number,
            .title = t.title,
            .url = t.url,
            .updated = t.updated,
            .fingerprint = t.fingerprint,
            .state = @tagName(t.state),
            .branch = t.branch,
            .proposal = t.proposal,
            .note = t.note,
            .plan = t.plan,
            .files = t.files,
            .verify = t.verify,
            .question = t.question,
            .created = t.created,
            .changed = t.changed,
        }) catch return;
        const data = std.json.Stringify.valueAlloc(self.gpa, Saved{
            .enabled = self.cfg.enabled,
            .every_seconds = self.cfg.every_seconds,
            .issues = self.cfg.issues,
            .reviews = self.cfg.reviews,
            .assigned_prs = self.cfg.assigned_prs,
            .mentions = self.cfg.mentions,
            .my_reviews = self.cfg.my_reviews,
            .ci = self.cfg.ci,
            .notifications = self.cfg.notifications,
            .auto_start = self.cfg.auto_start,
            .turns_per_hour = self.cfg.turns_per_hour,
            .projects = saved_projects.items,
            .next_id = self.next_id,
            .turns = self.turns.items,
            .threads = list.items,
        }, .{}) catch return;
        defer self.gpa.free(data);
        if (std.fs.path.dirname(self.path)) |dir| std.Io.Dir.cwd().createDirPath(self.io, dir) catch {};
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.path, .data = data }) catch {};
    }

    fn load(self: *Watcher) void {
        if (self.path.len == 0) return;
        const data = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, self.gpa, .limited(8 * 1024 * 1024)) catch return;
        defer self.gpa.free(data);
        const SavedThread = struct {
            id: u64 = 0,
            key: []const u8 = "",
            kind: []const u8 = "issue",
            number: u32 = 0,
            title: []const u8 = "",
            url: []const u8 = "",
            updated: []const u8 = "",
            fingerprint: []const u8 = "",
            state: []const u8 = "queued",
            branch: []const u8 = "",
            proposal: []const u8 = "",
            note: []const u8 = "",
            plan: []const u8 = "",
            files: u32 = 0,
            verify: []const u8 = "",
            question: []const u8 = "",
            created: f64 = 0,
            changed: f64 = 0,
        };
        const SavedProject = struct {
            cwd: []const u8 = "",
            repo: []const u8 = "",
            verified: bool = false,
            found: []const u8 = "",
        };
        const Saved = struct {
            enabled: bool = false,
            every_seconds: u32 = 5 * 60,
            issues: bool = true,
            reviews: bool = true,
            // A file written before these switches existed keeps reading
            // exactly what it used to.
            assigned_prs: bool = false,
            mentions: bool = false,
            my_reviews: bool = false,
            ci: bool = true,
            notifications: bool = true,
            auto_start: bool = true,
            turns_per_hour: u32 = 12,
            projects: []const SavedProject = &.{},
            /// Before folders were a list: one checkout and its repository.
            cwd: []const u8 = "",
            repo: []const u8 = "",
            unverified: bool = false,
            found_repo: []const u8 = "",
            next_id: u64 = 1,
            /// The turns spent this hour; a restart does not hand the hour back.
            turns: []const f64 = &.{},
            threads: []const SavedThread = &.{},
        };
        const parsed = std.json.parseFromSlice(Saved, self.gpa, data, .{ .ignore_unknown_fields = true }) catch return;
        defer parsed.deinit();
        const v = parsed.value;
        self.cfg.enabled = v.enabled;
        self.cfg.every_seconds = std.math.clamp(v.every_seconds, 60, 3600);
        self.cfg.issues = v.issues;
        self.cfg.reviews = v.reviews;
        self.cfg.assigned_prs = v.assigned_prs;
        self.cfg.mentions = v.mentions;
        self.cfg.my_reviews = v.my_reviews;
        self.cfg.ci = v.ci;
        self.cfg.notifications = v.notifications;
        self.cfg.auto_start = v.auto_start;
        self.cfg.turns_per_hour = std.math.clamp(v.turns_per_hour, 1, 120);
        for (v.turns) |at| self.turns.append(self.gpa, at) catch {};
        _ = self.turnsThisHour();
        for (v.projects) |p| self.appendProject(p.cwd, p.repo, p.verified, p.found);
        if (v.projects.len == 0 and (v.cwd.len > 0 or v.repo.len > 0)) {
            self.appendProject(v.cwd, v.repo, !v.unverified, v.found_repo);
        }
        self.next_id = @max(v.next_id, 1);
        for (v.threads) |s| {
            if (s.key.len == 0) continue;
            var t: Thread = .{
                .id = if (s.id == 0) self.next_id else s.id,
                .key = self.gpa.dupe(u8, s.key) catch continue,
                .kind = std.meta.stringToEnum(Kind, s.kind) orelse .issue,
                .number = s.number,
                .title = self.gpa.dupe(u8, s.title) catch continue,
                .url = self.gpa.dupe(u8, s.url) catch continue,
                .state = std.meta.stringToEnum(State, s.state) orelse .queued,
                .created = s.created,
                .changed = s.changed,
            };
            if (s.updated.len > 0) t.updated = self.gpa.dupe(u8, s.updated) catch &.{};
            if (s.fingerprint.len > 0) t.fingerprint = self.gpa.dupe(u8, s.fingerprint) catch &.{};
            if (s.branch.len > 0) t.branch = self.gpa.dupe(u8, s.branch) catch &.{};
            if (s.proposal.len > 0) t.proposal = self.gpa.dupe(u8, s.proposal) catch &.{};
            if (s.note.len > 0) t.note = self.gpa.dupe(u8, s.note) catch &.{};
            if (s.plan.len > 0) t.plan = self.gpa.dupe(u8, s.plan) catch &.{};
            if (s.verify.len > 0) t.verify = self.gpa.dupe(u8, s.verify) catch &.{};
            if (s.question.len > 0) t.question = self.gpa.dupe(u8, s.question) catch &.{};
            t.files = s.files;
            self.next_id = @max(self.next_id, t.id + 1);
            // Tabs do not survive a restart. A reading turn starts again; a
            // working one is reported, since it may have changed something.
            switch (t.state) {
                .analyzing => t.state = .queued,
                .running => {
                    t.state = .failed;
                    set(self.gpa, &t.note, "interrupted when nanoterm quit");
                },
                else => {},
            }
            self.threads.append(self.gpa, t) catch continue;
        }
    }
};

// -------------------------------------------------------------------- the poll

const Item = struct {
    key: []const u8,
    kind: Kind,
    number: u32,
    title: []const u8,
    url: []const u8,
    updated: []const u8 = "",
    fingerprint: []const u8 = "",
};

/// One project as a poll sees it: where to run `gh`, the repository it is
/// watched as, and what the folder turned out to hold.
const JobProject = struct {
    cwd: []const u8 = "",
    repo: []const u8 = "",
    /// `gh` must confirm the folder holds `repo` before anything is read.
    check: bool = false,
    /// It did.
    checked: bool = false,
    /// What `gh` says the folder holds.
    found: []const u8 = "",
};

const Job = struct {
    owner: *Watcher,
    arena: std.heap.ArenaAllocator,
    io: std.Io,
    projects: []JobProject = &.{},
    /// The switches as the poll found them.
    want: std.EnumSet(Source) = .empty,
    items: std.ArrayListUnmanaged(Item) = .empty,
    errors: std.ArrayListUnmanaged([]const u8) = .empty,

    fn destroy(job: *Job) void {
        const gpa = job.owner.gpa;
        job.arena.deinit();
        gpa.destroy(job);
    }

    fn run(job: *Job) void {
        job.fetch();
        nanoui.App.onMain(job, Watcher.adopt);
    }

    fn fetch(job: *Job) void {
        const a = job.arena.allocator();
        for (job.projects) |*p| {
            if (p.cwd.len == 0) continue;
            if (p.repo.len == 0 or p.check) {
                const out = job.gh(a, p.cwd, &.{ "gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner" }) orelse continue;
                const name = std.mem.trim(u8, out, " \t\r\n");
                if (name.len == 0) {
                    job.note("this folder is not a Github repository");
                    continue;
                }
                p.found = name;
                if (p.repo.len == 0) {
                    p.repo = name;
                    p.checked = true;
                } else if (std.mem.eql(u8, name, p.repo)) {
                    p.checked = true;
                } else {
                    job.note(std.fmt.allocPrint(a, "this folder holds {s}, not {s}; no agent is called until they match", .{ name, p.repo }) catch "this folder does not hold the watched repository");
                    continue;
                }
            }
            if (p.repo.len == 0) continue;
            if (job.want.contains(.issues)) job.readIssues(a, p) catch {};
            if (job.want.contains(.reviews)) job.readReviews(a, p) catch {};
            if (job.want.contains(.assigned_prs)) job.readAssigned(a, p) catch {};
            if (job.want.contains(.mentions)) job.readMentions(a, p) catch {};
            if (job.want.contains(.my_reviews)) job.readMyReviews(a, p) catch {};
            if (job.want.contains(.ci)) job.readCi(a, p) catch {};
        }
        if (job.want.contains(.notifications)) {
            // Notifications are account-wide: ask once, and only when a
            // confirmed project can claim some of them.
            var any = false;
            for (job.projects) |p| {
                if (p.repo.len == 0 or (p.check and !p.checked)) continue;
                any = true;
                break;
            }
            if (any) job.readNotifications(a) catch {};
        }
    }

    /// One `gh` run in the checkout. Its stderr's first line is the error
    /// when it fails; the output is the arena's to keep.
    fn gh(job: *Job, a: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) ?[]const u8 {
        const result = std.process.run(a, job.io, .{
            .argv = job.owner.toolArgv(a, argv),
            .environ_map = job.owner.env,
            .cwd = if (cwd.len > 0) .{ .path = cwd } else .inherit,
            .stdout_limit = .limited(4 * 1024 * 1024),
            .stderr_limit = .limited(64 * 1024),
            .timeout = .{ .duration = .{ .raw = std.Io.Duration.fromSeconds(45), .clock = .boot } },
        }) catch |err| {
            job.note(switch (err) {
                error.FileNotFound => "the Github CLI (gh) is not installed or not on PATH",
                error.Timeout => "gh did not answer in time",
                else => std.fmt.allocPrint(a, "gh failed: {s}", .{@errorName(err)}) catch "gh failed",
            });
            return null;
        };
        if (!result.term.success()) {
            const text = std.mem.trim(u8, result.stderr, " \t\r\n");
            const line = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
            job.note(if (line.len > 0) line else "gh returned an error");
            return null;
        }
        return plain(a, result.stdout);
    }

    /// gh colourises its JSON for a terminal (`gh api` does it as soon as it
    /// believes it has one, `CLICOLOR_FORCE` forces it anywhere), and escape
    /// sequences are no part of the answer: drop them, so the JSON starts at
    /// `{` or `[`.
    fn plain(a: std.mem.Allocator, text: []const u8) []const u8 {
        if (std.mem.indexOfScalar(u8, text, 0x1b) == null) return text;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] != 0x1b) {
                out.append(a, text[i]) catch return text;
                i += 1;
                continue;
            }
            i += 1;
            if (i >= text.len) break;
            if (text[i] == '[') {
                // A control sequence: up to and including its final byte.
                i += 1;
                while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) i += 1;
                if (i < text.len) i += 1;
            } else i += 1;
        }
        return out.items;
    }

    /// A query that answered with something that is not JSON: note it, and
    /// keep the answer itself, since those bytes are the only way to find out
    /// what gh printed instead.
    fn bad(job: *Job, a: std.mem.Allocator, cmd: []const u8, out: []const u8) []const u8 {
        job.keepAnswer(cmd, out);
        return unreadable(a, cmd, out);
    }

    fn keepAnswer(job: *Job, cmd: []const u8, out: []const u8) void {
        const self = job.owner;
        if (self.path.len == 0) return;
        const dir = std.fs.path.dirname(self.path) orelse return;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/last-gh-answer.txt", .{dir}) catch return;
        const kept = @min(out.len, 64 * 1024);
        const head = std.fmt.allocPrint(self.gpa, "{s}\n{d} bytes, first {d} kept\n\n", .{ cmd, out.len, kept }) catch return;
        defer self.gpa.free(head);
        const data = self.gpa.alloc(u8, head.len + kept) catch return;
        defer self.gpa.free(data);
        @memcpy(data[0..head.len], head);
        @memcpy(data[head.len..], out[0..kept]);
        std.Io.Dir.cwd().writeFile(job.io, .{ .sub_path = path, .data = data }) catch {};
    }

    fn note(job: *Job, text: []const u8) void {
        const a = job.arena.allocator();
        if (text.len == 0) return;
        const clean = std.mem.trim(u8, text, " \t\r\n");
        if (clean.len == 0) return;
        const line = clean[0 .. std.mem.indexOfScalar(u8, clean, '\n') orelse clean.len];
        for (job.errors.items) |e| if (std.mem.eql(u8, e, line)) return;
        job.errors.append(a, a.dupe(u8, line) catch return) catch {};
    }

    fn add(job: *Job, a: std.mem.Allocator, repo: []const u8, kind: Kind, number: u32, title: []const u8, url: []const u8, updated: []const u8, fingerprint: []const u8) !void {
        const key = try std.fmt.allocPrint(a, "{s}:{s}#{d}", .{ @tagName(kind), repo, number });
        for (job.items.items) |*it| {
            if (!std.mem.eql(u8, it.key, key)) continue;
            // A notification and a query can name the same thing: the query
            // knows more (a CI fingerprint), so it wins.
            if (it.fingerprint.len == 0 and fingerprint.len > 0) it.* = .{
                .key = key,
                .kind = kind,
                .number = number,
                .title = title,
                .url = url,
                .updated = updated,
                .fingerprint = fingerprint,
            };
            return;
        }
        try job.items.append(a, .{
            .key = key,
            .kind = kind,
            .number = number,
            .title = title,
            .url = url,
            .updated = updated,
            .fingerprint = fingerprint,
        });
    }

    // gh prints null wherever it has nothing to say, so every field it may
    // leave out is optional here and read with `str`.
    const GIssue = struct {
        number: u32,
        title: ?[]const u8 = null,
        url: ?[]const u8 = null,
        updatedAt: ?[]const u8 = null,
        /// Search results list issues and pull requests together.
        isPullRequest: bool = false,
    };
    const GPr = struct {
        number: u32,
        title: ?[]const u8 = null,
        url: ?[]const u8 = null,
        updatedAt: ?[]const u8 = null,
        headRefOid: ?[]const u8 = null,
        /// gh prints null for a pull request nobody has reviewed yet.
        reviewDecision: ?[]const u8 = null,
        /// gh prints null for a pull request no check has reported on yet.
        statusCheckRollup: ?[]const GCheck = null,
    };
    const GCheck = struct {
        name: ?[]const u8 = null,
        conclusion: ?[]const u8 = null,
        state: ?[]const u8 = null,
        context: ?[]const u8 = null,
    };

    fn readIssues(job: *Job, a: std.mem.Allocator, p: *const JobProject) !void {
        const out = job.gh(a, p.cwd, &.{
            "gh",     "search",                     "issues",  "--assignee=@me", "--repo", p.repo, "--state=open",
            "--json", "number,title,url,updatedAt", "--limit", "30",
        }) orelse return;
        const rows = parseList(GIssue, a, out) catch {
            job.note(job.bad(a, "gh search issues", out));
            return;
        };
        for (rows) |r| try job.add(a, p.repo, .issue, r.number, str(r.title), str(r.url), str(r.updatedAt), str(r.updatedAt));
    }

    fn readReviews(job: *Job, a: std.mem.Allocator, p: *const JobProject) !void {
        const out = job.gh(a, p.cwd, &.{
            "gh",     "search",                     "prs",     "--review-requested=@me", "--repo", p.repo, "--state=open",
            "--json", "number,title,url,updatedAt", "--limit", "30",
        }) orelse return;
        const rows = parseList(GIssue, a, out) catch {
            job.note(job.bad(a, "gh search prs", out));
            return;
        };
        for (rows) |r| try job.add(a, p.repo, .pr, r.number, str(r.title), str(r.url), str(r.updatedAt), str(r.updatedAt));
    }

    fn readAssigned(job: *Job, a: std.mem.Allocator, p: *const JobProject) !void {
        const out = job.gh(a, p.cwd, &.{
            "gh",     "search",                     "prs",     "--assignee=@me", "--repo", p.repo, "--state=open",
            "--json", "number,title,url,updatedAt", "--limit", "30",
        }) orelse return;
        const rows = parseList(GIssue, a, out) catch {
            job.note(job.bad(a, "gh search prs", out));
            return;
        };
        for (rows) |r| try job.add(a, p.repo, .pr, r.number, str(r.title), str(r.url), str(r.updatedAt), str(r.updatedAt));
    }

    fn readMentions(job: *Job, a: std.mem.Allocator, p: *const JobProject) !void {
        const out = job.gh(a, p.cwd, &.{
            "gh",     "search",                                   "issues",  "--mentions=@me", "--repo", p.repo, "--state=open",
            "--json", "number,title,url,updatedAt,isPullRequest", "--limit", "30",
        }) orelse return;
        const rows = parseList(GIssue, a, out) catch {
            job.note(job.bad(a, "gh search issues", out));
            return;
        };
        for (rows) |r| {
            const kind: Kind = if (r.isPullRequest) .pr else .issue;
            try job.add(a, p.repo, kind, r.number, str(r.title), str(r.url), str(r.updatedAt), str(r.updatedAt));
        }
    }

    fn readMyReviews(job: *Job, a: std.mem.Allocator, p: *const JobProject) !void {
        const out = job.gh(a, p.cwd, &.{
            "gh",     "pr",                                        "list",    "--repo", p.repo, "--author=@me", "--state=open",
            "--json", "number,title,url,updatedAt,reviewDecision", "--limit", "30",
        }) orelse return;
        const rows = parseList(GPr, a, out) catch {
            job.note(job.bad(a, "gh pr list", out));
            return;
        };
        for (rows) |r| {
            const decision = r.reviewDecision orelse continue;
            if (!std.mem.eql(u8, decision, "APPROVED") and !std.mem.eql(u8, decision, "CHANGES_REQUESTED")) continue;
            const fp = try std.fmt.allocPrint(a, "review:{s}", .{decision});
            try job.add(a, p.repo, .pr, r.number, str(r.title), str(r.url), str(r.updatedAt), fp);
        }
    }

    fn readCi(job: *Job, a: std.mem.Allocator, p: *const JobProject) !void {
        const out = job.gh(a, p.cwd, &.{
            "gh",     "pr",                                                      "list",    "--repo", p.repo, "--author=@me", "--state=open",
            "--json", "number,title,url,updatedAt,headRefOid,statusCheckRollup", "--limit", "30",
        }) orelse return;
        const rows = parseList(GPr, a, out) catch {
            job.note(job.bad(a, "gh pr list", out));
            return;
        };
        for (rows) |r| {
            const fp = try ciFingerprint(a, r);
            if (fp.len == 0) continue;
            try job.add(a, p.repo, .ci, r.number, str(r.title), str(r.url), str(r.updatedAt), fp);
        }
    }

    const GNote = struct {
        unread: bool = false,
        reason: ?[]const u8 = null,
        updated_at: ?[]const u8 = null,
        subject: struct {
            title: ?[]const u8 = null,
            type: ?[]const u8 = null,
            url: ?[]const u8 = null,
        } = .{},
        repository: struct { full_name: ?[]const u8 = null } = .{},
    };

    fn readNotifications(job: *Job, a: std.mem.Allocator) !void {
        const out = job.gh(a, "", &.{ "gh", "api", "notifications?all=false&per_page=50" }) orelse return;
        const rows = parseList(GNote, a, out) catch {
            job.note(job.bad(a, "gh api notifications", out));
            return;
        };
        const b = job.arena.allocator();
        for (rows) |n| {
            if (!n.unread) continue;
            // Only the repositories a confirmed project watches; a folder
            // that holds another repository watches nothing here.
            var repo: []const u8 = "";
            for (job.projects) |p| {
                if (!std.mem.eql(u8, p.repo, str(n.repository.full_name))) continue;
                if (p.check and !p.checked) continue;
                repo = p.repo;
                break;
            }
            if (repo.len == 0) continue;
            const kind: Kind = if (std.mem.eql(u8, str(n.subject.type), "PullRequest"))
                (if (std.mem.eql(u8, str(n.reason), "ci_activity")) .ci else .pr)
            else if (std.mem.eql(u8, str(n.subject.type), "Issue"))
                .issue
            else
                continue;
            const number = trailingNumber(str(n.subject.url)) orelse continue;
            const url = std.fmt.allocPrint(b, "https://github.com/{s}/{s}/{d}", .{
                repo,
                if (kind == .issue) "issues" else "pull",
                number,
            }) catch continue;
            try job.add(b, repo, kind, number, str(n.subject.title), url, str(n.updated_at), str(n.updated_at));
        }
    }
};

/// gh's answer as rows of `T`. An empty answer is no rows; anything else
/// that is not JSON is an error the caller reports with what gh printed.
fn parseList(comptime T: type, a: std.mem.Allocator, out: []const u8) ![]const T {
    // gh succeeded with nothing to say: no rows, not a broken answer.
    if (std.mem.trim(u8, out, " \t\r\n").len == 0) return &.{};
    const text = jsonFrom(out) orelse return error.SyntaxError;
    const parsed = try std.json.parseFromSlice([]const T, a, text, .{ .ignore_unknown_fields = true });
    return parsed.value;
}

/// gh's answer from its first line that could begin JSON. A warning on
/// stdout before the answer is skipped; text with no JSON in it at all is
/// null, and the caller reports what gh actually printed.
fn jsonFrom(out: []const u8) ?[]const u8 {
    const text = std.mem.trim(u8, out, " \t\r\n");
    if (text.len == 0) return null;
    var rest = text;
    while (rest.len > 0) {
        if (rest[0] == '[' or rest[0] == '{') return rest;
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return null;
        rest = std.mem.trimStart(u8, rest[nl + 1 ..], " \t");
    }
    return null;
}

/// What gh said for a field it may have left out.
fn str(v: ?[]const u8) []const u8 {
    return v orelse "";
}

const Snippet = struct { text: []const u8, cut: bool };

/// The first line of gh's output, at most `buf.len` bytes and never ending
/// inside a character: the part of a wrong answer worth showing.
fn snippet(out: []const u8, buf: []u8) Snippet {
    const text = std.mem.trim(u8, out, " \t\r\n");
    const line_end = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    var end = @min(line_end, buf.len);
    while (end < line_end and end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    @memcpy(buf[0..end], text[0..end]);
    return .{ .text = std.mem.trimEnd(u8, buf[0..end], " \t\r"), .cut = end < line_end };
}

/// What the settings page says when a query answered with something other
/// than JSON: which query, and the first line of what gh printed instead,
/// which is usually gh's own complaint in words.
fn unreadable(a: std.mem.Allocator, cmd: []const u8, out: []const u8) []const u8 {
    // An answer that does start with JSON, but not one this panel can read, is
    // a wall of punctuation in a one-line note: give its size and leave the
    // bytes beside the panel's state.
    if (jsonFrom(out) != null) {
        return std.fmt.allocPrint(a, "{s} answered JSON this panel could not read ({d} bytes)", .{ cmd, out.len }) catch "gh answered JSON this panel could not read";
    }
    // Binary in the answer would draw as broken glyphs: name the size instead,
    // the bytes themselves are kept beside the panel's state.
    if (!std.unicode.utf8ValidateSlice(out)) {
        return std.fmt.allocPrint(a, "{s} printed something that is not text ({d} bytes)", .{ cmd, out.len }) catch "gh printed something that is not text";
    }
    var buf: [160]u8 = undefined;
    const s = snippet(out, &buf);
    return std.fmt.allocPrint(a, "{s} printed something other than JSON: {s}{s}", .{
        cmd, s.text,
        if (s.cut) "…" else "",
    }) catch "gh printed something other than JSON";
}

/// The folder a person typed: absolute as written, `~/…` from home. Null
/// when it has no root, since a relative path means nothing to `gh`.
pub fn expandPath(home: []const u8, text: []const u8, buf: []u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    if (std.mem.eql(u8, trimmed, "~")) return home;
    if (std.mem.startsWith(u8, trimmed, "~/")) {
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ home, trimmed[2..] }) catch null;
    }
    if (std.fs.path.isAbsolute(trimmed)) return trimmed;
    return null;
}

/// The number at the end of an API URL (`…/issues/42`).
pub fn trailingNumber(url: []const u8) ?u32 {
    var end = url.len;
    while (end > 0 and url[end - 1] == '/') end -= 1;
    var start = end;
    while (start > 0 and std.ascii.isDigit(url[start - 1])) start -= 1;
    if (start == end) return null;
    return std.fmt.parseInt(u32, url[start..end], 10) catch null;
}

const failed_conclusions = [_][]const u8{ "FAILURE", "CANCELLED", "TIMED_OUT", "ACTION_REQUIRED", "STARTUP_FAILURE", "ERROR" };

/// The failing checks and the head they ran on, or "" when all is well.
/// One string so a rerun of the same failure does not read as new.
pub fn ciFingerprint(a: std.mem.Allocator, pr: anytype) ![]const u8 {
    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    defer names.deinit(a);
    for (pr.statusCheckRollup orelse &.{}) |c| {
        const verdict = if (str(c.conclusion).len > 0) str(c.conclusion) else str(c.state);
        var failed = false;
        for (failed_conclusions) |f| if (std.ascii.eqlIgnoreCase(verdict, f)) {
            failed = true;
            break;
        };
        if (failed) try names.append(a, if (str(c.name).len > 0) str(c.name) else if (str(c.context).len > 0) str(c.context) else "check");
    }
    if (names.items.len == 0) return "";
    std.mem.sort([]const u8, names.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.less);
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, if (str(pr.headRefOid).len > 0) str(pr.headRefOid) else "head");
    try out.append(a, ':');
    for (names.items, 0..) |n, i| {
        if (i > 0) try out.append(a, ',');
        try out.appendSlice(a, n);
    }
    return out.toOwnedSlice(a);
}

/// The branch an approved thread works on: `nanoterm/<kind>-<number>`.
pub fn branchFor(t: *const Thread, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, "nanoterm/{s}-{d}", .{ @tagName(t.kind), t.number }) catch "nanoterm/thread";
}

/// A turn's answer: the text after its tools, as the fold's summary reads it.
fn turnReply(gpa: std.mem.Allocator, turn: *agent_mod.Turn) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    const items = turn.items.items;
    var i = @import("view_fold.zig").replyStart(items);
    while (i < items.len) : (i += 1) switch (items[i]) {
        .text => |line| try out.appendSlice(gpa, line.items),
        else => {},
    };
    if (out.items.len == 0) for (items) |it| switch (it) {
        .note => |n| try out.appendSlice(gpa, n),
        else => {},
    };
    return out.toOwnedSlice(gpa);
}

/// What a watcher asks of the window while a test pumps it: the folder a
/// thread's tab was started in.
const TestHost = struct {
    var cwd_buf: [512]u8 = undefined;
    var cwd_len: usize = 0;
    var starts: usize = 0;
    var closes: usize = 0;
    /// Whether the tabs the host started are still open.
    var open: bool = true;

    fn reset() void {
        cwd_len = 0;
        starts = 0;
        closes = 0;
        open = true;
    }

    fn lastCwd() []const u8 {
        return cwd_buf[0..cwd_len];
    }

    fn start(_: *anyopaque, cwd: []const u8, _: u64, _: Mode, _: []const u8, _: []const u8) ?u64 {
        starts += 1;
        cwd_len = @min(cwd.len, cwd_buf.len);
        @memcpy(cwd_buf[0..cwd_len], cwd[0..cwd_len]);
        return 7 + starts;
    }

    fn ask(_: *anyopaque, _: u64, _: Mode, _: []const u8, _: []const u8) bool {
        return true;
    }

    fn focus(_: *anyopaque, _: u64) bool {
        return true;
    }

    fn close(_: *anyopaque, _: u64) void {
        closes += 1;
        open = false;
    }

    fn alive(_: *anyopaque, _: u64) bool {
        return open;
    }

    fn folder(_: *anyopaque) []const u8 {
        return "";
    }

    fn redraw(_: *anyopaque) void {}
};

test "threads: the number at the end of a Github url" {
    try std.testing.expectEqual(@as(?u32, 42), trailingNumber("https://api.github.com/repos/o/r/issues/42"));
    try std.testing.expectEqual(@as(?u32, 7), trailingNumber("https://api.github.com/repos/o/r/pulls/7/"));
    try std.testing.expectEqual(@as(?u32, null), trailingNumber("https://api.github.com/repos/o/r/issues"));
    try std.testing.expectEqual(@as(?u32, null), trailingNumber(""));
}

test "threads: a CI fingerprint names the failing checks, in order" {
    const Check = struct { name: []const u8 = "", conclusion: []const u8 = "", state: []const u8 = "", context: []const u8 = "" };
    const Pr = struct { headRefOid: []const u8, statusCheckRollup: ?[]const Check };
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const checks = [_]Check{
        .{ .name = "z", .conclusion = "FAILURE" },
        .{ .name = "ok", .conclusion = "SUCCESS" },
        .{ .name = "a", .conclusion = "TIMED_OUT" },
        .{ .state = "FAILURE", .context = "ctx" },
    };
    const fp = try ciFingerprint(a, Pr{ .headRefOid = "abc123", .statusCheckRollup = &checks });
    try std.testing.expectEqualStrings("abc123:a,ctx,z", fp);
    const passing = [_]Check{.{ .name = "ok", .conclusion = "SUCCESS" }};
    try std.testing.expectEqualStrings("", try ciFingerprint(a, Pr{ .headRefOid = "abc123", .statusCheckRollup = &passing }));
}

test "threads: a pull request whose checks have not run is not a failure" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // gh prints null for a pull request no check has reported on yet.
    const json =
        \\[{"number":8,"title":"Checks","url":"u","updatedAt":"t","headRefOid":"abc123","statusCheckRollup":null}]
    ;
    const parsed = try std.json.parseFromSlice([]const Job.GPr, a, json, .{ .ignore_unknown_fields = true });
    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    try std.testing.expectEqualStrings("", try ciFingerprint(a, parsed.value[0]));
}

test "threads: an empty gh answer is no rows, and a wrong one names itself" {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    // gh succeeded with nothing to say: no rows, not a broken answer.
    try std.testing.expectEqual(@as(usize, 0), (try parseList(Job.GIssue, a, "  \n")).len);
    const rows = try parseList(Job.GIssue, a, "[{\"number\":1,\"title\":\"T\"}]");
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("T", rows[0].title.?);
    // gh sometimes says something on stdout before the answer: the answer
    // is still read.
    const after_warning = try parseList(Job.GIssue, a, "Warning: offline\n[{\"number\":2}]");
    try std.testing.expectEqual(@as(u32, 2), after_warning[0].number);
    var failed = false;
    if (parseList(Job.GIssue, a, "Warning: offline\nmore")) |_| {} else |_| failed = true;
    try std.testing.expect(failed);
    // The note repeats gh's first line, so the output identifies itself.
    var buf: [160]u8 = undefined;
    const s = snippet("  Warning: offline \n{\"number\":1}", &buf);
    try std.testing.expectEqualStrings("Warning: offline", s.text);
    try std.testing.expect(!s.cut);
    var long: [300]u8 = undefined;
    @memset(&long, 'x');
    const cut = snippet(&long, &buf);
    try std.testing.expect(cut.cut);
    try std.testing.expectEqual(@as(usize, 160), cut.text.len);
    // A cut never splits a character.
    var small: [5]u8 = undefined;
    const part = snippet("éééé", &small);
    try std.testing.expectEqualStrings("éé", part.text);
    try std.testing.expect(part.cut);
    // The note names the query and repeats what gh printed, so the output
    // says what went wrong in gh's own words.
    const msg = unreadable(a, "gh search issues", "Warning: offline\nmore");
    try std.testing.expectEqualStrings("gh search issues printed something other than JSON: Warning: offline", msg);
    // An answer that is not text at all is named by its size: drawn as it
    // stands it would be broken glyphs, and nothing in it is worth reading.
    const bin = unreadable(a, "gh search issues", "\xff\xfe\x00binary");
    try std.testing.expectEqualStrings("gh search issues printed something that is not text (9 bytes)", bin);
    // JSON that does not fit is named by its size too, not drawn as punctuation.
    const wall = unreadable(a, "gh search issues", "[{\"number\":1,\"title\":7}]");
    try std.testing.expectEqualStrings("gh search issues answered JSON this panel could not read (24 bytes)", wall);
}

test "threads: an approved thread works on a branch of its own" {
    var t: Thread = .{ .key = @constCast("issue:o/r#42"), .kind = .issue, .number = 42, .title = @constCast("t"), .url = @constCast("u") };
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("nanoterm/issue-42", branchFor(&t, &buf));
    t.kind = .ci;
    try std.testing.expectEqualStrings("nanoterm/ci-42", branchFor(&t, &buf));
}

test "threads: one row per thread, and a newer version of a finished one comes back" {
    const gpa = std.testing.allocator;
    var w: Watcher = .{ .gpa = gpa, .io = std.testing.io, .home = "/tmp" };
    defer {
        for (w.threads.items) |*t| t.deinit(gpa);
        w.threads.deinit(gpa);
    }
    w.absorb(.{
        .key = "issue:o/r#1",
        .kind = .issue,
        .number = 1,
        .title = "first",
        .url = "https://github.com/o/r/issues/1",
        .updated = "t1",
        .fingerprint = "t1",
    }, 10);
    try std.testing.expectEqual(@as(usize, 1), w.threads.items.len);
    // The same thread again: one row, with what the newer read says.
    w.absorb(.{
        .key = "issue:o/r#1",
        .kind = .issue,
        .number = 1,
        .title = "second",
        .url = "https://github.com/o/r/issues/1",
        .updated = "t2",
        .fingerprint = "t2",
    }, 20);
    try std.testing.expectEqual(@as(usize, 1), w.threads.items.len);
    try std.testing.expectEqualStrings("second", w.threads.items[0].title);
    try std.testing.expectEqual(State.queued, w.threads.items[0].state);
    // A proposal waits for its person even if Github moves.
    w.threads.items[0].state = .proposed;
    w.absorb(.{
        .key = "issue:o/r#1",
        .kind = .issue,
        .number = 1,
        .title = "third",
        .url = "https://github.com/o/r/issues/1",
        .updated = "t3",
        .fingerprint = "t3",
    }, 30);
    try std.testing.expectEqual(State.proposed, w.threads.items[0].state);
    // Finished, and Github moved: read it again.
    w.threads.items[0].state = .done;
    w.absorb(.{
        .key = "issue:o/r#1",
        .kind = .issue,
        .number = 1,
        .title = "fourth",
        .url = "https://github.com/o/r/issues/1",
        .updated = "t4",
        .fingerprint = "t4",
    }, 40);
    try std.testing.expectEqual(State.queued, w.threads.items[0].state);
    try std.testing.expect(std.mem.indexOf(u8, w.threads.items[0].note, "moved on Github") != null);
}

test "threads: several project folders are watched, each task belongs to its own" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-threads-projects";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/work-a");
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/work-b");
    {
        var w = Watcher.init(gpa, io, home);
        defer w.deinit();
        try std.testing.expect(w.addProject(home ++ "/work-a"));
        try std.testing.expect(w.addProject("~/work-b"));
        try std.testing.expectEqual(@as(usize, 2), w.projects().len);
        try std.testing.expectEqualStrings(home ++ "/work-b", w.projects()[1].cwd);
        // The same folder twice is refused, and so is one with no root.
        try std.testing.expect(!w.addProject(home ++ "/work-a"));
        try std.testing.expect(w.errorText().len > 0);
        try std.testing.expect(!w.addProject("relative/folder"));
        var buf: [512]u8 = undefined;
        try std.testing.expectEqualStrings(home ++ "/work-b", expandPath(home, "~/work-b", &buf).?);
        try std.testing.expectEqualStrings("/tmp/elsewhere", expandPath(home, "/tmp/elsewhere", &buf).?);
        try std.testing.expect(expandPath(home, "relative/folder", &buf) == null);
        // Their repositories are learned by a poll. Until each is confirmed,
        // its tasks show but cannot trigger.
        set(w.gpa, &w.cfg.projects.items[0].repo, "owner/a");
        w.cfg.projects.items[0].verified = true;
        set(w.gpa, &w.cfg.projects.items[1].repo, "owner/b");
        w.absorb(.{ .key = "issue:owner/a#1", .kind = .issue, .number = 1, .title = "Mine", .url = "", .fingerprint = "1" }, 10);
        w.absorb(.{ .key = "pr:owner/b#2", .kind = .pr, .number = 2, .title = "Also mine", .url = "", .fingerprint = "1" }, 11);
        w.absorb(.{ .key = "issue:someone/else#3", .kind = .issue, .number = 3, .title = "Theirs", .url = "", .fingerprint = "1" }, 12);
        for (w.threads.items) |*t| t.state = .proposed;
        try std.testing.expectEqual(@as(usize, 2), w.visible());
        try std.testing.expectEqual(@as(usize, 2), w.needsYou());
        try std.testing.expect(w.belongs(&w.threads.items[0]));
        try std.testing.expect(w.belongs(&w.threads.items[1]));
        try std.testing.expect(!w.belongs(&w.threads.items[2]));
        try std.testing.expect(w.canTrigger(&w.threads.items[0]));
        try std.testing.expect(!w.canTrigger(&w.threads.items[1]));
        // A poll's confirmation for that folder makes it triggerable.
        w.cfg.projects.items[1].verified = true;
        try std.testing.expect(w.canTrigger(&w.threads.items[1]));
        // Removing one folder hides only its tasks.
        try std.testing.expect(w.removeProject(1));
        try std.testing.expectEqual(@as(usize, 1), w.projects().len);
        try std.testing.expectEqual(@as(usize, 1), w.visible());
        try std.testing.expect(!w.canTrigger(&w.threads.items[1]));
    }
    // What is left is kept for the next launch.
    var again = Watcher.init(gpa, io, home);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 1), again.projects().len);
    try std.testing.expectEqualStrings(home ++ "/work-a", again.projects()[0].cwd);
    try std.testing.expectEqualStrings("owner/a", again.projects()[0].repo);
    try std.testing.expect(again.projects()[0].verified);
}

test "threads: a poll records each folder's repository, and a mismatch keeps the chosen one" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-threads-adopt";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/new");
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/linked");
    var w = Watcher.init(gpa, io, home);
    defer w.deinit();
    try std.testing.expect(w.addProject(home ++ "/new"));
    try std.testing.expect(w.addProject(home ++ "/linked"));
    set(w.gpa, &w.cfg.projects.items[1].repo, "old/repo");
    const job = try gpa.create(Job);
    job.* = .{ .owner = &w, .arena = .init(gpa), .io = io };
    const a = job.arena.allocator();
    job.projects = try a.alloc(JobProject, 2);
    job.projects[0] = .{ .cwd = home ++ "/new", .repo = "owner/new", .checked = true, .found = "owner/new" };
    job.projects[1] = .{ .cwd = home ++ "/linked", .repo = "new/repo", .checked = false, .found = "new/repo" };
    try job.errors.append(a, "this folder holds new/repo, not old/repo; no agent is called until they match");
    Watcher.adopt(@ptrCast(job));
    // A new folder learns the repository it holds, and may trigger.
    try std.testing.expectEqualStrings("owner/new", w.projects()[0].repo);
    try std.testing.expect(w.projects()[0].verified);
    // The repo the person chose stays; the mismatch is offered for a switch.
    try std.testing.expectEqualStrings("old/repo", w.projects()[1].repo);
    try std.testing.expect(!w.projects()[1].verified);
    try std.testing.expectEqualStrings("new/repo", w.projects()[1].found);
    try std.testing.expect(w.errorText().len > 0);
    // Switching takes what that folder holds.
    try std.testing.expect(w.watchFound(1));
    try std.testing.expectEqualStrings("new/repo", w.projects()[1].repo);
    try std.testing.expect(w.projects()[1].verified);
    try std.testing.expectEqualStrings("", w.projects()[1].found);
    w.absorb(.{ .key = "issue:new/repo#4", .kind = .issue, .number = 4, .title = "Theirs", .url = "", .fingerprint = "1" }, 10);
    try std.testing.expect(w.canTrigger(&w.threads.items[0]));
}

test "threads: a thread's tab opens in the folder of its own project" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-threads-pump";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/a");
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/b");
    var w = Watcher.init(gpa, io, home);
    defer w.deinit();
    try std.testing.expect(w.addProject(home ++ "/a"));
    try std.testing.expect(w.addProject(home ++ "/b"));
    set(w.gpa, &w.cfg.projects.items[0].repo, "owner/a");
    w.cfg.projects.items[0].verified = true;
    set(w.gpa, &w.cfg.projects.items[1].repo, "owner/b");
    w.cfg.projects.items[1].verified = true;
    TestHost.reset();
    var ctx: u8 = 0;
    w.host = .{ .ctx = &ctx, .start = TestHost.start, .ask = TestHost.ask, .focus = TestHost.focus, .close = TestHost.close, .alive = TestHost.alive, .cwd = TestHost.folder, .redraw = TestHost.redraw };
    w.absorb(.{ .key = "issue:owner/b#5", .kind = .issue, .number = 5, .title = "B's", .url = "", .fingerprint = "1" }, 10);
    w.pump();
    try std.testing.expectEqual(@as(usize, 1), TestHost.starts);
    try std.testing.expectEqualStrings(home ++ "/b", TestHost.lastCwd());
    // An unconfirmed project's task waits for the next poll.
    w.threads.items[0].state = .dismissed;
    w.active_analysis = 0;
    w.cfg.projects.items[1].verified = false;
    w.absorb(.{ .key = "pr:owner/b#6", .kind = .pr, .number = 6, .title = "B's next", .url = "", .fingerprint = "1" }, 11);
    w.pump();
    try std.testing.expectEqual(@as(usize, 1), TestHost.starts);
}

test "threads: dismissing a thread takes its tab away" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-threads-dismiss-tab";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/a");
    var w = Watcher.init(gpa, io, home);
    defer w.deinit();
    try std.testing.expect(w.addProject(home ++ "/a"));
    set(w.gpa, &w.cfg.projects.items[0].repo, "owner/a");
    w.cfg.projects.items[0].verified = true;
    TestHost.reset();
    var ctx: u8 = 0;
    w.host = .{ .ctx = &ctx, .start = TestHost.start, .ask = TestHost.ask, .focus = TestHost.focus, .close = TestHost.close, .alive = TestHost.alive, .cwd = TestHost.folder, .redraw = TestHost.redraw };
    w.absorb(.{ .key = "issue:owner/a#1", .kind = .issue, .number = 1, .title = "A's", .url = "", .fingerprint = "1" }, 10);
    w.pump();
    try std.testing.expectEqual(State.analyzing, w.threads.items[0].state);
    try std.testing.expect(w.threads.items[0].session != 0);
    // A working thread is not dismissed; its tab is closed to cancel it.
    const id = w.threads.items[0].id;
    w.dismiss(id);
    try std.testing.expectEqual(State.analyzing, w.threads.items[0].state);
    try std.testing.expectEqual(@as(usize, 0), TestHost.closes);
    // A finished one goes, and its tab with it.
    w.threads.items[0].state = .proposed;
    w.active_analysis = 0;
    w.dismiss(id);
    try std.testing.expectEqual(State.dismissed, w.threads.items[0].state);
    try std.testing.expectEqual(@as(usize, 1), TestHost.closes);
    try std.testing.expectEqual(@as(u64, 0), w.threads.items[0].session);
}

test "threads: closing a working thread's tab cancels it, it does not fail" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-threads-cancel";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/a");
    var w = Watcher.init(gpa, io, home);
    defer w.deinit();
    try std.testing.expect(w.addProject(home ++ "/a"));
    set(w.gpa, &w.cfg.projects.items[0].repo, "owner/a");
    w.cfg.projects.items[0].verified = true;
    TestHost.reset();
    var ctx: u8 = 0;
    w.host = .{ .ctx = &ctx, .start = TestHost.start, .ask = TestHost.ask, .focus = TestHost.focus, .close = TestHost.close, .alive = TestHost.alive, .cwd = TestHost.folder, .redraw = TestHost.redraw };
    w.absorb(.{ .key = "issue:owner/a#2", .kind = .issue, .number = 2, .title = "A's", .url = "", .fingerprint = "1" }, 10);
    w.pump();
    try std.testing.expectEqual(State.analyzing, w.threads.items[0].state);
    // The person closed the tab while the reading turn ran.
    TestHost.open = false;
    w.reap();
    try std.testing.expectEqual(State.dismissed, w.threads.items[0].state);
    try std.testing.expectEqual(@as(u64, 0), w.threads.items[0].session);
    try std.testing.expectEqual(@as(u64, 0), w.active_analysis);
    try std.testing.expect(std.mem.indexOf(u8, w.threads.items[0].note, "cancelled") != null);
    // The next thread reads at once: the slot was given back.
    w.absorb(.{ .key = "pr:owner/a#3", .kind = .pr, .number = 3, .title = "A's next", .url = "", .fingerprint = "1" }, 11);
    TestHost.open = true;
    w.pump();
    try std.testing.expectEqual(@as(usize, 2), TestHost.starts);
}

test "threads: a Finder-launched app finds gh and git through the app PATH" {
    if (@import("builtin").os.tag == .windows) return;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-threads-app-path";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/bin");
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = home ++ "/bin/nanoterm-thread-gh",
        .data = "#!/bin/sh\nprintf 'GH_PATH=%s\\n' \"$PATH\"\nprintf 'GH_HOME=%s\\n' \"$HOME\"\nprintf 'gh-ok'\n",
        .flags = .{ .permissions = .executable_file },
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = home ++ "/bin/git",
        .data = "#!/bin/sh\nprintf 'main\\n'\n",
        .flags = .{ .permissions = .executable_file },
    });
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = home ++ "/bin/nanoterm-thread-git-env",
        .data = "#!/bin/sh\nprintf 'GIT_PATH=%s\\n' \"$PATH\"\nprintf 'GIT_HOME=%s\\n' \"$HOME\"\n",
        .flags = .{ .permissions = .executable_file },
    });

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var env: std.process.Environ.Map = .init(arena);
    try env.put("HOME", home);
    try env.put("PATH", home ++ "/bin:/usr/bin:/bin");
    try @import("env_path.zig").augment(arena, io, &env, home);

    var w = Watcher.initWithEnv(gpa, io, home, &env);
    defer w.deinit();
    try std.testing.expect(w.isWorktree(home, "main"));

    w.absorb(.{ .key = "issue:owner/a#1", .kind = .issue, .number = 1, .title = "A's", .url = "", .fingerprint = "1" }, 10);
    var thread_arena_state = std.heap.ArenaAllocator.init(gpa);
    defer thread_arena_state.deinit();
    try std.testing.expect(w.git(thread_arena_state.allocator(), &w.threads.items[0], "", &.{ "nanoterm-thread-git-env", "status" }));

    const job = try gpa.create(Job);
    job.* = .{ .owner = &w, .arena = .init(gpa), .io = io };
    defer job.destroy();
    const out = job.gh(job.arena.allocator(), "", &.{ "nanoterm-thread-gh", "repo", "view" }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, out, "gh-ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "GH_HOME=" ++ home) != null);
    try std.testing.expect(std.mem.indexOf(u8, out, home ++ "/bin") != null);
}

test "threads: an approved thread works in a worktree inside its project" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-threads-worktree";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    const repo = home ++ "/a";
    try std.Io.Dir.cwd().createDirPath(io, repo);
    // A repository with one commit, so there is a HEAD to branch a worktree from.
    for ([_][]const []const u8{
        &.{ "git", "-C", repo, "init", "-q" },
        &.{ "git", "-C", repo, "-c", "user.name=nanoterm", "-c", "user.email=nanoterm@example.com", "commit", "-q", "--allow-empty", "-m", "first" },
    }) |argv| {
        const r = std.process.run(gpa, io, .{
            .argv = argv,
            .stdout_limit = .limited(1 << 20),
            .stderr_limit = .limited(1 << 16),
        }) catch return error.SkipZigTest;
        defer gpa.free(r.stdout);
        defer gpa.free(r.stderr);
        try std.testing.expect(r.term.success());
    }

    var w = Watcher.init(gpa, io, home);
    defer w.deinit();
    try std.testing.expect(w.addProject(repo));
    set(w.gpa, &w.cfg.projects.items[0].repo, "owner/a");
    w.cfg.projects.items[0].verified = true;
    TestHost.reset();
    var ctx: u8 = 0;
    w.host = .{ .ctx = &ctx, .start = TestHost.start, .ask = TestHost.ask, .focus = TestHost.focus, .close = TestHost.close, .alive = TestHost.alive, .cwd = TestHost.folder, .redraw = TestHost.redraw };
    w.absorb(.{ .key = "issue:owner/a#1", .kind = .issue, .number = 1, .title = "A's", .url = "", .fingerprint = "1" }, 10);
    w.pump();
    const id = w.threads.items[0].id;
    w.threads.items[0].state = .proposed;
    w.active_analysis = 0;
    // The reading tab is still open: the approval closes it and opens one of
    // its own in the worktree, so the person's checkout is left alone.
    try std.testing.expect(w.run(id));
    try std.testing.expectEqual(@as(usize, 1), TestHost.closes);

    var path_buf: [512]u8 = undefined;
    const expected = try std.fmt.bufPrint(&path_buf, "{s}/.nanoterm/worktrees/{d}", .{ repo, id });
    try std.testing.expectEqualStrings(expected, TestHost.lastCwd());
    std.Io.Dir.cwd().access(io, expected, .{}) catch |err| {
        std.debug.print("worktree not there: {s}\n", .{@errorName(err)});
        return error.TestUnexpectedResult;
    };
    // The folder is the project's, but `git status` there stays quiet.
    const exclude_text = try std.Io.Dir.cwd().readFileAlloc(io, repo ++ "/.git/info/exclude", gpa, .limited(64 * 1024));
    defer gpa.free(exclude_text);
    try std.testing.expect(std.mem.indexOf(u8, exclude_text, ".nanoterm/") != null);
}

test "threads: the exclude file keeps what it had" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-threads-exclude";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    const repo = home ++ "/a";
    try std.Io.Dir.cwd().createDirPath(io, repo ++ "/.git/info");
    // The person's own entries come first, and stay first.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = repo ++ "/.git/info/exclude", .data = "node_modules/\n.env\n" });

    var w = Watcher.init(gpa, io, home);
    defer w.deinit();
    w.exclude(repo);
    const text = try std.Io.Dir.cwd().readFileAlloc(io, repo ++ "/.git/info/exclude", gpa, .limited(64 * 1024));
    defer gpa.free(text);
    try std.testing.expectEqualStrings("node_modules/\n.env\n.nanoterm/\n", text);
}

test "threads: without a linked project, nothing belongs" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-threads-no-repo";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    var w = Watcher.init(gpa, io, home);
    defer w.deinit();
    w.absorb(.{ .key = "issue:owner/repo#1", .kind = .issue, .number = 1, .title = "Mine", .url = "", .fingerprint = "1" }, 10);
    try std.testing.expect(!w.belongs(&w.threads.items[0]));
    try std.testing.expectEqual(@as(usize, 0), w.visible());
    try std.testing.expectEqual(@as(usize, 0), w.needsYou());
    try std.testing.expect(!w.canTrigger(&w.threads.items[0]));
    try std.testing.expect(!w.watchFound(0));
}

test "threads: the ledger survives a restart, and an interrupted run does not look done" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-threads-ledger";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/Library/Application Support/nanoterm");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/Library/Application Support/nanoterm/threads.json", .data =
        \\{
        \\  "enabled": true,
        \\  "every_seconds": 900,
        \\  "issues": true,
        \\  "reviews": false,
        \\  "ci": true,
        \\  "notifications": false,
        \\  "cwd": "/tmp/repo",
        \\  "repo": "owner/repo",
        \\  "next_id": 20,
        \\  "threads": [
        \\    {"id":1,"key":"issue:owner/repo#7","kind":"issue","number":7,"title":"Fix it","url":"https://github.com/owner/repo/issues/7","state":"analyzing","created":1,"changed":2},
        \\    {"id":2,"key":"ci:owner/repo#8","kind":"ci","number":8,"title":"Checks","url":"https://github.com/owner/repo/pull/8","state":"running","created":1,"changed":2},
        \\    {"id":3,"key":"pr:owner/repo#9","kind":"pr","number":9,"title":"Review","url":"https://github.com/owner/repo/pull/9","state":"proposed","proposal":"the plan","created":1,"changed":2}
        \\  ]
        \\}
    });
    var w = Watcher.init(gpa, io, home);
    defer w.deinit();
    try std.testing.expect(w.enabled());
    try std.testing.expectEqual(@as(u32, 900), w.every());
    try std.testing.expect(!w.source(.reviews));
    try std.testing.expect(w.source(.ci));
    // A file written before the newer switches existed keeps reading what it
    // used to: they stay off until someone turns them on.
    try std.testing.expect(!w.source(.assigned_prs));
    try std.testing.expect(!w.source(.mentions));
    try std.testing.expect(!w.source(.my_reviews));
    try std.testing.expectEqual(@as(usize, 2), w.watchedCount());
    try std.testing.expect(!w.notifications());
    try std.testing.expectEqual(@as(usize, 1), w.projects().len);
    try std.testing.expectEqualStrings("owner/repo", w.projects()[0].repo);
    try std.testing.expectEqualStrings("/tmp/repo", w.projects()[0].cwd);
    try std.testing.expect(w.projects()[0].verified);
    try std.testing.expectEqual(@as(usize, 3), w.visible());
    try std.testing.expectEqual(@as(usize, 1), w.needsYou());
    // Agents start on their own unless a file says otherwise.
    try std.testing.expect(w.autoStart());
    // A reading turn starts again; a working one may have changed files.
    try std.testing.expectEqual(State.queued, w.threads.items[0].state);
    try std.testing.expectEqual(State.failed, w.threads.items[1].state);
    try std.testing.expectEqualStrings("interrupted when nanoterm quit", w.threads.items[1].note);
    try std.testing.expectEqualStrings("the plan", w.threads.items[2].proposal);
    // Put away and slower checks are written back.
    w.dismiss(3);
    w.setEvery(60);
    w.setSource(.mentions, true);
    w.setAutoStart(false);
    const data = try std.Io.Dir.cwd().readFileAlloc(io, w.path, gpa, .limited(1024 * 1024));
    defer gpa.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"every_seconds\":60") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"mentions\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"my_reviews\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"auto_start\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"dismissed\"") != null);
}

test "threads: with agents started by hand, Read asks for one thread" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-threads-asked";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/Library/Application Support/nanoterm");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = home ++ "/Library/Application Support/nanoterm/threads.json", .data =
        \\{
        \\  "enabled": true,
        \\  "auto_start": false,
        \\  "projects": [{"cwd":"/tmp/repo","repo":"owner/repo","verified":true,"found":""}],
        \\  "threads": [
        \\    {"id":1,"key":"issue:owner/repo#7","kind":"issue","number":7,"title":"Fix it","url":"https://github.com/owner/repo/issues/7","state":"queued","created":1,"changed":2},
        \\    {"id":2,"key":"pr:owner/repo#9","kind":"pr","number":9,"title":"Review","url":"https://github.com/owner/repo/pull/9","state":"proposed","proposal":"the plan","created":1,"changed":2}
        \\  ]
        \\}
    });
    var w = Watcher.init(gpa, io, home);
    defer w.deinit();
    try std.testing.expect(!w.autoStart());
    // A queued thread waits for the ask; one already proposed has nothing
    // left to read.
    try std.testing.expect(w.analyze(1));
    try std.testing.expect(w.threads.items[0].asked);
    try std.testing.expect(!w.analyze(2));
    try std.testing.expect(!w.analyze(99));
}

test "gh's colour codes never reach the parser" {
    const gpa = std.testing.allocator;
    var a: std.heap.ArenaAllocator = .init(gpa);
    defer a.deinit();
    const arena = a.allocator();

    // What `gh api` prints for an empty list on a terminal.
    const colourised = "\x1b[1;37m[\x1b[m\x1b[1;37m]\x1b[m";
    const stripped = Job.plain(arena, colourised);
    try std.testing.expectEqualStrings("[]", stripped);
    try std.testing.expectEqual(@as(usize, 2), stripped.len);

    // Inside strings too, and a lone escape at the end is dropped.
    const nested = "\x1b[1;34m\"id\"\x1b[m\x1b[1;37m:\x1b[m \x1b[32m\"1\"\x1b[m\x1b";
    try std.testing.expectEqualStrings("\"id\": \"1\"", Job.plain(arena, nested));

    // Answers without escapes are handed on untouched.
    const plain_json = "[{\"number\":1}]";
    try std.testing.expectEqualStrings(plain_json, Job.plain(arena, plain_json));
}

test "threads: a proposal's tail is read, not guessed" {
    const reply =
        \\The parser drops the last field when the row has a trailing comma.
        \\
        \\plan: split the row before trimming it
        \\files: src/csv.zig, src/csv_test.zig
        \\verify: zig build test
        \\question: none
    ;
    const asked = Plan.of(reply);
    try std.testing.expectEqualStrings("split the row before trimming it", asked.plan);
    try std.testing.expectEqual(@as(u32, 2), asked.files);
    try std.testing.expectEqualStrings("zig build test", asked.verify);
    try std.testing.expectEqualStrings("", asked.question);

    // A question is kept; "none" is not a question, and no files is no count.
    const unsure = Plan.of("plan: `do it`\nfiles: none\nverify: zig build\nquestion: do we keep the old flag?");
    try std.testing.expectEqualStrings("do it", unsure.plan);
    try std.testing.expectEqual(@as(u32, 0), unsure.files);
    try std.testing.expectEqualStrings("do we keep the old flag?", unsure.question);

    // A reply that never got the tail leaves every field empty.
    const bare = Plan.of("I would change the parser.");
    try std.testing.expectEqualStrings("", bare.plan);
    try std.testing.expectEqual(@as(u32, 0), bare.files);

    // Markdown around the tail is not part of it.
    const styled = Plan.of("- **plan:** split the row\n2. `files:` src/csv.zig\n- verify: none\n**question:** none");
    try std.testing.expectEqualStrings("split the row", styled.plan);
    try std.testing.expectEqual(@as(u32, 1), styled.files);
    try std.testing.expectEqualStrings("", styled.verify);
    try std.testing.expectEqualStrings("", styled.question);
}

test "threads: the hour's turns stop a run of them" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-threads-budget";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    try std.Io.Dir.cwd().createDirPath(io, home ++ "/a");
    var w = Watcher.init(gpa, io, home);
    defer w.deinit();
    try std.testing.expect(w.addProject(home ++ "/a"));
    set(w.gpa, &w.cfg.projects.items[0].repo, "owner/a");
    w.cfg.projects.items[0].verified = true;
    w.setTurnBudget(1);
    TestHost.reset();
    var ctx: u8 = 0;
    w.host = .{ .ctx = &ctx, .start = TestHost.start, .ask = TestHost.ask, .focus = TestHost.focus, .close = TestHost.close, .alive = TestHost.alive, .cwd = TestHost.folder, .redraw = TestHost.redraw };
    w.absorb(.{ .key = "issue:owner/a#1", .kind = .issue, .number = 1, .title = "one", .url = "", .fingerprint = "1" }, 10);
    w.absorb(.{ .key = "issue:owner/a#2", .kind = .issue, .number = 2, .title = "two", .url = "", .fingerprint = "1" }, 11);
    w.pump();
    try std.testing.expectEqual(@as(usize, 1), TestHost.starts);
    try std.testing.expect(w.atLimit());
    try std.testing.expectEqual(@as(u32, 1), w.turnsThisHour());

    // The hour is spent: the second thread waits its turn.
    w.active_analysis = 0;
    w.pump();
    try std.testing.expectEqual(@as(usize, 1), TestHost.starts);

    // Once the oldest turn falls out of the hour, the next one may start.
    w.turns.items[0] -= 3601;
    try std.testing.expect(!w.atLimit());
    w.pump();
    try std.testing.expectEqual(@as(usize, 2), TestHost.starts);

    // A person's Run is refused too, and says why on the row.
    const id = w.threads.items[0].id;
    w.threads.items[0].state = .proposed;
    w.active_analysis = 0;
    w.active_run = 0;
    try std.testing.expect(!w.run(id));
    try std.testing.expect(std.mem.indexOf(u8, w.threads.items[0].note, "spent") != null);
}

test "threads: the turn budget is kept between runs, and held to its range" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const home = "/tmp/nanoterm-test-threads-budget-saved";
    std.Io.Dir.cwd().deleteTree(io, home) catch {};
    defer std.Io.Dir.cwd().deleteTree(io, home) catch {};
    {
        var w = Watcher.init(gpa, io, home);
        defer w.deinit();
        try std.testing.expectEqual(@as(u32, 12), w.turnBudget());
        w.setTurnBudget(0);
        try std.testing.expectEqual(@as(u32, 1), w.turnBudget());
        w.setTurnBudget(500);
        try std.testing.expectEqual(@as(u32, 120), w.turnBudget());
        w.setTurnBudget(24);
        // Turns spent stay spent for the hour, even if the window closes.
        w.spend();
        w.spend();
        w.save();
    }
    var w = Watcher.init(gpa, io, home);
    defer w.deinit();
    try std.testing.expectEqual(@as(u32, 24), w.turnBudget());
    try std.testing.expectEqual(@as(u32, 2), w.turnsThisHour());
}
