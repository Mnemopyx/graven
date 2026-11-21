//! The GUI without a screen: Graven's own frames run under DVUI's testing
//! backend, its widgets found by their tags and driven as a person would
//! (move, click, type, keys). `zig build gui-test`.
//!
//! Tags (main.zig, "Tags"): a property row "<section heading>/<field>", a
//! button "<section heading>/<label>", a menu item "menu/<label>", a
//! Browser node "tree/<path>", a content palette button "palette.<kind>"
//! (`palette.key.1-25u`).
//! A dropdown is chosen through `testing_api.choose` (its entries carry no
//! tags); everything else is clicked and typed.
//!
//! Each test starts Graven afresh with a scratch config (docked panes, no
//! user settings, no news fetched) in a window tall enough that no
//! property list needs scrolling.

const std = @import("std");
const dvui = @import("dvui");
const glyphic = @import("graven_glyphic");
const gui = @import("main.zig");

const api = gui.testing_api;
const layout = @import("graven_layout");
const process = layout.model.process;

const scratch = "/tmp/graven-gui-test";

/// The panes docked, so clicks reach them (a ghost pane lets them through
/// to the canvas).
const config =
    \\[panes]
    \\layout = "test"
    \\[panes.layouts.test.browser]
    \\mode = "docked"
    \\size = 300
    \\[panes.layouts.test.tools]
    \\mode = "docked"
    \\[panes.layouts.test.properties]
    \\mode = "docked"
    \\size = 380
    \\
;

var threaded: std.Io.Threaded = undefined;

/// Graven started under the testing backend.
pub const Run = struct {
    t: dvui.testing,

    pub fn start() !Run {
        const io = std.testing.io;
        std.Io.Dir.cwd().createDirPath(io, scratch ++ "/config") catch {};
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = scratch ++ "/config/local.toml", .data = config });
        std.Io.Dir.cwd().deleteFile(io, scratch ++ "/config/shared.toml") catch {};
        // Graven's background work (the font index, the desktop) has its
        // own threads: an Io and allocator of the run's, not the test's.
        threaded = .init(std.heap.c_allocator, .{});
        const t = try dvui.testing.init(.{ .io = threaded.io(), .allocator = std.heap.c_allocator, .window_size = .{ .w = 1600, .h = 4000 } });
        try gui.dvui_app.initFn.?(t.window);
        var r: Run = .{ .t = t };
        try r.frames(3);
        return r;
    }

    pub fn stop(r: *Run) void {
        if (gui.dvui_app.deinitFn) |f| f(r.t.window);
        r.t.deinit();
    }

    /// Runs `n` frames (Graven animates, so it may never settle).
    pub fn frames(_: *Run, n: usize) !void {
        for (0..n) |_| _ = try dvui.testing.step(gui.dvui_app.frameFn);
    }

    /// The widget tagged `tag`, once it is laid out (a new one takes its
    /// size a frame or two after it first appears).
    fn rectOf(r: *Run, tag: []const u8) !dvui.Rect.Physical {
        // Laid out, and where it was a frame ago: settled.
        var last: ?dvui.Rect.Physical = null;
        for (0..30) |_| {
            if (dvui.tagGet(tag)) |d| if (d.visible and d.rect.w > 0 and d.rect.h > 0) {
                if (last) |l| if (std.meta.eql(l, d.rect)) return d.rect;
                last = d.rect;
            };
            try r.frames(1);
        }
        const d = dvui.tagGet(tag) orelse {
            std.debug.print("no tag \"{s}\"; tags with its first part:\n", .{tag});
            dumpTags(tag[0 .. std.mem.indexOfScalar(u8, tag, '/') orelse tag.len]);
            return error.TagNotFound;
        };
        if (!d.visible) {
            std.debug.print("tag \"{s}\" not visible: {any}\n", .{ tag, d.rect });
            api.describePanes();
            return error.WidgetNotVisible;
        }
        return d.rect;
    }

    /// The tag that starts with `prefix` (a node whose label goes on), once
    /// it is there.
    pub fn tagStarting(r: *Run, prefix: []const u8) ![]const u8 {
        for (0..20) |_| {
            var it = dvui.currentWindow().tags.map.iterator();
            while (it.next()) |e| if (std.mem.startsWith(u8, e.key_ptr.*, prefix)) return e.key_ptr.*;
            try r.frames(1);
        }
        std.debug.print("no tag starting \"{s}\"\n", .{prefix});
        return error.TagNotFound;
    }

    /// Clicks the middle of the widget tagged `tag`.
    pub fn click(r: *Run, tag: []const u8) !void {
        try r.clickIn(tag, 0.5, 0.5);
    }

    /// Clicks at `fx`, `fy` (0 to 1) across the widget tagged `tag`.
    pub fn clickIn(r: *Run, tag: []const u8, fx: f32, fy: f32) !void {
        const rect = try r.rectOf(tag);
        try r.clickAt(.{ .x = rect.x + rect.w * fx, .y = rect.y + rect.h * fy });
    }

    pub fn clickAt(r: *Run, p: dvui.Point.Physical) !void {
        const cw = dvui.currentWindow();
        _ = try cw.addEventMouseMotion(.{ .pt = p });
        try r.frames(1);
        _ = try cw.addEventMouseButton(.left, .press);
        try r.frames(1);
        _ = try cw.addEventMouseButton(.left, .release);
        try r.frames(2);
    }

    /// Drags with the left button from `a` to `b`, in steps.
    pub fn drag(r: *Run, a: dvui.Point.Physical, b: dvui.Point.Physical) !void {
        const cw = dvui.currentWindow();
        _ = try cw.addEventMouseMotion(.{ .pt = a });
        try r.frames(1);
        _ = try cw.addEventMouseButton(.left, .press);
        try r.frames(1);
        for (1..9) |k| {
            const f: f32 = @as(f32, @floatFromInt(k)) / 8;
            _ = try cw.addEventMouseMotion(.{ .pt = .{ .x = a.x + (b.x - a.x) * f, .y = a.y + (b.y - a.y) * f } });
            try r.frames(1);
        }
        _ = try cw.addEventMouseButton(.left, .release);
        try r.frames(2);
    }

    /// Types `text` into the field of the property row tagged `tag`,
    /// replacing what it held, and leaves the field (which accepts it).
    pub fn set(r: *Run, tag: []const u8, text: []const u8) !void {
        try r.clickIn(tag, 0.8, 0.5);
        try dvui.testing.pressKey(.a, .lcontrol);
        try r.frames(1);
        // Typing replaces the selection; nothing typed, it is deleted.
        if (text.len == 0) try dvui.testing.pressKey(.backspace, .none) else try dvui.testing.writeText(text);
        try r.frames(1);
        // Fields take what is typed when it is accepted: the keyboard
        // leaves the field.
        api.leaveField();
        try r.frames(3);
    }

    // By name (decided 2026-11-20): objects by name path, UI elements by
    // id ("<section>.<key>", main.zig "Element ids"), each through the
    // path a person's input takes, without pointing.

    /// Makes the object at name path `path` the context.
    pub fn select(r: *Run, path: []const u8) !void {
        if (!api.select(path)) {
            std.debug.print("no object at \"{s}\"\n", .{path});
            return error.NoSuchObject;
        }
        try r.frames(2);
    }

    /// The flow cursor at item `index` of the flow of the track at `path`.
    pub fn cursor(r: *Run, path: []const u8, index: usize) !void {
        if (!api.cursor(path, index)) {
            std.debug.print("no track or flow at \"{s}\" (or not {d} items)\n", .{ path, index });
            return error.NoSuchObject;
        }
        try r.frames(2);
    }

    /// The field with id `id` given `text`, as typed and accepted.
    pub fn field(r: *Run, id: []const u8, text: []const u8) !void {
        api.setField(id, text);
        for (0..10) |_| {
            try r.frames(1);
            if (!api.fieldPending()) break;
        } else {
            std.debug.print("no field \"{s}\"; ", .{id});
            dumpSection(id);
            return error.NoSuchElement;
        }
        if (api.fieldRefused()) {
            std.debug.print("field \"{s}\" refused \"{s}\"\n", .{ id, text });
            return error.Refused;
        }
        try r.frames(2);
    }

    /// The button, menu item, tool or checkbox with id `id` pressed.
    pub fn press(r: *Run, id: []const u8) !void {
        api.press(id);
        for (0..10) |_| {
            try r.frames(1);
            if (!api.pressPending()) break;
        } else {
            api.cancelPress();
            std.debug.print("nothing to press with id \"{s}\"; ", .{id});
            dumpSection(id);
            return error.NoSuchElement;
        }
        try r.frames(2);
    }

    /// The app's action named `name` run, as its menu item does.
    pub fn run(r: *Run, name: []const u8) !void {
        if (!api.run(name, 0)) return error.NoSuchAction;
        try r.frames(3);
    }

    /// The dropdown in the row tagged `tag` takes entry `label`.
    pub fn choose(r: *Run, tag: []const u8, label: []const u8) !void {
        api.choose(tag, label);
        try r.frames(3);
        if (api.choicePending()) {
            std.debug.print("dropdown \"{s}\": no entry \"{s}\" (or no such row)\n", .{ tag, label });
            return error.NoSuchChoice;
        }
    }

    /// Clicks at `p` with Ctrl held.
    pub fn ctrlClickAt(r: *Run, p: dvui.Point.Physical) !void {
        const cw = dvui.currentWindow();
        _ = try cw.addEventKey(.{ .code = .left_control, .mod = .lcontrol, .action = .down });
        try r.frames(1);
        try r.clickAt(p);
        _ = try cw.addEventKey(.{ .code = .left_control, .mod = .none, .action = .up });
        try r.frames(1);
    }

    pub fn key(r: *Run, code: dvui.enums.Key, mod: dvui.enums.Mod) !void {
        try dvui.testing.pressKey(code, mod);
        // The modifiers let go after the chord, as a hand does: a click
        // after Ctrl+\ is a plain click (dvui keeps the last key's
        // modifiers for mouse events).
        dvui.currentWindow().modifiers = .none;
        try r.frames(2);
    }
};

/// Prints this frame's tags that start with `prefix` (for writing tests).
/// The ids in the section of `id` (before its last "."), for a report.
fn dumpSection(id: []const u8) void {
    const dot = std.mem.lastIndexOfScalar(u8, id, '.') orelse id.len;
    std.debug.print("ids in \"{s}\":\n", .{id[0..dot]});
    dumpTags(id[0..dot]);
}

