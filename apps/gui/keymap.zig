//! Graven's actions, modes and default keys (the machinery is
//! `actions.zig`), and matching DVUI's key and text events against them.
//!
//! Action names are message IDs too: the interface's labels for them will
//! come from a translation catalogue keyed by these names.
//!
//! Each place in the GUI that takes keys asks for the action its event
//! means in the mode (or modes, innermost first) it serves, and does it;
//! where it is asked keeps the keyboard's focus as it was. The modes active
//! now (`stack`) let a mode that takes typed text keep the unchorded
//! printable keys of the modes around it.

const std = @import("std");
const elements = @import("elements.zig");
const builtin = @import("builtin");
const platform = @import("graven_platform");
const dvui = @import("dvui");
const actions = @import("actions.zig");
const kb = @import("graven_keys");

pub const Direction = actions.Direction;

const M = actions.ModeDef;
const A = actions.ActionDef;
const B = actions.BindDef;

pub const modes = [_]M{
    .{ .name = "global", .kind = .root, .allows = &.{ "file", "edit", "panes", "views" } },
    // Prompts and small windows over the rest: Enter and Esc. One with a
    // text field takes typed text.
    .{ .name = "dialog", .kind = .dialog, .lifetime = .until_left, .parent = "global", .takes_text = true, .allows = &.{"dialog"} },
    .{ .name = "dialog.calibrate-size", .kind = .dialog, .lifetime = .until_left, .parent = "global", .extends = "dialog", .allows = &.{"dialog.calibrate-size"} },
    // The view of the canvas, a sketch or a panel being edited: zoom.
    // Layered on those major modes; its unchorded keys give way to typing.
    .{ .name = "view", .kind = .minor, .parent = "global", .allows = &.{ "view", "fab" } },
    // No document yet.
    .{ .name = "start", .kind = .major, .parent = "global", .allows = &.{"start"} },
    // The canvas, and what nests in it.
    .{ .name = "canvas", .kind = .major, .parent = "global", .allows = &.{ "canvas.object", "canvas.tile", "canvas.tool", "level", "tool", "ribbon", "views" } },
    // Engagement points near the pointer (or one locked onto).
    .{ .name = "canvas.engage", .kind = .sub, .parent = "canvas", .allows = &.{"canvas.engage"} },
    .{ .name = "canvas.selection", .kind = .sub, .parent = "canvas", .allows = &.{"canvas.selection"} },
    // The constraints for the object chosen (K with one chosen), while
    // their pop-up is open.
    .{ .name = "canvas.constrain-menu", .kind = .sub, .parent = "canvas", .allows = &.{"constrain-menu"} },
    // The constraints for the containers chosen (K with them chosen),
    // while their pop-up is open.
    .{ .name = "canvas.constrain-objects", .kind = .sub, .parent = "canvas", .allows = &.{"constrain-objects"} },
    .{ .name = "canvas.flow", .kind = .sub, .lifetime = .until_left, .parent = "canvas", .takes_text = true, .allows = &.{ "canvas.flow", "text" } },
    // Choosing a case (Ctrl+Space in a flow): a digit picks one, Space goes
    // back to the case before.
    .{ .name = "canvas.flow.case-picker", .kind = .sub, .lifetime = .until_left, .parent = "canvas.flow", .takes_text = true, .allows = &.{"canvas.flow.case-picker"} },
    .{ .name = "canvas.equation", .kind = .sub, .lifetime = .until_left, .parent = "canvas", .takes_text = true, .allows = &.{"canvas.equation"} },
    .{ .name = "canvas.equation.head", .kind = .sub, .parent = "canvas.equation", .allows = &.{"canvas.equation.head"} },
    // The expression line under the canvas.
    .{ .name = "expression-line", .kind = .sub, .parent = "canvas", .takes_text = true, .allows = &.{"expression-line.tab"} },
    .{ .name = "expression-line.completion", .kind = .sub, .parent = "expression-line", .allows = &.{"expression-line.completion"} },
    .{ .name = "expression-line.run", .kind = .sub, .parent = "expression-line", .allows = &.{"expression-line.run"} },
    // A sheet's view: its cells shown as the glyphics they set, moving
    // between them, and typing starting an edit.
    .{ .name = "sheet", .kind = .major, .parent = "global", .takes_text = true, .allows = &.{"sheet"} },
    // A sheet's cell in edit mode: its markup typed, in an editor.
    .{ .name = "sheet.edit", .kind = .sub, .parent = "sheet", .takes_text = true, .allows = &.{"sheet"} },
    // A panel's grid instances being placed.
    .{ .name = "panel-edit", .kind = .major, .lifetime = .until_left, .parent = "global", .allows = &.{"panel-edit"} },
    // A sketch being drawn and constrained, and its summary.
    .{ .name = "sketch", .kind = .major, .lifetime = .until_left, .parent = "global", .allows = &.{ "sketch.tab", "sketch.cancel", "sketch.finish", "sketch.delete", "sketch.constraint", "sketch.tool", "sketch.ink", "sketch.fill", "sketch.caption", "sketch.connect", "sketch.end", "sketch.show" } },
    .{ .name = "sketch.summary", .kind = .sub, .parent = "sketch", .allows = &.{"sketch.summary"} },
    // Text being typed somewhere, the canvas or a field (whatever asked
    // for text input last frame): the digraph key, and the two characters
    // after it.
    .{ .name = "text-entry", .kind = .minor, .parent = "global", .allows = &.{"text"} },
    .{ .name = "digraph", .kind = .sub, .lifetime = .until_left, .parent = "text-entry", .takes_text = true, .allows = &.{"digraph"} },
};

