//! What the phone makes of the relay's events, and what it sends back:
//! no socket, no window — the parts that decide what a tap means.
const std = @import("std");
const main = @import("main.zig");
const Phone = main.Phone;

/// A phone with nothing connected: events in, no socket out.
fn phone(gpa: std.mem.Allocator) !*Phone {
    const p = try gpa.create(Phone);
    p.* = .{ .gpa = gpa, .io = std.testing.io, .arena_state = .init(gpa) };
    p.session = 3;
    return p;
}

test "a turn's permission becomes a card with its options" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.event(
        \\{"seq":7,"kind":"turn","session":3,"id":11,"agent":"claude","prompt":"fix it","items":[{"kind":"text","text":"reading the file"},{"kind":"permission","rpc":"9","title":"Run this command?","options":[{"id":"yes","name":"Allow"},{"id":"no","name":"Deny"}],"chosen":null}]}
    );
    try std.testing.expectEqual(@as(usize, 1), p.pending.items.len);
    const q = p.pending.items[0];
    try std.testing.expectEqualStrings("9", q.rpc);
    try std.testing.expectEqualStrings("Run this command?", q.title);
    try std.testing.expectEqual(@as(usize, 2), q.options.items.len);
    try std.testing.expectEqualStrings("Deny", q.options.items[1]);
    // The same question again, in the next frame's event: one card.
    p.event(
        \\{"seq":8,"kind":"turn","session":3,"id":11,"agent":"claude","items":[{"kind":"permission","rpc":"9","title":"Run this command?","options":[{"id":"yes","name":"Allow"},{"id":"no","name":"Deny"}],"chosen":null}]}
    );
    try std.testing.expectEqual(@as(usize, 1), p.pending.items.len);
}

test "a permission answered at the workstation takes its card away" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.event(
        \\{"seq":7,"kind":"turn","session":3,"id":11,"items":[{"kind":"permission","rpc":"9","title":"Run this command?","options":[{"id":"yes","name":"Allow"}],"chosen":null}]}
    );
    try std.testing.expectEqual(@as(usize, 1), p.pending.items.len);
    p.event(
        \\{"seq":9,"kind":"turn","session":3,"id":11,"items":[{"kind":"permission","rpc":"9","title":"Run this command?","options":[{"id":"yes","name":"Allow"}],"chosen":0}]}
    );
    try std.testing.expectEqual(@as(usize, 0), p.pending.items.len);
}

test "a tab's welcome is the tab the composer sends to" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.session = 0;
    p.event(
        \\{"seq":1,"kind":"welcome","protocol":1,"port":4789,"sessions":[4,5]}
    );
    try std.testing.expectEqual(@as(u64, 4), p.session);
    try std.testing.expectEqual(@as(usize, 2), p.tabs);
    // It closes: nothing to send to, and the composer says so rather than
    // sending to a tab that is gone.
    p.event(
        \\{"seq":2,"kind":"gone","id":4}
    );
    try std.testing.expectEqual(@as(u64, 0), p.session);
}

test "what the composer sends is what the relay reads" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    Phone.opLine(&aw.writer, "run", 3, "echo \"hi\" && ls");
    try std.testing.expectEqualStrings(
        \\{"op":"run","session":3,"text":"echo \"hi\" && ls"}
        \\
    , aw.written());
    aw.writer.end = 0;
    Phone.opLine(&aw.writer, "ask", 7, "what broke?");
    try std.testing.expectEqualStrings(
        \\{"op":"ask","session":7,"text":"what broke?"}
        \\
    , aw.written());
    aw.writer.end = 0;
    Phone.answerLine(&aw.writer, 3, "9", 1);
    try std.testing.expectEqualStrings(
        \\{"op":"answer","session":3,"rpc":"9","option":1}
        \\
    , aw.written());
    aw.writer.end = 0;
    Phone.interruptLine(&aw.writer, 5);
    try std.testing.expectEqualStrings(
        \\{"op":"interrupt","session":5}
        \\
    , aw.written());
}

