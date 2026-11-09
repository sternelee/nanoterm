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
    aw.writer.end = 0;
    Phone.agentLine(&aw.writer, 3, "claude");
    try std.testing.expectEqualStrings(
        \\{"op":"agent","session":3,"text":"claude"}
        \\
    , aw.written());
    aw.writer.end = 0;
    Phone.modelLine(&aw.writer, 3, "opus", "anthropic");
    try std.testing.expectEqualStrings(
        \\{"op":"model","session":3,"text":"opus","provider":"anthropic"}
        \\
    , aw.written());
    aw.writer.end = 0;
    Phone.modelsLine(&aw.writer, 3);
    try std.testing.expectEqualStrings(
        \\{"op":"models","session":3}
        \\
    , aw.written());
}

test "a session says its agent and model, and the choices it offers" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.event(
        \\{"seq":1,"kind":"session","id":3,"title":"web","cwd":"/tmp/web","mode":"agent","agent":"Claude Code","agent_key":"claude","agent_status":"ready","model":"sonnet","models":[{"value":"sonnet","name":"Sonnet","provider":""},{"value":"opus","name":"Opus","provider":""}],"agents":[{"key":"agent","name":"Agent"},{"key":"claude","name":"Claude Code"}]}
    );
    try std.testing.expectEqual(@as(usize, 1), p.sessions.items.len);
    const tab = p.currentTab() orelse return error.NoTab;
    try std.testing.expectEqualStrings("web", tab.title);
    try std.testing.expectEqualStrings("Claude Code", tab.agent);
    try std.testing.expectEqualStrings("claude", tab.agent_key);
    try std.testing.expectEqualStrings("ready", tab.agent_status);
    try std.testing.expectEqualStrings("sonnet", tab.model);
    try std.testing.expectEqual(@as(usize, 2), tab.models.items.len);
    try std.testing.expectEqualStrings("opus", tab.models.items[1].value);
    try std.testing.expectEqual(@as(usize, 2), p.agents.items.len);
    try std.testing.expectEqualStrings("Agent", p.agents.items[0].name);
    // The agent switched: the same tab, with new choices.
    p.event(
        \\{"seq":2,"kind":"session","id":3,"title":"web","cwd":"/tmp/web","mode":"agent","agent":"Pi","agent_key":"pi","agent_status":"starting","model":"default model","models":[{"value":"openai/gpt-5","name":"GPT-5","provider":"openai"}],"agents":[{"key":"agent","name":"Agent"},{"key":"pi","name":"Pi"}]}
    );
    try std.testing.expectEqual(@as(usize, 1), p.sessions.items.len);
    try std.testing.expectEqualStrings("pi", tab.agent_key);
    try std.testing.expectEqualStrings("starting", tab.agent_status);
    try std.testing.expectEqual(@as(usize, 1), tab.models.items.len);
    try std.testing.expectEqualStrings("openai", tab.models.items[0].provider);
    try std.testing.expectEqual(@as(usize, 2), p.agents.items.len);
    try std.testing.expectEqualStrings("Pi", p.agents.items[1].name);
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
    try std.testing.expectEqual(@as(usize, 1), p.feed.items.len);
    try std.testing.expectEqualStrings("stop sent to tab 3", p.feed.items[0].line.text);
    p.session = 0;
    p.interrupt();
    try std.testing.expectEqualStrings("no tab to stop: is the workstation's relay up?", p.feed.items[1].line.text);
}

test "a command typed here is sent, and the box empties" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.input.set("echo typed-on-the-phone");
    p.submit();
    try std.testing.expectEqual(@as(usize, 0), p.input.text().len);
    // No echo of its own: the relay's block is the record, as on the desktop.
    try std.testing.expectEqual(@as(usize, 0), p.feed.items.len);
    // Nothing to send to: it says so, and keeps what was typed.
    p.session = 0;
    p.input.set("ls");
    p.submit();
    try std.testing.expectEqualStrings("ls", p.input.text());
    try std.testing.expectEqualStrings("no tab to send to: is the workstation's relay up?", p.feed.items[0].line.text);
}

test "Connect validates, saves, and opens when the fields are right" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.host_input.set("127.0.0.1");
    p.port_input.set("59999");
    p.token_input.set("0123456789abcdef0123456789abcdef");
    // Use a port that's not listening, so the dial fails and status is
    // .down: the fields were still taken, and the file was written. The
    // connect is dialed off the UI thread; wait for it, as the test would.
    p.connect();
    p.dialWait();
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

test "a turn arrives as its own snapshot, again and again" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.event(
        \\{"seq":1,"kind":"turn","session":3,"id":11,"agent":"claude","prompt":"hi","items":[{"kind":"text","text":"Hel"}]}
    );
    try std.testing.expectEqual(@as(usize, 1), p.feed.items.len);
    try std.testing.expectEqualStrings("claude", p.feed.items[0].turn.agent.items);
    try std.testing.expectEqualStrings("hi", p.feed.items[0].turn.prompt.items);
    try std.testing.expectEqualStrings("Hel", p.feed.items[0].turn.items.items[0].text.items);
    // The text grew between frames: the whole turn replaces the old one,
    // so it is one item saying "Hello", not "Hel" and "Hello".
    p.event(
        \\{"seq":2,"kind":"turn","session":3,"id":11,"agent":"claude","prompt":"hi","items":[{"kind":"text","text":"Hello"}]}
    );
    try std.testing.expectEqual(@as(usize, 1), p.feed.items.len);
    try std.testing.expectEqual(@as(usize, 1), p.feed.items[0].turn.items.items.len);
    try std.testing.expectEqualStrings("Hello", p.feed.items[0].turn.items.items[0].text.items);
}

