//! Actions, key modes and keymaps: what a key press may do, named.
//!
//! Everything a key can drive is an **action** with a hierarchical name
//! (`canvas.flow.paste`, `sketch.constraint.coincident`). The name says what
//! it does, never which key does it; it is also the action's message ID for
//! the interface's translations (labels, tooltips, descriptions), so no
//! display text lives here.
//!
//! A **mode** is a state the interface can be in, with a keymap of its own:
//! the start screen, the canvas, a flow being typed into, an equation, a
//! sketch, a dialog. Modes nest (`parent`: canvas → flow → equation), major
//! modes are peers (start, canvas, sketch, panel editing), and a mode may
//! take its keymap from another (`extends`) and add to it or override it:
//! the way a custom mode will be made from a built-in one. A mode that
//! takes typed text (`takes_text`) masks the unchorded printable keys of
//! the modes it sits in: in a flow, `d` types a d, whatever the canvas
//! would make of it.
//!
//! A **binding** ties a chord to an action in a mode, with an optional
//! argument (a direction, a count, a percentage): one action, several keys
//! (`selection.nudge` on all four arrows).
//!
//! All of this is fixed at compile time and checked there: an unknown
//! action, mode or key, an action bound in a mode that does not allow it,
//! the same chord twice in a mode, a mode whose parents or bases loop, an
//! argument an action does not take: each fails the build. What the user
//! or the moment decides (their own keymaps, which modes are active) is
//! the GUI's, at run time.
//!
//! Generic over the key type, so this file has no window behind it and is
//! tested on its own; `keymap.zig` instantiates it for DVUI's keys.

const std = @import("std");
const keys = @import("graven_keys");

/// How a mode relates to the others.
pub const Kind = enum {
    /// Always there, under everything (the app's own keys).
    root,
    /// One of the peers the interface is in one of at a time.
    major,
    /// Nested inside its parent.
    sub,
    /// A toggle layered on whichever major mode is active.
    minor,
    /// A dialog or prompt over the rest.
    dialog,
};

/// How long a mode lasts once entered.
pub const Lifetime = enum {
    /// While the state that makes it holds (a selection, a tool).
    state,
    /// Until it is left (Esc, its own key).
    until_left,
    /// For one more key: a prefix.
    one_shot,
    /// While a key is held.
    while_held,
    /// Toggled on and off.
    toggled,
};

pub const ModeDef = struct {
    name: []const u8,
    kind: Kind,
    lifetime: Lifetime = .state,
    /// The mode it sits in.
    parent: ?[]const u8 = null,
    /// The mode whose keymap it starts from.
    extends: ?[]const u8 = null,
    /// Printable keys type text here.
    takes_text: bool = false,
    /// Name prefixes of the actions it may bind (`canvas.flow` allows
    /// `canvas.flow.paste`); a mode also allows what its base allows.
    allows: []const []const u8 = &.{},
};

/// What an action's argument means.
pub const Param = enum { none, int, direction };

pub const Direction = enum(i32) { left, right, up, down };

pub const ActionDef = struct {
    name: []const u8,
    /// Repeats while its key is held.
    repeat: bool = false,
    param: Param = .none,
};

/// Which systems a binding is for (Ctrl+Y redoes off macOS only).
pub const Os = enum { any, mac, not_mac };

pub const BindDef = struct {
    mode: []const u8,
    /// `[mods+]key`: mods `ctrl`, `shift`, `alt`, `cmd`, `primary` (Cmd on
    /// macOS, else Ctrl); key one of
    /// - a key's name (`z`: the key the layout calls Z);
    /// - `@` and a position (`@D01`: the first key of the first letter row,
    ///   whatever it types; see `graven_keys`);
    /// - a symbol in quotes (`'>'`: the key that types `>` on the layout in
    ///   use, with Shift added where typing it takes Shift). Alone, with no
    ///   modifier, the same as `char:>`.
    /// `^x` is short for `ctrl+'x'` and `^@D01` for `ctrl+@D01`. Or
    /// `char:x`, the character typed (whatever key and layout made it), or
    /// `bind:name`, a text field binding of the toolkit's (word left, copy
    /// …), as the platform has it.
    chord: []const u8,
    action: []const u8,
    arg: i32 = 0,
    os: Os = .any,
};