pub fn dumpTags(prefix: []const u8) void {
    var it = dvui.currentWindow().tags.map.iterator();
    while (it.next()) |e| if (std.mem.startsWith(u8, e.key_ptr.*, prefix)) std.debug.print("  {s}\n", .{e.key_ptr.*});
}

/// Prints this frame's tags that hold `part`.
pub fn dumpTagsWith(part: []const u8) void {
    var it = dvui.currentWindow().tags.map.iterator();
    while (it.next()) |e| if (std.mem.indexOf(u8, e.key_ptr.*, part) != null) std.debug.print("  {s}\n", .{e.key_ptr.*});
}

test "the start screen's M makes a new canvas in millimetres" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try std.testing.expectEqual(@as(usize, 1), api.model().spaces.items.len);
}

test "a text style made and set in the Browser and its properties" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try r.select("Styles");
    try r.press("styles.add-a-style");
    const m = api.model();
    const sid = m.styles.items[m.styles.items.len - 1].id;
    try r.field("style.name", "legend");
    try r.field("style.cap-height", "2.6");
    try r.field("style.text-face-family", "Inter");
    try r.field("style.text-face-style", "Medium");
    const st = m.textStyle(sid);
    try std.testing.expectEqualStrings("legend", st.name);
    try std.testing.expectApproxEqAbs(2.6, st.cap_height, 1e-9);
    try std.testing.expectEqualStrings("Inter", st.face("text").?.family);
    try std.testing.expectEqualStrings("Medium", st.face("text").?.style);
}

// The PC keyboard, made in the GUI ------------------------------------------

/// A style made in the Browser: its name, cap height and text face.
fn makeStyle(r: *Run, name: []const u8, cap: []const u8) !void {
    try r.select("Styles");
    try r.press("styles.add-a-style");
    try r.field("style.name", name);
    try r.field("style.cap-height", cap);
    try r.field("style.text-face-family", "Inter");
    try r.field("style.text-face-style", "Medium");
}

/// The keyboard's key prototype: 19.05 mm u, its insets, its sizes, three
/// slots (one legend each), keycap art shaded back to front.
fn makeKeyPrototype(r: *Run) !void {
    try r.select("Prototypes");
    try r.press("tool.add-prototype");
    try r.field("prototype.name", "key");
    try r.field("prototype.unit", "19.05");
    inline for (.{ "left", "right", "top", "bottom" }) |side| try r.field("prototype.body-inset-" ++ side, "0.475");
    try r.field("prototype.face-inset-left", "2.7");
    try r.field("prototype.face-inset-right", "2.7");
    try r.field("prototype.face-inset-top", "1.6");
    try r.field("prototype.face-inset-bottom", "3.6");
    try r.field("prototype.widths", "1, 1.25, 1.5, 1.75, 2, 2.25, 2.75, 6.25");
    try r.field("prototype.heights", "1, 2");
    // Slots, one legend each, overlapping: top (the whole face), bottom
    // (its lower half), words (the whole face, smaller).
    try r.choose("prototype.slot.top.style", "legend");
    try r.press("prototype.add-track");
    try r.field("prototype.slot.track1.name", "bottom");
    try r.choose("prototype.slot.bottom.style", "legend");
    try r.choose("prototype.slot.bottom.set-from", "start");
    try r.field("prototype.slot.bottom.inset-top", "6.45");
    try r.press("prototype.add-track");
    try r.field("prototype.slot.track1.name", "words");
    try r.choose("prototype.slot.words.style", "legend words");
    try r.choose("prototype.slot.words.set-from", "start");
    // Keycap art drawn from the insets now set, shaded back to front.
    try r.press("prototype.remove-art");
    try r.press("prototype.add-keycap-art");

    try r.choose("prototype.art-layer.body.fill-kind", "a gradient");
    try r.field("prototype.art-layer.body.gradient-from", "#e9e7e1");
    try r.field("prototype.art-layer.body.gradient-to", "#cfccc3");
    try r.choose("prototype.art-layer.face.fill-kind", "a gradient");
    try r.field("prototype.art-layer.face.gradient-from", "#faf9f6");
    try r.field("prototype.art-layer.face.gradient-to", "#efede8");
}

/// The keyboard's keys, row by row: width and height in u, the gap before
/// in u, and the legends (a symbol or a pair's shifted one; a pair's base
/// symbol; words), as typed.
const Key = struct { w: f64 = 1, h: f64 = 1, gap: f64 = 0, top: []const u8 = "", bottom: []const u8 = "", words: []const u8 = "" };

fn one(t: []const u8) Key {
    return .{ .top = t };
}
fn pair(t: []const u8, b: []const u8) Key {
    return .{ .top = t, .bottom = b };
}
fn words(t: []const u8, w: f64) Key {
    return .{ .words = t, .w = w };
}
fn gap(k: Key, g: f64) Key {
    var c = k;
    c.gap = g;
    return c;
}

const rows = [_][]const Key{
    &.{ words("Esc", 1), gap(one("F1"), 1), one("F2"), one("F3"), one("F4"), gap(one("F5"), 0.5), one("F6"), one("F7"), one("F8"), gap(one("F9"), 0.5), one("F10"), one("F11"), one("F12"), gap(words("Print Screen", 1), 0.25), words("Scroll Lock", 1), words("Pause", 1) },
    &.{ pair("~", "`"), pair("!", "1"), pair("@", "2"), pair("#", "3"), pair("$", "4"), pair("%", "5"), pair("^", "6"), pair("&", "7"), pair("*", "8"), pair("(", "9"), pair(")", "0"), pair("_", "-"), pair("+", "="), words("Backspace", 2), gap(words("Insert", 1), 0.25), words("Home", 1), words("Page Up", 1), gap(words("Num Lock", 1), 0.25), one("/"), one("*"), one("-") },
    &.{ words("Tab", 1.5), one("Q"), one("W"), one("E"), one("R"), one("T"), one("Y"), one("U"), one("I"), one("O"), one("P"), pair("{", "["), pair("}", "]"), .{ .top = "|", .bottom = "\\", .w = 1.5 }, gap(words("Delete", 1), 0.25), words("End", 1), words("Page Down", 1), gap(one("7"), 0.25), one("8"), one("9"), .{ .top = "+", .h = 2 } },
    &.{ words("Caps Lock", 1.75), one("A"), one("S"), one("D"), one("F"), one("G"), one("H"), one("J"), one("K"), one("L"), pair(":", ";"), pair("\"", "'"), words("Enter", 2.25), gap(one("4"), 3.5), one("5"), one("6") },
    &.{ words("Shift", 2.25), one("Z"), one("X"), one("C"), one("V"), one("B"), one("N"), one("M"), pair("<", ","), pair(">", "."), pair("?", "/"), words("Shift", 2.75), gap(one("↑"), 1.25), gap(one("1"), 1.25), one("2"), one("3"), .{ .words = "Enter", .h = 2 } },
    &.{ words("Ctrl", 1.25), words("Super", 1.25), words("Alt", 1.25), .{ .w = 6.25 }, words("Alt", 1.25), words("Super", 1.25), words("Menu", 1.25), words("Ctrl", 1.25), gap(one("←"), 0.25), one("↓"), one("→"), gap(.{ .top = "0", .w = 2 }, 0.25), one(".") },
};

/// A legend as markup: Graven's special characters escaped.
fn markup(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '{', '}', '_', '^', '&', '%', '#', '$', '~' => try w.print("\\{c}", .{c}),
        '\\' => try w.writeAll("\\textbackslash{}"),
        else => try w.writeByte(c),
    };
}

/// A CSV field, quoted when it holds a comma, a quote or a line break.
fn csvField(w: *std.Io.Writer, text: []const u8) !void {
    var buf: [64]u8 = undefined;
    var fw: std.Io.Writer = .fixed(&buf);
    try markup(&fw, text);
    const f = fw.buffered();
    if (std.mem.indexOfAny(u8, f, ",\"\n") == null) return w.writeAll(f);
    try w.writeByte('"');
    for (f) |c| {
        if (c == '"') try w.writeByte('"');
        try w.writeByte(c);
    }
    try w.writeByte('"');
}

/// The keyboard's legend table: a row a key (K1 …), a column a slot.
fn legendsCsv(a: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll("name,top,bottom,words\r\n");
    var n: usize = 0;
    for (rows) |row| for (row) |k| {
        n += 1;
        try w.print("K{d},", .{n});
        try csvField(w, k.top);
        try w.writeByte(',');
        try csvField(w, k.bottom);
        try w.writeByte(',');
        try csvField(w, k.words);
        try w.writeAll("\r\n");
    };
    return out.toOwnedSlice();
}

/// The content palette's key of size `w` u: palette.key.1-25u.
fn paletteKey(buf: []u8, w: f64) ![]const u8 {
    const t = try std.fmt.bufPrint(buf, "palette.key.{d}u", .{w});
    for (t) |*c| if (c.* == '.') {
        c.* = '-';
    };
    // The dots between the parts again.
    @memcpy(t[0.."palette.key.".len], "palette.key.");
    return t;
}

fn screen(p: struct { f64, f64 }) !dvui.Point.Physical {
    return api.toScreen(.{ .x = p[0], .y = p[1] }) orelse error.NoCanvas;
}