pub const action_defs = [_]A{
    // Done by the properties pane's buttons (virtual keys: a button's id
    // is its action's name, see elements.zig), on the context.
    .{ .name = "track.make-tracks" },
    .{ .name = "flow-style.update-style-for-all-flows" },
    .{ .name = "flow-style.clear-overrides" },
    .{ .name = "flow-style.save-as-template" },
    .{ .name = "track.remove" },
    .{ .name = "track.name-tiles" },
    // A panel's keys named in order: its tracks in turn, each flow's keys.
    .{ .name = "panel.name-tiles" },
    .{ .name = "track.flow.show" },
    .{ .name = "track.flow.join-after" },
    .{ .name = "track.flow.take-out" },
    .{ .name = "flows.new" },
    .{ .name = "flow.remove" },
    .{ .name = "panel.edit" },
    .{ .name = "panel.release" },

    // Bring every auto-hide pane in, or let them all go (a hot corner's).
    .{ .name = "panes.toggle-auto" },
    // The document's views: a new one beside the active one, closing it,
    // filling the window with it, the next one.
    .{ .name = "views.split-across" },
    .{ .name = "views.split-down" },
    .{ .name = "views.close" },
    .{ .name = "views.maximize" },
    .{ .name = "views.next", .repeat = true, .param = .int },
    // A paged context's pages: arg 0 one page, 1 to the first or last.
    .{ .name = "views.page-prev", .repeat = true, .param = .int },
    .{ .name = "views.page-next", .repeat = true, .param = .int },
    // To the cell above (0), below (1), after (2) or before (3).
    .{ .name = "sheet.move", .repeat = true, .param = .int },
    // The selected cell's edit mode (its markup), and back to display mode
    // (the glyphics it sets).
    .{ .name = "sheet.edit" },
    .{ .name = "sheet.edit.leave" },
    // The pane layouts (layouts.zig): the next one, the panes as they are
    // saved as a new one, this machine's changes to the one in use dropped.
    .{ .name = "panes.layout-next" },
    .{ .name = "panes.layout-save-as" },
    .{ .name = "panes.layout-reset" },
    .{ .name = "file.new" },
    // A new drawing: a sketch in its own space (a canvas first, if none).
    .{ .name = "file.new-drawing" },
    .{ .name = "file.open" },
    .{ .name = "file.save" },
    .{ .name = "file.save-as" },
    .{ .name = "edit.undo", .repeat = true },
    .{ .name = "edit.redo", .repeat = true },

    // Zoom to fit the context (the selection, else what holds it).
    .{ .name = "view.zoom-fit" },
    // Zoom to fit everything on the canvas.
    .{ .name = "view.zoom-all" },
    // Per cent of actual size.
    .{ .name = "view.zoom-to", .param = .int },
    // Held: a drag pans, whatever is under it (a while-held mode).
    .{ .name = "view.pan-hold" },
    // Held: a drag zooms (up in, down out) about where it starts; tapped
    // alone, a zoom step in (arg 0) or out (1) about the pointer.
    .{ .name = "view.zoom-hold", .param = .int },
    // How scrolling acts on the canvas: arg 0 automatic, 1 zooms, 2 pans.
    .{ .name = "view.scrolling", .param = .int },
    // What is being edited, legible, with as much around it as shows so.
    .{ .name = "view.frame-edit" },
    // The context brought into view: nothing if it is already inside the
    // view's margins, else the least pan (and only the zoom out needed) to
    // bring it there. The Browser does it on a choice. No key yet (the
    // owner, 2026-11-22).
    .{ .name = "view.reveal" },
    .{ .name = "view.zoom-in", .repeat = true },
    .{ .name = "view.zoom-out", .repeat = true },
    // Drags snap to the grid, or not.
    .{ .name = "view.snap-grid" },
    // Drags snap to other objects' edges and centres and to construction
    // lines (smart guides), or not.
    .{ .name = "view.snap-objects" },
    // The canvas theme (canvas_theme.zig): arg its index, -1 the next one.
    .{ .name = "view.canvas-theme", .param = .int },
    // The fabrication checks (DRC) and the process's simulation, run on
    // the context's panel, else every panel with a process profile; shown
    // as result layers. Only ever run when asked.
    .{ .name = "fab.check" },

    .{ .name = "dialog.confirm" },
    .{ .name = "dialog.cancel" },
    // The card's width, device pixels.
    .{ .name = "dialog.calibrate-size.grow", .repeat = true, .param = .int },

    // The units' index: 0 mm, 1 inches.
    .{ .name = "start.new-canvas", .param = .int },
    .{ .name = "start.new-canvas-last" },
    .{ .name = "start.open" },
    .{ .name = "start.new-drawing" },
    .{ .name = "start.display-correction" },
    // Which recent file, from 0.
    .{ .name = "start.open-recent", .param = .int },

    // By the grid's minor unit showing (`…-far`: its major unit).
    .{ .name = "canvas.object.nudge", .repeat = true, .param = .direction },
    .{ .name = "canvas.object.nudge-far", .repeat = true, .param = .direction },
    .{ .name = "canvas.object.delete" },
    .{ .name = "canvas.tile.edit-text" },
    .{ .name = "level.up" },
    .{ .name = "level.down" },
    .{ .name = "canvas.tool.cancel" },
    .{ .name = "canvas.tool.finish" },

    // Locks onto the nearest engagement point, then the next (1: back).
    .{ .name = "canvas.engage.lock", .repeat = true, .param = .int },
    .{ .name = "canvas.engage.release" },
    // 0 forward, 1 back.
    .{ .name = "canvas.selection.hunt", .repeat = true, .param = .int },
    .{ .name = "canvas.selection.clear" },
    .{ .name = "canvas.selection.nudge", .repeat = true, .param = .direction },
    .{ .name = "canvas.selection.nudge-far", .repeat = true, .param = .direction },

} ++ textActions() ++ [_]A{
    .{ .name = "text.select.all" },
    .{ .name = "text.edit.copy" },
    .{ .name = "text.edit.cut" },
    .{ .name = "text.edit.paste" },
    .{ .name = "text.edit.paste-plain" },
    .{ .name = "text.edit.new-paragraph", .repeat = true },
    .{ .name = "text.edit.new-line", .repeat = true },
    .{ .name = "text.edit.transpose", .repeat = true },
    .{ .name = "text.edit.case-upper" },
    .{ .name = "text.edit.case-lower" },
    .{ .name = "text.edit.case-title" },
    // The whole displayed line (linenoise's Ctrl+U).
    .{ .name = "text.delete.line", .repeat = true },
    .{ .name = "text.style.bold" },
    .{ .name = "text.style.italic" },
    .{ .name = "canvas.flow.edit-equation" },
    // 0 forward, 1 back.
    .{ .name = "canvas.flow.tab", .repeat = true, .param = .int },
    .{ .name = "canvas.flow.choose-case" },
    .{ .name = "canvas.flow.case-picker.pick", .param = .int },
    .{ .name = "canvas.flow.case-picker.previous", .param = .int },
    .{ .name = "canvas.flow.case-picker.cancel" },
    .{ .name = "canvas.flow.case-picker.take" },
    .{ .name = "canvas.flow.case-picker.move", .repeat = true, .param = .int },
    .{ .name = "canvas.flow.case-picker.back", .repeat = true },
    .{ .name = "canvas.flow.leave" },

    .{ .name = "canvas.equation.leave" },
    .{ .name = "canvas.equation.tab", .repeat = true, .param = .int },
    .{ .name = "canvas.equation.caret.left", .repeat = true },
    .{ .name = "canvas.equation.caret.right", .repeat = true },
    .{ .name = "canvas.equation.caret.start", .repeat = true },
    .{ .name = "canvas.equation.caret.end", .repeat = true },
    .{ .name = "canvas.equation.select.left", .repeat = true },
    .{ .name = "canvas.equation.select.right", .repeat = true },
    .{ .name = "canvas.equation.select.start", .repeat = true },
    .{ .name = "canvas.equation.select.end", .repeat = true },
    .{ .name = "canvas.equation.select.all" },
    .{ .name = "canvas.equation.copy" },
    .{ .name = "canvas.equation.cut" },
    .{ .name = "canvas.equation.paste" },
    .{ .name = "canvas.equation.delete-back", .repeat = true },
    .{ .name = "canvas.equation.delete-forward", .repeat = true },
    .{ .name = "canvas.equation.choose" },
    .{ .name = "canvas.equation.head.next", .repeat = true, .param = .int },
    .{ .name = "canvas.equation.head.out" },
    .{ .name = "canvas.equation.head.release" },
    .{ .name = "canvas.equation.head.nudge", .repeat = true, .param = .direction },
    .{ .name = "canvas.equation.head.scale-up" },
    .{ .name = "canvas.equation.head.scale-down" },
    .{ .name = "canvas.equation.head.turn-left" },
    .{ .name = "canvas.equation.head.turn-right" },
    .{ .name = "canvas.equation.head.reset" },
    .{ .name = "canvas.equation.head.slot-index" },
    .{ .name = "canvas.equation.head.slot-upper" },
    .{ .name = "canvas.equation.head.slot-lower" },
    .{ .name = "canvas.equation.head.limits" },

    .{ .name = "expression-line.tab", .repeat = true, .param = .int },
    .{ .name = "expression-line.completion.previous", .repeat = true },
    .{ .name = "expression-line.completion.next", .repeat = true },
    .{ .name = "expression-line.completion.accept", .repeat = true },
    .{ .name = "expression-line.completion.dismiss" },
    .{ .name = "expression-line.run.leave" },

    .{ .name = "panel-edit.cancel" },
    .{ .name = "panel-edit.remove-tile" },

    .{ .name = "sketch.tab", .repeat = true, .param = .int },
    .{ .name = "sketch.cancel", .repeat = true },
    .{ .name = "sketch.finish", .repeat = true },
    .{ .name = "sketch.delete", .repeat = true },
    .{ .name = "sketch.constraint.coincident", .repeat = true },
    .{ .name = "sketch.constraint.horizontal", .repeat = true },
    .{ .name = "sketch.constraint.vertical", .repeat = true },
    .{ .name = "sketch.constraint.point-on", .repeat = true },
    .{ .name = "sketch.constraint.tangent", .repeat = true },
    .{ .name = "sketch.constraint.perpendicular", .repeat = true },
    .{ .name = "sketch.constraint.equal", .repeat = true },
    .{ .name = "sketch.constraint.distance", .repeat = true },
    .{ .name = "sketch.constraint.radius", .repeat = true },
    .{ .name = "sketch.constraint.angle", .repeat = true },
    .{ .name = "sketch.constraint.lock", .repeat = true },
    .{ .name = "sketch.tool.next", .repeat = true },
    .{ .name = "sketch.ink", .repeat = true },
    .{ .name = "sketch.fill", .repeat = true },
    .{ .name = "sketch.caption" },
    .{ .name = "sketch.connect" },
    .{ .name = "sketch.summary.leave", .repeat = true },
    .{ .name = "sketch.summary.back", .repeat = true },

    // Two characters typed next stand for a third (digraphs.zig).
    .{ .name = "text.digraph" },
    .{ .name = "digraph.cancel" },
    .{ .name = "digraph.back" },
};