test "a turn that only grew arrives as the text that is new" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.event(
        \\{"seq":1,"kind":"turn","session":3,"id":11,"done":false,"items":[{"kind":"text","text":"Hel"}]}
    );
    // What came is where the phone's copy ended: the rest is added to it,
    // not made into a second item.
    p.event(
        \\{"seq":2,"kind":"turn","session":3,"id":11,"done":true,"append":{"index":0,"len":3,"text":"lo"}}
    );
    const t = p.feed.items[0].turn;
    try std.testing.expectEqual(@as(usize, 1), t.items.items.len);
    try std.testing.expectEqualStrings("Hello", t.items.items[0].text.items);
    try std.testing.expect(t.done);
    // Not where the relay put it: the phone's copy is not what the relay
    // thinks it is, so the text is left alone until the feed comes whole.
    p.event(
        \\{"seq":3,"kind":"turn","session":3,"id":11,"append":{"index":0,"len":2,"text":"!!!"}}
    );
    try std.testing.expectEqual(@as(usize, 1), t.items.items.len);
    try std.testing.expectEqualStrings("Hello", t.items.items[0].text.items);
    p.event(
        \\{"seq":4,"kind":"turn","session":3,"id":11,"append":{"index":4,"len":0,"text":"?"}}
    );
    try std.testing.expectEqualStrings("Hello", t.items.items[0].text.items);
    // A thought's text grows the same way.
    p.event(
        \\{"seq":5,"kind":"turn","session":3,"id":11,"items":[{"kind":"text","text":"Hello"},{"kind":"thought","text":"thin"}]}
    );
    p.event(
        \\{"seq":6,"kind":"turn","session":3,"id":11,"append":{"index":1,"len":4,"text":"king"}}
    );
    try std.testing.expectEqualStrings("thinking", p.feed.items[0].turn.items.items[1].thought.items);
}

test "a turn's items keep the shape the desktop draws" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.event(
        \\{"seq":1,"kind":"turn","session":3,"id":11,"items":[
        \\  {"kind":"thought","text":"thinking"},
        \\  {"kind":"tool","id":"t1","tool":"read","title":"README.md","detail":"# hi","status":"completed"},
        \\  {"kind":"tool","id":"t2","tool":"execute","title":"ls","status":"failed","block":7},
        \\  {"kind":"plan","entries":[{"text":"read","status":"completed"},{"text":"write","status":"in_progress"}]},
        \\  {"kind":"command","block":8}
        \\]}
    );
    const items = p.feed.items[0].turn.items.items;
    try std.testing.expectEqual(@as(usize, 5), items.len);
    try std.testing.expectEqualStrings("thinking", items[0].thought.items);
    try std.testing.expectEqualStrings("read", items[1].tool.kind.items);
    try std.testing.expectEqualStrings("README.md", items[1].tool.title.items);
    try std.testing.expectEqual(main.Item.ToolStatus.completed, items[1].tool.status);
    try std.testing.expectEqual(main.Item.ToolStatus.failed, items[2].tool.status);
    try std.testing.expectEqual(@as(?u64, 7), items[2].tool.block);
    try std.testing.expectEqualStrings("write", items[3].plan.items[1].text.items);
    try std.testing.expectEqualStrings("in_progress", items[3].plan.items[1].status.items);
    try std.testing.expectEqual(@as(u64, 8), items[4].command);
}

test "a command block arrives whole, output and all" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    p.event(
        \\{"seq":1,"kind":"block","session":3,"id":2,"source":"agent","command":"echo hi","cwd":"/tmp","branch":"main","state":"running","started":5,"output":"hi\n"}
    );
    try std.testing.expectEqual(@as(usize, 1), p.feed.items.len);
    const b = p.feed.items[0].block;
    try std.testing.expect(b.is_agent);
    try std.testing.expectEqualStrings("echo hi", b.command.items);
    try std.testing.expectEqualStrings("hi\n", b.output.items);
    try std.testing.expect(!b.failed());
    // Done with a bad exit: the same block, now failed.
    p.event(
        \\{"seq":2,"kind":"block","session":3,"id":2,"source":"agent","command":"echo hi","cwd":"/tmp","branch":"main","state":"done","exit":2,"started":5,"ended":6,"output":"hi\n"}
    );
    try std.testing.expectEqual(@as(usize, 1), p.feed.items.len);
    const done = p.feed.items[0].block;
    try std.testing.expectEqual(@as(?i32, 2), done.exit);
    try std.testing.expect(done.failed());
}

test "the composer sends what was typed, and says when there is no tab" {
    const p = try phone(std.testing.allocator);
    defer p.destroy();
    // Nothing connected: the composer says so rather than sending to nowhere.
    p.session = 0;
    p.input.set("ls");
    p.submit();
    try std.testing.expectEqualStrings("no tab to send to: is the workstation's relay up?", p.feed.items[0].line.text);
    // With a tab: it sends, empties the box, and leaves the feed to the relay.
    p.session = 1;
    p.input.set("echo hi");
    p.submit();
    try std.testing.expectEqual(@as(usize, 0), p.input.text().len);
    try std.testing.expectEqual(@as(usize, 1), p.feed.items.len);
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