pub const Mods = struct {
    ctrl: bool = false,
    shift: bool = false,
    alt: bool = false,
    cmd: bool = false,

    /// With a modifier that keeps a key from typing.
    pub fn chorded(m: Mods) bool {
        return m.ctrl or m.alt or m.cmd;
    }

    pub fn eql(a: Mods, b: Mods) bool {
        return a.ctrl == b.ctrl and a.shift == b.shift and a.alt == b.alt and a.cmd == b.cmd;
    }
};

pub fn Chord(comptime Key: type) type {
    return struct {
        what: What,
        mods: Mods = .{},

        pub const What = union(enum) {
            code: Key,
            /// The key at a position on the keyboard.
            pos: keys.Position,
            /// The key that types this symbol (Shift added if it takes it).
            sym: []const u8,
            char: []const u8,
            bind: []const u8,
        };

        pub fn eql(a: @This(), b: @This()) bool {
            if (!a.mods.eql(b.mods)) return false;
            return switch (a.what) {
                .code => |k| b.what == .code and b.what.code == k,
                .pos => |p| b.what == .pos and b.what.pos.eql(p),
                .sym => |s| b.what == .sym and std.mem.eql(u8, s, b.what.sym),
                .char => |s| b.what == .char and std.mem.eql(u8, s, b.what.char),
                .bind => |s| b.what == .bind and std.mem.eql(u8, s, b.what.bind),
            };
        }
    };
}

/// `s` as a chord, at compile time; `mac` decides what `primary` is.
pub fn parseChord(comptime Key: type, comptime s: []const u8, comptime mac: bool) Chord(Key) {
    return comptime parse: {
        if (std.mem.startsWith(u8, s, "char:")) {
            if (s.len == 5) @compileError("empty character in chord \"" ++ s ++ "\"");
            break :parse .{ .what = .{ .char = s[5..] } };
        }
        if (std.mem.startsWith(u8, s, "bind:")) {
            if (s.len == 5) @compileError("empty binding name in chord \"" ++ s ++ "\"");
            break :parse .{ .what = .{ .bind = s[5..] } };
        }
        if (s.len > 1 and s[0] == '^') {
            const rest = s[1..];
            break :parse .{ .what = keyPart(Key, s, rest) orelse symPart(Key, s, rest), .mods = .{ .ctrl = true } };
        }
        // A quoted symbol may be `+` itself: modifiers end before its quote.
        var mods: Mods = .{};
        var rest = s;
        var key_from: ?usize = null;
        for (s, 0..) |ch, i| if (ch == '\'' and (i == 0 or s[i - 1] == '+')) {
            key_from = i;
            break;
        };
        const mod_part = if (key_from) |i| s[0..i] else s;
        if (key_from != null) rest = mod_part;
        while (std.mem.indexOfScalar(u8, rest, '+')) |i| {
            const m = rest[0..i];
            if (std.mem.eql(u8, m, "ctrl")) {
                mods.ctrl = true;
            } else if (std.mem.eql(u8, m, "shift")) {
                mods.shift = true;
            } else if (std.mem.eql(u8, m, "alt")) {
                mods.alt = true;
            } else if (std.mem.eql(u8, m, "cmd")) {
                mods.cmd = true;
            } else if (std.mem.eql(u8, m, "primary")) {
                if (mac) mods.cmd = true else mods.ctrl = true;
            } else @compileError("unknown modifier \"" ++ m ++ "\" in chord \"" ++ s ++ "\"");
            rest = rest[i + 1 ..];
        }
        if (key_from) |i| {
            const q = s[i..];
            if (q.len < 3 or q[q.len - 1] != '\'') @compileError("unclosed symbol in chord \"" ++ s ++ "\"");
            const sym = q[1 .. q.len - 1];
            if (!mods.chorded() and !mods.shift) break :parse .{ .what = .{ .char = sym } };
            break :parse .{ .what = .{ .sym = sym }, .mods = mods };
        }
        if (keyPart(Key, s, rest)) |w| break :parse .{ .what = w, .mods = mods };
        const key = std.meta.stringToEnum(Key, rest) orelse @compileError("unknown key \"" ++ rest ++ "\" in chord \"" ++ s ++ "\"");
        break :parse Chord(Key){ .what = .{ .code = key }, .mods = mods };
    };
}

