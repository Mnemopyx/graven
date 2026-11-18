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
const builtin = @import("builtin");
const dvui = @import("dvui");
const actions = @import("actions.zig");

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
    .{ .name = "view", .kind = .minor, .parent = "global", .allows = &.{"view"} },
    // No document yet.
    .{ .name = "start", .kind = .major, .parent = "global", .allows = &.{"start"} },
    // The canvas, and what nests in it.
    .{ .name = "canvas", .kind = .major, .parent = "global", .allows = &.{ "canvas.object", "canvas.tile", "canvas.tool" } },
    // Engagement points near the pointer (or one locked onto).
    .{ .name = "canvas.engage", .kind = .sub, .parent = "canvas", .allows = &.{"canvas.engage"} },
    .{ .name = "canvas.selection", .kind = .sub, .parent = "canvas", .allows = &.{"canvas.selection"} },
    .{ .name = "canvas.flow", .kind = .sub, .lifetime = .until_left, .parent = "canvas", .takes_text = true, .allows = &.{"canvas.flow"} },
    .{ .name = "canvas.equation", .kind = .sub, .lifetime = .until_left, .parent = "canvas", .takes_text = true, .allows = &.{"canvas.equation"} },
    .{ .name = "canvas.equation.head", .kind = .sub, .parent = "canvas.equation", .allows = &.{"canvas.equation.head"} },
    // The expression line under the canvas.
    .{ .name = "expression-line", .kind = .sub, .parent = "canvas", .takes_text = true, .allows = &.{"expression-line.tab"} },
    .{ .name = "expression-line.completion", .kind = .sub, .parent = "expression-line", .allows = &.{"expression-line.completion"} },
    .{ .name = "expression-line.run", .kind = .sub, .parent = "expression-line", .allows = &.{"expression-line.run"} },
    // A legend sheet's view: its cell edited where it is (typed text),
    // and moving between cells.
    .{ .name = "sheet", .kind = .major, .parent = "global", .takes_text = true, .allows = &.{"sheet"} },
    // A panel's grid instances being placed.
    .{ .name = "panel-edit", .kind = .major, .lifetime = .until_left, .parent = "global", .allows = &.{"panel-edit"} },
    // A sketch being drawn and constrained, and its summary.
    .{ .name = "sketch", .kind = .major, .lifetime = .until_left, .parent = "global", .allows = &.{ "sketch.tab", "sketch.cancel", "sketch.finish", "sketch.delete", "sketch.constraint", "sketch.tool" } },
    .{ .name = "sketch.summary", .kind = .sub, .parent = "sketch", .allows = &.{"sketch.summary"} },
};

