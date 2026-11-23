//! Fields that change nothing while they are typed in (the owner's rule,
//! 2026-11-20). An edit begins when a field takes the keyboard; what is
//! typed stays the field's own. Enter, or the keyboard leaving the field,
//! offers the text: complete and valid, the caller takes it (one undo
//! step); otherwise the field goes back to what it held when the edit
//! began. Esc goes back too, and leaves the field.
//!
//! A press elsewhere while a field holds an unaccepted edit could change
//! what the panes show (a node chosen in the Browser, an object on the
//! canvas) before the field is drawn again, and the edit would be lost. So
//! `beginFrame` sees such a press first: the frame becomes the field's
//! last (the keyboard leaves it, it offers its text), and the press is
//! held back and given again the next frame, to whatever it was for.

const std = @import("std");
const dvui = @import("dvui");
const units = @import("graven_layout").units;

/// Called when a field offers its text, before the caller takes it: the
/// app starts a new undo step for it.
pub var on_accept: ?*const fn () void = null;

/// The unit the label of the field about to be drawn names (set with the
/// label, taken by the next number field): every field so labelled reads
/// typed units through `units`, the same way.
pub var label_unit: ?units.Unit = null;

/// The id of the field about to be drawn (the app sets it with the
/// field's row; see main.zig, "Element ids").
pub var current_id: []const u8 = "";

/// Text a script gives the field with id `id`, as if typed and accepted
/// there; taken (or refused, as typing would be) when that field is next
/// drawn.
pub var script: ?struct { id: []const u8, text: []const u8 } = null;
var script_buf: [512]u8 = undefined;
var script_id_buf: [160]u8 = undefined;
/// Whether the last scripted text was refused by its field.
pub var script_refused = false;

/// Asks for `text` to be given to the field with id `id`.
pub fn setScripted(id: []const u8, text: []const u8) void {
    const n = @min(text.len, script_buf.len);
    @memcpy(script_buf[0..n], text[0..n]);
    const k = @min(id.len, script_id_buf.len);
    @memcpy(script_id_buf[0..k], id[0..k]);
    script = .{ .id = script_id_buf[0..k], .text = script_buf[0..n] };
    script_refused = false;
}

/// The field being edited, as last drawn.
var editing: ?struct {
    id: dvui.Id,
    subwindow: dvui.Id,
    rect: dvui.Rect.Physical,
    /// Its text differs from where the edit began.
    dirty: bool,
} = null;

/// The field that took a script's text last.
var last_offered: ?dvui.Id = null;

/// Button events held back a frame, in order.
const Held = struct { button: dvui.enums.Button, action: dvui.Event.Mouse.Action };
var held: [16]Held = undefined;
var held_n: usize = 0;

/// Call at the start of each frame, before any widget.
pub fn beginFrame() void {
    const cw = dvui.currentWindow();
    if (held_n > 0) {
        // What was held back, then this frame's own buttons after it, so
        // a release never comes before its press.
        var later: [16]Held = undefined;
        var later_n: usize = 0;
        for (dvui.events()) |*e| {
            if (e.handled or e.evt != .mouse) continue;
            switch (e.evt.mouse.action) {
                .press, .release => {
                    if (later_n < later.len) {
                        later[later_n] = .{ .button = e.evt.mouse.button, .action = e.evt.mouse.action };
                        later_n += 1;
                    }
                    e.handled = true;
                },
                .focus => e.handled = true,
                else => {},
            }
        }
        for (held[0..held_n]) |h| _ = cw.addEventMouseButton(h.button, h.action) catch {};
        for (later[0..later_n]) |h| _ = cw.addEventMouseButton(h.button, h.action) catch {};
        held_n = 0;
        return;
    }
    const ed = editing orelse return;
    if (!ed.dirty) return;
    var outside = false;
    for (dvui.events()) |e| {
        if (e.handled or e.evt != .mouse) continue;
        if (e.evt.mouse.action == .press and !ed.rect.contains(e.evt.mouse.p)) outside = true;
    }
    if (!outside) return;
    for (dvui.events()) |*e| {
        if (e.handled or e.evt != .mouse) continue;
        switch (e.evt.mouse.action) {
            .press, .release => {
                if (held_n < held.len) {
                    held[held_n] = .{ .button = e.evt.mouse.button, .action = e.evt.mouse.action };
                    held_n += 1;
                }
                e.handled = true;
            },
            .focus => e.handled = true,
            else => {},
        }
    }
    // The keyboard leaves the field: drawn this frame, it offers its text.
    dvui.focusWidget(null, ed.subwindow, null);
    dvui.refresh(null, @src(), null);
}

