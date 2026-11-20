//! A provider's model list, asked for by a short-lived process of its own.
//!
//! A turn's process is the wrong place to learn what a provider offers: codex
//! is single-shot and pi answers `get_available_models` before it reports its
//! own state, so a picker that waits for a turn shows nothing or shows a
//! partial list. Each provider is therefore asked directly, in a process that
//! exists only to answer, and the answer is kept for a few minutes.
//!
//! Codex speaks its app-server protocol (`model/list`, paged by cursor) and pi
//! speaks its RPC (`get_available_models`, which arrives in pieces as its
//! extensions register, so it is polled until it stops changing).
const std = @import("std");
const proc = @import("proc.zig");

/// How long an answer is reused before the provider is asked again.
const fresh_seconds = 300;
/// A probe's whole life. Codex answers in about a second; pi's extensions can
/// take longer to register, so it gets more room.
const codex_deadline_ms = 15_000;
const pi_deadline_ms = 45_000;
/// pi's list is complete once it has started at least this long ago and has
/// stopped changing for `pi_settle_ms`.
const pi_settle_after_ms = 5_000;
const pi_settle_ms = 1_000;
const pi_poll_ms = 500;
/// A provider that answers with more than this is not answering a model list.
const max_bytes = 2 * 1024 * 1024;

pub const Provider = enum { codex, pi };

pub const Model = struct {
    /// What the provider is sent, and what the picker stores.
    value: []u8 = &.{},
    /// What a person reads.
    name: []u8 = &.{},
    description: []u8 = &.{},

    pub fn deinit(m: *Model, gpa: std.mem.Allocator) void {
        // Empty slices are the zero value of an unfilled slot in a partially
        // built list; freeing them would be a no-op at best, invalid at worst.
        if (m.value.len > 0) gpa.free(m.value);
        if (m.name.len > 0) gpa.free(m.name);
        if (m.description.len > 0) gpa.free(m.description);
    }
};

pub const List = struct {
    models: []Model = &.{},
    /// What went wrong, for the picker to show instead of an empty list.
    note: ?[]u8 = null,

    pub fn deinit(l: *List, gpa: std.mem.Allocator) void {
        for (l.models) |*m| m.deinit(gpa);
        if (l.models.len > 0) gpa.free(l.models);
        if (l.note) |n| gpa.free(n);
        l.* = .{};
    }
};

/// What one probe found, before it is copied into a `List`.
const Answer = struct {
    models: std.ArrayList(Model) = .empty,
    note: ?[]u8 = null,

    /// Frees the models and the array, but not `note`: on the success path
    /// `fetch` transfers that string to the returned `List`.
    fn deinit(a: *Answer, gpa: std.mem.Allocator) void {
        for (a.models.items) |*m| m.deinit(gpa);
        a.models.deinit(gpa);
        a.* = .{};
    }
};

/// Asks `provider` what it offers. Blocks: call it from a worker thread.
/// `env` is the session's environment (the `KEY=VALUE` list), so the provider
/// finds the same PATH and credentials a turn would.
pub fn fetch(
    gpa: std.mem.Allocator,
    io: std.Io,
    provider: Provider,
    env: []const []const u8,
    cwd: []const u8,
    cancel: ?*std.atomic.Value(bool),
) List {
    var answer: Answer = .{};
    defer answer.deinit(gpa);
    const result = switch (provider) {
        .codex => fetchCodex(gpa, io, env, cwd, &answer, cancel),
        .pi => fetchPi(gpa, io, env, cwd, &answer, cancel),
    };
    if (result) |_| {} else |err| {
        if (answer.note == null) {
            answer.note = std.fmt.allocPrint(gpa, "{s}", .{@errorName(err)}) catch null;
        }
    }
    const models: []Model = answer.models.toOwnedSlice(gpa) catch &.{};
    const note = answer.note;
    answer.note = null; // ownership moves to the returned List
    return .{ .models = models, .note = note };
}

fn cancelled(cancel: ?*std.atomic.Value(bool)) bool {
    return if (cancel) |c| c.load(.acquire) else false;
}