const left: i32 = @backingInt(Direction.left);
const right: i32 = @backingInt(Direction.right);
const up: i32 = @backingInt(Direction.up);
const down: i32 = @backingInt(Direction.down);

/// The four arrows, bound to `action` in `mode`.
fn arrows(comptime md: []const u8, comptime ac: []const u8) [4]B {
    return .{
        .{ .mode = md, .chord = "left", .action = ac, .arg = left },
        .{ .mode = md, .chord = "right", .action = ac, .arg = right },
        .{ .mode = md, .chord = "up", .action = ac, .arg = up },
        .{ .mode = md, .chord = "down", .action = ac, .arg = down },
    };
}

/// The four arrows with Shift, bound to `ac` in `md`.
fn shiftArrows(comptime md: []const u8, comptime ac: []const u8) [4]B {
    return .{
        .{ .mode = md, .chord = "shift+left", .action = ac, .arg = left },
        .{ .mode = md, .chord = "shift+right", .action = ac, .arg = right },
        .{ .mode = md, .chord = "shift+up", .action = ac, .arg = up },
        .{ .mode = md, .chord = "shift+down", .action = ac, .arg = down },
    };
}

/// Enter and the keypad's Enter.
fn enters(comptime md: []const u8, comptime ac: []const u8) [2]B {
    return .{
        .{ .mode = md, .chord = "enter", .action = ac },
        .{ .mode = md, .chord = "kp_enter", .action = ac },
    };
}

/// The motions of text (`layout.caret.Motion`, by its names), each with the
/// operators move and select; those that delete too.
const text_motions = [_][]const u8{
    "char-prev",      "char-next",      "word-prev",       "word-next",     "line-start", "line-end",
    "line-up",        "line-down",      "paragraph-prev",  "paragraph-next", "paragraph-start",
    "paragraph-end",  "flow-start",     "flow-end",        "style-prev",    "style-next",
};
const text_deletes = [_][]const u8{ "char-prev", "char-next", "word-prev", "word-next", "line-start", "line-end" };

/// Every text action that is an operator on a motion: `text.move.<motion>`,
/// `text.select.<motion>`, `text.delete.<motion>`.
fn textActions() [2 * text_motions.len + text_deletes.len]A {
    var out: [2 * text_motions.len + text_deletes.len]A = undefined;
    for (text_motions, 0..) |m, i| {
        out[2 * i] = .{ .name = "text.move." ++ m, .repeat = true };
        out[2 * i + 1] = .{ .name = "text.select." ++ m, .repeat = true };
    }
    for (text_deletes, 0..) |m, i| out[2 * text_motions.len + i] = .{ .name = "text.delete." ++ m, .repeat = true };
    return out;
}

/// A flow's caret movements, each from the toolkit's text-field binding
/// (so as the platform has them), with and without selecting.
fn flowMoves() [20]B {
    const pairs = [_][2][]const u8{
        .{ "char_left", "char-prev" },   .{ "char_right", "char-next" }, .{ "word_left", "word-prev" },
        .{ "word_right", "word-next" },  .{ "line_start", "line-start" }, .{ "line_end", "line-end" },
        .{ "text_start", "flow-start" }, .{ "text_end", "flow-end" },     .{ "char_up", "line-up" },
        .{ "char_down", "line-down" },
    };
    var out: [20]B = undefined;
    for (pairs, 0..) |p, i| {
        out[2 * i] = .{ .mode = "canvas.flow", .chord = "bind:" ++ p[0], .action = "text.move." ++ p[1] };
        out[2 * i + 1] = .{ .mode = "canvas.flow", .chord = "bind:" ++ p[0] ++ "_select", .action = "text.select." ++ p[1] };
    }
    return out;
}