/// A chord's key part when it is a position (`@D01`).
fn keyPart(comptime Key: type, comptime s: []const u8, comptime rest: []const u8) ?Chord(Key).What {
    if (rest.len == 0 or rest[0] != '@') return null;
    const p = keys.Position.parse(rest[1..]) orelse @compileError("unknown position \"" ++ rest ++ "\" in chord \"" ++ s ++ "\"");
    return .{ .pos = p };
}

/// `^x`'s symbol: one character.
fn symPart(comptime Key: type, comptime s: []const u8, comptime rest: []const u8) Chord(Key).What {
    const n = std.unicode.utf8ByteSequenceLength(rest[0]) catch @compileError("not UTF-8 in chord \"" ++ s ++ "\"");
    if (n != rest.len) @compileError("\"^\" takes one character or a position, in chord \"" ++ s ++ "\"");
    return .{ .sym = rest };
}

fn eqlStr(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Whether `name` is `prefix` or below it (`a.b` is under `a`, `ab` is not).
pub fn under(name: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, name, prefix) and (name.len == prefix.len or name[prefix.len] == '.');
}

/// The registry for `modes`, `actions` and `binds`, keys of type `Key`, on
/// macOS or not.
pub fn Registry(
    comptime Key: type,
    comptime mac: bool,
    comptime modes: []const ModeDef,
    comptime actions: []const ActionDef,
    comptime binds: []const BindDef,
) type {
    @setEvalBranchQuota(20_000_000);
    comptime {
        if (modes.len > 255) @compileError("too many modes");
        if (actions.len > 65535) @compileError("too many actions");
        // Names unique and well formed.
        for (modes, 0..) |m, i| {
            for (modes[0..i]) |o| if (eqlStr(o.name, m.name)) @compileError("mode \"" ++ m.name ++ "\" defined twice");
            if (m.parent) |p| _ = findMode(modes, p) orelse @compileError("mode \"" ++ m.name ++ "\": no parent \"" ++ p ++ "\"");
            if (m.extends) |p| _ = findMode(modes, p) orelse @compileError("mode \"" ++ m.name ++ "\": no base \"" ++ p ++ "\"");
            if (m.kind == .root and m.parent != null) @compileError("root mode \"" ++ m.name ++ "\" has a parent");
            if (m.kind != .root and m.parent == null) @compileError("mode \"" ++ m.name ++ "\" has no parent");
        }
        for (actions, 0..) |a, i| {
            for (actions[0..i]) |o| if (eqlStr(o.name, a.name)) @compileError("action \"" ++ a.name ++ "\" defined twice");
            if (std.mem.indexOfScalar(u8, a.name, '.') == null) @compileError("action \"" ++ a.name ++ "\" is not under a group");
        }
        // No loops through parents or bases.
        for (modes) |m| {
            var at: ?[]const u8 = m.parent;
            var n: usize = 0;
            while (at) |p| : (n += 1) {
                if (n > modes.len) @compileError("mode \"" ++ m.name ++ "\": its parents loop");
                at = modes[findMode(modes, p).?].parent;
            }
            at = m.extends;
            n = 0;
            while (at) |p| : (n += 1) {
                if (n > modes.len) @compileError("mode \"" ++ m.name ++ "\": its bases loop");
                at = modes[findMode(modes, p).?].extends;
            }
        }
        // Each binding: a known mode and action, allowed there, a chord
        // that parses, an argument the action takes, not a chord the mode
        // already has.
        const parsed = parseAll(Key, binds, mac);
        for (binds, 0..) |b, i| {
            const mi = findMode(modes, b.mode) orelse @compileError("binding \"" ++ b.chord ++ "\": no mode \"" ++ b.mode ++ "\"");
            const ai = findAction(actions, b.action) orelse @compileError("binding \"" ++ b.chord ++ "\" in " ++ b.mode ++ ": no action \"" ++ b.action ++ "\"");
            if (!allows(modes, mi, b.action)) @compileError("mode \"" ++ b.mode ++ "\" does not allow \"" ++ b.action ++ "\"");
            const c = parsed[i];
            switch (actions[ai].param) {
                .none => if (b.arg != 0) @compileError("\"" ++ b.action ++ "\" takes no argument"),
                .direction => if (b.arg < 0 or b.arg > 3) @compileError("\"" ++ b.action ++ "\": not a direction"),
                .int => {},
            }
            for (binds[0..i], parsed[0..i]) |o, oc| {
                if (!eqlStr(o.mode, b.mode)) continue;
                if (!osOverlap(o.os, b.os)) continue;
                if (oc.eql(c)) @compileError("mode \"" ++ b.mode ++ "\": \"" ++ b.chord ++ "\" bound twice");
            }
        }
    }

    return struct {
        pub const ActionId = u16;
        pub const ModeId = u8;
        pub const KeyChord = Chord(Key);

        pub const Binding = struct {
            chord: KeyChord,
            action: ActionId,
            arg: i32,
        };

        pub const mode_defs = modes;
        pub const action_defs = actions;
        pub const mode_count = modes.len;
        pub const action_count = actions.len;

        /// The action named `name`; an unknown name fails the build.
        pub fn action(comptime name: []const u8) ActionId {
            comptime @setEvalBranchQuota(1_000_000);
            return comptime @intCast(findAction(actions, name) orelse @compileError("no action \"" ++ name ++ "\""));
        }

        /// Whether there is an action named `name`.
        pub fn hasAction(comptime name: []const u8) bool {
            comptime @setEvalBranchQuota(1_000_000);
            return comptime findAction(actions, name) != null;
        }

        /// The mode named `name`; an unknown name fails the build.
        pub fn mode(comptime name: []const u8) ModeId {
            comptime @setEvalBranchQuota(1_000_000);
            return comptime @intCast(findMode(modes, name) orelse @compileError("no mode \"" ++ name ++ "\""));
        }

        pub fn actionName(id: ActionId) []const u8 {
            return actions[id].name;
        }

        pub fn modeName(id: ModeId) []const u8 {
            return modes[id].name;
        }

        pub fn def(id: ActionId) ActionDef {
            return actions[id];
        }

        pub fn modeDef(id: ModeId) ModeDef {
            return modes[id];
        }

        pub fn parentOf(id: ModeId) ?ModeId {
            return parents[id];
        }

        const parents: [modes.len]?ModeId = blk: {
            @setEvalBranchQuota(20_000_000);
            var out: [modes.len]?ModeId = undefined;
            for (modes, 0..) |m, i| out[i] = if (m.parent) |p| @intCast(findMode(modes, p).?) else null;
            break :blk out;
        };

        const action_map = blk: {
            @setEvalBranchQuota(20_000_000);
            var kvs: [actions.len]struct { []const u8, ActionId } = undefined;
            for (actions, 0..) |a, i| kvs[i] = .{ a.name, @intCast(i) };
            break :blk std.StaticStringMap(ActionId).initComptime(kvs);
        };
        const mode_map = blk: {
            @setEvalBranchQuota(20_000_000);
            var kvs: [modes.len]struct { []const u8, ModeId } = undefined;
            for (modes, 0..) |m, i| kvs[i] = .{ m.name, @intCast(i) };
            break :blk std.StaticStringMap(ModeId).initComptime(kvs);
        };

        /// By name at run time (a user's keymap, a translation's key).
        pub fn actionByName(name: []const u8) ?ActionId {
            return action_map.get(name);
        }

        pub fn modeByName(name: []const u8) ?ModeId {
            return mode_map.get(name);
        }

        /// Whether `m` (or its base) may bind action `a`.
        pub fn allowed(m: ModeId, a: ActionId) bool {
            return masks[m].isSet(a);
        }

        pub const Mask = std.StaticBitSet(actions.len);

        const masks: [modes.len]Mask = blk: {
            @setEvalBranchQuota(20_000_000);
            var out: [modes.len]Mask = undefined;
            for (0..modes.len) |mi| {
                out[mi] = .empty;
                for (actions, 0..) |a, ai| if (allows(modes, mi, a.name)) out[mi].set(ai);
            }
            break :blk out;
        };

        /// Each mode's keymap: its own bindings first, then its base's (and
        /// theirs), a base's chord left out where the mode binds it itself.
        /// The bindings for this system only.
        const all_chords = parseAll(Key, binds, mac);

        pub const tables: [modes.len][]const Binding = blk: {
            @setEvalBranchQuota(20_000_000);
            var out: [modes.len][]const Binding = undefined;
            for (0..modes.len) |mi| {
                var list: [binds.len]Binding = undefined;
                var n: usize = 0;
                var at: ?usize = mi;
                while (at) |m| : (at = if (modes[m].extends) |e| findMode(modes, e).? else null) {
                    for (binds, all_chords) |b, c| {
                        if (!eqlStr(b.mode, modes[m].name) or !osFits(b.os, mac)) continue;
                        var shadowed = false;
                        for (list[0..n]) |have| if (have.chord.eql(c)) {
                            shadowed = true;
                        };
                        if (shadowed) continue;
                        list[n] = .{ .chord = c, .action = @intCast(findAction(actions, b.action).?), .arg = b.arg };
                        n += 1;
                    }
                }
                const final = list[0..n].*;
                out[mi] = &final;
            }
            break :blk out;
        };
    };
}

