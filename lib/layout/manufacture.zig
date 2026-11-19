//! Manufacturing plans (decided 2026-11-19): how a product is made, kept
//! apart from what it is. The design says what each shape is (a panel's
//! outline, its holes, its parts, its legends by slot) and how the stackup
//! extrudes them (`model.Fab`'s layers); a plan says what each part is made
//! of and the operations that make it: a panel waterjet cut, its legends
//! laser engraved, or the whole printed in four filaments.
//!
//! A plan spans one or more panels (its parts), each with a material.
//! Operations run in the order given (free, decided by the owner): each a
//! process profile, applied to stackup layers of any of the plan's parts,
//! with a colour for what it makes where the process can give one. An
//! order a process makes doubtful, a material it cannot work, a colour it
//! cannot give there: flagged, never refused (`warnings`).
//!
//! Colour for solid geometry belongs here, not in the design: what a laser
//! can show on black anodised aluminium (bare metal) is not what it shows
//! on birch (char), and FDM gives the filaments loaded. `results` says
//! what a process can give on a material, the data a manufacturing advisor
//! will later recommend from.
//!
//! Materials, like profiles, are copied into the document from the
//! library here when first used, so a file is whole on its own.

const std = @import("std");
const model = @import("model.zig");
const process = @import("process.zig");
const art = @import("art.zig");

const Allocator = std.mem.Allocator;
const ObjectId = model.ObjectId;
const Color = art.Color;

pub const MaterialKind = enum {
    polymer,
    metal,
    wood,
    paper,
    glass,
    stone,

    pub fn label(k: MaterialKind) []const u8 {
        return switch (k) {
            .polymer => "Polymer",
            .metal => "Metal",
            .wood => "Wood",
            .paper => "Paper and card",
            .glass => "Glass",
            .stone => "Stone",
        };
    }
};

/// How the stock comes.
pub const Form = enum {
    /// Wound filament, for FDM.
    filament,
    /// Flat sheet or plate, in `thicknesses`.
    sheet,
    /// A block, machined.
    block,

    pub fn label(f: Form) []const u8 {
        return switch (f) {
            .filament => "Filament",
            .sheet => "Sheet",
            .block => "Block",
        };
    }
};

/// The surface it comes with, which decides what marking shows.
pub const Surface = enum {
    /// The material throughout.
    bare,
    /// Anodised (aluminium): a dyed layer over bare metal.
    anodised,
    /// Painted or powder coated.
    coated,
    /// A two-colour laminate: a thin cap over a core of another colour.
    laminate,

    pub fn label(s: Surface) []const u8 {
        return switch (s) {
            .bare => "Bare",
            .anodised => "Anodised",
            .coated => "Coated",
            .laminate => "Two-colour laminate",
        };
    }
};

/// A named colour: a finish a material comes in, or what a process makes.
pub const Finish = model.FabColour;

pub const Material = struct {
    name: []const u8,
    kind: MaterialKind,
    form: Form,
    surface: Surface = .bare,
    /// The colours (finishes) it comes in.
    finishes: []const Finish = &.{},
    /// Under the surface: an anodised part's metal, a laminate's core.
    core: ?Finish = null,
    /// The thicknesses it is stocked in, mm (sheet).
    thicknesses: []const f64 = &.{},

    pub fn valid(m: Material) bool {
        if (m.name.len == 0) return false;
        for (m.thicknesses) |t| if (!(t > 0)) return false;
        return true;
    }
};

/// A material the document keeps.
pub const DocMaterial = struct {
    id: ObjectId = .none,
    material: Material,
};

fn rgb(r: u8, g: u8, b: u8) Color {
    return .{ .r = r, .g = g, .b = b };
}

const black: Finish = .{ .name = "black", .color = rgb(0x1e, 0x1e, 0x1e) };
const white: Finish = .{ .name = "white", .color = rgb(0xf4, 0xf4, 0xf0) };
const clear: Finish = .{ .name = "clear", .color = rgb(0xe8, 0xf0, 0xf2) };
const silver: Finish = .{ .name = "bare aluminium", .color = rgb(0xc8, 0xcc, 0xd0) };