pub const binds = [_]B{
    .{ .mode = "global", .chord = "primary+n", .action = "file.new" },
    .{ .mode = "global", .chord = "primary+shift+n", .action = "file.new-drawing" },
    .{ .mode = "global", .chord = "primary+tab", .action = "views.next", .arg = 0 },
    .{ .mode = "sheet", .chord = "up", .action = "sheet.move", .arg = 0 },
    .{ .mode = "sheet", .chord = "down", .action = "sheet.move", .arg = 1 },
    .{ .mode = "sheet", .chord = "right", .action = "sheet.move", .arg = 2 },
    .{ .mode = "sheet", .chord = "left", .action = "sheet.move", .arg = 3 },
    .{ .mode = "sheet", .chord = "tab", .action = "sheet.move", .arg = 2 },
    .{ .mode = "sheet", .chord = "shift+tab", .action = "sheet.move", .arg = 3 },
    .{ .mode = "sheet", .chord = "enter", .action = "sheet.edit" },
    .{ .mode = "sheet", .chord = "f2", .action = "sheet.edit" },
    .{ .mode = "sheet.edit", .chord = "up", .action = "sheet.move", .arg = 0 },
    .{ .mode = "sheet.edit", .chord = "down", .action = "sheet.move", .arg = 1 },
    .{ .mode = "sheet.edit", .chord = "enter", .action = "sheet.move", .arg = 1 },
    .{ .mode = "sheet.edit", .chord = "tab", .action = "sheet.move", .arg = 2 },
    .{ .mode = "sheet.edit", .chord = "shift+tab", .action = "sheet.move", .arg = 3 },
    .{ .mode = "sheet.edit", .chord = "escape", .action = "sheet.edit.leave" },
    .{ .mode = "global", .chord = "primary+shift+tab", .action = "views.next", .arg = 1 },
    .{ .mode = "global", .chord = "primary+o", .action = "file.open" },
    .{ .mode = "global", .chord = "primary+t", .action = "views.add" },
    .{ .mode = "global", .chord = "primary+e", .action = "views.add" },
    .{ .mode = "global", .chord = "primary+w", .action = "views.close" },
    .{ .mode = "global", .chord = "primary+shift+backslash", .action = "views.split-across" },
    .{ .mode = "global", .chord = "primary+s", .action = "file.save" },
    .{ .mode = "global", .chord = "primary+shift+s", .action = "file.save-as" },
    .{ .mode = "global", .chord = "primary+z", .action = "edit.undo" },
    .{ .mode = "global", .chord = "primary+shift+z", .action = "edit.redo" },
    .{ .mode = "global", .chord = "primary+y", .action = "edit.redo", .os = .not_mac },

    // As illustration and publishing apps have them; and unchorded where
    // nothing takes typed text.
    .{ .mode = "view", .chord = "primary+zero", .action = "view.zoom-fit" },
    .{ .mode = "view", .chord = "primary+alt+zero", .action = "view.zoom-all" },
    .{ .mode = "view", .chord = "primary+one", .action = "view.zoom-to", .arg = 100 },
    .{ .mode = "view", .chord = "primary+two", .action = "view.zoom-to", .arg = 200 },
    // By symbol: whichever keys type + = and - on the layout in use (on
    // German, + has a key of its own and = is Shift+0).
    .{ .mode = "view", .chord = "primary+'+'", .action = "view.zoom-in" },
    .{ .mode = "view", .chord = "primary+'='", .action = "view.zoom-in" },
    .{ .mode = "view", .chord = "primary+kp_add", .action = "view.zoom-in" },
    .{ .mode = "view", .chord = "primary+'-'", .action = "view.zoom-out" },
    .{ .mode = "view", .chord = "primary+kp_subtract", .action = "view.zoom-out" },
    .{ .mode = "view", .chord = "space", .action = "view.pan-hold" },
    .{ .mode = "view", .chord = "z", .action = "view.zoom-hold", .arg = 0 },
    .{ .mode = "view", .chord = "shift+z", .action = "view.zoom-hold", .arg = 1 },
    .{ .mode = "view", .chord = "primary+nine", .action = "view.frame-edit" },
    .{ .mode = "view", .chord = "nine", .action = "view.frame-edit" },
    .{ .mode = "view", .chord = "zero", .action = "view.zoom-fit" },
    .{ .mode = "view", .chord = "one", .action = "view.zoom-to", .arg = 100 },
    .{ .mode = "view", .chord = "two", .action = "view.zoom-to", .arg = 200 },
    .{ .mode = "view", .chord = "equal", .action = "view.zoom-in" },
    .{ .mode = "view", .chord = "shift+equal", .action = "view.zoom-in" },
    .{ .mode = "view", .chord = "kp_add", .action = "view.zoom-in" },
    .{ .mode = "view", .chord = "minus", .action = "view.zoom-out" },
    .{ .mode = "view", .chord = "kp_subtract", .action = "view.zoom-out" },
    // Inkscape's key for snapping.
    .{ .mode = "view", .chord = "char:%", .action = "view.snap-grid" },
    // U for ultraviolet: the next canvas theme (Light Table, Black Light Table).
    .{ .mode = "view", .chord = "u", .action = "view.canvas-theme", .arg = -1 },
    .{ .mode = "view", .chord = "c", .action = "fab.check" },
} ++ enters("dialog", "dialog.confirm") ++ [_]B{
    .{ .mode = "dialog", .chord = "escape", .action = "dialog.cancel" },
    // Vim's digraph key (RFC 1345's mnemonics), where text is typed.
    .{ .mode = "text-entry", .chord = "ctrl+k", .action = "text.digraph" },
    .{ .mode = "text-entry", .chord = "ctrl+shift+k", .action = "text.digraph" },
    .{ .mode = "digraph", .chord = "escape", .action = "digraph.cancel" },
    .{ .mode = "digraph", .chord = "backspace", .action = "digraph.back" },
    .{ .mode = "dialog.calibrate-size", .chord = "left", .action = "dialog.calibrate-size.grow", .arg = -1 },
    .{ .mode = "dialog.calibrate-size", .chord = "right", .action = "dialog.calibrate-size.grow", .arg = 1 },
    .{ .mode = "dialog.calibrate-size", .chord = "shift+left", .action = "dialog.calibrate-size.grow", .arg = -10 },
    .{ .mode = "dialog.calibrate-size", .chord = "shift+right", .action = "dialog.calibrate-size.grow", .arg = 10 },

    .{ .mode = "start", .chord = "m", .action = "start.new-canvas", .arg = 0 },
    .{ .mode = "start", .chord = "i", .action = "start.new-canvas", .arg = 1 },
    .{ .mode = "start", .chord = "o", .action = "start.open" },
    .{ .mode = "start", .chord = "s", .action = "start.new-drawing" },
    .{ .mode = "start", .chord = "d", .action = "start.display-correction" },
} ++ enters("start", "start.new-canvas-last") ++ recents() ++
    arrows("canvas", "canvas.object.nudge") ++ shiftArrows("canvas", "canvas.object.nudge-far") ++ [_]B{
    .{ .mode = "canvas", .chord = "delete", .action = "canvas.object.delete" },
    .{ .mode = "canvas", .chord = "primary+backslash", .action = "canvas.tile.edit-text" },
    // A level out and in: the keys < and > are on, Shift or not.
    .{ .mode = "canvas", .chord = "primary+comma", .action = "level.up" },
    .{ .mode = "canvas", .chord = "primary+shift+comma", .action = "level.up" },
    .{ .mode = "canvas", .chord = "primary+period", .action = "level.down" },
    .{ .mode = "canvas", .chord = "primary+shift+period", .action = "level.down" },
    .{ .mode = "canvas", .chord = "escape", .action = "canvas.tool.cancel" },
    // Select boundaries, on and off.
    .{ .mode = "canvas", .chord = "b", .action = "tool.select-boundaries" },
    // Construction line (a guide), on and off.
    .{ .mode = "canvas", .chord = "g", .action = "tool.construction-line" },
    // The ribbon's tools, a single key each (shown on their buttons).
    .{ .mode = "canvas", .chord = "p", .action = "tool.add-panel" },
    .{ .mode = "canvas", .chord = "i", .action = "tool.insert-figure" },
    .{ .mode = "canvas", .chord = "r", .action = "tool.layout-column-of-rows" },
    .{ .mode = "canvas", .chord = "shift+r", .action = "tool.layout-row-of-columns" },
    .{ .mode = "canvas", .chord = "t", .action = "tool.layout-single-track" },
    .{ .mode = "canvas", .chord = "s", .action = "tool.add-shape" },
    .{ .mode = "canvas", .chord = "a", .action = "tool.select-area" },
    .{ .mode = "canvas", .chord = "n", .action = "tool.new-sketch" },
    .{ .mode = "canvas", .chord = "k", .action = "tool.constrain" },
    .{ .mode = "canvas", .chord = "f", .action = "tool.fit-to-tiles" },
    .{ .mode = "canvas", .chord = "x", .action = "tool.add-array" },
    .{ .mode = "canvas", .chord = "l", .action = "ribbon.layers" },
    .{ .mode = "canvas", .chord = "y", .action = "ribbon.styles" },
    // A paged context's pages (none has pages yet).
    .{ .mode = "canvas", .chord = "page_up", .action = "views.page-prev", .arg = 0 },
    .{ .mode = "canvas", .chord = "page_down", .action = "views.page-next", .arg = 0 },
    .{ .mode = "canvas", .chord = "home", .action = "views.page-prev", .arg = 1 },
    .{ .mode = "canvas", .chord = "end", .action = "views.page-next", .arg = 1 },
} ++ enters("canvas", "canvas.tool.finish") ++ arrows("canvas.selection", "canvas.selection.nudge") ++ shiftArrows("canvas.selection", "canvas.selection.nudge-far") ++ [_]B{
    .{ .mode = "canvas.engage", .chord = "tab", .action = "canvas.engage.lock", .arg = 0 },
    .{ .mode = "canvas.engage", .chord = "shift+tab", .action = "canvas.engage.lock", .arg = 1 },
    .{ .mode = "canvas.engage", .chord = "escape", .action = "canvas.engage.release" },
    .{ .mode = "canvas.selection", .chord = "tab", .action = "canvas.selection.hunt", .arg = 0 },
    .{ .mode = "canvas.constrain-menu", .chord = "h", .action = "constrain-menu.horizontal" },
    .{ .mode = "canvas.constrain-menu", .chord = "v", .action = "constrain-menu.vertical" },
    .{ .mode = "canvas.constrain-menu", .chord = "d", .action = "constrain-menu.distance" },
    .{ .mode = "canvas.constrain-menu", .chord = "escape", .action = "constrain-menu.close" },
    .{ .mode = "canvas.constrain-objects", .chord = "w", .action = "constrain-objects.equal-width" },
    .{ .mode = "canvas.constrain-objects", .chord = "h", .action = "constrain-objects.equal-height" },
    .{ .mode = "canvas.constrain-objects", .chord = "g", .action = "constrain-objects.gap" },
    .{ .mode = "canvas.constrain-objects", .chord = "t", .action = "constrain-objects.top" },
    .{ .mode = "canvas.constrain-objects", .chord = "b", .action = "constrain-objects.bottom" },
    .{ .mode = "canvas.constrain-objects", .chord = "l", .action = "constrain-objects.left" },
    .{ .mode = "canvas.constrain-objects", .chord = "r", .action = "constrain-objects.right" },
    .{ .mode = "canvas.constrain-objects", .chord = "m", .action = "constrain-objects.measure" },
    .{ .mode = "canvas.constrain-objects", .chord = "escape", .action = "constrain-objects.close" },
    .{ .mode = "canvas.selection", .chord = "shift+tab", .action = "canvas.selection.hunt", .arg = 1 },
    .{ .mode = "canvas.selection", .chord = "escape", .action = "canvas.selection.clear" },
} ++ flowMoves() ++ [_]B{
    .{ .mode = "canvas.flow", .chord = "bind:copy", .action = "text.edit.copy" },
    .{ .mode = "canvas.flow", .chord = "bind:cut", .action = "text.edit.cut" },
    .{ .mode = "canvas.flow", .chord = "bind:paste", .action = "text.edit.paste" },
    .{ .mode = "canvas.flow", .chord = "primary+shift+v", .action = "text.edit.paste-plain" },
    // Ctrl+A is linenoise's line start in text (Travis, 2026-11-24): select
    // all is Cmd+A on a Mac, Ctrl+Shift+A elsewhere.
    .{ .mode = "canvas.flow", .chord = "bind:select_all", .action = "text.select.all", .os = .mac },
    .{ .mode = "canvas.flow", .chord = "ctrl+shift+a", .action = "text.select.all", .os = .not_mac },
    .{ .mode = "canvas.flow", .chord = "primary+backslash", .action = "canvas.flow.edit-equation" },
    .{ .mode = "canvas.flow", .chord = "tab", .action = "canvas.flow.tab", .arg = 0 },
    .{ .mode = "canvas.flow", .chord = "shift+tab", .action = "canvas.flow.tab", .arg = 1 },
    .{ .mode = "canvas.flow", .chord = "enter", .action = "text.edit.new-paragraph" },
    .{ .mode = "canvas.flow", .chord = "kp_enter", .action = "text.edit.new-paragraph" },
    .{ .mode = "canvas.flow", .chord = "shift+enter", .action = "text.edit.new-line" },
    .{ .mode = "canvas.flow", .chord = "shift+kp_enter", .action = "text.edit.new-line" },
    .{ .mode = "canvas.flow", .chord = "backspace", .action = "text.delete.char-prev" },
    // Words, and to the line's start or end: Ctrl (Alt and Cmd on a Mac).
    .{ .mode = "canvas.flow", .chord = "ctrl+backspace", .action = "text.delete.word-prev", .os = .not_mac },
    .{ .mode = "canvas.flow", .chord = "ctrl+delete", .action = "text.delete.word-next", .os = .not_mac },
    .{ .mode = "canvas.flow", .chord = "ctrl+shift+backspace", .action = "text.delete.line-start", .os = .not_mac },
    .{ .mode = "canvas.flow", .chord = "ctrl+shift+delete", .action = "text.delete.line-end", .os = .not_mac },
    .{ .mode = "canvas.flow", .chord = "alt+backspace", .action = "text.delete.word-prev", .os = .mac },
    .{ .mode = "canvas.flow", .chord = "alt+delete", .action = "text.delete.word-next", .os = .mac },
    .{ .mode = "canvas.flow", .chord = "cmd+backspace", .action = "text.delete.line-start", .os = .mac },
    .{ .mode = "canvas.flow", .chord = "cmd+delete", .action = "text.delete.line-end", .os = .mac },
    // Paragraphs: Ctrl+Up and Down (Alt on a Mac); a change of character
    // style: Alt+Left and Right (Ctrl+Alt on a Mac). Shift selects.
    .{ .mode = "canvas.flow", .chord = "ctrl+up", .action = "text.move.paragraph-prev", .os = .not_mac },
    .{ .mode = "canvas.flow", .chord = "ctrl+down", .action = "text.move.paragraph-next", .os = .not_mac },
    .{ .mode = "canvas.flow", .chord = "ctrl+shift+up", .action = "text.select.paragraph-prev", .os = .not_mac },
    .{ .mode = "canvas.flow", .chord = "ctrl+shift+down", .action = "text.select.paragraph-next", .os = .not_mac },
    .{ .mode = "canvas.flow", .chord = "alt+up", .action = "text.move.paragraph-prev", .os = .mac },
    .{ .mode = "canvas.flow", .chord = "alt+down", .action = "text.move.paragraph-next", .os = .mac },
    .{ .mode = "canvas.flow", .chord = "alt+shift+up", .action = "text.select.paragraph-prev", .os = .mac },
    .{ .mode = "canvas.flow", .chord = "alt+shift+down", .action = "text.select.paragraph-next", .os = .mac },
    .{ .mode = "canvas.flow", .chord = "alt+left", .action = "text.move.style-prev", .os = .not_mac },
    .{ .mode = "canvas.flow", .chord = "alt+right", .action = "text.move.style-next", .os = .not_mac },
    .{ .mode = "canvas.flow", .chord = "alt+shift+left", .action = "text.select.style-prev", .os = .not_mac },
    .{ .mode = "canvas.flow", .chord = "alt+shift+right", .action = "text.select.style-next", .os = .not_mac },
    .{ .mode = "canvas.flow", .chord = "ctrl+alt+left", .action = "text.move.style-prev", .os = .mac },
    .{ .mode = "canvas.flow", .chord = "ctrl+alt+right", .action = "text.move.style-next", .os = .mac },
    .{ .mode = "canvas.flow", .chord = "ctrl+alt+shift+left", .action = "text.select.style-prev", .os = .mac },
    .{ .mode = "canvas.flow", .chord = "ctrl+alt+shift+right", .action = "text.select.style-next", .os = .mac },
    // Bold and italic on the selection, or for what is typed next (Ctrl+B
    // was linenoise's character back: the Left arrow does that).
    .{ .mode = "canvas.flow", .chord = "primary+b", .action = "text.style.bold" },
    .{ .mode = "canvas.flow", .chord = "primary+i", .action = "text.style.italic" },
    .{ .mode = "canvas.flow", .chord = "delete", .action = "text.delete.char-next" },
    .{ .mode = "canvas.flow", .chord = "escape", .action = "canvas.flow.leave" },
    // linenoise's (readline's) keys, with Ctrl on every system; in text
    // they win over Graven's own (Travis, 2026-11-24): new file, new and
    // closed views work outside text, and the digraph key is Ctrl+Shift+K.
    .{ .mode = "canvas.flow", .chord = "ctrl+a", .action = "text.move.line-start" },
    .{ .mode = "canvas.flow", .chord = "ctrl+e", .action = "text.move.line-end" },
    .{ .mode = "canvas.flow", .chord = "ctrl+n", .action = "text.move.line-down" },
    .{ .mode = "canvas.flow", .chord = "ctrl+k", .action = "text.delete.line-end" },
    .{ .mode = "canvas.flow", .chord = "ctrl+t", .action = "text.edit.transpose" },
    // Cases of sorts: Ctrl+Space, then type part of a name, a digit (by
    // position: the number row's keys, whatever the layout types there) for a
    // row (0: the first), Enter for the highlighted one, Space for the case
    // before, or Esc.
    .{ .mode = "canvas.flow", .chord = "ctrl+space", .action = "canvas.flow.choose-case" },
    .{ .mode = "canvas.flow.case-picker", .chord = "ctrl+space", .action = "canvas.flow.case-picker.previous" },
    .{ .mode = "canvas.flow.case-picker", .chord = "char: ", .action = "canvas.flow.case-picker.previous", .arg = 1 },
    .{ .mode = "canvas.flow.case-picker", .chord = "enter", .action = "canvas.flow.case-picker.take" },
    .{ .mode = "canvas.flow.case-picker", .chord = "kp_enter", .action = "canvas.flow.case-picker.take" },
    .{ .mode = "canvas.flow.case-picker", .chord = "up", .action = "canvas.flow.case-picker.move", .arg = -1 },
    .{ .mode = "canvas.flow.case-picker", .chord = "down", .action = "canvas.flow.case-picker.move", .arg = 1 },
    .{ .mode = "canvas.flow.case-picker", .chord = "backspace", .action = "canvas.flow.case-picker.back" },
    .{ .mode = "canvas.flow.case-picker", .chord = "escape", .action = "canvas.flow.case-picker.cancel" },
    .{ .mode = "canvas.flow.case-picker", .chord = "@E10", .action = "canvas.flow.case-picker.pick", .arg = 0 },
    .{ .mode = "canvas.flow.case-picker", .chord = "@E01", .action = "canvas.flow.case-picker.pick", .arg = 1 },
    .{ .mode = "canvas.flow.case-picker", .chord = "@E02", .action = "canvas.flow.case-picker.pick", .arg = 2 },
    .{ .mode = "canvas.flow.case-picker", .chord = "@E03", .action = "canvas.flow.case-picker.pick", .arg = 3 },
    .{ .mode = "canvas.flow.case-picker", .chord = "@E04", .action = "canvas.flow.case-picker.pick", .arg = 4 },
    .{ .mode = "canvas.flow.case-picker", .chord = "@E05", .action = "canvas.flow.case-picker.pick", .arg = 5 },
    .{ .mode = "canvas.flow.case-picker", .chord = "@E06", .action = "canvas.flow.case-picker.pick", .arg = 6 },
    .{ .mode = "canvas.flow.case-picker", .chord = "@E07", .action = "canvas.flow.case-picker.pick", .arg = 7 },
    .{ .mode = "canvas.flow.case-picker", .chord = "@E08", .action = "canvas.flow.case-picker.pick", .arg = 8 },
    .{ .mode = "canvas.flow.case-picker", .chord = "@E09", .action = "canvas.flow.case-picker.pick", .arg = 9 },
    .{ .mode = "canvas.flow", .chord = "ctrl+w", .action = "text.delete.word-prev" },
    .{ .mode = "canvas.flow", .chord = "ctrl+f", .action = "text.move.char-next" },
    .{ .mode = "canvas.flow", .chord = "ctrl+p", .action = "text.move.line-up" },
    .{ .mode = "canvas.flow", .chord = "ctrl+d", .action = "text.delete.char-next" },
    .{ .mode = "canvas.flow", .chord = "ctrl+h", .action = "text.delete.char-prev" },
    .{ .mode = "canvas.flow", .chord = "ctrl+u", .action = "text.delete.line" },

    .{ .mode = "canvas.equation", .chord = "primary+backslash", .action = "canvas.equation.leave" },
    .{ .mode = "canvas.equation", .chord = "escape", .action = "canvas.equation.leave" },
} ++ enters("canvas.equation", "canvas.equation.leave") ++ [_]B{
    .{ .mode = "canvas.equation", .chord = "tab", .action = "canvas.equation.tab", .arg = 0 },
    .{ .mode = "canvas.equation", .chord = "shift+tab", .action = "canvas.equation.tab", .arg = 1 },
    .{ .mode = "canvas.equation", .chord = "up", .action = "canvas.equation.choose" },
    .{ .mode = "canvas.equation", .chord = "left", .action = "canvas.equation.caret.left" },
    .{ .mode = "canvas.equation", .chord = "right", .action = "canvas.equation.caret.right" },
    .{ .mode = "canvas.equation", .chord = "home", .action = "canvas.equation.caret.start" },
    .{ .mode = "canvas.equation", .chord = "end", .action = "canvas.equation.caret.end" },
    .{ .mode = "canvas.equation", .chord = "shift+left", .action = "canvas.equation.select.left" },
    .{ .mode = "canvas.equation", .chord = "shift+right", .action = "canvas.equation.select.right" },
    .{ .mode = "canvas.equation", .chord = "shift+home", .action = "canvas.equation.select.start" },
    .{ .mode = "canvas.equation", .chord = "shift+end", .action = "canvas.equation.select.end" },
    .{ .mode = "canvas.equation", .chord = "bind:copy", .action = "canvas.equation.copy" },
    .{ .mode = "canvas.equation", .chord = "bind:cut", .action = "canvas.equation.cut" },
    .{ .mode = "canvas.equation", .chord = "bind:paste", .action = "canvas.equation.paste" },
    .{ .mode = "canvas.equation", .chord = "bind:select_all", .action = "canvas.equation.select.all", .os = .mac },
    .{ .mode = "canvas.equation", .chord = "ctrl+shift+a", .action = "canvas.equation.select.all", .os = .not_mac },
    .{ .mode = "canvas.equation", .chord = "backspace", .action = "canvas.equation.delete-back" },
    .{ .mode = "canvas.equation", .chord = "delete", .action = "canvas.equation.delete-forward" },
} ++ arrows("canvas.equation.head", "canvas.equation.head.nudge") ++ [_]B{
    .{ .mode = "canvas.equation.head", .chord = "tab", .action = "canvas.equation.head.next", .arg = 0 },
    .{ .mode = "canvas.equation.head", .chord = "shift+tab", .action = "canvas.equation.head.next", .arg = 1 },
    .{ .mode = "canvas.equation.head", .chord = "char:o", .action = "canvas.equation.head.out" },
    .{ .mode = "canvas.equation.head", .chord = "escape", .action = "canvas.equation.head.release" },
    .{ .mode = "canvas.equation.head", .chord = "char:=", .action = "canvas.equation.head.scale-up" },
    .{ .mode = "canvas.equation.head", .chord = "char:+", .action = "canvas.equation.head.scale-up" },
    .{ .mode = "canvas.equation.head", .chord = "char:-", .action = "canvas.equation.head.scale-down" },
    .{ .mode = "canvas.equation.head", .chord = "char:[", .action = "canvas.equation.head.turn-left" },
    .{ .mode = "canvas.equation.head", .chord = "char:]", .action = "canvas.equation.head.turn-right" },
    .{ .mode = "canvas.equation.head", .chord = "char:0", .action = "canvas.equation.head.reset" },
    .{ .mode = "canvas.equation.head", .chord = "char:i", .action = "canvas.equation.head.slot-index" },
    .{ .mode = "canvas.equation.head", .chord = "char:u", .action = "canvas.equation.head.slot-upper" },
    .{ .mode = "canvas.equation.head", .chord = "char:b", .action = "canvas.equation.head.slot-lower" },
    .{ .mode = "canvas.equation.head", .chord = "char:l", .action = "canvas.equation.head.limits" },

    .{ .mode = "expression-line", .chord = "tab", .action = "expression-line.tab", .arg = 0 },
    .{ .mode = "expression-line", .chord = "shift+tab", .action = "expression-line.tab", .arg = 1 },
    .{ .mode = "expression-line.completion", .chord = "up", .action = "expression-line.completion.previous" },
    .{ .mode = "expression-line.completion", .chord = "down", .action = "expression-line.completion.next" },
    .{ .mode = "expression-line.completion", .chord = "tab", .action = "expression-line.completion.accept" },
    .{ .mode = "expression-line.completion", .chord = "escape", .action = "expression-line.completion.dismiss" },
} ++ enters("expression-line.completion", "expression-line.completion.accept") ++ enters("expression-line.run", "expression-line.run.leave") ++ [_]B{
    .{ .mode = "expression-line.run", .chord = "escape", .action = "expression-line.run.leave" },
    .{ .mode = "expression-line.run", .chord = "primary+backslash", .action = "expression-line.run.leave" },

    .{ .mode = "panel-edit", .chord = "escape", .action = "panel-edit.cancel" },
    .{ .mode = "panel-edit", .chord = "delete", .action = "panel-edit.remove-tile" },
    .{ .mode = "panel-edit", .chord = "backspace", .action = "panel-edit.remove-tile" },

    .{ .mode = "sketch", .chord = "tab", .action = "sketch.tab", .arg = 0 },
    .{ .mode = "sketch", .chord = "shift+tab", .action = "sketch.tab", .arg = 1 },
    .{ .mode = "sketch", .chord = "escape", .action = "sketch.cancel" },
} ++ enters("sketch", "sketch.finish") ++ [_]B{
    .{ .mode = "sketch", .chord = "delete", .action = "sketch.delete" },
    .{ .mode = "sketch", .chord = "backspace", .action = "sketch.delete" },
    .{ .mode = "sketch", .chord = "c", .action = "sketch.constraint.coincident" },
    .{ .mode = "sketch", .chord = "h", .action = "sketch.constraint.horizontal" },
    .{ .mode = "sketch", .chord = "v", .action = "sketch.constraint.vertical" },
    .{ .mode = "sketch", .chord = "o", .action = "sketch.constraint.point-on" },
    .{ .mode = "sketch", .chord = "t", .action = "sketch.constraint.tangent" },
    .{ .mode = "sketch", .chord = "p", .action = "sketch.constraint.perpendicular" },
    .{ .mode = "sketch", .chord = "e", .action = "sketch.constraint.equal" },
    .{ .mode = "sketch", .chord = "d", .action = "sketch.constraint.distance" },
    .{ .mode = "sketch", .chord = "r", .action = "sketch.constraint.radius" },
    .{ .mode = "sketch", .chord = "a", .action = "sketch.constraint.angle" },
    .{ .mode = "sketch", .chord = "l", .action = "sketch.constraint.lock" },
    .{ .mode = "sketch", .chord = "m", .action = "sketch.tool.next" },
    .{ .mode = "sketch", .chord = "u", .action = "sketch.end.update" },
    .{ .mode = "sketch", .chord = "x", .action = "sketch.end.discard" },
    .{ .mode = "sketch", .chord = "w", .action = "sketch.show.ink-only" },
    .{ .mode = "sketch", .chord = "i", .action = "sketch.ink" },
    .{ .mode = "sketch", .chord = "f", .action = "sketch.fill" },
    .{ .mode = "sketch", .chord = "n", .action = "sketch.caption" },
    .{ .mode = "sketch", .chord = "j", .action = "sketch.connect" },
} ++ enters("sketch.summary", "sketch.summary.leave") ++ [_]B{
    .{ .mode = "sketch.summary", .chord = "escape", .action = "sketch.summary.back" },
};