/// The keyboard as a person makes it in the GUI: styles, the key
/// prototype, a panel, six tracks in one flow, 104 keys from the content palette, their
/// names, gaps and heights, and their legends from a CSV table.
fn makeKeyboard(r: *Run) !void {
    try r.key(.m, .none);
    try makeStyle(r, "legend", "2.6");
    try checkSaveable("a style");
    try makeStyle(r, "legend words", "1.6");
    try makeKeyPrototype(r);
    try checkSaveable("the prototype");

    // The panel: drawn out, then typed exactly.
    try r.select("Canvas");
    try r.press("tool.add-panel");
    try r.drag(try screen(.{ 10, 10 }), try screen(.{ 80, 50 }));
    try r.select("Panel1");
    try r.field("panel.name", "PC keyboard (ANSI 104)");
    try r.field("panel.origin-across", "0");
    try r.field("panel.origin-up", "0");
    try r.field("panel.width", "448.625");
    try r.field("panel.height", "143.825");
    inline for (.{ "left", "right", "top", "bottom" }) |side| try r.field("panel.margins." ++ side, "5");

    try checkSaveable("the panel");
    // Six tracks, one a row, laid out in advance: each drawn out on the
    // panel, then typed exactly (the half unit after the function row is
    // where the second sits); the rest continue the first's flow.
    const tops = [_][]const u8{ "133.825", "105.25", "86.2", "67.15", "48.1", "29.05" };
    for (tops, 1..) |top, k| {
        var nb: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(&nb, "Row{d}", .{k});
        try r.select("\"PC keyboard (ANSI 104)\"");
        try r.press("tool.add-track");
        if (k == 1) try r.choose("tool.add-tracks.size-to", "Tile: key");
        try r.drag(try screen(.{ 20, 120 }), try screen(.{ 200, 121 }));
        try r.field("track.name", name);
        try r.field("track.origin.across", "10");
        try r.field("track.origin.up", top);
        try r.field("track.length", "22.5");
        if (k == 1) {
            // Its flow, named for what it holds.
            try r.press("track.flow.show");
            try r.field("flow.name", "keys");
        } else try r.choose("track.flow.choice", "keys");
    }
    try checkSaveable("the tracks");

    // The keys, from the content palette at the cursor, put at the start
    // of the first track: a row's keys, then a line break, which goes on
    // in the next track.
    const panel_path = "\"PC keyboard (ANSI 104)\"";
    try r.cursor(panel_path ++ ".Row1", 0);
    for (rows, 0..) |row, ri| {
        if (ri > 0) try r.press("palette.hard-break");
        for (row) |k| {
            var tb: [32]u8 = undefined;
            try r.press(try paletteKey(&tb, k.w));
        }
    }

    try checkSaveable("the keys");
    // Named in order, K1 to K104, from the first track's properties (its
    // flow's keys, through all six).
    try r.select(panel_path ++ ".Row1");
    try r.press("track.name-keys");

    // Gaps and heights, key by key: the key clicked on the canvas (the
    // panel chosen first, so a click picks a key rather than placing the
    // cursor), then its properties.
    // Each key that needs it chosen in the Browser, under its track (its
    // node is its name, then its legend).
    var n: usize = 0;
    for (rows, 1..) |row, ri| for (row) |k| {
        n += 1;
        if (k.gap == 0 and k.h == 1) continue;
        var tb: [128]u8 = undefined;
        _ = ri;
        try r.select(try std.fmt.bufPrint(&tb, "keys.K{d}", .{n}));
        var vb: [16]u8 = undefined;
        if (k.gap != 0) try r.field("tile.gap-before", try std.fmt.bufPrint(&vb, "{d}", .{k.gap}));
        if (k.h != 1) try r.choose("tile.height", try std.fmt.bufPrint(&vb, "{d} u", .{k.h}));
    };

    try checkSaveable("gaps and heights");
    // The legends: a table, one row a key, imported over the track.
    const csv = try legendsCsv(std.heap.c_allocator);
    defer std.heap.c_allocator.free(csv);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = scratch ++ "/keyboard-legends.csv", .data = csv });
    try r.select(panel_path ++ ".Row1");
    try r.click("menu.file");
    try r.click("menu.importLegendSheetCSV");
    try dvui.testing.pressKey(.a, .lcontrol);
    try r.frames(1);
    try dvui.testing.writeText(scratch ++ "/keyboard-legends.csv");
    try r.frames(1);
    try r.key(.enter, .none);
    try r.frames(3);
}

test "the PC keyboard, made in the GUI" {
    var r = try Run.start();
    defer r.stop();
    try makeKeyboard(&r);
    const m = api.model();
    var tiles: usize = 0;
    for (m.tiles.items) |t| {
        if (!t.removed) tiles += 1;
    }
    try std.testing.expectEqual(104, tiles);
    try std.testing.expectEqual(1, m.sheets.items.len);
    // No style left over that nothing uses.
    for (m.styles.items) |st| try std.testing.expect(!std.mem.eql(u8, st.name, "Label"));
    // The legend sheet's view, opened beside the canvas by the import,
    // closed: the example opens on its canvas.
    try std.testing.expectEqual(.sheet, api.activeView().kind);
    try r.run("views.close");
    try std.testing.expectEqual(.canvas, api.activeView().kind);
    // Saved as made: the example document's source.
    try saveAs(&r, scratch ++ "/pc-keyboard.graven");
    try sameAsExample(m, "examples/pc-keyboard.graven", &.{"PC keyboard (ANSI 104)"});
}

/// Whether the GUI's history so far saves and reopens whole (a step of
/// it that does not read back makes a damaged file).
fn checkSaveable(label: []const u8) !void {
    const a = std.heap.c_allocator;
    const who: layout.history.Writer = .{ .id = @splat(1), .device = "test", .tool = "test" };
    const bytes = try layout.history.fileBytes(api.history(), a, who, 1);
    defer a.free(bytes);
    var o = try layout.history.openFile(a, bytes);
    defer {
        o.model.deinit();
        o.history.deinit();
    }
    if (o.damaged) {
        std.debug.print("after {s}: the saved history does not read back\n", .{label});
        return error.NotSaveable;
    }
}

/// File › Save As… to `path`, as a person saves.
fn saveAs(r: *Run, path: []const u8) !void {
    std.Io.Dir.cwd().deleteFile(std.testing.io, path) catch {};
    try r.click("menu.file");
    try r.click("menu.file.save-as");
    try dvui.testing.pressKey(.a, .lcontrol);
    try r.frames(1);
    try dvui.testing.writeText(path);
    try r.frames(1);
    try r.key(.enter, .none);
    try r.frames(3);
    _ = try std.Io.Dir.cwd().statFile(std.testing.io, path, .{});
}

/// Panel `name` of `m` as 3MF (its fabrication layers), every legend in
/// `face`; null when it has no layers.
fn panel3mf(a: std.mem.Allocator, m: *layout.Model, name: []const u8, face: *layout.Face) !?[]u8 {
    const pi = for (m.panels.items, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) break i;
    } else return error.NoSuchPanel;
    if (m.panels.items[pi].fab.layers.len == 0) return null;
    const faces = [_]*layout.Face{face};
    var labels: layout.Labels = .init(a, &faces);
    defer labels.deinit();
    var placed = try layout.solve(a, m, pi, &labels);
    defer placed.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const ar = arena.allocator();
    const plan = try layout.fab.plan(ar, m, pi, &placed, &faces);
    const slabs = try layout.fab.slabs(ar, plan.steps);
    const parts = try layout.threemf.orient(ar, try layout.threemf.parts(ar, slabs, m.exportTolerance(), .colours), .bottom);
    return try a.dupe(u8, try layout.threemf.package(ar, name, parts));
}

/// Panel `name` of `m` as SVG, every legend in `face`.
fn panelSvg(a: std.mem.Allocator, m: *layout.Model, name: []const u8, face: *layout.Face) ![]u8 {
    const pi = for (m.panels.items, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) break i;
    } else return error.NoSuchPanel;
    const faces = [_]*layout.Face{face};
    var labels: layout.Labels = .init(a, &faces);
    defer labels.deinit();
    var placed = try layout.solve(a, m, pi, &labels);
    defer placed.deinit();
    return layout.output.panelSvg(a, &placed, &faces, .{});
}

/// Whether the panels `names` of the document made in the GUI (`m`) come
/// out as the example file's do, byte for byte, set in one face (the
/// repository's Inter Medium). A difference is written beside the scratch
/// config for a look.
fn sameAsExample(m: *layout.Model, path: []const u8, names: []const []const u8) !void {
    const a = std.heap.c_allocator;
    const io = std.testing.io;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(64 << 20));
    defer a.free(bytes);
    var opened = try layout.history.openFile(a, bytes);
    defer {
        opened.model.deinit();
        opened.history.deinit();
    }
    const font = try std.Io.Dir.cwd().readFileAlloc(io, "examples/fonts/Inter-Medium.otf", a, .limited(64 << 20));
    defer a.free(font);
    const face = try layout.Face.init(a, font, 0);
    defer face.deinit();
    for (names) |name| {
        const made = try panelSvg(a, m, name, face);
        defer a.free(made);
        const want = try panelSvg(a, &opened.model, name, face);
        defer a.free(want);
        if (std.mem.eql(u8, made, want)) {
            // And as made for printing, where it has fabrication layers.
            const made3 = try panel3mf(a, m, name, face);
            defer if (made3) |b| a.free(b);
            const want3 = try panel3mf(a, &opened.model, name, face);
            defer if (want3) |b| a.free(b);
            if ((made3 == null) != (want3 == null)) return error.NotTheSame;
            if (made3) |x| if (!std.mem.eql(u8, x, want3.?)) {
                std.debug.print("{s}: its 3MF differs from {s}'s\n", .{ name, path });
                return error.NotTheSame;
            };
            continue;
        }
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = scratch ++ "/made.svg", .data = made });
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = scratch ++ "/example.svg", .data = want });
        const at = std.mem.indexOfDiff(u8, made, want).?;
        std.debug.print("{s}: differs from {s} at byte {d} (of {d} and {d}): {s}/made.svg, example.svg\n", .{ name, path, at, made.len, want.len, scratch });
        return error.NotTheSame;
    }
}

// The HP-15C, made in the GUI ------------------------------------------------

/// A legend style on the Libertinus style: its cap height, 1.5 cap
/// heights between lines, superscripts raised and subscripts dropped.
fn make15cStyle(r: *Run, name: []const u8, cap: []const u8) !void {
    try r.select("Styles");
    try r.press("styles.add-a-style");
    try r.field("style.name", name);
    try r.choose("style.based-on", "Libertinus");
    try r.field("style.cap-height", cap);
    try r.field("style.line-pitch", "1.5");
    try r.press("style.rules.add-a-rule");
    try r.choose("style.rules.1.parameter", "sup_raise");
    try r.field("style.rules.1.value", "0.5");
    try r.press("style.rules.add-a-rule");
    try r.choose("style.rules.2.parameter", "sub_drop");
    try r.field("style.rules.2.value", "0.24");
}

/// A plain prototype: its tracks' size from the grid it is placed on (no
/// unit), no body inset, the face inset given, no art.
fn makePlainPrototype(r: *Run, name: []const u8, face: []const u8) !void {
    try r.select("Prototypes");
    try r.press("tool.add-prototype");
    try r.field("prototype.name", name);
    try r.field("prototype.unit", "");
    inline for (.{ "left", "right", "top", "bottom" }) |side| {
        try r.field("prototype.body-inset-" ++ side, "0");
        try r.field("prototype.face-inset-" ++ side, face);
    }
    try r.press("prototype.remove-art");
}