/// The materials Graven starts from.
pub const library = [_]Material{
    .{ .name = "PLA", .kind = .polymer, .form = .filament, .finishes = &.{ black, white, .{ .name = "grey", .color = rgb(0x80, 0x80, 0x80) }, .{ .name = "red", .color = rgb(0xc8, 0x20, 0x20) }, .{ .name = "blue", .color = rgb(0x3a, 0x7b, 0xd5) }, .{ .name = "yellow", .color = rgb(0xf0, 0xc8, 0x20) }, .{ .name = "gold", .color = rgb(0xc9, 0xa2, 0x27) } } },
    .{ .name = "PETG", .kind = .polymer, .form = .filament, .finishes = &.{ black, white, clear } },
    .{ .name = "Cast acrylic", .kind = .polymer, .form = .sheet, .finishes = &.{ clear, black, white, .{ .name = "red", .color = rgb(0xc8, 0x20, 0x20) } }, .thicknesses = &.{ 2, 3, 5 } },
    .{ .name = "Engraving laminate, black over white", .kind = .polymer, .form = .sheet, .surface = .laminate, .finishes = &.{black}, .core = white, .thicknesses = &.{1.6} },
    .{ .name = "Aluminium 5052, black anodised", .kind = .metal, .form = .sheet, .surface = .anodised, .finishes = &.{black}, .core = silver, .thicknesses = &.{ 1.5, 2, 3 } },
    .{ .name = "Stainless steel 304", .kind = .metal, .form = .sheet, .finishes = &.{.{ .name = "brushed steel", .color = rgb(0xb4, 0xb8, 0xbc) }}, .thicknesses = &.{ 1, 1.5, 2 } },
    .{ .name = "Birch plywood", .kind = .wood, .form = .sheet, .finishes = &.{.{ .name = "birch", .color = rgb(0xe2, 0xc9, 0x9a) }}, .thicknesses = &.{ 3, 6 } },
};

/// The library's material named `name`, or null.
pub fn libraryMaterial(name: []const u8) ?Material {
    for (library) |m| if (std.mem.eql(u8, m.name, name)) return m;
    return null;
}

/// How well a process suits a material.
pub const Fit = enum {
    /// It works it as intended.
    good,
    /// It can, with care or a poorer result.
    poor,
    /// It cannot (or must not: a CO2 laser on metal).
    no,
};

/// Whether process `kind` can work material `m`, and why not.
pub fn fit(kind: process.Kind, m: Material) struct { fit: Fit, why: []const u8 = "" } {
    return switch (kind) {
        .fdm => if (m.form == .filament) .{ .fit = .good } else .{ .fit = .no, .why = "FDM prints filament, not sheet or block" },
        .laser_cut => switch (m.kind) {
            .polymer, .wood, .paper => if (m.form == .sheet) .{ .fit = .good } else .{ .fit = .no, .why = "a laser cuts sheet" },
            .metal => .{ .fit = .no, .why = "a CO2 laser does not cut metal (a fibre laser or a waterjet does)" },
            .glass, .stone => .{ .fit = .no, .why = "a laser cracks glass and stone rather than cutting them" },
        },
        .laser_engrave => switch (m.kind) {
            .polymer, .wood, .paper, .stone => .{ .fit = .good },
            .metal => if (m.surface == .anodised or m.surface == .coated) .{ .fit = .good } else .{ .fit = .poor, .why = "bare metal marks dark only with a fibre laser" },
            .glass => .{ .fit = .poor, .why = "glass frosts, with a risk of chipping" },
        },
        .waterjet => switch (m.form) {
            .sheet, .block => if (m.kind == .paper) .{ .fit = .poor, .why = "water soaks paper and card" } else .{ .fit = .good },
            .filament => .{ .fit = .no, .why = "a waterjet cuts sheet and plate" },
        },
    };
}