fn parseAll(comptime Key: type, comptime binds: []const BindDef, comptime mac: bool) [binds.len]Chord(Key) {
    comptime {
        @setEvalBranchQuota(10_000_000);
        var out: [binds.len]Chord(Key) = undefined;
        for (binds, 0..) |b, i| out[i] = parseChord(Key, b.chord, mac);
        const final = out;
        return final;
    }
}

fn findMode(comptime modes: []const ModeDef, comptime name: []const u8) ?usize {
    for (modes, 0..) |m, i| if (eqlStr(m.name, name)) return i;
    return null;
}

fn findAction(comptime actions: []const ActionDef, comptime name: []const u8) ?usize {
    for (actions, 0..) |a, i| if (eqlStr(a.name, name)) return i;
    return null;
}

/// Whether mode `mi` (or a base of it) allows action `name`.
fn allows(comptime modes: []const ModeDef, comptime mi: usize, comptime name: []const u8) bool {
    var at: ?usize = mi;
    while (at) |m| : (at = if (modes[m].extends) |e| findMode(modes, e).? else null) {
        for (modes[m].allows) |p| if (under(name, p)) return true;
    }
    return false;
}

fn osOverlap(a: Os, b: Os) bool {
    return a == .any or b == .any or a == b;
}

fn osFits(o: Os, mac: bool) bool {
    return switch (o) {
        .any => true,
        .mac => mac,
        .not_mac => !mac,
    };
}