pub const action_defs = [_]A{
    // Bring every auto-hide pane in, or let them all go (a hot corner's).
    .{ .name = "panes.toggle-auto" },
    // The document's views: a new one beside the active one, closing it,
    // filling the window with it, the next one.
    .{ .name = "views.split-across" },
    .{ .name = "views.split-down" },
    .{ .name = "views.close" },
    .{ .name = "views.maximize" },
    .{ .name = "views.next", .repeat = true, .param = .int },
    // To the cell above (0), below (1), after (2) or before (3).
    .{ .name = "sheet.move", .repeat = true, .param = .int },
    // The pane layouts (layouts.zig): the next one, the panes as they are
    // saved as a new one, this machine's changes to the one in use dropped.
    .{ .name = "panes.layout-next" },
    .{ .name = "panes.layout-save-as" },
    .{ .name = "panes.layout-reset" },
    .{ .name = "file.new" },
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
    .{ .name = "view.zoom-in", .repeat = true },
    .{ .name = "view.zoom-out", .repeat = true },
    // Drags snap to the grid, or not.
    .{ .name = "view.snap-grid" },

    .{ .name = "dialog.confirm" },
    .{ .name = "dialog.cancel" },
    // The card's width, device pixels.
    .{ .name = "dialog.calibrate-size.grow", .repeat = true, .param = .int },

    // The units' index: 0 mm, 1 inches.
    .{ .name = "start.new-canvas", .param = .int },
    .{ .name = "start.new-canvas-last" },
    .{ .name = "start.open" },
    .{ .name = "start.display-correction" },
    // Which recent file, from 0.
    .{ .name = "start.open-recent", .param = .int },

    // By the grid's minor unit showing (`…-far`: its major unit).
    .{ .name = "canvas.object.nudge", .repeat = true, .param = .direction },
    .{ .name = "canvas.object.nudge-far", .repeat = true, .param = .direction },
    .{ .name = "canvas.object.delete" },
    .{ .name = "canvas.tile.edit-text" },
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

    .{ .name = "canvas.flow.caret.char-left", .repeat = true },
    .{ .name = "canvas.flow.caret.char-right", .repeat = true },
    .{ .name = "canvas.flow.caret.word-left", .repeat = true },
    .{ .name = "canvas.flow.caret.word-right", .repeat = true },
    .{ .name = "canvas.flow.caret.line-start", .repeat = true },
    .{ .name = "canvas.flow.caret.line-end", .repeat = true },
    .{ .name = "canvas.flow.caret.text-start", .repeat = true },
    .{ .name = "canvas.flow.caret.text-end", .repeat = true },
    .{ .name = "canvas.flow.caret.line-up", .repeat = true },
    .{ .name = "canvas.flow.caret.line-down", .repeat = true },
    .{ .name = "canvas.flow.select.char-left", .repeat = true },
    .{ .name = "canvas.flow.select.char-right", .repeat = true },
    .{ .name = "canvas.flow.select.word-left", .repeat = true },
    .{ .name = "canvas.flow.select.word-right", .repeat = true },
    .{ .name = "canvas.flow.select.line-start", .repeat = true },
    .{ .name = "canvas.flow.select.line-end", .repeat = true },
    .{ .name = "canvas.flow.select.text-start", .repeat = true },
    .{ .name = "canvas.flow.select.text-end", .repeat = true },
    .{ .name = "canvas.flow.select.line-up", .repeat = true },
    .{ .name = "canvas.flow.select.line-down", .repeat = true },
    .{ .name = "canvas.flow.select.all" },
    .{ .name = "canvas.flow.copy" },
    .{ .name = "canvas.flow.cut" },
    .{ .name = "canvas.flow.paste" },
    .{ .name = "canvas.flow.edit-equation" },
    // 0 forward, 1 back.
    .{ .name = "canvas.flow.tab", .repeat = true, .param = .int },
    .{ .name = "canvas.flow.new-paragraph", .repeat = true },
    .{ .name = "canvas.flow.new-line", .repeat = true },
    .{ .name = "canvas.flow.delete-back", .repeat = true },
    .{ .name = "canvas.flow.delete-forward", .repeat = true },
    .{ .name = "canvas.flow.leave" },

    .{ .name = "canvas.equation.leave" },
    .{ .name = "canvas.equation.tab", .repeat = true, .param = .int },
    .{ .name = "canvas.equation.caret.left", .repeat = true },
    .{ .name = "canvas.equation.caret.right", .repeat = true },
    .{ .name = "canvas.equation.caret.start", .repeat = true },
    .{ .name = "canvas.equation.caret.end", .repeat = true },
    .{ .name = "canvas.equation.delete-back", .repeat = true },
    .{ .name = "canvas.equation.delete-forward", .repeat = true },
    .{ .name = "canvas.equation.head.nudge", .repeat = true, .param = .direction },
    .{ .name = "canvas.equation.head.scale-up" },
    .{ .name = "canvas.equation.head.scale-down" },
    .{ .name = "canvas.equation.head.turn-left" },
    .{ .name = "canvas.equation.head.turn-right" },
    .{ .name = "canvas.equation.head.reset" },
    .{ .name = "canvas.equation.head.slot-index" },
    .{ .name = "canvas.equation.head.slot-upper" },
    .{ .name = "canvas.equation.head.slot-lower" },

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
    .{ .name = "sketch.tool.next", .repeat = true },
    .{ .name = "sketch.summary.leave", .repeat = true },
    .{ .name = "sketch.summary.back", .repeat = true },
};

const left: i32 = @intFromEnum(Direction.left);
const right: i32 = @intFromEnum(Direction.right);
const up: i32 = @intFromEnum(Direction.up);
const down: i32 = @intFromEnum(Direction.down);

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

/// A flow's caret movements, each from the toolkit's text-field binding
/// (so as the platform has them), with and without selecting.
fn flowMoves() [20]B {
    const pairs = [_][2][]const u8{
        .{ "char_left", "char-left" },   .{ "char_right", "char-right" }, .{ "word_left", "word-left" },
        .{ "word_right", "word-right" }, .{ "line_start", "line-start" }, .{ "line_end", "line-end" },
        .{ "text_start", "text-start" }, .{ "text_end", "text-end" },     .{ "char_up", "line-up" },
        .{ "char_down", "line-down" },
    };
    var out: [20]B = undefined;
    for (pairs, 0..) |p, i| {
        out[2 * i] = .{ .mode = "canvas.flow", .chord = "bind:" ++ p[0], .action = "canvas.flow.caret." ++ p[1] };
        out[2 * i + 1] = .{ .mode = "canvas.flow", .chord = "bind:" ++ p[0] ++ "_select", .action = "canvas.flow.select." ++ p[1] };
    }
    return out;
}

