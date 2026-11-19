//! The GUI without a screen: Graven's own frames run under DVUI's testing
//! backend, its widgets found by their tags and driven as a person would
//! (move, click, type, keys). `zig build gui-test`.
//!
//! Tags (main.zig, "Tags"): a property row "<section heading>/<field>", a
//! button "<section heading>/<label>", a menu item "menu/<label>", a
//! Browser node "tree/<path>", a content palette button "palette/<kind>".
//! A dropdown is chosen through `testing_api.choose` (its entries carry no
//! tags); everything else is clicked and typed.
//!
//! Each test starts Graven afresh with a scratch config (docked panes, no
//! user settings, no news fetched) in a window tall enough that no
//! property list needs scrolling.

const std = @import("std");
const dvui = @import("dvui");
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
    /// replacing what it held.
    pub fn set(r: *Run, tag: []const u8, text: []const u8) !void {
        try r.clickIn(tag, 0.8, 0.5);
        try dvui.testing.pressKey(.a, .lcontrol);
        try r.frames(1);
        // Typing replaces the selection; nothing typed, it is deleted.
        if (text.len == 0) try dvui.testing.pressKey(.backspace, .none) else try dvui.testing.writeText(text);
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
        try r.frames(2);
    }
};

/// Prints this frame's tags that start with `prefix` (for writing tests).
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
    try r.click("tree/untitled/Text styles");
    try r.click("Text styles/Add a style");
    const m = api.model();
    const sid = m.styles.items[m.styles.items.len - 1].id;
    try r.set("Text style/Name", "legend");
    try r.set("Text style/Cap height, mm", "2.6");
    try r.set("Faces/Text face family", "Inter");
    try r.set("Faces/Text face style", "Medium");
    const st = m.textStyle(sid);
    try std.testing.expectEqualStrings("legend", st.name);
    try std.testing.expectApproxEqAbs(2.6, st.cap_height, 1e-9);
    try std.testing.expectEqualStrings("Inter", st.face("text").?.family);
    try std.testing.expectEqualStrings("Medium", st.face("text").?.style);
}

// The PC keyboard, made in the GUI ------------------------------------------

/// A style made in the Browser: its name, cap height and text face.
fn makeStyle(r: *Run, name: []const u8, cap: []const u8) !void {
    try r.click("tree/untitled/Text styles");
    try r.click("Text styles/Add a style");
    try r.set("Text style/Name", name);
    try r.set("Text style/Cap height, mm", cap);
    try r.set("Faces/Text face family", "Inter");
    try r.set("Faces/Text face style", "Medium");
}

