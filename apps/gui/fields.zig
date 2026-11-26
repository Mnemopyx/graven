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
    if (lu == null) measure_id = null;
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

/// Measurements' own units (the owner, 2026-11-26: every measurement
/// carries its unit; a pop-up beside the value shows it, and picking
/// another converts the value). The app keeps them in the document: `get`
/// says which unit measurement `id` is shown in (null: its label's), `set`
/// keeps one picked from the pop-up or typed after a number.
pub var measure_unit_get: ?*const fn (id: []const u8) ?units.Unit = null;
pub var measure_unit_set: ?*const fn (id: []const u8, unit: units.Unit) void = null;

/// The id of the measurement about to be drawn (set with its label, by
/// `propName`, taken by the next number field): it gets a unit pop-up.
pub var measure_id: ?[]const u8 = null;

/// The size of a `u` (mm) for the measurements drawn now, where what they
/// belong to has one (a tile's prototype); null elsewhere.
pub var u_mm: ?f64 = null;

/// A unit a script picks in measurement `id`'s pop-up, as if chosen there.
pub var script_unit: ?struct { id: []const u8, unit: units.Unit } = null;
var script_unit_id: [160]u8 = undefined;

/// Asks for measurement `id` to be shown in the unit written `symbol`;
/// false when no unit is written so.
pub fn setScriptedUnit(id: []const u8, symbol: []const u8) bool {
    const u = units.bySymbol(symbol) orelse return false;
    if (u == .percent) return false;
    const k = @min(id.len, script_unit_id.len);
    @memcpy(script_unit_id[0..k], id[0..k]);
    script_unit = .{ .id = script_unit_id[0..k], .unit = u };
    return true;
}

/// How a unit reads in its pop-up.
pub fn unitLabel(u: units.Unit) []const u8 {
    return switch (u) {
        .deg => "°",
        else => u.symbol(),
    };
}

/// A value as a field shows it: six significant digits (at most nine
/// decimals), trailing zeros dropped (25.4 mm in inches is 1, not
/// 0.99999999999; 17.1106 %, not 17.110640914).
pub fn formatValue(buf: []u8, v: f64) []const u8 {
    const mag: i32 = if (v == 0) 0 else @intFromFloat(@floor(std.math.log10(@abs(v))));
    const decimals: usize = @intCast(std.math.clamp(5 - mag, 0, 9));
    var t = std.fmt.bufPrint(buf, "{d:.[1]}", .{ v, decimals }) catch return "?";
    if (std.mem.indexOfScalar(u8, t, '.') != null) {
        while (t[t.len - 1] == '0') t = t[0 .. t.len - 1];
        if (t[t.len - 1] == '.') t = t[0 .. t.len - 1];
    }
    if (std.mem.eql(u8, t, "-0")) t = t[1..];
    return t;
}