/// The environment a probe runs with: the session's own, so the provider sees
/// the PATH and credentials a turn would.
fn environ(gpa: std.mem.Allocator, env: []const []const u8) !std.process.Environ.Map {
    var map: std.process.Environ.Map = .init(gpa);
    errdefer map.deinit();
    for (env) |kv| {
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
        try map.put(kv[0..eq], kv[eq + 1 ..]);
    }
    return map;
}

const Probe = struct {
    child: std.process.Child,
    io: std.Io,
    /// Bytes read but not yet handed out as a line.
    buf: std.ArrayList(u8) = .empty,
    gpa: std.mem.Allocator,
    eof: bool = false,

    fn start(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, env: []const []const u8, cwd: []const u8) !Probe {
        var map = try environ(gpa, env);
        defer map.deinit();
        const child = try std.process.spawn(io, .{
            .argv = argv,
            .cwd = .{ .path = cwd },
            .environ_map = &map,
            .stdin = .pipe,
            .stdout = .pipe,
            // A provider's complaints are not this probe's answer.
            .stderr = .ignore,
        });
        return .{ .child = child, .io = io, .gpa = gpa };
    }

    fn send(p: *Probe, line: []const u8) !void {
        const stdin = p.child.stdin orelse return error.NoStdin;
        var wbuf: [4096]u8 = undefined;
        var w = stdin.writer(p.io, &wbuf);
        try w.interface.writeAll(line);
        try w.interface.writeAll("\n");
        try w.interface.flush();
    }

    /// The next line, or null at end of output.
    fn nextLine(p: *Probe, deadline: std.Io.Timestamp) !?[]const u8 {
        while (true) {
            if (std.mem.indexOfScalar(u8, p.buf.items, '\n')) |at| {
                return p.buf.items[0..at];
            }
            if (p.eof) {
                if (p.buf.items.len == 0) return null;
                // Return the whole remainder; `take` will consume it. Do not
                // reset the ArrayList here, that would leak its allocation.
                return p.buf.items;
            }
            if (std.Io.Timestamp.now(p.io, .awake).compare(.gt, deadline)) return error.TimedOut;
            const stdout = p.child.stdout orelse return null;
            var chunk: [16 * 1024]u8 = undefined;
            const n = stdout.readStreaming(p.io, &.{&chunk}) catch |err| switch (err) {
                error.EndOfStream => {
                    p.eof = true;
                    continue;
                },
                else => return err,
            };
            if (n == 0) {
                p.eof = true;
                continue;
            }
            if (p.buf.items.len + n > max_bytes) return error.StreamTooLong;
            try p.buf.appendSlice(p.gpa, chunk[0..n]);
        }
    }

    /// Consumes the line `nextLine` returned, so the next call moves on.
    fn take(p: *Probe, line: []const u8) void {
        const used = line.len + 1;
        if (used >= p.buf.items.len) {
            p.buf.clearRetainingCapacity();
        } else {
            std.mem.copyForwards(u8, p.buf.items, p.buf.items[used..]);
            p.buf.shrinkRetainingCapacity(p.buf.items.len - used);
        }
    }

    fn stop(p: *Probe) void {
        if (p.child.stdin) |f| {
            f.close(p.io);
            p.child.stdin = null;
        }
        p.child.kill(p.io);
        if (p.child.stdout) |f| {
            f.close(p.io);
            p.child.stdout = null;
        }
        p.buf.deinit(p.gpa);
    }
};

fn addModel(gpa: std.mem.Allocator, models: *std.ArrayList(Model), value: []const u8, name: []const u8, description: []const u8) !void {
    for (models.items) |m| if (std.mem.eql(u8, m.value, value)) return;
    const owned_value = try gpa.dupe(u8, value);
    errdefer gpa.free(owned_value);
    const owned_name = try gpa.dupe(u8, name);
    errdefer gpa.free(owned_name);
    const owned_description = try gpa.dupe(u8, description);
    errdefer gpa.free(owned_description);
    try models.append(gpa, .{
        .value = owned_value,
        .name = owned_name,
        .description = owned_description,
    });
}

