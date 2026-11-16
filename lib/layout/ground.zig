//! The ground for engine v2 (graven_glyphic) on a panel's tracks: each
//! segment a track's flow reaches, as a piece of glyphic ground.
//!
//! Built from the flow pass's own parts (place.zig: `Path` makes the
//! segments, `KeepOut` closes what art covers, `lineIn` gives a
//! paragraph's indents, `baselineIn` puts the baseline), so v1 and v2 can
//! never disagree about where a segment is or what is open in it.
//!
//! Segments are straight: a track's path bends the stack of segments, not
//! each one. A row's baseline runs right; a column's runs down, its up to
//! the right. Curved segments come in stage 5 through the same interface.

const std = @import("std");
const glyphic = @import("graven_glyphic");
const engine = @import("graven_engine");
const model = @import("model.zig");
const place = @import("place.zig");

const Allocator = std.mem.Allocator;
const Box = engine.geom.Box;
const G = glyphic.ground;

/// The ground of a flow's leg on one panel: from track `track` (the leg's
/// first track here: a thread's head, or where the thread enters this
/// panel) through the tracks threaded after it on the same panel.
pub const TrackGround = struct {
    arena: std.heap.ArenaAllocator,
    m: *const model.Model,
    labels: *const place.Labels,
    panel: usize,
    path: place.Path,
    keepouts: []const place.KeepOut,
    /// The flow's first paragraph style, for the first piece's indents.
    paragraph: ?model.ParagraphStyle,
    pieces: std.ArrayList(G.Piece) = .empty,
    /// Each piece's band, mm in the panel frame, as v1 places it.
    bands: std.ArrayList(Box) = .empty,
    /// Whether each piece lies past the room its track was drawn for.
    beyond: std.ArrayList(bool) = .empty,

    /// `placed` is the panel as solved, for the tracks placed before this
    /// one (segments are kept clear of them) and nothing else; null when
    /// there are none to keep clear of.
    pub fn init(gpa: Allocator, m: *const model.Model, labels: *const place.Labels, panel: usize, track: usize, placed: ?*const place.Placed) Allocator.Error!*TrackGround {
        const g = try gpa.create(TrackGround);
        errdefer gpa.destroy(g);
        g.* = .{ .arena = .init(gpa), .m = m, .labels = labels, .panel = panel, .path = undefined, .keepouts = &.{}, .paragraph = null };
        errdefer g.arena.deinit();
        const a = g.arena.allocator();
        const regions = m.panels.items[panel].regions.items;

        // The leg: this track and those threaded after it on this panel.
        const head = m.threadHead(panel, track);
        var all_buf: [256]model.TrackRef = undefined;
        const all = m.thread(head, &all_buf);
        var leg: std.ArrayList(usize) = .empty;
        var k: usize = 0;
        while (k < all.len and !(all[k].panel == panel and all[k].region == track)) k += 1;
        while (k < all.len and all[k].panel == panel) : (k += 1) try leg.append(a, all[k].region);
        if (leg.items.len == 0) try leg.append(a, track);
        const more = k < all.len;

        // Tracks placed before this one on the panel, to keep clear of.
        var avoid: std.ArrayList(place.PlacedTrack) = .empty;
        if (placed) |pl| for (pl.tracks) |t| {
            if (t.panel == panel and t.member < track) try avoid.append(a, t);
        };
        // What art on the panel closes.
        var keep: std.ArrayList(place.KeepOut) = .empty;
        for (m.panels.items[panel].art.items) |pa| {
            if (pa.wrap == .none or !pa.wrap_tracks) continue;
            try keep.append(a, try place.KeepOut.of(a, pa));
        }
        g.keepouts = keep.items;
        g.path = .{ .regions = regions, .thread = leg.items, .avoid = avoid.items, .more = more };
        // The flow's first paragraph, when the flow starts here.
        const flow = &m.panels.items[head.panel].regions.items[head.region];
        if (head.panel == panel and head.region == track) {
            if (flow.paragraph) |id| if (m.paraStyle(id)) |ps| {
                g.paragraph = ps.*;
            };
        }
        return g;
    }

    pub fn deinit(g: *TrackGround) void {
        const gpa = g.arena.child_allocator;
        g.arena.deinit();
        gpa.destroy(g);
    }

    pub fn ground(g: *TrackGround) G.Ground {
        return .{ .ctx = g, .vtable = &.{ .piece = pieceFn, .more = moreFn } };
    }

    fn moreFn(ctx: *anyopaque) bool {
        const g: *TrackGround = @ptrCast(@alignCast(ctx));
        return g.path.more;
    }

    fn pieceFn(ctx: *anyopaque, k: usize, lead: f64) ?G.Piece {
        const g: *TrackGround = @ptrCast(@alignCast(ctx));
        while (g.pieces.items.len <= k) {
            const made = g.make(lead) catch return null;
            if (!made) return null;
        }
        return g.pieces.items[k];
    }

    /// Makes the next piece; false when the flow leaves this panel instead.
    fn make(g: *TrackGround, lead: f64) Allocator.Error!bool {
        const a = g.arena.allocator();
        const n = g.pieces.items.len;
        if (n > 0) g.path.lead = lead;
        if (g.path.leaves(n)) return false;
        try g.path.ensure(a, n);
        const region = g.path.regionOf(n);
        const band = g.path.boxes.items[n];
        const rows = region.major == .row;
        const length = place.segLength(&g.path, rows, n);
        // What art closes, and what the paragraph's indents leave.
        var closed: std.ArrayList([2]f64) = .empty;
        for (g.keepouts) |ko| try ko.closes(a, rows, band, &closed);
        const shut = try a.alloc(G.Span, closed.items.len);
        for (closed.items, shut) |c, *s| s.* = .{ .lo = c[0], .hi = c[1] };
        const line = place.lineIn(if (n == 0) g.paragraph else null, n == 0, length);
        const open = try G.openSpans(a, line.lo, line.hi, shut);
        const cap = place.trackCap(g.m, g.labels, region.*);
        const alignment: G.Align = if (line.alignment) |al| switch (al) {
            .start => .start,
            .centre => .centre,
            .end => .end,
            .justify => .justify,
        } else switch (region.alignment) {
            .start => .start,
            .centre => .centre,
            .end => .end,
        };
        const piece: G.Piece = if (rows) blk: {
            const y = place.baselineIn(band, cap);
            break :blk .{
                .baseline = .{ .line = .{ .start = .{ .x = band.x0, .y = y }, .dir = .{ .x = 1, .y = 0 } } },
                .length = length,
                .open = open,
                .above = band.y1 - y,
                .below = y - band.y0,
                .cap = cap,
                .alignment = alignment,
            };
        } else .{
            // A column: down its middle, its up to the right.
            .baseline = .{ .line = .{ .start = .{ .x = (band.x0 + band.x1) / 2, .y = band.y1 }, .dir = .{ .x = 0, .y = -1 } } },
            .length = length,
            .open = open,
            .above = band.width() / 2,
            .below = band.width() / 2,
            .cap = cap,
            .alignment = alignment,
        };
        try g.pieces.append(a, piece);
        try g.bands.append(a, band);
        try g.beyond.append(a, g.path.origins.items[n].across + 1 > region.crossLength() + 1e-9);
        return true;
    }
};