/// A number field in `unit` (the unit its label names): the one path for
/// measurements in Properties. Labelled by `propName` (`measure_id`), it
/// shows its value in the measurement's own unit, with a pop-up of the
/// units of its kind beside it; picking one converts what it shows (the
/// value is unchanged). It takes any unit of that kind typed after the
/// number ("1in" in a mm field), which becomes its unit; "+2pt" or "-1mm"
/// is added to the value, "+10%" adds that share of it, "120%" is that
/// share of it. A bare number is in its unit. `u` (a layout's unit) is
/// offered where `u_mm` is known. Returns the new value in `unit`, within
/// `min` and `max`.
pub fn unitNumberField(src: std.builtin.SourceLocation, value: f64, min: f64, max: f64, unit: units.Unit, opts: dvui.Options) ?f64 {
    const mid = measure_id;
    measure_id = null;
    const dim = unit.def().dimension orelse .length;
    // The field's own unit in base units (a u field without a u size
    // counts in u alone).
    const own_base = units.baseIn(unit, .{ .u = u_mm }) orelse 1;
    const ctx: units.Context = .{ .u = if (unit == .u and u_mm == null) 1 else u_mm, .reference = value * own_base };
    // The unit it is shown in: the measurement's own, else its label's.
    var shown_unit = unit;
    if (mid) |id| if (measure_unit_get) |get| if (get(id)) |mu| {
        if (mu.def().dimension == dim and units.baseIn(mu, ctx) != null) shown_unit = mu;
    };
    // A script's pick, as if from the pop-up.
    if (mid) |id| if (script_unit) |sc| if (std.mem.eql(u8, sc.id, id)) {
        script_unit = null;
        if (sc.unit.def().dimension == dim and units.baseIn(sc.unit, ctx) != null) {
            if (measure_unit_set) |set| set(id, sc.unit);
            shown_unit = sc.unit;
        }
    };
    const shown_value = units.fromBaseIn(value * own_base, shown_unit, ctx) orelse value;
    var buf: [64]u8 = undefined;
    const shown = formatValue(&buf, shown_value);
    // Room for its pop-up beside it: narrower than a text entry's own
    // least width.
    var te_opts = opts;
    if (mid != null and te_opts.min_size_content == null) te_opts = te_opts.min_sizeM(6, 1);
    var te = dvui.textEntry(src, .{ .text_initial = shown }, te_opts);
    const typed = accept(te, shown);
    var out: ?f64 = null;
    if (typed) |text| blk: {
        const q = units.Quantity.parse(text, shown_unit) orelse {
            reject(te);
            break :blk;
        };
        const base = q.resolveIn(ctx) orelse {
            reject(te);
            break :blk;
        };
        const v = units.fromBaseIn(base, unit, ctx) orelse {
            reject(te);
            break :blk;
        };
        if (!(v >= min and v <= max)) {
            reject(te);
            break :blk;
        }
        // Typed with a unit of its kind: that is its unit now.
        if (q.unit != .percent and q.unit != shown_unit) if (mid) |id| if (measure_unit_set) |set| set(id, q.unit);
        if (v != value) out = v;
    }
    te.deinit();
    // The pop-up: the units of its kind (u only where there is one).
    if (mid) |id| {
        var entries: [8][]const u8 = undefined;
        var which: [8]units.Unit = undefined;
        var n: usize = 0;
        var choice: usize = 0;
        for (units.ofDimension(dim)) |u| {
            if (u == .u and u_mm == null and unit != .u) continue;
            if (n == entries.len) break;
            if (u == shown_unit) choice = n;
            entries[n] = unitLabel(u);
            which[n] = u;
            n += 1;
        }
        var tag_buf: [200]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, "{s}:unit", .{id}) catch id;
        const tag_a = dvui.currentWindow().arena().dupe(u8, tag) catch tag;
        if (dvui.dropdown(@src(), entries[0..n], .{ .choice = &choice }, .{}, .{
            .id_extra = opts.id_extra,
            .tag = tag_a,
            .min_size_content = .{ .w = 50 },
            .max_size_content = .{ .w = 50, .h = 1000 },
            .gravity_y = 0.5,
            .margin = .{ .x = 4 },
        })) {
            if (which[choice] != shown_unit) if (measure_unit_set) |set| set(id, which[choice]);
        }
    }
    return out;
}

/// What a stored quantity's field gives: its quantity, or "auto" (none
/// of its own).
pub const QuantityEdit = union(enum) {
    auto,
    quantity: units.Quantity,
};