const testing = std.testing;

const TestKey = enum { a, z, y, escape, tab, left, right };

const test_modes = [_]ModeDef{
    .{ .name = "global", .kind = .root, .allows = &.{ "edit", "file" } },
    .{ .name = "canvas", .kind = .major, .parent = "global", .allows = &.{"canvas"} },
    .{ .name = "canvas.flow", .kind = .sub, .parent = "canvas", .takes_text = true, .allows = &.{"canvas.flow"} },
    .{ .name = "dialog", .kind = .dialog, .parent = "global", .allows = &.{"dialog"} },
    .{ .name = "dialog.size", .kind = .dialog, .parent = "global", .extends = "dialog", .allows = &.{"dialog.size"} },
};
const test_actions = [_]ActionDef{
    .{ .name = "edit.undo", .repeat = true },
    .{ .name = "edit.redo", .repeat = true },
    .{ .name = "canvas.nudge", .repeat = true, .param = .direction },
    .{ .name = "canvas.flow.leave" },
    .{ .name = "canvas.flow.word-left" },
    .{ .name = "dialog.cancel" },
    .{ .name = "dialog.confirm" },
    .{ .name = "dialog.size.grow", .param = .int },
};
const test_binds = [_]BindDef{
    .{ .mode = "global", .chord = "primary+z", .action = "edit.undo" },
    .{ .mode = "global", .chord = "primary+shift+z", .action = "edit.redo" },
    .{ .mode = "global", .chord = "primary+y", .action = "edit.redo", .os = .not_mac },
    .{ .mode = "canvas", .chord = "left", .action = "canvas.nudge", .arg = @backingInt(Direction.left) },
    .{ .mode = "canvas", .chord = "right", .action = "canvas.nudge", .arg = @backingInt(Direction.right) },
    .{ .mode = "canvas.flow", .chord = "escape", .action = "canvas.flow.leave" },
    .{ .mode = "canvas.flow", .chord = "bind:word_left", .action = "canvas.flow.word-left" },
    .{ .mode = "dialog", .chord = "escape", .action = "dialog.cancel" },
    .{ .mode = "dialog", .chord = "a", .action = "dialog.confirm" },
    .{ .mode = "dialog.size", .chord = "right", .action = "dialog.size.grow", .arg = 1 },
    .{ .mode = "dialog.size", .chord = "shift+right", .action = "dialog.size.grow", .arg = 10 },
    .{ .mode = "dialog.size", .chord = "a", .action = "dialog.cancel" },
};