/// A track's style, alignment and insets (left, right, top, bottom).
fn setTrack(r: *Run, track: []const u8, style: []const u8, from: []const u8, insets: [4][]const u8) !void {
    var b: [96]u8 = undefined;
    try r.choose(try std.fmt.bufPrint(&b, "prototype.slot.{s}.style", .{track}), style);
    try r.choose(try std.fmt.bufPrint(&b, "prototype.slot.{s}.set-from", .{track}), from);
    for (insets, [_][]const u8{ "left", "right", "top", "bottom" }) |v, side| {
        try r.field(try std.fmt.bufPrint(&b, "prototype.slot.{s}.inset-{s}", .{ track, side }), v);
    }
}

/// A slot added after slot `after`, then named: it comes as track1 (the
/// lowest generated name free; the one before was renamed).
fn addTrack(r: *Run, after: []const u8, number: usize, name: []const u8) !void {
    _ = number;
    _ = after;
    try r.press("prototype.add-track");
    try r.field("prototype.slot.track1.name", name);
}

/// The HP-15C's keys, row by row: their white, blue and gold legends.
const Key15 = struct { top: []const u8, g: []const u8 = "", f: []const u8 = "" };

const keys15 = [4][10]Key15{
    .{ .{ .top = "$\\sqrt{x}$", .g = "$x^2$", .f = "A" }, .{ .top = "$e^x$", .g = "LN", .f = "B" }, .{ .top = "$10^x$", .g = "LOG", .f = "C" }, .{ .top = "$y^x$", .g = "\\%", .f = "D" }, .{ .top = "$1/x$", .g = "Δ\\%", .f = "E" }, .{ .top = "CHS", .g = "ABS", .f = "MATRIX" }, .{ .top = "7", .g = "DEG", .f = "FIX" }, .{ .top = "8", .g = "RAD", .f = "SCI" }, .{ .top = "9", .g = "GRD", .f = "ENG" }, .{ .top = "÷", .g = "$x<0$", .f = "$x\\le y$" } },
    .{ .{ .top = "SST", .g = "BST", .f = "LBL" }, .{ .top = "GTO", .g = "$\\mathrm{HYP}^{-1}$", .f = "HYP" }, .{ .top = "SIN", .g = "$\\mathrm{SIN}^{-1}$", .f = "DIM" }, .{ .top = "COS", .g = "$\\mathrm{COS}^{-1}$", .f = "(i)" }, .{ .top = "TAN", .g = "$\\mathrm{TAN}^{-1}$", .f = "I" }, .{ .top = "EEX", .g = "π", .f = "RESULT" }, .{ .top = "4", .g = "SF", .f = "$x$⇄" }, .{ .top = "5", .g = "CF", .f = "DSE" }, .{ .top = "6", .g = "F?", .f = "ISG" }, .{ .top = "×", .g = "$x=0$", .f = "$\\int_y^x$" } },
    .{ .{ .top = "R/S", .g = "P/R", .f = "PSE" }, .{ .top = "GSB", .g = "RTN", .f = "Σ" }, .{ .top = "R↓", .g = "R↑", .f = "PRGM" }, .{ .top = "$x$⇄$y$", .g = "RND", .f = "REG" }, .{ .top = "←", .g = "CL$x$", .f = "PREFIX" }, .{ .top = "ENTER", .g = "LST$x$", .f = "RAN#" }, .{ .top = "1", .g = "→P", .f = "→R" }, .{ .top = "2", .g = "→H", .f = "→H.MS" }, .{ .top = "3", .g = "→DEG", .f = "→RAD" }, .{ .top = "−", .g = "TEST", .f = "Re⇄Im" } },
    .{ .{ .top = "ON" }, .{ .top = "f" }, .{ .top = "g" }, .{ .top = "STO", .g = "INT", .f = "FRAC" }, .{ .top = "RCL", .g = "MEM", .f = "USER" }, .{ .top = "" }, .{ .top = "0", .g = "$\\bar{x}$", .f = "$x!$" }, .{ .top = ".", .g = "$s$", .f = "$\\hat{y},r$" }, .{ .top = "Σ+", .g = "Σ−", .f = "L.R." }, .{ .top = "+", .g = "C$y,x$", .f = "P$y,x$" } },
};

/// A panel drawn out on the canvas at `at` (mm), then typed exactly: its
/// name, origin, 128 × 62 mm and 3 mm margins.
fn make15cPanel(r: *Run, default: []const u8, name: []const u8, at: [2]f64, origin_x: []const u8) !void {
    try r.select("Canvas");
    try r.press("tool.add-panel");
    try r.drag(try screen(.{ at[0], at[1] }), try screen(.{ at[0] + 30, at[1] + 20 }));
    try r.select(default);
    try r.field("panel.name", name);
    try r.field("panel.origin-across", origin_x);
    try r.field("panel.origin-up", "0");
    try r.field("panel.width", "128");
    try r.field("panel.height", "62");
    inline for (.{ "left", "right", "top", "bottom" }) |side| try r.field("panel.margins." ++ side, "3");
}

/// Places the stamp chosen by `places` at a grid point by a click on it,
/// or across two points by a drag.
fn place(r: *Run, editing: []const u8, places: []const u8, pi: usize, c: u32, row: u32, span_down: bool) !void {
    _ = editing;
    try r.choose("panel.editing.places", places);
    const at = api.gridPoint(pi, 0, c, row) orelse return error.NoGrid;
    if (span_down) {
        try r.drag(at, api.gridPoint(pi, 0, c, row + 1) orelse return error.NoGrid);
    } else try r.clickAt(at);
}

fn make15c(r: *Run) !void {
    try r.key(.m, .none);
    try r.select("Styles");
    try r.press("styles.package.libertinus");
    try make15cStyle(r, "15C key", "1.9");
    try make15cStyle(r, "15C g", "1.25");
    try make15cStyle(r, "15C f", "1.4");

    try makePlainPrototype(r, "15C key", "0.4");
    try setTrack(r, "top", "15C key", "centre", .{ "0", "0", "0.7", "2.65" });
    try addTrack(r, "top", 2, "g");
    try setTrack(r, "g", "15C g", "centre", .{ "0", "0", "4.5", "0" });

    try makePlainPrototype(r, "15C ENTER key", "0.4");
    try setTrack(r, "top", "15C key", "centre", .{ "2.175", "2.175", "1", "2.65" });
    try r.choose("prototype.slot.top.runs", "down columns");
    try addTrack(r, "top", 2, "g");
    try setTrack(r, "g", "15C g", "centre", .{ "0", "0", "17.2", "0" });

    try makePlainPrototype(r, "15C gold legend", "0");
    try r.field("prototype.slot.top.name", "f");
    try setTrack(r, "f", "15C f", "centre", .{ "0", "0", "0", "0" });

    // The plate and the keys, side by side, 15 mm apart.
    try make15cPanel(r, "Panel1", "HP-15C plate", .{ 10, 10 }, "0");
    try make15cPanel(r, "Panel1", "HP-15C keys", .{ 60, 80 }, "143");

    // The plate's grid: 10 × 4 points, 11.43 mm across, 12.7 mm down;
    // its holes (rounded rectangles, r 1 mm) and its gold legends.
    try r.select("\"HP-15C plate\"");
    try r.press("panel.grids.add-grid");
    try r.field("grid.columns", "10");
    try r.field("grid.rows", "4");
    try r.field("grid.spacing-across", "11.43");
    try r.field("grid.spacing-down", "12.7");
    try r.field("grid.first-point-across", "12.565");
    try r.field("grid.first-point-up", "50");
    try r.press("grid.add-stamp.holes");
    try r.choose("grid.stamp.holes.prototype", "15C key");
    try r.field("grid.stamp.holes.width", "8.5");
    try r.field("grid.stamp.holes.height", "7.7");
    try r.choose("grid.stamp.holes.shape", "Rounded rectangle");
    try r.field("grid.stamp.holes.r", "1");
    try r.press("grid.add-stamp.legends");
    try r.choose("grid.stamp.legends.prototype", "15C gold legend");
    try r.field("grid.stamp.legends.width", "11");
    try r.field("grid.stamp.legends.height", "2.4");
    try r.field("grid.stamp.legends.offset-up", "5.15");

    // The keys' grid follows the plate's; on it, the keys themselves.
    try r.choose("grid.add-stamp.follow-it-on", "HP-15C keys");
    try r.select("\"HP-15C keys\"");
    try r.press("panel.grids.grid1");
    try r.press("grid.add-stamp.parts");
    try r.choose("grid.stamp.parts.prototype", "15C key");
    try r.field("grid.stamp.parts.width", "8");
    try r.field("grid.stamp.parts.height", "7.2");

    // Placed point by point in panel editing, as the code placed them:
    // row by row, a hole then its gold legend; ENTER over two rows.
    const plate = api.panelNamed("HP-15C plate").?;
    const keys = api.panelNamed("HP-15C keys").?;
    try r.select("\"HP-15C plate\"");
    try r.press("panel.edit");
    for (keys15, 0..) |row, ri| for (row, 0..) |k, ci| {
        const c: u32 = @intCast(ci);
        const rw: u32 = @intCast(ri);
        if (c == 5 and rw == 3) continue;
        try place(r, "HP-15C plate", "Holes", plate, c, rw, c == 5 and rw == 2);
        if (k.f.len > 0) try place(r, "HP-15C plate", "Legends", plate, c, rw, false);
    };
    try r.press("panel.editing.leave-panel-editing");
    try r.select("\"HP-15C keys\"");
    try r.press("panel.edit");
    for (keys15, 0..) |row, ri| for (row, 0..) |_, ci| {
        const c: u32 = @intCast(ci);
        const rw: u32 = @intCast(ri);
        if (c == 5 and rw == 3) continue;
        try place(r, "HP-15C keys", "Parts", keys, c, rw, c == 5 and rw == 2);
    };
    // ENTER picked (a click on it) and given its own prototype.
    try r.clickAt(api.gridPoint(keys, 0, 5, 2).?);
    try r.choose("tile.prototype", "15C ENTER key");
    try r.press("panel.editing.leave-panel-editing");

    // Fabrication: the plate black with its holes cut through and its gold
    // legends inlaid; the keys black with white and blue legends inlaid.
    // Made with a 0.2 mm nozzle: 0.4 mm cannot hold its legends.
    try r.select("\"HP-15C plate\"");
    try r.choose("panel.fab.process", "Generic FDM, 0.2 mm nozzle (built in)");
    try r.field("panel.fab.thickness", "2");
    try r.press("panel.fab.add-layer");
    try r.field("panel.fab.layer.1.name", "Plate");
    try r.press("panel.fab.add-layer");
    try r.field("panel.fab.layer.2.name", "Key holes");
    try r.choose("panel.fab.layer.2.from", "holes and cutouts");
    try r.choose("panel.fab.layer.2.makes", "a cut, away");
    try r.press("panel.fab.layer.2.through-the-whole-part");
    try r.press("panel.fab.add-layer");
    try r.field("panel.fab.layer.3.name", "Gold legends");
    try r.choose("panel.fab.layer.3.slot", "f");
    try r.field("panel.fab.layer.3.colour-name", "gold");
    try r.field("panel.fab.layer.3.colour", "#c9a227");
    try r.select("\"HP-15C keys\"");
    try r.choose("panel.fab.process", "Generic FDM, 0.2 mm nozzle");
    try r.field("panel.fab.thickness", "5");
    try r.press("panel.fab.add-layer");
    try r.field("panel.fab.layer.1.name", "Keys");
    try r.choose("panel.fab.layer.1.from", "grid parts");
    try r.press("panel.fab.add-layer");
    try r.field("panel.fab.layer.2.name", "White legends");
    try r.choose("panel.fab.layer.2.slot", "top");
    try r.press("panel.fab.add-layer");
    try r.field("panel.fab.layer.3.name", "Blue legends");
    try r.choose("panel.fab.layer.3.slot", "g");
    try r.field("panel.fab.layer.3.colour-name", "blue");
    try r.field("panel.fab.layer.3.colour", "#3a7bd5");

    // The legends: a sheet over the keys' grid, its keys named by their
    // place, a table imported into it.
    try r.press("panel.grids.grid1");
    try r.press("grid.make-a-legend-sheet");
    try r.press("sheet.cell.name-keys-by-grid-position-r1c1");
    var out: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("name,top,g,f\r\n");
    for (keys15, 0..) |row, ri| for (row, 0..) |k, ci| {
        if (ci == 5 and ri == 3) continue;
        try w.print("R{d}C{d}", .{ ri + 1, ci + 1 });
        for ([_][]const u8{ k.top, k.g, k.f }) |cell| {
            try w.writeByte(',');
            if (std.mem.indexOfAny(u8, cell, ",\"") != null) {
                try w.writeByte('"');
                for (cell) |ch| {
                    if (ch == '"') try w.writeByte('"');
                    try w.writeByte(ch);
                }
                try w.writeByte('"');
            } else try w.writeAll(cell);
        }
        try w.writeAll("\r\n");
    };
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = scratch ++ "/hp15c-legends.csv", .data = out.written() });
    try r.click("menu.file");
    try r.click("menu.importLegendSheetCSV");
    try dvui.testing.pressKey(.a, .lcontrol);
    try r.frames(1);
    try dvui.testing.writeText(scratch ++ "/hp15c-legends.csv");
    try r.frames(1);
    try r.key(.enter, .none);
    try r.frames(3);
}