// Tests ---------------------------------------------------------------------------

const testing = std.testing;
const testdata = @import("graven_testdata");
const art = @import("art.zig");
const native = @import("native.zig");

fn near(want: f64, got: f64) !void {
    try testing.expectApproxEqAbs(want, got, 1e-9);
}

test "a row track's pieces are v1's segments: same bands, baselines where v1 sets text" {
    const gpa = testing.allocator;
    const face = try engine.Face.init(gpa, testdata.truetype, 0);
    defer face.deinit();
    const faces = [_]*engine.Face{face};
    var m: model.Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("label", .{ .upright = 0, .cap_height = 3 });
    const p = try m.addPanel("board", 100, 60);
    const r = try m.addTracks(p, .{ .name = "text", .origin = .{ .x = 10, .y = 50 }, .style = style, .count = 3, .length = 5, .pitch = 6 });
    // Enough words for several 30 mm rows.
    try m.insertRun(p, r, 0, .{ .style = style, .content = "HOH HOH HOH HOH HOH HOH HOH HOH HOH" });
    var labels: place.Labels = .init(gpa, &faces);
    defer labels.deinit();
    var s = try place.solve(gpa, &m, p, &labels);
    defer s.deinit();
    try testing.expect(s.tracks.len >= 2);

    const g = try TrackGround.init(gpa, &m, &labels, p, r, &s);
    defer g.deinit();
    const gr = g.ground();
    for (s.tracks, 0..) |t, k| {
        const piece = gr.piece(k, 0).?;
        try testing.expectEqual(t.box, g.bands.items[k]);
        // Straight, running right, up the page.
        try near(t.box.x0, piece.frame(0).point.x);
        try near(1, piece.frame(5).along.x);
        try near(1, piece.frame(5).up.y);
        try near(3, piece.cap);
        try near(5 * 6, piece.length);
        try near(piece.above + piece.below, t.box.height());
    }
    // v1 set the first word's capitals centred across the first band: on
    // the ground's baseline.
    const first = gr.piece(0, 0).?;
    try near(s.labels[0].origin.y, first.frame(0).point.y);
    try testing.expect(!g.beyond.items[0]);
    try testing.expect(!gr.more());
}