test "Stop is offered while something runs, and stops when it is done" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    try std.testing.expectEqual(@as(usize, 0), p.running.items.len);
    // A command starts here, an agent's turn there: both are running.
    p.event(
        \\{"seq":1,"kind":"block","session":3,"id":2,"command":"sleep 9","state":"running"}
    );
    p.event(
        \\{"seq":2,"kind":"turn","session":3,"id":2,"done":false,"items":[]}
    );
    try std.testing.expectEqual(@as(usize, 2), p.running.items.len);
    // The block finishes: the turn (same id, another kind) still runs.
    p.event(
        \\{"seq":3,"kind":"block","session":3,"id":2,"command":"sleep 9","state":"done"}
    );
    try std.testing.expectEqual(@as(usize, 1), p.running.items.len);
    try std.testing.expect(p.running.items[0] != 2);
    p.event(
        \\{"seq":4,"kind":"turn","session":3,"id":2,"done":true,"items":[]}
    );
    try std.testing.expectEqual(@as(usize, 0), p.running.items.len);
    // The same event again changes nothing.
    p.event(
        \\{"seq":5,"kind":"block","session":3,"id":2,"command":"sleep 9","state":"done"}
    );
    try std.testing.expectEqual(@as(usize, 0), p.running.items.len);
}

test "the tap on Stop sends it to the tab, or says there is none" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.interrupt();
    try std.testing.expectEqual(@as(usize, 1), p.entries.items.len);
    try std.testing.expectEqualStrings("stop sent to tab 3", p.entries.items[0].text);
    p.session = 0;
    p.interrupt();
    try std.testing.expectEqualStrings("no tab to stop: is the workstation's relay up?", p.entries.items[1].text);
}

test "a command typed here is sent, echoed, and the box empties" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.input.set("echo typed-on-the-phone");
    p.submit();
    try std.testing.expectEqual(@as(usize, 0), p.input.text().len);
    try std.testing.expectEqual(@as(usize, 1), p.entries.items.len);
    try std.testing.expectEqualStrings("$ echo typed-on-the-phone", p.entries.items[0].text);
    // Nothing to send to: it says so, and keeps what was typed.
    p.session = 0;
    p.input.set("ls");
    p.submit();
    try std.testing.expectEqualStrings("ls", p.input.text());
    try std.testing.expectEqualStrings("no tab to send to: is the workstation's relay up?", p.entries.items[1].text);
}


test "Connect validates, saves, and opens when the fields are right" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.host_input.set("127.0.0.1");
    p.port_input.set("59999");
    p.token_input.set("0123456789abcdef0123456789abcdef");
    // Use a port that's not listening, so open() fails and status is .down:
    // the fields were still taken, and the file was written. The connection
    // failure is now shown to the user via connectFail().
    p.connect();
    try std.testing.expectEqualStrings("127.0.0.1", p.host[0..p.host_len]);
    try std.testing.expectEqual(@as(u16, 59999), p.port);
    try std.testing.expect(p.has_token);
    try std.testing.expect(p.connect_why_len > 0); // Connection refused is shown
    // A wrong token is refused before anything is tried.
    p.token_input.set("short");
    p.connect();
    try std.testing.expect(p.connect_why_len > 0);
    // An empty host, likewise.
    p.host_input.set("");
    p.token_input.set("0123456789abcdef0123456789abcdef");
    p.connect();
    try std.testing.expect(p.connect_why_len > 0);
}

test "welcome adds tabs, gone removes them, tapping switches" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.event(
        \\{"seq":1,"kind":"welcome","protocol":1,"port":4789,"sessions":[4,5]}
    );
    try std.testing.expectEqual(@as(usize, 2), p.sessions.items.len);
    // p.session is already 3 from the helper: welcome only sets it when 0.
    // A second welcome with the same tabs: no duplicates.
    p.event(
        \\{"seq":2,"kind":"welcome","protocol":1,"port":4789,"sessions":[4,5]}
    );
    try std.testing.expectEqual(@as(usize, 2), p.sessions.items.len);
    // A third tab appears.
    p.event(
        \\{"seq":3,"kind":"welcome","protocol":1,"port":4789,"sessions":[4,5,6]}
    );
    try std.testing.expectEqual(@as(usize, 3), p.sessions.items.len);
    // One closes.
    p.event(
        \\{"seq":4,"kind":"gone","id":5}
    );
    try std.testing.expectEqual(@as(usize, 2), p.sessions.items.len);
    var found = false;
    for (p.sessions.items) |s| {
        if (s.id == 5) {
            found = true;
            break;
        }
    }
    try std.testing.expect(!found);
}

