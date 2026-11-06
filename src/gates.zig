//! What an agent may do on its own, decided here rather than asked of the
//! person. A watched thread's tab works while nobody watches it, so its
//! permission requests must not wait for a click: reading turns read, working
//! turns change this checkout and nothing else, and the person's own tabs keep
//! asking, as they always did.
//!
//! The request's title and kind are what the decision is made on: titles come
//! from the agent ("Run command: git push origin main", "Edit file src/x.zig"),
//! and a pattern found in one is refused. This is a second line behind the
//! prompt's instructions, not a sandbox: an agent that never asks performs
//! nothing here.
const std = @import("std");

pub const Guard = enum {
    /// The person's own tab: every request is theirs to answer.
    none,
    /// A reading turn on a watched thread: nothing changes, anywhere.
    read,
    /// A working turn on a watched thread: this checkout changes, the world
    /// outside it does not.
    work,
};

pub const Verdict = union(enum) {
    /// The request reaches the person, as it always did.
    ask,
    /// Refused here; the reason is for the agent and the log.
    deny: []const u8,
};

/// Never, whatever the guard: these leave the machine or rewrite history.
const leaving = [_][]const u8{
    "git push",
    "git send-email",
    "git filter-branch",
    "git reset --hard",
    "git clean -fd",
    "gh pr merge",
    "gh pr close",
    "gh pr create",
    "gh pr edit",
    "gh pr review",
    "gh pr comment",
    "gh issue close",
    "gh issue create",
    "gh issue edit",
    "gh issue delete",
    "gh issue comment",
    "gh release",
    "gh repo",
    "gh workflow",
    "gh secret",
    "gh variable",
    "gh auth",
    "npm publish",
    "cargo publish",
    "docker push",
    "sudo",
    "rm -rf",
    "ssh",
    "scp",
};

/// Refused on a reading turn as well: anything that writes a file. Output sent
/// to a file is refused too, in `redirects`.
const writing = [_][]const u8{
    "git add",
    "git commit",
    "git checkout",
    "git switch",
    "git stash",
    "git restore",
    "git apply",
    "git merge",
    "git rebase",
    "git tag",
    "git init",
    "git worktree",
    "sed -i",
    "tee",
    "mv",
    "cp",
    "rm",
    "mkdir",
    "touch",
    "chmod",
    "chown",
    "npm install",
    "npm i",
    "npm run",
    "npx",
    "pnpm",
    "yarn",
    "pip install",
    "cargo build",
    "cargo run",
    "cargo test",
    "go build",
    "go test",
    "make",
    "zig build",
    "docker run",
    "docker build",
};

/// What to do with one permission request: `kind` is ACP's tool-call kind
/// (read, edit, delete, move, search, execute, think, fetch, other), `title`
/// what the agent calls it.
pub fn verdict(guard: Guard, kind: []const u8, title: []const u8) Verdict {
    switch (guard) {
        .none => return .ask,
        .read => {
            // Editing tools need no title to be recognised.
            if (std.mem.eql(u8, kind, "edit") or std.mem.eql(u8, kind, "delete") or std.mem.eql(u8, kind, "move")) {
                return .{ .deny = "a reading turn does not change the repository" };
            }
            if (hit(&leaving, title) or hit(&writing, title) or redirects(title)) {
                return .{ .deny = "a reading turn only reads: this is a working turn's job" };
            }
        },
        .work => {
            if (hit(&leaving, title)) {
                return .{ .deny = "the world outside this checkout waits for the person" };
            }
        },
    }
    return .ask;
}

/// Whether one of `list` is run in `title`. The words of a pattern must appear
/// as whole words, in order, so `git -C dir push` is `git push` while
/// `git log --grep pushed` is not, and `removed` is none of `rm`.
fn hit(list: []const []const u8, title: []const u8) bool {
    var title_scratch: [512]u8 = undefined;
    var title_words: [max_words][]const u8 = undefined;
    const said = words(&title_scratch, &title_words, title);
    if (said.len == 0) return false;
    for (list) |p| {
        var pat_scratch: [64]u8 = undefined;
        var pat_words: [12][]const u8 = undefined;
        const want = words(&pat_scratch, &pat_words, p);
        if (want.len > 0 and found(said, want)) return true;
    }
    return false;
}

/// The most words a title is torn into. A longer title is cut, which can lose
/// a match but never invent one.
const max_words = 256;

/// `text` lowercased and torn into words, quotes and punctuation off, into
/// `buf`.
fn words(scratch: []u8, buf: [][]const u8, text: []const u8) [][]const u8 {
    const n = @min(text.len, scratch.len);
    for (text[0..n], scratch[0..n]) |c, *b| b.* = std.ascii.toLower(c);
    var count: usize = 0;
    var it = std.mem.tokenizeAny(u8, scratch[0..n], " \t\r\n;&|<>()[]{},'\"`");
    while (it.next()) |w| {
        if (count == buf.len) break;
        const word = std.mem.trim(u8, w, "\"'`");
        if (word.len == 0) continue;
        buf[count] = word;
        count += 1;
    }
    return buf[0..count];
}