test "the HP-15C, made in the GUI" {
    var r = try Run.start();
    defer r.stop();
    try make15c(&r);
    const m = api.model();
    try sameAsExample(m, "examples/hp15c.graven", &.{ "HP-15C plate", "HP-15C keys" });
    // Both panels made with the one 0.2 mm profile, kept in the document.
    try std.testing.expectEqual(@as(usize, 1), m.processes.items.len);
    for ([_][]const u8{ "HP-15C plate", "HP-15C keys" }) |name| {
        const pr = m.processOf(api.panelNamed(name).?).?;
        try std.testing.expectEqual(0.2, pr.params.fdm.nozzle);
        try std.testing.expectEqual(@as(?f64, 0.1), pr.limits().layer);
    }
    try saveAs(&r, scratch ++ "/hp15c.graven");
}

test "a process profile added from the built-ins, edited, its limits overridden and given back" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try r.select("Processes");
    try r.press("processes.builtin.generic-fdm-0-4-mm-nozzle");
    const m = api.model();
    try std.testing.expectEqual(@as(usize, 1), m.processes.items.len);
    const id = m.processes.items[0].id;
    try r.field("process.name", "Fine");
    try r.field("process.nozzle", "0.25");
    try r.field("process.line-width", "0.27");
    var p = m.processes.items[m.processIndex(id).?].profile;
    try std.testing.expectEqualStrings("Fine", p.name);
    try std.testing.expectEqual(0.27, p.limits().stroke.pass);
    try std.testing.expectEqual(@as(?process.Band, null), p.stroke);
    try r.field("process.stroke-passes-at", "0.3");
    p = m.processes.items[m.processIndex(id).?].profile;
    try std.testing.expectEqual(0.3, p.stroke.?.pass);
    try std.testing.expectEqual(0.125, p.stroke.?.fail);
    try r.press("process.use-the-limits-its-settings-give");
    p = m.processes.items[m.processIndex(id).?].profile;
    try std.testing.expectEqual(@as(?process.Band, null), p.stroke);
    // A second from the same built-in is numbered.
    try r.select("Processes");
    try r.press("processes.builtin.generic-fdm-0-4-mm-nozzle");
    try r.select("Processes");
    try r.press("processes.builtin.generic-fdm-0-4-mm-nozzle");
    try std.testing.expectEqualStrings("Generic FDM, 0.4 mm nozzle (2)", m.processes.items[2].profile.name);
    // Unused, it can go.
    
    try r.select("Processes.Fine");
    try r.press("process.remove-this-profile");
    try std.testing.expectEqual(@as(usize, 2), m.processes.items.len);
}

// Fabrication checks ---------------------------------------------------------------

test "the checks run when asked (C), as result layers; a panel checked alone; cleared" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try openExample(&r, "HP-15C keypad");
    // Nothing is checked until asked.
    try std.testing.expectEqual(@as(usize, 0), api.checkedPanels().len);
    // A click on empty canvas below the panels gives it the keyboard.
    try r.clickAt(api.toScreen(.{ .x = 60, .y = -15 }).?);
    try r.key(.c, .none);
    try r.frames(2);
    const checked = api.checkedPanels();
    try std.testing.expectEqual(@as(usize, 2), checked.len);
    const keys = api.panelNamed("HP-15C keys").?;
    const rep = api.checkReport(keys).?;
    // At the 0.2 mm profile, the small legends' strokes are marginal and
    // their superscripts fail; the simulation lays walls.
    try std.testing.expect(rep.count(.stroke, .marginal) > 0);
    try std.testing.expect(rep.count(.stroke, .fail) > 0);
    try std.testing.expect(rep.paths.len > 0);
    try std.testing.expectEqual(layout.check.Verdict.pass, rep.worst.get(.size));
    // The result layers, in the canvas's Layers.
    try r.select("Canvas");
    _ = try r.rectOf("checks.results.check-again");
    // Out of date once the document changes.
    try std.testing.expect(!api.checksOutOfDate());
    try r.select("\"HP-15C plate\"");
    try r.field("panel.fab.thickness", "2.2");
    try std.testing.expect(api.checksOutOfDate());
    // One panel, from its Fabrication.
    try r.press("panel.checks.check-this-panel");
    try r.frames(2);
    try std.testing.expectEqual(@as(usize, 1), api.checkedPanels().len);
    try std.testing.expect(!api.checksOutOfDate());
    try r.select("Canvas");
    try r.press("checks.results.clear-results");
    try std.testing.expectEqual(@as(usize, 0), api.checkedPanels().len);
}

// Manufacturing plans ---------------------------------------------------------------

test "a manufacturing plan made in the GUI: parts of materials, operations in order, warnings, its view" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try openExample(&r, "HP-15C keypad");
    const m = api.model();
    // The example's fabrication, upgraded: Plan 1, opened in its view.
    
    try r.select("Plans.Plan1");
    try r.press("plan.open-in-a-manufacturing-view");
    try r.frames(2);
    try std.testing.expectEqual(.manufacture, api.activeView().kind);
    try std.testing.expectEqual(@intFromEnum(m.plans.items[0].id), api.activeView().target);
    // A second plan: the plate black anodised aluminium, waterjet cut and
    // engraved.
    try r.select("Plans");
    try r.press("plans.add-a-plan");
    try std.testing.expectEqual(@as(usize, 2), m.plans.items.len);
    const id = m.plans.items[1].id;
    try r.choose("plan.part.hp-15c-plate", "Aluminium 5052, black anodised (library)");
    try r.choose("plan.part.hp-15c-keys", "PLA");
    try r.press("plan.add-an-operation");
    try r.choose("plan.operation.1.process", "Generic waterjet (built in)");
    try r.press("plan.operation.1.hp-15c-plate-plate");
    try r.press("plan.operation.1.hp-15c-plate-key-holes");
    try r.press("plan.add-an-operation");
    try r.choose("plan.operation.2.process", "Generic laser engraver (built in)");
    try r.press("plan.operation.2.hp-15c-plate-gold-legends");
    var pl = m.plans.items[m.planIndex(id).?];
    try std.testing.expectEqual(@as(usize, 2), pl.operations.len);
    try std.testing.expectEqual(@as(usize, 2), pl.operations[0].targets.len);
    // Engraving after the cut is flagged; the keys' layers are unmade.
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var after_cut = false;
    for (try layout.model.manufacture.warnings(arena.allocator(), m, pl)) |w| {
        if (w.kind == .mark_after_cut) after_cut = true;
    }
    try std.testing.expect(after_cut);
    // Engraved first: no longer flagged.
    try r.press("plan.operation.2.earlier");
    pl = m.plans.items[m.planIndex(id).?];
    try std.testing.expectEqualStrings("Operation2", pl.operations[0].name);
    for (try layout.model.manufacture.warnings(arena.allocator(), m, pl)) |w| {
        try std.testing.expect(w.kind != .mark_after_cut);
    }
    // The engraving's mark: the bare metal under the anodising.
    try std.testing.expectEqualStrings("bare aluminium", pl.operations[0].targets[0].colour.?.name);
    // Checked, operation by operation, each against its own process: the
    // engraving's passes in the bare metal, the waterjet's kerf round the
    // plate and inside its 39 holes.
    try r.press("plan.checks.check-this-plan");
    try r.frames(2);
    const oc = api.planChecks(id);
    try std.testing.expectEqual(@as(usize, 2), oc.len);
    for (oc) |c| switch (c.op) {
        0 => {
            try std.testing.expect(c.report.paths.len > 0);
            try std.testing.expectEqualStrings("bare aluminium", c.report.paths[0].colour.name);
            try std.testing.expectEqualStrings("Generic laser engraver", c.report.profile.?.name);
        },
        1 => {
            try std.testing.expectEqual(@as(usize, 40), c.report.paths.len);
            try std.testing.expectEqual(0.9, c.report.paths[0].width);
        },
        else => return error.TestUnexpectedResult,
    };
    _ = try r.rectOf("plan.checks.findings");
    try r.select("Plans.Plan2");
    try r.press("plan.open-in-a-manufacturing-view");
    try r.frames(2);
    try std.testing.expectEqual(.manufacture, api.activeView().kind);
    // Shown in 3D: this build (the harness's) has no OCCT, and says so.
    try r.choose("plan.shown-as", "3D, through OCCT (not in this build)");
    try r.frames(2);
    try std.testing.expect(std.mem.indexOf(u8, api.statusText(), "no OCCT") != null);
    // Plan 1 stays the one exported.
    try std.testing.expectEqual(m.plans.items[0].id, m.active_plan);
    try saveAs(&r, scratch ++ "/hp15c-plans.graven");
}