/// The keyboard's key prototype: 19.05 mm u, its insets, its sizes, three
/// slots (one legend each), keycap art shaded back to front.
fn makeKeyPrototype(r: *Run) !void {
    try r.click("tree/untitled/Tile prototypes");
    try r.click("icon/Add prototype");
    try r.set("Tile prototype/Name", "key");
    try r.set("Tile prototype/Unit, mm per u", "19.05");
    inline for (.{ "left", "right", "top", "bottom" }) |side| try r.set("Tile prototype/Body inset " ++ side ++ ", mm", "0.475");
    try r.set("Tile prototype/Face inset left, mm", "2.7");
    try r.set("Tile prototype/Face inset right, mm", "2.7");
    try r.set("Tile prototype/Face inset top, mm", "1.6");
    try r.set("Tile prototype/Face inset bottom, mm", "3.6");
    try r.set("Tile prototype/Widths, u", "1, 1.25, 1.5, 1.75, 2, 2.25, 2.75, 6.25");
    try r.set("Tile prototype/Heights, u", "1, 2");
    // Slots, one legend each, overlapping: top (the whole face), bottom
    // (its lower half), words (the whole face, smaller).
    try r.choose("Track top/Style", "legend");
    try r.click("Track top/Add track");
    try r.set("Track track 2/Name", "bottom");
    try r.choose("Track bottom/Style", "legend");
    try r.choose("Track bottom/Set from", "start");
    try r.set("Track bottom/Inset top, mm", "6.45");
    try r.click("Track bottom/Add track");
    try r.set("Track track 3/Name", "words");
    try r.choose("Track words/Style", "legend words");
    try r.choose("Track words/Set from", "start");
    // Keycap art drawn from the insets now set, shaded back to front.
    try r.click("Layer face/Remove art");
    try r.click("Art/Add keycap art");

    try r.choose("Layer body/Fill kind", "a gradient");
    try r.set("Layer body/Gradient from", "#e9e7e1");
    try r.set("Layer body/Gradient to", "#cfccc3");
    try r.choose("Layer face/Fill kind", "a gradient");
    try r.set("Layer face/Gradient from", "#faf9f6");
    try r.set("Layer face/Gradient to", "#efede8");
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

fn screen(p: struct { f64, f64 }) !dvui.Point.Physical {
    return api.toScreen(.{ .x = p[0], .y = p[1] }) orelse error.NoCanvas;
}

/// The keyboard as a person makes it in the GUI: styles, the key
/// prototype, a panel, a track, 104 keys from the content palette, their
/// names, gaps and heights, and their legends from a CSV table.
fn makeKeyboard(r: *Run) !void {
    try r.key(.m, .none);
    try makeStyle(r, "legend", "2.6");
    try checkSaveable("a style");
    try makeStyle(r, "legend words", "1.6");
    try makeKeyPrototype(r);
    try checkSaveable("the prototype");

    // The panel: drawn out, then typed exactly.
    try r.click("tree/untitled/Canvas, mm");
    try r.click("icon/Add panel");
    try r.drag(try screen(.{ 10, 10 }), try screen(.{ 80, 50 }));
    try r.click("tree/untitled/Canvas, mm/Panel 1");
    try r.set("Panel/Name", "PC keyboard (ANSI 104)");
    try r.set("Panel/Origin across, mm", "0");
    try r.set("Panel/Origin up, mm", "0");
    try r.set("Panel/Width, mm", "448.625");
    try r.set("Panel/Height, mm", "143.825");
    inline for (.{ "Left", "Right", "Top", "Bottom" }) |side| try r.set("Margins/" ++ side ++ ", mm", "5");

    try checkSaveable("the panel");
    // The track: rows of keys, drawn out on the panel, then typed exactly.
    try r.click("icon/Add rows");
    try r.choose("Add rows/Size to", "Tile: key");
    try r.drag(try screen(.{ 20, 120 }), try screen(.{ 200, 60 }));
    try r.set("Region/Name", "keys");
    try r.set("Region/Origin across, mm", "10");
    try r.set("Region/Origin up, mm", "133.825");
    try r.set("Region/Length, u", "22.5");
    try r.set("Region/Depth, rows", "6.5");

    // The keys, from the content palette at the cursor: a row's keys, then
    // a line break; the second row starts a paragraph whose style puts
    // half a unit before it.
    for (rows, 0..) |row, ri| {
        if (ri == 1) {
            try r.click("palette/paragraph");
        } else if (ri > 1) try r.click("palette/hard_break");
        for (row) |k| {
            var tb: [32]u8 = undefined;
            try r.click(try std.fmt.bufPrint(&tb, "palette/key {d} u", .{k.w}));
        }
    }

    // The second paragraph (the cursor is in it, at the end): a style of
    // its own, half a unit (27 pt) before it.
    try r.click("Paragraph/New paragraph style");
    try r.set("Paragraph/Name", "Row gap 0.5 u");
    try r.set("Paragraph/Space before, pt", "27");

    try checkSaveable("the keys");
    // Named in order, K1 to K104, from the track's properties.
    try r.click("tree/untitled/Canvas, mm/PC keyboard (ANSI 104)/keys");
    try r.click("Region/Name keys in order: K1, K2 …");

    // Gaps and heights, key by key: the key clicked on the canvas (the
    // panel chosen first, so a click picks a key rather than placing the
    // cursor), then its properties.
    // Each row opened in the Browser, then each key that needs it chosen
    // there (its node is its name, then its legend).
    const keys_node = "tree/untitled/Canvas, mm/PC keyboard (ANSI 104)/keys";
    for (1..rows.len + 1) |ri| {
        var tb: [128]u8 = undefined;
        try r.click(try std.fmt.bufPrint(&tb, "{s}/Row {d}#open", .{ keys_node, ri }));
    }
    var n: usize = 0;
    for (rows) |row| for (row) |k| {
        n += 1;
        if (k.gap == 0 and k.h == 1) continue;
        var tb: [128]u8 = undefined;
        try r.click(try r.tagStarting(try std.fmt.bufPrint(&tb, "{s}/K{d} ", .{ keys_node, n })));
        var vb: [16]u8 = undefined;
        if (k.gap != 0) try r.set("Tile/Gap before, u", try std.fmt.bufPrint(&vb, "{d}", .{k.gap}));
        if (k.h != 1) try r.choose("Tile/Height", try std.fmt.bufPrint(&vb, "{d} u", .{k.h}));
    };

    try checkSaveable("gaps and heights");
    // The legends: a table, one row a key, imported over the track.
    const csv = try legendsCsv(std.heap.c_allocator);
    defer std.heap.c_allocator.free(csv);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = scratch ++ "/keyboard-legends.csv", .data = csv });
    try r.click("tree/untitled/Canvas, mm/PC keyboard (ANSI 104)/keys");
    try r.click("menu/File");
    try r.click("menu/Import legend sheet (CSV)…");
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
    try sameAsExample(m, "examples/pc-keyboard.graven", &.{"PC keyboard (ANSI 104)"});
    // Saved as made: the example document's source.
    try saveAs(&r, scratch ++ "/pc-keyboard.graven");
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
    try r.click("menu/File");
    try r.click("menu/Save As…");
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
    const parts = try layout.threemf.orient(ar, try layout.threemf.parts(ar, slabs, layout.threemf.default_tolerance, .colours), .bottom);
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
    try r.click("tree/untitled/Text styles");
    try r.click("Text styles/Add a style");
    try r.set("Text style/Name", name);
    try r.choose("Text style/Based on", "Libertinus");
    try r.set("Text style/Cap height, mm", cap);
    try r.set("Text style/Line pitch, cap heights", "1.5");
    try r.click("Faces/Add a rule");
    try r.choose("Faces/rule 1 parameter", "sup_raise");
    try r.set("Faces/rule 1 value", "0.5");
    try r.click("Faces/Add a rule");
    try r.choose("Faces/rule 2 parameter", "sub_drop");
    try r.set("Faces/rule 2 value", "0.24");
}