pub const binds = [_]B{
    .{ .mode = "global", .chord = "primary+n", .action = "file.new" },
    .{ .mode = "global", .chord = "primary+tab", .action = "views.next", .arg = 0 },
    .{ .mode = "sheet", .chord = "up", .action = "sheet.move", .arg = 0 },
    .{ .mode = "sheet", .chord = "down", .action = "sheet.move", .arg = 1 },
    .{ .mode = "sheet", .chord = "enter", .action = "sheet.move", .arg = 1 },
    .{ .mode = "sheet", .chord = "tab", .action = "sheet.move", .arg = 2 },
    .{ .mode = "sheet", .chord = "shift+tab", .action = "sheet.move", .arg = 3 },
    .{ .mode = "global", .chord = "primary+shift+tab", .action = "views.next", .arg = 1 },
    .{ .mode = "global", .chord = "primary+o", .action = "file.open" },
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
    .{ .mode = "view", .chord = "primary+equal", .action = "view.zoom-in" },
    .{ .mode = "view", .chord = "primary+shift+equal", .action = "view.zoom-in" },
    .{ .mode = "view", .chord = "primary+kp_add", .action = "view.zoom-in" },
    .{ .mode = "view", .chord = "primary+minus", .action = "view.zoom-out" },
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
} ++ enters("dialog", "dialog.confirm") ++ [_]B{
    .{ .mode = "dialog", .chord = "escape", .action = "dialog.cancel" },
    .{ .mode = "dialog.calibrate-size", .chord = "left", .action = "dialog.calibrate-size.grow", .arg = -1 },
    .{ .mode = "dialog.calibrate-size", .chord = "right", .action = "dialog.calibrate-size.grow", .arg = 1 },
    .{ .mode = "dialog.calibrate-size", .chord = "shift+left", .action = "dialog.calibrate-size.grow", .arg = -10 },
    .{ .mode = "dialog.calibrate-size", .chord = "shift+right", .action = "dialog.calibrate-size.grow", .arg = 10 },

    .{ .mode = "start", .chord = "m", .action = "start.new-canvas", .arg = 0 },
    .{ .mode = "start", .chord = "i", .action = "start.new-canvas", .arg = 1 },
    .{ .mode = "start", .chord = "o", .action = "start.open" },
    .{ .mode = "start", .chord = "d", .action = "start.display-correction" },
} ++ enters("start", "start.new-canvas-last") ++ recents() ++
    arrows("canvas", "canvas.object.nudge") ++ shiftArrows("canvas", "canvas.object.nudge-far") ++ [_]B{
    .{ .mode = "canvas", .chord = "delete", .action = "canvas.object.delete" },
    .{ .mode = "canvas", .chord = "primary+backslash", .action = "canvas.tile.edit-text" },
    .{ .mode = "canvas", .chord = "escape", .action = "canvas.tool.cancel" },
} ++ enters("canvas", "canvas.tool.finish") ++ arrows("canvas.selection", "canvas.selection.nudge") ++ shiftArrows("canvas.selection", "canvas.selection.nudge-far") ++ [_]B{
    .{ .mode = "canvas.engage", .chord = "tab", .action = "canvas.engage.lock", .arg = 0 },
    .{ .mode = "canvas.engage", .chord = "shift+tab", .action = "canvas.engage.lock", .arg = 1 },
    .{ .mode = "canvas.engage", .chord = "escape", .action = "canvas.engage.release" },
    .{ .mode = "canvas.selection", .chord = "tab", .action = "canvas.selection.hunt", .arg = 0 },
    .{ .mode = "canvas.selection", .chord = "shift+tab", .action = "canvas.selection.hunt", .arg = 1 },
    .{ .mode = "canvas.selection", .chord = "escape", .action = "canvas.selection.clear" },
} ++ flowMoves() ++ [_]B{
    .{ .mode = "canvas.flow", .chord = "bind:copy", .action = "canvas.flow.copy" },
    .{ .mode = "canvas.flow", .chord = "bind:cut", .action = "canvas.flow.cut" },
    .{ .mode = "canvas.flow", .chord = "bind:paste", .action = "canvas.flow.paste" },
    .{ .mode = "canvas.flow", .chord = "bind:select_all", .action = "canvas.flow.select.all" },
    .{ .mode = "canvas.flow", .chord = "primary+backslash", .action = "canvas.flow.edit-equation" },
    .{ .mode = "canvas.flow", .chord = "tab", .action = "canvas.flow.tab", .arg = 0 },
    .{ .mode = "canvas.flow", .chord = "shift+tab", .action = "canvas.flow.tab", .arg = 1 },
    .{ .mode = "canvas.flow", .chord = "enter", .action = "canvas.flow.new-paragraph" },
    .{ .mode = "canvas.flow", .chord = "kp_enter", .action = "canvas.flow.new-paragraph" },
    .{ .mode = "canvas.flow", .chord = "shift+enter", .action = "canvas.flow.new-line" },
    .{ .mode = "canvas.flow", .chord = "shift+kp_enter", .action = "canvas.flow.new-line" },
    .{ .mode = "canvas.flow", .chord = "backspace", .action = "canvas.flow.delete-back" },
    .{ .mode = "canvas.flow", .chord = "delete", .action = "canvas.flow.delete-forward" },
    .{ .mode = "canvas.flow", .chord = "escape", .action = "canvas.flow.leave" },

    .{ .mode = "canvas.equation", .chord = "primary+backslash", .action = "canvas.equation.leave" },
    .{ .mode = "canvas.equation", .chord = "escape", .action = "canvas.equation.leave" },
} ++ enters("canvas.equation", "canvas.equation.leave") ++ [_]B{
    .{ .mode = "canvas.equation", .chord = "tab", .action = "canvas.equation.tab", .arg = 0 },
    .{ .mode = "canvas.equation", .chord = "shift+tab", .action = "canvas.equation.tab", .arg = 1 },
    .{ .mode = "canvas.equation", .chord = "left", .action = "canvas.equation.caret.left" },
    .{ .mode = "canvas.equation", .chord = "right", .action = "canvas.equation.caret.right" },
    .{ .mode = "canvas.equation", .chord = "home", .action = "canvas.equation.caret.start" },
    .{ .mode = "canvas.equation", .chord = "end", .action = "canvas.equation.caret.end" },
    .{ .mode = "canvas.equation", .chord = "backspace", .action = "canvas.equation.delete-back" },
    .{ .mode = "canvas.equation", .chord = "delete", .action = "canvas.equation.delete-forward" },
} ++ arrows("canvas.equation.head", "canvas.equation.head.nudge") ++ [_]B{
    .{ .mode = "canvas.equation.head", .chord = "char:=", .action = "canvas.equation.head.scale-up" },
    .{ .mode = "canvas.equation.head", .chord = "char:+", .action = "canvas.equation.head.scale-up" },
    .{ .mode = "canvas.equation.head", .chord = "char:-", .action = "canvas.equation.head.scale-down" },
    .{ .mode = "canvas.equation.head", .chord = "char:[", .action = "canvas.equation.head.turn-left" },
    .{ .mode = "canvas.equation.head", .chord = "char:]", .action = "canvas.equation.head.turn-right" },
    .{ .mode = "canvas.equation.head", .chord = "char:0", .action = "canvas.equation.head.reset" },
    .{ .mode = "canvas.equation.head", .chord = "char:i", .action = "canvas.equation.head.slot-index" },
    .{ .mode = "canvas.equation.head", .chord = "char:u", .action = "canvas.equation.head.slot-upper" },
    .{ .mode = "canvas.equation.head", .chord = "char:b", .action = "canvas.equation.head.slot-lower" },

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
    .{ .mode = "sketch", .chord = "m", .action = "sketch.tool.next" },
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

pub const R = actions.Registry(dvui.enums.Key, builtin.os.tag == .macos, &modes, &action_defs, &binds);

pub const ActionId = R.ActionId;
pub const ModeId = R.ModeId;

/// The action named `name` (checked when built).
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
        return @enumFromInt(inv.arg);
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

fn printable(k: dvui.enums.Key) bool {
    const i = @intFromEnum(k);
    return (i >= @intFromEnum(dvui.enums.Key.a) and i <= @intFromEnum(dvui.enums.Key.nine)) or
        (i >= @intFromEnum(dvui.enums.Key.space) and i <= @intFromEnum(dvui.enums.Key.grave)) or
        (i >= @intFromEnum(dvui.enums.Key.kp_divide) and i <= @intFromEnum(dvui.enums.Key.kp_equal));
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
                        .bind => |name| k.matchBind(name),
                        .char => false,
                    };
                    if (hit) return logged(.{ .action = b.action, .arg = b.arg, .chorded = b.chord.what != .code or b.chord.mods.chorded() }, m);
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
    var best: ?R.Binding = null;
    for (R.tables[m]) |b| {
        if (b.action != a or b.arg != arg or b.chord.what == .bind) continue;
        if (best == null or (!best.?.chord.mods.chorded() and b.chord.mods.chorded())) best = b;
    }
    const b = best orelse return null;
    var w: std.Io.Writer = .fixed(buf);
    const cmd_name = if (builtin.os.tag == .macos) "Cmd+" else "Super+";
    if (b.chord.mods.ctrl) w.writeAll("Ctrl+") catch return null;
    if (b.chord.mods.cmd) w.writeAll(cmd_name) catch return null;
    if (b.chord.mods.alt) w.writeAll(if (builtin.os.tag == .macos) "Option+" else "Alt+") catch return null;
    if (b.chord.mods.shift) w.writeAll("Shift+") catch return null;
    switch (b.chord.what) {
        .char => |c| w.writeAll(c) catch return null,
        .code => |k| w.writeAll(keyName(k)) catch return null,
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