/// 1 to 9: the recent files on the start screen.
fn recents() [9]B {
    const keys = [_][]const u8{ "one", "two", "three", "four", "five", "six", "seven", "eight", "nine" };
    var out: [9]B = undefined;
    for (keys, 0..) |k, i| out[i] = .{ .mode = "start", .chord = k, .action = "start.open-recent", .arg = @intCast(i) };
    return out;
}

/// The hand-written actions, then every button's (elements.zig) that is
/// not among them: a button is a virtual key for its action.
const all_action_defs = blk: {
    @setEvalBranchQuota(10_000_000);
    var out: []const A = &action_defs;
    for (elements.button_actions) |name| {
        for (action_defs) |d| {
            if (std.mem.eql(u8, d.name, name)) break;
        } else out = out ++ [_]A{.{ .name = name }};
    }
    const fixed = out[0..out.len].*;
    break :blk fixed;
};

pub const R = actions.Registry(dvui.enums.Key, platform.is_macos, &modes, &all_action_defs, &binds);

pub const ActionId = R.ActionId;
pub const ModeId = R.ModeId;

/// The action named `name` (checked when built).
/// Whether action `a`'s name is `prefix` or under it.
pub fn actionUnder(a: ActionId, prefix: []const u8) bool {
    return actions.under(R.actionName(a), prefix);
}