/// A plain prototype: its tracks' size from the grid it is placed on (no
/// unit), no body inset, the face inset given, no art.
fn makePlainPrototype(r: *Run, name: []const u8, face: []const u8) !void {
    try r.click("tree/untitled/Tile prototypes");
    try r.click("icon/Add prototype");
    try r.set("Tile prototype/Name", name);
    try r.set("Tile prototype/Unit, mm per u", "");
    inline for (.{ "left", "right", "top", "bottom" }) |side| {
        try r.set("Tile prototype/Body inset " ++ side ++ ", mm", "0");
        try r.set("Tile prototype/Face inset " ++ side ++ ", mm", face);
    }
    try r.click("Layer face/Remove art");
}

/// A track's style, alignment and insets (left, right, top, bottom).
fn setTrack(r: *Run, track: []const u8, style: []const u8, from: []const u8, insets: [4][]const u8) !void {
    var b: [96]u8 = undefined;
    try r.choose(try std.fmt.bufPrint(&b, "Track {s}/Style", .{track}), style);
    try r.choose(try std.fmt.bufPrint(&b, "Track {s}/Set from", .{track}), from);
    for (insets, [_][]const u8{ "left", "right", "top", "bottom" }) |v, side| {
        try r.set(try std.fmt.bufPrint(&b, "Track {s}/Inset {s}, mm", .{ track, side }), v);
    }
}

fn addTrack(r: *Run, after: []const u8, number: usize, name: []const u8) !void {
    var b: [96]u8 = undefined;
    try r.click(try std.fmt.bufPrint(&b, "Track {s}/Add track", .{after}));
    try r.set(try std.fmt.bufPrint(&b, "Track track {d}/Name", .{number}), name);
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
    try r.click("tree/untitled/Canvas, mm");
    try r.click("icon/Add panel");
    try r.drag(try screen(.{ at[0], at[1] }), try screen(.{ at[0] + 30, at[1] + 20 }));
    var b: [96]u8 = undefined;
    try r.click(try std.fmt.bufPrint(&b, "tree/untitled/Canvas, mm/{s}", .{default}));
    try r.set("Panel/Name", name);
    try r.set("Panel/Origin across, mm", origin_x);
    try r.set("Panel/Origin up, mm", "0");
    try r.set("Panel/Width, mm", "128");
    try r.set("Panel/Height, mm", "62");
    inline for (.{ "Left", "Right", "Top", "Bottom" }) |side| try r.set("Margins/" ++ side ++ ", mm", "3");
}