/// Keeps text entry `te` to the rule: while it is not being edited it
/// shows `value`; returns the text it offers (Enter, or the keyboard
/// leaving it) when that differs from where the edit began, for the
/// caller to take or `reject`.
pub fn accept(te: *dvui.TextEntryWidget, value: []const u8) ?[]const u8 {
    const id = te.data().id;
    // A script's text, as if typed and accepted here.
    if (script) |sc| if (std.mem.eql(u8, sc.id, current_id)) {
        script = null;
        dvui.dataSet(null, id, "editing", false);
        dvui.dataSetSlice(null, id, "orig", value);
        te.textSet(sc.text, false);
        dvui.refresh(null, @src(), null);
        if (std.mem.eql(u8, sc.text, value)) return null;
        const out = dvui.currentWindow().arena().dupe(u8, sc.text) catch return null;
        if (on_accept) |f| f();
        // Refused, the field goes back (`reject`) and says so.
        last_offered = id;
        return out;
    };
    const focused = dvui.focusedWidgetId() == id;
    const was = dvui.dataGet(null, id, "editing", bool) orelse false;
    if (focused and !was) {
        dvui.dataSet(null, id, "editing", true);
        dvui.dataSetSlice(null, id, "orig", value);
    }
    const orig: []const u8 = dvui.dataGetSlice(null, id, "orig", []u8) orelse value;
    if (focused) {
        for (dvui.events()) |*e| {
            if (e.handled or e.evt != .key) continue;
            if (e.evt.key.code != .escape or e.evt.key.action != .down) continue;
            if (!dvui.eventMatchSimple(e, te.data())) continue;
            // Back to how it was, and out of the field.
            e.handle(@src(), te.data());
            te.textSet(orig, false);
            dvui.dataSet(null, id, "editing", false);
            editing = null;
            dvui.focusWidget(null, null, null);
            return null;
        }
        const text = te.textGet();
        editing = .{ .id = id, .subwindow = dvui.subwindowCurrentId(), .rect = te.data().borderRectScale().r, .dirty = !std.mem.eql(u8, text, orig) };
        if (te.enter_pressed and !std.mem.eql(u8, text, orig)) {
            const out = dvui.currentWindow().arena().dupe(u8, text) catch return null;
            // The next edit begins from what was offered.
            dvui.dataSetSlice(null, id, "orig", out);
            if (on_accept) |f| f();
            return out;
        }
        return null;
    }
    if (was) {
        dvui.dataSet(null, id, "editing", false);
        if (editing) |ed| if (ed.id == id) {
            editing = null;
        };
        const text = te.textGet();
        if (!std.mem.eql(u8, text, orig)) {
            const out = dvui.currentWindow().arena().dupe(u8, text) catch return null;
            if (on_accept) |f| f();
            return out;
        }
    }
    // Not being edited: it shows the value (an undo, another field's
    // change, a value refused last frame).
    if (!std.mem.eql(u8, te.textGet(), value)) te.textSet(value, false);
    return null;
}

/// The text offered is not taken: the field goes back to where its edit
/// began (while it still has the keyboard; else it shows the value again
/// by itself).
pub fn reject(te: *dvui.TextEntryWidget) void {
    const id = te.data().id;
    if (last_offered) |lo| if (lo == id) {
        script_refused = true;
    };
    if (dvui.dataGetSlice(null, id, "orig", []u8)) |orig| te.textSet(orig, false);
}

/// A number field: returns a new value, accepted and within `min` and
/// `max`; anything else typed goes back.
pub fn numberField(src: std.builtin.SourceLocation, comptime T: type, value: T, min: T, max: T, opts: dvui.Options) ?T {
    // Labelled with a unit: any unit of its kind, through `units`.
    const lu = label_unit;
    label_unit = null;
    if (lu) |u| {
        const v = unitNumberField(src, @floatCast(value), @floatCast(min), @floatCast(max), u, opts) orelse return null;
        return @floatCast(v);
    }
    var buf: [64]u8 = undefined;
    const shown = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "";
    var te = dvui.textEntry(src, .{ .text_initial = shown }, opts);
    defer te.deinit();
    const text = accept(te, shown) orelse return null;
    const v = std.fmt.parseFloat(T, std.mem.trim(u8, text, " ")) catch {
        reject(te);
        return null;
    };
    if (!(v >= min and v <= max)) {
        reject(te);
        return null;
    }
    if (v == value) return null;
    return v;
}

/// A number field in `unit` (the unit its label names): it takes any unit
/// of that dimension typed after the number ("1in" in a mm field), read by
/// `units`, the one path for typed units; a bare number is in `unit`. A
/// relative or percent value needs a reference, which this field has not:
/// it goes back. Returns the new value in `unit`, within `min` and `max`.
pub fn unitNumberField(src: std.builtin.SourceLocation, value: f64, min: f64, max: f64, unit: units.Unit, opts: dvui.Options) ?f64 {
    var buf: [64]u8 = undefined;
    const shown = std.fmt.bufPrint(&buf, "{d}", .{value}) catch "";
    var te = dvui.textEntry(src, .{ .text_initial = shown }, opts);
    defer te.deinit();
    const text = accept(te, shown) orelse return null;
    const q = units.Quantity.parse(text, unit) orelse {
        reject(te);
        return null;
    };
    const base = q.resolve(null) orelse {
        reject(te);
        return null;
    };
    const v = units.fromBase(base, unit);
    if (!(v >= min and v <= max)) {
        reject(te);
        return null;
    }
    if (v == value) return null;
    return v;
}

/// A text field: returns the new text, trimmed, when it is accepted and
/// `valid` takes it; anything else goes back.
pub fn textField(src: std.builtin.SourceLocation, value: []const u8, opts: dvui.Options, init: dvui.TextEntryWidget.InitOptions, comptime valid: fn ([]const u8) bool) ?[]const u8 {
    var o = init;
    o.text_initial = value;
    var te = dvui.textEntry(src, o, opts);
    defer te.deinit();
    const typed = accept(te, value) orelse return null;
    const t = std.mem.trim(u8, typed, " ");
    if (!valid(t)) {
        reject(te);
        return null;
    }
    if (std.mem.eql(u8, t, value)) return null;
    return t;
}

/// Any text but empty.
pub fn nonEmpty(t: []const u8) bool {
    return t.len > 0;
}

/// Any text at all, empty included.
pub fn anyText(_: []const u8) bool {
    return true;
}