pub fn act(comptime name: []const u8) ActionId {
    return comptime R.action(name);
}

/// The mode named `name` (checked when built).
pub fn mode(comptime name: []const u8) ModeId {
    return comptime R.mode(name);
}

/// An action as a key asked for it.
pub const Invocation = struct {
    action: ActionId,
    arg: i32,
    /// By a key with Ctrl, Alt or Cmd (not one that types).
    chorded: bool = true,

    pub fn dir(inv: Invocation) Direction {
        return @fromBackingInt(@intCast(inv.arg));
    }
};

// The modes active now -------------------------------------------------------

var stack_buf: [8]ModeId = undefined;
var stack_len: usize = 0;

/// Sets the modes active now, outermost first (the GUI works it out from
/// its state each frame).
pub fn setStack(s: []const ModeId) void {
    stack_len = @min(s.len, stack_buf.len);
    @memcpy(stack_buf[0..stack_len], s[0..stack_len]);
}

pub fn stack() []const ModeId {
    return stack_buf[0..stack_len];
}

/// Whether a mode inside `m` in the stack takes typed text: then `m`'s
/// unchorded printable keys type instead.
fn maskedByText(m: ModeId) bool {
    const s = stack();
    const at = std.mem.indexOfScalar(ModeId, s, m) orelse return false;
    for (s[at + 1 ..]) |inner| if (R.modeDef(inner).takes_text) return true;
    return false;
}