/// A measurement stored as typed (a `Quantity`: leading), the same way as
/// `unitNumberField`: its value and sign in the field, its unit in a
/// pop-up beside it (the lengths, and % of its reference), "auto" when it
/// has none. Picking a unit converts it, a relative one staying relative
/// ("+10%" of a 10 pt font becomes "+1" pt); a value typed with a unit
/// takes that unit. `reference` is what a share or a relative value is
/// of (base units). The pop-up's id is `measure_id`'s.
pub fn quantityField(src: std.builtin.SourceLocation, q: ?units.Quantity, default: units.Unit, reference: ?f64, opts: dvui.Options) ?QuantityEdit {
    const mid = measure_id;
    measure_id = null;
    label_unit = null;
    const ctx: units.Context = .{ .reference = reference, .u = u_mm };
    var cur = q;
    // A script's pick, as if from the pop-up.
    var picked: ?units.Unit = null;
    if (mid) |id| if (script_unit) |sc| if (std.mem.eql(u8, sc.id, id)) {
        script_unit = null;
        picked = sc.unit;
    };
    var buf: [64]u8 = undefined;
    const shown: []const u8 = if (cur) |c| blk: {
        const sign: []const u8 = if (c.relative and c.value >= 0) "+" else "";
        var vb: [48]u8 = undefined;
        break :blk std.fmt.bufPrint(&buf, "{s}{s}", .{ sign, formatValue(&vb, c.value) }) catch "?";
    } else "auto";
    var te_opts = opts;
    if (mid != null and te_opts.min_size_content == null) te_opts = te_opts.min_sizeM(6, 1);
    var te = dvui.textEntry(src, .{ .text_initial = shown }, te_opts);
    var out: ?QuantityEdit = null;
    if (accept(te, shown)) |text| blk: {
        const t = std.mem.trim(u8, text, " ");
        if (std.ascii.eqlIgnoreCase(t, "auto")) {
            out = .auto;
            break :blk;
        }
        const nq = units.Quantity.parse(t, if (cur) |c| c.unit else default) orelse {
            reject(te);
            break :blk;
        };
        if (nq.resolveIn(ctx) == null) {
            reject(te);
            break :blk;
        }
        out = .{ .quantity = nq };
    }
    te.deinit();
    if (mid) |id| {
        const list = units.ofDimension(default.def().dimension orelse .length);
        var entries: [10][]const u8 = undefined;
        var which: [10]units.Unit = undefined;
        var n: usize = 0;
        var choice: usize = 0;
        const now = if (cur) |c| c.unit else default;
        for (list) |u| {
            if (u == .u and u_mm == null) continue;
            if (u == now) choice = n;
            entries[n] = unitLabel(u);
            which[n] = u;
            n += 1;
        }
        if (reference != null) {
            if (now == .percent) choice = n;
            entries[n] = "%";
            which[n] = .percent;
            n += 1;
        }
        var tag_buf: [200]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, "{s}:unit", .{id}) catch id;
        const tag_a = dvui.currentWindow().arena().dupe(u8, tag) catch tag;
        if (dvui.dropdown(@src(), entries[0..n], .{ .choice = &choice }, .{}, .{
            .id_extra = opts.id_extra,
            .tag = tag_a,
            .min_size_content = .{ .w = 50 },
            .max_size_content = .{ .w = 50, .h = 1000 },
            .gravity_y = 0.5,
            .margin = .{ .x = 4 },
        })) picked = which[choice];
        if (picked) |u| if (cur) |c| if (u != c.unit and out == null) {
            if (convertQuantity(c, u, ctx)) |nq| {
                cur = nq;
                out = .{ .quantity = nq };
            }
        };
    }
    return out;
}

/// `q` in unit `to`, the same size (relative stays relative): through
/// base units, a share through its reference.
pub fn convertQuantity(q: units.Quantity, to: units.Unit, ctx: units.Context) ?units.Quantity {
    // Its amount (what is added, or all of it) in base units.
    const amount = if (q.unit == .percent) (ctx.reference orelse return null) * q.value / 100 else q.value * (units.baseIn(q.unit, ctx) orelse return null);
    const v = if (to == .percent) amount / (ctx.reference orelse return null) * 100 else units.fromBaseIn(amount, to, ctx) orelse return null;
    // Rounded off where the conversion leaves dust (12 pt is 12, not
    // 11.999999999998).
    const r = @round(v * 1e9) / 1e9;
    return .{ .value = r, .unit = to, .relative = q.relative };
}

/// A text field: returns the new text, trimmed, when it is accepted and
/// `valid` takes it; anything else goes back.
pub fn textField(src: std.builtin.SourceLocation, value: []const u8, opts: dvui.Options, init: dvui.TextEntryWidget.InitOptions, comptime valid: fn ([]const u8) bool) ?[]const u8 {
    // Not a measurement: a unit its label named is not for a field after.
    label_unit = null;
    measure_id = null;
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