// Known bugs, kept fixed --------------------------------------------------------

/// Opens an example from the File menu (an untitled copy).
fn openExample(r: *Run, label: []const u8) !void {
    var b: [64]u8 = undefined;
    try r.click("menu.file");
    var ib: [64]u8 = undefined;
    try r.click(try std.fmt.bufPrint(&b, "menu.openExample{s}", .{layout.names.identifier(&ib, label, "x")}));
    try r.frames(5);
}

test "a click on a key makes the key the context, its properties shown" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try openExample(&r, "PC keyboard");
    try r.clickAt(api.tileCenter("K2").?);
    try std.testing.expectEqualStrings("tile", api.contextName());
    // Likewise with its panel chosen in the Browser first.
    try r.click("tree/untitled/Canvas, mm/PC keyboard (ANSI 104)");
    try r.clickAt(api.tileCenter("K3").?);
    try std.testing.expectEqualStrings("tile", api.contextName());
    _ = try r.rectOf("tile.gap-before");
    // And after the flow cursor has been in its track, then the track and
    // the panel chosen in the Browser (as when keys are filled in).
    try r.click("tree/untitled/Canvas, mm/PC keyboard (ANSI 104)/Row2");
    try r.clickAt(try screen(.{ 400, 100 }));
    try r.click("tree/untitled/Canvas, mm/PC keyboard (ANSI 104)/Row2");
    try r.click("tree/untitled/Canvas, mm/PC keyboard (ANSI 104)");
    try r.clickAt(api.tileCenter("K4").?);
    try std.testing.expectEqualStrings("tile", api.contextName());
}

test "after Tab hunts a Ctrl-click selection, the keyboard stays with the canvas" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try openExample(&r, "HP-15C keypad");
    // Ctrl-click near a key's edge: the nearest container is selected.
    const p = api.gridPoint(api.panelNamed("HP-15C keys").?, 0, 0, 0).?;
    try r.ctrlClickAt(.{ .x = p.x + 30, .y = p.y });
    try std.testing.expect(api.selectionCount() > 0);
    try std.testing.expect(api.canvasHasKeyboard());
    for (0..3) |_| {
        try r.key(.tab, .none);
        try std.testing.expect(api.canvasHasKeyboard());
    }
    // Esc still reaches the selection.
    try r.key(.escape, .none);
    try std.testing.expectEqual(0, api.selectionCount());
}

test "a region's rows made into tracks, one a row: the panel the same; a track removed and put back" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try r.select("Canvas");
    try r.press("tool.add-panel");
    try r.drag(try screen(.{ 10, 10 }), try screen(.{ 160, 90 }));
    try r.select("Panel1");
    // Two rows of keys in a region: three, a line break, two.
    try r.press("tool.add-rows");
    try r.drag(try screen(.{ 15, 85 }), try screen(.{ 120, 45 }));
    try r.field("track.length", "5");
    try r.field("track.depth", "2");
    for (0..5) |k| {
        if (k == 3) try r.press("palette.hard-break");
        try r.press("palette.key.1u");
    }
    try r.frames(3);
    const a = std.heap.c_allocator;
    const font = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "examples/fonts/Inter-Medium.otf", a, .limited(64 << 20));
    defer a.free(font);
    const face = try layout.Face.init(a, font, 0);
    defer face.deinit();
    const before = try panelSvg(a, api.model(), "Panel1", face);
    defer a.free(before);

    try r.select("Panel1.Rows1");
    try r.press("track.make-tracks");
    try r.frames(3);
    const m = api.model();
    const pi = for (m.panels.items, 0..) |p, k| {
        if (std.mem.eql(u8, p.name, "Panel1")) break k;
    } else return error.TestUnexpectedResult;
    const regions = m.panels.items[pi].regions.items;
    try std.testing.expectEqual(2, regions.len);
    for (regions) |t| try std.testing.expectEqual(layout.model.TileRegion.Kind.track, t.kind);
    try std.testing.expectEqual(m.trackFlow(pi, 0).?.id, m.trackFlow(pi, 1).?.id);
    const after = try panelSvg(a, m, "Panel1", face);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
    // The second track removed (its keys with it), and put back by undo.
    try r.select("Panel1.Rows2");
    _ = try r.rectOf("track.direction");
    try r.press("track.remove");
    try r.frames(3);
    try std.testing.expectEqual(1, api.model().panels.items[pi].regions.items.len);
    try r.key(.z, .lcontrol);
    try r.frames(3);
    try std.testing.expectEqual(2, api.model().panels.items[pi].regions.items.len);
    const again = try panelSvg(a, api.model(), "Panel1", face);
    defer a.free(again);
    try std.testing.expectEqualStrings(before, again);
}

// Fields: nothing changes while typed; accepted on leaving or Enter -----------

fn panelNamed(name: []const u8) ?usize {
    for (api.model().panels.items, 0..) |p, k| if (std.mem.eql(u8, p.name, name)) return k;
    return null;
}

fn typeInto(r: *Run, tag: []const u8, text: []const u8) !void {
    try r.clickIn(tag, 0.8, 0.5);
    try dvui.testing.pressKey(.a, .lcontrol);
    try r.frames(1);
    try dvui.testing.writeText(text);
    try r.frames(2);
}

test "a field changes nothing while typed; leaving it or Enter accepts, one undo step each" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try r.click("tree/untitled/Canvas, mm");
    try r.click("tool.add-panel");
    try r.drag(try screen(.{ 10, 10 }), try screen(.{ 80, 50 }));
    try r.click("tree/untitled/Canvas, mm/Panel1");
    const steps = api.undoSteps();
    try typeInto(&r, "panel.name", "Front");
    // Typed, not yet accepted: the model is as it was.
    try std.testing.expect(panelNamed("Panel1") != null);
    try std.testing.expectEqual(steps, api.undoSteps());
    api.leaveField();
    try r.frames(3);
    try std.testing.expect(panelNamed("Front") != null);
    try std.testing.expectEqual(steps + 1, api.undoSteps());
    // Enter accepts too, as a step of its own.
    try typeInto(&r, "panel.name", "Back");
    try r.key(.enter, .none);
    try r.frames(3);
    try std.testing.expect(panelNamed("Back") != null);
    try std.testing.expectEqual(steps + 2, api.undoSteps());
    try r.key(.z, .lcontrol);
    try r.frames(3);
    try std.testing.expect(panelNamed("Front") != null);
}

test "a field given what it cannot take, or left by Esc, goes back to how it was" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try r.click("tree/untitled/Canvas, mm");
    try r.click("tool.add-panel");
    try r.drag(try screen(.{ 10, 10 }), try screen(.{ 80, 50 }));
    try r.click("tree/untitled/Canvas, mm/Panel1");
    const pi = panelNamed("Panel1").?;
    const w = api.model().panels.items[pi].w;
    // Not a number: refused, the width as it was.
    try typeInto(&r, "panel.width", "wide");
    api.leaveField();
    try r.frames(3);
    try std.testing.expectEqual(w, api.model().panels.items[pi].w);
    // Esc: back, nothing changed.
    try typeInto(&r, "panel.width", "120");
    try r.key(.escape, .none);
    try r.frames(3);
    // Left after Esc: still nothing to take.
    api.leaveField();
    try r.frames(3);
    try std.testing.expectEqual(w, api.model().panels.items[pi].w);
    // An empty name is not a name.
    try typeInto(&r, "panel.name", "");
    try dvui.testing.pressKey(.backspace, .none);
    api.leaveField();
    try r.frames(3);
    try std.testing.expect(panelNamed("Panel1") != null);
}

test "a click elsewhere accepts the field first, then does what it was for" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try r.click("tree/untitled/Canvas, mm");
    try r.click("tool.add-panel");
    try r.drag(try screen(.{ 10, 10 }), try screen(.{ 80, 50 }));
    try r.click("tree/untitled/Canvas, mm/Panel1");
    try typeInto(&r, "panel.name", "Front");
    // A click on another node of the Browser: the name is taken, and the
    // node chosen.
    try r.click("tree/untitled/Text styles");
    try r.frames(3);
    try std.testing.expect(panelNamed("Front") != null);
    try std.testing.expectEqualStrings("styles", api.contextName());
}

test "a button is a virtual key: its action runs from a press, and only a shown button can be pressed" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try openExample(&r, "PC keyboard");
    const kb = "\"PC keyboard (ANSI 104)\"";
    // Not shown with the panel as the context: a script cannot press it.
    try r.select(kb);
    try std.testing.expectError(error.NoSuchElement, r.press("track.remove"));
    try std.testing.expect(api.model().resolve(kb ++ ".Row6") != null);
    // Shown with the track: its press runs region.remove on that track.
    try r.select(kb ++ ".Row6");
    try r.press("track.remove");
    try std.testing.expect(api.model().resolve(kb ++ ".Row6") == null);
    try std.testing.expect(api.model().resolve(kb ++ ".Row5") != null);
    try std.testing.expectEqualStrings("panel", api.contextName());
}