pub fn printable(k: dvui.enums.Key) bool {
    const i = @backingInt(k);
    return (i >= @backingInt(dvui.enums.Key.a) and i <= @backingInt(dvui.enums.Key.nine)) or
        (i >= @backingInt(dvui.enums.Key.space) and i <= @backingInt(dvui.enums.Key.grave)) or
        (i >= @backingInt(dvui.enums.Key.kp_divide) and i <= @backingInt(dvui.enums.Key.kp_equal));
}

/// The modifiers of key event `k`, or held now: a modifier pressed before
/// the window had the keyboard (or reported only as a change, as Wayland
/// may) is missing from the event, and SDL keeps the live state.
fn modsOf(k: dvui.Event.Key) actions.Mods {
    var m: actions.Mods = .{ .ctrl = k.mod.control(), .shift = k.mod.shift(), .alt = k.mod.alt(), .cmd = k.mod.command() };
    if (dvui.backend.kind == .sdl3) {
        const c = dvui.backend.c;
        const live = c.SDL_GetModState();
        if (live & c.SDL_KMOD_CTRL != 0) m.ctrl = true;
        if (live & c.SDL_KMOD_GUI != 0) m.cmd = true;
    }
    return m;
}

// The keyboard: positions and the layout in use --------------------------

/// What each key types on the layout in use (US English until the system
/// says; under the testing backend, always). Bindings by symbol and cases
/// of sorts resolve keys through it.
pub var layout: kb.Layout = kb.us;
var layout_stale = true;
var watching = false;

/// Each key event's SDL scancode, as SDL queued it: taken off in order as
/// the same events reach DVUI (`assignScancodes`), which carry no
/// scancode of their own.
const Queued = struct { hid: u16, key: i32 };
var queued: [64]Queued = undefined;
var queued_head: usize = 0;
var queued_len: usize = 0;

/// DVUI's key events this frame, by event number (numbered afresh each
/// frame), with the position each came from.
const Placed = struct { num: u16, pos: ?kb.Position };
var placed: [64]Placed = undefined;
var placed_len: usize = 0;

fn watch(_: ?*anyopaque, ev: [*c]dvui.backend.c.SDL_Event) callconv(.c) bool {
    const c = dvui.backend.c;
    const e = ev.*;
    switch (e.type) {
        c.SDL_EVENT_KEYMAP_CHANGED => layout_stale = true,
        c.SDL_EVENT_KEY_DOWN, c.SDL_EVENT_KEY_UP => {
            if (queued_len == queued.len) {
                queued_head = (queued_head + 1) % queued.len;
                queued_len -= 1;
            }
            queued[(queued_head + queued_len) % queued.len] = .{ .hid = @intCast(e.key.scancode), .key = @intCast(e.key.key) };
            queued_len += 1;
        },
        else => {},
    }
    return true;
}

/// At the start of a frame: watches SDL's events (once), reads the layout
/// again if it changed, and gives this frame's key events their positions.
pub fn beginFrame() void {
    if (dvui.backend.kind != .sdl3) return;
    const c = dvui.backend.c;
    if (!watching) {
        watching = c.SDL_AddEventWatch(watch, null);
    }
    if (layout_stale) {
        layout_stale = false;
        readLayout();
    }
    assignScancodes();
}

/// The layout from SDL: what each position types, without and with Shift.
fn readLayout() void {
    const c = dvui.backend.c;
    var l: kb.Layout = .{};
    for (kb.grid, 0..) |g, i| {
        l.lower[i] = symOf(c.SDL_GetKeyFromScancode(g.hid, c.SDL_KMOD_NONE, false));
        l.upper[i] = symOf(c.SDL_GetKeyFromScancode(g.hid, c.SDL_KMOD_SHIFT, false));
    }
    layout = l;
    if (log) {
        std.debug.print("keys: layout", .{});
        for (kb.grid, 0..) |g, i| std.debug.print(" {s}={s}{s}", .{ &g.pos.name(), layout.lower[i].slice(), layout.upper[i].slice() });
        std.debug.print("\n", .{});
    }
}

fn symOf(key: u32) kb.Sym {
    const c = dvui.backend.c;
    if (key & c.SDLK_SCANCODE_MASK != 0 or key < 0x20 or key == 0x7f or key > 0x10ffff) return .{};
    return .ofCodepoint(@intCast(key));
}

fn assignScancodes() void {
    placed_len = 0;
    for (dvui.events()) |*e| {
        const k = switch (e.evt) {
            .key => |k| k,
            else => continue,
        };
        // The next queued key event that DVUI makes this key of (others,
        // for another window, are dropped).
        var pos: ?kb.Position = null;
        while (queued_len > 0) {
            const q = queued[queued_head];
            queued_head = (queued_head + 1) % queued.len;
            queued_len -= 1;
            if (dvui.backend.SDL_keysym_to_dvui(q.key) == k.code) {
                pos = kb.atHid(q.hid);
                break;
            }
        }
        if (placed_len == placed.len) continue;
        placed[placed_len] = .{ .num = e.num, .pos = pos };
        placed_len += 1;
    }
}

fn placedAt(num: u16) ?*Placed {
    for (placed[0..placed_len]) |*p| if (p.num == num) return p;
    return null;
}

/// Where key event `e` came from on the keyboard: from SDL's scancode, or
/// (under the testing backend, or when it is not known) the US position
/// of its key.
pub fn positionOf(e: *const dvui.Event, k: dvui.Event.Key) ?kb.Position {
    if (placedAt(e.num)) |p| if (p.pos) |pos| return pos;
    return usPosition(k.code);
}

fn usPosition(code: dvui.enums.Key) ?kb.Position {
    const name: []const u8 = switch (code) {
        .zero => "0",
        .one => "1",
        .two => "2",
        .three => "3",
        .four => "4",
        .five => "5",
        .six => "6",
        .seven => "7",
        .eight => "8",
        .nine => "9",
        .equal => "=",
        .minus => "-",
        .left_bracket => "[",
        .right_bracket => "]",
        .backslash => "\\",
        .semicolon => ";",
        .apostrophe => "'",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .grave => "`",
        .space => " ",
        else => blk: {
            const t = @tagName(code);
            break :blk if (t.len == 1) t else return null;
        },
    };
    return (kb.us.find(name) orelse return null).pos;
}