/// The colours process `kind` can give on material `m`: what an operation
/// may assign. Cutting gives none of its own (the material shows).
pub fn results(a: Allocator, kind: process.Kind, m: Material) Allocator.Error![]const Finish {
    var out: std.ArrayList(Finish) = .empty;
    switch (kind) {
        .fdm => try out.appendSlice(a, m.finishes),
        .laser_cut, .waterjet => {},
        .laser_engrave => switch (m.surface) {
            // The coat taken off: what is under it.
            .anodised, .coated, .laminate => if (m.core) |c| try out.append(a, c),
            .bare => switch (m.kind) {
                .wood, .paper => try out.appendSlice(a, &.{ .{ .name = "light char", .color = rgb(0xa8, 0x7a, 0x4a) }, .{ .name = "dark char", .color = rgb(0x4a, 0x30, 0x1c) } }),
                .polymer, .glass, .stone => try out.append(a, .{ .name = "frosted", .color = rgb(0xe6, 0xe8, 0xea) }),
                .metal => try out.append(a, .{ .name = "dark mark", .color = rgb(0x38, 0x38, 0x3c) }),
            },
        },
    }
    return out.items;
}

/// A part of a plan: a panel, and what it is made of.
pub const Part = struct {
    panel: ObjectId,
    material: ObjectId = .none,
};

/// What an operation works on: a panel's stackup layer (by name), and the
/// colour it gives there, where it gives one.
pub const Target = struct {
    panel: ObjectId,
    layer: []const u8,
    colour: ?Finish = null,
};

pub const Operation = struct {
    name: []const u8,
    /// A process profile of the document's.
    process: ObjectId,
    targets: []const Target = &.{},
    /// Repeats over the same path (engraving deeper, cutting thicker).
    passes: u32 = 1,
};

pub const Plan = struct {
    id: ObjectId = .none,
    name: []const u8,
    parts: []const Part = &.{},
    /// In the order they are done.
    operations: []const Operation = &.{},

    pub fn part(p: Plan, panel: ObjectId) ?Part {
        for (p.parts) |pt| if (pt.panel == panel) return pt;
        return null;
    }
};

/// Something about a plan worth a second look; never a refusal.
pub const Warning = struct {
    kind: enum {
        /// A part names no material.
        no_material,
        /// An operation's process cannot work (or works poorly) a part's
        /// material; `why` says why.
        unsuited,
        /// An operation gives a colour its process cannot give on that
        /// material.
        colour_unavailable,
        /// Marking or engraving a part after it was cut free: it may
        /// move. (Engrave first, then cut.)
        mark_after_cut,
        /// An operation works on a panel that is not one of the plan's
        /// parts, or on a stackup layer the panel does not have.
        no_such_target,
        /// A stackup layer of a part that no operation makes.
        unmade_layer,
        /// The part is thicker than the process can cut through.
        too_thick,
        /// The operation's process profile is not the document's.
        no_process,
    },
    operation: ?usize = null,
    /// The panel it is about.
    panel: ObjectId = .none,
    layer: []const u8 = "",
    why: []const u8 = "",
};