test "the discovery path: a track's groups and elements, and which are shown now" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try openExample(&r, "PC keyboard");
    try r.select("\"PC keyboard (ANSI 104)\".Row1");
    try r.frames(2);
    var buf: [64]api.Discovered = undefined;
    // The track's group holds its origin's group and its fields, buttons
    // and values, by logical name.
    const track = api.discover("track", &buf);
    var origin_shown = false;
    var make_tracks: ?api.Discovered = null;
    for (track) |d| {
        if (d.child.group and std.mem.eql(u8, d.child.name, "origin")) origin_shown = d.shown;
        if (std.mem.eql(u8, d.child.name, "make-tracks")) make_tracks = d;
    }
    try std.testing.expect(origin_shown);
    // A track has no rows to make tracks of: listed, not shown.
    try std.testing.expect(make_tracks != null and !make_tracks.?.shown);
    const origin = api.discover("track.origin", &buf);
    try std.testing.expectEqual(2, origin.len);
    for (origin) |d| {
        try std.testing.expect(d.shown);
        try std.testing.expect(d.rect.w > 0);
    }
    // Shown where it is shown, named where it belongs: the flow's
    // buttons are the track's, whatever section they are drawn in.
    for (api.discover("track.flow", &buf)) |d| if (std.mem.eql(u8, d.child.name, "show")) try std.testing.expect(d.shown);
    // And acted on by its name.
    try r.field("track.origin.up", "134");
    const row1 = api.model().resolve("\"PC keyboard (ANSI 104)\".Row1").?.region;
    try std.testing.expectEqual(134, api.model().panels.items[row1.panel].regions.items[row1.region].origin.y);
}

test {
    // The element registry's own tests (ids, the discovery walk).
    _ = @import("elements.zig");
}

test "every button in the registry is an action with a handler" {
    var buf: [256][]const u8 = undefined;
    const missing = api.unhandledButtons(&buf);
    for (missing) |m| std.debug.print("no handler: {s}\n", .{m});
    try std.testing.expectEqual(0, missing.len);
}

test "a slot edited on the canvas outlines its objects; a click chooses one, measured; the expression's section comes first, on a tile as in a run" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try openExample(&r, "HP-15C keypad");
    // Close in on the √x key, mid-canvas.
    api.centreOnTile("R1C1", 30);
    try r.frames(2);
    // The √x key's top slot, edited on the canvas (the key selected by
    // its outline first).
    try r.clickAt(api.tileEdge("R1C1").?);
    try std.testing.expectEqualStrings("tile", api.contextName());
    try std.testing.expect(!api.eqEditing());
    try r.key(.backslash, .lcontrol);
    try r.frames(2);
    var buf: [16]dvui.Rect.Physical = undefined;
    // Its objects: x, and the radical round it (its field left out).
    const boxes = api.eqBoxes(&buf);
    try std.testing.expectEqual(2, boxes.len);
    const x = boxes[0];
    const radical = boxes[1];
    try std.testing.expect(radical.w > x.w and radical.x < x.x);
    // The expression's section first, naming what is edited.
    _ = try r.rectOf("expression.editing");
    try std.testing.expect((try r.rectOf("expression.editing")).y < (try r.rectOf("tile.designator")).y);
    // A click by an object's outline chooses it: the radical's left edge
    // the radical; x's, x.
    try r.clickAt(.{ .x = radical.x + 1, .y = radical.y + radical.h * 0.6 });
    try r.frames(2);
    try std.testing.expectEqual(glyphic.Kind.radical, api.eqChosenKind().?);
    try std.testing.expect(api.eqMeasured());
    _ = try r.rectOf("expression.gap-before");
    _ = try r.rectOf("expression.baseline");
    try r.clickAt(.{ .x = x.x + x.w - 1, .y = x.y + x.h / 2 });
    try r.frames(2);
    try std.testing.expectEqual(glyphic.Kind.variable, api.eqChosenKind().?);
    try std.testing.expect(api.eqMeasured());
}

test "objects chosen and nudged on the canvas: Up chooses, Tab steps, arrows nudge from the neighbour and the baseline, o steps out, 0 clears, Esc types again" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try openExample(&r, "HP-15C keypad");
    api.centreOnTile("R1C1", 30);
    try r.frames(2);
    // The √x key's top slot: "$\sqrt{x}$" (the key selected by its outline).
    try r.clickAt(api.tileEdge("R1C1").?);
    try std.testing.expectEqualStrings("tile", api.contextName());
    try r.key(.backslash, .lcontrol);
    try r.frames(2);
    // Tab among objects from a click by x's outline: x chosen; o: out to
    // the radical.
    var buf: [16]dvui.Rect.Physical = undefined;
    const x = api.eqBoxes(&buf)[0];
    try r.clickAt(.{ .x = x.x + x.w - 1, .y = x.y + x.h / 2 });
    try r.frames(2);
    try std.testing.expectEqual(glyphic.Kind.variable, api.eqChosenKind().?);
    try dvui.testing.writeText("o");
    try r.frames(2);
    try r.frames(2);
    try std.testing.expectEqual(glyphic.Kind.radical, api.eqChosenKind().?);
    // Three nudges right and two up: written into the source in the call
    // form, the object still chosen; the measure follows.
    for (0..3) |_| try r.key(.right, .none);
    for (0..2) |_| try r.key(.up, .none);
    try r.frames(2);
    const tile = api.model().findTile("R1C1").?;
    const track = api.model().prototypeOf(tile).tracks[0].id;
    const text = try api.model().tileTrackText(std.testing.allocator, tile, track);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("$\\set(space_before: 0.06, shift_y: 0.04){\\sqrt{x}}$", text);
    try std.testing.expectEqual(glyphic.Kind.radical, api.eqChosenKind().?);
    try std.testing.expect(api.eqMeasured());
    // Tab: the next object, x inside it.
    try r.key(.tab, .none);
    try r.frames(2);
    try std.testing.expectEqual(glyphic.Kind.variable, api.eqChosenKind().?);
    // Back on the radical, 0 clears it; the source as it was.
    try dvui.testing.writeText("o");
    try r.frames(2);
    try dvui.testing.writeText("0");
    try r.frames(2);
    try r.frames(2);
    const back = try api.model().tileTrackText(std.testing.allocator, tile, track);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings("$\\sqrt{x}$", back);
    // Esc: typing again, the caret after it; Up chooses what is there.
    try r.key(.escape, .none);
    try r.frames(2);
    try std.testing.expect(!api.eqPicking());
    try r.key(.left, .none);
    try r.key(.up, .none);
    try r.frames(2);
    try std.testing.expect(api.eqPicking());
}

test "Ctrl+< and Ctrl+> go a level out and in: a key's text, the key, its track, its panel, the canvas, and back the same way" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try openExample(&r, "PC keyboard");
    api.centreOnTile("K30", 10);
    try r.frames(2);
    try r.clickAt(api.tileEdge("K30").?);
    try std.testing.expectEqualStrings("tile", api.contextName());
    // In: its text, then the word in it chosen.
    try r.key(.period, .lcontrol);
    try std.testing.expect(api.eqEditing());
    try std.testing.expect(!api.eqPicking());
    try r.key(.period, .lcontrol);
    try std.testing.expect(api.eqPicking());
    // Out, Shift or not: typing, the key, its track, its panel, the canvas.
    try r.key(.comma, .lcontrol);
    try std.testing.expect(api.eqEditing() and !api.eqPicking());
    try r.key(.comma, .lcontrol);
    try std.testing.expect(!api.eqEditing());
    try std.testing.expectEqualStrings("tile", api.contextName());
    try r.key(.comma, @enumFromInt(@intFromEnum(dvui.enums.Mod.lcontrol) | @intFromEnum(dvui.enums.Mod.lshift)));
    try std.testing.expectEqualStrings("region", api.contextName());
    // The track it lies in (the keyboard's second row), not its flow's first.
    try std.testing.expectEqualStrings("Row2", api.contextRegionName().?);
    try r.key(.comma, .lcontrol);
    try std.testing.expectEqualStrings("panel", api.contextName());
    try r.key(.comma, .lcontrol);
    try std.testing.expectEqualStrings("panel", api.contextName());
    try std.testing.expect(api.contextIsCanvas());
    // Back in the way it came: the panel, the track, the key, its text.
    try r.key(.period, .lcontrol);
    try std.testing.expect(!api.contextIsCanvas());
    try r.key(.period, .lcontrol);
    try std.testing.expectEqualStrings("region", api.contextName());
    try r.key(.period, .lcontrol);
    try std.testing.expectEqualStrings("tile", api.contextName());
    try std.testing.expectEqualStrings("K30", api.contextTile().?);
    try r.key(.period, .lcontrol);
    try std.testing.expect(api.eqEditing());
    // A track chosen afresh: in goes to its content, the flow cursor.
    try r.key(.escape, .none);
    try r.select("\"PC keyboard (ANSI 104)\".Row1");
    try r.key(.period, .lcontrol);
    try std.testing.expect(api.flowCursor());
    // In again: the item after the cursor, the first key.
    try r.key(.period, .lcontrol);
    try std.testing.expectEqualStrings("K1", api.contextTile().?);
}

test "pointing: by a key's outline the key, inside it a slot's text, the caret where pressed" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try openExample(&r, "HP-15C keypad");
    const cw = dvui.currentWindow();
    api.centreOnTile("R1C3", 30);
    try r.frames(2);
    // Near the outline: the key is highlighted, and a press selects it.
    const edge = api.tileEdge("R1C3").?;
    _ = try cw.addEventMouseMotion(.{ .pt = edge });
    try r.frames(2);
    try std.testing.expectEqualStrings("tile", api.hoverKind().?);
    try r.clickAt(edge);
    try std.testing.expectEqualStrings("tile", api.contextName());
    try std.testing.expect(!api.eqEditing());
    // Inside, on the g slot's text (LOG) at its end: that slot edited,
    // the caret after the last letter.
    const g = api.slotRect("R1C3", "g").?;
    const end: dvui.Point.Physical = .{ .x = g.x + g.w - 1, .y = g.y + g.h / 2 };
    _ = try cw.addEventMouseMotion(.{ .pt = end });
    try r.frames(2);
    try std.testing.expectEqualStrings("slot", api.hoverKind().?);
    try r.clickAt(end);
    try std.testing.expect(api.eqEditing());
    try dvui.testing.writeText("Z");
    try r.frames(2);
    try std.testing.expectEqualStrings("LOGZ", api.eqText().?);
    // Out of it (Esc), then at its start: the caret before the first
    // letter. (Pressed while editing, the very edge of a word is the
    // word's outline: it would choose the word.)
    try r.key(.escape, .none);
    // (Centred, the text grew both ways: its box found again.)
    const g2 = api.slotRect("R1C3", "g").?;
    try r.clickAt(.{ .x = g2.x + 1, .y = g2.y + g2.h / 2 });
    try dvui.testing.writeText("A");
    try r.frames(2);
    try std.testing.expectEqualStrings("ALOGZ", api.eqText().?);
    // The key's other slot, pressed while this one is edited: that one.
    const top = api.slotRect("R1C3", "top").?;
    try r.clickAt(.{ .x = top.x + top.w / 2, .y = top.y + top.h / 2 });
    try std.testing.expect(api.eqEditing());
    try std.testing.expect(std.mem.indexOf(u8, api.eqText().?, "10") != null);
}