// Codex.

/// Codex's app-server, asked for `model/list` and then closed. It answers in
/// pages; each `nextCursor` is followed until there is none.
fn fetchCodex(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: []const []const u8,
    cwd: []const u8,
    answer: *Answer,
    cancel: ?*std.atomic.Value(bool),
) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const path = envPath(env);
    const bin = proc.which(al, io, path, "codex") orelse {
        answer.note = try gpa.dupe(u8, "codex is not installed");
        return;
    };
    var probe = try Probe.start(gpa, io, &.{ bin, "app-server" }, env, cwd);
    defer probe.stop();
    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(std.Io.Duration.fromMilliseconds(codex_deadline_ms));

    try probe.send(
        \\{"id":1,"method":"initialize","params":{"clientInfo":{"name":"nanoterm","version":"1"},"capabilities":{"experimentalApi":true}}}
    );
    var asked = false;
    var cursor: ?[]u8 = null;
    var seen_cursors: std.StringHashMapUnmanaged(void) = .empty;
    defer {
        if (cursor) |c| gpa.free(c);
        var it = seen_cursors.keyIterator();
        while (it.next()) |k| gpa.free(k.*);
        seen_cursors.deinit(gpa);
    }

    while (true) {
        if (cancelled(cancel)) return error.Cancelled;
        const line = (try probe.nextLine(deadline)) orelse break;
        defer probe.take(line);
        var parsed = std.json.parseFromSlice(std.json.Value, al, line, .{}) catch continue;
        defer parsed.deinit();
        const v = parsed.value;
        if (v != .object) continue;
        const obj = v.object;

        // The server asks questions of its own; a probe that stays silent
        // leaves `model/list` waiting forever.
        if (obj.get("method")) |method| {
            if (obj.get("id")) |id| {
                if (method == .string and std.mem.eql(u8, method.string, "currentTime/read")) {
                    const reply = try std.fmt.allocPrint(al, "{{\"id\":{},\"result\":{{\"currentTimeAt\":{d}}}}}", .{ id, std.Io.Timestamp.now(io, .real).toSeconds() });
                    try probe.send(reply);
                } else {
                    const reply = try std.fmt.allocPrint(al, "{{\"id\":{},\"error\":{{\"code\":-32601,\"message\":\"Unsupported method\"}}}}", .{id});
                    try probe.send(reply);
                }
            }
            continue;
        }

        const id = obj.get("id") orelse continue;
        if (id != .integer) continue;
        if (id.integer == 1) {
            if (obj.get("error")) |e| if (e != .null) {
                answer.note = try gpa.dupe(u8, "codex could not start");
                return;
            };
            try probe.send("{\"method\":\"initialized\"}");
            try probe.send("{\"id\":2,\"method\":\"model/list\",\"params\":{\"limit\":100}}");
            asked = true;
            continue;
        }
        if (id.integer != 2 or !asked) continue;
        if (obj.get("error")) |e| if (e != .null) {
            answer.note = try gpa.dupe(u8, "codex did not list its models");
            return;
        };
        const result = obj.get("result") orelse continue;
        if (result != .object) continue;
        if (result.object.get("data")) |data| if (data == .array) {
            for (data.array.items) |row| {
                if (row != .object) continue;
                if (row.object.get("hidden")) |h| if (h == .bool and h.bool) continue;
                const value = str(row, "model") orelse str(row, "id") orelse continue;
                const name = str(row, "displayName") orelse value;
                const description = str(row, "description") orelse "";
                try addModel(gpa, &answer.models, value, name, description);
            }
        };
        // A page ends with a cursor; the next page is the same request.
        const next = str(result, "nextCursor") orelse break;
        if (next.len == 0) break;
        if (seen_cursors.contains(next)) {
            answer.note = try gpa.dupe(u8, "codex repeated a page cursor");
            return;
        }
        const owned = try gpa.dupe(u8, next);
        try seen_cursors.put(gpa, owned, {});
        if (cursor) |c| gpa.free(c);
        cursor = try gpa.dupe(u8, next);
        const request = try std.fmt.allocPrint(al, "{{\"id\":2,\"method\":\"model/list\",\"params\":{{\"limit\":100,\"cursor\":{s}}}}}", .{try jsonString(al, cursor.?)});
        try probe.send(request);
    }
    if (answer.models.items.len == 0 and answer.note == null) {
        answer.note = try gpa.dupe(u8, "codex listed no models");
    }
    sortModels(answer.models.items);
}