const R = Registry(TestKey, false, &test_modes, &test_actions, &test_binds);
const Rmac = Registry(TestKey, true, &test_modes, &test_actions, &test_binds);

test "chords parse, primary follows the system" {
    const c = parseChord(TestKey, "primary+shift+z", false);
    try testing.expect(c.mods.ctrl and c.mods.shift and !c.mods.cmd);
    try testing.expectEqual(TestKey.z, c.what.code);
    const m = parseChord(TestKey, "primary+z", true);
    try testing.expect(m.mods.cmd and !m.mods.ctrl);
    try testing.expectEqualStrings("+", parseChord(TestKey, "char:+", false).what.char);
    try testing.expectEqualStrings("copy", parseChord(TestKey, "bind:copy", false).what.bind);
}

test "chords by position and by symbol" {
    const p = parseChord(TestKey, "ctrl+@D01", false);
    try testing.expect(p.mods.ctrl and p.what.pos.eql(keys.Position.parse("D01").?));
    const s = parseChord(TestKey, "^>", false);
    try testing.expect(s.mods.ctrl and !s.mods.shift);
    try testing.expectEqualStrings(">", s.what.sym);
    try testing.expect(s.eql(parseChord(TestKey, "ctrl+'>'", false)));
    try testing.expectEqualStrings("+", parseChord(TestKey, "alt+'+'", false).what.sym);
    try testing.expectEqualStrings("+", parseChord(TestKey, "^+", false).what.sym);
    try testing.expect(parseChord(TestKey, "^@E01", false).what.pos.eql(keys.Position.parse("E01").?));
    // Unchorded, a symbol is the character typed.
    try testing.expectEqualStrings("%", parseChord(TestKey, "'%'", false).what.char);
    try testing.expectEqualStrings("é", parseChord(TestKey, "^é", false).what.sym);
}

test "names to IDs and back, at compile time and at run time" {
    const undo = R.action("edit.undo");
    try testing.expectEqualStrings("edit.undo", R.actionName(undo));
    try testing.expectEqual(undo, R.actionByName("edit.undo").?);
    try testing.expect(R.actionByName("edit.nothing") == null);
    try testing.expectEqual(R.mode("canvas"), R.parentOf(R.mode("canvas.flow")).?);
    try testing.expect(R.parentOf(R.mode("global")) == null);
}

test "masks follow the allowed prefixes, bases included" {
    try testing.expect(R.allowed(R.mode("canvas"), R.action("canvas.nudge")));
    try testing.expect(R.allowed(R.mode("canvas"), R.action("canvas.flow.leave")));
    try testing.expect(!R.allowed(R.mode("canvas.flow"), R.action("canvas.nudge")));
    try testing.expect(R.allowed(R.mode("dialog.size"), R.action("dialog.cancel")));
    try testing.expect(!R.allowed(R.mode("dialog"), R.action("edit.undo")));
}

test "tables: per system, a base's bindings after the mode's own, shadowed where rebound" {
    try testing.expectEqual(3, R.tables[R.mode("global")].len);
    try testing.expectEqual(2, Rmac.tables[Rmac.mode("global")].len);
    const size = R.tables[R.mode("dialog.size")];
    // Its own three, then the dialog's Escape; the dialog's `a` is its own.
    try testing.expectEqual(4, size.len);
    try testing.expectEqual(R.action("dialog.size.grow"), size[0].action);
    try testing.expectEqual(10, size[1].arg);
    try testing.expectEqual(R.action("dialog.cancel"), size[2].action);
    try testing.expectEqual(R.action("dialog.cancel"), size[3].action);
    try testing.expectEqual(TestKey.escape, size[3].chord.what.code);
}

test "under: whole name segments only" {
    try testing.expect(under("canvas.flow.paste", "canvas.flow"));
    try testing.expect(under("canvas", "canvas"));
    try testing.expect(!under("canvasx.a", "canvas"));
}
