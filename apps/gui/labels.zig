//! Labels: what a button, a menu item or a key says, as a property of the
//! element (the owner, 2026-11-27: no label is hard-coded).
//!
//! Every element's default label is its registry entry's (`elements.zig`):
//! drawing code names the element by id and never writes its words. The
//! label is a property whose value is either text or a reference to a
//! cell of a text sheet, which is how the interface is translated:
//!
//!     [labels]
//!     "dialog.leave.cancel" = "Abbrechen"          # text
//!     "file.save" = "=Interface!menu.file.save"    # a sheet's cell
//!     "file.open" = "=Interface!menu.file.open!fr" # in that column
//!
//!     [interface]
//!     sheet = "Interface"   # every label not set: this sheet's row named by its id
//!     language = "de"       # the column read (else the sheet's shown one)
//!
//! A text sheet is a document's (`LegendSheet` with `texts`): each row
//! names something, its first column the default text, each other column
//! a language. A sheet named `Interface` is used without any setting.
//!
//! A reference names its sheet; the sheet is looked up by that name once
//! and then held by its ID (the owner, 2026-11-26: name links), so it
//! keeps working when the sheet is renamed. Rows are looked up by name:
//! an interface sheet's rows are element ids, which are not renamed.
//!
//! Window-free: the sheets are reached through `Sheets`, which the GUI
//! makes over its document; tested on its own.

const std = @import("std");
const elements = @import("elements.zig");

/// The labels in use (the GUI's settings) and the sheets they read: set
/// by the GUI at start; until then, the registry's.
pub var store: ?*Store = null;
pub var reader: ?Sheets = null;

/// The label of element `id` (a drawn element's, "#n" aside): its value,
/// else the registry's; null when the registry has no such element.
pub fn of(id: []const u8) ?[]const u8 {
    const e = elements.find(id) orelse return null;
    const s = store orelse return e.label;
    return s.label(id, e.label, reader);
}

/// The label of element `id`, checked when built.
pub fn get(comptime id: []const u8) []const u8 {
    const e = comptime elements.get(id);
    const s = store orelse return e.label;
    return s.label(id, e.label, reader);
}

/// Element `id`'s tooltip (`alt`: its other one, for when it is on or has
/// nothing to do), checked when built; its key is not in it.
pub fn tip(comptime id: []const u8, alt: bool) []const u8 {
    const e = comptime elements.get(id);
    const default = if (alt and e.tip_alt.len > 0) e.tip_alt else e.tip;
    const s = store orelse return default;
    return s.label(if (alt and e.tip_alt.len > 0) id ++ ":tip-alt" else id ++ ":tip", default, reader);
}

/// The label of element or group `id` (a menu's: "File"), checked when
/// built.
pub fn any(comptime id: []const u8) []const u8 {
    const default = comptime blk: {
        @setEvalBranchQuota(1_000_000);
        for (elements.all) |e| if (std.mem.eql(u8, e.id, id)) break :blk e.label;
        for (elements.groups) |g| if (std.mem.eql(u8, g.id, id)) break :blk g.label;
        @compileError("no element or group \"" ++ id ++ "\"");
    };
    const s = store orelse return default;
    return s.label(id, default, reader);
}

/// `get`'s label with `args` in its `{}`s (a label that says how many,
/// or which: "Make tracks of its {} rows"), into the frame's `buf`.
pub fn fmt(buf: []u8, comptime id: []const u8, args: anytype) []const u8 {
    return fill(buf, get(id), args);
}

/// `text` with each `{}` replaced by the next of `args` (strings or
/// numbers), into `buf`; cut short when `buf` is full.
pub fn fill(buf: []u8, text: []const u8, args: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var rest = text;
    inline for (args) |a| {
        const k = std.mem.indexOf(u8, rest, "{}") orelse break;
        w.writeAll(rest[0..k]) catch return w.buffered();
        const T = @TypeOf(a);
        const is_str = comptime switch (@typeInfo(T)) {
            .pointer => |p| p.child == u8 or (@typeInfo(p.child) == .array and @typeInfo(p.child).array.child == u8),
            else => false,
        };
        if (is_str) w.writeAll(a) catch return w.buffered() else w.print("{d}", .{a}) catch return w.buffered();
        rest = rest[k + 2 ..];
    }
    w.writeAll(rest) catch {};
    return w.buffered();
}

/// A cell of a text sheet, by name.
pub const Cell = struct {
    sheet: []const u8,
    row: []const u8,
    /// Its column (a language); null: the language in use.
    column: ?[]const u8 = null,
};