// Pi.

/// Pi's RPC, asked for `get_available_models` until the list stops growing.
/// Pi's extensions register their providers as it starts, so one answer is
/// only the part that had arrived by then.
fn fetchPi(
    gpa: std.mem.Allocator,
    io: std.Io,
    env: []const []const u8,
    cwd: []const u8,
    answer: *Answer,
    cancel: ?*std.atomic.Value(bool),
) !void {
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const al = arena.allocator();
    const path = envPath(env);
    const bin = proc.which(al, io, path, "pi") orelse {
        answer.note = try gpa.dupe(u8, "pi is not installed");
        return;
    };
    var probe = try Probe.start(gpa, io, &.{ bin, "--mode", "rpc", "--no-session" }, env, cwd);
    defer probe.stop();
    const started = std.Io.Timestamp.now(io, .awake);
    const deadline = std.Io.Timestamp.now(io, .awake).addDuration(std.Io.Duration.fromMilliseconds(pi_deadline_ms));

    var signature: ?[]u8 = null;
    defer if (signature) |s| gpa.free(s);
    var changed_at = started;

    // Pi sends no greeting. Each request gets exactly one response, so send
    // first and then read; a read with no request outstanding would block
    // forever. Extensions register their providers as pi starts, so one
    // answer is only the part that had arrived by then: ask again, with a
    // short pause, until the list stops changing.
    while (true) {
        if (cancelled(cancel)) return error.Cancelled;
        if (std.Io.Timestamp.now(io, .awake).compare(.gt, deadline)) break;
        try probe.send("{\"type\":\"get_available_models\"}");
        // Pi also pushes extension notifications (setStatus, setWidget). Skip
        // those until this request's response comes back. Consume each line
        // explicitly: a `defer` here would only run at function exit.
        var got_response = false;
        while (!got_response) {
            if (cancelled(cancel)) return error.Cancelled;
            if (std.Io.Timestamp.now(io, .awake).compare(.gt, deadline)) break;
            const line = (try probe.nextLine(deadline)) orelse break;
            defer probe.take(line);
            var parsed = std.json.parseFromSlice(std.json.Value, al, line, .{}) catch continue;
            defer parsed.deinit();
            const v = parsed.value;
            if (v != .object) continue;
            const obj = v.object;
            const kind = str(v, "type") orelse continue;
            if (!std.mem.eql(u8, kind, "response")) continue;
            got_response = true;
            if (obj.get("success")) |ok| if (ok == .bool and !ok.bool) {
                if (answer.models.items.len == 0) answer.note = try gpa.dupe(u8, "pi did not list its models");
                break;
            };
            const data = obj.get("data") orelse break;
            if (data != .object) break;
            const rows = if (data.object.get("models")) |m| m else data;
            if (rows != .array) break;
            const text = try std.json.Stringify.valueAlloc(al, rows, .{});
            if (signature == null or !std.mem.eql(u8, signature.?, text)) {
                if (signature) |s| gpa.free(s);
                signature = try gpa.dupe(u8, text);
                changed_at = std.Io.Timestamp.now(io, .awake);
            }
            for (rows.array.items) |row| {
                if (row != .object) continue;
                const provider = str(row, "provider") orelse continue;
                const id = str(row, "id") orelse continue;
                const value = try std.fmt.allocPrint(al, "{s}/{s}", .{ provider, id });
                const name = str(row, "name") orelse id;
                try addModel(gpa, &answer.models, value, name, provider);
            }
        }
        if (!got_response) break;
        // Complete once it has had time to start and has stopped changing.
        const settled = std.Io.Timestamp.now(io, .awake);
        const ran_long_enough = started.durationTo(settled).toMilliseconds() >= pi_settle_after_ms;
        const quiet = changed_at.durationTo(settled).toMilliseconds() >= pi_settle_ms;
        if (ran_long_enough and quiet and answer.models.items.len > 0) break;
        std.Io.sleep(io, .fromMilliseconds(pi_poll_ms), .awake) catch break;
    }
    if (answer.models.items.len == 0 and answer.note == null) {
        answer.note = try gpa.dupe(u8, "pi listed no models");
    }
    sortModels(answer.models.items);
}