test "Select boundaries: a mode toggled by its button or B, kept through Esc; the nearest boundary; a click selects its container, its drag points shown" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try openExample(&r, "HP-15C keypad");
    defer api.setBoundaryMode(false);
    api.centreOnTile("R1C3", 20);
    try r.frames(2);
    try r.press("tool.select-boundaries");
    try std.testing.expect(api.boundaryMode());
    try std.testing.expectEqualStrings("select", api.toolName());
    // Inside the key, well away from its outline: still the key's boundary
    // (no content in this mode); a click selects the key, not its text.
    const c = api.tileCenter("R1C3").?;
    const cw = dvui.currentWindow();
    _ = try cw.addEventMouseMotion(.{ .pt = c });
    try r.frames(2);
    try std.testing.expectEqualStrings("tile", api.hoverKind().?);
    try r.clickAt(c);
    try std.testing.expectEqualStrings("tile", api.contextName());
    try std.testing.expect(!api.eqEditing());
    // Esc leaves the mode on.
    try r.key(.escape, .none);
    try std.testing.expect(api.boundaryMode());
    // Near the keys panel's edge: the panel, made the selection with its
    // drag points.
    api.setView(0, 0, 4);
    try r.frames(2);
    const pe = api.panelEdge("HP-15C keys").?;
    try r.clickAt(pe);
    try std.testing.expectEqualStrings("panel", api.contextName());
    try std.testing.expectEqual(1, api.selectionCount());
    try std.testing.expect(api.handleCount() > 0);
    // B turns it off, and on again.
    try r.key(.b, .none);
    try std.testing.expect(!api.boundaryMode());
    try r.key(.b, .none);
    try std.testing.expect(api.boundaryMode());
}

test "construction lines: made by a drag and by two clicks, chosen by a click near one, held vertical, removed by Delete" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try r.press("tool.construction-line");
    try std.testing.expectEqualStrings("construction", api.toolName());
    // A drag from (80, 50) to (110, 80) mm, mid-canvas: a 45° line.
    try r.drag(api.screenOf(80, 50).?, api.screenOf(110, 80).?);
    try std.testing.expectEqual(1, api.guides().len);
    try std.testing.expectApproxEqAbs(45, api.guides()[0].angle, 1);
    // A click at (70, 20), released where pressed, then a click at
    // (130, 20): a horizontal line.
    try r.clickAt(api.screenOf(70, 20).?);
    try std.testing.expectEqual(1, api.guides().len);
    try r.clickAt(api.screenOf(130, 20).?);
    try std.testing.expectEqual(2, api.guides().len);
    try std.testing.expectApproxEqAbs(0, api.guides()[1].angle, 1);
    try std.testing.expectEqualStrings("guide", api.contextName());
    // Esc ends the tool; a click near the first line, far off where it was
    // drawn (it runs on), chooses it.
    try r.key(.escape, .none);
    try std.testing.expectEqualStrings("select", api.toolName());
    try r.clickAt(api.screenOf(125, 95).?);
    try std.testing.expectEqualStrings("guide", api.contextName());
    // Held vertical: its angle 90.
    try r.choose("guide.held", "vertical");
    try std.testing.expectEqual(90, api.guides()[0].angle);
    // Delete removes it.
    try r.key(.delete, .none);
    try std.testing.expectEqual(1, api.guides().len);
}

test "a click puts the caret anywhere inside an expression's braces: between a word's letters, after a script's last character" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try openExample(&r, "HP-15C keypad");
    api.centreOnTile("R2C3", 30);
    try r.frames(2);
    // SIN's g legend: $\mathrm{SIN}^{-1}$.
    const g = api.slotRect("R2C3", "g").?;
    // Its right end, high (the superscript): in the script, after its 1.
    try r.clickAt(.{ .x = g.x + g.w - 1, .y = g.y + g.h * 0.2 });
    try std.testing.expect(api.eqEditing());
    try dvui.testing.writeText("2");
    try r.frames(2);
    try std.testing.expectEqualStrings("$\\mathrm{SIN}^{-12}$", api.eqText().?);
    try r.key(.escape, .none);
    // Between S and I of SIN (low, in the base): inside \mathrm{…}.
    const g2 = api.slotRect("R2C3", "g").?;
    const sin = api.slotGlyphs("R2C3", "g", 0, 3).?;
    try r.clickAt(.{ .x = (sin[0] + sin[1]) / 2, .y = g2.y + g2.h * 0.75 });
    try dvui.testing.writeText("x");
    try r.frames(2);
    try std.testing.expectEqualStrings("$\\mathrm{SxIN}^{-12}$", api.eqText().?);
}

test "a window's tabs: + adds a context from its pop-up (by a click, or by typing and Enter), × takes a tab off, the split button splits" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try openExample(&r, "PC keyboard");
    try std.testing.expectEqual(1, api.windowCount());
    try std.testing.expectEqual(1, api.activeTabs());
    // +: the pop-up; the legend sheet chosen in it, a tab in this window.
    try r.press("views.add");
    try r.frames(2);
    try std.testing.expect(api.addingView());
    const name = api.model().sheets.items[0].name;
    var kb: [96]u8 = undefined;
    var n: usize = 0;
    var dash = false;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c)) {
            if (dash and n > 0) {
                kb[n] = '-';
                n += 1;
            }
            dash = false;
            kb[n] = std.ascii.toLower(c);
            n += 1;
        } else dash = true;
    }
    var ib: [128]u8 = undefined;
    try r.press(try std.fmt.bufPrint(&ib, "views.contexts.{s}", .{kb[0..n]}));
    try r.frames(2);
    try std.testing.expect(!api.addingView());
    try std.testing.expectEqual(.sheet, api.activeView().kind);
    try std.testing.expectEqual(1, api.windowCount());
    try std.testing.expectEqual(2, api.activeTabs());
    // ×: off the tabs, the canvas shown again.
    try r.run("views.close");
    try std.testing.expectEqual(.canvas, api.activeView().kind);
    try std.testing.expectEqual(1, api.activeTabs());
    // By its key, then typing part of the sheet's name and Enter.
    try r.key(.t, .lcontrol);
    try r.frames(2);
    try std.testing.expect(api.addingView());
    try dvui.testing.writeText(name[0..@min(name.len, 4)]);
    try r.frames(1);
    try r.key(.enter, .none);
    try r.frames(2);
    try std.testing.expect(!api.addingView());
    try std.testing.expectEqual(.sheet, api.activeView().kind);
    try std.testing.expectEqual(2, api.activeTabs());
    // Choosing a context already in the window selects its tab.
    try r.run("views.add");
    try r.frames(2);
    try r.press("views.contexts.canvas");
    try r.frames(2);
    try std.testing.expectEqual(.canvas, api.activeView().kind);
    try std.testing.expectEqual(2, api.activeTabs());
    // The split button: two windows; the last tab of one off, one again.
    try r.press("views.split-across");
    try r.frames(2);
    try std.testing.expectEqual(2, api.windowCount());
    try std.testing.expectEqual(1, api.activeTabs());
    try r.key(.w, .lcontrol);
    try r.frames(2);
    try std.testing.expectEqual(1, api.windowCount());
}

test "preview tabs: a context opened from the Browser takes the window's preview tab; work in it or a double-click keeps it" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try openExample(&r, "PC keyboard");
    try std.testing.expect(api.makeSheetLikeFirst("Second legends"));
    try r.frames(2);
    // The first sheet, opened: a preview tab beside the canvas.
    api.openSheetFromBrowser(0);
    try r.frames(2);
    try std.testing.expectEqual(.sheet, api.activeView().kind);
    try std.testing.expect(api.isPreview(api.activeIndex()));
    try std.testing.expectEqual(2, api.activeTabs());
    // The second, opened: in the preview's place, the first gone.
    api.openSheetFromBrowser(1);
    try r.frames(2);
    try std.testing.expectEqual(2, api.activeTabs());
    try std.testing.expectEqual(0, api.sheetViews(0));
    try std.testing.expectEqual(1, api.sheetViews(1));
    try std.testing.expect(api.isPreview(api.activeIndex()));
    // Work in it: kept. The first opened again is a new preview beside it.
    const second = api.activeIndex();
    try r.press("sheet.cell.add-a-row");
    try r.frames(2);
    try std.testing.expect(!api.isPreview(second));
    api.openSheetFromBrowser(0);
    try r.frames(2);
    try std.testing.expectEqual(3, api.activeTabs());
    try std.testing.expect(api.isPreview(api.activeIndex()));
    try std.testing.expectEqual(1, api.sheetViews(1));
    // From the + pop-up: chosen, so kept, not a preview.
    try r.run("views.close");
    try r.run("views.add");
    try r.frames(2);
    try r.press("views.contexts.keyboardlegends");
    try r.frames(2);
    try std.testing.expect(!api.isPreview(api.activeIndex()));
}

test "tabs: a split's grip shows its options: swap sides, even out, stacked; a double-click on the divider evens it out" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try r.press("views.split-across");
    try r.frames(2);
    var sp = api.activeSplit().?;
    try std.testing.expect(!sp.first);
    try std.testing.expectEqual(0, sp.dir);
    // The grip: its options; Swap sides puts the active view first.
    try r.press("views.divider");
    try r.frames(2);
    try std.testing.expect(api.dividerMenuOpen());
    try r.press("views.swap");
    try r.frames(2);
    try std.testing.expect(!api.dividerMenuOpen());
    try std.testing.expect(api.activeSplit().?.first);
    // Stacked.
    try r.press("views.divider");
    try r.frames(2);
    try r.press("views.turn");
    try r.frames(2);
    sp = api.activeSplit().?;
    try std.testing.expectEqual(1, sp.dir);
    // Dragged off the middle, then the divider double-clicked: even again.
    const g = try r.rectOf("views.divider");
    const mid: dvui.Point.Physical = .{ .x = g.x - 40, .y = g.y + g.h / 2 };
    try r.drag(mid, .{ .x = mid.x, .y = mid.y + 200 });
    try std.testing.expect(api.activeSplit().?.ratio > 0.51);
    const g2 = try r.rectOf("views.divider");
    const at: dvui.Point.Physical = .{ .x = g2.x - 40, .y = g2.y + g2.h / 2 };
    try r.clickAt(at);
    try r.clickAt(at);
    try std.testing.expectApproxEqAbs(0.5, api.activeSplit().?.ratio, 1e-6);
}