/// A label's value.
pub const Value = union(enum) {
    text: []const u8,
    cell: Cell,

    /// `=Sheet!row` or `=Sheet!row!column` is a cell; anything else is
    /// text (`==` starts text with an `=`). Slices into `s`.
    pub fn parse(s: []const u8) Value {
        if (s.len < 2 or s[0] != '=') return .{ .text = s };
        if (s[1] == '=') return .{ .text = s[1..] };
        var it = std.mem.splitScalar(u8, s[1..], '!');
        const sheet = it.next().?;
        const row = it.next() orelse return .{ .text = s };
        const column = it.next();
        if (it.next() != null or sheet.len == 0 or row.len == 0) return .{ .text = s };
        return .{ .cell = .{ .sheet = sheet, .row = row, .column = if (column) |c| (if (c.len == 0) null else c) else null } };
    }
};

/// What the labels read their sheets through (the GUI's document).
pub const Sheets = struct {
    ctx: *anyopaque,
    /// The ID of the text sheet named `name`, if there is one.
    find: *const fn (ctx: *anyopaque, name: []const u8) ?u64,
    /// The cell of row `row` of sheet `id` in column `column` (by its
    /// name; null: the column the sheet shows); null when the sheet, the
    /// row or the column is not there. An empty cell is "".
    cell: *const fn (ctx: *anyopaque, id: u64, row: []const u8, column: ?[]const u8) ?[]const u8,
};

/// The sheet looked for when nothing names one.
pub const default_sheet = "Interface";

pub const Store = struct {
    gpa: std.mem.Allocator,
    /// The labels set, by element id (keys and values owned).
    values: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Every label not set is this sheet's row named by its id.
    sheet: []const u8 = default_sheet,
    sheet_owned: bool = false,
    /// The column read when a reference names none (owned); null: the
    /// sheet's shown column.
    language: ?[]const u8 = null,
    /// Sheets found by name, held by ID from then on.
    held: std.StringHashMapUnmanaged(u64) = .empty,

    pub fn deinit(s: *Store) void {
        s.clear();
        s.values.deinit(s.gpa);
        s.held.deinit(s.gpa);
    }

    /// Forgets every label set, the sheet and language, and the sheets
    /// held.
    pub fn clear(s: *Store) void {
        var it = s.values.iterator();
        while (it.next()) |e| {
            s.gpa.free(e.key_ptr.*);
            s.gpa.free(e.value_ptr.*);
        }
        s.values.clearRetainingCapacity();
        if (s.sheet_owned) s.gpa.free(s.sheet);
        s.sheet = default_sheet;
        s.sheet_owned = false;
        if (s.language) |l| s.gpa.free(l);
        s.language = null;
        s.forget();
    }

    /// Forgets the sheets held (another document is open).
    pub fn forget(s: *Store) void {
        var it = s.held.keyIterator();
        while (it.next()) |k| s.gpa.free(k.*);
        s.held.clearRetainingCapacity();
    }

    /// Sets element `id`'s label to `value` (text, or `=Sheet!row`).
    pub fn put(s: *Store, id: []const u8, value: []const u8) !void {
        const v = try s.gpa.dupe(u8, value);
        errdefer s.gpa.free(v);
        const gop = try s.values.getOrPut(s.gpa, id);
        if (gop.found_existing) {
            s.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = s.gpa.dupe(u8, id) catch |e| {
                s.values.removeByPtr(gop.key_ptr);
                return e;
            };
        }
        gop.value_ptr.* = v;
    }

    pub fn setSheet(s: *Store, name: []const u8) !void {
        const n = try s.gpa.dupe(u8, name);
        if (s.sheet_owned) s.gpa.free(s.sheet);
        s.sheet = n;
        s.sheet_owned = true;
    }

    pub fn setLanguage(s: *Store, lang: ?[]const u8) !void {
        const l = if (lang) |x| try s.gpa.dupe(u8, x) else null;
        if (s.language) |o| s.gpa.free(o);
        s.language = l;
    }

    /// Element `id`'s label: its value (text, or its cell), else the
    /// interface sheet's row named `id`, else `default` (the registry's).
    /// An empty cell is passed over for the row's default column, then
    /// for `default`.
    pub fn label(s: *Store, id: []const u8, default: []const u8, sheets: ?Sheets) []const u8 {
        const base = if (std.mem.indexOfScalar(u8, id, '#')) |k| id[0..k] else id;
        if (s.values.get(base)) |raw| switch (Value.parse(raw)) {
            .text => |t| return t,
            .cell => |c| return s.cellText(c, sheets) orelse default,
        };
        return s.cellText(.{ .sheet = s.sheet, .row = base }, sheets) orelse default;
    }

    /// Cell `c`'s text: its column, else the language in use, else the
    /// sheet's shown column; an empty cell falls back to the default
    /// column (its first). Null when there is nothing there.
    pub fn cellText(s: *Store, c: Cell, sheets: ?Sheets) ?[]const u8 {
        const sh = sheets orelse return null;
        const id = s.sheetId(c.sheet, sh) orelse return null;
        const col = c.column orelse s.language;
        if (sh.cell(sh.ctx, id, c.row, col)) |t| if (t.len > 0) return t;
        if (col != null) if (sh.cell(sh.ctx, id, c.row, null)) |t| if (t.len > 0) return t;
        if (sh.cell(sh.ctx, id, c.row, "")) |t| if (t.len > 0) return t;
        return null;
    }

    /// The sheet named `name`: found once, then held by its ID.
    fn sheetId(s: *Store, name: []const u8, sh: Sheets) ?u64 {
        if (s.held.get(name)) |id| return id;
        const id = sh.find(sh.ctx, name) orelse return null;
        const k = s.gpa.dupe(u8, name) catch return id;
        s.held.put(s.gpa, k, id) catch s.gpa.free(k);
        return id;
    }
};

