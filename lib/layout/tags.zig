//! Tags: what kind of thing a drawn item is (construction geometry, the
//! ink of a drawing, a dimension …), so that a layer can show or hide
//! each kind of thing on it (the owner, 2026-11-26: visibility options
//! for the kinds of tagged geometry in the same layer).
//!
//! One mechanism for every kind: an item says which tags it carries
//! (`ofGeometry` for a sketch's geometry; a drawer names the tag of what
//! it draws), a layer holds the set it hides (`Layer.hidden`), and an
//! item is drawn when none of its tags is hidden (`Tags.shows`). A new
//! kind is a new tag here, nothing more; the Layers panel and the
//! presets list them from this enum.
//!
//! Tags only say what is drawn on the screen: output is decided by what
//! is output (ink, panels), never by them.

const std = @import("std");
const sketch = @import("graven_sketch");

/// The kinds. Stored by number in a layer's mask: add new ones at the end.
pub const Tag = enum(u5) {
    /// A sketch's geometry that is not construction: its drawn lines and
    /// curves (connections included).
    edges,
    /// Construction geometry: guides, a polygon's circles, an array's
    /// lattice, infinite lines and rays.
    construction,
    /// Points: lone points and the ends and centres of lines and curves.
    points,
    /// The ink of a drawing: its strokes and fills, as it will be output.
    ink,
    /// Constraint marks: coincident rings, H, V, tangent and the rest.
    constraints,
    /// Dimensions: driving and reference, their lines and values.
    dimensions,
    /// A sketch's origin, its axes and its box.
    frame,

    pub fn label(t: Tag) []const u8 {
        return switch (t) {
            .edges => "Lines and curves",
            .construction => "Construction",
            .points => "Points",
            .ink => "Ink",
            .constraints => "Constraint marks",
            .dimensions => "Dimensions",
            .frame => "Origin, axes and box",
        };
    }

    /// Its name in the interface's ids (kebab-case).
    pub fn id(t: Tag) []const u8 {
        return switch (t) {
            .edges => "edges",
            .construction => "construction",
            .points => "points",
            .ink => "ink",
            .constraints => "constraints",
            .dimensions => "dimensions",
            .frame => "frame",
        };
    }
};

/// A set of tags.
pub const Tags = struct {
    mask: u32 = 0,

    pub const none: Tags = .{};
    pub const all: Tags = blk: {
        var m: u32 = 0;
        for (std.enums.values(Tag)) |t| m |= bit(t);
        break :blk .{ .mask = m };
    };

    fn bit(t: Tag) u32 {
        return @as(u32, 1) << @intFromEnum(t);
    }

    pub fn one(t: Tag) Tags {
        return .{ .mask = bit(t) };
    }

    pub fn has(s: Tags, t: Tag) bool {
        return s.mask & bit(t) != 0;
    }

    pub fn with(s: Tags, t: Tag) Tags {
        return .{ .mask = s.mask | bit(t) };
    }

    pub fn without(s: Tags, t: Tag) Tags {
        return .{ .mask = s.mask & ~bit(t) };
    }

    pub fn toggled(s: Tags, t: Tag) Tags {
        return .{ .mask = s.mask ^ bit(t) };
    }

    /// With every one of `o`'s too.
    pub fn plus(s: Tags, o: Tags) Tags {
        return .{ .mask = s.mask | o.mask };
    }

    pub fn eql(s: Tags, o: Tags) bool {
        return s.mask & all.mask == o.mask & all.mask;
    }

    /// With this set hidden, whether an item carrying `of` is drawn: none
    /// of its tags hidden. An item with no tags is always drawn.
    pub fn shows(hidden: Tags, of: Tags) bool {
        return hidden.mask & of.mask == 0;
    }

    /// With this set hidden, whether things tagged `t` are drawn.
    pub fn showsTag(hidden: Tags, t: Tag) bool {
        return !hidden.has(t);
    }
};

/// A named choice of what a layer hides.
pub const Preset = enum {
    /// Everything shown.
    everything,
    /// The ink alone: the drawing as it will be output.
    ink_only,
    /// The sketch without its ink.
    sketch_only,

    pub fn hidden(p: Preset) Tags {
        return switch (p) {
            .everything => Tags.none,
            .ink_only => Tags.all.without(.ink),
            .sketch_only => Tags.one(.ink),
        };
    }

    pub fn label(p: Preset) []const u8 {
        return switch (p) {
            .everything => "Everything",
            .ink_only => "Ink only",
            .sketch_only => "Sketch only",
        };
    }

    /// The preset this hidden set is, if any.
    pub fn of(h: Tags) ?Preset {
        for (std.enums.values(Preset)) |p| if (p.hidden().eql(h)) return p;
        return null;
    }
};

/// The tags of a sketch's geometry `g` (its curve; its points carry
/// `points`): construction or edges; the origin and axes, frame.
pub fn ofGeometry(g: sketch.Geometry) Tags {
    if (g.reference) return Tags.one(.frame);
    if (g.kind == .point) return Tags.one(.points).plus(if (g.construction) Tags.one(.construction) else Tags.none);
    return Tags.one(if (g.construction) .construction else .edges);
}

test "a preset is the set it hides" {
    try std.testing.expectEqual(Preset.ink_only, Preset.of(Preset.ink_only.hidden()).?);
    try std.testing.expect(Preset.ink_only.hidden().shows(Tags.one(.ink)));
    try std.testing.expect(!Preset.ink_only.hidden().shows(Tags.one(.construction)));
    try std.testing.expect(!Tags.one(.construction).shows(Tags.one(.points).with(.construction)));
    try std.testing.expect(Tags.none.shows(Tags.all));
}
