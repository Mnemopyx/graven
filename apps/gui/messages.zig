//! The log: every message the app gives the user (status, warnings,
//! errors, the checks' notices), kept in order for the Log pane.
//!
//! One path in (decided 2026-11-27): code says something with `post`
//! (main.zig's `say`, which also puts it on the status line); a message
//! set on the status line any other way is taken in once a frame as well,
//! so nothing shown is lost. The same message again straight after is
//! counted (×3), not repeated. The oldest go once there are `capacity`.
//!
//! Window-free, so it is tested on its own.

const std = @import("std");

pub const Level = enum {
    info,
    warning,
    @"error",

    pub fn name(l: Level) []const u8 {
        return switch (l) {
            .info => "Info",
            .warning => "Warning",
            .@"error" => "Error",
        };
    }
};

pub const Entry = struct {
    level: Level,
    /// Owned.
    text: []u8,
    /// When it was last said, seconds since the epoch.
    time: i64,
    /// How many times in a row it was said.
    count: u32 = 1,
};

pub const capacity = 500;

pub const Log = struct {
    gpa: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// Bumped on every change, so a view can tell it moved.
    revision: u64 = 0,
    /// Warnings and errors said since the log was last looked at.
    unseen: u32 = 0,
    /// Of those, the worst.
    unseen_level: Level = .info,

    pub fn init(gpa: std.mem.Allocator) Log {
        return .{ .gpa = gpa };
    }

    pub fn deinit(l: *Log) void {
        for (l.entries.items) |e| l.gpa.free(e.text);
        l.entries.deinit(l.gpa);
    }

    /// Says `text` (trimmed; nothing when empty) at `level`, at `time`.
    pub fn post(l: *Log, level: Level, text: []const u8, time: i64) void {
        const t = std.mem.trim(u8, text, " \t\r\n");
        if (t.len == 0) return;
        l.revision +%= 1;
        if (level != .info) {
            l.unseen +|= 1;
            if (@intFromEnum(level) > @intFromEnum(l.unseen_level)) l.unseen_level = level;
        }
        if (l.entries.items.len > 0) {
            const last = &l.entries.items[l.entries.items.len - 1];
            if (last.level == level and std.mem.eql(u8, last.text, t)) {
                last.count +|= 1;
                last.time = time;
                return;
            }
        }
        const owned = l.gpa.dupe(u8, t) catch return;
        if (l.entries.items.len >= capacity) {
            l.gpa.free(l.entries.items[0].text);
            _ = l.entries.orderedRemove(0);
        }
        l.entries.append(l.gpa, .{ .level = level, .text = owned, .time = time }) catch l.gpa.free(owned);
    }

    pub fn postFmt(l: *Log, level: Level, time: i64, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        l.post(level, std.fmt.bufPrint(&buf, fmt, args) catch return, time);
    }

    /// The log was looked at: nothing unseen.
    pub fn seen(l: *Log) void {
        l.unseen = 0;
        l.unseen_level = .info;
    }

    pub fn clear(l: *Log) void {
        for (l.entries.items) |e| l.gpa.free(e.text);
        l.entries.clearRetainingCapacity();
        l.seen();
        l.revision +%= 1;
    }
};

/// The level of a message set on the status line without one: what failed
/// or was refused is a warning, the rest information.
pub fn guessLevel(text: []const u8) Level {
    const warn = [_][]const u8{ "could not", "was not", "were not", "cannot", "failed", "not written", "is not there", "not found", "Not a ", "not a " };
    for (warn) |w| if (std.mem.indexOf(u8, text, w) != null) return .warning;
    return .info;
}

test "repeats are counted, the oldest go, warnings are unseen until looked at" {
    var l = Log.init(std.testing.allocator);
    defer l.deinit();
    l.post(.info, "Saved. ", 1);
    l.post(.info, "Saved.", 2);
    try std.testing.expectEqual(1, l.entries.items.len);
    try std.testing.expectEqual(2, l.entries.items[0].count);
    try std.testing.expectEqualStrings("Saved.", l.entries.items[0].text);
    l.post(.warning, "The SVG could not be made.", 3);
    l.post(.info, "  ", 4);
    try std.testing.expectEqual(2, l.entries.items.len);
    try std.testing.expectEqual(1, l.unseen);
    try std.testing.expectEqual(Level.warning, l.unseen_level);
    l.seen();
    try std.testing.expectEqual(0, l.unseen);
    for (0..capacity + 5) |i| l.postFmt(.info, 5, "n {d}", .{i});
    try std.testing.expectEqual(capacity, l.entries.items.len);
    try std.testing.expectEqualStrings("n 5", l.entries.items[0].text);
    try std.testing.expectEqual(Level.warning, guessLevel("The document could not be written there. "));
    try std.testing.expectEqual(Level.info, guessLevel("Framed: all of it, legible. "));
}