/// Whether key event `e` (modifiers `mods`) is the key of `chord` by
/// position or symbol, with its modifiers.
fn hitsKey(e: *const dvui.Event, k: dvui.Event.Key, mods: actions.Mods, chord: R.KeyChord) bool {
    switch (chord.what) {
        .pos => |p| return chord.mods.eql(mods) and (positionOf(e, k) orelse return false).eql(p),
        .sym => |s| {
            const at = layout.find(s) orelse return false;
            var want = chord.mods;
            if (at.shift) want.shift = true;
            return want.eql(mods) and (positionOf(e, k) orelse return false).eql(at.pos);
        },
        else => return false,
    }
}

/// The action event `e` asks for in `in` (innermost first): the first
/// binding that matches, in the first mode that has one. A key down, or a
/// repeat for an action that repeats; a typed character for a `char:`
/// binding. Null: none (the event is left alone).
pub fn match(e: *const dvui.Event, in: []const ModeId) ?Invocation {
    if (e.handled) return null;
    switch (e.evt) {
        .key => |k| {
            if (k.action == .up) return null;
            const mods = modsOf(k);
            for (in) |m| {
                const masked = maskedByText(m);
                for (R.tables[m]) |b| {
                    if (k.action == .repeat and !R.def(b.action).repeat) continue;
                    const hit = switch (b.chord.what) {
                        .code => |code| code == k.code and b.chord.mods.eql(mods) and
                            !(masked and !b.chord.mods.chorded() and printable(code)),
                        .pos, .sym => hitsKey(e, k, mods, b.chord) and
                            !(masked and !b.chord.mods.chorded() and printable(k.code)),
                        .bind => |name| k.matchBind(name),
                        .char => false,
                    };
                    if (hit) return logged(.{ .action = b.action, .arg = b.arg, .chorded = switch (b.chord.what) {
                        .code, .pos, .sym => b.chord.mods.chorded(),
                        else => true,
                    } }, m);
                }
            }
            return null;
        },
        .text => |t| {
            const txt = switch (t.action) {
                .value => |v| v.txt,
                else => return null,
            };
            for (in) |m| {
                if (maskedByText(m)) continue;
                for (R.tables[m]) |b| switch (b.chord.what) {
                    .char => |ch| if (std.mem.eql(u8, ch, txt)) return logged(.{ .action = b.action, .arg = b.arg, .chorded = false }, m),
                    else => {},
                };
            }
            return null;
        },
        else => return null,
    }
}

/// Whether a mode inside `m` in the stack binds event `e`: then the inner
/// mode's meaning wins (Ctrl+E is line end in text, a new view outside).
pub fn shadowed(e: *const dvui.Event, m: ModeId) bool {
    const s = stack();
    const at = std.mem.indexOfScalar(ModeId, s, m) orelse return false;
    var k = s.len;
    while (k > at + 1) {
        k -= 1;
        const was = log;
        log = false;
        defer log = was;
        if (match(e, s[k .. k + 1]) != null) return true;
    }
    return false;
}

/// Whether a mode in the stack that takes typed text, other than `m`, binds
/// event `e`: the text's own editor's keys win over a generic text mode's
/// (Ctrl+K kills to the line's end in a flow, starts a digraph elsewhere).
pub fn takenByEditor(e: *const dvui.Event, m: ModeId) bool {
    for (stack()) |o| {
        if (o == m or !R.modeDef(o).takes_text) continue;
        const was = log;
        log = false;
        defer log = was;
        if (match(e, &.{o}) != null) return true;
    }
    return false;
}

/// GRAVEN_KEY_LOG: each action a key asks for, printed with the modes
/// active.
pub var log = false;

fn logged(inv: Invocation, m: ModeId) Invocation {
    if (log) {
        std.debug.print("key: {s}({d}) in {s} [", .{ R.actionName(inv.action), inv.arg, R.modeName(m) });
        for (stack(), 0..) |s, i| std.debug.print("{s}{s}", .{ if (i > 0) " > " else "", R.modeName(s) });
        std.debug.print("]\n", .{});
    }
    return inv;
}

/// For a key released (event `e`): the action its key is bound to in mode
/// `m` (whatever the modifiers now), for actions held down (`view.pan-hold`).
pub fn released(e: *const dvui.Event, m: ModeId) ?ActionId {
    if (e.handled) return null;
    const k = switch (e.evt) {
        .key => |k| k,
        else => return null,
    };
    if (k.action != .up) return null;
    for (R.tables[m]) |b| switch (b.chord.what) {
        .code => |code| if (code == k.code) return b.action,
        .pos => |p| if (positionOf(e, k)) |at| if (at.eql(p)) return b.action,
        .sym => |sym| if (layout.find(sym)) |f| if (positionOf(e, k)) |at| if (at.eql(f.pos)) return b.action,
        else => {},
    };
    return null;
}

/// `match` in one mode.
pub fn match1(e: *const dvui.Event, m: ModeId) ?Invocation {
    return match(e, &.{m});
}

// Shortcuts shown ---------------------------------------------------------

/// The key that does `a` (with argument `arg`) in mode `m`, as a menu
/// shows it ("Ctrl+Shift+S"): the first chorded binding, else the first;
/// null when none. `bind:` chords are the toolkit's and not shown.
pub fn shortcut(buf: []u8, m: ModeId, a: ActionId, arg: i32) ?[]const u8 {
    return shortcutPreferring(buf, m, a, arg, true);
}

/// As `shortcut`, preferring a chorded key (`chorded`: one that works
/// while a field has the keyboard, for menus) or a single key (for the
/// ribbon's keys, which show the single-key commands).
pub fn shortcutPreferring(buf: []u8, m: ModeId, a: ActionId, arg: i32, chorded: bool) ?[]const u8 {
    var best: ?R.Binding = null;
    for (R.tables[m]) |b| {
        if (b.action != a or b.arg != arg or b.chord.what == .bind) continue;
        if (best == null or (best.?.chord.mods.chorded() != chorded and b.chord.mods.chorded() == chorded)) best = b;
    }
    const b = best orelse return null;
    var w: std.Io.Writer = .fixed(buf);
    const kn = platform.key_names;
    if (b.chord.mods.ctrl) w.writeAll(kn.ctrl) catch return null;
    if (b.chord.mods.cmd) w.writeAll(kn.cmd) catch return null;
    if (b.chord.mods.alt) w.writeAll(kn.alt) catch return null;
    if (b.chord.mods.shift) w.writeAll(kn.shift) catch return null;
    switch (b.chord.what) {
        .char, .sym => |c| w.writeAll(c) catch return null,
        .code => |k| w.writeAll(keyName(k)) catch return null,
        .pos => |p| {
            // What the key types here, a letter as its capital.
            const t = layout.typed(p, false);
            if (t.len == 1 and std.ascii.isLower(t[0])) w.writeByte(std.ascii.toUpper(t[0])) catch return null else if (t.len > 0) w.writeAll(t) catch return null else w.writeAll(&p.name()) catch return null;
        },
        .bind => unreachable,
    }
    return w.buffered();
}

/// A key's name as shown.
pub fn keyName(k: dvui.enums.Key) []const u8 {
    return switch (k) {
        inline .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z => |c| comptime upper(@tagName(c)),
        .zero => "0",
        .one => "1",
        .two => "2",
        .three => "3",
        .four => "4",
        .five => "5",
        .six => "6",
        .seven => "7",
        .eight => "8",
        .nine => "9",
        .equal => "=",
        .minus => "-",
        .left_bracket => "[",
        .right_bracket => "]",
        .backslash => "\\",
        .semicolon => ";",
        .apostrophe => "'",
        .comma => ",",
        .period => ".",
        .slash => "/",
        .grave => "`",
        .kp_add => "Num +",
        .kp_subtract => "Num -",
        .kp_enter => "Num Enter",
        .enter => "Enter",
        .escape => "Esc",
        .tab => "Tab",
        .space => "Space",
        .delete => "Del",
        .backspace => "Backspace",
        .home => "Home",
        .end => "End",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .left => "Left",
        .right => "Right",
        .up => "Up",
        .down => "Down",
        else => @tagName(k),
    };
}

fn upper(comptime s: []const u8) []const u8 {
    comptime {
        var out: [s.len]u8 = undefined;
        for (s, 0..) |c, i| out[i] = std.ascii.toUpper(c);
        const final = out;
        return &final;
    }
}
