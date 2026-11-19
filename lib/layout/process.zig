//! Manufacturing process profiles: how a part is made, and what that way
//! of making can hold, for the manufacture stage's checks (decided
//! 2026-11-16: the design describes the ideal; the checks say where it is
//! out of a process's reach, pass, marginal or fail, never changing it).
//!
//! Two levels: a class (additive, subtractive, formed, finishing), which
//! says what the process does to material, and a process within it (FDM,
//! for now), whose parameters a profile sets: one machine and setting,
//! "Generic FDM, 0.2 mm nozzle". A profile's limits come from its
//! parameters unless it overrides them.
//!
//! A document keeps the profiles its panels are made with, so a file is
//! whole on its own; the built-ins here are where they start.

const std = @import("std");

pub const Class = enum {
    /// Material laid down where it is wanted: FDM, SLA.
    additive,
    /// Material cut away: milling, laser engraving.
    subtractive,
    /// Material shaped: moulding, forming.
    formed,
    /// A surface applied to a part: pad, screen or UV printing, anodising.
    finishing,

    pub fn label(c: Class) []const u8 {
        return switch (c) {
            .additive => "Additive",
            .subtractive => "Subtractive",
            .formed => "Formed",
            .finishing => "Finishing",
        };
    }
};

/// The processes Graven knows, each in its class.
pub const Kind = enum {
    /// Fused deposition: filament extruded through a nozzle, layer by
    /// layer; colours from more than one filament.
    fdm,

    pub fn class(k: Kind) Class {
        return switch (k) {
            .fdm => .additive,
        };
    }

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .fdm => "FDM (fused deposition)",
        };
    }
};

/// FDM's settings: the machine's, and the print's.
pub const Fdm = struct {
    /// Nozzle diameter, mm.
    nozzle: f64 = 0.4,
    /// Extrusion line width, mm: what one wall is.
    line_width: f64 = 0.42,
    /// Layer height, mm, and the first layer's.
    layer_height: f64 = 0.2,
    first_layer: f64 = 0.2,
    /// How many filaments (colours) one print can use: an AMS's four.
    slots: u32 = 4,
    /// The build volume, mm: across, deep, high.
    build: [3]f64 = .{ 256, 256, 256 },
};

pub const Params = union(Kind) {
    fdm: Fdm,
};

/// A limit on a measure where less is worse (a stroke's width, a gap, a
/// cap height): at or above `pass` passes; below `fail` fails; between,
/// marginal.
pub const Band = struct {
    pass: f64,
    fail: f64,

    pub const Verdict = enum { pass, marginal, fail };

    pub fn judge(b: Band, value: f64) Verdict {
        if (value >= b.pass) return .pass;
        if (value < b.fail) return .fail;
        return .marginal;
    }

    pub fn valid(b: Band) bool {
        return b.fail >= 0 and b.pass >= b.fail;
    }
};

/// What a profile's checks measure against.
pub const Limits = struct {
    /// A stroke's width (a legend's ink, a wall).
    stroke: Band,
    /// A gap's width (between strokes, inside a counter).
    gap: Band,
    /// A legend's cap height.
    cap: Band,
    /// An inlay or a cut is a whole number of layers this high, at least
    /// this many of them; null where the process has no layers.
    layer: ?f64,
    min_layers: u32,
    /// The most colours one part may have; the build volume.
    colours: u32,
    build: [3]f64,
};

pub const Profile = struct {
    name: []const u8,
    params: Params,
    /// Overrides of the limits the parameters give.
    stroke: ?Band = null,
    gap: ?Band = null,
    cap: ?Band = null,

    pub fn kind(p: Profile) Kind {
        return std.meta.activeTag(p.params);
    }

    pub fn class(p: Profile) Class {
        return p.kind().class();
    }

    /// The limits: from the parameters, each overridden where the profile
    /// says so.
    pub fn limits(p: Profile) Limits {
        var l = derived(p.params);
        if (p.stroke) |b| l.stroke = b;
        if (p.gap) |b| l.gap = b;
        if (p.cap) |b| l.cap = b;
        return l;
    }

    /// Whether its settings can be made with: positive sizes, bands in
    /// order.
    pub fn valid(p: Profile) bool {
        switch (p.params) {
            .fdm => |f| {
                if (!(f.nozzle > 0) or !(f.line_width > 0) or !(f.layer_height > 0) or !(f.first_layer > 0)) return false;
                if (f.slots == 0) return false;
                for (f.build) |b| if (!(b > 0)) return false;
            },
        }
        for ([_]?Band{ p.stroke, p.gap, p.cap }) |b| if (b) |x| if (!x.valid()) return false;
        return true;
    }
};