test "art closes stretches of a piece, as it does v1's lines" {
    const gpa = testing.allocator;
    var m: model.Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("label", .{ .upright = 0, .cap_height = 3 });
    const p = try m.addPanel("board", 100, 60);
    const r = try m.addTracks(p, .{ .name = "text", .origin = .{ .x = 0, .y = 50 }, .style = style, .count = 2, .length = 15, .pitch = 6 });
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    // A box 20 mm wide from x 40, wrapped by its bounds, 1 mm clear.
    const block = try art.primitive(arena.allocator(), "block", .{ .rect = .{ .w = 20, .h = 30 } }, .{});
    _ = try m.addArt(p, .{ .name = "block", .at = .{ .x = 40, .y = 30 }, .shapes = block, .wrap = .bounds, .clearance = 1 });
    var labels: place.Labels = .init(gpa, &.{});
    defer labels.deinit();
    const g = try TrackGround.init(gpa, &m, &labels, p, r, null);
    defer g.deinit();
    const piece = g.ground().piece(0, 0).?;
    // 90 mm long, open but for 39 to 61 mm.
    try testing.expectEqual(@as(usize, 2), piece.open.len);
    try near(0, piece.open[0].lo);
    try near(39, piece.open[0].hi);
    try near(61, piece.open[1].lo);
    try near(90, piece.open[1].hi);
    try near(61, piece.fit(30, 10).?);
}

test "a thread: pieces go on into the next track; one on another panel says there is more" {
    const gpa = testing.allocator;
    var m: model.Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("label", .{ .upright = 0, .cap_height = 3 });
    const p = try m.addPanel("left", 100, 60);
    const q = try m.addPanel("right", 100, 60);
    const a = try m.addTracks(p, .{ .name = "a", .origin = .{ .x = 0, .y = 50 }, .style = style, .count = 1, .length = 10, .pitch = 6 });
    const b = try m.addTracks(p, .{ .name = "b", .origin = .{ .x = 0, .y = 20 }, .style = style, .count = 1, .length = 10, .pitch = 6 });
    const c = try m.addTracks(q, .{ .name = "c", .origin = .{ .x = 0, .y = 50 }, .style = style, .count = 1, .length = 10, .pitch = 6 });
    try m.joinTracks(p, a, b);
    try m.threadTracks(p, b, q, c);
    var labels: place.Labels = .init(gpa, &.{});
    defer labels.deinit();
    const g = try TrackGround.init(gpa, &m, &labels, p, a, null);
    defer g.deinit();
    const gr = g.ground();
    // Track a's one row, then track b's; then the flow leaves the panel.
    // Band 44 to 50 mm, 3 mm capitals centred: the baseline at 45.5.
    try near(45.5, gr.piece(0, 0).?.frame(0).point.y);
    const p1 = gr.piece(1, 0).?;
    // Track b's band, 14 to 20 mm: its baseline at 15.5.
    try near(15.5, p1.frame(0).point.y);
    try testing.expectEqual(null, gr.piece(2, 0));
    try testing.expect(gr.more());
}

test "a column's pieces run down the page, up to the right" {
    const gpa = testing.allocator;
    var m: model.Model = .init(gpa);
    defer m.deinit();
    const style = try m.addStyle("label", .{ .upright = 0, .cap_height = 3 });
    const p = try m.addPanel("board", 100, 60);
    const r = try m.addTracks(p, .{ .name = "down", .origin = .{ .x = 10, .y = 50 }, .style = style, .count = 2, .length = 8, .pitch = 5, .major = .column });
    var labels: place.Labels = .init(gpa, &.{});
    defer labels.deinit();
    const g = try TrackGround.init(gpa, &m, &labels, p, r, null);
    defer g.deinit();
    const piece = g.ground().piece(0, 0).?;
    const f = piece.frame(0);
    try near(-1, f.along.y);
    try near(1, f.up.x);
    try near(12.5, f.point.x);
    try near(50, f.point.y);
    try near(40, piece.length);
}

test "a panel's process limits are kept through a save (for the manufacture stage)" {
    const gpa = testing.allocator;
    var m: model.Model = .init(gpa);
    defer m.deinit();
    const p = try m.addPanel("board", 100, 60);
    try m.setPanelFab(p, .{ .min_stroke = 0.3, .min_gap = 0.5, .min_cap = 1.5 });
    try testing.expectError(error.BadSize, m.setPanelFab(p, .{ .min_gap = -1 }));
    const bytes = try native.encode(gpa, &m);
    defer gpa.free(bytes);
    var back = try native.decode(gpa, bytes);
    defer back.deinit();
    const f = back.panels.items[p].fab;
    try near(0.3, f.min_stroke);
    try near(0.5, f.min_gap);
    try near(1.5, f.min_cap);
}