test "addEntry makes typed entries" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.addEntry(.command, "echo hi", 3);
    p.addEntry(.agent_reply, "reading the file", 3);
    p.addEntry(.output, "hello", 3);
    p.addEntry(.system, "test message", 0);
    try std.testing.expectEqual(@as(usize, 4), p.entries.items.len);
    try std.testing.expectEqual(p.entries.items[0].kind, .command);
    try std.testing.expectEqual(p.entries.items[1].kind, .agent_reply);
    try std.testing.expectEqual(p.entries.items[2].kind, .output);
    try std.testing.expectEqual(p.entries.items[3].kind, .system);
    try std.testing.expectEqualStrings("echo hi", p.entries.items[0].text);
}

test "the composer echoes what it sends, and says when there is no tab" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    // Nothing connected: the composer says so rather than sending to nowhere.
    p.session = 0;
    p.input.set("ls");
    p.submit();
    try std.testing.expectEqualStrings("no tab to send to: is the workstation's relay up?", p.entries.items[0].text);
    // With a tab: it sends, echoes, and empties the box.
    p.session = 1;
    p.input.set("echo hi");
    p.submit();
    try std.testing.expectEqualStrings("$ echo hi", p.entries.items[1].text);
    try std.testing.expectEqual(@as(usize, 0), p.input.text().len);
}

test "refresh sends list command when live" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.status = .live;
    p.refresh();
    // Refresh should complete without error when live.
    try std.testing.expect(!p.pull_refreshing);
}

test "refresh does nothing when not connected" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.status = .down;
    p.pull_refreshing = true;
    p.refresh();
    // Should reset the flag but not send anything.
    try std.testing.expect(!p.pull_refreshing);
}

test "gesture tracking fields initialize correctly" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    try std.testing.expect(!p.swipe_tracking);
    try std.testing.expectEqual(@as(f32, 0), p.swipe_start_x);
    try std.testing.expectEqual(@as(f32, 0), p.swipe_start_y);
    try std.testing.expectEqual(@as(f32, 0), p.pull_distance);
    try std.testing.expect(!p.pull_refreshing);
}

test "notify adds a notification to the queue" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    try std.testing.expectEqual(@as(usize, 0), p.notifications.items.len);
    
    p.notify(.info, "test message", .{});
    try std.testing.expectEqual(@as(usize, 1), p.notifications.items.len);
    try std.testing.expectEqual(main.NotificationKind.info, p.notifications.items[0].kind);
    try std.testing.expectEqualStrings("test message", p.notifications.items[0].message);
    
    p.notify(.success, "success!", .{});
    try std.testing.expectEqual(@as(usize, 2), p.notifications.items.len);
}

test "notifications are limited to 5" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    
    for (0..7) |i| {
        p.notify(.info, "message {d}", .{i});
    }
    try std.testing.expectEqual(@as(usize, 5), p.notifications.items.len);
}

test "dismissNotification removes a notification" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    
    p.notify(.info, "first", .{});
    p.notify(.success, "second", .{});
    p.notify(.err, "third", .{});
    try std.testing.expectEqual(@as(usize, 3), p.notifications.items.len);
    
    p.dismissNotification(1);
    try std.testing.expectEqual(@as(usize, 2), p.notifications.items.len);
    try std.testing.expectEqualStrings("first", p.notifications.items[0].message);
    try std.testing.expectEqualStrings("third", p.notifications.items[1].message);
}

test "notification duration varies by kind" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    
    p.notify(.info, "info", .{});
    try std.testing.expectEqual(@as(f32, 3.0), p.notifications.items[0].duration);
    
    p.notify(.success, "success", .{});
    try std.testing.expectEqual(@as(f32, 2.5), p.notifications.items[1].duration);
    
    p.notify(.warning, "warning", .{});
    try std.testing.expectEqual(@as(f32, 4.0), p.notifications.items[2].duration);
    
    p.notify(.err, "error", .{});
    try std.testing.expectEqual(@as(f32, 5.0), p.notifications.items[3].duration);
}
