//! What a manufacturing plan writes. Each plan writes its own output, part
//! by part, from the same steps its views and checks are made from
//! (`fab.madeBy`), so the files are the plan as shown:
//!
//! - a part's print: what the plan's FDM operations make of it, one 3MF
//!   (one object a colour, in the colours the plan gives, curves within
//!   the plan's tolerance), and the same as slabs for STEP through OCCT;
//! - each operation that cuts or engraves a part: one SVG, the part's
//!   frame to scale (mm), every file of a part on the same page so they
//!   register: a cutter's paths as hairlines, an engraving's areas filled.
//!
//! A panel's content is already clipped to its outline in `fab`'s steps.

const std = @import("std");
const font = @import("graven_font");
const geom = @import("graven_geom");
const model = @import("model.zig");
const place = @import("place.zig");
const fab = @import("fab.zig");
const threemf = @import("threemf.zig");
const output = @import("output.zig");
const manufacture = model.manufacture;
const Allocator = std.mem.Allocator;

pub const File = struct {
    /// Its name in the plan's folder.
    name: []const u8,
    data: []const u8,
    /// The operation it is for (an SVG); null for the part's print.
    op: ?usize = null,
};

pub const PartOutput = struct {
    files: []const File,
    /// What the FDM operations print, as slabs (for STEP through OCCT);
    /// empty when none prints this part.
    printed: []const fab.Slab = &.{},
    /// The print's file name without its extension (".3mf", ".step").
    print_stem: []const u8 = "",
};

/// A cutter's line colour and width (mm): a hairline, as laser software
/// reads a vector cut.
pub const cut_stroke = "#ff0000";
pub const cut_width = 0.01;

/// Part `panel` of plan `mp` as `placed` lays it out (`faces`: the faces
/// its labels were set in): its files. Allocated from `a` (an arena).
pub fn part(a: Allocator, m: *const model.Model, mp: manufacture.Plan, panel: usize, placed: *const place.Placed, faces: []const *font.Face) !PartOutput {
    const pn = m.panels.items[panel];
    if (mp.part(pn.id) == null) return .{ .files = &.{} };
    const name = try safe(a, pn.name);
    var files: std.ArrayList(File) = .empty;
    const n = mp.operations.len;
    var printing = try a.alloc(bool, n);
    var any_print = false;
    for (mp.operations, 0..) |op, k| {
        const kind = if (m.profileById(op.process)) |pr| pr.kind() else null;
        printing[k] = kind == .fdm and mp.touches(k, pn.id);
        if (printing[k]) any_print = true;
    }
    var out: PartOutput = .{ .files = &.{} };
    if (any_print) {
        const steps = try fab.madeBy(a, m, mp, printing, panel, placed, faces);
        const slabs = try fab.slabs(a, steps);
        const ps = try threemf.orient(a, try threemf.parts(a, slabs, mp.tolerance, .colours), .bottom);
        try files.append(a, .{ .name = try std.fmt.allocPrint(a, "{s}.3mf", .{name}), .data = try threemf.package(a, pn.name, ps) });
        out.printed = slabs;
        out.print_stem = name;
    }
    // The page every drawing of the part shares: its outline's box.
    const box = (try fab.edgeOf(a, m, panel, placed)).bounds();
    const only = try a.alloc(bool, n);
    for (mp.operations, 0..) |op, k| {
        if (printing[k] or !mp.touches(k, pn.id)) continue;
        const kind = (m.profileById(op.process) orelse continue).kind();
        @memset(only, false);
        only[k] = true;
        const steps = try fab.madeBy(a, m, mp, only, panel, placed, faces);
        // Each layer's pieces once (an inlay is two steps over the same).
        var pieces: std.ArrayList(geom.Outline) = .empty;
        var last: ?usize = null;
        for (steps) |st| {
            if (last == st.layer) continue;
            last = st.layer;
            try pieces.appendSlice(a, st.pieces);
        }
        const data = try output.svg(a, pieces.items, box, if (kind.cuts()) .{ .stroke = cut_stroke, .stroke_width = cut_width } else .{});
        try files.append(a, .{ .name = try std.fmt.allocPrint(a, "{s} {d} {s}.svg", .{ name, k + 1, try safe(a, op.name) }), .data = data, .op = k });
    }
    out.files = files.items;
    return out;
}

/// `s` fit for a file name: path separators and the characters Windows
/// refuses made dashes.
pub fn safe(a: Allocator, s: []const u8) ![]const u8 {
    const c = try a.dupe(u8, s);
    for (c) |*ch| switch (ch.*) {
        '/', '\\', ':', '*', '?', '"', '<', '>', '|' => ch.* = '-',
        else => {},
    };
    return if (c.len == 0) "part" else c;
}

/// The folder plan `mp` of a document at `doc_path` writes to: beside the
/// document, named for it and the plan ("hp15c Plan1"); for an untitled
/// document, the plan's name in the working folder.
pub fn folder(a: Allocator, doc_path: ?[]const u8, mp: manufacture.Plan) ![]const u8 {
    const plan_name = try safe(a, mp.name);
    const fp = doc_path orelse return plan_name;
    const dir = std.fs.path.dirname(fp) orelse "";
    const base = std.fs.path.basename(fp);
    const stem = base[0 .. base.len - std.fs.path.extension(base).len];
    const leaf = try std.fmt.allocPrint(a, "{s} {s}", .{ stem, plan_name });
    return if (dir.len > 0) try std.fs.path.join(a, &.{ dir, leaf }) else leaf;
}