/// Whether `want` appears in `said` in order, with flags (and the values they
/// take) allowed in between: `git -C /tmp/x push` runs `git push`.
fn found(said: []const []const u8, want: []const []const u8) bool {
    var i: usize = 0;
    while (i < said.len) : (i += 1) {
        if (!std.mem.eql(u8, said[i], want[0])) continue;
        var k: usize = 1;
        var j = i + 1;
        while (k < want.len and j < said.len) {
            if (std.mem.eql(u8, said[j], want[k])) {
                k += 1;
                j += 1;
            } else if (said[j].len > 1 and said[j][0] == '-') {
                // A flag, and the value a short one carries, stand aside.
                const short = said[j].len == 2;
                j += 1;
                if (short and j < said.len and said[j][0] != '-') j += 1;
            } else break;
        }
        if (k == want.len) return true;
    }
    return false;
}

/// Whether the command in `title` writes a file: output sent to anything other
/// than the terminal, a descriptor or `/dev/null`.
fn redirects(title: []const u8) bool {
    var i: usize = 0;
    while (i < title.len) : (i += 1) {
        if (title[i] != '>') continue;
        var j = i + 1;
        if (j < title.len and (title[j] == '&' or title[j] == '|')) continue;
        if (j < title.len and title[j] == '>') j += 1;
        while (j < title.len and (title[j] == ' ' or title[j] == '\t')) j += 1;
        if (j >= title.len) return false;
        const rest = title[j..];
        if (std.mem.startsWith(u8, rest, "&")) continue;
        if (std.mem.startsWith(u8, rest, "/dev/null")) continue;
        return true;
    }
    return false;
}

test "gates: a reading turn only reads" {
    try std.testing.expect(verdict(.read, "read", "Read file src/main.zig") == .ask);
    try std.testing.expect(verdict(.read, "search", "Search for fn run") == .ask);
    try std.testing.expect(verdict(.read, "edit", "Edit file src/main.zig") == .deny);
    try std.testing.expect(verdict(.read, "delete", "Delete src/main.zig") == .deny);
    try std.testing.expect(verdict(.read, "execute", "Run command: gh pr comment 12 --body ok") == .deny);
    try std.testing.expect(verdict(.read, "execute", "Run command: git commit -am fix") == .deny);
    try std.testing.expect(verdict(.read, "execute", "Run command: zig build test") == .deny);
    // Reading the repository with gh and git stays allowed.
    try std.testing.expect(verdict(.read, "execute", "Run command: gh pr view 12 --json files") == .ask);
    try std.testing.expect(verdict(.read, "execute", "Run command: git log -5 --oneline") == .ask);
    try std.testing.expect(verdict(.read, "execute", "Run command: git log 2>/dev/null | head -20") == .ask);
    // A write hidden behind a shell, a flag or a quote is still a write.
    try std.testing.expect(verdict(.read, "execute", "Run command: bash -lc \"git commit -am fix\"") == .deny);
    try std.testing.expect(verdict(.read, "execute", "Run command: git -C /tmp/x checkout main") == .deny);
    try std.testing.expect(verdict(.read, "execute", "Run command: git log > notes.txt") == .deny);
    try std.testing.expect(verdict(.read, "execute", "Run command: gh pr view 12 >> notes.txt") == .deny);
    // Words that hold a pattern inside them are not the pattern.
    // Words inside a pattern are still words: a reading turn is told no when
    // the command it gives names one, however deep.
    try std.testing.expect(verdict(.read, "execute", "Run command: rg 'git push' src/") == .deny);
    try std.testing.expect(verdict(.read, "execute", "Run command: git log --grep removed") == .ask);
}

test "gates: a working turn changes this checkout, not the world" {
    try std.testing.expect(verdict(.work, "edit", "Edit file src/threads.zig") == .ask);
    try std.testing.expect(verdict(.work, "execute", "Run command: git commit -am \"Fix the thing\"") == .ask);
    try std.testing.expect(verdict(.work, "execute", "Run command: zig build test") == .ask);
    try std.testing.expect(verdict(.work, "execute", "Run command: git push origin fix/thing") == .deny);
    try std.testing.expect(verdict(.work, "execute", "Run command: gh pr merge 12 --squash") == .deny);
    try std.testing.expect(verdict(.work, "execute", "Run command: sudo rm -rf /") == .deny);
    try std.testing.expect(verdict(.work, "execute", "Run command: git reset --hard origin/main") == .deny);
    // However the command is spelled, what leaves is refused.
    try std.testing.expect(verdict(.work, "execute", "Run command: git -C /tmp/x push origin main") == .deny);
    try std.testing.expect(verdict(.work, "execute", "Run command: sh -c 'gh pr create --fill'") == .deny);
    try std.testing.expect(verdict(.work, "execute", "Run command: git push") == .deny);
    try std.testing.expect(verdict(.work, "execute", "Run command: git log --grep pushed") == .ask);
}

test "gates: the person's own tab asks everything" {
    try std.testing.expect(verdict(.none, "edit", "Edit file src/main.zig") == .ask);
    try std.testing.expect(verdict(.none, "execute", "Run command: git push --force") == .ask);
}

test "gates: a title is matched however the agent capitalises it" {
    try std.testing.expect(verdict(.work, "execute", "Run command: GIT PUSH origin HEAD") == .deny);
    try std.testing.expect(verdict(.read, "execute", "Run command: Git Commit -m wip") == .deny);
}