/// The limits a process's parameters give. FDM: a stroke passes at a
/// line's width (one wall) and fails below half the nozzle (what a slicer
/// can still lay as a thin wall); a gap passes at the nozzle's width and
/// fails below half of it; a cap height passes at 3.75 nozzles (1.5 mm
/// with 0.4) and fails below 2.5 (1.0 mm); inlays and cuts are whole
/// layers, two at least; as many colours as filament slots.
pub fn derived(params: Params) Limits {
    return switch (params) {
        .fdm => |f| .{
            .stroke = .{ .pass = f.line_width, .fail = f.nozzle * 0.5 },
            .gap = .{ .pass = f.nozzle, .fail = f.nozzle * 0.5 },
            .cap = .{ .pass = f.nozzle * 3.75, .fail = f.nozzle * 2.5 },
            .layer = f.layer_height,
            .min_layers = 2,
            .colours = f.slots,
            .build = f.build,
        },
    };
}

/// The profiles Graven starts from: generic FDM with the common nozzles,
/// each at its usual line width and a layer half the nozzle.
pub const builtins = [_]Profile{
    .{ .name = "Generic FDM, 0.2 mm nozzle", .params = .{ .fdm = .{ .nozzle = 0.2, .line_width = 0.22, .layer_height = 0.1, .first_layer = 0.1 } } },
    .{ .name = "Generic FDM, 0.4 mm nozzle", .params = .{ .fdm = .{} } },
    .{ .name = "Generic FDM, 0.6 mm nozzle", .params = .{ .fdm = .{ .nozzle = 0.6, .line_width = 0.62, .layer_height = 0.3, .first_layer = 0.3 } } },
    .{ .name = "Generic FDM, 0.8 mm nozzle", .params = .{ .fdm = .{ .nozzle = 0.8, .line_width = 0.82, .layer_height = 0.4, .first_layer = 0.4 } } },
};

/// The built-in named `name`, or null.
pub fn builtin(name: []const u8) ?Profile {
    for (builtins) |p| if (std.mem.eql(u8, p.name, name)) return p;
    return null;
}

const testing = std.testing;

test "every built-in is FDM, additive and sound; finer nozzles reach finer strokes" {
    for (builtins) |p| {
        try testing.expect(p.valid());
        try testing.expectEqual(Class.additive, p.class());
    }
    const fine = builtin("Generic FDM, 0.2 mm nozzle").?.limits();
    const usual = builtin("Generic FDM, 0.4 mm nozzle").?.limits();
    try testing.expect(fine.stroke.pass < usual.stroke.pass);
    try testing.expectEqual(@as(?f64, 0.1), fine.layer);
    try testing.expectApproxEqAbs(1.5, usual.cap.pass, 1e-12);
    try testing.expectApproxEqAbs(1.0, usual.cap.fail, 1e-12);
}

test "a band judges: pass, marginal, fail" {
    const b: Band = .{ .pass = 0.42, .fail = 0.2 };
    try testing.expectEqual(Band.Verdict.pass, b.judge(0.42));
    try testing.expectEqual(Band.Verdict.marginal, b.judge(0.3));
    try testing.expectEqual(Band.Verdict.fail, b.judge(0.19));
    try testing.expect(!(Band{ .pass = 0.1, .fail = 0.2 }).valid());
}

test "a profile's overrides win over what its parameters give" {
    var p = builtin("Generic FDM, 0.4 mm nozzle").?;
    p.stroke = .{ .pass = 0.3, .fail = 0.15 };
    try testing.expectEqual(0.3, p.limits().stroke.pass);
    try testing.expectEqual(0.4, p.limits().gap.pass);
    p.params.fdm.slots = 0;
    try testing.expect(!p.valid());
}