/// What is worth a second look in plan `p` of model `m`.
pub fn warnings(a: Allocator, m: *const model.Model, p: Plan) Allocator.Error![]const Warning {
    var out: std.ArrayList(Warning) = .empty;
    for (p.parts) |pt| {
        if (m.materialIndex(pt.material) == null) try out.append(a, .{ .kind = .no_material, .panel = pt.panel });
    }
    for (p.operations, 0..) |op, oi| {
        const prof = m.profileById(op.process) orelse {
            try out.append(a, .{ .kind = .no_process, .operation = oi });
            continue;
        };
        const kind = prof.kind();
        for (op.targets) |t| {
            const pt = p.part(t.panel) orelse {
                try out.append(a, .{ .kind = .no_such_target, .operation = oi, .panel = t.panel });
                continue;
            };
            const pi = m.panelIndex(t.panel) orelse {
                try out.append(a, .{ .kind = .no_such_target, .operation = oi, .panel = t.panel });
                continue;
            };
            const fab = m.panels.items[pi].fab;
            const has_layer = for (fab.layers) |l| {
                if (std.mem.eql(u8, l.name, t.layer)) break true;
            } else false;
            if (!has_layer) try out.append(a, .{ .kind = .no_such_target, .operation = oi, .panel = t.panel, .layer = t.layer });
            const mi = m.materialIndex(pt.material) orelse continue;
            const mat = m.materials.items[mi].material;
            const f = fit(kind, mat);
            if (f.fit != .good) try out.append(a, .{ .kind = .unsuited, .operation = oi, .panel = t.panel, .layer = t.layer, .why = f.why });
            if (t.colour) |col| {
                const can = try results(a, kind, mat);
                const ok = for (can) |c| {
                    if (std.mem.eql(u8, c.name, col.name)) break true;
                } else false;
                if (!ok) try out.append(a, .{ .kind = .colour_unavailable, .operation = oi, .panel = t.panel, .layer = t.layer });
            }
            const thickest: ?f64 = switch (prof.params) {
                .laser_cut => |l| l.max_thickness,
                .waterjet => |w| w.max_thickness,
                else => null,
            };
            if (thickest) |th| if (fab.thickness > th + 1e-9) try out.append(a, .{ .kind = .too_thick, .operation = oi, .panel = t.panel });
            // Marked after this part was cut free by an earlier operation.
            if (!kind.cuts()) for (p.operations[0..oi]) |earlier| {
                const ep = m.profileById(earlier.process) orelse continue;
                if (!ep.kind().cuts()) continue;
                const same = for (earlier.targets) |et| {
                    if (et.panel == t.panel) break true;
                } else false;
                if (same) {
                    try out.append(a, .{ .kind = .mark_after_cut, .operation = oi, .panel = t.panel, .layer = t.layer });
                    break;
                }
            };
        }
    }
    // Every part's stackup layers made by some operation.
    for (p.parts) |pt| {
        const pi = m.panelIndex(pt.panel) orelse continue;
        for (m.panels.items[pi].fab.layers) |l| {
            const made = made: {
                for (p.operations) |op| for (op.targets) |t| {
                    if (t.panel == pt.panel and std.mem.eql(u8, t.layer, l.name)) break :made true;
                };
                break :made false;
            };
            if (!made) try out.append(a, .{ .kind = .unmade_layer, .panel = pt.panel, .layer = l.name });
        }
    }
    return out.items;
}

const testing = std.testing;

test "the library: sound materials; what fits what" {
    for (library) |m| try testing.expect(m.valid());
    const pla = libraryMaterial("PLA").?;
    const alu = libraryMaterial("Aluminium 5052, black anodised").?;
    const birch = libraryMaterial("Birch plywood").?;
    try testing.expectEqual(Fit.good, fit(.fdm, pla).fit);
    try testing.expectEqual(Fit.no, fit(.fdm, alu).fit);
    try testing.expectEqual(Fit.no, fit(.laser_cut, alu).fit);
    try testing.expectEqual(Fit.good, fit(.waterjet, alu).fit);
    try testing.expectEqual(Fit.good, fit(.laser_engrave, alu).fit);
    try testing.expectEqual(Fit.good, fit(.laser_cut, birch).fit);
}

test "what a process gives on a material: anodising bared, wood charred, filaments as loaded, cuts nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const alu = try results(a, .laser_engrave, libraryMaterial("Aluminium 5052, black anodised").?);
    try testing.expectEqual(1, alu.len);
    try testing.expectEqualStrings("bare aluminium", alu[0].name);
    const lam = try results(a, .laser_engrave, libraryMaterial("Engraving laminate, black over white").?);
    try testing.expectEqualStrings("white", lam[0].name);
    try testing.expectEqual(2, (try results(a, .laser_engrave, libraryMaterial("Birch plywood").?)).len);
    try testing.expectEqual(7, (try results(a, .fdm, libraryMaterial("PLA").?)).len);
    try testing.expectEqual(0, (try results(a, .waterjet, libraryMaterial("Stainless steel 304").?)).len);
}