const testing = std.testing;

test "a label with what it counts filled in" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Make tracks of its 6 rows", fill(&buf, "Make tracks of its {} rows", .{6}));
    try testing.expectEqualStrings("Add a STIX style", fill(&buf, "Add a {} style", .{"STIX"}));
}

test "a label's value: text, or a sheet's cell" {
    try testing.expectEqualStrings("Save", Value.parse("Save").text);
    try testing.expectEqualStrings("=x", Value.parse("==x").text);
    const c = Value.parse("=Interface!file.save").cell;
    try testing.expectEqualStrings("Interface", c.sheet);
    try testing.expectEqualStrings("file.save", c.row);
    try testing.expect(c.column == null);
    try testing.expectEqualStrings("de", Value.parse("=Interface!file.save!de").cell.column.?);
    try testing.expectEqualStrings("=Interface", Value.parse("=Interface").text);
}

/// A sheet for the tests: rows "a" and "b", columns default, de, fr;
/// renamed by changing `name` (its ID stays 7).
const Fake = struct {
    name: []const u8 = "Interface",
    shown: usize = 0,
    finds: usize = 0,
    const cols = [_][]const u8{ "Default", "de", "fr" };
    const rows = [_][3][]const u8{ .{ "Save", "Sichern", "" }, .{ "Open", "", "Ouvrir" } };

    fn find(ctx: *anyopaque, name: []const u8) ?u64 {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        f.finds += 1;
        return if (std.mem.eql(u8, name, f.name)) 7 else null;
    }
    fn cell(ctx: *anyopaque, id: u64, row: []const u8, column: ?[]const u8) ?[]const u8 {
        const f: *Fake = @ptrCast(@alignCast(ctx));
        if (id != 7) return null;
        const r: usize = if (std.mem.eql(u8, row, "a")) 0 else if (std.mem.eql(u8, row, "b")) 1 else return null;
        const c: usize = if (column) |n| blk: {
            if (n.len == 0) break :blk 0;
            for (cols, 0..) |x, i| if (std.mem.eql(u8, x, n)) break :blk i;
            return null;
        } else f.shown;
        return rows[r][c];
    }
    fn sheets(f: *Fake) Sheets {
        return .{ .ctx = f, .find = find, .cell = cell };
    }
};

test "labels: the registry's, set ones, the interface sheet's, by language" {
    var s: Store = .{ .gpa = testing.allocator };
    defer s.deinit();
    var f: Fake = .{};
    // No sheet: the registry's.
    try testing.expectEqualStrings("Keep", s.label("x", "Keep", null));
    // The interface sheet's row named by the id, its shown column.
    try testing.expectEqualStrings("Save", s.label("a", "Keep", f.sheets()));
    f.shown = 1;
    try testing.expectEqualStrings("Sichern", s.label("a#2", "Keep", f.sheets()));
    // An empty cell: the row's default.
    try testing.expectEqualStrings("Open", s.label("b", "Keep", f.sheets()));
    // A language set wins over the shown column.
    try s.setLanguage("fr");
    try testing.expectEqualStrings("Ouvrir", s.label("b", "Keep", f.sheets()));
    // A row the sheet lacks: the registry's.
    try testing.expectEqualStrings("Keep", s.label("c", "Keep", f.sheets()));
    // Set as text, or as another cell.
    try s.put("c", "Behalten");
    try testing.expectEqualStrings("Behalten", s.label("c", "Keep", f.sheets()));
    try s.put("c", "=Interface!a!de");
    try testing.expectEqualStrings("Sichern", s.label("c", "Keep", f.sheets()));
}

test "labels: a sheet found by name once, then held by its ID through a rename" {
    var s: Store = .{ .gpa = testing.allocator };
    defer s.deinit();
    var f: Fake = .{};
    try testing.expectEqualStrings("Save", s.label("a", "Keep", f.sheets()));
    const finds = f.finds;
    f.name = "Labels";
    try testing.expectEqualStrings("Save", s.label("a", "Keep", f.sheets()));
    try testing.expectEqual(finds, f.finds);
    // Another document: looked up again.
    s.forget();
    try testing.expectEqualStrings("Keep", s.label("a", "Keep", f.sheets()));
}