/// Places the stamp chosen by `places` at a grid point by a click on it,
/// or across two points by a drag.
fn place(r: *Run, editing: []const u8, places: []const u8, pi: usize, c: u32, row: u32, span_down: bool) !void {
    var b: [96]u8 = undefined;
    try r.choose(try std.fmt.bufPrint(&b, "Editing {s}/Places", .{editing}), places);
    const at = api.gridPoint(pi, 0, c, row) orelse return error.NoGrid;
    if (span_down) {
        try r.drag(at, api.gridPoint(pi, 0, c, row + 1) orelse return error.NoGrid);
    } else try r.clickAt(at);
}

fn make15c(r: *Run) !void {
    try r.key(.m, .none);
    try r.click("tree/untitled/Text styles");
    try r.click("From a math package/Add a Libertinus style");
    try make15cStyle(r, "15C key", "1.9");
    try make15cStyle(r, "15C g", "1.25");
    try make15cStyle(r, "15C f", "1.4");

    try makePlainPrototype(r, "15C key", "0.4");
    try setTrack(r, "top", "15C key", "centre", .{ "0", "0", "0.7", "2.65" });
    try addTrack(r, "top", 2, "g");
    try setTrack(r, "g", "15C g", "centre", .{ "0", "0", "4.5", "0" });

    try makePlainPrototype(r, "15C ENTER key", "0.4");
    try setTrack(r, "top", "15C key", "centre", .{ "2.175", "2.175", "1", "2.65" });
    try r.choose("Track top/Runs", "down columns");
    try addTrack(r, "top", 2, "g");
    try setTrack(r, "g", "15C g", "centre", .{ "0", "0", "17.2", "0" });

    try makePlainPrototype(r, "15C gold legend", "0");
    try r.set("Track top/Name", "f");
    try setTrack(r, "f", "15C f", "centre", .{ "0", "0", "0", "0" });

    // The plate and the keys, side by side, 15 mm apart.
    try make15cPanel(r, "Panel 1", "HP-15C plate", .{ 10, 10 }, "0");
    try make15cPanel(r, "Panel 2", "HP-15C keys", .{ 60, 80 }, "143");

    // The plate's grid: 10 × 4 points, 11.43 mm across, 12.7 mm down;
    // its holes (rounded rectangles, r 1 mm) and its gold legends.
    try r.click("tree/untitled/Canvas, mm/HP-15C plate");
    try r.click("Grids/Add grid");
    try r.set("Points/Columns", "10");
    try r.set("Points/Rows", "4");
    try r.set("Points/Spacing across, mm", "11.43");
    try r.set("Points/Spacing down, mm", "12.7");
    try r.set("Points/First point across, mm", "12.565");
    try r.set("Points/First point up, mm", "50");
    try r.click("Add a stamp/Holes");
    try r.choose("Stamp: Holes/Prototype", "15C key");
    try r.set("Stamp: Holes/Width, mm", "8.5");
    try r.set("Stamp: Holes/Height, mm", "7.7");
    try r.choose("Stamp: Holes/Shape", "Rounded rectangle");
    try r.set("Stamp: Holes/r, mm", "1");
    try r.click("Add a stamp/Legends");
    try r.choose("Stamp: Legends/Prototype", "15C gold legend");
    try r.set("Stamp: Legends/Width, mm", "11");
    try r.set("Stamp: Legends/Height, mm", "2.4");
    try r.set("Stamp: Legends/Offset up, mm", "5.15");

    // The keys' grid follows the plate's; on it, the keys themselves.
    try r.choose("Add a stamp/Follow it on", "HP-15C keys");
    try r.click("tree/untitled/Canvas, mm/HP-15C keys");
    try r.click("Grids/Grid 1");
    try r.click("Add a stamp/Parts");
    try r.choose("Stamp: Parts/Prototype", "15C key");
    try r.set("Stamp: Parts/Width, mm", "8");
    try r.set("Stamp: Parts/Height, mm", "7.2");

    // Placed point by point in panel editing, as the code placed them:
    // row by row, a hole then its gold legend; ENTER over two rows.
    const plate = api.panelNamed("HP-15C plate").?;
    const keys = api.panelNamed("HP-15C keys").?;
    try r.click("tree/untitled/Canvas, mm/HP-15C plate");
    try r.click("Margins/Edit panel");
    for (keys15, 0..) |row, ri| for (row, 0..) |k, ci| {
        const c: u32 = @intCast(ci);
        const rw: u32 = @intCast(ri);
        if (c == 5 and rw == 3) continue;
        try place(r, "HP-15C plate", "Holes", plate, c, rw, c == 5 and rw == 2);
        if (k.f.len > 0) try place(r, "HP-15C plate", "Legends", plate, c, rw, false);
    };
    try r.click("Editing HP-15C plate/Leave panel editing");
    try r.click("tree/untitled/Canvas, mm/HP-15C keys");
    try r.click("Margins/Edit panel");
    for (keys15, 0..) |row, ri| for (row, 0..) |_, ci| {
        const c: u32 = @intCast(ci);
        const rw: u32 = @intCast(ri);
        if (c == 5 and rw == 3) continue;
        try place(r, "HP-15C keys", "Parts", keys, c, rw, c == 5 and rw == 2);
    };
    // ENTER picked (a click on it) and given its own prototype.
    try r.clickAt(api.gridPoint(keys, 0, 5, 2).?);
    try r.choose("Tile/Prototype", "15C ENTER key");
    try r.click("Editing HP-15C keys/Leave panel editing");

    // Fabrication: the plate black with its holes cut through and its gold
    // legends inlaid; the keys black with white and blue legends inlaid.
    // Made with a 0.2 mm nozzle: 0.4 mm cannot hold its legends.
    try r.click("tree/untitled/Canvas, mm/HP-15C plate");
    try r.choose("Fabrication/Process", "Generic FDM, 0.2 mm nozzle (built in)");
    try r.set("Fabrication/Thickness, mm", "2");
    try r.click("Fabrication/Add layer");
    try r.set("Layer 1/Name", "Plate");
    try r.click("Fabrication/Add layer");
    try r.set("Layer 2/Name", "Key holes");
    try r.choose("Layer 2/From", "holes and cutouts");
    try r.choose("Layer 2/Makes", "a cut, away");
    try r.click("Layer 2/Through the whole part");
    try r.click("Fabrication/Add layer");
    try r.set("Layer 3/Name", "Gold legends");
    try r.choose("Layer 3/Slot", "f");
    try r.set("Layer 3/Colour name", "gold");
    try r.set("Layer 3/Colour", "#c9a227");
    try r.click("tree/untitled/Canvas, mm/HP-15C keys");
    try r.choose("Fabrication/Process", "Generic FDM, 0.2 mm nozzle");
    try r.set("Fabrication/Thickness, mm", "5");
    try r.click("Fabrication/Add layer");
    try r.set("Layer 1/Name", "Keys");
    try r.choose("Layer 1/From", "grid parts");
    try r.click("Fabrication/Add layer");
    try r.set("Layer 2/Name", "White legends");
    try r.choose("Layer 2/Slot", "top");
    try r.click("Fabrication/Add layer");
    try r.set("Layer 3/Name", "Blue legends");
    try r.choose("Layer 3/Slot", "g");
    try r.set("Layer 3/Colour name", "blue");
    try r.set("Layer 3/Colour", "#3a7bd5");

    // The legends: a sheet over the keys' grid, its keys named by their
    // place, a table imported into it.
    try r.click("Grids/Grid 1");
    try r.click("Grid/Make a legend sheet");
    try r.click("Legends of HP-15C keys/Name keys by grid position (R1C1…)");
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
    try r.click("menu/File");
    try r.click("menu/Import legend sheet (CSV)…");
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
    try r.click("tree/untitled/Processes");
    try r.click("Add a profile/Generic FDM, 0.4 mm nozzle");
    const m = api.model();
    try std.testing.expectEqual(@as(usize, 1), m.processes.items.len);
    const id = m.processes.items[0].id;
    try r.set("Process profile/Name", "Fine");
    try r.set("FDM/Nozzle, mm", "0.25");
    try r.set("FDM/Line width, mm", "0.27");
    var p = m.processes.items[m.processIndex(id).?].profile;
    try std.testing.expectEqualStrings("Fine", p.name);
    try std.testing.expectEqual(0.27, p.limits().stroke.pass);
    try std.testing.expectEqual(@as(?process.Band, null), p.stroke);
    try r.set("Limits/Stroke passes at, mm", "0.3");
    p = m.processes.items[m.processIndex(id).?].profile;
    try std.testing.expectEqual(0.3, p.stroke.?.pass);
    try std.testing.expectEqual(0.125, p.stroke.?.fail);
    try r.click("Limits/Use the limits its settings give");
    p = m.processes.items[m.processIndex(id).?].profile;
    try std.testing.expectEqual(@as(?process.Band, null), p.stroke);
    // A second from the same built-in is numbered.
    try r.click("tree/untitled/Processes");
    try r.click("Add a profile/Generic FDM, 0.4 mm nozzle");
    try r.click("tree/untitled/Processes");
    try r.click("Add a profile/Generic FDM, 0.4 mm nozzle");
    try std.testing.expectEqualStrings("Generic FDM, 0.4 mm nozzle (2)", m.processes.items[2].profile.name);
    // Unused, it can go.
    try r.click("tree/untitled/Processes#open");
    try r.click("tree/untitled/Processes/Fine");
    try r.click("Used by/Remove this profile");
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
    try r.click("tree/untitled/Canvas, mm");
    _ = try r.rectOf("Results/Check again");
    // Out of date once the document changes.
    try std.testing.expect(!api.checksOutOfDate());
    try r.click("tree/untitled/Canvas, mm/HP-15C plate");
    try r.set("Fabrication/Thickness, mm", "2.2");
    try std.testing.expect(api.checksOutOfDate());
    // One panel, from its Fabrication.
    try r.click("Fabrication/Check this panel");
    try r.frames(2);
    try std.testing.expectEqual(@as(usize, 1), api.checkedPanels().len);
    try std.testing.expect(!api.checksOutOfDate());
    try r.click("tree/untitled/Canvas, mm");
    try r.click("Results/Clear results");
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
    try r.click("tree/untitled/Manufacturing plans#open");
    try r.click("tree/untitled/Manufacturing plans/Plan 1");
    try r.click("Manufacturing plan/Open in a manufacturing view");
    try r.frames(2);
    try std.testing.expectEqual(.manufacture, api.activeView().kind);
    try std.testing.expectEqual(@intFromEnum(m.plans.items[0].id), api.activeView().target);
    // A second plan: the plate black anodised aluminium, waterjet cut and
    // engraved.
    try r.click("tree/untitled/Manufacturing plans");
    try r.click("Manufacturing plans/Add a plan");
    try std.testing.expectEqual(@as(usize, 2), m.plans.items.len);
    const id = m.plans.items[1].id;
    try r.choose("Parts/HP-15C plate", "Aluminium 5052, black anodised (library)");
    try r.choose("Parts/HP-15C keys", "PLA");
    try r.click("Operations/Add an operation");
    try r.choose("1. Operation 1/Process", "Generic waterjet (built in)");
    try r.click("1. Operation 1/HP-15C plate · Plate");
    try r.click("1. Operation 1/HP-15C plate · Key holes");
    try r.click("Operations/Add an operation");
    try r.choose("2. Operation 2/Process", "Generic laser engraver (built in)");
    try r.click("2. Operation 2/HP-15C plate · Gold legends");
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
    try r.click("2. Operation 2/Earlier");
    pl = m.plans.items[m.planIndex(id).?];
    try std.testing.expectEqualStrings("Operation 2", pl.operations[0].name);
    for (try layout.model.manufacture.warnings(arena.allocator(), m, pl)) |w| {
        try std.testing.expect(w.kind != .mark_after_cut);
    }
    // The engraving's mark: the bare metal under the anodising.
    try std.testing.expectEqualStrings("bare aluminium", pl.operations[0].targets[0].colour.?.name);
    // Plan 1 stays the one exported.
    try std.testing.expectEqual(m.plans.items[0].id, m.active_plan);
    try saveAs(&r, scratch ++ "/hp15c-plans.graven");
}

// Known bugs, kept fixed --------------------------------------------------------

/// Opens an example from the File menu (an untitled copy).
fn openExample(r: *Run, label: []const u8) !void {
    var b: [64]u8 = undefined;
    try r.click("menu/File");
    try r.click(try std.fmt.bufPrint(&b, "menu/Open example: {s}", .{label}));
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
    _ = try r.rectOf("Tile/Gap before, u");
    // And after the flow cursor has been in its track, then the track and
    // the panel chosen in the Browser (as when keys are filled in).
    try r.click("tree/untitled/Canvas, mm/PC keyboard (ANSI 104)/keys");
    try r.clickAt(try screen(.{ 400, 120 }));
    try r.click("tree/untitled/Canvas, mm/PC keyboard (ANSI 104)/keys");
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