// Shared.

fn str(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const field = v.object.get(key) orelse return null;
    return if (field == .string and field.string.len > 0) field.string else null;
}

fn jsonString(al: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(al);
    defer out.deinit();
    try std.json.Stringify.encodeJsonString(s, .{}, &out.writer);
    return al.dupe(u8, out.written());
}

fn sortModels(models: []Model) void {
    std.mem.sort(Model, models, {}, struct {
        fn lessThan(_: void, a: Model, b: Model) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
}

fn envPath(env: []const []const u8) []const u8 {
    for (env) |kv| if (std.mem.startsWith(u8, kv, "PATH=")) return kv[5..];
    return "/usr/bin:/bin:/usr/local/bin";
}

// The cache.

const Entry = struct {
    provider: Provider,
    list: List,
    at: std.Io.Timestamp,
};

var cache_mutex: std.Io.Mutex = .init;
var cache: std.ArrayList(Entry) = .empty;
var cache_ready = false;

fn cacheInit(gpa: std.mem.Allocator) void {
    if (cache_ready) return;
    cache = .empty;
    cache_ready = true;
    _ = gpa;
}

/// The last answer for `provider`, if it is still fresh. Never blocks and
/// never starts a process: the picker draws this while a probe runs.
pub fn cached(gpa: std.mem.Allocator, io: std.Io, provider: Provider) ?List {
    cacheInit(gpa);
    const io_ = io;
    cache_mutex.lockUncancelable(io_);
    defer cache_mutex.unlock(io_);
    const now = std.Io.Timestamp.now(io_, .awake);
    for (cache.items) |entry| {
        if (entry.provider != provider) continue;
        if (entry.at.durationTo(now).toMilliseconds() > fresh_seconds * 1000) return null;
        return cloneList(gpa, entry.list);
    }
    return null;
}

/// Keeps an answer for the picker to draw without asking again.
pub fn store(gpa: std.mem.Allocator, io: std.Io, provider: Provider, list: List) void {
    cacheInit(gpa);
    cache_mutex.lockUncancelable(io);
    defer cache_mutex.unlock(io);
    const now = std.Io.Timestamp.now(io, .awake);
    for (cache.items) |*entry| {
        if (entry.provider != provider) continue;
        entry.list.deinit(gpa);
        entry.list = cloneList(gpa, list);
        entry.at = now;
        return;
    }
    cache.append(gpa, .{ .provider = provider, .list = cloneList(gpa, list), .at = now }) catch {};
}

/// Drops one provider's answer, so the next `cached` misses.
pub fn invalidate(gpa: std.mem.Allocator, io: std.Io, provider: Provider) void {
    cacheInit(gpa);
    cache_mutex.lockUncancelable(io);
    defer cache_mutex.unlock(io);
    var i: usize = 0;
    while (i < cache.items.len) {
        if (cache.items[i].provider != provider) {
            i += 1;
            continue;
        }
        cache.items[i].list.deinit(gpa);
        _ = cache.orderedRemove(i);
    }
}

fn cloneList(gpa: std.mem.Allocator, list: List) List {
    var out: List = .{};
    if (list.models.len > 0) {
        const models = gpa.alloc(Model, list.models.len) catch return out;
        // Zero every slot first, so a partial fill leaves safe empty slices
        // that `Model.deinit` can skip.
        for (models) |*slot| slot.* = .{};
        var n: usize = 0;
        for (list.models) |m| {
            const value = gpa.dupe(u8, m.value) catch break;
            const name = gpa.dupe(u8, m.name) catch {
                gpa.free(value);
                break;
            };
            const description = gpa.dupe(u8, m.description) catch {
                gpa.free(value);
                gpa.free(name);
                break;
            };
            models[n] = .{ .value = value, .name = name, .description = description };
            n += 1;
        }
        // Keep the full slice so `deinit` frees the whole allocation, even if
        // only a prefix was filled (the rest are zeroed empty slots).
        out.models = models;
    }
    if (list.note) |note| out.note = gpa.dupe(u8, note) catch null;
    return out;
}

// Tests.

test "codex's pages are followed until the cursor stops" {
    const gpa = std.testing.allocator;
    var answer: Answer = .{};
    defer answer.deinit(gpa);
    // The two pages a real app-server answers with.
    const page1 =
        \\{"id":2,"result":{"data":[{"id":"gpt-6.1-sol","model":"gpt-6.1-sol","displayName":"GPT-6.1 Sol","description":"Frontier"},{"id":"hidden-one","model":"hidden-one","hidden":true}],"nextCursor":"page-2"}}
    ;
    const page2 =
        \\{"id":2,"result":{"data":[{"id":"gpt-6.1-terra","model":"gpt-6.1-terra","displayName":"GPT-6.1 Terra","description":"Fast"}]}}
    ;
    for ([_][]const u8{ page1, page2 }) |line| {
        var parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
        defer parsed.deinit();
        const result = parsed.value.object.get("result").?;
        if (result.object.get("data")) |data| if (data == .array) {
            for (data.array.items) |row| {
                if (row.object.get("hidden")) |h| if (h == .bool and h.bool) continue;
                const value = str(row, "model") orelse str(row, "id") orelse continue;
                try addModel(gpa, &answer.models, value, str(row, "displayName") orelse value, str(row, "description") orelse "");
            }
        };
        _ = result.object.get("nextCursor");
    }
    try std.testing.expectEqual(@as(usize, 2), answer.models.items.len);
    try std.testing.expectEqualStrings("gpt-6.1-sol", answer.models.items[0].value);
    try std.testing.expectEqualStrings("gpt-6.1-terra", answer.models.items[1].value);
}

test "pi's models keep their upstream provider in the value" {
    const gpa = std.testing.allocator;
    var answer: Answer = .{};
    defer answer.deinit(gpa);
    const line =
        \\{"type":"response","success":true,"data":{"models":[{"provider":"cloudflare-workers-ai","id":"@cf/deepseek-ai/x","name":"DeepSeek X"},{"provider":"anthropic","id":"claude-sonnet-5.5","name":"Sonnet"}]}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, line, .{});
    defer parsed.deinit();
    const rows = parsed.value.object.get("data").?.object.get("models").?;
    for (rows.array.items) |row| {
        const provider = str(row, "provider") orelse continue;
        const id = str(row, "id") orelse continue;
        const value = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ provider, id });
        defer gpa.free(value);
        try addModel(gpa, &answer.models, value, str(row, "name") orelse id, provider);
    }
    try std.testing.expectEqual(@as(usize, 2), answer.models.items.len);
    try std.testing.expectEqualStrings("cloudflare-workers-ai/@cf/deepseek-ai/x", answer.models.items[0].value);
    try std.testing.expectEqualStrings("anthropic/claude-sonnet-5.5", answer.models.items[1].value);
}

test "a model listed twice is kept once" {
    const gpa = std.testing.allocator;
    var answer: Answer = .{};
    defer answer.deinit(gpa);
    try addModel(gpa, &answer.models, "codex/gpt-6.1-sol", "GPT-6.1 Sol", "Frontier");
    try addModel(gpa, &answer.models, "codex/gpt-6.1-sol", "GPT-6.1 Sol", "Frontier");
    try std.testing.expectEqual(@as(usize, 1), answer.models.items.len);
}
