//! Graven GUI editor, on DVUI over SDL3.
//!
//! Immediate mode: the panes are rebuilt from the model every frame, so the
//! model stays the single source of truth. Edits go through the layout
//! library's actions, and the panel is re-solved when the model's revision
//! moves. Legends on the canvas are Graven's own outlines, filled nonzero;
//! DVUI's text is for the interface only.
//!
//! This first slice follows one workflow: open the PC keyboard sample, look
//! around it, select tiles, edit their legends, and try other fonts.

const std = @import("std");
const builtin = @import("builtin");
const dvui = @import("dvui");
const layout = @import("graven_layout");
const engine = @import("graven_engine");
const samples = @import("graven_samples");
const desktop = @import("desktop.zig");
const ghost_pane = @import("ghost.zig");
const settings_file = @import("settings.zig");
const history = layout.history;
const locale = @import("locale.zig");

const geom = engine.geom;
const Model = layout.Model;
const TileId = layout.TileId;

pub const dvui_app: dvui.App = .{
    .config = .{ .startFn = start },
    .frameFn = frame,
    .initFn = init,
    .deinitFn = deinit,
};
/// Runs before SDL starts. SDL 3.4 falls back to XWayland on compositors
/// without the fifo-v1 protocol (COSMIC, for one), where it cannot see the
/// display scale; an editor wants correct scaling over frame pacing, so
/// Wayland comes first. SDL_VIDEO_DRIVER in the environment still wins.
fn start() dvui.App.StartOptions {
    if (dvui.backend.kind == .sdl3) {
        const c = dvui.backend.c;
        _ = c.SDL_SetHint(c.SDL_HINT_VIDEO_DRIVER, "wayland,x11");
        // The identifier becomes the Wayland app id, which the desktop uses
        // to find Graven's .desktop file and icon.
        _ = c.SDL_SetAppMetadata("Graven", engine.version, "com.mnemopyx.graven");
    }
    return .{
        .size = .{ .w = 1500, .h = 820 },
        .min_size = .{ .w = 800, .h = 500 },
        .title = "Graven",
        .app = "Graven",
        .org = "com.mnemopyx.graven",
    };
}

pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

/// The bundled example font, relative to the repository root. The GUI opens
/// with an installed Inter Medium if fontconfig finds one (system or user
/// fonts), else this file when run from the repository root, else the first
/// font found.
const example_font = "examples/fonts/Inter-Medium.otf";

const Font = struct {
    name: []const u8,
    path: []const u8,
    /// Face index within a collection (.ttc, .otc); 0 for a single font.
    index: u32 = 0,
    family: []const u8 = "",
    style: []const u8 = "",
};

const State = struct {
    gpa: std.mem.Allocator,
    fonts: []Font = &.{},
    font_choice: usize = 0,
    font_loaded: ?usize = null,
    face: ?*engine.Face = null,
    faces: [1]*engine.Face = undefined,
    model: Model,
    labels: ?layout.Labels = null,
    /// One solve per panel, in the panel's own frame.
    placed: std.ArrayList(layout.place.Placed) = .empty,
    placed_rev: u64 = std.math.maxInt(u64),
    /// Labels whose ink reaches into the worksheet's margins.
    intrusions: []layout.drc.MarginIntrusion = &.{},
    /// Panels out of compliance, as sheet and margin changes can leave them.
    panel_issues: []layout.drc.PanelIssue = &.{},
    /// Layers the checks flag (see `Model.layerIssues`).
    layer_issues: []layout.model.LayerIssue = &.{},
    /// The canvas tool, and a rectangle being dragged out with it.
    tool: Tool = .select,
    drag: ?struct { start: geom.Point, at: geom.Point } = null,
    /// The pointer's position on the worksheet, mm; null off the canvas.
    mouse: ?geom.Point = null,
    /// The press was used by a tool (placing a label), so its release does
    /// not pick.
    press_consumed: bool = false,
    /// Where the pointer went down on the canvas, mm.
    press_at: ?geom.Point = null,
    /// A selected panel being dragged to a new place: shown at its preview
    /// position, committed on release.
    moving: ?struct { panel: usize, start: geom.Point, at: geom.Point } = null,
    /// A selected panel label being dragged, likewise.
    moving_label: ?struct { panel: usize, index: usize, start: geom.Point, at: geom.Point } = null,
    /// The style new panel labels get, made with the first one; its size
    /// is the app's choice until the user sets it.
    label_style: ?layout.model.StyleId = null,
    label_style_set: bool = false,
    solve_ms: f64 = 0,
    flat: Flat,
    view: View = .{},
    /// The file's name; a new file is untitled until saved or renamed.
    file_name: []const u8 = "untitled",
    /// Whether the user has given the file name and the legend font. Until
    /// then they are the app's choices, shown in italic.
    file_name_set: bool = false,
    font_set: bool = false,
    /// What the tree, canvas, tools and properties are about.
    context: Context = .worksheet,
    /// Tree nodes the user has opened or closed, by context key.
    expanded: std.AutoHashMapUnmanaged(u64, bool) = .empty,
    status: []const u8 = "",
};

/// What a canvas drag does: pick things, or draw out a new panel.
const Tool = enum { select, add_panel, add_label, add_tracks, add_art, select_area };

/// What Add shape draws: a closed path, dragged out as a box (a polygon
/// is clicked corner by corner).
const ShapeKind = enum { rect, rounded, circle, ellipse, slot, polygon };
var shape_kind: ShapeKind = .rounded;
/// A polygon's corners so far, on panel `polygon_panel`, worksheet mm.
var polygon_pts: std.ArrayList(geom.Point) = .empty;
var polygon_panel: usize = 0;

/// The Add tracks tool's choices: what sizes the rows or columns (a tile
/// prototype, or a text style), and which way the tracks run.
var tracks_tool: struct {
    size_to: SizeTo = .{ .prototype = 0 },
    major: layout.model.Major = .row,
} = .{};

/// What new tracks are sized to: a tile prototype's smallest tile, or a
/// text style's line pitch. A null style is the default Label style, made
/// when the tracks are.
const SizeTo = union(enum) {
    prototype: layout.model.PrototypeId,
    style: ?layout.model.StyleId,
};

/// The current context: a node of the component tree.
const Context = union(enum) {
    /// The file: everything, the worksheet included.
    file,
    worksheet,
    panel: usize,
    region: struct { panel: usize, region: usize },
    row: struct { panel: usize, region: usize, row: usize },
    tile: TileId,
    /// A label placed directly on a panel.
    label: struct { panel: usize, index: usize },
    /// Line art placed on a panel.
    art: struct { panel: usize, index: usize },
    /// A selection group of a space.
    group: layout.model.ObjectId,
    /// Objects picked together with Select area (see `selection`).
    selection,
    /// A view of another space, placed in space `space`.
    view: struct { space: usize, index: usize },
    /// A layer of a space.
    layer: struct { space: usize, index: usize },
    /// A raster image placed in a space.
    image: struct { space: usize, index: usize },
    /// The file's tile prototypes, and one of them.
    prototypes,
    prototype: layout.model.PrototypeId,

    fn key(c: Context) u64 {
        var h: std.hash.Wyhash = .init(0);
        std.hash.autoHash(&h, c);
        return h.final();
    }

    fn eql(a: Context, b: Context) bool {
        return std.meta.eql(a, b);
    }

    fn kindName(c: Context) []const u8 {
        return switch (c) {
            .file => "File",
            .worksheet => "Worksheet",
            .panel => "Panel",
            .region => "Region",
            .row => "Row",
            .tile => "Tile",
            .label => "Label",
            .art => "Line art",
            .group => "Group",
            .selection => "Selection",
            .view => "View",
            .layer => "Layer",
            .image => "Image",
            .prototypes => "Tile prototypes",
            .prototype => "Tile prototype",
        };
    }
};

/// The canvas view: the mm point at the canvas centre, and physical pixels
/// per mm. While `fit` holds a box, the view keeps that box centred and
/// filling the canvas (through window resizes) until the user zooms or pans.
const View = struct {
    cx: f64 = 0,
    cy: f64 = 0,
    ppm: f64 = 0,
    fit: ?geom.Box = null,

    fn toPx(v: View, area: dvui.Rect.Physical, p: geom.Point) dvui.Point.Physical {
        return .{
            .x = @floatCast(area.x + area.w / 2 + (p.x - v.cx) * v.ppm),
            .y = @floatCast(area.y + area.h / 2 - (p.y - v.cy) * v.ppm),
        };
    }

    fn toMm(v: View, area: dvui.Rect.Physical, p: dvui.Point.Physical) geom.Point {
        return .{
            .x = v.cx + (p.x - area.x - area.w / 2) / v.ppm,
            .y = v.cy - (p.y - area.y - area.h / 2) / v.ppm,
        };
    }

    fn rect(v: View, area: dvui.Rect.Physical, b: geom.Box) dvui.Rect.Physical {
        const tl = v.toPx(area, .{ .x = b.x0, .y = b.y1 });
        const br = v.toPx(area, .{ .x = b.x1, .y = b.y0 });
        return .{ .x = tl.x, .y = tl.y, .w = br.x - tl.x, .h = br.y - tl.y };
    }
};

/// What a filled shape came from: ink, faint preview text (source shown
/// literally while it is not valid), or a placeholder for what is to come.
const PieceKind = enum { ink, faint, placeholder };

/// One item's outline, flattened and resolved: its overlaps removed, as
/// simple loops and the triangles that fill them.
const Piece = struct { region: geom.fill.Region, kind: PieceKind };

/// Label outlines flattened to polylines in mm and triangulated, per
/// render, at a tolerance matched to the zoom. Rebuilt when the zoom
/// changes a lot or the panel is re-solved (renders may be freed then).
/// One shape of a tile's art, flattened: its region for the fill and its
/// contours as drawn for the edge.
const TilePiece = struct {
    shape: *const layout.art.Shape,
    region: geom.fill.Region,
    lines: []const []const geom.Point,
};

const Flat = struct {
    arena: std.heap.ArenaAllocator,
    map: std.AutoHashMapUnmanaged(*const engine.Render, []const Piece) = .empty,
    /// Tile art, by its placed shapes (owned by the placement, which resets
    /// this cache when it changes).
    tiles: std.AutoHashMapUnmanaged([*]const layout.art.Shape, []const TilePiece) = .empty,
    tol: f64 = 0,

    fn reset(f: *Flat, tol: f64) void {
        f.map = .empty;
        f.tiles = .empty;
        _ = f.arena.reset(.retain_capacity);
        f.tol = tol;
    }

    fn get(f: *Flat, r: *const engine.Render, faces: []const *engine.Face) ![]const Piece {
        if (f.map.get(r)) |c| return c;
        const a = f.arena.allocator();
        var contours: std.ArrayList(Piece) = .empty;
        // `outlines` is item for item.
        for (try r.outlines(a, faces), r.items) |o, item| {
            const kind: PieceKind = switch (item) {
                .glyph => |g| if (g.faint) .faint else .ink,
                .path => |p| if (p.role == .placeholder) .placeholder else .ink,
            };
            // Overlaps resolved here, once: glyphs from variable fonts keep
            // overlapping and self-crossing contours, which DVUI's
            // triangulator fills wrongly. The triangles are drawn as they are.
            const polys = try a.alloc([]const geom.Point, o.contours.len);
            for (o.contours, polys) |c, *poly| {
                var pts: std.ArrayList(geom.Point) = .empty;
                for (c.segments) |s| try flatten(a, &pts, s, f.tol);
                poly.* = pts.items;
            }
            try contours.append(a, .{ .region = try geom.fill.nonzero(a, polys, f.tol * 0.1), .kind = kind });
        }
        const out = contours.items;
        try f.map.put(a, r, out);
        return out;
    }
};

/// A tile's art shapes flattened and resolved, made once per placement and
/// zoom.
fn flatTile(f: *Flat, shapes: []const layout.art.Shape) ![]const TilePiece {
    if (shapes.len == 0) return &.{};
    if (f.tiles.get(shapes.ptr)) |c| return c;
    const a = f.arena.allocator();
    const out = try a.alloc(TilePiece, shapes.len);
    for (shapes, out) |*s, *piece| {
        const lines = try a.alloc([]const geom.Point, s.outline.contours.len);
        for (s.outline.contours, lines) |c, *line| {
            var pts: std.ArrayList(geom.Point) = .empty;
            for (c.segments) |seg| try flatten(a, &pts, seg, f.tol);
            line.* = pts.items;
        }
        piece.* = .{ .shape = s, .region = try geom.fill.nonzero(a, lines, f.tol * 0.1), .lines = lines };
    }
    try f.tiles.put(a, shapes.ptr, out);
    return out;
}

/// Strokes an outline's contours placed at worksheet point `at`.
fn strokeOutline(area: dvui.Rect.Physical, o: geom.Outline, at: geom.Point, width: f32, color: dvui.Color) void {
    const arena = dvui.currentWindow().arena();
    for (o.contours) |c| {
        var pts: std.ArrayList(geom.Point) = .empty;
        // Each segment adds the points after its start: the loop closes on
        // the last one, so the first point is not repeated.
        for (c.segments) |seg| flatten(arena, &pts, seg, state.flat.tol) catch return;
        strokeLoop(area, pts.items, at, width, color);
    }
}

/// Strokes a closed polyline placed at worksheet point `at`.
fn strokeLoop(area: dvui.Rect.Physical, line: []const geom.Point, at: geom.Point, width: f32, color: dvui.Color) void {
    if (line.len < 2) return;
    const lifo = dvui.currentWindow().lifo();
    const pts = lifo.alloc(dvui.Point.Physical, line.len) catch return;
    defer lifo.free(pts);
    for (line, pts) |q, *out| out.* = state.view.toPx(area, .{ .x = q.x + at.x, .y = q.y + at.y });
    dvui.Path.stroke(.{ .points = pts }, .{ .thickness = width, .color = .{ .color = color }, .closed = true });
}

/// Appends a segment's points after its start, within `tol` of the curve.
fn flatten(a: std.mem.Allocator, pts: *std.ArrayList(geom.Point), s: geom.Segment, tol: f64) !void {
    switch (s) {
        .line => |p| try pts.append(a, p[1]),
        .quad => |p| {
            const dev = 0.25 * @sqrt(sq(p[0].x - 2 * p[1].x + p[2].x) + sq(p[0].y - 2 * p[1].y + p[2].y));
            const n: usize = @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(dev / tol)))));
            for (1..n + 1) |i| {
                const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
                const u = 1 - t;
                try pts.append(a, .{
                    .x = u * u * p[0].x + 2 * u * t * p[1].x + t * t * p[2].x,
                    .y = u * u * p[0].y + 2 * u * t * p[1].y + t * t * p[2].y,
                });
            }
        },
        .cubic => |p| {
            const d1 = @sqrt(sq(p[0].x - 2 * p[1].x + p[2].x) + sq(p[0].y - 2 * p[1].y + p[2].y));
            const d2 = @sqrt(sq(p[1].x - 2 * p[2].x + p[3].x) + sq(p[1].y - 2 * p[2].y + p[3].y));
            const dev = 0.75 * @max(d1, d2);
            const n: usize = @max(1, @as(usize, @intFromFloat(@ceil(@sqrt(dev / tol)))));
            for (1..n + 1) |i| {
                const t: f64 = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
                const u = 1 - t;
                try pts.append(a, .{
                    .x = u * u * u * p[0].x + 3 * u * u * t * p[1].x + 3 * u * t * t * p[2].x + t * t * t * p[3].x,
                    .y = u * u * u * p[0].y + 3 * u * u * t * p[1].y + 3 * u * t * t * p[2].y + t * t * t * p[3].y,
                });
            }
        },
    }
}

fn sq(x: f64) f64 {
    return x * x;
}

var state: State = undefined;

fn init(win: *dvui.Window) !void {
    const gpa = win.gpa;
    initWindowFrame(win);
    // Match the desktop now, then follow its changes.
    main_window = win;
    const settings = desktop.read(gpa, dvui.io);
    applyDesktop(win, settings);
    desktop.watch(dvui.io, settings, wakeGui);
    state = .{ .gpa = gpa, .model = .init(gpa), .flat = .{ .arena = .init(gpa) } };
    hist = .init(gpa);
    initWriter();
    // Work starts on a canvas, not a worksheet: the user picks its units.
    state.model.has_sheet = false;
    const installed: []Font = listFonts(gpa) catch &.{};
    if (std.Io.Dir.cwd().access(dvui.io, example_font, .{})) |_| {
        const fonts = try gpa.alloc(Font, installed.len + 1);
        fonts[0] = .{ .name = "Inter Medium (examples)", .path = example_font, .family = "Inter", .style = "Medium" };
        @memcpy(fonts[1..], installed);
        state.fonts = fonts;
    } else |_| {
        state.fonts = installed;
    }
    state.font_choice = defaultFont(state.fonts);
    loadPrefs();
}

/// Asking for a new canvas's units, before anything is drawn.
var canvas_prompt = true;
/// The units the last canvas was made in: the next one's default. (Kept
/// for the session; shared preferences will keep it across sessions.)
var last_units: layout.model.Units = .mm;
/// Where the last click on the canvas landed, worksheet frame: typing makes
/// a label there.
var click_at: ?geom.Point = null;

/// The part of the canvas a new one first shows, mm: its origin near the
/// bottom left.
const canvas_view: geom.Box = .{ .x0 = -15, .y0 = -15, .x1 = 185, .y1 = 120 };

/// The space the canvas shows: the canvas itself (0), or a frame.
var shown_space: usize = 0;

/// Objects picked together with Select area, all in the shown space.
var selection: std.ArrayList(layout.model.ObjectId) = .empty;

/// The shown space's own panel (its loose objects), if the document is a
/// canvas.
fn spaceRoot() ?usize {
    if (shown_space >= state.model.spaces.items.len) return null;
    return state.model.spaces.items[shown_space].root;
}

/// Whether panel `pi` is shown: it lives in the shown space (a worksheet
/// document shows every panel).
fn shownPanel(pi: usize) bool {
    if (state.model.spaces.items.len == 0) return true;
    return state.model.panels.items[pi].space == shown_space;
}

/// Shows the space the context belongs to.
fn followContext() void {
    if (state.model.spaces.items.len == 0) return;
    const pi: ?usize = switch (state.context) {
        .panel => |pi| pi,
        .label => |l| l.panel,
        .art => |l| l.panel,
        .region => |r| r.panel,
        .row => |r| r.panel,
        .tile => |id| if (findTile(id)) |f| f.panel else null,
        .group => |g| {
            if (state.model.spaceOfId(g)) |sp| shown_space = sp;
            return;
        },
        .view => |v| {
            shown_space = v.space;
            return;
        },
        .layer => |l| {
            shown_space = l.space;
            return;
        },
        .image => |im| {
            shown_space = im.space;
            return;
        },
        else => null,
    };
    if (pi) |p| if (p < state.model.panels.items.len) {
        shown_space = state.model.panels.items[p].space;
    };
    if (shown_space >= state.model.spaces.items.len) shown_space = 0;
}

/// Whether the document is an open canvas (no sheet).
fn openCanvas() bool {
    return !state.model.has_sheet;
}

/// The units lengths are shown and typed in: the sheet's, or the canvas's.
fn docUnits() layout.model.Units {
    return if (state.model.has_sheet) state.model.sheet.units else state.model.units;
}

/// Starts over with an empty document and asks for the new canvas's units.
fn newCanvas() void {
    setFilePath(null);
    clearPlaced();
    state.model.deinit();
    state.model = .init(state.gpa);
    state.model.has_sheet = false;
    if (state.labels) |*l| l.clear();
    state.label_style = null;
    state.label_style_set = false;
    state.context = .worksheet;
    state.tool = .select;
    state.drag = null;
    state.moving = null;
    state.moving_label = null;
    state.placed_rev = std.math.maxInt(u64);
    track_cursor = null;
    click_at = null;
    state.view.fit = canvas_view;
    canvas_prompt = true;
    shown_space = 0;
    selection.clearRetainingCapacity();
}

/// Makes the canvas in `units`, and makes it the context.
fn createCanvas(units: layout.model.Units) void {
    const ci = state.model.startCanvas(units) catch return;
    // The new canvas is where its history starts: nothing to undo.
    hist.reset(&state.model) catch {};
    last_units = units;
    canvas_prompt = false;
    state.context = .{ .panel = ci };
    state.view.fit = canvas_view;
}

/// The new-canvas prompt, centred on the canvas: its units, then Create
/// (or Enter).
fn newCanvasPrompt() void {
    const c = canvas_rect;
    if (c.w <= 0 or c.h <= 0) return;
    const w: f32 = 340;
    const h: f32 = 175;
    var r: dvui.Rect = .{ .x = c.x + (c.w - w) / 2, .y = c.y + (c.h - h) / 2, .w = w, .h = h };
    var fw = dvui.floatingWindow(@src(), .{ .rect = &r, .resize = .none }, overlayOptions(9));
    defer fw.deinit();
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(12) });
    defer body.deinit();
    dvui.labelNoFmt(@src(), "New canvas", .{}, .{ .font = dvui.Font.theme(.heading) });
    dvui.labelNoFmt(@src(), "An open drafting space. Its units come first.", .{}, .{ .font = dvui.Font.theme(.body).larger(-2), .padding = .{ .y = 2, .h = 8 } });
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        propName("Units");
        const names = [_][]const u8{ "Millimetres", "Inches", "Mils" };
        var choice: usize = @intFromEnum(last_units);
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal })) last_units = @enumFromInt(choice);
    }
    var enter = false;
    for (dvui.events()) |*e| {
        if (e.evt != .key or e.handled) continue;
        const k = e.evt.key;
        if (k.action == .down and (k.code == .enter or k.code == .kp_enter)) {
            e.handle(@src(), fw.data());
            enter = true;
        }
    }
    if (dvui.button(@src(), "Create", .{}, .{ .gravity_x = 1, .margin = .{ .y = 10 } }) or enter) createCanvas(last_units);
}

/// File › Export SVG is asking where to write.
var export_prompt = false;

fn exportSvg() void {
    if (canvas_prompt) return;
    export_prompt = true;
}

/// What Export SVG writes: the selected panel, else the canvas's loose
/// objects (on a worksheet, the first panel).
fn exportPanel() ?usize {
    switch (state.context) {
        .panel => |pi| return pi,
        .label => |l| return l.panel,
        .art => |l| return l.panel,
        .region => |r| return r.panel,
        .row => |r| return r.panel,
        else => {},
    }
    if (spaceRoot()) |ri| return ri;
    return if (state.model.panels.items.len > 0) 0 else null;
}

/// The export prompt: the file to write, then Export (or Enter); Esc or
/// Cancel closes it.
fn exportPrompt() void {
    const c = canvas_rect;
    if (c.w <= 0 or c.h <= 0) return;
    const w: f32 = 460;
    const h: f32 = 185;
    var r: dvui.Rect = .{ .x = c.x + (c.w - w) / 2, .y = c.y + (c.h - h) / 2, .w = w, .h = h };
    var fw = dvui.floatingWindow(@src(), .{ .rect = &r, .resize = .none }, overlayOptions(10));
    defer fw.deinit();
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(12) });
    defer body.deinit();
    const pi = exportPanel();
    const what = if (pi) |p| (if (state.model.panels.items[p].unbounded) "the canvas's loose objects" else state.model.panels.items[p].name) else "nothing yet";
    dvui.label(@src(), "Export SVG: {s}", .{what}, .{ .font = dvui.Font.theme(.heading) });
    var go = false;
    var cancel = false;
    for (dvui.events()) |*e| {
        if (e.evt != .key or e.handled) continue;
        const k = e.evt.key;
        if (k.action != .down) continue;
        if (k.code == .enter or k.code == .kp_enter) go = true else if (k.code == .escape) cancel = true else continue;
        e.handle(@src(), fw.data());
    }
    var path: []const u8 = "graven.svg";
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 8 } });
        defer row.deinit();
        propName("File");
        var te = dvui.textEntry(@src(), .{ .text_initial = "graven.svg" }, .{ .expand = .horizontal });
        defer te.deinit();
        path = dvui.currentWindow().arena().dupe(u8, std.mem.trim(u8, te.textGet(), " ")) catch "graven.svg";
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1, .margin = .{ .y = 8 } });
        defer row.deinit();
        if (dvui.button(@src(), "Cancel", .{}, .{})) cancel = true;
        if (dvui.button(@src(), "Export", .{}, .{})) go = true;
    }
    if (cancel) {
        export_prompt = false;
        return;
    }
    if (!go) return;
    export_prompt = false;
    const p = pi orelse {
        state.status = "There is nothing to export yet. ";
        return;
    };
    if (p >= state.placed.items.len or path.len == 0) return;
    const svg = layout.output.panelSvg(state.gpa, &state.placed.items[p], &state.faces, .{}) catch {
        state.status = "The SVG could not be made. ";
        return;
    };
    defer state.gpa.free(svg);
    std.Io.Dir.cwd().writeFile(dvui.io, .{ .sub_path = path, .data = svg }) catch {
        state.status = "The SVG could not be written there. ";
        return;
    };
    state.status = "Exported. ";
}

/// Adds the sample PC keyboard as a new panel and makes it the context.
fn loadSample() !void {
    // Built by the sample's own calls, then logged as one step: a snapshot.
    const main_style = try state.model.addStyle("legend", .{ .upright = 0, .cap_height = 2.6 });
    const small = try state.model.addStyle("legend words", .{ .upright = 0, .cap_height = 1.6 });
    const pi = try samples.pc_keyboard.build(state.gpa, &state.model, .{ .main = main_style, .small = small });
    // Top-left of the sheet, 20 mm in; on a canvas, at its origin.
    const panel = state.model.panels.items[pi];
    try state.model.movePanel(pi, if (openCanvas()) .{ .x = 0, .y = 0 } else .{ .x = 20, .y = state.model.sheet.h - 20 - panel.h });
    try hist.snapshot(&state.model);
    state.context = .{ .panel = pi };
    state.view.fit = state.model.panels.items[pi].box();
}

fn deinit(_: *dvui.Window) void {
    hist.deinit();
    if (prefs_store) |*ps| ps.deinit();
    clearPlaced();
    state.placed.deinit(state.gpa);
    if (state.labels) |*l| l.deinit();
    if (state.face) |f| f.deinit();
    state.flat.arena.deinit();
    state.expanded.deinit(state.gpa);
    state.model.deinit();
}

/// The best match for Inter Medium, preferring installed fonts (they come
/// after the bundled one) and exact names: Inter Medium, then any Inter
/// family in Medium, then any Inter, then the first font.
fn defaultFont(fonts: []const Font) usize {
    var best: usize = 0;
    var best_score: u8 = 0;
    for (fonts, 0..) |f, i| {
        const inter = std.mem.startsWith(u8, f.family, "Inter") and !std.mem.startsWith(u8, f.family, "Inter Display");
        const medium = std.mem.eql(u8, f.style, "Medium");
        const installed: u8 = if (std.mem.eql(u8, f.path, example_font)) 0 else 1;
        const score: u8 = if (inter and medium and std.mem.eql(u8, f.family, "Inter"))
            6 + installed
        else if (inter and medium)
            4 + installed
        else if (inter)
            2 + installed
        else
            0;
        if (score > best_score) {
            best = i;
            best_score = score;
        }
    }
    return best;
}

/// Installed outline fonts from fontconfig (system and user folders, such
/// as ~/.local/share/fonts), sorted by name. Each face of a collection is
/// listed; a variable font is listed once, at its default instance, under
/// that instance's style (fontconfig also lists the font itself, unstyled).
fn listFonts(gpa: std.mem.Allocator) ![]Font {
    const r = try std.process.run(gpa, dvui.io, .{ .argv = &.{ "fc-list", "--format", "%{family[0]}\t%{style[0]}\t%{index}\t%{file}\n" } });
    defer gpa.free(r.stderr);
    var list: std.ArrayList(Font) = .empty;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const family = fields.next() orelse continue;
        const style = fields.next() orelse continue;
        const index = std.fmt.parseInt(u32, fields.next() orelse continue, 10) catch continue;
        const path = fields.rest();
        const ext = std.fs.path.extension(path);
        const known = for ([_][]const u8{ ".otf", ".ttf", ".ttc", ".otc" }) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) break true;
        } else false;
        // Named instances of a variable font carry the instance above bit 16.
        if (!known or index >> 16 != 0) continue;
        const user = std.mem.indexOf(u8, path, "/.local/share/fonts/") != null or std.mem.indexOf(u8, path, "/.fonts/") != null;
        const name = try std.fmt.allocPrint(gpa, "{s}{s}{s}{s}", .{ family, if (style.len > 0) " " else "", style, if (user) " (user)" else "" });
        const font: Font = .{ .name = name, .path = path, .index = index, .family = family, .style = style };
        // One entry per face of a file: a styled one replaces an unstyled.
        const same = for (list.items) |*f| {
            if (f.index == index and std.mem.eql(u8, f.path, path)) break f;
        } else null;
        if (same) |f| {
            if (f.style.len == 0 and style.len > 0) {
                gpa.free(f.name);
                f.* = font;
            } else gpa.free(name);
            continue;
        }
        try list.append(gpa, font);
    }
    std.mem.sort(Font, list.items, {}, struct {
        fn less(_: void, x: Font, y: Font) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.less);
    return list.toOwnedSlice(gpa);
}

/// Loads the chosen font if it changed, and re-solves when the model or the
/// font changed.
fn update() !void {
    followContext();
    if (state.font_loaded != state.font_choice and state.fonts.len > 0) {
        const f = state.fonts[state.font_choice];
        const bytes = try std.Io.Dir.cwd().readFileAlloc(dvui.io, f.path, state.gpa, .limited(64 << 20));
        defer state.gpa.free(bytes);
        const face = try engine.Face.init(state.gpa, bytes, f.index);
        clearPlaced();
        if (state.labels) |*l| l.deinit();
        if (state.face) |old| old.deinit();
        state.face = face;
        state.faces = .{face};
        state.labels = .init(state.gpa, &state.faces);
        state.font_loaded = state.font_choice;
        state.placed_rev = std.math.maxInt(u64);
    }
    const labels = if (state.labels) |*l| l else return;
    if (state.placed_rev == state.model.revision) return;
    const t0: std.Io.Timestamp = .now(dvui.io, .awake);
    clearPlaced();
    for (0..state.model.panels.items.len) |pi| {
        try state.placed.append(state.gpa, try layout.solve(state.gpa, &state.model, pi, labels));
    }
    state.intrusions = try layout.drc.marginIntrusions(state.gpa, &state.model, state.placed.items);
    state.panel_issues = try layout.drc.panelIssues(state.gpa, &state.model);
    state.layer_issues = try state.model.layerIssues(state.gpa);
    state.solve_ms = @as(f64, @floatFromInt(t0.untilNow(dvui.io, .awake).toNanoseconds())) / 1e6;
    state.placed_rev = state.model.revision;
    state.flat.reset(state.flat.tol);
    // Segments the flow no longer reaches go, kept origins and all (the
    // next solve shows it); a selected one gives way to its track.
    for (state.placed.items, 0..) |*pl, pi| for (pl.flows) |f| {
        if (state.model.panels.items[pi].regions.items[f.region].segments.items.len > @max(1, f.segments))
            hist.join(&state.model, .trimSegments, .{ pi, f.region, f.segments }) catch {};
        switch (state.context) {
            .row => |r| if (r.panel == pi and r.region == f.region and r.row >= f.segments) {
                state.context = .{ .region = .{ .panel = pi, .region = f.region } };
            },
            else => {},
        }
    };
}

fn clearPlaced() void {
    state.gpa.free(state.intrusions);
    state.intrusions = &.{};
    state.gpa.free(state.panel_issues);
    state.panel_issues = &.{};
    state.gpa.free(state.layer_issues);
    state.layer_issues = &.{};
    for (state.placed.items) |*p| p.deinit();
    state.placed.clearRetainingCapacity();
    state.placed_rev = std.math.maxInt(u64);
}

/// A placed tile and the panel it is on.
const Found = struct { panel: usize, tile: *const layout.place.PlacedTile };

fn findTile(id: TileId) ?Found {
    for (state.placed.items, 0..) |*p, pi| if (p.findTile(id)) |t| return .{ .panel = pi, .tile = t };
    return null;
}

/// Where panel `pi` sits on the worksheet: its origin, or its preview
/// position while it is being dragged (whole millimetres of travel).
fn panelOrigin(pi: usize) geom.Point {
    const o = state.model.panels.items[pi].origin;
    // It may be dragged past the sheet's edge, but keeps a grip on it.
    if (state.moving) |mv| if (mv.panel == pi) return state.model.clampOnSheet(pi, .{ .x = o.x + @round(mv.at.x - mv.start.x), .y = o.y + @round(mv.at.y - mv.start.y) });
    return o;
}

fn panelBox(pi: usize) geom.Box {
    const p = state.model.panels.items[pi];
    const o = panelOrigin(pi);
    return .{ .x0 = o.x, .y0 = o.y, .x1 = o.x + p.w, .y1 = o.y + p.h };
}

/// A box in panel `pi`'s frame, moved onto the worksheet.
fn onSheet(pi: usize, b: geom.Box) geom.Box {
    const o = panelOrigin(pi);
    return .{ .x0 = b.x0 + o.x, .y0 = b.y0 + o.y, .x1 = b.x1 + o.x, .y1 = b.y1 + o.y };
}

fn frame() !dvui.App.Result {
    if (desktop.take()) |s| applyDesktop(dvui.currentWindow(), s);
    try update();

    var root = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .style = .window });
    defer root.deinit();
    // Undo and redo take their keys before any widget does.
    historyKeys(root.data());
    autosaveTick(root.data().id);

    if (titleBar()) |r| return r;

    {
        // The body, the docked bottom bar and the bottom edge's strip are
        // placed explicitly, so a tall pane can never push them off the
        // bottom of the window.
        var rest = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer rest.deinit();
        const size = rest.data().contentRect();
        const t: f32 = tab_size;
        const status_h: f32 = if (bottom_pane.mode == .docked) status_height else 0;
        const body_h = @max(0, size.h - status_h - t);
        // A side pane stops above a ghost bottom bar, so they never overlap.
        const side_h = @max(0, body_h - if (bottom_pane.mode == .ghost) @as(f32, status_height) else 0);
        {
            var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = .{ .x = 0, .y = 0, .w = size.w, .h = body_h } });
            defer body.deinit();
            sideStrip(&tree_pane, if (tree_pane.mode == .docked) body_h else side_h, 1);
            if (tree_pane.mode == .docked) {
                const prev = ghost_pane.themePush(&tree_pane);
                defer ghost_pane.themePop(prev);
                treePane();
            }
            canvas();
            if (rightDocked()) try rightColumn();
            rightStrip(if (rightDocked()) body_h else side_h);
        }
        if (bottom_pane.mode == .docked) {
            const prev = ghost_pane.themePush(&bottom_pane);
            defer ghost_pane.themePop(prev);
            var bottom = dvui.box(@src(), .{ .dir = .vertical }, .{
                .rect = .{ .x = t, .y = body_h, .w = @max(0, size.w - 2 * t), .h = status_h },
                .background = true,
                .color_fill = .{ .color = ghost_pane.fill(&bottom_pane) },
                .border = .{ .y = 1 },
            });
            defer bottom.deinit();
            try bottomContent();
        }
        {
            // The bottom edge: the bottom bar's tab, as wide as the bar.
            var strip = dvui.box(@src(), .{}, .{ .rect = .{ .x = 0, .y = size.h - t, .w = size.w, .h = t }, .background = true, .color_fill = .{ .color = colors.titlebar } });
            defer strip.deinit();
            applyTab(&bottom_pane, ghost_pane.tab(&bottom_pane, .{ .x = t, .y = 0, .w = @max(0, size.w - 2 * t), .h = t }, 3));
        }
    }
    try overlays();
    savePrefsIfChanged();
    updateWindowTitle();
    if (quit_now) return .close;
    if (hot_edges) {
        ghost_pane.hotEdges(&all_panes, root.data().id);
    } else for (all_panes) |p| {
        p.hot = .{};
    }
    return .ok;
}

// Panes ---------------------------------------------------------------------
//
// The tree, the tools with the properties, and the bottom bar (the
// expression and status lines) are ghost panes (see ghost.zig): attached to
// an edge of the window, with a tab along that edge whose icons choose the
// pane's mode (ghost over the canvas, docked beside it, or hidden), and
// whose body makes a ghost pane active or ghost again.

var tree_pane: ghost_pane.Pane = .{ .name = "Tree", .edge = .left, .size = tree_width, .look = .{ .hue = 165 } };
/// The right edge holds two panes, one above the other: the tool palette
/// and the properties. They meet at `tools_height` below the top, which
/// the grip between their tabs moves.
var tools_pane: ghost_pane.Pane = .{ .name = "Tools", .edge = .right, .size = properties_width, .look = .{ .hue = 330 } };
var props_pane: ghost_pane.Pane = .{ .name = "Properties", .edge = .right, .size = properties_width, .look = .{ .hue = 230 } };
/// The tool palette's height, logical pixels.
var tools_height: f32 = 120;
const split_grip = 8;
/// The grip between the right edge's panes is being dragged.
var split_dragging = false;
const min_pane_height = 48;
/// Docked by default: the expression line is typed into often.
var bottom_pane: ghost_pane.Pane = .{ .name = "Expression and status", .edge = .bottom, .size = status_height, .mode = .docked, .look = .{ .hue = 300 } };
const all_panes = [_]*ghost_pane.Pane{ &tree_pane, &tools_pane, &props_pane, &bottom_pane };

// Files ------------------------------------------------------------------------
//
// A document file holds the model as the history's checkpoint and the op
// log since it (see layout.history): saved, it reopens with its undo
// history. Save writes the whole file beside the old one and renames it
// over it, so a failed save never leaves half a file. New, Open and Quit
// with unsaved changes first ask whether to save them.

/// The document's file, once saved or opened (owned).
var file_path: ?[]u8 = null;

const FilePromptKind = enum { open, save_as };
/// A file name is being asked for.
var file_prompt: ?FilePromptKind = null;
var file_prompt_new = false;

/// What waits on the unsaved-changes question, or on a save.
const Pending = enum { new_canvas, open, quit };
var leave_prompt: ?Pending = null;
var after_save: ?Pending = null;
var quit_now = false;

/// The extension Graven's documents take.
const doc_ext = ".graven";

fn setFilePath(path: ?[]const u8) void {
    // Copied before the old one is freed: `path` may be it.
    const next = if (path) |p| state.gpa.dupe(u8, p) catch null else null;
    if (file_path) |old| state.gpa.free(old);
    file_path = next;
    if (file_path) |p| {
        state.file_name = std.fs.path.basename(p);
        state.file_name_set = true;
    } else {
        state.file_name = "untitled";
        state.file_name_set = false;
    }
}

var shown_title: [256]u8 = undefined;
var shown_title_len: usize = 0;

/// The window's title for the desktop: the file, marked while unsaved.
fn updateWindowTitle() void {
    if (dvui.backend.kind != .sdl3) return;
    var buf: [256]u8 = undefined;
    const dirty = !canvas_prompt and hist.isDirty();
    const t = std.fmt.bufPrintSentinel(&buf, "{s}{s} — Graven", .{ if (dirty) "• " else "", state.file_name }, 0) catch return;
    if (std.mem.eql(u8, t, shown_title[0..shown_title_len])) return;
    @memcpy(shown_title[0..t.len], t);
    shown_title_len = t.len;
    _ = dvui.backend.c.SDL_SetWindowTitle(dvui.currentWindow().backend.impl.window, t.ptr);
}

/// Does `p` now, or first asks about unsaved changes.
fn leave(p: Pending) void {
    if (!canvas_prompt and hist.isDirty()) {
        leave_prompt = p;
    } else proceed(p);
}

fn proceed(p: Pending) void {
    switch (p) {
        .new_canvas => newCanvas(),
        .open => {
            file_prompt = .open;
            file_prompt_new = true;
        },
        .quit => quit_now = true,
    }
}

/// Saves to the document's file, or asks for one.
fn save() void {
    if (file_path) |p| {
        _ = writeDocument(p);
    } else saveAs();
}

fn saveAs() void {
    file_prompt = .save_as;
    file_prompt_new = true;
}

// Files: writing, autosave, recovery and other writers -----------------------
//
// A save appends a segment to the document's file when the file is as this
// run left it, and otherwise writes the whole file beside it and renames
// it over it. Every few minutes (`files.autosave_minutes` in the config, 0
// for never) the steps since the last write are appended as unsaved work,
// which a later run can recover if this one ends without saving. Before
// every write the file is read again: if another run (or anything else)
// has written to it, nothing is written and the user decides.

/// This run, as the writer of what it adds to files: a fresh random ID.
var this_run: history.Writer = .{ .id = @splat(0) };
var device_buf: [256]u8 = undefined;

fn initWriter() void {
    var random: [16]u8 = undefined;
    dvui.io.random(&random);
    const device: []const u8 = if (builtin.os.tag == .windows or builtin.os.tag == .wasi) "" else std.posix.gethostname(device_buf[0..std.posix.HOST_NAME_MAX]) catch "";
    this_run = .{ .id = history.writerId(random), .device = device, .tool = history.tool_version };
}

fn nowSeconds() i64 {
    return std.Io.Clock.real.now(dvui.io).toSeconds();
}

/// "2026-11-10 23:31" (UTC), for names and messages.
fn stamp(buf: []u8, seconds: i64, sep: u8) []const u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, seconds)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d}-{d:0>2}-{d:0>2} {d:0>2}{c}{d:0>2}", .{ yd.year, md.month.numeric(), md.day_index + 1, ds.getHoursIntoDay(), sep, ds.getMinutesIntoHour() }) catch "";
}

var autosave_minutes: u32 = 2;
/// Set when a write was refused or put off; cleared by the next save.
var autosave_paused = false;

/// Another run has written to the file: the write of this kind waits for
/// the user's choice.
var contention: ?history.WriteKind = null;

/// A file opened with unsaved steps in it, waiting for the user to keep or
/// discard them.
var recovery: ?struct { opened: history.Opened, path: []u8 } = null;

/// Whether a prompt about files is up, over the new-canvas prompt.
fn filePromptOpen() bool {
    return file_prompt != null or leave_prompt != null or recovery != null or contention != null;
}

/// Writes the document to `path` as a save.
fn writeDocument(path: []const u8) bool {
    return writeTo(path, .save, false);
}

/// `path` with " (<what> <time>)" before its extension: a backup or a copy.
fn sideName(buf: []u8, path: []const u8, what: []const u8) []const u8 {
    const ext = std.fs.path.extension(path);
    var tb: [32]u8 = undefined;
    const now = nowSeconds();
    return std.fmt.bufPrint(buf, "{s} ({s} {s}.{d:0>2}){s}", .{ path[0 .. path.len - ext.len], what, stamp(&tb, now, '.'), @as(u64, @intCast(@mod(now, 60))), if (ext.len > 0) ext else doc_ext }) catch path;
}

/// Copies the file at `path` aside, as it is, before it is overwritten.
fn backup(path: []const u8, buf: []u8) ?[]const u8 {
    const name = sideName(buf, path, "backup");
    const dir = std.Io.Dir.cwd();
    dir.copyFile(path, dir, name, dvui.io, .{}) catch return null;
    return name;
}

/// Writes `bytes` as the whole file at `path`: beside it first, then
/// renamed over it, so there is never half a file.
fn writeWhole(path: []const u8, bytes: []const u8) bool {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.saving", .{path}) catch return false;
    const dir = std.Io.Dir.cwd();
    dir.writeFile(dvui.io, .{ .sub_path = tmp, .data = bytes }) catch return false;
    dir.rename(tmp, dir, path, dvui.io) catch return false;
    return true;
}

/// Writes `bytes` into the file at `path` at offset `at`, and syncs it.
fn writeAt(path: []const u8, bytes: []const u8, at: u64) bool {
    const io = dvui.io;
    const f = std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write }) catch return false;
    defer f.close(io);
    f.writePositionalAll(io, bytes, at) catch return false;
    f.sync(io) catch return false;
    return true;
}

/// Writes one write from the history to `path`.
fn put(path: []const u8, w: *const history.Write) bool {
    return if (w.at) |at| writeAt(path, w.bytes, at) else writeWhole(path, w.bytes);
}

/// Whether the file at `path` is as this run last left it; true when it
/// is gone (nothing to overwrite). Null when it cannot be read.
fn fileUnchanged(path: []const u8) ?bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(dvui.io, path, state.gpa, .limited(1 << 30)) catch |err| switch (err) {
        error.FileNotFound => return true,
        else => return null,
    };
    defer state.gpa.free(bytes);
    return history.fileIsAsLeft(&hist, bytes);
}

/// Writes the document to `path`: a save, or an autosave of the steps
/// since the last write. Appends when it can; `fresh` writes the whole
/// file. Returns whether it was written.
fn writeTo(path: []const u8, kind: history.WriteKind, fresh_asked: bool) bool {
    var fresh = fresh_asked;
    const same = if (file_path) |p| std.mem.eql(u8, p, path) else false;
    if (!same) {
        fresh = true;
    } else if (!fresh) {
        const unchanged = fileUnchanged(path) orelse {
            state.status = "The document's file could not be read: nothing was written. ";
            return false;
        };
        if (!unchanged) {
            contention = kind;
            dvui.refresh(null, @src(), null);
            return false;
        }
        // Gone: written afresh.
        if (std.Io.Dir.cwd().access(dvui.io, path, .{})) |_| {} else |_| fresh = true;
    }
    var w = history.prepareWrite(&hist, state.gpa, this_run, nowSeconds(), kind, fresh) catch |err| {
        if (err == error.SavedStateLost) {
            autosave_paused = true;
            state.status = "Autosave is waiting for a save: the history no longer holds the saved document. ";
        } else state.status = "The document could not be made ready to write. ";
        return false;
    };
    defer w.deinit(state.gpa);
    if (!put(path, &w)) {
        state.status = "The document could not be written there. ";
        return false;
    }
    history.wrote(&hist, &w);
    if (kind == .save) {
        setFilePath(path);
        autosave_paused = false;
        state.status = "Saved. ";
    }
    dvui.refresh(null, @src(), null);
    if (kind == .save) if (after_save) |p| {
        after_save = null;
        proceed(p);
    };
    return true;
}

/// Every `autosave_minutes`, the steps since the last write go to the
/// file as unsaved work.
fn autosaveTick(id: dvui.Id) void {
    if (autosave_minutes == 0) return;
    if (dvui.timerDone(id)) autosave();
    if (dvui.timerDoneOrNone(id)) dvui.timer(id, @intCast(@as(u64, autosave_minutes) * 60 * std.time.us_per_s));
}

fn autosave() void {
    const path = file_path orelse return;
    if (autosave_paused or canvas_prompt or contention != null or recovery != null) return;
    if (!history.changedSinceWrite(&hist)) return;
    if (writeTo(path, .autosave, false)) {
        var tb: [32]u8 = undefined;
        state.status = std.fmt.bufPrint(&status_buf, "Autosaved at {s} UTC (unsaved until you save). ", .{stamp(&tb, nowSeconds(), ':')[11..]}) catch "Autosaved. ";
    }
}

var status_buf: [256]u8 = undefined;

/// The user chose not to save: the steps autosaved since the last save
/// are dropped from the file too, so they are not offered back later.
fn discardAutosaved() void {
    const path = file_path orelse return;
    var d = (history.prepareDiscard(&hist, state.gpa, this_run, nowSeconds()) catch return) orelse return;
    defer d.deinit(state.gpa);
    if ((fileUnchanged(path) orelse false) and put(path, &d)) history.wroteDiscard(&hist, &d);
}

/// Opens the document at `path`, replacing the one open; when it holds
/// unsaved steps, asks first whether to keep them.
fn openDocument(path: []const u8) void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(dvui.io, path, state.gpa, .limited(1 << 30)) catch {
        state.status = "That file could not be read. ";
        return;
    };
    defer state.gpa.free(bytes);
    var opened = history.openFile(state.gpa, bytes) catch |err| {
        state.status = switch (err) {
            error.BadFile, error.NoModel => "That is not a Graven document. ",
            error.TooNew => "That document is from a newer Graven. ",
            error.BadChecksum, error.Truncated => "That document is damaged where its model is stored: it cannot be opened. ",
            else => "That document could not be opened. ",
        };
        return;
    };
    if (opened.unsaved != null) {
        const p = state.gpa.dupe(u8, path) catch {
            opened.model.deinit();
            opened.history.deinit();
            return;
        };
        recovery = .{ .opened = opened, .path = p };
        dvui.refresh(null, @src(), null);
        return;
    }
    install(&opened, path);
    state.status = if (opened.damaged) "Opened. The end of the file was damaged: the last changes in it are lost. " else "Opened. ";
}

/// Makes `opened` the document open, from `path`.
fn install(opened: *history.Opened, path: []const u8) void {
    newCanvas();
    state.model.deinit();
    state.model = opened.model;
    hist.deinit();
    hist = opened.history;
    canvas_prompt = false;
    shown_space = 0;
    state.context = if (state.model.spaces.items.len > 0) .{ .panel = state.model.spaces.items[0].root } else .worksheet;
    for (state.model.styles.items, 0..) |st, si| {
        if (std.mem.eql(u8, st.name, "Label")) state.label_style = @intCast(si);
    }
    state.view.fit = canvas_view;
    setFilePath(path);
    autosave_paused = false;
    dvui.refresh(null, @src(), null);
}

/// A centred modal prompt over the canvas.
fn promptWindow(src: std.builtin.SourceLocation, id: usize, w: f32, h: f32) ?*dvui.FloatingWindowWidget {
    const c = canvas_rect;
    if (c.w <= 0 or c.h <= 0) return null;
    const S = struct {
        var r: dvui.Rect = .{};
    };
    S.r = .{ .x = c.x + (c.w - w) / 2, .y = c.y + (c.h - h) / 2, .w = w, .h = h };
    return dvui.floatingWindow(src, .{ .rect = &S.r, .resize = .none, .modal = true }, overlayOptions(id));
}

/// The file holds steps after its last save, by a run that ended (or is
/// still open elsewhere) without saving them: keep them, or go back to
/// the save.
fn recoveryPrompt() void {
    const rec = &(recovery orelse return);
    const u = rec.opened.unsaved.?;
    var fw = promptWindow(@src(), 14, 600, 175) orelse return;
    defer fw.deinit();
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(12) });
    defer body.deinit();
    dvui.label(@src(), "{s} has changes that were never saved", .{std.fs.path.basename(rec.path)}, .{ .font = dvui.Font.theme(.heading) });
    var tb: [32]u8 = undefined;
    const by = if (u.device.len > 0) u.device else "another computer";
    dvui.label(@src(), "Made after its last save, on {s} at {s} UTC,", .{ by, stamp(&tb, u.time, ':') }, .{ .margin = .{ .y = 6 } });
    dvui.labelNoFmt(@src(), "by a session that ended without saving them, or is still open there.", .{}, .{});
    if (rec.opened.damaged) dvui.labelNoFmt(@src(), "The end of the file was damaged: the last of them are lost.", .{}, .{});
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1, .margin = .{ .y = 10 } });
    defer row.deinit();
    if (dvui.button(@src(), "Cancel", .{}, .{})) {
        rec.opened.model.deinit();
        rec.opened.history.deinit();
        state.gpa.free(rec.path);
        recovery = null;
        return;
    }
    if (dvui.button(@src(), "Discard them", .{}, .{})) {
        var bb: [std.fs.max_path_bytes]u8 = undefined;
        const copy = backup(rec.path, &bb);
        rec.opened.discardUnsaved() catch {
            state.status = "The saved document could not be rebuilt. ";
            return;
        };
        finishRecovery(rec, .save);
        state.status = if (copy) |c| std.fmt.bufPrint(&status_buf, "Opened as last saved. The file as it was is kept as {s}. ", .{std.fs.path.basename(c)}) catch "Opened as last saved. " else "Opened as last saved. A backup copy could not be made. ";
        return;
    }
    if (dvui.button(@src(), "Keep them", .{}, .{})) {
        finishRecovery(rec, .autosave);
        state.status = "Opened with the changes kept; they are not saved yet. ";
    }
}

/// Installs the recovered document and writes its file afresh under this
/// run, so no file mixes two runs' unsaved work.
fn finishRecovery(rec: anytype, kind: history.WriteKind) void {
    install(&rec.opened, rec.path);
    _ = writeTo(rec.path, kind, true);
    state.gpa.free(rec.path);
    recovery = null;
}

/// Another run (or program) wrote to the file since this one did.
fn contentionPrompt(kind: history.WriteKind) void {
    var fw = promptWindow(@src(), 15, 640, 175) orelse return;
    defer fw.deinit();
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(12) });
    defer body.deinit();
    dvui.label(@src(), "{s} was changed elsewhere", .{state.file_name}, .{ .font = dvui.Font.theme(.heading) });
    dvui.labelNoFmt(@src(), "Another Graven session, or another program, has written to it", .{}, .{ .margin = .{ .y = 6 } });
    dvui.labelNoFmt(@src(), "since this one did, so nothing was written. Your changes are still here.", .{}, .{});
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1, .margin = .{ .y = 10 } });
    defer row.deinit();
    const path = file_path orelse {
        contention = null;
        return;
    };
    if (dvui.button(@src(), "Not now", .{}, .{})) {
        contention = null;
        after_save = null;
        autosave_paused = true;
        state.status = "Not written: the file was changed elsewhere. Autosave waits until you save. ";
        return;
    }
    if (dvui.button(@src(), "Load theirs", .{}, .{})) {
        contention = null;
        after_save = null;
        // Mine first, as a copy beside it.
        var nb: [std.fs.max_path_bytes]u8 = undefined;
        const mine = sideName(&nb, path, "mine");
        const theirs = state.gpa.dupe(u8, path) catch return;
        defer state.gpa.free(theirs);
        if (!writeTo(mine, .save, true)) return;
        var kept: [std.fs.max_path_bytes]u8 = undefined;
        const kept_name = std.fmt.bufPrint(&kept, "{s}", .{std.fs.path.basename(mine)}) catch "";
        openDocument(theirs);
        if (recovery == null) state.status = std.fmt.bufPrint(&status_buf, "Opened theirs. Your version is saved as {s}. ", .{kept_name}) catch "Opened theirs. ";
        return;
    }
    if (dvui.button(@src(), "Save mine as…", .{}, .{})) {
        contention = null;
        saveAs();
        return;
    }
    if (dvui.button(@src(), "Overwrite with mine", .{}, .{})) {
        contention = null;
        var bb: [std.fs.max_path_bytes]u8 = undefined;
        const copy = backup(path, &bb);
        if (writeTo(path, if (kind == .save) .save else .autosave, true)) {
            state.status = if (copy) |c| std.fmt.bufPrint(&status_buf, "Written over it. Theirs is kept as {s}. ", .{std.fs.path.basename(c)}) catch "Written over it. " else "Written over it. ";
        }
    }
}

/// The file prompt: a name to open or save as; Enter or the button does
/// it, Esc or Cancel closes it.
fn filePrompt(kind: FilePromptKind) void {
    const c = canvas_rect;
    if (c.w <= 0 or c.h <= 0) return;
    const w: f32 = 460;
    const h: f32 = 185;
    var r: dvui.Rect = .{ .x = c.x + (c.w - w) / 2, .y = c.y + (c.h - h) / 2, .w = w, .h = h };
    var fw = dvui.floatingWindow(@src(), .{ .rect = &r, .resize = .none }, overlayOptions(12));
    defer fw.deinit();
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(12) });
    defer body.deinit();
    dvui.labelNoFmt(@src(), if (kind == .open) "Open a document" else "Save the document as", .{}, .{ .font = dvui.Font.theme(.heading) });
    var go = false;
    var cancel = false;
    for (dvui.events()) |*e| {
        if (e.evt != .key or e.handled) continue;
        const k = e.evt.key;
        if (k.action != .down) continue;
        if (k.code == .enter or k.code == .kp_enter) go = true else if (k.code == .escape) cancel = true else continue;
        e.handle(@src(), fw.data());
    }
    var path: []const u8 = "";
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 8 } });
        defer row.deinit();
        propName("File");
        const initial = if (kind == .save_as) (file_path orelse "untitled" ++ doc_ext) else "";
        var te = dvui.textEntry(@src(), .{ .text_initial = initial }, .{ .expand = .horizontal, .id_extra = @intFromEnum(kind) });
        defer te.deinit();
        if (file_prompt_new) {
            // The prompt's window takes the keys, so Enter and Esc reach it.
            dvui.focusSubwindow(fw.data().id, null);
            dvui.focusWidget(te.data().id, fw.data().id, null);
            file_prompt_new = false;
        }
        if (te.enter_pressed) go = true;
        path = dvui.currentWindow().arena().dupe(u8, std.mem.trim(u8, te.textGet(), " ")) catch "";
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1, .margin = .{ .y = 8 } });
        defer row.deinit();
        if (dvui.button(@src(), "Cancel", .{}, .{})) cancel = true;
        if (dvui.button(@src(), if (kind == .open) "Open" else "Save", .{}, .{})) go = true;
    }
    if (cancel) {
        file_prompt = null;
        after_save = null;
        dvui.refresh(null, @src(), null);
        return;
    }
    if (!go or path.len == 0) return;
    file_prompt = null;
    dvui.refresh(null, @src(), null);
    switch (kind) {
        .open => openDocument(path),
        .save_as => {
            // A name without an extension takes Graven's.
            const full = if (std.fs.path.extension(path).len == 0) (std.mem.concat(dvui.currentWindow().arena(), u8, &.{ path, doc_ext }) catch path) else path;
            if (!writeDocument(full)) after_save = null;
        },
    }
}

/// Unsaved changes: Save (then go on), Don't save, or Cancel.
fn leavePrompt(p: Pending) void {
    const c = canvas_rect;
    if (c.w <= 0 or c.h <= 0) return;
    const w: f32 = 460;
    const h: f32 = 150;
    var r: dvui.Rect = .{ .x = c.x + (c.w - w) / 2, .y = c.y + (c.h - h) / 2, .w = w, .h = h };
    var fw = dvui.floatingWindow(@src(), .{ .rect = &r, .resize = .none, .modal = true }, overlayOptions(13));
    defer fw.deinit();
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(12) });
    defer body.deinit();
    dvui.label(@src(), "{s} has unsaved changes", .{state.file_name}, .{ .font = dvui.Font.theme(.heading) });
    const doing = switch (p) {
        .new_canvas => "starting a new canvas",
        .open => "opening another document",
        .quit => "quitting",
    };
    dvui.label(@src(), "Save them before {s}?", .{doing}, .{ .margin = .{ .y = 6 } });
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1, .margin = .{ .y = 10 } });
    defer row.deinit();
    if (dvui.button(@src(), "Cancel", .{}, .{})) leave_prompt = null;
    if (dvui.button(@src(), "Don't save", .{}, .{})) {
        leave_prompt = null;
        discardAutosaved();
        proceed(p);
    }
    if (dvui.button(@src(), "Save", .{}, .{})) {
        leave_prompt = null;
        after_save = p;
        save();
    }
}

// Undo -------------------------------------------------------------------------
//
// Every change to the model is an action, done through `act` (or `actV`
// for those that cannot fail, `actM` for runs that undo as one step) and
// logged by the history: undo restores its checkpoint and replays the
// steps before the last; redo applies undone steps again.

var hist: history.History = undefined;

fn act(comptime tag: history.Tag, args: history.Args(@tagName(tag))) history.Error!history.Result(@tagName(tag)) {
    return hist.do(&state.model, tag, args);
}

/// An action that cannot fail but for memory to log it.
fn actV(comptime tag: history.Tag, args: history.Args(@tagName(tag))) void {
    hist.do(&state.model, tag, args) catch {
        state.status = "That change could not be recorded. ";
    };
}

/// An action that joins the step before when that had the same `key`: a
/// run of nudges, or typing, undone as one.
fn actM(key: u64, comptime tag: history.Tag, args: history.Args(@tagName(tag))) history.Error!history.Result(@tagName(tag)) {
    return hist.doMerged(&state.model, key, tag, args);
}

fn mergeKey(parts: anytype) u64 {
    var h: std.hash.Wyhash = .init(0);
    std.hash.autoHashStrat(&h, parts, .Deep);
    return h.final();
}

/// Ctrl+Z undoes; Ctrl+Shift+Z (and Ctrl+Y off macOS) redoes. Cmd on
/// macOS. Held, they repeat.
fn historyKeys(wd: *dvui.WidgetData) void {
    if (file_prompt != null or leave_prompt != null) return;
    for (dvui.events()) |*e| {
        if (e.evt != .key or e.handled) continue;
        const k = e.evt.key;
        if (k.action != .down and k.action != .repeat) continue;
        const primary = if (builtin.os.tag == .macos) k.mod.command() else k.mod.control();
        if (!primary) continue;
        if (k.code == .z and !k.mod.shift()) {
            e.handle(@src(), wd);
            if (!canvas_prompt) undo();
        } else if (k.code == .s and k.action == .down) {
            e.handle(@src(), wd);
            if (!canvas_prompt) {
                if (k.mod.shift()) saveAs() else save();
            }
        } else if (k.code == .o and k.action == .down) {
            e.handle(@src(), wd);
            leave(.open);
        } else if (k.code == .n and k.action == .down) {
            e.handle(@src(), wd);
            leave(.new_canvas);
        } else if ((k.code == .z and k.mod.shift()) or (k.code == .y and builtin.os.tag != .macos)) {
            e.handle(@src(), wd);
            if (!canvas_prompt) redo();
        } else continue;
        dvui.refresh(null, @src(), null);
    }
}

fn undo() void {
    const done = hist.undo(&state.model) catch {
        state.status = "Undo failed. ";
        return;
    };
    state.status = if (done) "" else "Nothing to undo. ";
    afterHistory();
}

fn redo() void {
    const done = hist.redoStep(&state.model) catch {
        state.status = "Redo failed. ";
        return;
    };
    state.status = if (done) "" else "Nothing to redo. ";
    afterHistory();
}

/// After undo or redo, what pointed into the model may point at nothing:
/// the context, the selection and the flow cursor fall back to what still
/// exists.
fn afterHistory() void {
    selection.clearRetainingCapacity();
    track_cursor = null;
    state.moving = null;
    state.moving_label = null;
    if (!contextValid(state.context)) {
        state.context = if (state.model.spaces.items.len > shown_space) .{ .panel = state.model.spaces.items[shown_space].root } else .worksheet;
    }
    if (shown_space >= state.model.spaces.items.len) shown_space = 0;
}

fn contextValid(c: Context) bool {
    const m = &state.model;
    const np = m.panels.items.len;
    return switch (c) {
        .file, .worksheet, .prototypes, .selection => true,
        .panel => |pi| pi < np,
        .region => |r| r.panel < np and r.region < m.panels.items[r.panel].regions.items.len,
        .row => |r| r.panel < np and r.region < m.panels.items[r.panel].regions.items.len and r.row < m.panels.items[r.panel].regions.items[r.region].segments.items.len,
        .tile => |id| @intFromEnum(id) < m.tiles.items.len and !m.tileConst(id).removed,
        .label => |l| l.panel < np and l.index < m.panels.items[l.panel].labels.items.len,
        .art => |l| l.panel < np and l.index < m.panels.items[l.panel].art.items.len,
        .group => |g| m.group(g) != null,
        .view => |v| v.space < m.spaces.items.len and v.index < m.spaces.items[v.space].views.items.len,
        .layer => |l| l.space < m.spaces.items.len and l.index < m.spaces.items[l.space].layers.items.len,
        .image => |im| im.space < m.spaces.items.len and im.index < m.spaces.items[im.space].images.items.len,
        .prototype => |id| id < m.prototypes.items.len,
    };
}

// Settings --------------------------------------------------------------------
//
// Preferences are read from the config files at start (see settings.zig:
// shared.toml, then local.toml over it) and written back when they change.
// Shared (how the user likes to work): the units a new canvas starts in,
// text construction, hot edges. Local (this machine's layout): each pane's
// mode, where the right edge's panes meet.

var prefs_store: ?settings_file.Store = null;

const Prefs = struct {
    units: layout.model.Units,
    show_construction: bool,
    hot_edges: bool,
    modes: [all_panes.len]ghost_pane.Mode,
    tools_height: f32,

    fn eql(a: Prefs, b: Prefs) bool {
        return std.meta.eql(a, b);
    }
};

/// The keys of each pane's mode, in `all_panes` order.
const pane_keys = [all_panes.len][]const u8{ "panes.tree.mode", "panes.tools.mode", "panes.properties.mode", "panes.bottom.mode" };

var saved_prefs: ?Prefs = null;

fn currentPrefs() Prefs {
    var modes: [all_panes.len]ghost_pane.Mode = undefined;
    for (all_panes, &modes) |p, *m| m.* = p.mode;
    return .{ .units = last_units, .show_construction = show_construction, .hot_edges = hot_edges, .modes = modes, .tools_height = tools_height };
}

/// Reads the config files and applies what they set; what they leave out
/// keeps its default.
fn loadPrefs() void {
    var ps = settings_file.load(state.gpa, dvui.io);
    loadLocale(&ps);
    // How often unsaved work goes to the file, in minutes (0: never).
    if (ps.get("files.autosave_minutes")) |v| if (v == .integer) {
        autosave_minutes = @intCast(std.math.clamp(v.integer, 0, 30));
    };
    if (ps.get("canvas.units")) |v| if (v == .string) if (std.meta.stringToEnum(layout.model.Units, v.string)) |u| {
        last_units = u;
    };
    if (ps.get("view.show_text_construction")) |v| if (v == .boolean) {
        show_construction = v.boolean;
    };
    if (ps.get("panes.hot_edges")) |v| if (v == .boolean) {
        hot_edges = v.boolean;
    };
    for (all_panes, pane_keys) |p, key| if (ps.get(key)) |v| if (v == .string) if (std.meta.stringToEnum(ghost_pane.Mode, v.string)) |m| {
        p.mode = m;
    };
    if (ps.get("panes.tools_height")) |v| switch (v) {
        .float => |f| tools_height = @floatCast(f),
        .integer => |i| tools_height = @floatFromInt(i),
        else => {},
    };
    if (ps.problem()) |msg| state.status = msg;
    prefs_store = ps;
    saved_prefs = currentPrefs();
}

// Locale ----------------------------------------------------------------------
//
// The user's languages and measurement system: from `[locale]` in the
// config files when set there, else from the system (see locale.zig). The
// measurement system picks a new canvas's units (mm or inches) until the
// user has chosen units (`canvas.units`). The languages are kept for the
// interface text to come.

/// Preferred languages, most preferred first.
var languages: []const locale.Locale = &.{};
var measurement: locale.Measurement = .metric;
var measurement_source: locale.Source = .default;

/// The system's preferred languages, as SDL reports them.
fn systemLanguages(gpa: std.mem.Allocator) []const locale.Locale {
    const c = dvui.backend.c;
    var n_locales: c_int = 0;
    const list = c.SDL_GetPreferredLocales(&n_locales) orelse return &.{};
    defer c.SDL_free(@ptrCast(list));
    const out = gpa.alloc(locale.Locale, @intCast(n_locales)) catch return &.{};
    var n: usize = 0;
    for (0..@intCast(n_locales)) |i| {
        const l = list[i] orelse continue;
        const lang = l.*.language orelse continue;
        out[n] = .{
            .language = gpa.dupe(u8, std.mem.span(lang)) catch continue,
            .country = if (l.*.country) |ct| gpa.dupe(u8, std.mem.span(ct)) catch null else null,
        };
        n += 1;
    }
    return out[0..n];
}

/// Reads `[locale]` from the config files and the system's locale, and
/// sets the languages, the measurement system and from it the default
/// units of a new canvas.
fn loadLocale(ps: *const settings_file.Store) void {
    const gpa = state.gpa;
    languages = systemLanguages(gpa);
    // `languages = ["en-GB", "de"]` (or one tag) in the config wins.
    if (ps.get("locale.languages")) |v| {
        var list: std.ArrayList(locale.Locale) = .empty;
        const tags: []const settings_file.Value = switch (v) {
            .array => |xs| xs,
            .string => &.{v},
            else => &.{},
        };
        for (tags) |t| if (t == .string) if (locale.parseTag(t.string)) |l| {
            list.append(gpa, .{ .language = gpa.dupe(u8, l.language) catch continue, .country = if (l.country) |ct| gpa.dupe(u8, ct) catch null else null }) catch {};
        };
        if (list.items.len > 0) languages = list.items;
    }
    const from_config: ?locale.Measurement = if (ps.get("locale.measurement")) |v| (if (v == .string) std.meta.stringToEnum(locale.Measurement, v.string) else null) else null;
    const d = locale.decide(from_config, locale.systemMeasurement(), languages);
    measurement = d.measurement;
    measurement_source = d.source;
    last_units = if (measurement == .imperial) .inch else .mm;
}

/// Writes the preferences back when one has changed since they were last
/// read or written.
fn savePrefsIfChanged() void {
    const ps = &(prefs_store orelse return);
    const now = currentPrefs();
    if (saved_prefs) |old| if (old.eql(now)) return;
    // A split being dragged is written once it rests.
    if (split_dragging) return;
    saved_prefs = now;
    ps.put("canvas.units", .{ .string = @tagName(now.units) }, .shared);
    ps.put("view.show_text_construction", .{ .boolean = now.show_construction }, .shared);
    ps.put("panes.hot_edges", .{ .boolean = now.hot_edges }, .shared);
    for (now.modes, pane_keys) |m, key| ps.put(key, .{ .string = @tagName(m) }, .local);
    ps.put("panes.tools_height", .{ .integer = @intFromFloat(@round(now.tools_height)) }, .local);
    if (ps.save(dvui.io)) |msg| state.status = msg;
}

/// Hot edges: holding the pointer on a ghost pane's tab activates it.
var hot_edges = false;

/// The strips along the window's edges that hold the panes' tabs, logical
/// pixels.
const tab_size = 18;

const tree_width = 240;
const properties_width = 320;
/// The bottom area: the expression line above the status line.
const expression_height = 38;
const status_line_height = 32;
const status_height = expression_height + status_line_height;
/// Space between the key palette and the panes beside it.
const overlay_gap = 6;
/// How opaque an overlay's background is.
const overlay_alpha = 0.84;

/// The canvas's rectangle in logical pixels, from the last frame: overlays
/// anchor to it.
var canvas_rect: dvui.Rect = .{};

/// A side edge's strip, holding its pane's tab as tall as the pane.
fn sideStrip(p: *ghost_pane.Pane, h: f32, id: usize) void {
    var strip = dvui.box(@src(), .{ .dir = .vertical }, .{
        .id_extra = id,
        .min_size_content = .{ .w = tab_size },
        .max_size_content = .width(tab_size),
        .expand = .vertical,
        .background = true,
        .color_fill = .{ .color = colors.titlebar },
    });
    defer strip.deinit();
    applyTab(p, ghost_pane.tab(p, .{ .x = 0, .y = 0, .w = tab_size, .h = h }, id));
}

/// Whether the right edge's column is laid out beside the canvas: either of
/// its panes is docked.
fn rightDocked() bool {
    return tools_pane.mode == .docked or props_pane.mode == .docked;
}

/// The tool palette's height for a right edge `h` tall, kept so both panes
/// keep some room.
fn toolsHeight(h: f32) f32 {
    return std.math.clamp(tools_height, min_pane_height, @max(min_pane_height, h - split_grip - min_pane_height));
}

/// The right edge's strip: the tools pane's tab, the grip where the two
/// panes meet (drag it up or down), then the properties pane's tab.
fn rightStrip(h: f32) void {
    var strip = dvui.box(@src(), .{ .dir = .vertical }, .{
        .min_size_content = .{ .w = tab_size },
        .max_size_content = .width(tab_size),
        .expand = .vertical,
        .background = true,
        .color_fill = .{ .color = colors.titlebar },
    });
    defer strip.deinit();
    const th = toolsHeight(h);
    applyTab(&tools_pane, ghost_pane.tab(&tools_pane, .{ .x = 0, .y = 0, .w = tab_size, .h = th }, 2));
    splitGrip(strip.data(), th);
    applyTab(&props_pane, ghost_pane.tab(&props_pane, .{ .x = 0, .y = th + split_grip, .w = tab_size, .h = @max(0, h - th - split_grip) }, 4));
}

/// The grip between the right edge's tabs: dragged, it moves where the
/// tool palette ends and the properties begin.
fn splitGrip(strip: *dvui.WidgetData, at: f32) void {
    var grip = dvui.box(@src(), .{}, .{
        .rect = .{ .x = 0, .y = at, .w = tab_size, .h = split_grip },
        .background = true,
        .color_fill = .{ .color = colors.titlebar },
    });
    defer grip.deinit();
    const r = grip.data().contentRectScale().r;
    const ns = dvui.windowNaturalScale();
    // Three dots, to say it can be gripped.
    const mid: dvui.Point.Physical = .{ .x = r.x + r.w / 2, .y = r.y + r.h / 2 };
    for ([_]f32{ -4, 0, 4 }) |dx| {
        const d: dvui.Rect.Physical = .{ .x = mid.x + dx * ns - ns, .y = mid.y - ns, .w = 2 * ns, .h = 2 * ns };
        d.fill(.square, .{ .color = .{ .color = colors.panel_edge } });
    }
    const top = strip.contentRectScale().r.y;
    split_dragging = dvui.captured(grip.data().id);
    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, grip.data())) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            .press => if (me.button.pointer()) {
                e.handle(@src(), grip.data());
                dvui.captureMouse(grip.data(), e.num);
                dvui.dragPreStart(me.button, me.p, .{ .cursor = .arrow_n_s });
            },
            .release => if (dvui.captured(grip.data().id)) {
                e.handle(@src(), grip.data());
                dvui.captureMouse(null, e.num);
                dvui.dragEnd(me.button);
                split_dragging = false;
            },
            .motion => if (dvui.captured(grip.data().id)) {
                e.handle(@src(), grip.data());
                tools_height = (me.p.y - top) / ns - split_grip / 2;
                dvui.refresh(null, @src(), grip.data().id);
            },
            .position => dvui.cursorSet(.arrow_n_s),
            else => {},
        }
    }
}

/// The right edge's docked column: the tool palette above (or room for it,
/// when it is not docked), the properties below.
fn rightColumn() !void {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = properties_width }, .max_size_content = .width(properties_width), .expand = .vertical, .border = .{ .x = 1 } });
    defer col.deinit();
    const th = toolsHeight(col.data().contentRect().h);
    {
        var top = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .h = th }, .max_size_content = .height(th), .expand = .horizontal, .background = tools_pane.mode == .docked, .color_fill = .{ .color = ghost_pane.fill(&tools_pane) } });
        defer top.deinit();
        if (tools_pane.mode == .docked) {
            const prev = ghost_pane.themePush(&tools_pane);
            defer ghost_pane.themePop(prev);
            toolsContent();
        }
    }
    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = split_grip } });
    var rest = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = props_pane.mode == .docked, .color_fill = .{ .color = ghost_pane.fill(&props_pane) } });
    defer rest.deinit();
    if (props_pane.mode == .docked) {
        const prev = ghost_pane.themePush(&props_pane);
        defer ghost_pane.themePop(prev);
        try propertiesBody();
    }
}

/// What a tab asked for, done; the canvas takes the keyboard back from a
/// pane that stops taking events.
fn applyTab(p: *ghost_pane.Pane, r: ghost_pane.TabResult) void {
    if (r == .none) return;
    const had = p.interactive();
    ghost_pane.apply(&all_panes, p, r);
    if (had and !p.interactive()) if (canvas_id) |id| dvui.focusWidget(id, null, null);
    dvui.refresh(null, @src(), null);
}

/// How much of each canvas edge ghost panes cover, logical pixels, so
/// fitting a view keeps its subject clear of them.
fn overlayInsets() struct { left: f32, right: f32, bottom: f32 } {
    return .{
        .left = if (tree_pane.mode == .ghost) tree_width + overlay_gap else 0,
        .right = if (!rightDocked() and (props_pane.mode == .ghost or tools_pane.mode == .ghost)) properties_width + overlay_gap else 0,
        .bottom = if (bottom_pane.mode == .ghost) status_height + overlay_gap else 0,
    };
}

fn overlayOptions(id: usize) dvui.Options {
    return .{
        .id_extra = id,
        .background = true,
        .color_fill = .{ .color = dvui.themeGet().color(.window, .fill).opacity(overlay_alpha) },
        .border = .all(1),
        .color_border = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.12) },
        .corners = .all(8),
        .box_shadow = null,
    };
}

/// The ghost panes over the canvas, attached to its edges, then the key
/// palette and any prompt.
fn overlays() !void {
    for (all_panes) |p| {
        if (p.mode != .ghost) {
            p.rect_px = .{};
            p.sub_id = null;
        }
    }
    const c = canvas_rect;
    if (c.w <= 0 or c.h <= 0) return;
    const g: f32 = overlay_gap;
    const bottom: f32 = if (bottom_pane.mode == .ghost) status_height else 0;
    if (tree_pane.mode == .ghost) {
        var o = ghost_pane.begin(&tree_pane, .{ .x = c.x, .y = c.y, .w = tree_width, .h = @max(60, c.h - bottom) }, 1);
        defer o.end();
        treeContent();
    }
    {
        // The right edge: over the canvas's right side, or over the docked
        // column's room when the other pane there is docked.
        const x = if (rightDocked()) c.x + c.w + 1 else c.x + c.w - properties_width;
        const h = @max(2 * min_pane_height + split_grip, c.h - if (rightDocked()) 0 else bottom);
        const th = toolsHeight(h);
        if (tools_pane.mode == .ghost) {
            var o = ghost_pane.begin(&tools_pane, .{ .x = x, .y = c.y, .w = properties_width, .h = th }, 2);
            defer o.end();
            toolsContent();
        }
        if (props_pane.mode == .ghost) {
            var o = ghost_pane.begin(&props_pane, .{ .x = x, .y = c.y + th + split_grip, .w = properties_width, .h = h - th - split_grip }, 4);
            defer o.end();
            try propertiesBody();
        }
    }
    if (bottom_pane.mode == .ghost) {
        var o = ghost_pane.begin(&bottom_pane, .{ .x = c.x, .y = c.y + c.h - status_height, .w = c.w, .h = status_height }, 3);
        defer o.end();
        try bottomContent();
    }
    // A key palette across the top of the canvas, between the panes: the
    // insert palette while there is a flow cursor, the move palette for a
    // selected track.
    const moving_track = track_cursor == null and state.context == .row;
    if (track_cursor != null or moving_track) {
        const left: f32 = if (tree_pane.mode == .ghost) tree_width + g else g;
        const right: f32 = if (!rightDocked() and tools_pane.mode == .ghost) properties_width + g else g;
        var r: dvui.Rect = .{ .x = c.x + left, .y = c.y + g, .w = @max(200, c.w - left - right), .h = if (moving_track) move_palette_height else palette_height };
        // Lighter than the panes: the tracks being filled show through.
        var fw = dvui.floatingWindow(@src(), .{ .rect = &r, .resize = .none }, overlayOptions(4).override(.{
            .color_fill = .{ .color = dvui.themeGet().color(.window, .fill).opacity(palette_alpha) },
        }));
        defer fw.deinit();
        if (moving_track) movePalette() else trackPalette();
    }
    // The new-canvas prompt waits under an open or save prompt, so Enter
    // goes to the prompt on top.
    if (canvas_prompt and !filePromptOpen()) newCanvasPrompt();
    if (export_prompt) exportPrompt();
    if (image_prompt) imagePrompt();
    if (file_prompt) |kind| filePrompt(kind);
    if (leave_prompt) |p| leavePrompt(p);
    if (recovery != null) recoveryPrompt();
    if (contention) |k| contentionPrompt(k);
}

/// The bottom area: the expression line, then the status line.
fn bottomContent() !void {
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .min_size_content = .{ .h = expression_height - 2 } });
        defer line.deinit();
        try expressionLine();
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer bar.deinit();
    statusContent();
}

// The expression line -----------------------------------------------------
//
// Shows and edits the selected label's markup as typed. Whatever is typed
// is stored, valid or not; the canvas draws it from the engine's lenient
// parse (placeholders for what is still to come, unfinished commands
// faint), and the first problem shows at the line's end. Braces pair as in
// a code editor, so partial input stays renderable.

/// What the expression line edits.
const ExprTarget = union(enum) {
    panel_label: struct { panel: usize, index: usize },
    tile_slot: struct { tile: TileId, slot: usize },
    /// A run of markup (text, an equation) in a track's flow.
    run: struct { panel: usize, region: usize, item: usize },

    fn content(t: ExprTarget) []const u8 {
        return switch (t) {
            .panel_label => |l| state.model.panels.items[l.panel].labels.items[l.index].content,
            .tile_slot => |ts| state.model.slot(ts.tile, ts.slot).content,
            .run => |r| state.model.panels.items[r.panel].regions.items[r.region].items.items[r.item].what.run.content,
        };
    }

    fn store(t: ExprTarget, text: []const u8) !void {
        switch (t) {
            // Typing into one label is one undo step.
            .panel_label => |l| try actM(mergeKey(.{ "label", l.panel, l.index }), .setLabelContent, .{ l.panel, l.index, text }),
            .tile_slot => |ts| try actM(mergeKey(.{ "slot", ts.tile, ts.slot }), .setContent, .{ ts.tile, state.model.slot(ts.tile, ts.slot).name, text }),
            .run => |r| try actM(mergeKey(.{ "run", r.panel, r.region, r.item }), .setRunContent, .{ r.panel, r.region, r.item, text }),
        }
    }

    fn key(t: ExprTarget) u64 {
        var h: std.hash.Wyhash = .init(7);
        std.hash.autoHash(&h, t);
        return h.final();
    }
};

fn exprTarget() ?ExprTarget {
    return switch (state.context) {
        .label => |l| .{ .panel_label = .{ .panel = l.panel, .index = l.index } },
        .tile => |id| if (state.model.slotCount(id) > 0) .{ .tile_slot = .{ .tile = id, .slot = 0 } } else null,
        .region => if (runAtCursor()) |r| .{ .run = .{ .panel = r.panel, .region = r.region, .item = r.item } } else null,
        else => null,
    };
}

/// The line's text before this frame's edits, for the pairing rules.
var expr_prev: std.ArrayList(u8) = .empty;
var expr_prev_key: u64 = 0;

/// Command completion: the list shown while a command is being typed, the
/// highlighted entry, and a pending acceptance or dismissal.
var expr_entry_id: ?dvui.Id = null;
var comp: std.ArrayList(engine.markup.Completion) = .empty;
var comp_index: usize = 0;
var comp_accept: ?usize = null;
/// The cursor position at which Esc dismissed the list, until it moves.
var comp_dismissed_at: ?usize = null;
const comp_max = 8;

/// While the expression line has focus: what it edits and where its cursor
/// is, so the canvas draws the cursor in the rendered label too.
var expr_caret: ?struct { target: ExprTarget, offset: usize } = null;

/// The command name being typed just before the cursor: the backslash's
/// offset and the letters after it.
fn partialCommand(text: []const u8, cur: usize) ?struct { at: usize, prefix: []const u8 } {
    var i = @min(cur, text.len);
    while (i > 0 and std.ascii.isAlphabetic(text[i - 1])) i -= 1;
    if (i == 0 or text[i - 1] != '\\') return null;
    // An escaped backslash (\\) is a line break, not a command.
    if (i >= 2 and text[i - 2] == '\\') return null;
    return .{ .at = i - 1, .prefix = text[i..@min(cur, text.len)] };
}

/// Replaces the partial command before the cursor with a completion, and
/// leaves the cursor inside its first argument, or after it.
fn acceptCompletion(te: *dvui.TextEntryWidget, c: engine.markup.Completion) void {
    const cur = te.textLayout.selection.cursor;
    const part = partialCommand(te.textGet(), cur) orelse return;
    setCursor(te, part.at + 1);
    te.textLayout.selection.end = cur;
    var buf: [96]u8 = undefined;
    const insert = std.fmt.bufPrint(&buf, "{s}{s}", .{ c.name, c.args }) catch return;
    te.textTyped(insert, false);
    const after_name = part.at + 1 + c.name.len;
    setCursor(te, if (c.args.len > 0) after_name + 1 else after_name);
}

fn expressionLine() !void {
    const muted: dvui.Options = .{ .gravity_y = 0.5, .padding = .{ .x = 8, .w = 6 }, .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.65) } };
    dvui.labelNoFmt(@src(), "Expression", .{}, muted);
    const target = exprTarget() orelse {
        dvui.labelNoFmt(@src(), "Select a label or tile to edit its expression.", .{}, muted.override(.{ .expand = .horizontal, .font = dvui.Font.theme(.body).withStyle(.italic) }));
        return;
    };
    const key = target.key();
    const content = target.content();
    if (key != expr_prev_key) {
        expr_prev.clearRetainingCapacity();
        try expr_prev.appendSlice(state.gpa, content);
        expr_prev_key = key;
    }

    // While the completion list shows, its keys are taken before the entry
    // sees them: Up and Down move, Tab or Enter accepts, Esc dismisses.
    const was_focused = expr_entry_id != null and expr_entry_id.? == dvui.focusedWidgetId();
    if (was_focused and comp.items.len > 0) for (dvui.events()) |*e| {
        if (e.evt != .key or e.handled) continue;
        const k = e.evt.key;
        if (k.action != .down and k.action != .repeat) continue;
        switch (k.code) {
            .up => comp_index = if (comp_index == 0) comp.items.len - 1 else comp_index - 1,
            .down => comp_index = (comp_index + 1) % comp.items.len,
            .tab, .enter, .kp_enter => comp_accept = comp_index,
            .escape => comp_dismissed_at = std.math.maxInt(usize),
            else => continue,
        }
        e.handle(@src(), dvui.currentWindow().data());
    };

    // In a run of a track's flow, Enter or Esc ends the run: the keyboard
    // goes back to the canvas and its flow cursor, where Enter is a hard
    // break.
    if (was_focused and target == .run and comp.items.len == 0) for (dvui.events()) |*e| {
        if (e.evt != .key or e.handled) continue;
        const k = e.evt.key;
        if (k.action != .down) continue;
        if (k.code != .enter and k.code != .kp_enter and k.code != .escape) continue;
        e.handle(@src(), dvui.currentWindow().data());
        if (canvas_id) |id| dvui.focusWidget(id, null, null);
    };

    // Otherwise Tab moves to the next argument slot, taken before the
    // entry sees it, as the entry would move focus.
    var next_slot = false;
    if (was_focused) for (dvui.events()) |*e| {
        if (e.evt != .key or e.handled) continue;
        const k = e.evt.key;
        if (k.code == .tab and (k.action == .down or k.action == .repeat)) {
            e.handle(@src(), dvui.currentWindow().data());
            next_slot = true;
        }
    };
    var te = dvui.textEntry(@src(), .{ .text_initial = content }, .{
        .expand = .horizontal,
        .gravity_y = 0.5,
        .font = .theme(.mono),
        .id_extra = @truncate(key),
    });
    // A run just put in a track takes the keyboard at once.
    if (focus_expression) {
        focus_expression = false;
        // Its window first: the palette over the canvas may hold the
        // keyboard.
        dvui.focusSubwindow(null, null);
        dvui.focusWidget(te.data().id, null, null);
        if (focus_expression_end) setCursor(te, te.textGet().len);
        focus_expression_end = false;
    }
    const focused = te.data().id == dvui.focusedWidgetId();
    if (next_slot) nextSlot(te);
    // Kept in step with edits made elsewhere (the Text property).
    if (!focused and !std.mem.eql(u8, te.textGet(), content)) te.textSet(content, false);
    expr_entry_id = te.data().id;
    if (te.text_changed and !std.mem.eql(u8, te.textGet(), expr_prev.items)) pairBraces(te, expr_prev.items);
    if (comp_accept) |i| {
        if (i < comp.items.len) acceptCompletion(te, comp.items[i]);
        comp_accept = null;
    }
    // The list for the command being typed, unless dismissed here.
    const cursor = te.textLayout.selection.cursor;
    if (comp_dismissed_at) |d| {
        if (d == std.math.maxInt(usize)) comp_dismissed_at = cursor else if (d != cursor) comp_dismissed_at = null;
    }
    comp.clearRetainingCapacity();
    if (focused and comp_dismissed_at == null) if (partialCommand(te.textGet(), cursor)) |part| {
        try engine.markup.completions(state.gpa, &engine.entities.Table.builtin, part.prefix, &comp);
        if (comp.items.len > comp_max) comp.shrinkRetainingCapacity(comp_max);
        // Nothing to offer once the name is complete and alone.
        if (comp.items.len == 1 and std.mem.eql(u8, comp.items[0].name, part.prefix)) comp.clearRetainingCapacity();
    };
    if (comp_index >= comp.items.len) comp_index = 0;
    const entry_rect = te.data().borderRectScale().r;
    // The canvas caret follows; redraw when it moves.
    const caret: @TypeOf(expr_caret) = if (focused) .{ .target = target, .offset = te.textLayout.selection.cursor } else null;
    if (!std.meta.eql(caret, expr_caret)) dvui.refresh(null, @src(), null);
    expr_caret = caret;
    const text = te.textGet();
    const changed = !std.mem.eql(u8, text, content);
    if (changed) try target.store(text);
    expr_prev.clearRetainingCapacity();
    try expr_prev.appendSlice(state.gpa, text);
    te.deinit();

    if (comp.items.len > 0) completionList(entry_rect);

    // The first problem, if any, at the line's end.
    if (firstSyntaxProblem(target)) |d| {
        var buf: [96]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "{s} (at {d})", .{ d.kind.message(), d.offset }) catch "";
        dvui.labelNoFmt(@src(), msg, .{}, .{ .gravity_y = 0.5, .padding = .{ .x = 8, .w = 8 }, .color_text = .{ .color = colors.overflow } });
    }
}

/// The completion list, floating just above the expression line.
fn completionList(entry: dvui.Rect.Physical) void {
    const ns = dvui.windowNaturalScale();
    const font = dvui.Font.theme(.mono);
    const row_pad: f32 = 3;
    const row_h: f32 = font.textHeight() + 2 * row_pad;
    const h = row_h * @as(f32, @floatFromInt(comp.items.len)) + 10;
    var fw: dvui.FloatingWidget = undefined;
    fw.init(@src(), .{}, .{
        .rect = .{ .x = entry.x / ns + 8, .y = entry.y / ns - h - 4, .w = 360, .h = h },
        .background = true,
        .color_fill = .{ .color = dvui.themeGet().color(.window, .fill) },
        .border = .all(1),
        .corners = .all(6),
        .padding = .all(4),
    });
    defer fw.deinit();
    for (comp.items, 0..) |c, i| {
        var buf: [96]u8 = undefined;
        var cp_buf: [4]u8 = undefined;
        // The character with its code point: the interface font may lack it.
        var code_buf: [16]u8 = undefined;
        const glyph = if (c.cp) |cp| cp_buf[0 .. std.unicode.utf8Encode(cp, &cp_buf) catch 0] else "";
        const code = if (c.cp) |cp| std.fmt.bufPrint(&code_buf, "  U+{X:0>4}", .{cp}) catch "" else "";
        const line = std.fmt.bufPrint(&buf, "\\{s}{s}    {s}{s}{s}", .{ c.name, c.args, glyph, code, c.note }) catch c.name;
        const selected = i == comp_index;
        if (dvui.labelClick(@src(), "{s}", .{line}, .{}, .{
            .id_extra = i,
            .expand = .horizontal,
            .font = font,
            .padding = .{ .x = 6, .w = 6, .y = row_pad, .h = row_pad },
            .background = selected,
            .color_fill = if (selected) .{ .color = dvui.themeGet().focus.opacity(0.3) } else null,
        })) {
            comp_index = i;
            comp_accept = i;
        }
    }
}

fn firstSyntaxProblem(target: ExprTarget) ?engine.markup.Diagnostic {
    for (state.placed.items, 0..) |*p, pi| for (p.issues) |i| {
        if (i.kind != .markup_error) continue;
        const hit = switch (target) {
            .panel_label => |l| l.panel == pi and i.label == l.index,
            .tile_slot => |ts| i.tile == ts.tile and i.slot == ts.slot,
            .run => |r| r.panel == pi and i.region == r.region and i.item == r.item,
        };
        if (hit) return i.syntax;
    };
    return null;
}

/// The pairing rules, applied after the entry has taken a keystroke:
/// typing '{' adds its '}' (after \frac, "{}{}"), with the cursor inside;
/// typing '}' where the text has one too many steps over the next '}';
/// deleting the '{' of an empty "{}" deletes both.
fn pairBraces(te: *dvui.TextEntryWidget, prev: []const u8) void {
    const text = te.textGet();
    const sel = te.textLayout.selection;
    const cur = sel.cursor;
    if (text.len == prev.len + 1 and cur > 0 and cur <= text.len) {
        const typed = text[cur - 1];
        if (typed == '{') {
            const two = std.mem.endsWith(u8, text[0 .. cur - 1], "\\frac") or std.mem.endsWith(u8, text[0 .. cur - 1], "\\dfrac") or std.mem.endsWith(u8, text[0 .. cur - 1], "\\tfrac");
            te.textTyped(if (two) "}{}" else "}", false);
            setCursor(te, cur);
        } else if (typed == '}' and cur < text.len and text[cur] == '}' and count(text, '}') > count(text, '{')) {
            // Remove the '}' just typed: the cursor steps over the next one.
            setCursor(te, cur - 1);
            te.textLayout.selection.end = cur;
            te.textTyped("", false);
            setCursor(te, cur);
        }
    } else if (text.len + 1 == prev.len and cur < prev.len and prev[cur] == '{' and cur + 1 < prev.len and prev[cur + 1] == '}' and
        std.mem.eql(u8, text[0..cur], prev[0..cur]) and std.mem.eql(u8, text[cur..], prev[cur + 1 ..]))
    {
        // The '{' of an empty pair was deleted: take its '}' too.
        setCursor(te, cur);
        te.textLayout.selection.end = cur + 1;
        te.textTyped("", false);
        setCursor(te, cur);
    }
}

fn count(text: []const u8, c: u8) usize {
    return std.mem.count(u8, text, &.{c});
}

fn setCursor(te: *dvui.TextEntryWidget, at: usize) void {
    te.textLayout.selection.cursor = at;
    te.textLayout.selection.start = at;
    te.textLayout.selection.end = at;
}

/// Tab: the cursor goes just inside the next '{' after it, or to the end.
fn nextSlot(te: *dvui.TextEntryWidget) void {
    const text = te.textGet();
    const cur = te.textLayout.selection.cursor;
    const next = if (cur < text.len) std.mem.indexOfScalarPos(u8, text, cur, '{') else null;
    setCursor(te, if (next) |n| n + 1 else text.len);
}

// The title bar -----------------------------------------------------------
//
// Like a GTK header bar: the window has no native frame, and Graven draws
// one bar holding its menus, the title, and at the right end the window
// controls in a plain native style. SDL's hit test tells the window manager
// which parts of the bar drag the window and which window edges resize it.

/// The title bar's rectangle and the controls on it, in physical pixels,
/// from the last frame: the hit test reads them.
var frame_bar: dvui.Rect.Physical = .{};
var frame_holes: [16]dvui.Rect.Physical = undefined;
var frame_hole_count: usize = 0;
/// Physical pixels per window coordinate (SDL's hit test gives points).
var frame_density: f32 = 1;

const title_height = 34;
/// Width of the window edges that resize it, window coordinates.
const resize_edge = 6;

fn initWindowFrame(win: *dvui.Window) void {
    if (dvui.backend.kind != .sdl3) return;
    const c = dvui.backend.c;
    const window = win.backend.impl.window;
    _ = c.SDL_SetWindowTitle(window, "untitled — Graven");
    if (std.c.getenv("GRAVEN_NATIVE_FRAME") != null) return;
    _ = c.SDL_SetWindowBordered(window, false);
    _ = c.SDL_SetWindowHitTest(window, hitTest, null);
}

/// Where a point in the window drags or resizes it: resize along the
/// edges (unless maximised), drag on the title bar away from its controls.
fn hitTest(win: ?*dvui.backend.c.SDL_Window, area: [*c]const dvui.backend.c.SDL_Point, _: ?*anyopaque) callconv(.c) dvui.backend.c.SDL_HitTestResult {
    const c = dvui.backend.c;
    const p = area.*;
    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSize(win, &w, &h);
    const maximized = (c.SDL_GetWindowFlags(win) & c.SDL_WINDOW_MAXIMIZED) != 0;
    if (!maximized) {
        const l = p.x < resize_edge;
        const r = p.x >= w - resize_edge;
        const t = p.y < resize_edge;
        const b = p.y >= h - resize_edge;
        if (t and l) return c.SDL_HITTEST_RESIZE_TOPLEFT;
        if (t and r) return c.SDL_HITTEST_RESIZE_TOPRIGHT;
        if (b and l) return c.SDL_HITTEST_RESIZE_BOTTOMLEFT;
        if (b and r) return c.SDL_HITTEST_RESIZE_BOTTOMRIGHT;
        if (t) return c.SDL_HITTEST_RESIZE_TOP;
        if (b) return c.SDL_HITTEST_RESIZE_BOTTOM;
        if (l) return c.SDL_HITTEST_RESIZE_LEFT;
        if (r) return c.SDL_HITTEST_RESIZE_RIGHT;
    }
    const pp: dvui.Point.Physical = .{ .x = @as(f32, @floatFromInt(p.x)) * frame_density, .y = @as(f32, @floatFromInt(p.y)) * frame_density };
    if (!frame_bar.contains(pp)) return c.SDL_HITTEST_NORMAL;
    for (frame_holes[0..frame_hole_count]) |hole| if (hole.contains(pp)) return c.SDL_HITTEST_NORMAL;
    return c.SDL_HITTEST_DRAGGABLE;
}

/// Marks a control on the title bar, so pressing it is not a window drag.
fn frameHole(r: dvui.Rect.Physical) void {
    if (frame_hole_count < frame_holes.len) {
        frame_holes[frame_hole_count] = r;
        frame_hole_count += 1;
    }
}

const WindowButton = enum { minimize, maximize, close };

/// A window control: a round button showing only on hover, with a thin
/// glyph, as GTK and COSMIC draw them.
fn windowButton(kind: WindowButton) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = @backingInt(kind),
        .min_size_content = .{ .w = 18, .h = 18 },
        .padding = .all(5),
        .margin = .{ .x = 3, .w = 3 },
        .corners = .round(14),
        .gravity_y = 0.5,
        .background = false,
        .border = .all(0),
    });
    bw.processEvents();
    if (bw.hovered() or bw.pressed()) bw.data().borderRectScale().r.fill(.round(14 * dvui.windowNaturalScale()), .{ .color = .{ .color = dvui.themeGet().color(.control, .text).opacity(if (bw.pressed()) 0.2 else 0.1) } });
    const clicked = bw.clicked();
    const r = bw.data().contentRectScale().r;
    frameHole(bw.data().borderRectScale().r);
    const ns = dvui.windowNaturalScale();
    const ink: dvui.ColorOrGradient = .{ .color = dvui.themeGet().color(.control, .text) };
    const cx = r.x + r.w / 2;
    const cy = r.y + r.h / 2;
    const k = 4.5 * ns;
    switch (kind) {
        .minimize => dvui.Path.stroke(.{ .points = &.{ .{ .x = cx - k, .y = cy + k * 0.6 }, .{ .x = cx + k, .y = cy + k * 0.6 } } }, .{ .thickness = 1.3 * ns, .color = ink }),
        .maximize => (dvui.Rect.Physical{ .x = cx - k, .y = cy - k, .w = 2 * k, .h = 2 * k }).stroke(.square, .{ .thickness = 1.3 * ns, .color = ink }),
        .close => {
            dvui.Path.stroke(.{ .points = &.{ .{ .x = cx - k, .y = cy - k }, .{ .x = cx + k, .y = cy + k } } }, .{ .thickness = 1.3 * ns, .color = ink });
            dvui.Path.stroke(.{ .points = &.{ .{ .x = cx - k, .y = cy + k }, .{ .x = cx + k, .y = cy - k } } }, .{ .thickness = 1.3 * ns, .color = ink });
        },
    }
    bw.deinit();
    return clicked;
}

/// The title bar: menus at the left, the file and worksheet in the middle,
/// window controls at the right. Everything that is not a control drags
/// the window.
fn titleBar() ?dvui.App.Result {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = true, .color_fill = .{ .color = colors.titlebar }, .min_size_content = .{ .h = title_height }, .border = .{ .h = 1 } });
    defer bar.deinit();
    frame_bar = bar.data().borderRectScale().r;
    frame_hole_count = 0;
    const win = dvui.currentWindow();
    const px = win.backend.pixelSize();
    const ws = win.backend.windowSize();
    frame_density = if (ws.w > 0) px.w / ws.w else 1;

    const native_frame = dvui.backend.kind != .sdl3 or std.c.getenv("GRAVEN_NATIVE_FRAME") != null;
    // Window buttons on the left, when the desktop puts them there.
    if (!native_frame) if (windowButtons(desk.layout.leftSide())) |r| return r;

    if (menu()) |r| return r;

    // The title fills the middle and is part of the draggable bar.
    {
        // Each name italic while it is the app's choice.
        // Fills the bar's height too, so the title centres against the
        // menus and window buttons rather than sitting at the top.
        var middle = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer middle.deinit();
        var title = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5, .gravity_y = 0.5 });
        defer title.deinit();
        // A bullet while there are unsaved changes.
        if (!canvas_prompt and hist.isDirty()) dvui.labelNoFmt(@src(), "• ", .{}, .{ .padding = .{ .x = 0, .w = 0, .y = 4, .h = 4 } });
        dvui.labelNoFmt(@src(), state.file_name, .{}, .{ .font = styled(.theme(.body), !state.file_name_set), .padding = .{ .x = 0, .w = 0, .y = 4, .h = 4 } });
        dvui.labelNoFmt(@src(), "  —  ", .{}, .{ .padding = .{ .x = 0, .w = 0, .y = 4, .h = 4 } });
        if (openCanvas()) {
            var tb: [64]u8 = undefined;
            const t = if (canvas_prompt) "New canvas" else if (shown_space > 0 and shown_space < state.model.spaces.items.len) std.fmt.bufPrint(&tb, "{s}, {s}", .{ state.model.spaces.items[shown_space].name, state.model.units.symbol() }) catch "Frame" else std.fmt.bufPrint(&tb, "Canvas, {s}", .{state.model.units.symbol()}) catch "Canvas";
            dvui.labelNoFmt(@src(), t, .{}, .{ .padding = .{ .x = 0, .w = 0, .y = 4, .h = 4 } });
        } else dvui.labelNoFmt(@src(), state.model.sheet.name, .{}, .{ .font = styled(.theme(.body), state.model.sheet.default_name), .padding = .{ .x = 0, .w = 0, .y = 4, .h = 4 } });
    }

    if (!native_frame) if (windowButtons(desk.layout.rightSide())) |r| return r;
    return null;
}

/// The window buttons in the desktop's order.
fn windowButtons(buttons: []const desktop.Button) ?dvui.App.Result {
    if (dvui.backend.kind != .sdl3) return null;
    const c = dvui.backend.c;
    const window = dvui.currentWindow().backend.impl.window;
    for (buttons) |b| {
        const kind: WindowButton = switch (b) {
            .minimize => .minimize,
            .maximize => .maximize,
            .close => .close,
        };
        if (!windowButton(kind)) continue;
        switch (kind) {
            .minimize => _ = c.SDL_MinimizeWindow(window),
            .maximize => {
                const maximized = (c.SDL_GetWindowFlags(window) & c.SDL_WINDOW_MAXIMIZED) != 0;
                _ = if (maximized) c.SDL_RestoreWindow(window) else c.SDL_MaximizeWindow(window);
            },
            .close => leave(.quit),
        }
    }
    return null;
}

fn menu() ?dvui.App.Result {
    var m = dvui.menu(@src(), .horizontal, .{ .gravity_y = 0.5 });
    frameHole(m.data().borderRectScale().r);
    defer m.deinit();
    if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        const mod = if (builtin.os.tag == .macos) "Cmd" else "Ctrl";
        var kb: [4][48]u8 = undefined;
        if (dvui.menuItemLabel(@src(), std.fmt.bufPrint(&kb[0], "New canvas…      {s}+N", .{mod}) catch "New canvas…", .{}, .{ .expand = .horizontal }) != null) {
            leave(.new_canvas);
            m.close();
        }
        if (dvui.menuItemLabel(@src(), std.fmt.bufPrint(&kb[1], "Open…      {s}+O", .{mod}) catch "Open…", .{}, .{ .expand = .horizontal }) != null) {
            leave(.open);
            m.close();
        }
        if (!canvas_prompt) {
            if (dvui.menuItemLabel(@src(), std.fmt.bufPrint(&kb[2], "Save      {s}+S", .{mod}) catch "Save", .{}, .{ .expand = .horizontal }) != null) {
                save();
                m.close();
            }
            if (dvui.menuItemLabel(@src(), std.fmt.bufPrint(&kb[3], "Save As…      {s}+Shift+S", .{mod}) catch "Save As…", .{}, .{ .expand = .horizontal }) != null) {
                saveAs();
                m.close();
            }
        }
        if (dvui.menuItemLabel(@src(), "Place image…", .{}, .{ .expand = .horizontal }) != null) {
            m.close();
            if (!canvas_prompt and openCanvas()) {
                image_prompt = true;
                image_prompt_new = true;
            }
        }
        if (dvui.menuItemLabel(@src(), "Export SVG…", .{}, .{ .expand = .horizontal }) != null) {
            m.close();
            exportSvg();
        }
        const others = state.model.panels.items.len - state.model.spaces.items.len;
        if (others == 0 and !canvas_prompt) {
            if (dvui.menuItemLabel(@src(), "Add sample: PC keyboard", .{}, .{ .expand = .horizontal }) != null) {
                loadSample() catch |err| {
                    state.status = if (err == error.OffSheet) "The sample keyboard does not fit on this sheet. " else "The sample did not load. ";
                };
                m.close();
            }
        }
        if (dvui.menuItemLabel(@src(), "Quit", .{}, .{ .expand = .horizontal }) != null) {
            leave(.quit);
            m.close();
        }
    }
    if (dvui.menuItemLabel(@src(), "Edit", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        const mod = if (builtin.os.tag == .macos) "Cmd" else "Ctrl";
        var ub: [48]u8 = undefined;
        var rb: [48]u8 = undefined;
        if (dvui.menuItemLabel(@src(), std.fmt.bufPrint(&ub, "Undo      {s}+Z", .{mod}) catch "Undo", .{}, .{ .expand = .horizontal, .color_text = if (hist.canUndo()) null else .{ .color = dvui.themeGet().color(.window, .text).opacity(0.4) } }) != null) {
            undo();
            m.close();
        }
        if (dvui.menuItemLabel(@src(), std.fmt.bufPrint(&rb, "Redo      {s}+Shift+Z", .{mod}) catch "Redo", .{}, .{ .expand = .horizontal, .color_text = if (hist.canRedo()) null else .{ .color = dvui.themeGet().color(.window, .text).opacity(0.4) } }) != null) {
            redo();
            m.close();
        }
    }
    if (dvui.menuItemLabel(@src(), "View", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        if (dvui.menuItemLabel(@src(), "    Zoom to context", .{}, .{ .expand = .horizontal }) != null) {
            zoomToContext();
            m.close();
        }
        // DVUI's interface font has no check mark; a bullet marks what is on.
        if (dvui.menuItemLabel(@src(), if (show_construction) "•  Show text construction" else "    Show text construction", .{}, .{ .expand = .horizontal }) != null) {
            show_construction = !show_construction;
            m.close();
        }
        // Pane modes, as the tabs' icons set them, and hot edges.
        for (all_panes, 0..) |pane, pi| {
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = pi });
            for ([_]ghost_pane.Mode{ .ghost, .docked, .hidden }, 0..) |mode, mi| {
                var buf: [64]u8 = undefined;
                const on = pane.mode == mode;
                const text = std.fmt.bufPrint(&buf, "{s}{s}: {s}", .{ if (on) "•  " else "    ", pane.name, @tagName(mode) }) catch pane.name;
                if (dvui.menuItemLabel(@src(), text, .{}, .{ .expand = .horizontal, .id_extra = pi * 3 + mi }) != null) {
                    applyTab(pane, .{ .mode = mode });
                    m.close();
                }
            }
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 9 });
        // An experiment: how a ghost pane's content is drawn.
        for ([_]ghost_pane.Style{ .uniform, .matched, .tinted, .outlined, .haloed }, [_][]const u8{ "one alpha", "matched contrast", "tinted", "outlined", "tinted, outlined and inlined" }, 0..) |st, name, si| {
            var buf: [64]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{s}Ghost style: {s}", .{ if (ghost_pane.style == st) "•  " else "    ", name }) catch name;
            if (dvui.menuItemLabel(@src(), text, .{}, .{ .expand = .horizontal, .id_extra = 20 + si }) != null) {
                ghost_pane.style = st;
                m.close();
            }
        }
        if (dvui.menuItemLabel(@src(), if (ghost_pane.deep_active) "•  Active and docked panes: deep background" else "    Active and docked panes: deep background", .{}, .{ .expand = .horizontal }) != null) {
            ghost_pane.deep_active = !ghost_pane.deep_active;
            m.close();
        }
        if (dvui.menuItemLabel(@src(), if (ghost_pane.vivid) "•  Pane colour: vivid" else "    Pane colour: vivid", .{}, .{ .expand = .horizontal }) != null) {
            ghost_pane.vivid = !ghost_pane.vivid;
            m.close();
        }
        if (dvui.menuItemLabel(@src(), if (ghost_pane.halo.light_inside) "•  Halo: light line inside, dark keyline outside (try)" else "    Halo: light line inside, dark keyline outside (try)", .{}, .{ .expand = .horizontal }) != null) {
            ghost_pane.halo.light_inside = !ghost_pane.halo.light_inside;
            m.close();
        }
        _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = 10 });
        if (dvui.menuItemLabel(@src(), if (hot_edges) "•  Hot edges: hold on a tab to open its pane" else "    Hot edges: hold on a tab to open its pane", .{}, .{ .expand = .horizontal }) != null) {
            hot_edges = !hot_edges;
            m.close();
        }
    }
    return null;
}

/// The component tree: file, panels, regions, rows, tiles. Clicking a node
/// makes it the context; its arrow opens or closes it.
fn treePane() void {
    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = tree_width }, .max_size_content = .width(tree_width), .expand = .vertical, .border = .{ .w = 1 }, .background = true, .color_fill = .{ .color = ghost_pane.fill(&tree_pane) } });
    defer pane.deinit();
    treeContent();
}

/// The tree itself, in whatever holds it; scrolls by wheel, with no bars.
fn treeContent() void {
    var scroll = dvui.scrollArea(@src(), .{ .vertical_bar = .hide, .horizontal_bar = .hide }, .{ .expand = .both, .background = false });
    defer scroll.deinit();
    // Nothing to show until the canvas is made.
    if (canvas_prompt) return;

    // The file holds everything: its worksheet, and the tile prototypes its
    // tiles are made from.
    if (!treeNode(.file, state.file_name, 0, true, !state.file_name_set)) return;
    worksheetTree();
    if (treeNode(.prototypes, "Tile prototypes", 1, state.model.prototypes.items.len > 0, false)) {
        for (state.model.prototypes.items, 0..) |p, i| _ = treeNode(.{ .prototype = @intCast(i) }, p.name, 2, false, false);
    }
}

/// The worksheet's branch: its panels, their labels, regions, rows and
/// tiles.
fn worksheetTree() void {
    // A canvas: each space (the canvas, then its frames) with its groups,
    // its loose objects and its panels.
    if (state.model.spaces.items.len > 0) {
        var tb: [64]u8 = undefined;
        for (state.model.spaces.items, 0..) |sp, si| {
            const title = if (si == 0) std.fmt.bufPrint(&tb, "Canvas, {s}", .{state.model.units.symbol()}) catch "Canvas" else sp.name;
            if (!treeNode(.{ .panel = sp.root }, title, 1, true, sp.default_name)) continue;
            for (sp.groups.items) |g| {
                if (state.model.parentGroup(g.id) == null) groupTree(g.id, 2);
            }
            for (sp.views.items, 0..) |sv, vi| _ = treeNode(.{ .view = .{ .space = si, .index = vi } }, sv.name, 2, false, false);
            for (sp.images.items, 0..) |im, ii| {
                var ib: [96]u8 = undefined;
                _ = treeNode(.{ .image = .{ .space = si, .index = ii } }, std.fmt.bufPrint(&ib, "Image {s}", .{im.name}) catch im.name, 2, false, false);
            }
            panelChildren(sp.root, 2);
            for (state.model.panels.items, 0..) |panel, pi| {
                if (pi == sp.root or panel.space != si) continue;
                if (!treeNode(.{ .panel = pi }, panel.name, 2, hasChildren(panel), panel.default_name)) continue;
                panelChildren(pi, 3);
            }
        }
        return;
    }
    const sheet = state.model.sheet;
    if (!treeNode(.worksheet, sheet.name, 1, state.model.panels.items.len > 0, sheet.default_name)) return;
    for (state.model.panels.items, 0..) |panel, pi| {
        if (!treeNode(.{ .panel = pi }, panel.name, 2, hasChildren(panel), panel.default_name)) continue;
        panelChildren(pi, 3);
    }
}

/// A group in the tree: its name and size, and the groups nested in it.
fn groupTree(id: layout.model.ObjectId, d: usize) void {
    const g = state.model.group(id) orelse return;
    var tb: [96]u8 = undefined;
    var nested = false;
    for (g.members.items) |mb| {
        if (state.model.group(mb) != null) nested = true;
    }
    const text = std.fmt.bufPrint(&tb, "Group “{s}” ({d})", .{ g.name, g.members.items.len }) catch g.name;
    if (!treeNode(.{ .group = id }, text, d, nested, false)) return;
    for (g.members.items) |mb| {
        if (state.model.group(mb) != null) groupTree(mb, d + 1);
    }
}

fn hasChildren(panel: layout.model.Panel) bool {
    return panel.regions.items.len > 0 or panel.labels.items.len > 0 or panel.art.items.len > 0;
}

/// A panel's art, labels and tracks (with their rows and tiles) in the
/// tree, from depth `d`.
fn panelChildren(pi: usize, d: usize) void {
    var name_buf: [64]u8 = undefined;
    const panel = state.model.panels.items[pi];
    {
        for (panel.art.items, 0..) |pa, ai| _ = treeNode(.{ .art = .{ .panel = pi, .index = ai } }, pa.name, d, false, false);
        for (panel.labels.items, 0..) |label, li| {
            const text = std.fmt.bufPrint(&name_buf, "“{s}”", .{label.content}) catch label.content;
            _ = treeNode(.{ .label = .{ .panel = pi, .index = li } }, text, d, false, label.default_content);
        }
        for (panel.regions.items, 0..) |region, ri| {
            const seg_count = segmentCount(pi, ri);
            if (!treeNode(.{ .region = .{ .panel = pi, .region = ri } }, region.name, d, seg_count > 0, false)) continue;
            for (0..seg_count) |rowi| {
                const title = std.fmt.bufPrint(&name_buf, "{s} {d}", .{ trackWord(region.major), rowi + 1 }) catch "Row";
                // What the flow put in this segment, from the last solve.
                const placed_items: []const layout.place.PlacedItem = if (pi < state.placed.items.len) state.placed.items[pi].items else &.{};
                const filled = for (placed_items) |it| {
                    if (it.region == ri and it.segment == rowi and !isBreak(pi, it)) break true;
                } else false;
                if (!treeNode(.{ .row = .{ .panel = pi, .region = ri, .row = rowi } }, title, d + 1, filled, false)) continue;
                for (placed_items) |it| {
                    if (it.region != ri or it.segment != rowi) continue;
                    // Blanks, runs and breaks are not things to select here.
                    const id = (modelItem(pi, it) orelse continue).tileOf() orelse continue;
                    if (state.model.prototypes.items[state.model.tileConst(id).prototype].spacer) continue;
                    const t = state.model.tileConst(id);
                    const legend = if (state.model.slotCount(id) > 0) state.model.slot(id, 0).content else "";
                    const text = std.fmt.bufPrint(&name_buf, "{s}  {s}", .{ t.designator, legend }) catch t.designator;
                    _ = treeNode(.{ .tile = id }, text, d + 2, false, false);
                }
            }
        }
    }
}

/// One tree row: an open/close arrow when it has children, and its name,
/// highlighted when it is the context and in italic when the app chose it.
/// Returns whether it is open.
fn treeNode(ctx: Context, text: []const u8, depth: usize, has_children: bool, default: bool) bool {
    const key = ctx.key();
    const id: usize = @truncate(key);
    const open = state.expanded.get(key) orelse switch (ctx) {
        .file, .worksheet, .panel, .region, .prototypes => true,
        else => false,
    };
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = id, .margin = .{ .x = @floatFromInt(depth * 14) } });
    defer row.deinit();
    if (has_children) {
        if (dvui.buttonIcon(@src(), if (open) "Close" else "Open", if (open) dvui.entypo.chevron_small_down else dvui.entypo.chevron_small_right, .{}, .{}, .{
            .min_size_content = .{ .w = 12, .h = 12 },
            .padding = .all(1),
            .margin = .all(1),
            .gravity_y = 0.5,
            .background = false,
            .border = .all(0),
        })) {
            state.expanded.put(state.gpa, key, !open) catch {};
        }
    } else {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .w = 16 } });
    }
    const selected = state.context.eql(ctx);
    const flagged = switch (ctx) {
        .panel => |pi| panelIssue(pi) != null,
        else => false,
    };
    if (dvui.labelClick(@src(), "{s}", .{text}, .{}, .{
        .color_text = if (flagged) .{ .color = colors.overflow } else null,
        .expand = .horizontal,
        .background = selected,
        .color_fill = if (selected) .{ .color = dvui.themeGet().focus.opacity(0.25) } else null,
        .font = styled(if (depth == 0) .theme(.heading) else .theme(.body), default),
    })) {
        state.context = ctx;
        // The keyboard goes to the canvas, where keys act on the context
        // (Delete, arrows moving a track).
        if (canvas_id) |cid| dvui.focusWidget(cid, null, null);
    }
    return open;
}

/// Opens the tree down to `ctx`, so a context chosen on the canvas shows.
fn revealInTree(ctx: Context) void {
    const id = switch (ctx) {
        .tile => |t| t,
        .label => |l| {
            for ([_]Context{ .file, .worksheet, .{ .panel = l.panel } }) |c| state.expanded.put(state.gpa, c.key(), true) catch {};
            return;
        },
        else => return,
    };
    const f = findTile(id) orelse return;
    for ([_]Context{
        .worksheet,
        .{ .panel = f.panel },
        .{ .region = .{ .panel = f.panel, .region = f.tile.region } },
        .{ .row = .{ .panel = f.panel, .region = f.tile.region, .row = f.tile.row } },
    }) |c| state.expanded.put(state.gpa, c.key(), true) catch {};
    state.expanded.put(state.gpa, Context.key(.file), true) catch {};
}

/// Whether a placed tile on panel `pi` belongs to the context, for canvas
/// highlighting.
fn inContext(pi: usize, t: layout.place.PlacedTile) bool {
    return switch (state.context) {
        .tile => |id| t.id == id,
        .row => |r| r.panel == pi and t.region == r.region and t.row == r.row,
        .region => |r| r.panel == pi and t.region == r.region,
        // Every tile made from the prototype.
        .prototype => |p| state.model.tileConst(t.id).prototype == p,
        .file, .worksheet, .panel, .label, .art, .group, .selection, .view, .layer, .image, .prototypes => false,
    };
}

/// The context's extents on the worksheet, mm.
fn contextExtents() geom.Box {
    switch (state.context) {
        .file, .worksheet, .prototypes => return if (openCanvas()) contentExtents() else state.model.sheet.box(),
        .panel => |pi| return if (state.model.panels.items[pi].unbounded) contentExtents() else state.model.panels.items[pi].box(),
        .label => |l| if (labelBox(l.panel, l.index)) |b| return b,
        .art => |l| return onSheet(l.panel, state.model.panels.items[l.panel].art.items[l.index].box()),
        .view => |v| if (viewAt(v.space, v.index)) |sv| {
            const b = viewBox(sv);
            if (!b.isEmpty()) return withNameRoom(b);
        },
        .image => |im| if (imageAt(im.space, im.index)) |image| return image.box(),
        else => {},
    }
    var b: geom.Box = .empty;
    for (state.placed.items, 0..) |*p, pi| for (p.tiles) |t| {
        if (inContext(pi, t)) b = b.join(onSheet(pi, t.pitch_box));
    };
    return if (b.isEmpty()) state.model.sheet.box() else b;
}

/// What the canvas holds, on the worksheet frame: every panel's solved
/// content, or the canvas's first view when it holds nothing.
fn contentExtents() geom.Box {
    var b = spaceExtents();
    if (state.model.spaces.items.len > shown_space) if (state.model.spaces.items[shown_space].bound) |fb| {
        b = b.join(fb);
    };
    return if (b.isEmpty()) canvas_view else b;
}

/// Centres the context in the canvas and zooms it to fill the canvas.
fn zoomToContext() void {
    state.view.fit = contextExtents();
}

/// Graven's own colours. The artwork (sheet, tiles, legends) keeps light
/// paper colours in either scheme, as drawing apps do; the chrome around it
/// (desk, rulers, title bar) follows the desktop's dark or light setting.
const Palette = struct {
    desk: dvui.Color,
    paper: dvui.Color = .{ .r = 0xfb, .g = 0xfa, .b = 0xf7 },
    panel_edge: dvui.Color = .{ .r = 0x5c, .g = 0x5a, .b = 0x55 },
    margin: dvui.Color = .{ .r = 0x9c, .g = 0x8a, .b = 0x6e },
    ruler: dvui.Color,
    titlebar: dvui.Color,
    ruler_ink: dvui.Color,
    body: dvui.Color = .{ .r = 0xe4, .g = 0xe2, .b = 0xdc },
    edge: dvui.Color = .{ .r = 0x9a, .g = 0x97, .b = 0x8f },
    face: dvui.Color = .{ .r = 0xf6, .g = 0xf5, .b = 0xf1 },
    ink: dvui.Color = .{ .r = 0x1d, .g = 0x1d, .b = 0x1b },
    /// Compliance flags take one hot hue, between red-hot and flame orange
    /// (OKLCH hue 38): no annotation or pane uses it. This is its light
    /// tint, behind a tile missing a glyph.
    missing: dvui.Color = .{ .r = 0xff, .g = 0xdd, .b = 0xd0 },
    /// Annotations that are not content: guides (margins, boundaries, view
    /// outlines, axes, track bands, break marks) and names, in one green
    /// hue (OKLCH 145), told apart by lightness, weight and line style.
    guide: dvui.Color = .{ .r = 0x2f, .g = 0x8a, .b = 0x4e },
    /// The active selection, the flow cursor and shapes being drawn: their
    /// own blue (OKLCH 255), and they move (marching dashes, a pulse).
    select: dvui.Color = .{ .r = 0x1f, .g = 0x6f, .b = 0xe0 },
    /// What fails a check: overflow, past an edge, ink in a margin.
    overflow: dvui.Color = .{ .r = 0xf3, .g = 0x46, .b = 0x00 },
};

const light_palette: Palette = .{
    .desk = .{ .r = 0xd9, .g = 0xd7, .b = 0xd2 },
    .ruler = .{ .r = 0xe9, .g = 0xe7, .b = 0xe2 },
    .titlebar = .{ .r = 0xeb, .g = 0xea, .b = 0xe7 },
    .ruler_ink = .{ .r = 0x4a, .g = 0x48, .b = 0x44 },
};

const dark_palette: Palette = .{
    .desk = .{ .r = 0x2b, .g = 0x2b, .b = 0x2d },
    .ruler = .{ .r = 0x38, .g = 0x38, .b = 0x3b },
    .titlebar = .{ .r = 0x30, .g = 0x30, .b = 0x33 },
    .ruler_ink = .{ .r = 0xc8, .g = 0xc6, .b = 0xc2 },
    .edge = .{ .r = 0x6a, .g = 0x68, .b = 0x64 },
};

var colors: Palette = light_palette;

/// The desktop settings in effect, for the title bar's button layout.
var desk: desktop.Settings = .{};

/// Matches the desktop: DVUI's Adwaita theme in the desktop's scheme with
/// its accent as the focus colour, and Graven's palette to suit.
fn applyDesktop(win: *dvui.Window, s: desktop.Settings) void {
    desk = s;
    const dark = s.scheme == .dark;
    var theme = if (dark) dvui.Theme.builtin.adwaita_dark else dvui.Theme.builtin.adwaita_light;
    if (s.accent) |a| theme.focus = .{ .r = @intFromFloat(a[0] * 255), .g = @intFromFloat(a[1] * 255), .b = @intFromFloat(a[2] * 255) };
    win.themeSet(theme);
    colors = if (dark) dark_palette else light_palette;
}

var main_window: ?*dvui.Window = null;

fn wakeGui() void {
    if (main_window) |w| dvui.refresh(w, @src(), null);
}

/// The canvas: the worksheet at true proportions, with every panel on it.
/// Wheel zooms about the pointer and dragging pans. With the select tool a
/// click makes a tile, panel or the worksheet the context; with the add
/// panel tool a drag draws out a new panel. The context is outlined.
fn canvas() void {
    var box = dvui.box(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = .{ .color = colors.desk } });
    defer box.deinit();
    const area = box.data().contentRectScale().r;
    const rw: f32 = ruler_size * dvui.windowNaturalScale();
    if (area.w <= 3 * rw or area.h <= 3 * rw) return;
    const sheet = state.model.sheet;
    const open = openCanvas();

    // The first frame fits the worksheet, leaving room for its rulers; a
    // canvas shows the space around its origin.
    if (state.view.ppm == 0 and state.view.fit == null) state.view.fit = if (open) canvas_view else sheet.box();
    const ns = dvui.windowNaturalScale();
    canvas_rect = .{ .x = area.x / ns, .y = area.y / ns, .w = area.w / ns, .h = area.h / ns };
    if (state.view.fit) |b| {
        // Fit into the part of the canvas overlays leave clear.
        const ins = overlayInsets();
        const free: dvui.Rect.Physical = .{ .x = area.x + ins.left * ns, .y = area.y, .w = @max(1, area.w - (ins.left + ins.right) * ns), .h = @max(1, area.h - ins.bottom * ns) };
        state.view.ppm = 0.96 * @min((free.w - 2.5 * rw) / b.width(), (free.h - 2.5 * rw) / b.height());
        const dx = (free.x + free.w / 2) - (area.x + area.w / 2);
        const dy = (free.y + free.h / 2) - (area.y + area.h / 2);
        state.view.cx = (b.x0 + b.x1) / 2 - dx / state.view.ppm;
        state.view.cy = (b.y0 + b.y1) / 2 + dy / state.view.ppm;
    }
    // Drawn last, over everything.
    defer drawRulers(area);
    const clip = dvui.clip(area);
    defer dvui.clipSet(clip);

    // With a panel or the canvas as the context, typed text makes a
    // label: ask for text input, which the backend sends only on request.
    if (state.context == .panel and track_cursor == null and !canvas_prompt and cursorKeysReach()) {
        const ns_ = dvui.windowNaturalScale();
        dvui.wantTextInput(.{ .x = area.x / ns_, .y = area.y / ns_, .w = area.w / ns_, .h = area.h / ns_ });
    }
    canvasEvents(box, area);
    const px = dvui.windowNaturalScale();
    if (open) {
        // An open canvas: drafting surface everywhere, and its axes
        // through the origin.
        area.fill(.square, .{ .color = .{ .color = colors.paper } });
        drawAxes(area);
    } else {
        // Work happens on the worksheet: the view's centre stays on the sheet.
        state.view.cx = std.math.clamp(state.view.cx, 0, sheet.w);
        state.view.cy = std.math.clamp(state.view.cy, 0, sheet.h);
        const sheet_rect = state.view.rect(area, sheet.box());
        sheet_rect.fill(.square, .{ .color = .{ .color = colors.paper } });
        drawMargins(area, sheet);
        sheet_rect.stroke(.square, .{ .thickness = px, .color = .{ .color = colors.edge } });
    }

    // Re-flatten label outlines when the zoom has moved more than 2x.
    const tol = 0.2 / state.view.ppm;
    if (state.flat.tol == 0 or tol < state.flat.tol / 2 or tol > state.flat.tol * 2) state.flat.reset(tol);

    if (open) drawFrameBound(area);
    if (open) drawSpace(area, shown_space, 0) else drawSpacePanels(area, null, null);

    drawPicked(area);
    drawPolygonDraft(area);

    // Tracks being drawn out: the region they snap to, divided into them,
    // and their count and length.
    if (state.drag) |d| if (state.tool == .add_tracks) {
        if (planTracks(d.start, d.at)) |plan| drawTrackPlan(area, plan);
    } else {
        const r = state.view.rect(area, dragBox(d.start, d.at));
        r.fill(.square, .{ .color = .{ .color = colors.select.opacity(0.12) } });
        r.stroke(.square, .{ .thickness = 1.5 * px, .color = .{ .color = colors.select } });
    };
    if (state.tool == .add_panel and state.model.panels.items.len == 0 and state.drag == null) {
        dvui.labelNoFmt(@src(), "Drag out the new panel on the sheet. Esc cancels.", .{}, .{
            .gravity_x = 0.5,
            .gravity_y = 0.05,
            .color_text = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.6) },
        });
    }
}

/// The margins as translucent bands inside the sheet's edge, and the ink
/// area's boundary as a thin line.
fn drawMargins(area: dvui.Rect.Physical, sheet: layout.model.Sheet) void {
    const px = dvui.windowNaturalScale();
    const s = sheet.box();
    const ink = sheet.inkArea();
    const band: dvui.ColorOrGradient = .{ .color = colors.guide.opacity(0.10) };
    for ([_]geom.Box{
        .{ .x0 = s.x0, .y0 = s.y0, .x1 = ink.x0, .y1 = s.y1 },
        .{ .x0 = ink.x1, .y0 = s.y0, .x1 = s.x1, .y1 = s.y1 },
        .{ .x0 = ink.x0, .y0 = ink.y1, .x1 = ink.x1, .y1 = s.y1 },
        .{ .x0 = ink.x0, .y0 = s.y0, .x1 = ink.x1, .y1 = ink.y0 },
    }) |b| {
        if (b.width() > 0 and b.height() > 0) state.view.rect(area, b).fill(.square, .{ .color = band });
    }
    state.view.rect(area, ink).stroke(.square, .{ .thickness = px, .color = .{ .color = colors.guide.opacity(0.7) } });
}

/// Panel `pi`'s compliance issue, if it has one.
fn panelIssue(pi: usize) ?layout.drc.PanelIssue {
    for (state.panel_issues) |i| if (i.panel == pi) return i;
    return null;
}

/// A panel's margins as a light translucent band inside its outline, and
/// its ink area's boundary as a thin line.
fn drawPanelMargins(area: dvui.Rect.Physical, pi: usize) void {
    const px = dvui.windowNaturalScale();
    const p = state.model.panels.items[pi];
    const b = panelBox(pi);
    const ink = p.margins.inset(b);
    const band: dvui.ColorOrGradient = .{ .color = colors.guide.opacity(0.07) };
    for ([_]geom.Box{
        .{ .x0 = b.x0, .y0 = b.y0, .x1 = ink.x0, .y1 = b.y1 },
        .{ .x0 = ink.x1, .y0 = b.y0, .x1 = b.x1, .y1 = b.y1 },
        .{ .x0 = ink.x0, .y0 = ink.y1, .x1 = ink.x1, .y1 = b.y1 },
        .{ .x0 = ink.x0, .y0 = b.y0, .x1 = ink.x1, .y1 = ink.y0 },
    }) |r| {
        if (r.width() > 0 and r.height() > 0) state.view.rect(area, r).fill(.square, .{ .color = band });
    }
    if (ink.width() > 0 and ink.height() > 0) state.view.rect(area, ink).stroke(.square, .{ .thickness = px, .color = .{ .color = colors.guide.opacity(0.45) } });
}

fn inMargin(pi: usize, tile: ?TileId, slot: usize, run_region: ?usize) bool {
    for (state.intrusions) |i| if (i.panel == pi and i.tile == tile and i.slot == slot and i.run_region == run_region) return true;
    return false;
}

/// A panel label's ink box on the worksheet, from the last solve, moved to
/// its preview place while dragged.
fn labelBox(pi: usize, index: usize) ?geom.Box {
    if (pi >= state.placed.items.len) return null;
    for (state.placed.items[pi].labels) |l| {
        if (l.tile != null or l.run != null or l.slot != index) continue;
        const d = labelDelta(pi, index);
        const b = onSheet(pi, l.box);
        return .{ .x0 = b.x0 + d.x, .y0 = b.y0 + d.y, .x1 = b.x1 + d.x, .y1 = b.y1 + d.y };
    }
    return null;
}

/// How far a dragged panel label has travelled, in 0.5 mm steps.
fn labelDelta(pi: usize, index: usize) geom.Point {
    if (state.moving_label) |mv| if (mv.panel == pi and mv.index == index) return .{
        .x = @round((mv.at.x - mv.start.x) * 2) / 2,
        .y = @round((mv.at.y - mv.start.y) * 2) / 2,
    };
    return .{ .x = 0, .y = 0 };
}

/// The style for new panel labels: "Label", 3 mm cap height in the legend
/// font, made the first time it is needed.
fn labelStyle() !layout.model.StyleId {
    return labelStyleIn(null);
}

/// As `labelStyle`, making the style (when it has to) as part of the step
/// merged under `key`.
fn labelStyleIn(key: ?u64) !layout.model.StyleId {
    if (state.label_style) |s| return s;
    const s = if (key) |k| try actM(k, .addStyle, .{ "Label", .{ .upright = 0, .cap_height = 3 } }) else try act(.addStyle, .{ "Label", .{ .upright = 0, .cap_height = 3 } });
    state.label_style = s;
    return s;
}

/// A label begun by typing `txt` on panel `pi`: at the last click on it,
/// else at the view's centre, in the label style; it becomes the context
/// and the expression line takes the keyboard, its cursor after `txt`.
fn typeLabel(pi: usize, txt: []const u8) void {
    const at = if (click_at) |c| (if (panelHolds(pi, c)) c else geom.Point{ .x = state.view.cx, .y = state.view.cy }) else geom.Point{ .x = state.view.cx, .y = state.view.cy };
    const o = state.model.panels.items[pi].origin;
    // The style (if new), the label and the typing into it: one undo step.
    const k = mergeKey(.{ "new label", pi, hist.next_step });
    const style = labelStyleIn(k) catch return;
    const li = actM(k, .addLabel, .{ pi, .{
        .at = .{ .x = @round((at.x - o.x) * 2) / 2, .y = @round((at.y - o.y) * 2) / 2 },
        .style = style,
        .content = txt,
    } }) catch return;
    hist.mergeAs(mergeKey(.{ "label", pi, li }));
    state.context = .{ .label = .{ .panel = pi, .index = li } };
    focus_expression = true;
    focus_expression_end = true;
}

/// A frame's properties: its name, its boundary (fitted to what it holds),
/// and what it holds.
fn frameProperties(space: usize) !void {
    const sp = state.model.spaces.items[space];
    propText("Name", "{s}", .{sp.name}, 1);
    if (sp.bound) |b| propText("Boundary", "{d:.1} × {d:.1} mm", .{ b.width(), b.height() }, 2) else propText("Boundary", "{s}", .{"none yet"}, 2);
    propText("Groups", "{d}", .{sp.groups.items.len}, 3);
    var panels: usize = 0;
    for (state.model.panels.items) |p| {
        if (p.space == space and !p.unbounded) panels += 1;
    }
    propText("Panels", "{d}", .{panels}, 4);
    if (dvui.button(@src(), "Fit frame to its contents", .{}, .{ .margin = .{ .y = 8 } })) {
        const e = spaceExtents();
        if (e.isEmpty()) {
            state.status = "The frame holds nothing to fit. ";
        } else {
            const margin = 5.0;
            act(.setFrameBound, .{space, .{ .x0 = e.x0 - margin, .y0 = e.y0 - margin, .x1 = e.x1 + margin, .y1 = e.y1 + margin }}) catch {};
        }
    }
    layersList(space);
    placeViewButtons(space);
}

/// A group's properties: what it holds, and how to move or dissolve it.
fn groupProperties(id: layout.model.ObjectId) !void {
    const g = state.model.group(id) orelse return;
    propText("Name", "{s}", .{g.name}, 1);
    propText("Members", "{d}", .{g.members.items.len}, 2);
    if (state.model.parentGroup(id)) |p| if (state.model.group(p)) |pg| propText("In group", "{s}", .{pg.name}, 3);
    propText("Moves", "{s}", .{"arrow keys, 1 mm, all together"}, 4);
    if (dvui.button(@src(), "Ungroup", .{}, .{ .margin = .{ .y = 8 } })) {
        const parent = state.model.parentGroup(id);
        const space = state.model.spaceOfId(id) orelse shown_space;
        act(.ungroup, .{id}) catch return;
        state.context = if (parent) |p| .{ .group = p } else .{ .panel = state.model.spaces.items[space].root };
    }
}

/// Objects picked with Select area: how many, and what can be done with
/// them: group them in place, or move or copy them to another space.
fn selectionProperties() !void {
    propText("Objects", "{d}", .{selection.items.len}, 1);
    if (selection.items.len == 0) return;
    if (dvui.button(@src(), "Group", .{}, .{ .expand = .horizontal, .margin = .{ .y = 6 } })) groupSelection();
    if (dvui.button(@src(), "Move to a new frame", .{}, .{ .expand = .horizontal })) transferSelection(null, false);
    if (dvui.button(@src(), "Copy to a new frame", .{}, .{ .expand = .horizontal })) transferSelection(null, true);
    for (state.model.spaces.items, 0..) |sp, si| {
        if (si == shown_space) continue;
        var buf: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "Move to {s}", .{if (si == 0) "the canvas" else sp.name}) catch "Move";
        if (dvui.button(@src(), text, .{}, .{ .expand = .horizontal, .id_extra = si })) transferSelection(si, false);
    }
}

/// Groups the selection where it is, and makes the group the context.
fn groupSelection() void {
    if (selection.items.len == 0) return;
    var nb: [32]u8 = undefined;
    var n: usize = 1;
    for (state.model.spaces.items) |sp| n += sp.groups.items.len;
    const name = std.fmt.bufPrint(&nb, "Group {d}", .{n}) catch "Group";
    const g = act(.makeGroup, .{selection.items, name}) catch {
        state.status = "They could not be grouped. ";
        return;
    };
    selection.clearRetainingCapacity();
    state.context = .{ .group = g };
    if (canvas_id) |id| dvui.focusWidget(id, null, null);
}

/// Moves (or copies) the selection to space `dest` (a new frame, fitted
/// around it, when null), shows that space, and makes the group the
/// objects arrived as the context, so the next move places them all.
fn transferSelection(dest: ?usize, copy: bool) void {
    const items = selection.items;
    if (items.len == 0) return;
    const target = dest orelse blk: {
        var nb: [32]u8 = undefined;
        const name = state.model.nextFrameName(&nb, "Frame");
        const e = selectionExtents();
        const margin = 10.0;
        const edge: ?geom.Box = if (e.isEmpty()) null else .{ .x0 = e.x0 - margin, .y0 = e.y0 - margin, .x1 = e.x1 + margin, .y1 = e.y1 + margin };
        const f = act(.addFrame, .{name, edge}) catch return;
        state.model.spaces.items[f].default_name = true;
        break :blk f;
    };
    const g = (if (copy) act(.copyToSpace, .{items, target}) else act(.moveToSpace, .{items, target})) catch {
        state.status = "They could not be moved there. ";
        return;
    };
    selection.clearRetainingCapacity();
    track_cursor = null;
    shown_space = target;
    state.context = .{ .group = g };
    // The keyboard goes to the canvas, for the arrow keys.
    if (canvas_id) |id| dvui.focusWidget(id, null, null);
    state.status = "Arrived as one group: arrow keys move it into place. ";
}

/// The selection's extents in its space, from the last solve.
fn selectionExtents() geom.Box {
    var b: geom.Box = .empty;
    for (selection.items) |id| b = b.join(idBox(id));
    return b;
}

/// An object's or a group's extents in its space, from the last solve.
fn idBox(id: layout.model.ObjectId) geom.Box {
    if (state.model.group(id)) |g| {
        var b: geom.Box = .empty;
        for (g.members.items) |mb| b = b.join(idBox(mb));
        return b;
    }
    const loc = state.model.locate(id) orelse return .empty;
    return memberBox(loc);
}

/// A member's extents in its space: a panel's outline, a label's ink, line
/// art's shapes, a track's segments.
fn memberBox(mb: layout.model.Member) geom.Box {
    switch (mb) {
        .panel => |pi| return state.model.panels.items[pi].box(),
        .label => |l| return labelBox(l.panel, l.index) orelse .empty,
        .art => |l| return onSheet(l.panel, state.model.panels.items[l.panel].art.items[l.index].box()),
        .region => |l| {
            var b: geom.Box = .empty;
            if (l.panel < state.placed.items.len) for (state.placed.items[l.panel].tracks) |t| {
                if (t.region == l.index) b = b.join(onSheet(l.panel, t.box));
            };
            return b;
        },
    }
}

/// Select area: what lies wholly inside box `b` in the shown space. A
/// grouped object is picked only with its whole outermost group.
fn selectArea(b: geom.Box) void {
    defer state.tool = .select;
    selection.clearRetainingCapacity();
    var inside: std.ArrayList(layout.model.ObjectId) = .empty;
    defer inside.deinit(state.gpa);
    for (state.model.panels.items, 0..) |p, pi| {
        if (!shownPanel(pi)) continue;
        if (!p.unbounded) {
            if (layout.model.within(p.box(), b)) inside.append(state.gpa, p.id) catch {};
            continue;
        }
        const kinds = [_]struct { n: usize, k: u2 }{ .{ .n = p.labels.items.len, .k = 0 }, .{ .n = p.art.items.len, .k = 1 }, .{ .n = p.regions.items.len, .k = 2 } };
        for (kinds) |kind| for (0..kind.n) |i| {
            const loc: layout.model.Member = switch (kind.k) {
                0 => .{ .label = .{ .panel = pi, .index = i } },
                1 => .{ .art = .{ .panel = pi, .index = i } },
                else => .{ .region = .{ .panel = pi, .index = i } },
            };
            const mb = memberBox(loc);
            if (!mb.isEmpty() and layout.model.within(mb, b)) inside.append(state.gpa, state.model.idAt(loc)) catch {};
        };
    }
    for (inside.items) |id| {
        const top = state.model.topLevel(id);
        if (std.mem.indexOfScalar(layout.model.ObjectId, selection.items, top) != null) continue;
        if (top != id and !layout.model.within(idBox(top), b)) continue;
        selection.append(state.gpa, top) catch {};
    }
    state.context = if (selection.items.len > 0) .selection else if (spaceRoot()) |r| .{ .panel = r } else .worksheet;
    track_cursor = null;
    if (selection.items.len == 0) state.status = "Nothing lies wholly inside that area. ";
}

/// The outermost group holding what context `c` names, if it is grouped.
fn groupOf(c: Context) ?layout.model.ObjectId {
    const loc: layout.model.Member = switch (c) {
        .panel => |pi| if (state.model.panels.items[pi].unbounded) return null else .{ .panel = pi },
        .label => |l| .{ .label = .{ .panel = l.panel, .index = l.index } },
        .art => |l| .{ .art = .{ .panel = l.panel, .index = l.index } },
        .region => |r| .{ .region = .{ .panel = r.panel, .index = r.region } },
        else => return null,
    };
    const id = state.model.idAt(loc);
    const top = state.model.topLevel(id);
    return if (top == id) null else top;
}

/// Moves the selected group 1 mm the way an arrow points.
fn moveGroupKey(code: dvui.enums.Key) bool {
    const g = switch (state.context) {
        .group => |g| g,
        else => return false,
    };
    const d: geom.Point = switch (code) {
        .up => .{ .x = 0, .y = 1 },
        .down => .{ .x = 0, .y = -1 },
        .left => .{ .x = -1, .y = 0 },
        .right => .{ .x = 1, .y = 0 },
        else => return false,
    };
    actM(mergeKey(.{ "moveGroupKey", state.context }), .moveGroup, .{g, d.x, d.y}) catch return false;
    return true;
}

/// Outlines what the selection or the selected group holds.
fn drawPicked(area: dvui.Rect.Physical) void {
    const px = dvui.windowNaturalScale();
    const focus = colors.select;
    switch (state.context) {
        .selection => for (selection.items) |id| {
            const b = idBox(id);
            if (!b.isEmpty()) marchingBox(area, b, focus, 2 * px);
        },
        .group => |g| {
            const grp = state.model.group(g) orelse return;
            for (grp.members.items) |mb| {
                const b = idBox(mb);
                if (!b.isEmpty()) state.view.rect(area, b).stroke(.square, .{ .thickness = px, .color = .{ .color = focus.opacity(0.6) } });
            }
            const all = idBox(g);
            if (!all.isEmpty()) marchingBox(area, .{ .x0 = all.x0 - 2, .y0 = all.y0 - 2, .x1 = all.x1 + 2, .y1 = all.y1 + 2 }, focus, 1.5 * px);
        },
        else => {},
    }
}

/// The canvas's properties: its units (a conversion: nothing moves), and
/// what it holds.
fn canvasProperties(pi: usize) !void {
    const panel = state.model.panels.items[pi];
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 1 });
        defer row.deinit();
        propName("Units");
        const names = [_][]const u8{ "Millimetres", "Inches", "Mils" };
        var choice: usize = @intFromEnum(state.model.units);
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .id_extra = 1 })) actV(.setCanvasUnits, .{@enumFromInt(choice)});
    }
    propText("Labels", "{d}", .{panel.labels.items.len}, 2);
    propText("Tracks", "{d}", .{panel.regions.items.len}, 3);
    propText("Line art", "{d}", .{panel.art.items.len}, 4);
    var on_canvas: usize = 0;
    for (state.model.panels.items) |p| {
        if (p.space == 0 and !p.unbounded) on_canvas += 1;
    }
    propText("Panels", "{d}", .{on_canvas}, 5);
    propText("Typing", "{s}", .{"makes a label where you last clicked"}, 6);
    {
        var buf: [96]u8 = undefined;
        var tb: [16]u8 = undefined;
        const lang = if (languages.len > 0) languages[0].tag(&tb) else "not given";
        propText("Language", "{s}", .{std.fmt.bufPrint(&buf, "{s}{s}", .{ lang, if (languages.len > 1) " and others" else "" }) catch lang}, 8);
        const from = switch (measurement_source) {
            .config => "your settings",
            .system => "the system",
            .country => "your language's country",
            .default => "no locale given",
        };
        propText("Measures", "{s}, from {s}", .{ @tagName(measurement), from }, 9);
    }
    try propFont("Legend font", 7);
    layersList(0);
    placeViewButtons(0);
}

/// Makes line art from a finished drag: the chosen shape filling the box
/// (a circle in its shorter side), on its panel, made the context.
fn addArtFromDrag(b: geom.Box) void {
    defer state.tool = .select;
    const pi = switch (state.context) {
        .panel => |pi| pi,
        else => return,
    };
    if (!(b.width() >= 1 and b.height() >= 1)) return;
    const prim: layout.art.Primitive = switch (shape_kind) {
        .rect => .{ .rect = .{ .w = b.width(), .h = b.height() } },
        .rounded => .{ .rounded = .{ .w = b.width(), .h = b.height(), .r = @min(3.0, @min(b.width(), b.height()) / 4) } },
        .circle => .{ .circle = @min(b.width(), b.height()) },
        .ellipse => .{ .ellipse = .{ .w = b.width(), .h = b.height() } },
        .slot => .{ .slot = .{ .w = b.width(), .h = b.height() } },
        .polygon => return,
    };
    addPrimitive(pi, prim, .{ .x = b.x0, .y = b.y0 });
}

/// Adds primitive `prim` as line art on panel `pi`, its box's corner at
/// worksheet point `at`, and makes it the context. Drawn as an outline:
/// these are paths to cut or to make panels from.
fn addPrimitive(pi: usize, prim: layout.art.Primitive, at: geom.Point) void {
    const o = state.model.panels.items[pi].origin;
    var name_buf: [48]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s} {d}", .{ prim.label(), state.model.panels.items[pi].art.items.len + 1 }) catch "Shape";
    const shapes = layout.art.primitive(dvui.currentWindow().arena(), name, prim, .{
        .edge = .{ .r = 0x2b, .g = 0x2b, .b = 0x2b },
        .edge_width = 0.25,
    }) catch return;
    // An outline lies over what is drawn inside it; a cutout keeps it away.
    const ai = act(.addArt, .{pi, .{ .name = name, .at = .{ .x = at.x - o.x, .y = at.y - o.y }, .shapes = shapes, .prim = prim, .wrap = .none }}) catch return;
    state.context = .{ .art = .{ .panel = pi, .index = ai } };
}

/// A click while drawing a polygon: a new corner, or, on the first
/// corner again, the polygon closed.
fn polygonClick(pi: usize, at: geom.Point) void {
    if (polygon_pts.items.len > 0 and polygon_panel != pi) polygon_pts.clearRetainingCapacity();
    polygon_panel = pi;
    if (polygon_pts.items.len >= 3) {
        const first = polygon_pts.items[0];
        const near = 6 / state.view.ppm;
        if (@abs(at.x - first.x) <= near and @abs(at.y - first.y) <= near) {
            finishPolygon();
            return;
        }
    }
    polygon_pts.append(state.gpa, at) catch {};
}

/// Closes the polygon being drawn (three corners at least) as line art.
fn finishPolygon() void {
    defer polygon_pts.clearRetainingCapacity();
    if (polygon_pts.items.len < 3) {
        state.status = "A polygon needs three corners at least. ";
        return;
    }
    var box: geom.Box = .empty;
    for (polygon_pts.items) |q| box = box.join(.{ .x0 = q.x, .y0 = q.y, .x1 = q.x, .y1 = q.y });
    const pts = dvui.currentWindow().arena().alloc(geom.Point, polygon_pts.items.len) catch return;
    for (polygon_pts.items, pts) |q, *r| r.* = .{ .x = q.x - box.x0, .y = q.y - box.y0 };
    state.tool = .select;
    addPrimitive(polygon_panel, .{ .polygon = pts }, .{ .x = box.x0, .y = box.y0 });
}

/// The polygon being drawn: its corners joined, and on to the pointer.
fn drawPolygonDraft(area: dvui.Rect.Physical) void {
    if (state.tool != .add_art or shape_kind != .polygon or polygon_pts.items.len == 0) return;
    const px = dvui.windowNaturalScale();
    const focus = colors.select;
    const n = polygon_pts.items.len + @as(usize, if (state.mouse != null) 1 else 0);
    const pts = dvui.currentWindow().arena().alloc(dvui.Point.Physical, n) catch return;
    for (polygon_pts.items, 0..) |q, i| pts[i] = state.view.toPx(area, q);
    if (state.mouse) |m| pts[n - 1] = state.view.toPx(area, m);
    if (pts.len >= 2) dvui.Path.stroke(.{ .points = pts }, .{ .thickness = 1.5 * px, .color = .{ .color = focus } });
    for (polygon_pts.items) |q| {
        const c = state.view.toPx(area, q);
        const r: dvui.Rect.Physical = .{ .x = c.x - 3 * px, .y = c.y - 3 * px, .w = 6 * px, .h = 6 * px };
        r.fill(.square, .{ .color = .{ .color = focus } });
    }
}

/// Moves the selected line art 1 mm the way an arrow points.
fn moveArtKey(code: dvui.enums.Key) bool {
    const l = switch (state.context) {
        .art => |l| l,
        else => return false,
    };
    const d: geom.Point = switch (code) {
        .up => .{ .x = 0, .y = 1 },
        .down => .{ .x = 0, .y = -1 },
        .left => .{ .x = -1, .y = 0 },
        .right => .{ .x = 1, .y = 0 },
        else => return false,
    };
    const at = state.model.panels.items[l.panel].art.items[l.index].at;
    actM(mergeKey(.{ "moveArtKey", state.context }), .moveArt, .{l.panel, l.index, .{ .x = at.x + d.x, .y = at.y + d.y }}) catch return false;
    return true;
}

/// Line art's properties: where it is, and how tracks under it flow.
fn artProperties(pi: usize, index: usize) !void {
    const pa = state.model.panels.items[pi].art.items[index];
    propText("Name", "{s}", .{pa.name}, 1);
    const b = pa.box();
    propText("Box", "({d:.1}, {d:.1}) to ({d:.1}, {d:.1}) mm", .{ b.x0, b.y0, b.x1, b.y1 }, 2);
    propText("Moves", "{s}", .{"arrow keys, 1 mm"}, 3);
    var wrap = pa.wrap;
    var clearance = pa.clearance;
    var changed = false;
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 4 });
        defer row.deinit();
        propName("Tracks under it");
        const names = [_][]const u8{ "Run straight under", "Flow around its box", "Flow around its ink" };
        // (What flows: the tracks' tiles, unless they stay under it below,
        // and the labels on them.)
        var choice: usize = @intFromEnum(wrap);
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .id_extra = 4 })) {
            wrap = @enumFromInt(choice);
            changed = true;
        }
    }
    var buf: [32]u8 = undefined;
    if (sizesProp("Clearance, mm", if (clearance > 0) std.fmt.bufPrint(&buf, "{d}", .{clearance}) catch "" else "any", 5)) |list| if (list.len <= 1) {
        clearance = if (list.len == 1) list[0] else 0;
        changed = true;
    };
    if (changed) try act(.setArtWrap, .{pi, index, wrap, clearance});
    {
        // Off, tracks lie under it (a mark printed over keys): their tiles
        // stay, and only labels on them wrap around it.
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 6 });
        defer row.deinit();
        propName("Tiles");
        var on = pa.wrap_tracks;
        if (dvui.checkbox(@src(), &on, "Move out from under it", .{ .id_extra = 6 })) try act(.setArtWrapsTracks, .{pi, index, on});
    }
    try shapeProperties(pi, index);
}

/// Line art's shape: what it was drawn as, a rounded rectangle's corner
/// radius, whether it is a cutout, and Make panel for a closed path lying
/// loose in a space.
fn shapeProperties(pi: usize, index: usize) !void {
    const pa = state.model.panels.items[pi].art.items[index];
    propText("Shape", "{s}", .{pa.prim.label()}, 10);
    switch (pa.prim) {
        .rounded => |r| {
            var buf: [32]u8 = undefined;
            if (sizesProp("Corner radius, mm", std.fmt.bufPrint(&buf, "{d}", .{r.r}) catch "", 11)) |list| if (list.len == 1) {
                act(.setArtCorner, .{pi, index, list[0]}) catch {
                    state.status = "That radius could not be used. ";
                };
            };
        },
        .circle => |d| propText("Diameter", "{d:.2} mm", .{d}, 11),
        else => {},
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 12 });
        defer row.deinit();
        propName("Cutout");
        var on = pa.cutout;
        if (dvui.checkbox(@src(), &on, "Cut through the panel", .{ .id_extra = 12 })) try act(.setArtCutout, .{pi, index, on});
    }
    if (!state.model.panels.items[pi].unbounded) return;
    if (pa.closedPath() == null) {
        propText("Panel", "{s}", .{"only a single closed path makes one"}, 13);
        return;
    }
    if (dvui.button(@src(), "Make panel", .{}, .{ .expand = .horizontal, .margin = .{ .y = 8 } })) {
        const np = act(.makePanel, .{pi, index}) catch {
            state.status = "A panel could not be made from it. ";
            return;
        };
        hist.join(&state.model, .setPanelLayer, .{ np, newObjectLayer() }) catch {};
        state.context = .{ .panel = np };
        state.expanded.put(state.gpa, Context.key(.{ .panel = np }), true) catch {};
        if (canvas_id) |id| dvui.focusWidget(id, null, null);
        state.status = "Made a panel: what it encloses moves with it. ";
    }
}

/// Places a new label on panel `pi` at worksheet point `at` (on a 0.5 mm
/// grid), with placeholder text; the context stays the panel.
fn addLabelAt(pi: usize, at: geom.Point) void {
    const o = state.model.panels.items[pi].origin;
    const style = labelStyle() catch return;
    _ = act(.addLabel, .{pi, .{
        .at = .{ .x = @round((at.x - o.x) * 2) / 2, .y = @round((at.y - o.y) * 2) / 2 },
        .style = style,
        .content = "LABEL",
        .default_content = true,
    }}) catch return;
    state.expanded.put(state.gpa, Context.key(.{ .panel = pi }), true) catch {};
}

/// Tiles and legends of panel `pi`, moved onto the worksheet.
fn drawPanel(area: dvui.Rect.Physical, pi: usize, placed: *const layout.place.Placed) void {
    const px = dvui.windowNaturalScale();
    const radius: f32 = @floatCast(1.0 * state.view.ppm);
    const o = panelOrigin(pi);
    // Every track's band, faintly, so empty tracks show where tiles go.
    for (placed.tracks) |t| {
        // Past the panel's edge: in the warning colour.
        const outside = for (placed.issues) |i| {
            if (i.kind == .region_outside and i.region == t.region) break true;
        } else false;
        // Past its track's soft area: in the warning colour, lighter.
        const past_soft = for (placed.issues) |i| {
            if (i.kind == .past_soft_area and i.region == t.region and i.row == t.track) break true;
        } else false;
        const colour = if (outside) colors.overflow else if (past_soft) colors.overflow.opacity(0.5) else colors.guide.opacity(0.35);
        state.view.rect(area, onSheet(pi, t.box)).stroke(.square, .{ .thickness = if (outside) 1.5 * px else px, .color = .{ .color = colour } });
    }
    // The context track's soft area, which its rows or columns expand
    // into, as a faint dashed outline.
    const soft_region: ?usize = switch (state.context) {
        .region => |r| if (r.panel == pi) r.region else null,
        .row => |r| if (r.panel == pi) r.region else null,
        else => null,
    };
    if (soft_region) |sr| if (sr < state.model.panels.items[pi].regions.items.len) {
        dashedBox(area, onSheet(pi, state.model.panels.items[pi].regions.items[sr].softArea()), colors.guide.opacity(0.6), px);
    };
    for (placed.tiles) |t| {
        const in_context = inContext(pi, t);
        // A blank (a spacer tile): a faint outline while editing, nothing in
        // output.
        if (t.spacer) {
            const box = state.view.rect(area, onSheet(pi, t.pitch_box));
            const sel = in_context and state.context == .tile;
            box.stroke(.square, .{ .thickness = (if (sel) @as(f32, 2) else 1) * px, .color = .{ .color = if (sel) colors.select else colors.guide.opacity(0.3) } });
            continue;
        }
        const flagged = tileFlag(placed, t.id);
        const body = state.view.rect(area, onSheet(pi, t.body));
        const face = state.view.rect(area, onSheet(pi, t.face));
        // The tile's art, as placement stretched it: fills, then edges.
        const pieces = flatTile(&state.flat, t.shapes) catch &.{};
        for (pieces) |piece| {
            if (piece.shape.paint.fill != .none) fillRegion(area, piece.region, o, .{ .art = piece.shape.paint.fill });
            const edge = piece.shape.paint.edge orelse continue;
            const width: f32 = @max(px, @as(f32, @floatCast(piece.shape.paint.edge_width * state.view.ppm)));
            for (piece.lines) |line| strokeLoop(area, line, o, width, .{ .r = edge.r, .g = edge.g, .b = edge.b, .a = edge.a });
        }
        if (flagged.missing) face.fill(.round(radius), .{ .color = .{ .color = colors.missing } });
        if (flagged.overflow) face.stroke(.round(radius), .{ .thickness = 1.5 * px, .color = .{ .color = colors.overflow } });
        // A size its prototype does not allow: the body outlined in warning.
        if (flagged.size and !in_context) body.stroke(.round(radius), .{ .thickness = 1.5 * px, .color = .{ .color = colors.overflow } });
        if (in_context) body.stroke(.round(radius), .{ .thickness = (if (state.context == .tile) @as(f32, 3) else 2) * px, .color = .{ .color = colors.select } });
    }
    // Line art, over the tracks; the selected piece outlined.
    for (placed.art) |pa| {
        const pieces = flatTile(&state.flat, pa.shapes) catch &.{};
        if (pa.cutout) {
            // A hole: its outline, in the panel's edge colour, a little
            // heavier than line art.
            for (pieces) |piece| for (piece.lines) |line| strokeLoop(area, line, o, 1.5 * px, colors.panel_edge);
        } else for (pieces) |piece| {
            if (piece.shape.paint.fill != .none) fillRegion(area, piece.region, o, .{ .art = piece.shape.paint.fill });
            const edge = piece.shape.paint.edge orelse continue;
            const width: f32 = @max(px, @as(f32, @floatCast(piece.shape.paint.edge_width * state.view.ppm)));
            for (piece.lines) |line| strokeLoop(area, line, o, width, .{ .r = edge.r, .g = edge.g, .b = edge.b, .a = edge.a });
        }
        const sel = switch (state.context) {
            .art => |l| l.panel == pi and l.index == pa.index,
            else => false,
        };
        if (sel) marchingBox(area, onSheet(pi, pa.box), colors.select, 1.5 * px);
    }
    const lifo = dvui.currentWindow().lifo();
    for (placed.labels) |l| {
        const d = if (l.tile == null and l.run == null) labelDelta(pi, l.slot) else geom.Point{ .x = 0, .y = 0 };
        const pieces = state.flat.get(l.render, &state.faces) catch continue;
        // Ink in the sheet's margins is drawn in the warning colour.
        const ink = if (inMargin(pi, l.tile, l.slot, if (l.run) |r| r.region else null)) colors.overflow else colors.ink;
        const at: geom.Point = .{ .x = l.origin.x + o.x + d.x, .y = l.origin.y + o.y + d.y };
        for (pieces) |piece| {
            const color: dvui.Color = switch (piece.kind) {
                .ink => ink,
                .faint => ink.opacity(0.35),
                .placeholder => colors.select.opacity(0.7),
            };
            if (show_construction and piece.kind == .ink) {
                // Outlines over a translucent fill, so the lines show through.
                fillRegion(area, piece.region, at, .{ .flat = color.opacity(0.18) });
                for (piece.region.loops) |loop| {
                    const pts = lifo.alloc(dvui.Point.Physical, loop.len) catch break;
                    defer lifo.free(pts);
                    for (loop, pts) |q, *out| out.* = state.view.toPx(area, .{ .x = q.x + at.x, .y = q.y + at.y });
                    dvui.Path.stroke(.{ .points = pts }, .{ .thickness = px, .color = .{ .color = color }, .closed = true });
                }
            } else {
                fillRegion(area, piece.region, at, .{ .flat = color });
            }
        }
        if (show_construction) drawConstruction(area, l, .{ .x = o.x + d.x, .y = o.y + d.y });
        if (caretIn(pi, l)) |c| {
            const x = l.origin.x + o.x + d.x + c.x;
            const y = l.origin.y + o.y + d.y;
            const a = state.view.toPx(area, .{ .x = x, .y = y + c.y0 });
            const b = state.view.toPx(area, .{ .x = x, .y = y + c.y1 });
            dvui.Path.stroke(.{ .points = &.{ a, b } }, .{ .thickness = 1.5 * px, .color = .{ .color = colors.select } });
        }
    }
    drawFlowMarks(area, pi, placed);
    if (track_cursor) |c| if (c.panel == pi) drawCursor(area, pi, placed, c);
    // The selected panel label: its ink box, with a little room.
    switch (state.context) {
        .label => |sel| if (sel.panel == pi) if (labelBox(pi, sel.index)) |b| {
            const pad = 0.6;
            state.view.rect(area, .{ .x0 = b.x0 - pad, .y0 = b.y0 - pad, .x1 = b.x1 + pad, .y1 = b.y1 + pad }).stroke(.square, .{ .thickness = 1.5 * px, .color = .{ .color = colors.select } });
        },
        else => {},
    }
}

/// Fills a resolved region placed at worksheet point `at`: its triangles as
/// they are, then a band one pixel wide fading out past each loop, for
/// antialiasing.
fn fillRegion(area: dvui.Rect.Physical, region: geom.fill.Region, at: geom.Point, paint: Paint) void {
    const lifo = dvui.currentWindow().lifo();
    const Index = dvui.Vertex.Index;
    // Vertex indices may be 16-bit: the triangles go in batches.
    const batch = 20000;
    var from: usize = 0;
    while (from < region.triangles.len) : (from += batch) {
        const tris = region.triangles[from..@min(from + batch, region.triangles.len)];
        var b = dvui.Triangles.Builder.init(lifo, 3 * tris.len, 3 * tris.len) catch return;
        defer b.deinit(lifo);
        for (tris, 0..) |t, k| {
            var v: [3]dvui.Point.Physical = undefined;
            for (t, &v) |q, *out| out.* = state.view.toPx(area, .{ .x = q.x + at.x, .y = q.y + at.y });
            for (v, t) |pos, q| b.appendVertex(.{ .pos = pos, .col = paint.at(q) });
            const i: Index = @intCast(3 * k);
            b.appendTriangles(&ccw(v[0], v[1], v[2], i, i + 1, i + 2));
        }
        dvui.renderTriangles(b.build_unowned(), null) catch {};
    }
    for (region.loops) |loop| {
        if (loop.len < 3 or loop.len > 30000) continue;
        const n = loop.len;
        var b = dvui.Triangles.Builder.init(lifo, 2 * n, 6 * n) catch return;
        defer b.deinit(lifo);
        const pts = lifo.alloc(dvui.Point.Physical, n) catch return;
        defer lifo.free(pts);
        for (loop, pts) |q, *out| out.* = state.view.toPx(area, .{ .x = q.x + at.x, .y = q.y + at.y });
        for (pts, 0..) |p, i| {
            // Loops keep the filled side on their left, so outward is to
            // the right of each edge.
            const out_in = outward(pts[(i + n - 1) % n], p);
            const out_next = outward(p, pts[(i + 1) % n]);
            var nx = (out_in.x + out_next.x) / 2;
            var ny = (out_in.y + out_next.y) / 2;
            // Mitred, within reason.
            const d2 = nx * nx + ny * ny;
            if (d2 > 1e-6) {
                nx /= d2;
                ny /= d2;
            }
            const len = @sqrt(nx * nx + ny * ny);
            if (len > 2) {
                nx *= 2 / len;
                ny *= 2 / len;
            }
            b.appendVertex(.{ .pos = p, .col = paint.at(loop[i]) });
            b.appendVertex(.{ .pos = .{ .x = p.x + nx, .y = p.y + ny }, .col = .transparent });
        }
        for (0..n) |i| {
            const j = (i + 1) % n;
            const ii: Index = @intCast(2 * i);
            const jj: Index = @intCast(2 * j);
            const v = b.vertexes.items;
            b.appendTriangles(&ccw(v[ii].pos, v[ii + 1].pos, v[jj].pos, ii, ii + 1, jj));
            b.appendTriangles(&ccw(v[ii + 1].pos, v[jj + 1].pos, v[jj].pos, ii + 1, jj + 1, jj));
        }
        dvui.renderTriangles(b.build_unowned(), null) catch {};
    }
}

/// What fills a region: one colour, or a tile art fill, whose gradient is
/// in the region's own frame (before `at` moves it).
const Paint = union(enum) {
    flat: dvui.Color,
    art: layout.art.Fill,

    /// The premultiplied colour at `q`, in the region's frame.
    fn at(p: Paint, q: geom.Point) dvui.Color.PMA {
        const c: dvui.Color = switch (p) {
            .flat => |c| c,
            .art => |f| if (f.at(q)) |ac| .{ .r = ac.r, .g = ac.g, .b = ac.b, .a = ac.a } else .transparent,
        };
        return .fromColor(c.opacity(dvui.currentWindow().alpha));
    }
};

/// The unit normal to the right of the edge from `p` to `q`, on screen.
fn outward(p: dvui.Point.Physical, q: dvui.Point.Physical) dvui.Point.Physical {
    const dx = q.x - p.x;
    const dy = q.y - p.y;
    const len = @sqrt(dx * dx + dy * dy);
    if (len == 0) return .{ .x = 0, .y = 0 };
    return .{ .x = -dy / len, .y = dx / len };
}

/// A triangle's indices in the order DVUI draws (counter-clockwise, y down).
fn ccw(p0: dvui.Point.Physical, p1: dvui.Point.Physical, p2: dvui.Point.Physical, a: dvui.Vertex.Index, b: dvui.Vertex.Index, c: dvui.Vertex.Index) [3]dvui.Vertex.Index {
    const cross = (p1.x - p0.x) * (p2.y - p0.y) - (p1.y - p0.y) * (p2.x - p0.x);
    return if (cross <= 0) .{ a, b, c } else .{ a, c, b };
}

/// The expression line's cursor in placed label `l` of panel `pi`, if it
/// is the one being edited.
fn caretIn(pi: usize, l: layout.place.PlacedLabel) ?engine.Caret {
    const c = expr_caret orelse return null;
    const mine = switch (c.target) {
        .panel_label => |t| t.panel == pi and l.tile == null and l.run == null and l.slot == t.index,
        .tile_slot => |t| l.tile != null and std.meta.eql(l.tile.?, t.tile) and l.slot == t.slot,
        .run => |t| t.panel == pi and l.run != null and l.run.?.region == t.region and l.run.?.item == t.item,
    };
    if (!mine) return null;
    // A run of text set word by word: the word the caret is in (or just
    // after) draws it, measured from the word's start.
    if (l.run) |run| if (run.len > 0) {
        const off: u32 = @intCast(c.offset);
        if (off < run.from or off > run.from + run.len) return null;
        return l.render.caret(off - run.from);
    };
    return l.render.caret(@intCast(c.offset));
}

/// View › Show text construction: text as outlines over a translucent fill,
/// with every element's frame lines, the anchor and the ink box.
var show_construction = false;

const construction = struct {
    const ascender: dvui.Color = .{ .r = 0x7a, .g = 0x5c, .b = 0xc4 };
    const cap: dvui.Color = .{ .r = 0x2e, .g = 0x7d, .b = 0xc2 };
    const x_height: dvui.Color = .{ .r = 0x2a, .g = 0x9d, .b = 0x8f };
    const baseline: dvui.Color = .{ .r = 0xd1, .g = 0x4b, .b = 0x2a };
    const descender: dvui.Color = .{ .r = 0xb0, .g = 0x7a, .b = 0x2c };
    const box: dvui.Color = .{ .r = 0x88, .g = 0x88, .b = 0x88 };
};

/// One label's construction: for each element (a run in one face and size,
/// scripts included), its ascender, cap height, x-height, baseline and
/// descender across its advance; the label's ink box; and its anchor, the
/// label frame's origin, as a small cross. `at` is where the label frame's
/// panel sits on the worksheet.
fn drawConstruction(area: dvui.Rect.Physical, l: layout.place.PlacedLabel, at: geom.Point) void {
    const px = dvui.windowNaturalScale();
    const ox = at.x + l.origin.x;
    const oy = at.y + l.origin.y;
    for (l.render.elements) |e| {
        const face = state.faces[e.face orelse 0];
        const cap_units = (face.capHeight() catch null) orelse continue;
        const k = e.cap_height / cap_units;
        const ext = face.extents();
        const x0 = ox + e.origin.x;
        const x1 = x0 + e.advance;
        const base = oy + e.origin.y;
        const xh = face.xHeight() catch null;
        const lines = [_]struct { y: ?f64, color: dvui.Color }{
            .{ .y = base + ext.ascender * k, .color = construction.ascender },
            .{ .y = base + e.cap_height, .color = construction.cap },
            .{ .y = if (xh) |v| base + v * k else null, .color = construction.x_height },
            .{ .y = base, .color = construction.baseline },
            .{ .y = base + ext.descender * k, .color = construction.descender },
        };
        for (lines) |line| {
            const y = line.y orelse continue;
            const a = state.view.toPx(area, .{ .x = x0, .y = y });
            const b = state.view.toPx(area, .{ .x = x1, .y = y });
            dvui.Path.stroke(.{ .points = &.{ a, b } }, .{ .thickness = px, .color = .{ .color = line.color.opacity(0.8) } });
        }
    }
    if (!l.render.ink.isEmpty()) {
        const ink = l.render.ink;
        state.view.rect(area, .{ .x0 = ox + ink.x0, .y0 = oy + ink.y0, .x1 = ox + ink.x1, .y1 = oy + ink.y1 }).stroke(.square, .{ .thickness = px, .color = .{ .color = construction.box.opacity(0.7) } });
    }
    const c = state.view.toPx(area, .{ .x = ox, .y = oy });
    const r: f32 = 4 * px;
    const mark: dvui.ColorOrGradient = .{ .color = construction.baseline };
    dvui.Path.stroke(.{ .points = &.{ .{ .x = c.x - r, .y = c.y }, .{ .x = c.x + r, .y = c.y } } }, .{ .thickness = 1.5 * px, .color = mark });
    dvui.Path.stroke(.{ .points = &.{ .{ .x = c.x, .y = c.y - r }, .{ .x = c.x, .y = c.y + r } } }, .{ .thickness = 1.5 * px, .color = mark });
}

/// Ruler depth, logical pixels.
const ruler_size = 24;

/// One kind of ruler tick: every `step` mm, `len` of the ruler's depth
/// long, numbered or not.
const Tick = struct { step: f64, len: f32, label: bool };

/// The ticks for the worksheet's units at the current zoom. Metric: numbered
/// centimetres (thinned out to 2, 5, 10 cm … when crowded), then 5 mm and
/// 1 mm ticks where they fit. Imperial: numbered inches (thinned the same
/// way), then halves, quarters, eighths … to the finest that fits.
fn ticks(buf: []Tick) []Tick {
    const ns = dvui.windowNaturalScale();
    const ppm = state.view.ppm;
    const min_tick = 4 * ns;
    const min_label = 44 * ns;
    var n: usize = 0;
    switch (docUnits()) {
        .mil => {
            // Labels at round numbers of mils, ticks at a half and a tenth.
            const mil = 0.0254;
            var label: f64 = 10;
            for ([_]f64{ 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000 }) |st| {
                label = st;
                if (st * mil * ppm >= min_label) break;
            }
            buf[n] = .{ .step = label * mil, .len = 0.7, .label = true };
            n += 1;
            for ([_]Tick{ .{ .step = label * mil / 2, .len = 0.45, .label = false }, .{ .step = label * mil / 10, .len = 0.25, .label = false } }) |t| {
                if (t.step * ppm >= min_tick and n < buf.len) {
                    buf[n] = t;
                    n += 1;
                }
            }
        },
        .mm => {
            var label: f64 = 10;
            for ([_]f64{ 10, 20, 50, 100, 200, 500, 1000, 2000 }) |st| {
                label = st;
                if (st * ppm >= min_label) break;
            }
            buf[n] = .{ .step = label, .len = 0.7, .label = true };
            n += 1;
            for ([_]Tick{ .{ .step = 10, .len = 0.5, .label = false }, .{ .step = 5, .len = 0.35, .label = false }, .{ .step = 1, .len = 0.2, .label = false } }) |t| {
                if (t.step < label and t.step * ppm >= min_tick and n < buf.len) {
                    buf[n] = t;
                    n += 1;
                }
            }
        },
        .inch => {
            var label: f64 = 1;
            for ([_]f64{ 1, 2, 5, 10, 20, 50, 100 }) |st| {
                label = st;
                if (st * 25.4 * ppm >= min_label) break;
            }
            buf[n] = .{ .step = label * 25.4, .len = 0.7, .label = true };
            n += 1;
            if (label > 1 and 25.4 * ppm >= min_tick) {
                buf[n] = .{ .step = 25.4, .len = 0.5, .label = false };
                n += 1;
            }
            var k: u6 = 1;
            while (n < buf.len) : (k += 1) {
                const step = 25.4 / @as(f64, @floatFromInt(@as(u64, 1) << k));
                if (step * ppm < min_tick) break;
                buf[n] = .{ .step = step, .len = @max(0.14, 0.45 - 0.07 * @as(f32, @floatFromInt(k))), .label = false };
                n += 1;
            }
        },
    }
    return buf[0..n];
}

/// The rulers, fixed to the sheet's edges and spanning only the sheet: the
/// horizontal one on its top edge, the vertical one on the side the ruler
/// origin is on. When an edge scrolls out of view its ruler stays pinned
/// to the canvas edge. Numbers count from the ruler origin in the
/// worksheet's units; the pointer is marked on both.
fn drawRulers(area: dvui.Rect.Physical) void {
    const ns = dvui.windowNaturalScale();
    const rw: f32 = ruler_size * ns;
    const prev = dvui.clip(area);
    defer dvui.clipSet(prev);
    const sheet = state.model.sheet;
    const open = openCanvas();
    const right = !open and sheet.ruler_origin.fromRight();
    // A canvas has no edges: its rulers run along the canvas's own.
    const tl = if (open) dvui.Point.Physical{ .x = area.x + rw, .y = area.y + rw } else state.view.toPx(area, .{ .x = 0, .y = sheet.h });
    const br = if (open) dvui.Point.Physical{ .x = area.x + area.w, .y = area.y + area.h } else state.view.toPx(area, .{ .x = sheet.w, .y = 0 });

    const hy = std.math.clamp(tl.y - rw, area.y, area.y + area.h - rw);
    const hx0 = @max(tl.x, area.x);
    const hx1 = @min(br.x, area.x + area.w);
    const vx = std.math.clamp(if (right) br.x else tl.x - rw, area.x, area.x + area.w - rw);
    const vy0 = @max(tl.y, area.y);
    const vy1 = @min(br.y, area.y + area.h);
    const top: dvui.Rect.Physical = .{ .x = hx0, .y = hy, .w = @max(0, hx1 - hx0), .h = rw };
    const side: dvui.Rect.Physical = .{ .x = vx, .y = vy0, .w = rw, .h = @max(0, vy1 - vy0) };
    const corner: dvui.Rect.Physical = .{ .x = vx, .y = hy, .w = rw, .h = rw };

    for ([_]dvui.Rect.Physical{ top, side, corner }) |r| r.fill(.square, .{ .color = .{ .color = colors.ruler } });

    var buf: [12]Tick = undefined;
    const list = ticks(&buf);
    rulerAxis(top, area, list, true);
    rulerAxis(side, area, list, false);

    // Each ruler's edge against the sheet.
    const line: dvui.ColorOrGradient = .{ .color = colors.edge };
    for ([_]dvui.Rect.Physical{ top, side, corner }) |r| r.stroke(.square, .{ .thickness = ns, .color = line });

    if (state.mouse) |m| {
        const p = state.view.toPx(area, m);
        const mark: dvui.ColorOrGradient = .{ .color = colors.select };
        dvui.Path.stroke(.{ .points = &.{ .{ .x = p.x, .y = top.y }, .{ .x = p.x, .y = top.y + top.h } } }, .{ .thickness = ns, .color = mark });
        dvui.Path.stroke(.{ .points = &.{ .{ .x = side.x, .y = p.y }, .{ .x = side.x + side.w, .y = p.y } } }, .{ .thickness = ns, .color = mark });
    }
}

/// The panels of `space` (or, when null, of the shown space), with their
/// outlines and content, as the view maps them.
fn drawSpacePanels(area: dvui.Rect.Physical, space: ?usize, layer: ?layout.model.ObjectId) void {
    const px = dvui.windowNaturalScale();
    for (0..state.model.panels.items.len) |pi| {
        if (space) |sp| {
            if (state.model.panels.items[pi].space != sp) continue;
        } else if (!shownPanel(pi)) continue;
        if (layer) |l| if (panelLayer(pi) != l) continue;
        // A space's own panel has no outline: only its content.
        if (state.model.panels.items[pi].unbounded) {
            if (pi < state.placed.items.len) drawPanel(area, pi, &state.placed.items[pi]);
            continue;
        }
        const outline = state.view.rect(area, panelBox(pi));
        const is_context = switch (state.context) {
            .panel => |c| c == pi,
            else => false,
        };
        // While dragged, compliance is shown live for the preview position.
        const off = if (state.moving != null and state.moving.?.panel == pi) !state.model.compliantAt(pi, panelOrigin(pi)) else panelIssue(pi) != null;
        // A panel past the sheet's edge is outlined in the warning colour.
        const edge = if (is_context) colors.select else if (off) colors.overflow else colors.panel_edge;
        const thickness = if (is_context or off) 2 * px else px;
        // A panel made from a closed path is drawn as that path; its
        // margins (still a band inside its box) are not shown.
        const shaped = pi < state.placed.items.len and state.model.panels.items[pi].edge != null and state.placed.items[pi].edge != null;
        if (shaped) {
            strokeOutline(area, state.placed.items[pi].edge.?, panelOrigin(pi), thickness, edge);
        } else {
            drawPanelMargins(area, pi);
            // The selected panel's outline marches; others are content edges.
            if (is_context and !off) marchingBox(area, panelBox(pi), edge, thickness) else outline.stroke(.square, .{ .thickness = thickness, .color = .{ .color = edge } });
        }
        if (pi < state.placed.items.len) drawPanel(area, pi, &state.placed.items[pi]);
    }
}

// Layers and images ---------------------------------------------------------
//
// Each space draws its layers bottom first: a hidden layer is skipped; the
// rest are drawn at their opacity, images with their blend mode (vector
// content of a blended layer is drawn normally for now). Locked and hidden
// layers' objects cannot be picked. New panels and images go on the active
// layer: the last one chosen in the space, else its base layer.

/// The layer last chosen; new objects in its space go on it.
var active_layer: layout.model.ObjectId = .none;

/// The layer a panel is on, resolved (a space's own panel is on its base
/// layer).
fn panelLayer(pi: usize) layout.model.ObjectId {
    const p = state.model.panels.items[pi];
    if (state.model.spaces.items.len == 0) return .none;
    const sp = state.model.spaces.items[p.space];
    return if (p.unbounded or p.layer == .none) sp.base_layer else p.layer;
}

/// Whether what is on layer `id` of space `space` can be picked: the layer
/// is shown and not locked.
fn layerOpen(space: usize, id: layout.model.ObjectId) bool {
    if (space >= state.model.spaces.items.len) return true;
    const sp = state.model.spaces.items[space];
    const li = sp.layerIndex(id) orelse return true;
    const l = sp.layers.items[li];
    return l.visible and !l.locked;
}

/// The layer new objects in the shown space go on.
fn newObjectLayer() layout.model.ObjectId {
    if (shown_space >= state.model.spaces.items.len) return .none;
    const sp = state.model.spaces.items[shown_space];
    return if (sp.layerIndex(active_layer) != null and active_layer != .none) active_layer else sp.base_layer;
}

fn imageAt(space: usize, index: usize) ?layout.model.Image {
    if (space >= state.model.spaces.items.len) return null;
    const list = state.model.spaces.items[space].images.items;
    return if (index < list.len) list[index] else null;
}

/// Space `space`'s layers, bottom first, each at its opacity: its images,
/// views and panels on that layer.
fn drawSpace(area: dvui.Rect.Physical, space: usize, depth: usize) void {
    if (space >= state.model.spaces.items.len) return;
    for (state.model.spaces.items[space].layers.items) |l| {
        if (!l.visible) continue;
        const prev = dvui.alpha(@floatCast(l.opacity));
        defer dvui.alphaSet(prev);
        drawImages(area, space, l.id, l.blend);
        drawViews(area, space, depth, l.id);
        drawSpacePanels(area, space, l.id);
    }
}

/// The SDL blend mode for a layer's blend, on premultiplied colour.
fn sdlBlend(b: layout.model.Blend) dvui.backend.c.SDL_BlendMode {
    const c = dvui.backend.c;
    return switch (b) {
        .normal => c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD),
        // src·dst + dst·(1 − src alpha)
        .multiply => c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_DST_COLOR, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD),
        // src + dst·(1 − src)
        .screen => c.SDL_ComposeCustomBlendMode(c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_COLOR, c.SDL_BLENDOPERATION_ADD, c.SDL_BLENDFACTOR_ONE, c.SDL_BLENDFACTOR_ONE_MINUS_SRC_ALPHA, c.SDL_BLENDOPERATION_ADD),
    };
}

/// The images of space `space` on layer `layer`, at their physical size,
/// blended as the layer says.
fn drawImages(area: dvui.Rect.Physical, space: usize, layer: layout.model.ObjectId, blend: layout.model.Blend) void {
    const sp = state.model.spaces.items[space];
    const px = dvui.windowNaturalScale();
    for (sp.images.items, 0..) |im, ii| {
        if ((if (im.layer == .none) sp.base_layer else im.layer) != layer) continue;
        const r = state.view.rect(area, im.box());
        const src: dvui.ImageSource = .{ .imageFile = .{ .bytes = im.data, .name = im.name } };
        const tex = src.getTexture() catch {
            r.stroke(.square, .{ .thickness = px, .color = .{ .color = colors.overflow } });
            continue;
        };
        _ = dvui.backend.c.SDL_SetTextureBlendMode(@ptrCast(@alignCast(tex.ptr)), sdlBlend(blend));
        // The layer's opacity in the image's own colour: drawing may be
        // replayed after the current alpha is back to 1.
        const a = dvui.currentWindow().alpha;
        dvui.alphaSet(1);
        dvui.renderTexture(tex, .{ .r = r, .s = px }, .{ .colormod = (dvui.Color{ .r = 255, .g = 255, .b = 255 }).opacity(a) }) catch {};
        dvui.alphaSet(a);
        const sel = switch (state.context) {
            .image => |c| c.space == space and c.index == ii,
            else => false,
        };
        if (sel) marchingBox(area, im.box(), colors.select, 2 * px);
    }
}

/// The top-most image of the shown space under `at` on an open layer.
fn imageUnder(at: geom.Point) ?Context {
    if (shown_space >= state.model.spaces.items.len) return null;
    const sp = state.model.spaces.items[shown_space];
    var hit: ?Context = null;
    var hit_layer: usize = 0;
    for (sp.images.items, 0..) |im, ii| {
        if (!contains(im.box(), at) or !layerOpen(shown_space, im.layer)) continue;
        const li = sp.layerIndex(im.layer) orelse 0;
        if (hit == null or li >= hit_layer) {
            hit = .{ .image = .{ .space = shown_space, .index = ii } };
            hit_layer = li;
        }
    }
    return hit;
}

/// The layer flags of layer `li` of space `space`, as text lines.
fn layerFlags(space: usize, li: usize, n: usize) void {
    for (state.layer_issues) |iss| {
        if (iss.space != space or iss.layer != li) continue;
        const sp = state.model.spaces.items[space];
        const l = sp.layers.items[li];
        var buf: [160]u8 = undefined;
        const text = switch (iss.kind) {
            .blend_ignored => std.fmt.bufPrint(&buf, "Opacity and blending mean nothing to {s}: what is made ignores them.", .{@tagName(l.output)}) catch "",
            .low_resolution => std.fmt.bufPrint(&buf, "{s} prints at {d:.0} dpi, under {d:.0}.", .{ sp.images.items[iss.image.?].name, sp.images.items[iss.image.?].dpi(), layout.model.min_print_dpi }) catch "",
        };
        // Wrapped: a flag is read in full.
        var tl = dvui.textLayout(@src(), .{}, .{ .id_extra = n + 100 * @as(usize, @intFromEnum(iss.kind)) + (iss.image orelse 0), .expand = .horizontal, .background = false, .margin = .{ .y = 4 } });
        tl.addText(text, .{ .color_text = .{ .color = colors.overflow } });
        tl.deinit();
    }
}

/// A space's layers, top first, for its properties: each one shown or
/// hidden, locked or not, and opened by its name; then Add layer.
fn layersList(space: usize) void {
    heading("{s}", .{"Layers"}, 700);
    const sp = state.model.spaces.items[space];
    const n = sp.layers.items.len;
    for (0..n) |k| {
        const li = n - 1 - k;
        const l = sp.layers.items[li];
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = li });
        defer row.deinit();
        var vis = l.visible;
        if (dvui.checkbox(@src(), &vis, null, .{ .id_extra = li })) {
            var nl = l;
            nl.visible = vis;
            act(.setLayer, .{space, li, nl}) catch {};
        }
        var flagged = false;
        for (state.layer_issues) |iss| {
            if (iss.space == space and iss.layer == li) flagged = true;
        }
        var buf: [96]u8 = undefined;
        const active = l.id == newObjectLayer();
        const text = std.fmt.bufPrint(&buf, "{s}{s}{s}{s}", .{ l.name, if (l.locked) " (locked)" else "", if (active) " · new objects" else "", if (flagged) " · flagged" else "" }) catch l.name;
        if (dvui.button(@src(), text, .{}, .{ .id_extra = li, .expand = .horizontal, .color_text = if (flagged) .{ .color = colors.overflow } else null })) {
            state.context = .{ .layer = .{ .space = space, .index = li } };
            active_layer = l.id;
        }
    }
    if (dvui.button(@src(), "Add layer", .{}, .{ .expand = .horizontal, .margin = .{ .y = 4 } })) {
        var buf: [32]u8 = undefined;
        const li = act(.addLayer, .{space, state.model.nextLayerName(space, &buf)}) catch return;
        state.context = .{ .layer = .{ .space = space, .index = li } };
        active_layer = state.model.spaces.items[space].layers.items[li].id;
    }
}

/// A layer's properties: shown, locked, opacity, blend, output, its place
/// in the stack, and its flags.
fn layerProperties(space: usize, li: usize) !void {
    const sp = state.model.spaces.items[space];
    if (li >= sp.layers.items.len) return;
    var l = sp.layers.items[li];
    var changed = false;
    propText("Name", "{s}", .{l.name}, 1);
    propText("Place", "{d} of {d}, from the bottom", .{ li + 1, sp.layers.items.len }, 2);
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 3 });
        defer row.deinit();
        propName("Shown");
        if (dvui.checkbox(@src(), &l.visible, "Visible", .{ .id_extra = 3 })) changed = true;
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 4 });
        defer row.deinit();
        propName("Lock");
        if (dvui.checkbox(@src(), &l.locked, "Locked: nothing on it can be picked", .{ .id_extra = 4 })) changed = true;
    }
    var buf: [32]u8 = undefined;
    if (sizesProp("Opacity, %", std.fmt.bufPrint(&buf, "{d}", .{@round(l.opacity * 100)}) catch "", 5)) |list| if (list.len == 1) {
        l.opacity = std.math.clamp(list[0] / 100, 0, 1);
        changed = true;
    };
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 6 });
        defer row.deinit();
        propName("Blend");
        const names = [_][]const u8{ "Normal", "Multiply", "Screen" };
        var choice: usize = @intFromEnum(l.blend);
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .id_extra = 6 })) {
            l.blend = @enumFromInt(choice);
            changed = true;
        }
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 7 });
        defer row.deinit();
        propName("Output");
        const names = [_][]const u8{ "None (guide)", "Print", "Engrave", "Cut", "Mill" };
        var choice: usize = @intFromEnum(l.output);
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .id_extra = 7 })) {
            l.output = @enumFromInt(choice);
            changed = true;
        }
    }
    if (changed) try act(.setLayer, .{space, li, l});
    propText("New objects", "{s}", .{if (l.id == newObjectLayer()) "go on this layer" else "go elsewhere"}, 8);
    layerFlags(space, li, 9);
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 8 } });
        defer row.deinit();
        if (dvui.button(@src(), "Move up", .{}, .{})) state.context = .{ .layer = .{ .space = space, .index = act(.moveLayer, .{space, li, true}) catch li } };
        if (dvui.button(@src(), "Move down", .{}, .{})) state.context = .{ .layer = .{ .space = space, .index = act(.moveLayer, .{space, li, false}) catch li } };
        if (dvui.button(@src(), "Remove", .{}, .{})) {
            act(.removeLayer, .{space, li}) catch {
                state.status = "Only an empty layer, other than the space's first, can be removed. ";
                return;
            };
            state.context = .{ .panel = sp.root };
        }
    }
}

/// A dropdown of space `space`'s layers; returns the chosen layer when it
/// changes.
fn layerChoice(space: usize, current: layout.model.ObjectId, n: usize) ?layout.model.ObjectId {
    const sp = state.model.spaces.items[space];
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n });
    defer row.deinit();
    propName("Layer");
    var names_buf: [16][]const u8 = undefined;
    const n_layers = @min(sp.layers.items.len, names_buf.len);
    for (0..n_layers) |i| names_buf[i] = sp.layers.items[i].name;
    var choice: usize = sp.layerIndex(current) orelse 0;
    if (dvui.dropdown(@src(), names_buf[0..n_layers], .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .id_extra = n })) return sp.layers.items[choice].id;
    return null;
}

/// An image's properties: its layer, place, physical size, pixels and
/// effective resolution.
fn imageProperties(space: usize, index: usize) !void {
    const im = imageAt(space, index) orelse return;
    propText("Name", "{s}", .{im.name}, 1);
    if (layerChoice(space, im.layer, 2)) |l| try act(.setImage, .{space, index, im.at, im.w, l});
    propText("Place", "({d:.1}, {d:.1}) mm", .{ im.at.x, im.at.y }, 3);
    var buf: [32]u8 = undefined;
    if (sizesProp("Width, mm", std.fmt.bufPrint(&buf, "{d:.2}", .{im.w}) catch "", 4)) |list| if (list.len == 1) {
        act(.setImage, .{space, index, im.at, list[0], im.layer}) catch {
            state.status = "A width must be more than 0. ";
        };
    };
    propText("Height", "{d:.2} mm (keeps its proportions)", .{im.h}, 5);
    propText("Pixels", "{d} × {d}", .{ im.px_w, im.px_h }, 6);
    propText("Resolution", "{d:.0} dpi at this size", .{im.dpi()}, 7);
    propText("Moves", "{s}", .{"arrow keys, 1 mm"}, 8);
    if (state.model.spaces.items[space].layerIndex(im.layer)) |li| layerFlags(space, li, 9);
    if (dvui.button(@src(), "Remove image", .{}, .{ .expand = .horizontal, .margin = .{ .y = 8 } })) {
        actV(.removeImage, .{space, index});
        state.context = .{ .panel = state.model.spaces.items[space].root };
    }
}

/// Moves the selected image 1 mm the way an arrow points.
fn moveImageKey(code: dvui.enums.Key) bool {
    const c = switch (state.context) {
        .image => |c| c,
        else => return false,
    };
    const im = imageAt(c.space, c.index) orelse return false;
    const d: geom.Point = switch (code) {
        .up => .{ .x = 0, .y = 1 },
        .down => .{ .x = 0, .y = -1 },
        .left => .{ .x = -1, .y = 0 },
        .right => .{ .x = 1, .y = 0 },
        else => return false,
    };
    actM(mergeKey(.{ "moveImageKey", state.context }), .setImage, .{c.space, c.index, .{ .x = im.at.x + d.x, .y = im.at.y + d.y }, im.w, im.layer}) catch return false;
    return true;
}

/// File › Place image is asking for the file.
var image_prompt = false;
/// The prompt has just opened: its file field takes the keyboard.
var image_prompt_new = false;

/// The Place image prompt: a PNG or JPEG file, placed in the shown space
/// at 150 dpi on the active layer.
fn imagePrompt() void {
    const c = canvas_rect;
    if (c.w <= 0 or c.h <= 0) return;
    const w: f32 = 460;
    const h: f32 = 185;
    var r: dvui.Rect = .{ .x = c.x + (c.w - w) / 2, .y = c.y + (c.h - h) / 2, .w = w, .h = h };
    var fw = dvui.floatingWindow(@src(), .{ .rect = &r, .resize = .none }, overlayOptions(11));
    defer fw.deinit();
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .padding = .all(12) });
    defer body.deinit();
    dvui.labelNoFmt(@src(), "Place image (PNG or JPEG)", .{}, .{ .font = dvui.Font.theme(.heading) });
    var go = false;
    var cancel = false;
    for (dvui.events()) |*e| {
        if (e.evt != .key or e.handled) continue;
        const k = e.evt.key;
        if (k.action != .down) continue;
        if (k.code == .enter or k.code == .kp_enter) go = true else if (k.code == .escape) cancel = true else continue;
        e.handle(@src(), fw.data());
    }
    var path: []const u8 = "";
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .margin = .{ .y = 8 } });
        defer row.deinit();
        propName("File");
        var te = dvui.textEntry(@src(), .{}, .{ .expand = .horizontal });
        defer te.deinit();
        if (image_prompt_new) {
            // The prompt's window takes the keys, so Enter and Esc reach it.
            dvui.focusSubwindow(fw.data().id, null);
            dvui.focusWidget(te.data().id, fw.data().id, null);
            image_prompt_new = false;
        }
        if (te.enter_pressed) go = true;
        path = dvui.currentWindow().arena().dupe(u8, std.mem.trim(u8, te.textGet(), " ")) catch "";
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 1, .margin = .{ .y = 8 } });
        defer row.deinit();
        if (dvui.button(@src(), "Cancel", .{}, .{})) cancel = true;
        if (dvui.button(@src(), "Place", .{}, .{})) go = true;
    }
    if (cancel) {
        image_prompt = false;
        dvui.refresh(null, @src(), null);
        return;
    }
    if (!go or path.len == 0) return;
    image_prompt = false;
    placeImage(path);
}

/// Reads image file `path` and places it in the shown space.
fn placeImage(path: []const u8) void {
    const bytes = std.Io.Dir.cwd().readFileAlloc(dvui.io, path, state.gpa, .limited(256 << 20)) catch {
        state.status = "That file could not be read. ";
        return;
    };
    defer state.gpa.free(bytes);
    var pw: c_int = 0;
    var ph: c_int = 0;
    var channels: c_int = 0;
    if (dvui.c.stbi_info_from_memory(bytes.ptr, @intCast(bytes.len), &pw, &ph, &channels) == 0 or pw <= 0 or ph <= 0) {
        state.status = "That is not a PNG or JPEG image. ";
        return;
    }
    // At 150 dpi, centred in the view.
    const w = @as(f64, @floatFromInt(pw)) / 150.0 * 25.4;
    const hgt = w * @as(f64, @floatFromInt(ph)) / @as(f64, @floatFromInt(pw));
    const at: geom.Point = .{ .x = state.view.cx - w / 2, .y = state.view.cy - hgt / 2 };
    const ii = act(.addImage, .{shown_space, std.fs.path.basename(path), bytes, @intCast(pw), @intCast(ph), at, w, newObjectLayer()}) catch {
        state.status = "The image could not be placed. ";
        return;
    };
    state.context = .{ .image = .{ .space = shown_space, .index = ii } };
    state.status = "Placed at 150 dpi: set its width in its properties. ";
}

// Views ---------------------------------------------------------------------
//
// A view is a live, read-only window onto another space, placed at a scale:
// the source's panels are drawn through it from the same solve, so an edit
// to the source shows in every view at once. Nothing in it is picked; the
// view itself is, by its box.

/// Views nest at most this deep (cycles are refused; this only bounds the
/// drawing).
const view_depth = 6;

fn viewAt(space: usize, index: usize) ?layout.model.SpaceView {
    if (space >= state.model.spaces.items.len) return null;
    const list = state.model.spaces.items[space].views.items;
    return if (index < list.len) list[index] else null;
}

/// What a view shows, in its source's coordinates: its window, else the
/// source frame's boundary, else all the source holds.
fn viewWindow(sv: layout.model.SpaceView) geom.Box {
    if (sv.window) |w| return w;
    if (sv.source < state.model.spaces.items.len) if (state.model.spaces.items[sv.source].bound) |b| return b;
    return extentsOf(sv.source, 1);
}

/// Where a view lies in its host, mm.
fn viewBox(sv: layout.model.SpaceView) geom.Box {
    const w = viewWindow(sv);
    if (w.isEmpty()) return .{ .x0 = sv.at.x, .y0 = sv.at.y, .x1 = sv.at.x + 20, .y1 = sv.at.y + 10 };
    const c: geom.Point = .{ .x = w.x0, .y = w.y0 };
    const lo = sv.toHost(c, c);
    const hi = sv.toHost(c, .{ .x = w.x1, .y = w.y1 });
    return .{ .x0 = lo.x, .y0 = lo.y, .x1 = hi.x, .y1 = hi.y };
}

/// A view's box with room above it for its name, for fitting.
fn withNameRoom(b: geom.Box) geom.Box {
    var r = b;
    r.y1 += 0.08 * b.height();
    return r;
}

/// What space `space` holds, in its coordinates: its panels' outlines and
/// solved content, and its views.
fn extentsOf(space: usize, depth: usize) geom.Box {
    var b: geom.Box = .empty;
    for (state.model.panels.items, 0..) |p, pi| {
        if (state.model.spaces.items.len > 0 and p.space != space) continue;
        if (pi < state.placed.items.len and !state.placed.items[pi].bounds.isEmpty()) b = b.join(onSheet(pi, state.placed.items[pi].bounds));
        if (!p.unbounded) b = b.join(p.box());
    }
    if (space < state.model.spaces.items.len) for (state.model.spaces.items[space].images.items) |im| {
        b = b.join(im.box());
    };
    if (depth < view_depth and space < state.model.spaces.items.len) for (state.model.spaces.items[space].views.items) |sv| {
        if (sv.window == null and state.model.spaces.items[sv.source].bound == null and extentsOf(sv.source, depth + 1).isEmpty()) continue;
        b = b.join(withNameRoom(viewBox(sv)));
    };
    return b;
}

/// The views placed in space `host`: each its source drawn through the
/// view's scale, clipped to the view's box, on a faint ground; the selected
/// one outlined. Views in the source are drawn inside, as deep as
/// `view_depth`.
fn drawViews(area: dvui.Rect.Physical, host: usize, depth: usize, layer: layout.model.ObjectId) void {
    if (depth >= view_depth or host >= state.model.spaces.items.len) return;
    const px = dvui.windowNaturalScale();
    const base = state.model.spaces.items[host].base_layer;
    for (state.model.spaces.items[host].views.items, 0..) |sv, vi| {
        if ((if (sv.layer == .none) base else sv.layer) != layer) continue;
        const hb = viewBox(sv);
        const r = state.view.rect(area, hb);
        r.fill(.square, .{ .color = .{ .color = colors.paper.opacity(0.7) } });
        const w = viewWindow(sv);
        if (!w.isEmpty()) {
            const prev = state.view;
            const prev_clip = dvui.clip(r);
            state.view.ppm = prev.ppm * sv.scale;
            state.view.cx = w.x0 + (prev.cx - sv.at.x) / sv.scale;
            state.view.cy = w.y0 + (prev.cy - sv.at.y) / sv.scale;
            drawSpace(area, sv.source, depth + 1);
            state.view = prev;
            dvui.clipSet(prev_clip);
        }
        const sel = depth == 0 and switch (state.context) {
            .view => |v| v.space == host and v.index == vi,
            else => false,
        };
        if (sel) {
            marchingBox(area, hb, colors.select, 2 * px);
        } else {
            dashedBox(area, hb, colors.guide.opacity(0.8), px);
        }
        if (depth > 0) continue;
        // Its name above its corner, with the scale.
        var buf: [128]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "{s} · {s}", .{ sv.name, scaleText(sv.scale) }) catch sv.name;
        const corner = state.view.toPx(area, .{ .x = hb.x0, .y = hb.y1 });
        const font = dvui.Font.theme(.body).larger(-2);
        dvui.labelNoFmt(@src(), text, .{}, .{
            .id_extra = vi,
            .rect = annotationRect(area, corner, font, 320),
            .padding = .{ .x = 0, .w = 0, .y = annotation_pad, .h = annotation_pad },
            .color_text = .{ .color = if (sel) colors.select else colors.guide },
            .font = font,
        });
    }
}

/// A one-line annotation's rectangle just above canvas point `corner`
/// (physical pixels), in the canvas's own logical coordinates: as tall as
/// the font's line with its padding, so no part of the text is clipped.
fn annotationRect(area: dvui.Rect.Physical, corner: dvui.Point.Physical, font: dvui.Font, w: f32) dvui.Rect {
    const ns = dvui.windowNaturalScale();
    const h = font.lineHeight() + 2 * annotation_pad;
    return .{ .x = (corner.x - area.x) / ns, .y = (corner.y - area.y) / ns - h - 2, .w = w, .h = h };
}

const annotation_pad = 2;

/// A scale as a ratio: 1:1, 1:2 (smaller), 2:1 (larger).
fn scaleText(scale: f64) []const u8 {
    const buf = dvui.currentWindow().arena().alloc(u8, 32) catch return "";
    if (scale >= 1) return std.fmt.bufPrint(buf, "{d}:1", .{@round(scale * 100) / 100}) catch "";
    return std.fmt.bufPrint(buf, "1:{d}", .{@round(100 / scale) / 100}) catch "";
}

/// The top-most view of the shown space under `at`, if any.
fn viewUnder(at: geom.Point) ?Context {
    if (shown_space >= state.model.spaces.items.len) return null;
    var hit: ?Context = null;
    for (state.model.spaces.items[shown_space].views.items, 0..) |sv, vi| {
        if (contains(viewBox(sv), at) and layerOpen(shown_space, sv.layer)) hit = .{ .view = .{ .space = shown_space, .index = vi } };
    }
    return hit;
}

/// A view's properties: what it shows and at what scale, where it lies,
/// and the way to its source.
fn viewProperties(host: usize, index: usize) !void {
    const sv = viewAt(host, index) orelse return;
    propText("Name", "{s}", .{sv.name}, 1);
    const src = state.model.spaces.items[sv.source];
    propText("Shows", "{s}", .{if (sv.source == 0) "the canvas" else src.name}, 2);
    const hb = viewBox(sv);
    propText("Place", "({d:.1}, {d:.1}) mm", .{ hb.x0, hb.y0 }, 3);
    propText("Size", "{d:.1} × {d:.1} mm", .{ hb.width(), hb.height() }, 4);
    var buf: [32]u8 = undefined;
    if (sizesProp("Scale", std.fmt.bufPrint(&buf, "{d}", .{sv.scale}) catch "", 5)) |list| if (list.len == 1) {
        act(.setViewScale, .{host, index, list[0]}) catch {
            state.status = "A scale must be more than 0. ";
        };
    };
    propText("Reads as", "{s}", .{scaleText(sv.scale)}, 6);
    propText("Moves", "{s}", .{"arrow keys, 1 mm"}, 7);
    propText("Edits", "{s}", .{"in its source: it shows them at once"}, 8);
    if (dvui.button(@src(), "Show its source", .{}, .{ .expand = .horizontal, .margin = .{ .y = 8 } })) {
        shown_space = sv.source;
        state.context = .{ .panel = src.root };
        state.view.fit = contentExtents();
    }
    if (dvui.button(@src(), "Remove view", .{}, .{ .expand = .horizontal })) {
        actV(.removeView, .{host, index});
        state.context = .{ .panel = state.model.spaces.items[host].root };
    }
}

/// Buttons placing a view of space `space` in each other space it may
/// show in (one that would show itself is left out).
fn placeViewButtons(space: usize) void {
    var any = false;
    for (state.model.spaces.items, 0..) |sp, host| {
        if (state.model.viewWouldCycle(host, space)) continue;
        if (!any) {
            dvui.labelNoFmt(@src(), "Views of it", .{}, .{ .font = dvui.Font.theme(.heading), .margin = .{ .y = 8 } });
            any = true;
        }
        var buf: [96]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, "Place a view in {s}", .{if (host == 0) "the canvas" else sp.name}) catch "Place a view";
        if (dvui.button(@src(), text, .{}, .{ .expand = .horizontal, .id_extra = host })) placeView(space, host);
    }
}

/// Places a view of `source` in `host` at 1:1, just right of what the host
/// holds, and shows it there.
fn placeView(source: usize, host: usize) void {
    const e = extentsOf(host, 0);
    const at: geom.Point = if (e.isEmpty()) .{ .x = 0, .y = 0 } else .{ .x = e.x1 + 20, .y = e.y0 };
    const vi = act(.addView, .{host, source, at, 1}) catch {
        state.status = "That view would show itself. ";
        return;
    };
    shown_space = host;
    state.context = .{ .view = .{ .space = host, .index = vi } };
    state.view.fit = contentExtents();
    state.status = "Placed a view: edits to its source show in it at once. ";
}

/// Moves the selected view 1 mm the way an arrow points.
fn moveViewKey(code: dvui.enums.Key) bool {
    const v = switch (state.context) {
        .view => |v| v,
        else => return false,
    };
    const sv = viewAt(v.space, v.index) orelse return false;
    const d: geom.Point = switch (code) {
        .up => .{ .x = 0, .y = 1 },
        .down => .{ .x = 0, .y = -1 },
        .left => .{ .x = -1, .y = 0 },
        .right => .{ .x = 1, .y = 0 },
        else => return false,
    };
    actM(mergeKey(.{ "moveViewKey", state.context }), .moveView, .{v.space, v.index, .{ .x = sv.at.x + d.x, .y = sv.at.y + d.y }}) catch return false;
    return true;
}

/// The shown frame's boundary, with its name above it: in the warning colour
/// when content reaches past it.
fn drawFrameBound(area: dvui.Rect.Physical) void {
    if (shown_space == 0 or shown_space >= state.model.spaces.items.len) return;
    const sp = state.model.spaces.items[shown_space];
    const b = sp.bound orelse return;
    const px = dvui.windowNaturalScale();
    const past = !layout.model.within(spaceExtents(), b);
    const colour = if (past) colors.overflow else colors.guide;
    state.view.rect(area, b).stroke(.square, .{ .thickness = 1.5 * px, .color = .{ .color = colour } });
    const corner = state.view.toPx(area, .{ .x = b.x0, .y = b.y1 });
    const font = dvui.Font.theme(.body).larger(-1);
    dvui.labelNoFmt(@src(), sp.name, .{}, .{
        .rect = annotationRect(area, corner, font, 240),
        .padding = .{ .x = 0, .w = 0, .y = annotation_pad, .h = annotation_pad },
        .color_text = .{ .color = colour },
        .font = font,
    });
}

/// What the shown space holds, in its coordinates: its panels' outlines
/// and every solved bound of its panels.
fn spaceExtents() geom.Box {
    return extentsOf(shown_space, 0);
}

/// The canvas's axes through its origin, faint, with a mark at the origin.
fn drawAxes(area: dvui.Rect.Physical) void {
    const px = dvui.windowNaturalScale();
    const o = state.view.toPx(area, .{ .x = 0, .y = 0 });
    const axis: dvui.ColorOrGradient = .{ .color = colors.guide.opacity(0.3) };
    if (o.y >= area.y and o.y <= area.y + area.h) dvui.Path.stroke(.{ .points = &.{ .{ .x = area.x, .y = o.y }, .{ .x = area.x + area.w, .y = o.y } } }, .{ .thickness = px, .color = axis });
    if (o.x >= area.x and o.x <= area.x + area.w) dvui.Path.stroke(.{ .points = &.{ .{ .x = o.x, .y = area.y }, .{ .x = o.x, .y = area.y + area.h } } }, .{ .thickness = px, .color = axis });
    const r: f32 = 4 * px;
    const mark: dvui.ColorOrGradient = .{ .color = colors.guide.opacity(0.7) };
    dvui.Path.stroke(.{ .points = &.{ .{ .x = o.x - r, .y = o.y }, .{ .x = o.x + r, .y = o.y } } }, .{ .thickness = 1.5 * px, .color = mark });
    dvui.Path.stroke(.{ .points = &.{ .{ .x = o.x, .y = o.y - r }, .{ .x = o.x, .y = o.y + r } } }, .{ .thickness = 1.5 * px, .color = mark });
}

/// One ruler's ticks and numbers, counted from the ruler origin. Ticks grow
/// from the ruler's edge against the sheet.
fn rulerAxis(r: dvui.Rect.Physical, area: dvui.Rect.Physical, list: []const Tick, horizontal: bool) void {
    if (r.w <= 0 or r.h <= 0) return;
    const ns = dvui.windowNaturalScale();
    const sheet = state.model.sheet;
    const open = openCanvas();
    const from_far = !open and (if (horizontal) sheet.ruler_origin.fromRight() else sheet.ruler_origin.fromTop());
    const length = if (horizontal) sheet.w else sheet.h;
    // The ruler's ends in the worksheet frame, then as the ruler counts.
    const e0 = if (horizontal) state.view.toMm(area, .{ .x = r.x, .y = 0 }).x else state.view.toMm(area, .{ .x = 0, .y = r.y + r.h }).y;
    const e1 = if (horizontal) state.view.toMm(area, .{ .x = r.x + r.w, .y = 0 }).x else state.view.toMm(area, .{ .x = 0, .y = r.y }).y;
    const c0 = if (from_far) length - e0 else e0;
    const c1 = if (from_far) length - e1 else e1;
    // A millimetre of slack each way, so pixel rounding at a sheet edge
    // does not drop the 0 or end tick; still clamped to the sheet.
    const lo = if (open) @min(c0, c1) - 1 else @max(0, @min(c0, c1) - 1);
    const hi = if (open) @max(c0, c1) + 1 else @min(length, @max(c0, c1) + 1);
    if (lo > hi) return;

    // Ticks grow from the edge against the sheet: the horizontal ruler's
    // bottom; the vertical ruler's right side on the left, left side on
    // the right.
    const right_side = !horizontal and !open and sheet.ruler_origin.fromRight();
    const ink: dvui.ColorOrGradient = .{ .color = colors.ruler_ink };
    const font = dvui.Font.theme(.body).withSize(7);
    const depth = if (horizontal) r.h else r.w;
    for (list) |t| {
        var i: f64 = @ceil(lo / t.step - 1e-9);
        while (i * t.step <= hi + 1e-9) : (i += 1) {
            const v = i * t.step;
            const along = if (from_far) length - v else v;
            const p = state.view.toPx(area, if (horizontal) .{ .x = along, .y = 0 } else .{ .x = 0, .y = along });
            const len = depth * t.len;
            const pts: [2]dvui.Point.Physical = if (horizontal)
                .{ .{ .x = p.x, .y = r.y + r.h }, .{ .x = p.x, .y = r.y + r.h - len } }
            else if (right_side)
                .{ .{ .x = r.x, .y = p.y }, .{ .x = r.x + len, .y = p.y } }
            else
                .{ .{ .x = r.x + r.w, .y = p.y }, .{ .x = r.x + r.w - len, .y = p.y } };
            dvui.Path.stroke(.{ .points = &pts }, .{ .thickness = ns, .color = ink });
            if (!t.label) continue;

            var text_buf: [16]u8 = undefined;
            // @round(-0.0) prints as "-0".
            const rounded = @round(v * docUnits().perMm());
            const text = std.fmt.bufPrint(&text_buf, "{d}", .{if (rounded == 0) 0 else rounded}) catch continue;
            const size = font.textSize(text);
            const tw: f32 = size.w * ns;
            const th: f32 = size.h * ns;
            // Bounds for culling: the canvas, since rotated text is culled by
            // its unrotated extent.
            const rs: dvui.RectScale = .{ .r = area, .s = ns };
            if (horizontal) {
                // Numbers sit on the side of the tick they count toward.
                const x = if (from_far) p.x - 2 * ns - tw else p.x + 2 * ns;
                dvui.renderText(.{ .font = font, .text = text, .rs = rs, .p = .{ .x = x, .y = r.y + ns }, .color = colors.ruler_ink }) catch {};
            } else {
                // Rotated to read bottom to top; on the far side from the sheet.
                const x = if (right_side) r.x + r.w - th - ns else r.x + ns;
                const y = if (from_far) p.y + 2 * ns + tw else p.y - 2 * ns;
                dvui.renderText(.{ .font = font, .text = text, .rs = rs, .p = .{ .x = x, .y = y }, .color = colors.ruler_ink, .rotation = -std.math.pi / 2.0 }) catch {};
            }
        }
    }
}

/// Snaps a worksheet point to the 1 mm grid the add panel tool uses. A
/// panel starts on the sheet but may be drawn past its edge, flagged.
fn snap(p: geom.Point) geom.Point {
    return .{ .x = @round(p.x), .y = @round(p.y) };
}

fn dragBox(a: geom.Point, b: geom.Point) geom.Box {
    return .{ .x0 = @min(a.x, b.x), .y0 = @min(a.y, b.y), .x1 = @max(a.x, b.x), .y1 = @max(a.y, b.y) };
}

fn canvasEvents(box: *dvui.BoxWidget, area: dvui.Rect.Physical) void {
    // A tool waiting for the canvas: Add panel (a drag) or Add label (a click).
    const drawing = state.tool != .select;
    canvas_id = box.data().id;
    validateCursor();
    for (dvui.events()) |*e| {
        // While a new canvas's units are asked for, the canvas takes no
        // input but Enter, which makes it (unless an open or save prompt
        // is on top, which takes the Enter).
        if (canvas_prompt) {
            if (!filePromptOpen() and e.evt == .key and e.evt.key.action == .down and (e.evt.key.code == .enter or e.evt.key.code == .kp_enter)) {
                e.handle(@src(), box.data());
                createCanvas(last_units);
                dvui.refresh(null, @src(), box.data().id);
            }
            continue;
        }
        // A selected track's arrow keys move it, while the canvas or the
        // palette has the keyboard.
        if (e.evt == .key and track_cursor == null and state.context == .row and !e.handled and cursorKeysReach()) {
            const k = e.evt.key;
            if ((k.action == .down or k.action == .repeat) and moveTrackKey(k.code)) {
                e.handle(@src(), box.data());
                dvui.refresh(null, @src(), box.data().id);
                continue;
            }
        }
        // Typing with a panel or the canvas as the context makes a label
        // where the last click landed, and the expression line takes the
        // rest of the typing.
        if (e.evt == .text and !e.handled and track_cursor == null and state.tool == .select and !canvas_prompt and cursorKeysReach()) {
            const txt = switch (e.evt.text.action) {
                .value => |v| v.txt,
                else => "",
            };
            if (state.context == .panel and txt.len > 0 and txt[0] >= ' ') {
                e.handle(@src(), box.data());
                typeLabel(state.context.panel, txt);
                dvui.refresh(null, @src(), box.data().id);
                continue;
            }
        }
        // A selected group: arrow keys move all of it 1 mm.
        if (e.evt == .key and state.context == .group and !e.handled and cursorKeysReach()) {
            const k = e.evt.key;
            if ((k.action == .down or k.action == .repeat) and moveGroupKey(k.code)) {
                e.handle(@src(), box.data());
                dvui.refresh(null, @src(), box.data().id);
                continue;
            }
        }
        // A selected image: arrow keys move it 1 mm.
        if (e.evt == .key and state.context == .image and !e.handled and cursorKeysReach()) {
            const k = e.evt.key;
            if ((k.action == .down or k.action == .repeat) and moveImageKey(k.code)) {
                e.handle(@src(), box.data());
                dvui.refresh(null, @src(), box.data().id);
                continue;
            }
        }
        // A selected view: arrow keys move it 1 mm.
        if (e.evt == .key and state.context == .view and !e.handled and cursorKeysReach()) {
            const k = e.evt.key;
            if ((k.action == .down or k.action == .repeat) and moveViewKey(k.code)) {
                e.handle(@src(), box.data());
                dvui.refresh(null, @src(), box.data().id);
                continue;
            }
        }
        // Selected line art: arrow keys move it 1 mm, and the tracks under
        // it reflow.
        if (e.evt == .key and state.context == .art and !e.handled and cursorKeysReach()) {
            const k = e.evt.key;
            if ((k.action == .down or k.action == .repeat) and moveArtKey(k.code)) {
                e.handle(@src(), box.data());
                dvui.refresh(null, @src(), box.data().id);
                continue;
            }
        }
        // The flow cursor's keys, while the canvas or the palette has the
        // keyboard: never from a text entry.
        if (e.evt == .key and track_cursor != null and !e.handled and cursorKeysReach()) {
            const k = e.evt.key;
            if ((k.action == .down or k.action == .repeat) and cursorKey(k.code)) {
                e.handle(@src(), box.data());
                dvui.refresh(null, @src(), box.data().id);
                continue;
            }
        }
        if (e.evt == .key and (state.moving != null or state.moving_label != null)) {
            const k = e.evt.key;
            if (k.code == .escape and k.action == .down) {
                e.handle(@src(), box.data());
                state.moving = null;
                state.moving_label = null;
                dvui.refresh(null, @src(), box.data().id);
            }
            continue;
        }
        if (e.evt == .key and drawing) {
            const k = e.evt.key;
            if (k.code == .escape and k.action == .down) {
                e.handle(@src(), box.data());
                state.tool = .select;
                state.drag = null;
                polygon_pts.clearRetainingCapacity();
                dvui.refresh(null, @src(), box.data().id);
            } else if ((k.code == .enter or k.code == .kp_enter) and k.action == .down and state.tool == .add_art and polygon_pts.items.len > 0) {
                e.handle(@src(), box.data());
                finishPolygon();
                dvui.refresh(null, @src(), box.data().id);
            }
            continue;
        }
        if (!dvui.eventMatchSimple(e, box.data())) continue;
        if (e.evt == .key) {
            // Keys reach the canvas only while it has focus.
            const k = e.evt.key;
            if (k.code == .delete and k.action == .down and state.moving == null) {
                switch (state.context) {
                    .panel => |pi| if (!state.model.panels.items[pi].unbounded) {
                        e.handle(@src(), box.data());
                        actV(.removePanel, .{pi});
                        state.context = .worksheet;
                        dvui.refresh(null, @src(), box.data().id);
                    },
                    .label => |l| if (state.moving_label == null) {
                        e.handle(@src(), box.data());
                        actV(.removeLabel, .{l.panel, l.index});
                        state.context = .{ .panel = l.panel };
                        dvui.refresh(null, @src(), box.data().id);
                    },
                    .art => |l| {
                        e.handle(@src(), box.data());
                        actV(.removeArt, .{l.panel, l.index});
                        state.context = .{ .panel = l.panel };
                        dvui.refresh(null, @src(), box.data().id);
                    },
                    .image => |im| {
                        e.handle(@src(), box.data());
                        actV(.removeImage, .{im.space, im.index});
                        state.context = .{ .panel = state.model.spaces.items[im.space].root };
                        dvui.refresh(null, @src(), box.data().id);
                    },
                    .view => |v| {
                        e.handle(@src(), box.data());
                        actV(.removeView, .{v.space, v.index});
                        state.context = .{ .panel = state.model.spaces.items[v.space].root };
                        dvui.refresh(null, @src(), box.data().id);
                    },
                    // A tile leaves its track, which closes up behind it.
                    .tile => |id| {
                        e.handle(@src(), box.data());
                        const found = findTile(id);
                        actV(.removeTile, .{id});
                        state.context = if (found) |f| .{ .row = .{ .panel = f.panel, .region = f.tile.region, .row = f.tile.row } } else .worksheet;
                        dvui.refresh(null, @src(), box.data().id);
                    },
                    else => {},
                }
            }
            continue;
        }
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            // A press first sends a focus event; taking it gives the canvas
            // keyboard focus, for Delete and the like.
            .focus => {
                e.handle(@src(), box.data());
                dvui.focusWidget(box.data().id, null, e.num);
            },
            .position => {
                // The pointer's worksheet position, for the rulers and readout.
                const at = state.view.toMm(area, me.p);
                state.mouse = if (area.contains(me.p) and (openCanvas() or contains(state.model.sheet.box(), at))) at else null;
                if (drawing) {
                    dvui.cursorSet(.crosshair);
                } else if (state.moving != null or state.moving_label != null) {
                    dvui.cursorSet(.arrow_all);
                } else if (labelUnder(state.view.toMm(area, me.p))) {
                    dvui.cursorSet(.arrow_all);
                } else if (panelToMove(state.view.toMm(area, me.p)) != null) {
                    // Over a panel a drag would move, show that it can be.
                    dvui.cursorSet(.arrow_all);
                }
            },
            .wheel_y => |dy| {
                e.handle(@src(), box.data());
                const at = state.view.toMm(area, me.p);
                const z = @exp(@log(1.003) * @as(f64, dy));
                state.view.ppm *= z;
                state.view.fit = null;
                // Keep the point under the pointer fixed.
                state.view.cx = at.x - (at.x - state.view.cx) / z;
                state.view.cy = at.y - (at.y - state.view.cy) / z;
                dvui.refresh(null, @src(), box.data().id);
            },
            .press => if ((me.button.pointer() or me.button == .middle) and area.contains(me.p)) {
                e.handle(@src(), box.data());
                dvui.captureMouse(box.data(), e.num);
                if (state.tool == .add_label and me.button.pointer()) {
                    // One click places a label on the panel it was chosen for.
                    const at = state.view.toMm(area, me.p);
                    if (state.context == .panel and panelHolds(state.context.panel, at)) {
                        addLabelAt(state.context.panel, at);
                        state.tool = .select;
                        // The release that follows is part of this click, not a pick.
                        state.press_consumed = true;
                    }
                } else if (state.tool == .select_area and me.button.pointer()) {
                    const at = state.view.toMm(area, me.p);
                    state.drag = .{ .start = at, .at = at };
                } else if (state.tool == .add_art and me.button.pointer()) {
                    // Line art is drawn from a point on its panel; a polygon
                    // takes a click per corner.
                    const at = state.view.toMm(area, me.p);
                    if (state.context == .panel and panelHolds(state.context.panel, at)) {
                        const p: geom.Point = .{ .x = @round(at.x * 2) / 2, .y = @round(at.y * 2) / 2 };
                        if (shape_kind == .polygon) {
                            polygonClick(state.context.panel, p);
                            state.press_consumed = true;
                        } else state.drag = .{ .start = p, .at = p };
                    }
                } else if (state.tool == .add_tracks and me.button.pointer()) {
                    // Tracks are drawn from a point on the panel chosen for them.
                    const at = state.view.toMm(area, me.p);
                    if (state.context == .panel and panelHolds(state.context.panel, at)) {
                        const p: geom.Point = .{ .x = @round(at.x * 2) / 2, .y = @round(at.y * 2) / 2 };
                        state.drag = .{ .start = p, .at = p };
                    }
                } else if (drawing and me.button.pointer()) {
                    // A panel is drawn from a point on the sheet.
                    const at = snap(state.view.toMm(area, me.p));
                    if (openCanvas() or contains(state.model.sheet.box(), at)) state.drag = .{ .start = at, .at = at };
                } else {
                    state.press_at = if (me.button.pointer()) state.view.toMm(area, me.p) else null;
                    dvui.dragPreStart(me.button, me.p, .{});
                }
            },
            .motion => if (dvui.captured(box.data().id)) {
                if (state.drag) |*d| {
                    e.handle(@src(), box.data());
                    d.at = if (state.tool == .add_tracks) state.view.toMm(area, me.p) else snap(state.view.toMm(area, me.p));
                    dvui.refresh(null, @src(), box.data().id);
                } else if (state.moving) |*mv| {
                    e.handle(@src(), box.data());
                    mv.at = state.view.toMm(area, me.p);
                    dvui.refresh(null, @src(), box.data().id);
                } else if (state.moving_label) |*mv| {
                    e.handle(@src(), box.data());
                    mv.at = state.view.toMm(area, me.p);
                    dvui.refresh(null, @src(), box.data().id);
                } else if (dvui.dragging(me, null)) |d| {
                    e.handle(@src(), box.data());
                    // Dragging the selected panel moves it; anything else pans.
                    if (grabbedLabel()) |l| {
                        state.moving_label = .{ .panel = l.panel, .index = l.index, .start = state.press_at.?, .at = state.view.toMm(area, me.p) };
                    } else if (grabbedPanel()) |pi| {
                        state.moving = .{ .panel = pi, .start = state.press_at.?, .at = state.view.toMm(area, me.p) };
                    } else {
                        state.view.fit = null;
                        state.view.cx -= d.x / state.view.ppm;
                        state.view.cy += d.y / state.view.ppm;
                    }
                    dvui.refresh(null, @src(), box.data().id);
                }
            },
            .release => if (dvui.captured(box.data().id)) {
                e.handle(@src(), box.data());
                if (state.drag) |d| {
                    state.drag = null;
                    switch (state.tool) {
                        .add_tracks => addTracksFromDrag(d.start, d.at),
                        .add_art => addArtFromDrag(dragBox(d.start, d.at)),
                        .select_area => selectArea(dragBox(d.start, d.at)),
                        else => addPanelFromDrag(dragBox(d.start, d.at)),
                    }
                } else if (state.moving) |mv| {
                    finishMove(mv.panel);
                } else if (state.moving_label) |mv| {
                    const d = labelDelta(mv.panel, mv.index);
                    state.moving_label = null;
                    const at = state.model.panels.items[mv.panel].labels.items[mv.index].at;
                    actV(.moveLabel, .{mv.panel, mv.index, .{ .x = at.x + d.x, .y = at.y + d.y }});
                } else if (state.press_consumed) {
                    state.press_consumed = false;
                } else if (dvui.dragging(me, null) == null) {
                    pick(state.view.toMm(area, me.p));
                }
                state.press_at = null;
                dvui.captureMouse(null, e.num);
                dvui.dragEnd(me.button);
                dvui.refresh(null, @src(), box.data().id);
            },
            else => {},
        }
    }
}

/// The selected panel, when the pointer went down on it: a drag then moves it.
/// Whether `at` is on the selected panel label, which a drag would move.
fn labelUnder(at: geom.Point) bool {
    const l = switch (state.context) {
        .label => |l| l,
        else => return false,
    };
    const b = labelBox(l.panel, l.index) orelse return false;
    return contains(.{ .x0 = b.x0 - 1, .y0 = b.y0 - 1, .x1 = b.x1 + 1, .y1 = b.y1 + 1 }, at);
}

/// The selected panel label, when the pointer went down on it.
fn grabbedLabel() ?struct { panel: usize, index: usize } {
    const at = state.press_at orelse return null;
    const l = switch (state.context) {
        .label => |l| l,
        else => return null,
    };
    const b = labelBox(l.panel, l.index) orelse return null;
    if (!contains(.{ .x0 = b.x0 - 1, .y0 = b.y0 - 1, .x1 = b.x1 + 1, .y1 = b.y1 + 1 }, at)) return null;
    return .{ .panel = l.panel, .index = l.index };
}

fn grabbedPanel() ?usize {
    return panelToMove(state.press_at orelse return null);
}

/// Whether worksheet point `at` lies on panel `pi`: always, for the canvas.
fn panelHolds(pi: usize, at: geom.Point) bool {
    const p = state.model.panels.items[pi];
    return p.unbounded or contains(p.box(), at);
}

/// The panel a drag from worksheet point `at` would move: the selected
/// panel when `at` is on it; from the worksheet context, the one panel
/// under `at`, if exactly one is (where panels overlap, select one first).
/// The context does not change.
fn panelToMove(at: geom.Point) ?usize {
    switch (state.context) {
        // The canvas itself never moves.
        .panel => |pi| return if (!state.model.panels.items[pi].unbounded and contains(state.model.panels.items[pi].box(), at)) pi else null,
        .worksheet => {
            var found: ?usize = null;
            for (state.model.panels.items, 0..) |p, pi| {
                if (p.unbounded or !contains(p.box(), at)) continue;
                if (found != null) return null;
                found = pi;
            }
            return found;
        },
        else => return null,
    }
}

fn contains(b: geom.Box, p: geom.Point) bool {
    return p.x >= b.x0 and p.x <= b.x1 and p.y >= b.y0 and p.y <= b.y1;
}

/// Commits a panel drag. A panel that started compliant ends compliant,
/// stopped where it would stop complying; one that was not may end anywhere.
fn finishMove(pi: usize) void {
    const target = panelOrigin(pi);
    state.moving = null;
    act(.movePanel, .{pi, target}) catch |err| dvui.log.err("moving a panel: {s}", .{@errorName(err)});
}

/// Makes what is under worksheet point `at` the context: a tile, else a
/// panel, else the worksheet.
fn pick(at: geom.Point) void {
    // In a region's context, a click in its tracks puts the flow cursor
    // there; anywhere else picks as usual.
    if (cursorAt(at)) |c| {
        track_cursor = c;
        return;
    }
    track_cursor = null;
    click_at = at;
    // Empty space is the worksheet, or on a canvas the shown space itself.
    state.context = if (spaceRoot()) |ri| .{ .panel = ri } else .worksheet;
    selection.clearRetainingCapacity();
    // An image, then a view, by their boxes; anything over them wins.
    if (imageUnder(at)) |im| state.context = im;
    if (viewUnder(at)) |v| state.context = v;
    for (state.model.panels.items, 0..) |panel, pi| {
        if (!shownPanel(pi)) continue;
        if (state.model.spaces.items.len > 0 and !layerOpen(panel.space, panelLayer(pi))) continue;
        const b = panel.box();
        if (!panel.unbounded and at.x >= b.x0 and at.x <= b.x1 and at.y >= b.y0 and at.y <= b.y1) state.context = .{ .panel = pi };
        if (pi >= state.placed.items.len) continue;
        for (state.placed.items[pi].tiles) |t| {
            const body = onSheet(pi, t.body);
            if (at.x >= body.x0 and at.x <= body.x1 and at.y >= body.y0 and at.y <= body.y1) state.context = .{ .tile = t.id };
        }
        // Line art, by its box: drawn over the tracks, it is picked over
        // what is under it.
        for (state.placed.items[pi].art) |pa| {
            if (contains(onSheet(pi, pa.box), at)) state.context = .{ .art = .{ .panel = pi, .index = pa.index } };
        }
        for (state.placed.items[pi].labels) |l| {
            if (l.tile != null) continue;
            // A run of text or an equation in a track: the track becomes
            // the context, with the cursor just after the run.
            if (l.run) |run| {
                if (contains(onSheet(pi, l.box), at)) {
                    state.context = .{ .region = .{ .panel = pi, .region = run.region } };
                    track_cursor = .{ .panel = pi, .region = run.region, .index = run.item + 1 };
                }
                continue;
            }
            if (labelBox(pi, l.slot)) |lb| if (contains(.{ .x0 = lb.x0 - 1, .y0 = lb.y0 - 1, .x1 = lb.x1 + 1, .y1 = lb.y1 + 1 }, at)) {
                state.context = .{ .label = .{ .panel = pi, .index = l.slot } };
            };
        }
    }
    // A grouped object is picked as its group: one move places them all.
    if (groupOf(state.context)) |g| state.context = .{ .group = g };
    revealInTree(state.context);
}

/// Adds the panel drawn out with the add panel tool. A drag under 1 mm on
/// either side is taken as a slip and ignored, leaving the tool ready.
fn addPanelFromDrag(b: geom.Box) void {
    if (b.width() < 1 or b.height() < 1) return;
    var buf: [32]u8 = undefined;
    const name = state.model.nextPanelName(&buf, "Panel");
    const pi = act(.placePanel, .{.{
        .name = name,
        .default_name = true,
        .space = shown_space,
        .origin = .{ .x = b.x0, .y = b.y0 },
        .w = b.width(),
        .h = b.height(),
    }}) catch |err| {
        state.status = if (err == error.OffSheet) "Too little of it is on the sheet: start further in. " else "The panel was not added. ";
        return;
    };
    // On the layer last chosen in its space.
    if (state.model.spaces.items.len > 0) hist.join(&state.model, .setPanelLayer, .{ pi, newObjectLayer() }) catch {};
    // Tools are not modes: a use ends the tool, and the context it was
    // chosen in stays, so the next panel is one press away.
    state.tool = .select;
    state.expanded.put(state.gpa, Context.key(.file), true) catch {};
    state.expanded.put(state.gpa, Context.key(.worksheet), true) catch {};
}

const Flags = struct { missing: bool = false, overflow: bool = false, size: bool = false };

fn tileFlag(placed: *const layout.place.Placed, id: TileId) Flags {
    var f: Flags = .{};
    for (placed.issues) |i| {
        if (i.tile != id) continue;
        switch (i.kind) {
            .missing_glyph => f.missing = true,
            .label_overflow => f.overflow = true,
            // Reaching back into rows already filled: outlined as a size
            // problem is, in the warning colour.
            .tile_size, .tall_item => f.size = true,
            else => {},
        }
    }
    return f;
}

/// The right side: a tool palette for the current context, then its
/// properties.
/// The tool palette, in whatever holds it.
fn toolsContent() void {
    if (canvas_prompt) return;
    var scroll = dvui.scrollArea(@src(), .{ .vertical_bar = .hide, .horizontal_bar = .hide }, .{ .expand = .both, .background = false });
    defer scroll.deinit();
    toolPalette();
}

/// The context's properties (and the active tool's choices), in whatever
/// holds them.
fn propertiesBody() !void {
    if (canvas_prompt) return;
    var scroll = dvui.scrollArea(@src(), .{ .vertical_bar = .hide, .horizontal_bar = .hide }, .{ .expand = .both, .background = false });
    defer scroll.deinit();
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .all(8) });
    defer body.deinit();
    if (state.tool == .add_tracks) try tracksToolOptions();
    try properties();
}

/// The Add tracks tool's choices, above the context's properties while it
/// is active.
fn tracksToolOptions() !void {
    heading("{s}", .{if (tracks_tool.major == .row) "Add rows" else "Add columns"}, 9000);
    const protos = state.model.prototypes.items;
    const styles = state.model.styles.items;
    // Keep the choice valid as prototypes and styles come and go.
    switch (tracks_tool.size_to) {
        .prototype => |pid| if (pid >= protos.len) {
            tracks_tool.size_to = if (protos.len > 0) .{ .prototype = 0 } else .{ .style = null };
        },
        .style => |sid| if (sid != null and sid.? >= styles.len) {
            tracks_tool.size_to = .{ .style = null };
        },
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 9001 });
        defer row.deinit();
        propName("Size to");
        // Tile prototypes, then text styles (the default one offered while
        // there is none).
        const lifo = dvui.currentWindow().lifo();
        const n_styles = @max(1, styles.len);
        const names = try lifo.alloc([]const u8, protos.len + n_styles);
        defer lifo.free(names);
        const arena = dvui.currentWindow().arena();
        for (protos, 0..) |p, i| names[i] = try std.fmt.allocPrint(arena, "Tile: {s}", .{p.name});
        if (styles.len == 0) names[protos.len] = "Text: Label";
        for (styles, 0..) |st, i| names[protos.len + i] = try std.fmt.allocPrint(arena, "Text: {s}", .{st.name});
        var choice: usize = switch (tracks_tool.size_to) {
            .prototype => |pid| pid,
            .style => |sid| protos.len + (sid orelse 0),
        };
        if (dvui.dropdown(@src(), names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal })) {
            tracks_tool.size_to = if (choice < protos.len)
                .{ .prototype = @intCast(choice) }
            else if (styles.len == 0) .{ .style = null } else .{ .style = @intCast(choice - protos.len) };
        }
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 9002 });
        defer row.deinit();
        propName("Tracks");
        const names = [_][]const u8{ "Rows (row-major)", "Columns (column-major)" };
        var choice: usize = @backingInt(tracks_tool.major);
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal })) tracks_tool.major = @fromBackingInt(@intCast(choice));
    }
    var buf: [96]u8 = undefined;
    switch (tracks_tool.size_to) {
        .prototype => |pid| if (pid < protos.len) {
            const p = protos[pid];
            const along = p.smallest(tracks_tool.major, .along);
            const step_ = p.step(tracks_tool.major, .along);
            const across = p.smallest(tracks_tool.major, .across);
            propText("Snaps to", "{s}", .{std.fmt.bufPrint(&buf, "{d} u thick; {d} u long or more, in {d} u steps", .{ across, along, step_ }) catch ""}, 9003);
        },
        .style => |sid| if (styleLinePitch(sid)) |lp| {
            propText("Snaps to", "{s}", .{std.fmt.bufPrint(&buf, "one line ({d:.2} mm) thick; {d} mm steps along", .{ lp, text_track_step }) catch ""}, 9003);
        },
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal, .margin = .{ .y = 6, .h = 6 } });
}

/// Text tracks snap along to this, mm.
const text_track_step = 0.5;

/// A text style's baseline-to-baseline distance, mm, in the current font;
/// for no style, what the default Label style's would be (3 mm caps).
fn styleLinePitch(style: ?layout.model.StyleId) ?f64 {
    const labels = if (state.labels) |*l| l else return null;
    if (style) |sid| {
        const ctx = labels.context(sid) orelse return null;
        return ctx.linePitch() catch null;
    }
    if (state.faces.len == 0) return null;
    const ctx = engine.style.Context.init(&state.faces, .{ .upright = 0, .cap_height = 3 }) catch return null;
    return ctx.linePitch() catch null;
}

/// "Row" or "Column".
fn trackWord(major: layout.model.Major) []const u8 {
    return if (major == .row) "Row" else "Column";
}

/// A prototype to draw tracks of: the first, made as a plain keycap when
/// there is none.
fn ensurePrototype() !void {
    if (state.model.prototypes.items.len > 0) return;
    var p: layout.model.TilePrototype = .{
        .name = "Key",
        .unit = 19.05,
        .body_inset = .all(0.5),
        .face_inset = .all(2),
        .slots = &.{.{ .name = "top", .style = try labelStyle(), .place = .{ .inset = .all(0.8) } }},
    };
    p.art = try layout.art.redrawKeycap(dvui.currentWindow().arena(), p, 19.05);
    _ = try act(.addPrototype, .{p});
}

/// Tracks a drag from `start` to `at` (worksheet, mm) would make on the
/// context panel: the region snapped to whole tracks across, as thick as
/// the prototype's smallest tile, and along to its size step, no shorter
/// than its smallest tile; set out from `start` the way the drag went.
const TrackPlan = struct {
    panel: usize,
    count: usize,
    length: f64,
    pitch: f64,
    major: layout.model.Major,
    /// On the worksheet, mm.
    box: geom.Box,
};

fn planTracks(from: geom.Point, at: geom.Point) ?TrackPlan {
    const pi = switch (state.context) {
        .panel => |pi| pi,
        else => return null,
    };
    const major = tracks_tool.major;
    // The unit (mm per u), and in it: the thickness of one track, the
    // shortest length and the step along.
    var pitch: f64 = undefined;
    var along_min: f64 = undefined;
    var step_: f64 = undefined;
    var across: f64 = 1;
    switch (tracks_tool.size_to) {
        .prototype => |pid| {
            if (pid >= state.model.prototypes.items.len) return null;
            const p = state.model.prototypes.items[pid];
            // Its own unit: a 1 u key is 19.05 mm in any track.
            pitch = p.unit orelse if (p.art) |art| art.pitch else 19.05;
            along_min = p.smallest(major, .along);
            step_ = p.step(major, .along);
            across = p.smallest(major, .across);
        },
        .style => |sid| {
            // One line thick: the unit is the style's line pitch.
            pitch = styleLinePitch(sid) orelse return null;
            step_ = text_track_step / pitch;
            along_min = step_;
        },
    }
    const dx = at.x - from.x;
    const dy = at.y - from.y;
    const d_along = @abs(if (major == .row) dx else dy) / pitch;
    const d_across = @abs(if (major == .row) dy else dx) / pitch;
    const length = @max(along_min, @round(d_along / step_) * step_);
    const tracks: usize = @max(1, @as(usize, @intFromFloat(@round(d_across / across))));
    const thickness = @as(f64, @floatFromInt(tracks)) * across;
    const w = (if (major == .row) length else thickness) * pitch;
    const h = (if (major == .row) thickness else length) * pitch;
    const x0 = if (dx >= 0) from.x else from.x - w;
    const y0 = if (dy >= 0) from.y else from.y - h;
    return .{ .panel = pi, .count = tracks, .length = length, .pitch = pitch, .major = major, .box = .{ .x0 = x0, .y0 = y0, .x1 = x0 + w, .y1 = y0 + h } };
}

fn drawTrackPlan(area: dvui.Rect.Physical, plan: TrackPlan) void {
    const px = dvui.windowNaturalScale();
    const fits = layout.model.within(plan.box, state.model.panels.items[plan.panel].box());
    const colour = if (fits) colors.select else colors.overflow;
    const r = state.view.rect(area, plan.box);
    r.fill(.square, .{ .color = .{ .color = colour.opacity(0.12) } });
    r.stroke(.square, .{ .thickness = 1.5 * px, .color = .{ .color = colour } });
    // The lines between tracks.
    const n = plan.count;
    for (1..n) |i| {
        const f = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        const b = plan.box;
        const a_pt: geom.Point = if (plan.major == .row) .{ .x = b.x0, .y = b.y1 - f * b.height() } else .{ .x = b.x0 + f * b.width(), .y = b.y1 };
        const b_pt: geom.Point = if (plan.major == .row) .{ .x = b.x1, .y = a_pt.y } else .{ .x = a_pt.x, .y = b.y0 };
        dvui.Path.stroke(.{ .points = &.{ state.view.toPx(area, a_pt), state.view.toPx(area, b_pt) } }, .{ .thickness = px, .color = .{ .color = colour.opacity(0.6) } });
    }
    var buf: [64]u8 = undefined;
    const word = if (plan.major == .row) "row" else "column";
    const plural = if (n == 1) "" else "s";
    // Text tracks in mm: a unit of one line pitch means little to anyone.
    const text = if (tracks_tool.size_to == .style)
        std.fmt.bufPrint(&buf, "{d} {s}{s} × {d:.1} mm", .{ n, word, plural, plan.length * plan.pitch }) catch ""
    else
        std.fmt.bufPrint(&buf, "{d} {s}{s} × {d} u", .{ n, word, plural, plan.length }) catch "";
    const corner = state.view.toPx(area, .{ .x = plan.box.x0, .y = plan.box.y1 });
    const font = dvui.themeGet().font_body;
    dvui.labelNoFmt(@src(), text, .{}, .{
        // In the canvas's own coordinates, just above the region.
        .rect = annotationRect(area, corner, font, 220),
        .padding = .{ .x = 4, .w = 4, .y = annotation_pad, .h = annotation_pad },
        .font = font,
        .color_text = .{ .color = colour },
        .background = true,
        .color_fill = .{ .color = dvui.themeGet().color(.window, .fill).opacity(0.85) },
    });
}

/// Makes the empty tracks a finished drag planned, makes their region the
/// context and puts the flow cursor at the start of the first, ready for
/// tiles. One use ends the tool.
fn addTracksFromDrag(from: geom.Point, at: geom.Point) void {
    defer state.tool = .select;
    const plan = planTracks(from, at) orelse return;
    const panel = state.model.panels.items[plan.panel];
    // Tracks may run past the panel: flagged, to be fitted or the panel
    // resized once their tiles show what is needed.
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "Tracks {d}", .{panel.regions.items.len + 1}) catch "Tracks";
    const r = act(.addTracks, .{plan.panel, .{
        .name = name,
        .origin = .{ .x = plan.box.x0 - panel.origin.x, .y = plan.box.y1 - panel.origin.y },
        .major = plan.major,
        .prototype = switch (tracks_tool.size_to) {
            .prototype => |pid| pid,
            .style => null,
        },
        .style = switch (tracks_tool.size_to) {
            .prototype => null,
            .style => |sid| sid orelse (labelStyle() catch return),
        },
        .count = plan.count,
        .length = plan.length,
        .pitch = plan.pitch,
    }}) catch {
        state.status = "The tracks were not added. ";
        return;
    };
    // Empty tracks, the user fills them: the cursor waits at the start.
    state.context = .{ .region = .{ .panel = plan.panel, .region = r } };
    track_cursor = .{ .panel = plan.panel, .region = r, .index = 0 };
    state.expanded.put(state.gpa, Context.key(.{ .panel = plan.panel }), true) catch {};
}

/// Tools for the current context, as icon buttons; with Add shape on,
/// which shape it draws.
fn toolPalette() void {
    var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal });
    defer col.deinit();
    toolBar();
    if (state.tool != .add_art) return;
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .{ .x = 8, .w = 8, .h = 4 } });
    defer row.deinit();
    propName("Shape");
    const names = [_][]const u8{ "Rectangle", "Rounded rectangle", "Circle", "Ellipse", "Slot", "Polygon" };
    var choice: usize = @intFromEnum(shape_kind);
    if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal })) {
        shape_kind = @enumFromInt(choice);
        polygon_pts.clearRetainingCapacity();
        state.drag = null;
    }
}

fn toolBar() void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(4) });
    defer bar.deinit();
    var wd: dvui.WidgetData = undefined;
    if (dvui.buttonIcon(@src(), "Zoom to context", dvui.entypo.resize_full_screen, .{}, .{}, .{ .data_out = &wd })) zoomToContext();
    dvui.tooltip(@src(), .{ .active_rect = wd.borderRectScale().r }, "Zoom to fit the {s}", .{lowerKind()}, .{});

    switch (state.context) {
        .prototypes => {
            var pwd: dvui.WidgetData = undefined;
            if (dvui.buttonIcon(@src(), "Add prototype", dvui.entypo.squared_plus, .{}, .{}, .{ .data_out = &pwd })) addPrototype() catch {
                state.status = "The prototype was not added. ";
            };
            dvui.tooltip(@src(), .{ .active_rect = pwd.borderRectScale().r }, "Add a tile prototype", .{}, .{});
        },
        .prototype => |id| {
            var dwd: dvui.WidgetData = undefined;
            if (dvui.buttonIcon(@src(), "Duplicate prototype", dvui.entypo.copy, .{}, .{}, .{ .data_out = &dwd })) duplicatePrototype(id) catch {
                state.status = "The prototype was not duplicated. ";
            };
            dvui.tooltip(@src(), .{ .active_rect = dwd.borderRectScale().r }, "Duplicate: a copy to make a variant of", .{}, .{});
            var rwd: dvui.WidgetData = undefined;
            if (dvui.buttonIcon(@src(), "Delete prototype", dvui.entypo.trash, .{}, .{}, .{ .data_out = &rwd })) {
                if (act(.removePrototype, .{id})) {
                    state.context = .prototypes;
                } else |err| state.status = if (err == error.PrototypeInUse) "Tiles are still made from this prototype: switch them first. " else "The prototype was not deleted. ";
            }
            dvui.tooltip(@src(), .{ .active_rect = rwd.borderRectScale().r }, "Delete: only while no tile is made from it", .{}, .{});
        },
        else => {},
    }

    if (state.context == .panel) {
        // Add label: the next click on the panel places one.
        const on = state.tool == .add_label;
        var lwd: dvui.WidgetData = undefined;
        if (dvui.buttonIcon(@src(), "Add label", dvui.entypo.text, .{}, .{}, .{
            .data_out = &lwd,
            .color_fill = if (on) .{ .color = dvui.themeGet().focus.opacity(0.35) } else null,
        })) {
            state.tool = if (on) .select else .add_label;
        }
        dvui.tooltip(@src(), .{ .active_rect = lwd.borderRectScale().r }, "Add label: click on the panel to place it", .{}, .{});

        const art_on = state.tool == .add_art;
        var awd: dvui.WidgetData = undefined;
        if (dvui.buttonIcon(@src(), "Add shape", dvui.entypo.circle, .{}, .{}, .{
            .data_out = &awd,
            .color_fill = if (art_on) .{ .color = dvui.themeGet().focus.opacity(0.35) } else null,
        })) {
            state.drag = null;
            state.tool = if (art_on) .select else .add_art;
        }
        dvui.tooltip(@src(), .{ .active_rect = awd.borderRectScale().r }, "Add shape: drag out line art on the panel; tracks under it flow around its ink", .{}, .{});

        // Two track modes, one button each: rows (tiles flow left to right)
        // and columns (top to bottom).
        inline for (.{
            .{ layout.model.Major.row, "Add rows", dvui.entypo.menu, "Add rows: tracks of tiles running left to right, drawn out on the panel" },
            .{ layout.model.Major.column, "Add columns", dvui.entypo.bar_graph, "Add columns: tracks of tiles running top to bottom, drawn out on the panel" },
        }, 0..) |mode, mi| {
            const mode_on = state.tool == .add_tracks and tracks_tool.major == mode[0];
            var twd: dvui.WidgetData = undefined;
            if (dvui.buttonIcon(@src(), mode[1], mode[2], .{}, .{}, .{
                .id_extra = mi,
                .data_out = &twd,
                .color_fill = if (mode_on) .{ .color = dvui.themeGet().focus.opacity(0.35) } else null,
            })) {
                state.drag = null;
                if (mode_on) {
                    state.tool = .select;
                } else {
                    state.tool = .add_tracks;
                    tracks_tool.major = mode[0];
                    ensurePrototype() catch {};
                }
            }
            dvui.tooltip(@src(), .{ .active_rect = twd.borderRectScale().r }, mode[3], .{}, .{ .id_extra = mi });
        }
    }
    if (state.context == .region) {
        // Fit to tiles: the tracks shrink to what has been put in them.
        const r = state.context.region;
        var fwd: dvui.WidgetData = undefined;
        if (dvui.buttonIcon(@src(), "Fit to tiles", dvui.entypo.crop, .{}, .{}, .{ .data_out = &fwd })) {
            state.status = if (fitRegion(r.panel, r.region)) "" else "The tracks already fit their content (or hold none). ";
        }
        dvui.tooltip(@src(), .{ .active_rect = fwd.borderRectScale().r }, "Fit to tiles: make the rows or columns as long as the longest paragraph", .{}, .{});
    }
    const on_canvas = switch (state.context) {
        .panel => |pi| state.model.panels.items[pi].unbounded,
        else => false,
    };
    if (on_canvas or state.context == .selection or state.context == .group) {
        const sel_on = state.tool == .select_area;
        var swd: dvui.WidgetData = undefined;
        if (dvui.buttonIcon(@src(), "Select area", dvui.entypo.select_arrows, .{}, .{}, .{
            .data_out = &swd,
            .color_fill = if (sel_on) .{ .color = dvui.themeGet().focus.opacity(0.35) } else null,
        })) {
            state.drag = null;
            state.tool = if (sel_on) .select else .select_area;
        }
        dvui.tooltip(@src(), .{ .active_rect = swd.borderRectScale().r }, "Select area: drag around objects to pick them together, to move or copy into a frame", .{}, .{});
    }
    if (state.context == .worksheet or on_canvas) {
        // A mode tool: shown pressed while active; pressing again cancels.
        const on = state.tool == .add_panel;
        var awd: dvui.WidgetData = undefined;
        if (dvui.buttonIcon(@src(), "Add panel", dvui.entypo.squared_plus, .{}, .{}, .{
            .data_out = &awd,
            .color_fill = if (on) .{ .color = dvui.themeGet().focus.opacity(0.35) } else null,
        })) {
            state.tool = if (on) .select else .add_panel;
            state.drag = null;
        }
        dvui.tooltip(@src(), .{ .active_rect = awd.borderRectScale().r }, "Add panel: drag out its outline on the sheet", .{}, .{});
    }
}

fn lowerKind() []const u8 {
    return switch (state.context) {
        .file => "file",
        .worksheet => "worksheet",
        .panel => "panel",
        .region => "region",
        .row => "row",
        .tile => "tile",
        .label => "label",
        .art => "line art",
        .group => "group",
        .selection => "selection",
        .view => "view",
        .layer => "layer",
        .image => "image",
        .prototypes => "tile prototypes",
        .prototype => "tiles of the prototype",
    };
}

/// Property rows lay out as name and value. `n` numbers rows within a pane
/// so each has its own widget id.
const label_width = 104;

fn heading(comptime fmt: []const u8, args: anytype, n: usize) void {
    dvui.label(@src(), fmt, args, .{ .font = .theme(.heading), .id_extra = n, .padding = .{ .y = 8, .h = 4 } });
}

/// UI style rule: a value the app chose, and the user has not, is italic.
fn styled(font: dvui.Font, default: bool) dvui.Font {
    return if (default) font.withStyle(.italic) else font;
}

fn propText(name: []const u8, comptime fmt: []const u8, args: anytype, n: usize) void {
    propValue(name, false, fmt, args, n);
}

/// A read-only property; `default` marks a value the app chose.
fn propValue(name: []const u8, default: bool, comptime fmt: []const u8, args: anytype, n: usize) void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n });
    defer row.deinit();
    dvui.labelNoFmt(@src(), name, .{}, .{ .min_size_content = .{ .w = label_width }, .color_text = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.65) } });
    dvui.label(@src(), fmt, args, .{ .expand = .horizontal, .font = styled(.theme(.body), default) });
}

/// The left-hand name of a property row.
fn propName(name: []const u8) void {
    dvui.labelNoFmt(@src(), name, .{}, .{ .min_size_content = .{ .w = label_width }, .gravity_y = 0.5, .color_text = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.65) } });
}

/// The worksheet's editable properties: its name (a short description for
/// reference, separate from the file name), and its sheet as a
/// standard paper and orientation or a custom size.
fn worksheetProperties() !void {
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        propName("Name");
        var te = dvui.textEntry(@src(), .{ .text_initial = state.model.sheet.name }, .{ .expand = .horizontal, .font = styled(.theme(.body), state.model.sheet.default_name) });
        const changed = te.text_changed;
        const text = te.textGet();
        te.deinit();
        // A text entry reports a change on its first frame; only a
        // different text is an edit.
        if (changed and !std.mem.eql(u8, text, state.model.sheet.name)) try act(.nameWorksheet, .{text});
    }

    const sheet = state.model.sheet;
    const papers = layout.model.papers;
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        propName("Sheet");
        var names: [papers.len + 1][]const u8 = undefined;
        for (papers, 0..) |p, i| names[i] = p.name;
        names[papers.len] = "Custom";
        var choice: usize = sheet.paper orelse papers.len;
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .font = styled(.theme(.body), sheet.default_size) })) {
            try act(.setSheet, .{if (choice < papers.len) .standard(choice, sheet.orientation) else .custom(sheet.w, sheet.h)});
            zoomToContext();
        }
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        propName("Orientation");
        const names = [_][]const u8{ "Landscape", "Portrait" };
        var choice: usize = @backingInt(sheet.orientation);
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .font = styled(.theme(.body), sheet.default_size) })) {
            const o: layout.model.Orientation = @fromBackingInt(@intCast(choice));
            if (o != sheet.orientation) {
                try act(.setSheet, .{if (sheet.paper) |p| .standard(p, o) else .custom(sheet.h, sheet.w)});
                zoomToContext();
            }
        }
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        propName("Units");
        const names = [_][]const u8{ "Millimetres", "Inches" };
        var choice: usize = @backingInt(sheet.units);
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .font = styled(.theme(.body), sheet.default_units) })) {
            actV(.setUnits, .{@fromBackingInt(@intCast(choice))});
        }
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        propName("Ruler origin");
        const names = [_][]const u8{ "Bottom left", "Top left", "Bottom right", "Top right" };
        var choice: usize = @backingInt(sheet.ruler_origin);
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .font = styled(.theme(.body), sheet.default_ruler_origin) })) {
            actV(.setRulerOrigin, .{@fromBackingInt(@intCast(choice))});
        }
    }
    if (sheet.paper == null) {
        // A custom sheet takes its size as typed.
        var w = sheet.w;
        var h = sheet.h;
        var changed = false;
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            propName("Width, mm");
            changed = dvui.textEntryNumber(@src(), f64, .{ .value = &w, .min = 1, .max = 10000 }, .{ .expand = .horizontal }).changed or changed;
        }
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
            defer row.deinit();
            propName("Height, mm");
            changed = dvui.textEntryNumber(@src(), f64, .{ .value = &h, .min = 1, .max = 10000 }, .{ .expand = .horizontal }).changed or changed;
        }
        if (changed) {
            try act(.setSheet, .{.custom(w, h)});
            zoomToContext();
        }
    } else {
        propValue("Size", sheet.default_size, "{d} × {d} mm", .{ sheet.w, sheet.h }, 50);
    }

    // Margins: ink keep-out bands. Panels may reach into them; their ink
    // may not.
    heading("Margins", .{}, 60);
    var m = sheet.margins;
    var changed = false;
    inline for (.{ .{ "Left, mm", "left" }, .{ "Right, mm", "right" }, .{ "Top, mm", "top" }, .{ "Bottom, mm", "bottom" } }, 0..) |side, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 61 + i });
        defer row.deinit();
        propName(side[0]);
        const r = dvui.textEntryNumber(@src(), f64, .{ .value = &@field(m, side[1]), .min = 0, .max = 1000 }, .{
            .expand = .horizontal,
            .font = styled(.theme(.body), sheet.default_margins),
        });
        changed = r.changed or changed;
    }
    if (changed) act(.setMargins, .{m}) catch {};
    if (state.intrusions.len > 0) {
        propValue("Ink in margins", false, "{d} labels", .{state.intrusions.len}, 70);
    }
    if (state.panel_issues.len > 0) {
        propValue("Out of compliance", false, "{d} panels", .{state.panel_issues.len}, 71);
    }
}

/// A panel's margins: the ink keep-out bands inside its edges.
fn panelMargins(pi: usize) !void {
    const panel = state.model.panels.items[pi];
    heading("Margins", .{}, 10);
    var m = panel.margins;
    var changed = false;
    inline for (.{ .{ "Left, mm", "left" }, .{ "Right, mm", "right" }, .{ "Top, mm", "top" }, .{ "Bottom, mm", "bottom" } }, 0..) |side, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 11 + i });
        defer row.deinit();
        propName(side[0]);
        const r = dvui.textEntryNumber(@src(), f64, .{ .value = &@field(m, side[1]), .min = 0, .max = 1000 }, .{
            .expand = .horizontal,
            .font = styled(.theme(.body), panel.default_margins),
            .id_extra = pi,
        });
        changed = r.changed or changed;
    }
    if (changed) act(.setPanelMargins, .{pi, m}) catch {};
}

/// The font property: a list of installed fonts, with arrows to step
/// through them. All labels share one face for now; per-style fonts come
/// with the style editor.
fn propFont(name: []const u8, n: usize) !void {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n });
    defer row.deinit();
    dvui.labelNoFmt(@src(), name, .{}, .{ .min_size_content = .{ .w = label_width }, .gravity_y = 0.5, .color_text = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.65) } });
    if (state.fonts.len == 0) {
        dvui.labelNoFmt(@src(), "none found (fc-list)", .{}, .{});
        return;
    }
    const lifo = dvui.currentWindow().lifo();
    const names = try lifo.alloc([]const u8, state.fonts.len);
    defer lifo.free(names);
    for (state.fonts, 0..) |f, i| names[i] = f.name;
    if (dvui.dropdown(@src(), names, .{ .choice = &state.font_choice }, .{}, .{ .expand = .horizontal, .max_size_content = .width(120), .font = styled(.theme(.body), !state.font_set) })) state.font_set = true;
    if (dvui.buttonIcon(@src(), "Previous font", dvui.entypo.chevron_left, .{}, .{}, .{})) {
        state.font_choice = (state.font_choice + state.fonts.len - 1) % state.fonts.len;
        state.font_set = true;
    }
    if (dvui.buttonIcon(@src(), "Next font", dvui.entypo.chevron_right, .{}, .{}, .{})) {
        state.font_choice = (state.font_choice + 1) % state.fonts.len;
        state.font_set = true;
    }
}

fn properties() !void {
    const on_canvas = switch (state.context) {
        .panel => |pi| state.model.panels.items[pi].unbounded,
        else => false,
    };
    const frame_root = switch (state.context) {
        .panel => |pi| state.model.panels.items[pi].unbounded and state.model.panels.items[pi].space != 0,
        else => false,
    };
    heading("{s}", .{if (frame_root) "Frame" else if (on_canvas) "Canvas" else state.context.kindName()}, 0);
    switch (state.context) {
        .file => {
            // The file's name is its path, set by saving; it is not a property.
            propValue("Saved", true, "not yet", .{}, 1);
            propText("Engine", "{s}", .{engine.version}, 2);
        },
        .worksheet => {
            try worksheetProperties();
            propText("Panels", "{d}", .{state.model.panels.items.len}, 3);
            propText("Tiles", "{d}", .{state.model.tiles.items.len}, 4);
            try propFont("Legend font", 5);
        },
        .panel => |pi| if (state.model.panels.items[pi].unbounded) {
            if (state.model.panels.items[pi].space == 0) try canvasProperties(pi) else try frameProperties(state.model.panels.items[pi].space);
        } else {
            const panel = state.model.panels.items[pi];
            propValue("Name", panel.default_name, "{s}", .{panel.name}, 1);
            propText("Origin", "({d:.2}, {d:.2}) mm", .{ panel.origin.x, panel.origin.y }, 2);
            propText("Size", "{d:.2} × {d:.2} mm", .{ panel.w, panel.h }, 3);
            propText("Regions", "{d}", .{panel.regions.items.len}, 4);
            propText("Labels", "{d}", .{panel.labels.items.len}, 7);
            propText("Outline", "{s}", .{if (panel.edge) |e| e.prim.label() else "Rectangle"}, 8);
            if (state.model.spaces.items.len > 0) if (layerChoice(panel.space, panelLayer(pi), 10)) |l| try act(.setPanelLayer, .{pi, l});
            var cutouts: usize = 0;
            for (panel.art.items) |pa| {
                if (pa.cutout) cutouts += 1;
            }
            propText("Cutouts", "{d}", .{cutouts}, 9);
            try panelMargins(pi);
            if (panelIssue(pi)) |i| {
                if (i.off_sheet > 0) propText("Issue", "{d:.2} mm off the sheet", .{i.off_sheet}, 20);
                if (i.ink_outside > 0) propText("Issue", "ink area {d:.2} mm in margin", .{i.ink_outside}, 21);
            }
            try propFont("Legend font", 5);
            if (state.model.has_sheet) return;
            if (dvui.button(@src(), "Release panel", .{}, .{ .expand = .horizontal, .margin = .{ .y = 8 } })) {
                const id = act(.releasePanel, .{pi}) catch {
                    state.status = "The panel could not be released. ";
                    return;
                };
                state.context = if (state.model.locate(id)) |loc| switch (loc) {
                    .art => |l| .{ .art = .{ .panel = l.panel, .index = l.index } },
                    else => .worksheet,
                } else .worksheet;
                state.status = "Released: its outline and contents are loose again. ";
            }
        },
        .region => |r| {
            const region = state.model.panels.items[r.panel].regions.items[r.region];
            propText("Name", "{s}", .{region.name}, 1);
            propText("Origin", "({d:.2}, {d:.2}) mm", .{ region.origin.x, region.origin.y }, 2);
            // Sized to a text style, the unit is one line pitch: shown in mm.
            if (region.style != null)
                propText("Size", "{d:.1} × {d:.1} mm", .{ region.w * region.pitch, region.h * region.pitch }, 3)
            else
                propText("Size", "{d} × {d} u", .{ region.w, region.h }, 3);
            propText("Pitch", "{d:.2} mm", .{region.pitch}, 4);
            propText(if (region.major == .row) "Rows" else "Columns", "{d}", .{segmentCount(r.panel, r.region)}, 5);
            propText("Items", "{d}", .{region.items.items.len}, 8);
            if (r.panel < state.placed.items.len) for (state.placed.items[r.panel].issues) |i| {
                if (i.kind == .region_outside and i.region == r.region) propText("Issue", "{d:.2} mm past the panel", .{i.amount}, 7);
            };
            if (region.prototype) |pid| if (pid < state.model.prototypes.items.len) propText("Prototype", "{s}", .{state.model.prototypes.items[pid].name}, 6);
            if (region.style) |sid| if (sid < state.model.styles.items.len) propText("Sized to", "{s}, one line ({d:.2} mm)", .{ state.model.styles.items[sid].name, region.pitch }, 9);
            try trackFlowProperties(r.panel, r.region);
        },
        .row => |r| {
            const region = state.model.panels.items[r.panel].regions.items[r.region];
            propText(trackWord(region.major), "{d} of {d} in {s}", .{ r.row + 1, segmentCount(r.panel, r.region), region.name }, 1);
            var where_buf: [96]u8 = undefined;
            propText("Placed", "{s}", .{trackWhere(&where_buf, r.panel, r.region, r.row)}, 2);
            var held: usize = 0;
            if (r.panel < state.placed.items.len) for (state.placed.items[r.panel].items) |it| {
                if (it.region == r.region and it.segment == r.row and !isBreak(r.panel, it)) held += 1;
            };
            propText("Items", "{d}", .{held}, 3);
        },
        .tile => |id| try tileProperties(id),
        .label => |l| try labelProperties(l.panel, l.index),
        .art => |l| try artProperties(l.panel, l.index),
        .group => |g| try groupProperties(g),
        .selection => try selectionProperties(),
        .view => |v| try viewProperties(v.space, v.index),
        .layer => |l| try layerProperties(l.space, l.index),
        .image => |im| try imageProperties(im.space, im.index),
        .prototypes => propText("Prototypes", "{d}", .{state.model.prototypes.items.len}, 1),
        .prototype => |id| try prototypeProperties(id),
    }
}

/// A panel label's properties: its text, how it aligns on its anchor, the
/// anchor's position, and its style's size.
fn labelProperties(pi: usize, index: usize) !void {
    const label = state.model.panels.items[pi].labels.items[index];
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        propName("Text");
        var te = dvui.textEntry(@src(), .{ .text_initial = label.content }, .{
            .expand = .horizontal,
            .font = styled(.theme(.body), label.default_content),
            .id_extra = pi * 1000 + index,
        });
        // Kept in step with the expression line while not being edited here.
        if (te.data().id != dvui.focusedWidgetId() and !std.mem.eql(u8, te.textGet(), label.content)) te.textSet(label.content, false);
        const changed = te.text_changed;
        const text = te.textGet();
        te.deinit();
        if (changed and !std.mem.eql(u8, text, label.content)) try actM(mergeKey(.{ "label", pi, index }), .setLabelContent, .{ pi, index, text });
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        propName("Alignment");
        const names = [_][]const u8{ "Start", "Centre", "End" };
        var choice: usize = @backingInt(label.alignment);
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal })) {
            actV(.alignLabel, .{pi, index, @fromBackingInt(@intCast(choice))});
        }
    }
    {
        // The anchor, on the baseline, in the panel's frame.
        var at = label.at;
        var changed = false;
        inline for (.{ .{ "Anchor x, mm", "x" }, .{ "Anchor y, mm", "y" } }, 0..) |axis, i| {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = i });
            defer row.deinit();
            propName(axis[0]);
            const r = dvui.textEntryNumber(@src(), f64, .{ .value = &@field(at, axis[1]), .min = -10000, .max = 10000 }, .{ .expand = .horizontal, .id_extra = pi * 1000 + index });
            changed = r.changed or changed;
        }
        if (changed) actV(.moveLabel, .{pi, index, at});
    }
    const style = state.model.styles.items[label.style];
    propText("Style", "{s}", .{style.name}, 20);
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        propName("Cap height, mm");
        var cap = style.spec.cap_height;
        const default = state.label_style == label.style and !state.label_style_set;
        const r = dvui.textEntryNumber(@src(), f64, .{ .value = &cap, .min = 0.1, .max = 200 }, .{ .expand = .horizontal, .font = styled(.theme(.body), default) });
        if (r.changed) {
            act(.setCapHeight, .{label.style, cap}) catch {};
            if (state.label_style == label.style) state.label_style_set = true;
        }
    }
    try propFont("Font", 21);
    for (state.intrusions) |i| if (i.panel == pi and i.tile == null and i.slot == index) {
        propText("Issue", "ink {d:.2} mm in margin", .{i.amount}, 22);
    };
    if (pi < state.placed.items.len) for (state.placed.items[pi].issues, 0..) |i, k| if (i.label == index) {
        propText("Issue", "{s}", .{@tagName(i.kind)}, 23 + k);
    };
}

fn tileProperties(id: TileId) !void {
    const t = state.model.tileConst(id);
    propText("Designator", "{s}", .{t.designator}, 1);
    try sizeProperty(id, .horizontal);
    try sizeProperty(id, .vertical);
    const found = findTile(id);
    if (found) |f| {
        const pt = f.tile;
        propText("Body", "{d:.2} × {d:.2} mm", .{ pt.body.width(), pt.body.height() }, 3);
        propText("Position", "({d:.2}, {d:.2}) mm in panel", .{ pt.body.x0, pt.body.y0 }, 4);
        propText("Row", "{d}", .{pt.row + 1}, 5);
    }

    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 6 });
        defer row.deinit();
        propName("Prototype");
        const lifo = dvui.currentWindow().lifo();
        const names = try lifo.alloc([]const u8, state.model.prototypes.items.len);
        defer lifo.free(names);
        for (state.model.prototypes.items, names) |p, *nm| nm.* = p.name;
        var choice: usize = t.prototype;
        if (dvui.dropdown(@src(), names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal }) and choice != t.prototype) {
            try act(.setTilePrototype, .{id, @intCast(choice)});
        }
    }

    for (0..state.model.slotCount(id)) |si| {
        const slot = state.model.slot(id, si);
        const n = 100 + si * 10;
        heading("Slot {s}", .{slot.name}, n);
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n + 1 });
            defer row.deinit();
            dvui.labelNoFmt(@src(), "Legend", .{}, .{ .min_size_content = .{ .w = label_width }, .gravity_y = 0.5, .color_text = .{ .color = dvui.themeGet().color(.control, .text).opacity(0.65) } });
            var te = dvui.textEntry(@src(), .{ .text_initial = slot.content }, .{
                .expand = .horizontal,
                .id_extra = @backingInt(id) * 16 + si,
            });
            if (te.data().id != dvui.focusedWidgetId() and !std.mem.eql(u8, te.textGet(), slot.content)) te.textSet(slot.content, false);
            const changed = te.text_changed;
            const text = te.textGet();
            te.deinit();
            if (changed and !std.mem.eql(u8, text, slot.content)) try actM(mergeKey(.{ "slot", id, si }), .setContent, .{ id, slot.name, text });
        }
        // Style and placement: the prototype's, or the tile's own.
        const own = state.model.fillConst(id, slot.name);
        const proto_slot = state.model.prototypeOf(id).slots[si];
        if (styleChoice(if (own) |f| f.style else null, proto_slot.style, n + 2)) |c| try act(.setSlotStyle, .{id, slot.name, c});
        try propFont("Font", n + 3);
        {
            var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n + 5 });
            defer row.deinit();
            propName("Placement");
            const names = [_][]const u8{ "Prototype's", "This tile's" };
            const has_own = own != null and own.?.place != null;
            var choice: usize = if (has_own) 1 else 0;
            if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .id_extra = n + 5 })) {
                try act(.setSlotPlace, .{id, slot.name, if (choice == 1) slot.place else null});
            }
        }
        if (own != null and own.?.place != null) {
            if (slotPlaceEditor(slot.place, 1000 + n * 10)) |p| try act(.setSlotPlace, .{id, slot.name, p});
        }
        if (found) |f| {
            for (state.placed.items[f.panel].issues, 0..) |i, k| if (i.tile == id and i.slot == si) {
                propText("Issue", "{s}", .{@tagName(i.kind)}, n + 4 + k);
            };
            for (state.intrusions) |i| if (i.tile == id and i.slot == si) {
                propText("Issue", "ink {d:.2} mm into the sheet margin", .{i.amount}, n + 9);
            };
        }
    }
}

/// A tile prototype: what its tiles share, and the parts of it that can be
/// changed here: where its labels go and how its art is painted. Its art's
/// outlines are left as drawn. Every tile made from it is outlined on the
/// canvas.
fn prototypeProperties(id: layout.model.PrototypeId) !void {
    const p = state.model.prototypes.items[id];
    // Whole-prototype changes go through one copy, set once at the end.
    var next_proto = p;
    var proto_changed = false;
    if (textProp("Name", p.name, 1)) |name| {
        next_proto.name = name;
        proto_changed = true;
    }
    propText("Used by", "{d} tiles", .{state.model.prototypeUses(id)}, 2);
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 3 });
        defer row.deinit();
        propName("Grows");
        if (dvui.checkbox(@src(), &next_proto.expand.horizontal, "Wider", .{ .id_extra = 3 })) proto_changed = true;
        if (dvui.checkbox(@src(), &next_proto.expand.vertical, "Taller", .{ .id_extra = 4 })) proto_changed = true;
    }
    {
        // How its tiles flow: a spacer (a blank, not in output), and
        // whether one is dropped where a soft break leaves it at a row's
        // start (a space between words) or kept (a keyboard's gap).
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 7 });
        defer row.deinit();
        propName("In the flow");
        if (dvui.checkbox(@src(), &next_proto.spacer, "Spacer", .{ .id_extra = 5 })) proto_changed = true;
        var drop = next_proto.at_soft_break == .drop;
        if (dvui.checkbox(@src(), &drop, "Dropped at a wrap", .{ .id_extra = 6 })) {
            next_proto.at_soft_break = if (drop) .drop else .keep;
            proto_changed = true;
        }
    }
    {
        // A letter binds to what follows it (an illuminated initial with
        // its word); with a baseline, it sits on the row's text baseline.
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 8 });
        defer row.deinit();
        propName("As a letter");
        if (dvui.checkbox(@src(), &next_proto.letter, "Binds to its word", .{ .id_extra = 8 })) proto_changed = true;
    }
    {
        var bbuf: [32]u8 = undefined;
        const shown = if (p.baseline) |b| std.fmt.bufPrint(&bbuf, "{d}", .{b}) catch "" else "any";
        if (sizesProp("Baseline, u up", shown, 9)) |list| if (list.len <= 1) {
            next_proto.baseline = if (list.len == 1) list[0] else null;
            proto_changed = true;
        };
    }
    var buf: [160]u8 = undefined;
    {
        // Its u in mm; empty follows the pitch of the track a tile is in.
        var ubuf: [32]u8 = undefined;
        const shown = if (p.unit) |u| std.fmt.bufPrint(&ubuf, "{d}", .{u}) catch "" else "any";
        if (sizesProp("Unit, mm per u", shown, 6)) |list| if (list.len <= 1) {
            next_proto.unit = if (list.len == 1) list[0] else null;
            proto_changed = true;
        };
    }
    if (p.expand.horizontal) if (sizesProp("Widths, u", sizeList(&buf, p.widths), 4)) |list| {
        next_proto.widths = list;
        proto_changed = true;
    };
    if (p.expand.vertical) if (sizesProp("Heights, u", sizeList(&buf, p.heights), 5)) |list| {
        next_proto.heights = list;
        proto_changed = true;
    };
    var insets_changed = false;
    if (sidesEditor("Body inset", p.body_inset, 10)) |s| {
        next_proto.body_inset = s;
        insets_changed = true;
    }
    if (sidesEditor("Face inset", p.face_inset, 20)) |s| {
        next_proto.face_inset = s;
        insets_changed = true;
    }
    if (insets_changed) {
        // A keycap's shape follows its insets; other art keeps its outlines
        // until redrawn.
        if (isKeycap(p.art)) next_proto.art = try layout.art.redrawKeycap(dvui.currentWindow().arena(), next_proto, protoUnit(next_proto));
        proto_changed = true;
    }
    if (proto_changed) {
        try act(.setPrototype, .{id, next_proto});
        return;
    }

    for (p.slots, 0..) |sp, si| {
        const n = 100 + si * 20;
        heading("Slot {s}", .{sp.name}, n);
        if (textProp("Name", sp.name, n * 8 + 7)) |name| {
            act(.renamePrototypeSlot, .{id, si, name}) catch {
                state.status = "Another slot has that name. ";
            };
            return;
        }
        var next = sp;
        var changed = false;
        if (styleChoice(sp.style, null, n + 1)) |c| {
            next.style = c.?;
            changed = true;
        }
        if (slotPlaceEditor(sp.place, n + 2)) |pl| {
            next.place = pl;
            changed = true;
        }
        if (changed) try act(.setPrototypeSlot, .{id, si, next});
        if (dvui.button(@src(), "Remove slot", .{}, .{ .id_extra = n, .gravity_x = 1 })) {
            try act(.removePrototypeSlot, .{id, si});
            return;
        }
    }
    if (dvui.button(@src(), "Add slot", .{}, .{ .id_extra = 590, .gravity_x = 1, .margin = .{ .y = 8 } })) {
        var name_buf: [32]u8 = undefined;
        var k: usize = p.slots.len + 1;
        const name = while (true) : (k += 1) {
            const candidate = std.fmt.bufPrint(&name_buf, "slot {d}", .{k}) catch "slot";
            const taken = for (p.slots) |s| {
                if (std.mem.eql(u8, s.name, candidate)) break true;
            } else false;
            if (!taken) break candidate;
        };
        try act(.addPrototypeSlot, .{id, .{ .name = name, .style = if (p.slots.len > 0) p.slots[0].style else 0, .place = .{ .inset = .all(0.8) } }});
        return;
    }

    heading("Art", .{}, 600);
    const art = p.art orelse {
        propText("Look", "plain, from the insets", .{}, 601);
        if (dvui.button(@src(), "Add keycap art", .{}, .{ .id_extra = 602, .gravity_x = 1 })) {
            try act(.setPrototypeArt, .{id, try layout.art.redrawKeycap(dvui.currentWindow().arena(), p, protoUnit(p))});
        }
        return;
    };
    for (art.layers, 0..) |layer, li| {
        const n = 700 + li * 20;
        heading("Layer {s}", .{layer.name}, n);
        if (paintEditor(layer.paint, n + 1)) |paint| try act(.setLayerPaint, .{id, li, paint});
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .gravity_x = 1, .id_extra = 690, .margin = .{ .y = 8 } });
        defer row.deinit();
        if (!isKeycap(p.art) and dvui.button(@src(), "Redraw from insets", .{}, .{ .id_extra = 691 })) {
            try act(.setPrototypeArt, .{id, try layout.art.redrawKeycap(dvui.currentWindow().arena(), p, protoUnit(p))});
        }
        if (dvui.button(@src(), "Remove art", .{}, .{ .id_extra = 692 })) try act(.setPrototypeArt, .{id, null});
    }
}

/// Whether `art` is a keycap's two layers, body and face, so it can be
/// redrawn from the insets without losing anything.
fn isKeycap(art: ?layout.art.Art) bool {
    const a = art orelse return false;
    return a.layers.len == 2 and std.mem.eql(u8, a.layers[0].name, "body") and std.mem.eql(u8, a.layers[1].name, "face");
}

/// A prototype's unit, mm per u, which its art is drawn for: 19.05 mm (a
/// keyboard's u) when it follows its tracks' pitch.
fn protoUnit(p: layout.model.TilePrototype) f64 {
    return p.unit orelse 19.05;
}

/// How a track holds its content: alignment in each row or column, the
/// indent after hard breaks, and the gap between rows the path makes.
fn trackFlowProperties(pi: usize, ri: usize) !void {
    const region = state.model.panels.items[pi].regions.items[ri];
    var alignment = region.alignment;
    var indent = region.indent;
    var gap = region.gap;
    var changed = false;
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = 20 });
        defer row.deinit();
        propName("Content");
        const names = [_][]const u8{ "From the start", "Centred", "Back from the end" };
        var choice: usize = @intFromEnum(alignment);
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .id_extra = 20 })) {
            alignment = @enumFromInt(choice);
            changed = true;
        }
    }
    var buf: [32]u8 = undefined;
    // Empty is none; one length each.
    if (sizesProp("Indent, u", if (indent > 0) std.fmt.bufPrint(&buf, "{d}", .{indent}) catch "" else "any", 21)) |list| if (list.len <= 1) {
        indent = if (list.len == 1) list[0] else 0;
        changed = true;
    };
    if (sizesProp(if (region.major == .row) "Row gap, u" else "Column gap, u", if (gap > 0) std.fmt.bufPrint(&buf, "{d}", .{gap}) catch "" else "any", 22)) |list| if (list.len <= 1) {
        gap = if (list.len == 1) list[0] else 0;
        changed = true;
    };
    if (changed) try act(.setTrackFlow, .{pi, ri, alignment, indent, gap});
}

/// A new plain prototype with one slot and keycap art, made the context.
fn addPrototype() !void {
    var name_buf: [32]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "Prototype {d}", .{state.model.prototypes.items.len + 1}) catch "Prototype";
    var p: layout.model.TilePrototype = .{
        .name = name,
        .unit = 19.05,
        .body_inset = .all(0.5),
        .face_inset = .all(2),
        .slots = &.{.{ .name = "top", .style = try labelStyle(), .place = .{ .inset = .all(0.8) } }},
    };
    p.art = try layout.art.redrawKeycap(dvui.currentWindow().arena(), p, protoUnit(p));
    const id = try act(.addPrototype, .{p});
    state.context = .{ .prototype = id };
}

fn duplicatePrototype(id: layout.model.PrototypeId) !void {
    var name_buf: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s} copy", .{state.model.prototypes.items[id].name}) catch "copy";
    state.context = .{ .prototype = try act(.duplicatePrototype, .{id, name}) };
}

/// An editable text property. Returns the new text when it changes; the
/// model copies it.
fn textProp(name: []const u8, value: []const u8, n: usize) ?[]const u8 {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n });
    defer row.deinit();
    propName(name);
    var te = dvui.textEntry(@src(), .{ .text_initial = value }, .{ .expand = .horizontal, .id_extra = n });
    defer te.deinit();
    if (te.data().id != dvui.focusedWidgetId() and !std.mem.eql(u8, te.textGet(), value)) te.textSet(value, false);
    if (!te.text_changed) return null;
    const text = std.mem.trim(u8, te.textGet(), " ");
    if (text.len == 0 or std.mem.eql(u8, text, value)) return null;
    return dvui.currentWindow().arena().dupe(u8, text) catch null;
}

/// A list of sizes typed as "1, 1.25, 2"; empty allows any. Returns the new
/// list once what is typed reads as one.
fn sizesProp(name: []const u8, shown: []const u8, n: usize) ?[]const f64 {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n });
    defer row.deinit();
    propName(name);
    // Shown without the unit, as typed.
    const value = if (std.mem.eql(u8, shown, "any")) "" else std.mem.trimEnd(u8, shown, " u");
    var te = dvui.textEntry(@src(), .{ .text_initial = value }, .{ .expand = .horizontal, .id_extra = n });
    defer te.deinit();
    if (te.data().id != dvui.focusedWidgetId() and !std.mem.eql(u8, te.textGet(), value)) te.textSet(value, false);
    if (!te.text_changed) return null;
    var list: std.ArrayList(f64) = .empty;
    var it = std.mem.tokenizeAny(u8, te.textGet(), ", ");
    while (it.next()) |tok| {
        const v = std.fmt.parseFloat(f64, tok) catch return null;
        if (!(v > 0)) return null;
        list.append(dvui.currentWindow().arena(), v) catch return null;
    }
    return list.items;
}

/// Four insets, left, right, top and bottom, mm. Returns them when one
/// changes.
fn sidesEditor(name: []const u8, sides: layout.model.Sides, n: usize) ?layout.model.Sides {
    var s = sides;
    var changed = false;
    var label_buf: [4][48]u8 = undefined;
    inline for (.{ "left", "right", "top", "bottom" }, 0..) |side, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n * 8 + i });
        defer row.deinit();
        propName(std.fmt.bufPrint(&label_buf[i], "{s} {s}, mm", .{ name, side }) catch name);
        const r = dvui.textEntryNumber(@src(), f64, .{ .value = &@field(s, side), .min = 0, .max = 100 }, .{ .expand = .horizontal, .id_extra = n * 8 + i });
        changed = r.changed or changed;
    }
    return if (changed) s else null;
}

/// "1, 1.25, 2 u", or "any" for an empty list.
fn sizeList(buf: []u8, sizes: []const f64) []const u8 {
    if (sizes.len == 0) return "any";
    var w: std.Io.Writer = .fixed(buf);
    for (sizes, 0..) |s, i| w.print("{s}{d}", .{ if (i > 0) ", " else "", s }) catch break;
    w.writeAll(" u") catch {};
    return w.buffered();
}

/// A style choice. With `inherited` (a tile's slot), the first entry takes
/// the prototype's style and `own` is the tile's, if any; without, `own` is
/// the style itself. Returns the choice when it changes: a style, or null
/// for the prototype's.
fn styleChoice(own: ?layout.model.StyleId, inherited: ?layout.model.StyleId, n: usize) ??layout.model.StyleId {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n });
    defer row.deinit();
    propName("Style");
    const styles = state.model.styles.items;
    if (styles.len == 0 or styles.len > 31) {
        dvui.labelNoFmt(@src(), "none", .{}, .{});
        return null;
    }
    var bufs: [32][64]u8 = undefined;
    var names: [32][]const u8 = undefined;
    const first: usize = if (inherited != null) 1 else 0;
    if (inherited) |s| names[0] = std.fmt.bufPrint(&bufs[0], "Prototype's: {s}", .{styles[s].name}) catch "Prototype's";
    for (styles, 0..) |s, i| names[first + i] = std.fmt.bufPrint(&bufs[first + i], "{s}", .{s.name}) catch "?";
    var choice: usize = if (own) |s| first + s else 0;
    const before = choice;
    if (!dvui.dropdown(@src(), names[0 .. first + styles.len], .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .id_extra = n }) or choice == before) return null;
    if (choice < first) return @as(?layout.model.StyleId, null);
    return @as(?layout.model.StyleId, @intCast(choice - first));
}

/// Edits a slot's place: its inset from the face on each side, and how the
/// label aligns across and down. Returns the new place when it changes.
fn slotPlaceEditor(place: layout.model.SlotPlace, n: usize) ?layout.model.SlotPlace {
    var p = place;
    var changed = false;
    inline for (.{ .{ "Inset left, mm", "left" }, .{ "Inset right, mm", "right" }, .{ "Inset top, mm", "top" }, .{ "Inset bottom, mm", "bottom" } }, 0..) |side, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n * 8 + i });
        defer row.deinit();
        propName(side[0]);
        const r = dvui.textEntryNumber(@src(), f64, .{ .value = &@field(p.inset, side[1]), .min = 0, .max = 100 }, .{ .expand = .horizontal, .id_extra = n * 8 + i });
        changed = r.changed or changed;
    }
    inline for (.{ .{ "Across", "h", [_][]const u8{ "Start", "Centre", "End" } }, .{ "Down", "v", [_][]const u8{ "Top", "Centre", "Bottom" } } }, 0..) |axis, i| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n * 8 + 4 + i });
        defer row.deinit();
        propName(axis[0]);
        var choice: usize = @backingInt(@field(p, axis[1]));
        const names = axis[2];
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .id_extra = n * 8 + 4 + i })) {
            @field(p, axis[1]) = @fromBackingInt(@intCast(choice));
            changed = true;
        }
    }
    return if (changed) p else null;
}

/// Edits how an art layer is painted: its fill's colours (one, or a
/// gradient's two ends) and its edge's colour and width. Returns the new
/// paint when it changes.
fn paintEditor(paint: layout.art.Paint, n: usize) ?layout.art.Paint {
    var p = paint;
    var changed = false;
    switch (p.fill) {
        .none => propText("Fill", "none", .{}, n),
        .solid => |c| if (colourEntry("Fill", c, false, n)) |v| {
            p.fill = .{ .solid = v.? };
            changed = true;
        },
        .linear => |l| {
            if (colourEntry("Gradient from", l.start, false, n)) |v| {
                p.fill.linear.start = v.?;
                changed = true;
            }
            if (colourEntry("Gradient to", l.end, false, n + 1)) |v| {
                p.fill.linear.end = v.?;
                changed = true;
            }
        },
    }
    if (colourEntry("Edge", p.edge, true, n + 2)) |v| {
        p.edge = v;
        changed = true;
    }
    if (p.edge != null) {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n + 3 });
        defer row.deinit();
        propName("Edge width, mm");
        const r = dvui.textEntryNumber(@src(), f64, .{ .value = &p.edge_width, .min = 0, .max = 5 }, .{ .expand = .horizontal, .id_extra = n + 3 });
        changed = r.changed or changed;
    }
    return if (changed) p else null;
}

/// A colour as "#rrggbb", with a swatch. Returns a new colour once what is
/// typed is one, or null (`allow_none`, emptied) for no colour.
fn colourEntry(name: []const u8, colour: ?layout.art.Color, allow_none: bool, n: usize) ??layout.art.Color {
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n });
    defer row.deinit();
    propName(name);
    var swatch = dvui.box(@src(), .{}, .{
        .min_size_content = .{ .w = 16, .h = 16 },
        .gravity_y = 0.5,
        .margin = .{ .w = 6 },
        .border = .all(1),
        .background = colour != null,
        .color_fill = if (colour) |c| .{ .color = .{ .r = c.r, .g = c.g, .b = c.b, .a = c.a } } else null,
    });
    swatch.deinit();
    var buf: [7]u8 = undefined;
    const text: []const u8 = if (colour) |c| c.format(&buf) else "";
    var te = dvui.textEntry(@src(), .{ .text_initial = text }, .{ .expand = .horizontal, .font = .theme(.mono), .id_extra = n });
    defer te.deinit();
    if (te.data().id != dvui.focusedWidgetId() and !std.mem.eql(u8, te.textGet(), text)) te.textSet(text, false);
    if (!te.text_changed) return null;
    const typed = std.mem.trim(u8, te.textGet(), " ");
    if (typed.len == 0) return if (allow_none and colour != null) @as(?layout.art.Color, null) else null;
    const c = layout.art.Color.parse(typed) orelse return null;
    if (colour != null and std.meta.eql(c, colour.?)) return null;
    return @as(?layout.art.Color, c);
}

/// A tile's width or height: a choice of the sizes its prototype allows
/// along that axis, a fixed 1 u where it may not grow, or the value alone
/// where any size goes. A size outside the rules stays listed, marked.
fn sizeProperty(id: TileId, axis: enum { horizontal, vertical }) !void {
    const t = state.model.tileConst(id);
    const proto = state.model.prototypeOf(id);
    const horizontal = axis == .horizontal;
    const name = if (horizontal) "Width" else "Height";
    const size = if (horizontal) t.w else t.h;
    const grows = if (horizontal) proto.expand.horizontal else proto.expand.vertical;
    const sizes = if (horizontal) proto.widths else proto.heights;
    const n: usize = if (horizontal) 2 else 7;
    if (grows and sizes.len == 0) {
        // Any size goes: typed.
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n });
        defer row.deinit();
        propName(if (horizontal) "Width, u" else "Height, u");
        var v = size;
        const r = dvui.textEntryNumber(@src(), f64, .{ .value = &v, .min = 0.25, .max = 100 }, .{ .expand = .horizontal, .id_extra = n });
        if (r.changed and v > 0) {
            if (horizontal) try act(.setTileSize, .{id, v, t.h}) else try act(.setTileSize, .{id, t.w, v});
        }
        return;
    }
    if (!grows or sizes.len > 15) {
        const ok = proto.allows(if (horizontal) size else 1, if (horizontal) 1 else size);
        propText(name, "{d} u{s}", .{ size, if (!grows and ok) " (fixed)" else if (!ok) " (not allowed)" else "" }, n);
        return;
    }
    var bufs: [16][32]u8 = undefined;
    var names: [16][]const u8 = undefined;
    var choice: ?usize = null;
    for (sizes, 0..) |s, i| {
        names[i] = std.fmt.bufPrint(&bufs[i], "{d} u", .{s}) catch "?";
        if (@abs(s - size) <= 1e-9) choice = i;
    }
    var listed = sizes.len;
    if (choice == null) {
        names[listed] = std.fmt.bufPrint(&bufs[listed], "{d} u (not allowed)", .{size}) catch "?";
        choice = listed;
        listed += 1;
    }
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = n });
    defer row.deinit();
    propName(name);
    var picked = choice.?;
    if (dvui.dropdown(@src(), names[0..listed], .{ .choice = &picked }, .{}, .{ .expand = .horizontal }) and picked < sizes.len) {
        if (horizontal) try act(.setTileSize, .{id, sizes[picked], t.h}) else try act(.setTileSize, .{id, t.w, sizes[picked]});
    }
}

/// The status line's fields, each always in the same place so nothing
/// jumps as values come and go: the pointer position (a dash off the
/// sheet), the counts, any tool hint or message, then the font and zoom.
fn statusContent() void {
    var tiles: usize = 0;
    var labels: usize = 0;
    var missing: usize = 0;
    var overflow: usize = 0;
    for (state.placed.items) |*p| {
        tiles += p.tiles.len;
        labels += p.labels.len;
        for (p.issues) |i| switch (i.kind) {
            .missing_glyph => missing += 1,
            .label_overflow, .row_overflow, .region_outside => overflow += 1,
            else => {},
        };
    }
    const field: dvui.Options = .{ .gravity_y = 0.5, .padding = .{ .x = 8, .w = 8, .y = 2, .h = 2 } };
    const muted: dvui.Options = .{ .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.65) } };

    var pos_buf: [64]u8 = undefined;
    const u = docUnits();
    const pos = if (state.mouse) |m_sheet| blk: {
        // Shown as the rulers count: from the ruler origin (a canvas's own).
        const m = if (openCanvas()) m_sheet else state.model.sheet.toRuler(m_sheet);
        const k = u.perMm();
        break :blk switch (u) {
            .mm => std.fmt.bufPrint(&pos_buf, "x {d:.2}   y {d:.2} mm", .{ m.x * k, m.y * k }),
            .inch => std.fmt.bufPrint(&pos_buf, "x {d:.3}   y {d:.3} in", .{ m.x * k, m.y * k }),
            .mil => std.fmt.bufPrint(&pos_buf, "x {d:.0}   y {d:.0} mil", .{ m.x * k, m.y * k }),
        } catch "";
    } else std.fmt.bufPrint(&pos_buf, "x –   y – {s}", .{u.symbol()}) catch "";
    dvui.labelNoFmt(@src(), pos, .{}, field.override(.{ .min_size_content = .{ .w = 190 }, .font = .theme(.mono) }));

    var counts_buf: [200]u8 = undefined;
    var flags_buf: [40]u8 = undefined;
    const layer_flags = if (state.layer_issues.len > 0) std.fmt.bufPrint(&flags_buf, " · {d} layer flag{s}", .{ state.layer_issues.len, if (state.layer_issues.len == 1) "" else "s" }) catch "" else "";
    const counts = std.fmt.bufPrint(&counts_buf, "{d} panels ({d} out of compliance) · {d} tiles · {d} labels · {d} missing glyphs · {d} overflows · {d} in margins{s}", .{
        state.model.panels.items.len - state.model.spaces.items.len, state.panel_issues.len, tiles, labels, missing, overflow, state.intrusions.len, layer_flags,
    }) catch "";
    dvui.labelNoFmt(@src(), counts, .{}, field);

    const hint = switch (state.tool) {
        .select => state.status,
        .add_panel => "Add panel: drag out its outline · Esc cancels",
        .add_label => "Add label: click on the panel to place it · Esc cancels",
        .add_art => if (shape_kind == .polygon) "Add polygon: click each corner; click the first again, or Enter, to close · Esc cancels" else "Add shape: drag out its box · Esc cancels",
        .select_area => "Select area: drag around the objects to pick · Esc cancels",
        .add_tracks => if (tracks_tool.major == .row) "Add rows: drag them out on the panel · Esc cancels" else "Add columns: drag them out on the panel · Esc cancels",
    };
    dvui.labelNoFmt(@src(), hint, .{}, field.override(.{ .expand = .horizontal }).override(muted));

    var right_buf: [160]u8 = undefined;
    const font = if (state.fonts.len > 0) state.fonts[state.font_choice].name else "-";
    const right = std.fmt.bufPrint(&right_buf, "{s} · zoom {d:.2} px/mm · {d:.1} ms", .{ font, state.view.ppm, state.solve_ms }) catch "";
    dvui.labelNoFmt(@src(), right, .{}, field.override(muted));
}

// Populating tracks --------------------------------------------------------
//
// A track is one flow: tiles, blanks, runs of text or equations, and hard
// breaks, poured in order through its rows or columns. With a region as
// the context, a click in its tracks puts the flow cursor between items.
// Things go in at the cursor from the insert palette, or by its keys:
// digits for tiles, the row below them for blanks, A for text or an
// equation (typed in the expression line), Enter for a hard break.
// Backspace removes the item before the cursor, Delete the one after;
// arrows move it along the flow, or to the next row or column.

/// Where things go in: before item `index` of a track's flow.
const TrackCursor = struct { panel: usize, region: usize, index: usize };
var track_cursor: ?TrackCursor = null;
/// The canvas, and the palette's buttons, from the last frame: the
/// cursor's keys work while one of them has the keyboard.
var canvas_id: ?dvui.Id = null;
var palette_ids: [24]dvui.Id = undefined;
var palette_id_count: usize = 0;
const palette_height = 212;
const move_palette_height = 124;
/// How opaque the palette and its buttons are over the canvas.
const palette_alpha = 0.6;
const palette_button_alpha = 0.45;

const tile_keys = "1234567890";

/// The prototype the insert palette's tile row inserts, once switched with
/// Tab; null for the track's own.
var palette_prototype: ?layout.model.PrototypeId = null;

/// Switches the palette's tile row to the next (or previous) prototype that
/// is not a spacer.
fn cyclePalettePrototype(back: bool) void {
    const c = track_cursor orelse return;
    const pal = paletteFor(c.panel, c.region) orelse return;
    const protos = state.model.prototypes.items;
    var id = pal.prototype;
    for (0..protos.len) |_| {
        id = if (back) (if (id == 0) @intCast(protos.len - 1) else id - 1) else @intCast((id + 1) % protos.len);
        if (!protos[id].spacer) break;
    }
    palette_prototype = id;
}
const blank_keys = "QWERTYUIOP";

/// The palette's choices for a region: tile lengths along its tracks (the
/// prototype's allowed sizes, or its steps from the smallest) and blank
/// lengths (multiples of its step), ten of each at most.
const InsertPalette = struct {
    prototype: layout.model.PrototypeId,
    tiles: [10]f64 = undefined,
    tile_count: usize = 0,
    blanks: [10]f64 = undefined,
};

fn paletteFor(panel: usize, region: usize) ?InsertPalette {
    if (state.model.prototypes.items.len == 0) return null;
    const r = state.model.panels.items[panel].regions.items[region];
    // The prototype the tile row inserts: the one chosen with Tab, else the
    // track's own.
    const own = r.prototype orelse 0;
    const id = if (palette_prototype) |pp| (if (pp < state.model.prototypes.items.len and !state.model.prototypes.items[pp].spacer) pp else own) else own;
    const p = state.model.prototypes.items[id];
    var out: InsertPalette = .{ .prototype = id };
    const sizes = if (r.major == .row) p.widths else p.heights;
    const grows = if (r.major == .row) p.expand.horizontal else p.expand.vertical;
    const step_ = p.step(r.major, .along);
    if (grows and sizes.len > 0) {
        out.tile_count = @min(10, sizes.len);
        @memcpy(out.tiles[0..out.tile_count], sizes[0..out.tile_count]);
    } else if (grows) {
        const smallest = p.smallest(r.major, .along);
        out.tile_count = 10;
        for (&out.tiles, 0..) |*t, k| t.* = smallest + @as(f64, @floatFromInt(k)) * step_;
    } else {
        out.tile_count = 1;
        out.tiles[0] = 1;
    }
    for (&out.blanks, 1..) |*b, k| b.* = @as(f64, @floatFromInt(k)) * step_;
    return out;
}

/// The region the context is, which the flow cursor belongs to. A track
/// as the context is for moving it, not filling it.
fn contextRegion() ?struct { panel: usize, region: usize } {
    return switch (state.context) {
        .region => |r| .{ .panel = r.panel, .region = r.region },
        else => null,
    };
}

/// The item of a region's flow that a click `along` mm into segment `seg`
/// goes before: the first in that segment whose middle lies beyond it, else
/// the segment's hard break (the end of its line), else past its last item.
fn indexAt(pi: usize, region: usize, seg: usize, along: f64) usize {
    const r = state.model.panels.items[pi].regions.items[region];
    var after: ?usize = null;
    for (state.placed.items[pi].items) |it| {
        if (it.region != region or it.segment != seg) continue;
        if (isBreak(pi, it)) return it.index;
        if ((it.span[0] + it.span[1]) / 2 > along) return it.index;
        after = it.index + 1;
    }
    return after orelse r.items.items.len;
}

/// How many rows or columns a track's flow reached in the last solve.
fn segmentCount(pi: usize, region: usize) usize {
    if (pi >= state.placed.items.len) return 0;
    for (state.placed.items[pi].flows) |f| if (f.region == region) return f.segments;
    return 0;
}

/// Where row or column `t` of a track's path lies, from the last solve.
fn segmentOrigin(pi: usize, region: usize, t: usize) ?layout.model.Segment {
    if (pi >= state.placed.items.len) return null;
    for (state.placed.items[pi].tracks) |tr| if (tr.region == region and tr.track == t) return tr.origin;
    return null;
}

/// The model's item for a placed one, while the model still has it: the
/// placement is from the last solve, and an edit since may have removed it.
fn modelItem(pi: usize, it: layout.place.PlacedItem) ?layout.model.Item {
    if (pi >= state.model.panels.items.len) return null;
    const regions = state.model.panels.items[pi].regions.items;
    if (it.region >= regions.len or it.index >= regions[it.region].items.items.len) return null;
    return regions[it.region].items.items[it.index];
}

fn isBreak(pi: usize, it: layout.place.PlacedItem) bool {
    const item = modelItem(pi, it) orelse return false;
    return item.what == .hard_break;
}

/// The cursor a click at worksheet point `at` puts in the context region's
/// tracks: in the row or column under it, between the items either side.
fn cursorAt(at: geom.Point) ?TrackCursor {
    const cr = contextRegion() orelse return null;
    if (cr.panel >= state.placed.items.len) return null;
    for (state.placed.items[cr.panel].tracks) |t| {
        if (t.region != cr.region) continue;
        const b = onSheet(cr.panel, t.box);
        if (!contains(b, at)) continue;
        const along = if (t.major == .row) at.x - b.x0 else b.y1 - at.y;
        return .{ .panel = cr.panel, .region = cr.region, .index = indexAt(cr.panel, cr.region, t.track, along) };
    }
    return null;
}

/// Where the cursor shows: the segment and the distance along it, mm.
fn cursorPlace(c: TrackCursor) ?struct { segment: usize, along: f64 } {
    if (c.panel >= state.placed.items.len) return null;
    var prev: ?layout.place.PlacedItem = null;
    var here: ?layout.place.PlacedItem = null;
    for (state.placed.items[c.panel].items) |it| {
        if (it.region != c.region) continue;
        // A run set word by word has several pieces: the cursor goes after
        // the last of the item before it, before the first of its own.
        if (it.index + 1 == c.index) prev = it;
        if (it.index == c.index and here == null) here = it;
    }
    // After a hard break: the start of the next segment.
    if (prev) |p| if (isBreak(c.panel, p)) {
        const seg = if (here) |h| h.segment else @min(p.segment + 1, @max(1, segmentCount(c.panel, c.region)) - 1);
        return .{ .segment = seg, .along = 0 };
    };
    if (here) |h| {
        if (prev) |p| if (p.segment == h.segment) return .{ .segment = h.segment, .along = (p.span[1] + h.span[0]) / 2 };
        return .{ .segment = h.segment, .along = h.span[0] };
    }
    if (prev) |p| return .{ .segment = p.segment, .along = p.span[1] };
    return .{ .segment = 0, .along = 0 };
}

/// The run of text or an equation the expression line edits while the
/// cursor is in a track: the one just before the cursor, else the one just
/// after it.
fn runAtCursor() ?struct { panel: usize, region: usize, item: usize } {
    const c = track_cursor orelse return null;
    const items = state.model.panels.items[c.panel].regions.items[c.region].items.items;
    if (c.index > 0 and c.index <= items.len and items[c.index - 1].what == .run) return .{ .panel = c.panel, .region = c.region, .item = c.index - 1 };
    if (c.index < items.len and items[c.index].what == .run) return .{ .panel = c.panel, .region = c.region, .item = c.index };
    return null;
}

/// Fits a region's rows or columns to their content: as long as its
/// longest paragraph needs, from the last solve. Whether it changed.
fn fitRegion(pi: usize, region: usize) bool {
    if (pi >= state.placed.items.len) return false;
    for (state.placed.items[pi].flows) |f| {
        if (f.region != region) continue;
        const r = state.model.panels.items[pi].regions.items[region];
        if (!(f.natural > 0) or @abs(f.natural - r.segmentLength()) < 1e-9) return false;
        act(.setSegmentLength, .{pi, region, f.natural}) catch return false;
        return true;
    }
    return false;
}

/// Drops the cursor when its region stops being the context, and keeps it
/// within the flow as items come and go.
fn validateCursor() void {
    // Out of the flow, the palette goes back to each track's own prototype.
    const c = track_cursor orelse {
        palette_prototype = null;
        return;
    };
    const cr = contextRegion() orelse {
        track_cursor = null;
        return;
    };
    if (cr.panel != c.panel or cr.region != c.region or c.panel >= state.model.panels.items.len) {
        track_cursor = null;
        return;
    }
    const r = state.model.panels.items[c.panel].regions.items[c.region];
    if (r.segments.items.len == 0) {
        track_cursor = null;
        return;
    }
    track_cursor.?.index = @min(c.index, r.items.items.len);
}

fn cursorKeysReach() bool {
    const focused = dvui.focusedWidgetId() orelse return true;
    if (canvas_id != null and focused == canvas_id.?) return true;
    for (palette_ids[0..palette_id_count]) |id| if (id == focused) return true;
    return false;
}

/// Acts on a key for the flow cursor; whether it was one.
fn cursorKey(code: dvui.enums.Key) bool {
    const c = track_cursor orelse return false;
    const tile_codes = [_]dvui.enums.Key{ .one, .two, .three, .four, .five, .six, .seven, .eight, .nine, .zero };
    const blank_codes = [_]dvui.enums.Key{ .q, .w, .e, .r, .t, .y, .u, .i, .o, .p };
    const pal = paletteFor(c.panel, c.region) orelse return false;
    for (tile_codes, 0..) |k, i| if (code == k) {
        if (i < pal.tile_count) insertAtCursor(.tile, pal.tiles[i]);
        return true;
    };
    for (blank_codes, 0..) |k, i| if (code == k) {
        insertAtCursor(.blank, pal.blanks[i]);
        return true;
    };
    const region = state.model.panels.items[c.panel].regions.items[c.region];
    const len = region.items.items.len;
    const rows = region.major == .row;
    var next = c;
    switch (code) {
        .a => {
            insertAtCursor(.run, 0);
            return true;
        },
        .tab => {
            cyclePalettePrototype(false);
            return true;
        },
        .g => {
            toggleBindAtCursor();
            return true;
        },
        .enter, .kp_enter => {
            insertAtCursor(.hard_break, 0);
            return true;
        },
        .backspace => {
            if (c.index == 0) return true;
            act(.removeAt, .{c.panel, c.region, c.index - 1}) catch {};
            next.index -= 1;
        },
        .delete => if (c.index < len) act(.removeAt, .{c.panel, c.region, c.index}) catch {},
        .escape => {
            track_cursor = null;
            return true;
        },
        .left, .right, .up, .down => {
            const forward = code == .right or code == .down;
            const along_key = if (rows) code == .left or code == .right else code == .up or code == .down;
            if (along_key) {
                if (forward and c.index < len) next.index += 1;
                if (!forward and c.index > 0) next.index -= 1;
            } else if (cursorPlace(c)) |at| {
                // To the nearest place in the next or previous segment.
                const segs = segmentCount(c.panel, c.region);
                if (forward and at.segment + 1 < segs) next.index = indexAt(c.panel, c.region, at.segment + 1, at.along);
                if (!forward and at.segment > 0) next.index = indexAt(c.panel, c.region, at.segment - 1, at.along);
            }
        },
        else => return false,
    }
    track_cursor = next;
    validateCursor();
    return true;
}

/// Inserts at the cursor, which moves past it: a tile or a blank `size` u
/// long, a hard break, or an empty run of markup, whose text the expression
/// line then takes.
fn insertAtCursor(kind: enum { tile, blank, run, hard_break }, size: f64) void {
    const c = track_cursor orelse return;
    const pal = paletteFor(c.panel, c.region) orelse return;
    switch (kind) {
        .tile => _ = act(.insertTile, .{c.panel, c.region, c.index, pal.prototype, size}) catch return,
        .blank => {
            // The palette's blanks are in the prototype's u, as its tiles
            // are; a blank is stored in its track's unit.
            const r = state.model.panels.items[c.panel].regions.items[c.region];
            const unit = state.model.prototypes.items[pal.prototype].unitIn(r.pitch);
            _ = act(.insertBlank, .{c.panel, c.region, c.index, size * unit / r.pitch}) catch return;
        },
        .hard_break => {
            // With the track's indent, a blank follows: the cursor goes past
            // it, to where the new paragraph's content starts.
            const n = act(.insertBreak, .{c.panel, c.region, c.index}) catch return;
            track_cursor.?.index += n;
            return;
        },
        .run => {
            const style = state.model.panels.items[c.panel].regions.items[c.region].style orelse (labelStyle() catch return);
            act(.insertRun, .{c.panel, c.region, c.index, .{ .style = style, .content = "" }}) catch return;
            focus_expression = true;
        },
    }
    track_cursor.?.index += 1;
}

/// Joins the items either side of the cursor into one group, or parts them:
/// a group breaks as one.
fn toggleBindAtCursor() void {
    const c = track_cursor orelse return;
    const items = state.model.panels.items[c.panel].regions.items[c.region].items.items;
    if (c.index == 0 or c.index >= items.len) {
        state.status = "Put the cursor between two items to join or part them. ";
        return;
    }
    const before = items[c.index - 1];
    if (before.what == .hard_break or items[c.index].what == .hard_break) {
        state.status = "A hard break cannot be part of a group. ";
        return;
    }
    act(.setBind, .{c.panel, c.region, c.index - 1, !before.bind}) catch return;
    state.status = if (before.bind) "Parted: a break may fall here. " else "Joined: no break falls here. ";
}

/// Set when a new run wants the expression line to take the keyboard.
var focus_expression = false;
/// With it, the cursor goes to the end of what is there (a label begun by
/// typing).
var focus_expression_end = false;

/// The cursor: a bar across its row or column between items.
fn drawCursor(area: dvui.Rect.Physical, pi: usize, placed: *const layout.place.Placed, c: TrackCursor) void {
    const at = cursorPlace(c) orelse return;
    for (placed.tracks) |t| {
        if (t.region != c.region or t.track != at.segment) continue;
        const pos = at.along;
        const b = onSheet(pi, t.box);
        const px = dvui.windowNaturalScale();
        // The cursor pulses: it is where typing goes.
        const focus = colors.select.opacity(pulse());
        // The segment, faintly, then the bar a little past its edges.
        state.view.rect(area, b).fill(.square, .{ .color = .{ .color = focus.opacity(0.06) } });
        const over = 1.0;
        const p0: geom.Point = if (t.major == .row) .{ .x = b.x0 + pos, .y = b.y0 - over } else .{ .x = b.x0 - over, .y = b.y1 - pos };
        const p1: geom.Point = if (t.major == .row) .{ .x = b.x0 + pos, .y = b.y1 + over } else .{ .x = b.x1 + over, .y = b.y1 - pos };
        dvui.Path.stroke(.{ .points = &.{ state.view.toPx(area, p0), state.view.toPx(area, p1) } }, .{ .thickness = 3 * px, .color = .{ .color = focus } });
        return;
    }
}

/// A box outlined in dashes, about 2 mm long, on the worksheet.
/// The active selection's outline: dashes that march round box `b`,
/// fixed in screen size whatever the zoom. Keeps the canvas redrawing
/// while it shows.
fn marchingBox(area: dvui.Rect.Physical, b: geom.Box, colour: dvui.Color, width: f32) void {
    const ns = dvui.windowNaturalScale();
    const r = state.view.rect(area, b);
    const pts = [_]dvui.Point.Physical{ .{ .x = r.x, .y = r.y }, .{ .x = r.x + r.w, .y = r.y }, .{ .x = r.x + r.w, .y = r.y + r.h }, .{ .x = r.x, .y = r.y + r.h } };
    const dash: f32 = 6 * ns;
    const phase: f32 = @floatCast(@mod(@as(f64, @floatFromInt(@divTrunc(dvui.frameTimeNS(), std.time.ns_per_ms))) * 0.03 * ns, 2 * dash));
    // Under the dashes, a faint solid line, so the box reads between them.
    r.stroke(.square, .{ .thickness = width, .color = .{ .color = colour.opacity(0.25) } });
    var walked: f32 = -phase;
    for (0..4) |i| {
        const a = pts[i];
        const z = pts[(i + 1) % 4];
        const len = @sqrt((z.x - a.x) * (z.x - a.x) + (z.y - a.y) * (z.y - a.y));
        if (len <= 0) continue;
        // Dashes start every 2·dash along the whole perimeter.
        var d: f32 = @mod(-walked, 2 * dash);
        if (d > dash) d -= 2 * dash;
        while (d < len) : (d += 2 * dash) {
            const s0 = @max(0, d);
            const s1 = @min(len, d + dash);
            if (s1 <= s0) continue;
            const p0: dvui.Point.Physical = .{ .x = a.x + (z.x - a.x) * s0 / len, .y = a.y + (z.y - a.y) * s0 / len };
            const p1: dvui.Point.Physical = .{ .x = a.x + (z.x - a.x) * s1 / len, .y = a.y + (z.y - a.y) * s1 / len };
            dvui.Path.stroke(.{ .points = &.{ p0, p1 } }, .{ .thickness = width, .color = .{ .color = colour } });
        }
        walked += len;
    }
    animate();
}

/// How strongly the flow cursor shows now, 0.55 to 1: a slow pulse.
fn pulse() f32 {
    animate();
    const t: f64 = @as(f64, @floatFromInt(@divTrunc(dvui.frameTimeNS(), std.time.ns_per_ms))) / 1000;
    return @floatCast(0.775 + 0.225 * @sin(t * 2 * std.math.pi / 1.4));
}

/// Keeps the canvas redrawing about 25 times a second while something on
/// it moves.
fn animate() void {
    const id = canvas_id orelse return;
    if (dvui.timerDoneOrNone(id)) dvui.timer(id, 40_000);
}

fn dashedBox(area: dvui.Rect.Physical, b: geom.Box, colour: dvui.Color, px: f32) void {
    const corners = [_]geom.Point{ .{ .x = b.x0, .y = b.y1 }, .{ .x = b.x1, .y = b.y1 }, .{ .x = b.x1, .y = b.y0 }, .{ .x = b.x0, .y = b.y0 } };
    const dash = 2.0;
    for (0..4) |i| {
        const a = corners[i];
        const z = corners[(i + 1) % 4];
        const len = @sqrt((z.x - a.x) * (z.x - a.x) + (z.y - a.y) * (z.y - a.y));
        if (len <= 0) continue;
        var d: f64 = 0;
        while (d < len) : (d += 2 * dash) {
            const e = @min(len, d + dash);
            const p0: geom.Point = .{ .x = a.x + (z.x - a.x) * d / len, .y = a.y + (z.y - a.y) * d / len };
            const p1: geom.Point = .{ .x = a.x + (z.x - a.x) * e / len, .y = a.y + (z.y - a.y) * e / len };
            dvui.Path.stroke(.{ .points = &.{ state.view.toPx(area, p0), state.view.toPx(area, p1) } }, .{ .thickness = px, .color = .{ .color = colour } });
        }
    }
}

/// What the flow holds that output leaves out, drawn faintly while editing:
/// each hard break as a down-and-left arrow (a carriage return) at the end
/// of its segment's content, and each empty run as a dashed slot.
fn drawFlowMarks(area: dvui.Rect.Physical, pi: usize, placed: *const layout.place.Placed) void {
    const px = dvui.windowNaturalScale();
    const ghost = colors.guide.opacity(0.55);
    // Groups: a tie along the foot of the row (or the side of the column)
    // from each item to the next one it is bound to.
    for (placed.items, 0..) |it, k| {
        const item = modelItem(pi, it) orelse continue;
        if (k + 1 >= placed.items.len) break;
        const nx = placed.items[k + 1];
        if (nx.region != it.region or nx.segment != it.segment) continue;
        _ = modelItem(pi, nx) orelse continue;
        _ = item;
        const r = state.model.panels.items[pi].regions.items[it.region];
        // Bound by hand, or a letter tile to its word.
        if (nx.index != it.index + 1 or !state.model.bound(r.items.items, it.index)) continue;
        const band = for (placed.tracks) |t| {
            if (t.region == it.region and t.track == it.segment) break onSheet(pi, t.box);
        } else continue;
        const a_mid = (it.span[0] + it.span[1]) / 2;
        const b_mid = (nx.span[0] + nx.span[1]) / 2;
        const inset = r.pitch * 0.08;
        const p0: geom.Point = if (r.major == .row) .{ .x = band.x0 + a_mid, .y = band.y0 + inset } else .{ .x = band.x1 - inset, .y = band.y1 - a_mid };
        const p1: geom.Point = if (r.major == .row) .{ .x = band.x0 + b_mid, .y = band.y0 + inset } else .{ .x = band.x1 - inset, .y = band.y1 - b_mid };
        dvui.Path.stroke(.{ .points = &.{ state.view.toPx(area, p0), state.view.toPx(area, p1) } }, .{ .thickness = 2 * px, .color = .{ .color = colors.select.opacity(0.7) } });
    }
    for (placed.items) |it| {
        const what = (modelItem(pi, it) orelse continue).what;
        const r = state.model.panels.items[pi].regions.items[it.region];
        if (what != .hard_break and !(what == .run and what.run.content.len == 0)) continue;
        const band = for (placed.tracks) |t| {
            if (t.region == it.region and t.track == it.segment) break onSheet(pi, t.box);
        } else continue;
        const rows = r.major == .row;
        if (what == .run) {
            const box: geom.Box = if (rows)
                .{ .x0 = band.x0 + it.span[0], .x1 = band.x0 + it.span[1], .y0 = band.y0 + r.pitch * 0.2, .y1 = band.y1 - r.pitch * 0.2 }
            else
                .{ .x0 = band.x0 + r.pitch * 0.2, .x1 = band.x1 - r.pitch * 0.2, .y1 = band.y1 - it.span[0], .y0 = band.y1 - it.span[1] };
            state.view.rect(area, box).stroke(.square, .{ .thickness = px, .color = .{ .color = ghost } });
            continue;
        }
        // The arrow, about a third of a unit, just past the content: down
        // from the top, then left, with a head.
        const u = r.pitch * 0.32;
        const x0 = if (rows) band.x0 + it.span[0] + u * 0.4 else (band.x0 + band.x1) / 2 - u / 2;
        const ytop = if (rows) (band.y0 + band.y1) / 2 + u / 2 else band.y1 - it.span[0] - u * 0.4;
        const right = x0 + u;
        const low = ytop - u;
        const pts = [_]geom.Point{ .{ .x = right, .y = ytop }, .{ .x = right, .y = low }, .{ .x = x0, .y = low } };
        var phys: [3]dvui.Point.Physical = undefined;
        for (pts, &phys) |q, *o| o.* = state.view.toPx(area, q);
        dvui.Path.stroke(.{ .points = &phys }, .{ .thickness = 1.5 * px, .color = .{ .color = ghost } });
        const h = u * 0.3;
        const head = [_]geom.Point{ .{ .x = x0 + h, .y = low + h }, .{ .x = x0, .y = low }, .{ .x = x0 + h, .y = low - h } };
        var hp: [3]dvui.Point.Physical = undefined;
        for (head, &hp) |q, *o| o.* = state.view.toPx(area, q);
        dvui.Path.stroke(.{ .points = &hp }, .{ .thickness = 1.5 * px, .color = .{ .color = ghost } });
    }
}

/// The insert palette: a row of tile buttons and a row of blank buttons,
/// each drawn to scale, with its key and its size. A click inserts at the
/// cursor, as the key does.
fn trackPalette() void {
    palette_id_count = 0;
    const c = track_cursor orelse return;
    const pal = paletteFor(c.panel, c.region) orelse return;
    const name = state.model.prototypes.items[pal.prototype].name;
    dvui.label(@src(), "Insert {s} tiles, blanks, text or equations, and breaks at the cursor · Backspace and Delete remove · arrows move · Esc ends", .{name}, .{ .font = dvui.Font.theme(.body).larger(-2), .padding = .{ .x = 6, .y = 2, .h = 2 } });
    inline for (.{ .tile, .blank }) |kind| {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .id_extra = @backingInt(@as(enum { tile, blank }, kind)) });
        defer row.deinit();
        const keys = if (kind == .tile) tile_keys else blank_keys;
        const n = if (kind == .tile) pal.tile_count else pal.blanks.len;
        for (0..n) |i| {
            const size = if (kind == .tile) pal.tiles[i] else pal.blanks[i];
            if (paletteButton(kind == .tile, keys[i], size, i)) {
                insertAtCursor(if (kind == .tile) .tile else .blank, size);
                if (canvas_id) |id| dvui.focusWidget(id, null, null);
            }
        }
    }
    // The flow's other items: a run of text or an equation, and a hard break.
    var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
    defer row.deinit();
    if (flowButton(.run, 0)) insertAtCursor(.run, 0);
    if (flowButton(.join, 3)) {
        toggleBindAtCursor();
        if (canvas_id) |id| dvui.focusWidget(id, null, null);
    }
    if (flowButton(.next_prototype, 2)) {
        cyclePalettePrototype(false);
        if (canvas_id) |id| dvui.focusWidget(id, null, null);
    }
    if (flowButton(.hard_break, 1)) {
        insertAtCursor(.hard_break, 0);
        if (canvas_id) |id| dvui.focusWidget(id, null, null);
    }
}

/// A palette button for an item that is not a tile: its key, a picture and
/// what it puts in.
fn flowButton(kind: enum { run, hard_break, next_prototype, join }, i: usize) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = i,
        .margin = .all(2),
        .padding = .{ .x = 8, .w = 8, .y = 3, .h = 3 },
        .corners = .all(4),
        .color_fill = .{ .color = dvui.themeGet().color(.control, .fill).opacity(palette_button_alpha) },
    });
    bw.processEvents();
    bw.drawBackground();
    const clicked = bw.clicked();
    if (palette_id_count < palette_ids.len) {
        palette_ids[palette_id_count] = bw.data().id;
        palette_id_count += 1;
    }
    {
        var line = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer line.deinit();
        dvui.labelNoFmt(@src(), switch (kind) {
            .run => "A",
            .hard_break => "Enter",
            .next_prototype => "Tab",
            .join => "G",
        }, .{}, .{ .gravity_y = 0.5, .font = dvui.Font.theme(.mono).withWeight(.bold), .padding = .{ .w = 8 } });
        var pic = dvui.box(@src(), .{}, .{ .gravity_y = 0.5, .min_size_content = .{ .w = 22, .h = 18 }, .max_size_content = .{ .w = 22, .h = 18 } });
        const r = pic.data().contentRectScale().r;
        pic.deinit();
        const px = dvui.windowNaturalScale();
        const ghost = colors.edge.opacity(0.55);
        if (kind == .hard_break) {
            // Down, then left, with a head: a carriage return, ghosted as
            // it is on the canvas.
            const right = r.x + r.w * 0.8;
            const left = r.x + r.w * 0.15;
            const top = r.y + r.h * 0.1;
            const low = r.y + r.h * 0.75;
            const h = r.h * 0.25;
            dvui.Path.stroke(.{ .points = &.{ .{ .x = right, .y = top }, .{ .x = right, .y = low }, .{ .x = left, .y = low } } }, .{ .thickness = 1.5 * px, .color = .{ .color = ghost } });
            dvui.Path.stroke(.{ .points = &.{ .{ .x = left + h, .y = low - h }, .{ .x = left, .y = low }, .{ .x = left + h, .y = low + h } } }, .{ .thickness = 1.5 * px, .color = .{ .color = ghost } });
        } else if (kind == .join) {
            // Two tiles with a tie under them: one group.
            const w = r.w * 0.38;
            const a_r: dvui.Rect.Physical = .{ .x = r.x + r.w * 0.06, .y = r.y + r.h * 0.1, .w = w, .h = r.h * 0.55 };
            const b_r: dvui.Rect.Physical = .{ .x = r.x + r.w * 0.56, .y = r.y + r.h * 0.1, .w = w, .h = r.h * 0.55 };
            a_r.stroke(.all(2 * px), .{ .thickness = px, .color = .{ .color = colors.edge } });
            b_r.stroke(.all(2 * px), .{ .thickness = px, .color = .{ .color = colors.edge } });
            const y = r.y + r.h * 0.85;
            dvui.Path.stroke(.{ .points = &.{ .{ .x = a_r.x + w / 2, .y = y }, .{ .x = b_r.x + w / 2, .y = y } } }, .{ .thickness = 2 * px, .color = .{ .color = dvui.themeGet().focus } });
        } else if (kind == .next_prototype) {
            // Two tiles side by side: another kind of tile.
            const w = r.w * 0.42;
            const a_r: dvui.Rect.Physical = .{ .x = r.x, .y = r.y + r.h * 0.2, .w = w, .h = r.h * 0.6 };
            const b_r: dvui.Rect.Physical = .{ .x = r.x + r.w - w, .y = r.y + r.h * 0.2, .w = w, .h = r.h * 0.6 };
            a_r.stroke(.all(2 * px), .{ .thickness = px, .color = .{ .color = ghost } });
            b_r.fill(.all(2 * px), .{ .color = .{ .color = colors.face } });
            b_r.stroke(.all(2 * px), .{ .thickness = px, .color = .{ .color = colors.edge } });
        } else {
            // A dashed-looking slot with a caret: text to be typed.
            r.stroke(.square, .{ .thickness = px, .color = .{ .color = ghost } });
            const x = r.x + r.w * 0.3;
            dvui.Path.stroke(.{ .points = &.{ .{ .x = x, .y = r.y + 3 * px }, .{ .x = x, .y = r.y + r.h - 3 * px } } }, .{ .thickness = 1.5 * px, .color = .{ .color = dvui.themeGet().focus } });
        }
        const next_name = blk: {
            if (kind != .next_prototype) break :blk "";
            const c = track_cursor orelse break :blk "";
            const pal = paletteFor(c.panel, c.region) orelse break :blk "";
            break :blk std.fmt.allocPrint(dvui.currentWindow().arena(), "Tiles: {s} · next kind", .{state.model.prototypes.items[pal.prototype].name}) catch "";
        };
        dvui.labelNoFmt(@src(), switch (kind) {
            .run => "Text or equation",
            .hard_break => "Hard break",
            .next_prototype => next_name,
            .join => "Join or part",
        }, .{}, .{ .gravity_y = 0.5, .font = dvui.Font.theme(.body).larger(-2), .padding = .{ .x = 8 } });
    }
    bw.drawFocus();
    bw.deinit();
    return clicked;
}

/// One palette button: the tile or blank drawn to scale, its key, its size.
fn paletteButton(tile: bool, key: u8, size: f64, i: usize) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = i,
        .margin = .all(2),
        .padding = .all(4),
        .min_size_content = .{ .w = 44, .h = 56 },
        .corners = .all(4),
        .color_fill = .{ .color = dvui.themeGet().color(.control, .fill).opacity(palette_button_alpha) },
    });
    bw.processEvents();
    bw.drawBackground();
    const clicked = bw.clicked();
    if (palette_id_count < palette_ids.len) {
        palette_ids[palette_id_count] = bw.data().id;
        palette_id_count += 1;
    }
    {
        var col = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_x = 0.5 });
        defer col.deinit();
        // To scale: 18 px a unit.
        const w: f32 = @floatCast(@max(4, size * 18));
        _ = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = w, .h = 16 },
            .max_size_content = .{ .w = w, .h = 16 },
            .gravity_x = 0.5,
            .background = tile,
            .border = .all(1),
            .corners = .all(3),
            .color_fill = if (tile) .{ .color = colors.face } else null,
            .color_border = .{ .color = if (tile) colors.edge else colors.edge.opacity(0.5) },
        }).deinit();
        var kb: [1]u8 = .{key};
        dvui.labelNoFmt(@src(), &kb, .{}, .{ .gravity_x = 0.5, .font = dvui.Font.theme(.mono).withWeight(.bold), .padding = .{ .y = 2 } });
        var sb: [16]u8 = undefined;
        dvui.labelNoFmt(@src(), std.fmt.bufPrint(&sb, "{d} u", .{size}) catch "", .{}, .{ .gravity_x = 0.5, .font = dvui.Font.theme(.body).larger(-3), .padding = .{} });
    }
    bw.drawFocus();
    bw.deinit();
    return clicked;
}

// Moving tracks ------------------------------------------------------------
//
// With a track (a row or a column) as the context, the arrow keys, or the
// move palette's inverted-T buttons, move it in its prototype's smallest
// step: along its length, or across. Its origin moves and the path bends
// through it, so rows that only continue the path follow; kept ones stay.

/// The step a region's tracks move in: the finer of its prototype's size
/// steps along and across (0.25 u for keyboard keys).
fn moveStep(panel: usize, region: usize) f64 {
    const r = state.model.panels.items[panel].regions.items[region];
    if (state.model.prototypes.items.len == 0) return 0.25;
    const p = state.model.prototypes.items[r.prototype orelse 0];
    return @min(p.step(r.major, .along), p.step(r.major, .across));
}

const Arrow = enum { up, left, down, right };

/// Moves the selected track one step the way an arrow points, on screen.
fn moveTrackArrow(arrow: Arrow) void {
    const t = switch (state.context) {
        .row => |r| r,
        else => return,
    };
    const major = state.model.panels.items[t.panel].regions.items[t.region].major;
    const s = moveStep(t.panel, t.region);
    // Rows run right and stack down; columns run down and set right.
    var along: f64 = 0;
    var across: f64 = 0;
    switch (arrow) {
        .left => if (major == .row) {
            along = -s;
        } else {
            across = -s;
        },
        .right => if (major == .row) {
            along = s;
        } else {
            across = s;
        },
        .up => if (major == .row) {
            across = -s;
        } else {
            along = -s;
        },
        .down => if (major == .row) {
            across = s;
        } else {
            along = s;
        },
    }
    if (t.panel >= state.placed.items.len) return;
    const placed = &state.placed.items[t.panel];
    var obuf: [512]layout.model.Segment = undefined;
    var abuf: [1024]geom.Box = undefined;
    const kept = state.model.panels.items[t.panel].regions.items[t.region].segments.items.len;
    // The path bends through it; rows that only continue the path follow.
    act(.moveSegment, .{t.panel, t.region, t.row, placed.origins(t.region, &obuf), along, across, placed.obstacles(t.region, t.row, kept, &abuf)}) catch |err| {
        state.status = if (err == error.NoRoom) "No room to move it that way. " else "It did not move. ";
        return;
    };
    state.status = "";
}

fn moveTrackKey(code: dvui.enums.Key) bool {
    const arrow: Arrow = switch (code) {
        .up => .up,
        .left => .left,
        .down => .down,
        .right => .right,
        else => return false,
    };
    moveTrackArrow(arrow);
    return true;
}

/// The move palette: the arrow keys as an inverted T, each moving the
/// selected track one step, and where it now sits.
fn movePalette() void {
    palette_id_count = 0;
    const t = switch (state.context) {
        .row => |r| r,
        else => return,
    };
    const region = state.model.panels.items[t.panel].regions.items[t.region];
    const s = moveStep(t.panel, t.region);
    const word = trackWord(region.major);
    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer body.deinit();
    {
        var keys = dvui.box(@src(), .{ .dir = .vertical }, .{ .padding = .{ .x = 6, .y = 4, .w = 12 } });
        defer keys.deinit();
        {
            var top = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
            defer top.deinit();
            if (arrowButton(.up, 0)) moveTrackArrow(.up);
        }
        var bottom = dvui.box(@src(), .{ .dir = .horizontal }, .{ .gravity_x = 0.5 });
        defer bottom.deinit();
        for ([_]Arrow{ .left, .down, .right }, 1..) |a, i| {
            if (arrowButton(a, i)) moveTrackArrow(a);
        }
    }
    var info = dvui.box(@src(), .{ .dir = .vertical }, .{ .gravity_y = 0.5 });
    defer info.deinit();
    dvui.label(@src(), "Move {s} {d} of {s} in {d} u steps", .{ word, t.row + 1, region.name, s }, .{ .font = dvui.Font.theme(.heading) });
    dvui.label(@src(), "Arrow keys or these buttons move it, tiles and all. The path bends through it: rows that only continue the path follow; the rest stay.", .{}, .{ .font = dvui.Font.theme(.body).larger(-2) });
    var where_buf: [96]u8 = undefined;
    dvui.labelNoFmt(@src(), trackWhere(&where_buf, t.panel, t.region, t.row), .{}, .{ .font = dvui.Font.theme(.mono) });
}

/// Where a row or column sits from where a straight path would put it, in
/// plain words: "0.25 u up · 1.5 u left" (a row) or "1 u right · 0.5 u
/// down" (a column).
fn trackWhere(buf: []u8, pi: usize, region: usize, t: usize) []const u8 {
    const o = segmentOrigin(pi, region, t) orelse return "";
    // Straight on from the region's origin, one thickness each.
    const across = o.across - @as(f64, @floatFromInt(t));
    const along = o.along;
    const rows = state.model.panels.items[pi].regions.items[region].major == .row;
    const across_word = if (rows) (if (across < 0) "up" else "down") else (if (across < 0) "left" else "right");
    const along_word = if (rows) (if (along < 0) "left" else "right") else (if (along < 0) "up" else "down");
    return std.fmt.bufPrint(buf, "{d} u {s} · {d} u {s}", .{ @abs(across), across_word, @abs(along), along_word }) catch "";
}

/// One arrow key of the move palette: its arrow, drawn as a keycap.
fn arrowButton(arrow: Arrow, i: usize) bool {
    var bw: dvui.ButtonWidget = undefined;
    bw.init(@src(), .{}, .{
        .id_extra = i,
        .margin = .all(2),
        .padding = .all(6),
        .min_size_content = .{ .w = 34, .h = 34 },
        .corners = .all(5),
        .border = .all(1),
        .color_fill = .{ .color = dvui.themeGet().color(.control, .fill).opacity(palette_button_alpha) },
    });
    bw.processEvents();
    bw.drawBackground();
    const clicked = bw.clicked();
    if (palette_id_count < palette_ids.len) {
        palette_ids[palette_id_count] = bw.data().id;
        palette_id_count += 1;
    }
    const icon = switch (arrow) {
        .up => dvui.entypo.arrow_bold_up,
        .left => dvui.entypo.arrow_bold_left,
        .down => dvui.entypo.arrow_bold_down,
        .right => dvui.entypo.arrow_bold_right,
    };
    dvui.icon(@src(), @tagName(arrow), icon, .{}, .{ .gravity_x = 0.5, .gravity_y = 0.5, .min_size_content = .{ .w = 20, .h = 20 } });
    bw.drawFocus();
    bw.deinit();
    if (clicked) if (canvas_id) |id| dvui.focusWidget(id, null, null);
    return clicked;
}
