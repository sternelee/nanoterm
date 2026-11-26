//! The fonts Settings offers for the terminal: the system's, and the
//! monospaced and Nerd families installed (filtered from all of them, so
//! the list stays a list). macOS asks AppKit's font manager; elsewhere
//! well-known terminal families are offered, and any family the user has
//! kept.
const std = @import("std");
const builtin = @import("builtin");
const nanoui = @import("nanoui");
const objc = nanoui.objc;

pub const Registry = struct {
    /// "System" first, then the installed terminal and Nerd families.
    options: std.ArrayList([]const u8) = .empty,
    loaded: bool = false,

    /// Loads the families once, keeping the font the user chose even if
    /// it is no longer (or never was) in the filtered list.
    pub fn ensure(r: *Registry, gpa: std.mem.Allocator, io: std.Io, current: []const u8) void {
        _ = io;
        if (r.loaded) return;
        r.loaded = true;
        const system = gpa.dupe(u8, "System") catch "";
        if (system.len > 0) r.options.append(gpa, system) catch return;
        switch (builtin.os.tag) {
            .macos => loadInstalled(r, gpa),
            else => addFallbacks(r, gpa),
        }
        if (current.len > 0 and !contains(r, current)) {
            const kept = gpa.dupe(u8, current) catch return;
            r.options.append(gpa, kept) catch gpa.free(kept);
        }
        sortFamilies(r);
    }

    pub fn deinit(r: *Registry, gpa: std.mem.Allocator) void {
        for (r.options.items) |name| gpa.free(name);
        r.options.deinit(gpa);
    }
};

fn contains(r: *const Registry, name: []const u8) bool {
    for (r.options.items) |option| if (std.mem.eql(u8, option, name)) return true;
    return false;
}

/// "System" stays first; the rest are alphabetical.
fn sortFamilies(r: *Registry) void {
    if (r.options.items.len < 2) return;
    std.mem.sort([]const u8, r.options.items[1..], {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
}

/// The terminal families offered where the system's list isn't asked:
/// a starter set, plus Nerd variants a user may have installed.
const fallback_families = [_][]const u8{
    "Andale Mono",              "Cascadia Code",    "Cascadia Mono",           "Consolas",
    "Courier New",              "DejaVu Sans Mono", "Fira Code",               "FiraCode Nerd Font",
    "Geist Mono",               "Hack",             "Hack Nerd Font",          "IBM Plex Mono",
    "Iosevka",                  "JetBrains Mono",   "JetBrainsMono Nerd Font", "Liberation Mono",
    "Menlo",                    "MesloLGS NF",      "Monaco",                  "Noto Sans Mono",
    "Sauce Code Pro Nerd Font", "SF Mono",          "Source Code Pro",         "Symbols Nerd Font",
    "Symbols Nerd Font Mono",   "Ubuntu Mono",
};

fn addFallbacks(r: *Registry, gpa: std.mem.Allocator) void {
    for (fallback_families) |family| {
        const name = gpa.dupe(u8, family) catch continue;
        r.options.append(gpa, name) catch gpa.free(name);
    }
}

/// A family worth a terminal: monospaced, or a Nerd variant, or one of
/// the system's monospaced faces whose name says nothing about it.
fn terminalFamily(family: []const u8) bool {
    var lower_buf: [128]u8 = undefined;
    if (family.len > lower_buf.len) return false;
    const lower = std.ascii.lowerString(&lower_buf, family);
    if (std.mem.indexOf(u8, lower, "mono") != null) return true;
    if (std.mem.indexOf(u8, lower, "nerd") != null) return true;
    if (std.mem.endsWith(u8, lower, "nf")) return true;
    const known = [_][]const u8{
        "andale mono",   "menlo",       "monaco",     "courier",       "courier new",
        "courier prime", "consolas",    "sf mono",    "cascadia code", "cascadia mono",
        "input mono",    "victor mono", "space mono",
    };
    for (known) |name| if (std.mem.eql(u8, lower, name)) return true;
    return false;
}

fn loadInstalled(r: *Registry, gpa: std.mem.Allocator) void {
    const manager = objc.msg(objc.Object, objc.class("NSFontManager"), "sharedFontManager", .{});
    const families = objc.msg(objc.Object, manager, "availableFontFamilies", .{});
    const count = objc.msg(objc.NSUInteger, families, "count", .{});
    for (0..count) |i| {
        const family = objc.msg(?objc.Object, families, "objectAtIndex:", .{i}) orelse continue;
        const name = objc.fromNSString(family);
        if (name.len == 0 or !terminalFamily(name)) continue;
        const copy = gpa.dupe(u8, name) catch continue;
        r.options.append(gpa, copy) catch gpa.free(copy);
    }
    if (r.options.items.len == 0) addFallbacks(r, gpa);
}
