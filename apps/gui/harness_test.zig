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

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

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

/// Graven started under the testing backend.
pub const Run = struct {
    t: dvui.testing,

    pub fn start() !Run {
        const io = std.testing.io;
        std.Io.Dir.cwd().createDirPath(io, scratch ++ "/config") catch {};
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = scratch ++ "/config/local.toml", .data = config });
        std.Io.Dir.cwd().deleteFile(io, scratch ++ "/config/shared.toml") catch {};
        _ = setenv("GRAVEN_CONFIG_DIR", scratch ++ "/config", 1);
        _ = setenv("GRAVEN_FONTS_INDEX", scratch ++ "/fonts-index.json", 1);
        _ = setenv("GRAVEN_MOTD_URL", "none", 1);
        const t = try dvui.testing.init(.{ .allocator = std.heap.c_allocator, .window_size = .{ .w = 1600, .h = 4000 } });
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
        try dvui.testing.writeText(text);
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

test "the PC keyboard, made in the GUI" {
    var r = try Run.start();
    defer r.stop();
    try r.key(.m, .none);
    try makeStyle(&r, "legend", "2.6");
    try makeStyle(&r, "legend words", "1.6");
    try makeKeyPrototype(&r);
    const m = api.model();
    const p = m.prototypes.items[m.prototypes.items.len - 1];
    try std.testing.expectEqualStrings("key", p.name);
    try std.testing.expectEqual(3, p.tracks.len);
    try std.testing.expectEqualStrings("words", p.tracks[2].name);
    try std.testing.expectEqual(6.45, p.tracks[1].place.inset.top);
    try std.testing.expect(p.art.?.layers[0].paint.fill == .linear);
    try std.testing.expectEqual(8, p.widths.len);
}
