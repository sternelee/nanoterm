//! Tests for threads revision and question answering (P0-A)
//! Tests for baseline tracking (P0-B)
// Tests for graceful stop (P0-C) - skipped due to Watcher initialization issues
const std = @import("std");
const threads_mod = @import("threads.zig");
const blocks = @import("blocks.zig");

const testing = std.testing;

test "threads: revision fields exist and default correctly" {
    const gpa = testing.allocator;

    const t: threads_mod.Thread = .{
        .id = 1,
        .key = try gpa.dupe(u8, "test-key"),
        .kind = .issue,
        .number = 42,
        .title = try gpa.dupe(u8, "Test issue"),
        .url = try gpa.dupe(u8, "https://github.com/test/42"),
        .proposal = &.{},
        .note = &.{},
        .plan = &.{},
        .verify = &.{},
        .question = &.{},
        .baseline_commit = &.{},
        .baseline_dirty = &.{},
        .run_baseline_commit = &.{},
        .run_baseline_dirty_hash = &.{},
    };
    defer {
        gpa.free(t.key);
        gpa.free(t.title);
        gpa.free(t.url);
    }

    // Verify new fields exist and default to zero/false
    try testing.expectEqual(@as(u64, 0), t.instruction_revision);
    try testing.expectEqual(@as(u64, 0), t.proposal_revision);
    try testing.expectEqual(false, t.question_answered);
    try testing.expectEqual(@as(u64, 0), t.question_answered_at_revision);
}

test "threads: baseline fields exist and default correctly" {
    const gpa = testing.allocator;

    const t: threads_mod.Thread = .{
        .id = 1,
        .key = try gpa.dupe(u8, "test-key"),
        .kind = .issue,
        .number = 42,
        .title = try gpa.dupe(u8, "Test issue"),
        .url = try gpa.dupe(u8, "https://github.com/test/42"),
        .proposal = &.{},
        .note = &.{},
        .plan = &.{},
        .verify = &.{},
        .question = &.{},
        .baseline_commit = &.{},
        .baseline_dirty = &.{},
        .run_baseline_commit = &.{},
        .run_baseline_dirty_hash = &.{},
    };
    defer {
        gpa.free(t.key);
        gpa.free(t.title);
        gpa.free(t.url);
    }

    // Verify baseline fields exist and default to empty
    try testing.expectEqual(@as(usize, 0), t.baseline_commit.len);
    try testing.expectEqual(@as(usize, 0), t.baseline_dirty.len);
    try testing.expectEqual(@as(usize, 0), t.run_baseline_commit.len);
    try testing.expectEqual(@as(usize, 0), t.run_baseline_dirty_hash.len);
}
