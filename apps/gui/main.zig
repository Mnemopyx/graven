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
const dvui = @import("dvui");
const layout = @import("graven_layout");
const engine = @import("graven_engine");
const samples = @import("graven_samples");
const desktop = @import("desktop.zig");

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
const Tool = enum { select, add_panel, add_label };

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
const Flat = struct {
    arena: std.heap.ArenaAllocator,
    map: std.AutoHashMapUnmanaged(*const engine.Render, []const Piece) = .empty,
    tol: f64 = 0,

    fn reset(f: *Flat, tol: f64) void {
        f.map = .empty;
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
}

/// Adds the sample PC keyboard as a new panel and makes it the context.
fn loadSample() !void {
    const main_style = try state.model.addStyle("legend", .{ .upright = 0, .cap_height = 2.6 });
    const small = try state.model.addStyle("legend words", .{ .upright = 0, .cap_height = 1.6 });
    const pi = try samples.pc_keyboard.build(state.gpa, &state.model, .{ .main = main_style, .small = small });
    // Top-left of the sheet, 20 mm in.
    const panel = state.model.panels.items[pi];
    try state.model.movePanel(pi, .{ .x = 20, .y = state.model.sheet.h - 20 - panel.h });
    state.context = .{ .panel = pi };
    state.view.fit = state.model.panels.items[pi].box();
}

fn deinit(_: *dvui.Window) void {
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
/// listed; a variable font is listed once, at its default instance.
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
        const name = try std.fmt.allocPrint(gpa, "{s} {s}{s}", .{ family, style, if (user) " (user)" else "" });
        try list.append(gpa, .{ .name = name, .path = path, .index = index, .family = family, .style = style });
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
    state.solve_ms = @as(f64, @floatFromInt(t0.untilNow(dvui.io, .awake).toNanoseconds())) / 1e6;
    state.placed_rev = state.model.revision;
    state.flat.reset(state.flat.tol);
}

fn clearPlaced() void {
    state.gpa.free(state.intrusions);
    state.intrusions = &.{};
    state.gpa.free(state.panel_issues);
    state.panel_issues = &.{};
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
    if (state.moving) |mv| if (mv.panel == pi) return .{ .x = o.x + @round(mv.at.x - mv.start.x), .y = o.y + @round(mv.at.y - mv.start.y) };
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

    if (titleBar()) |r| return r;

    {
        // The body and the status bar are placed explicitly, so a tall pane
        // can never push the status bar off the bottom of the window.
        var rest = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer rest.deinit();
        const size = rest.data().contentRect();
        const status_h: f32 = if (panes.status == .docked) status_height else 0;
        {
            var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .rect = .{ .x = 0, .y = 0, .w = size.w, .h = @max(0, size.h - status_h) } });
            defer body.deinit();
            if (panes.tree == .docked) treePane();
            canvas();
            if (panes.properties == .docked) try propertiesPane();
        }
        if (panes.status == .docked) {
            var bottom = dvui.box(@src(), .{ .dir = .vertical }, .{
                .rect = .{ .x = 0, .y = size.h - status_h, .w = size.w, .h = status_h },
                .background = true,
                .border = .{ .y = 1 },
            });
            defer bottom.deinit();
            try bottomContent();
        }
    }
    try overlays();
    return .ok;
}

// Pane display -------------------------------------------------------------
//
// The tree, the tool palette with properties, and the status bar each show
// docked beside the canvas, over it as translucent overlays (the default),
// or not at all.

const PaneMode = enum { overlay, docked, hidden };

var panes: struct {
    tree: PaneMode = .overlay,
    properties: PaneMode = .overlay,
    status: PaneMode = .overlay,
} = .{};

const tree_width = 240;
const properties_width = 320;
/// The bottom area: the expression line above the status line.
const expression_height = 38;
const status_line_height = 32;
const status_height = expression_height + status_line_height;
/// Space between an overlay and the canvas edge, logical pixels.
const overlay_gap = 6;
/// How opaque an overlay's background is.
const overlay_alpha = 0.84;

/// The canvas's rectangle in logical pixels, from the last frame: overlays
/// anchor to it.
var canvas_rect: dvui.Rect = .{};

/// How much of each canvas edge overlays cover, logical pixels, so fitting
/// a view keeps its subject clear of them.
fn overlayInsets() struct { left: f32, right: f32, bottom: f32 } {
    return .{
        .left = if (panes.tree == .overlay) tree_width + 2 * overlay_gap else 0,
        .right = if (panes.properties == .overlay) properties_width + 2 * overlay_gap else 0,
        .bottom = if (panes.status == .overlay) status_height + 2 * overlay_gap else 0,
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

/// The panes shown as overlays, anchored to the canvas's edges.
fn overlays() !void {
    const c = canvas_rect;
    if (c.w <= 0 or c.h <= 0) return;
    const g: f32 = overlay_gap;
    const bottom: f32 = if (panes.status == .overlay) status_height + g else 0;
    if (panes.tree == .overlay) {
        var r: dvui.Rect = .{ .x = c.x + g, .y = c.y + g, .w = tree_width, .h = @max(60, c.h - 2 * g - bottom) };
        var fw = dvui.floatingWindow(@src(), .{ .rect = &r, .resize = .none }, overlayOptions(1));
        defer fw.deinit();
        treeContent();
    }
    if (panes.properties == .overlay) {
        var r: dvui.Rect = .{ .x = c.x + c.w - properties_width - g, .y = c.y + g, .w = properties_width, .h = @max(60, c.h - 2 * g - bottom) };
        var fw = dvui.floatingWindow(@src(), .{ .rect = &r, .resize = .none }, overlayOptions(2));
        defer fw.deinit();
        try propertiesContent();
    }
    if (panes.status == .overlay) {
        var r: dvui.Rect = .{ .x = c.x + g, .y = c.y + c.h - status_height - g, .w = c.w - 2 * g, .h = status_height };
        var fw = dvui.floatingWindow(@src(), .{ .rect = &r, .resize = .none }, overlayOptions(3));
        defer fw.deinit();
        try bottomContent();
    }
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

    fn content(t: ExprTarget) []const u8 {
        return switch (t) {
            .panel_label => |l| state.model.panels.items[l.panel].labels.items[l.index].content,
            .tile_slot => |ts| state.model.tileConst(ts.tile).slots.items[ts.slot].content,
        };
    }

    fn store(t: ExprTarget, text: []const u8) !void {
        switch (t) {
            .panel_label => |l| try state.model.setLabelContent(l.panel, l.index, text),
            .tile_slot => |ts| try state.model.setContent(ts.tile, state.model.tileConst(ts.tile).slots.items[ts.slot].name, text),
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
        .tile => |id| if (state.model.tileConst(id).slots.items.len > 0) .{ .tile_slot = .{ .tile = id, .slot = 0 } } else null,
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
        dvui.labelNoFmt(@src(), state.file_name, .{}, .{ .font = styled(.theme(.body), !state.file_name_set), .padding = .{ .x = 0, .w = 0, .y = 4, .h = 4 } });
        dvui.labelNoFmt(@src(), "  —  ", .{}, .{ .padding = .{ .x = 0, .w = 0, .y = 4, .h = 4 } });
        dvui.labelNoFmt(@src(), state.model.sheet.name, .{}, .{ .font = styled(.theme(.body), state.model.sheet.default_name), .padding = .{ .x = 0, .w = 0, .y = 4, .h = 4 } });
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
            .close => return .close,
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
        if (state.model.panels.items.len == 0) {
            if (dvui.menuItemLabel(@src(), "Add sample: PC keyboard", .{}, .{ .expand = .horizontal }) != null) {
                loadSample() catch |err| {
                    state.status = if (err == error.OffSheet) "The sample keyboard does not fit on this sheet. " else "The sample did not load. ";
                };
                m.close();
            }
        }
        if (dvui.menuItemLabel(@src(), "Quit", .{}, .{ .expand = .horizontal }) != null) return .close;
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
        // Pane display: overlay (the default), docked or hidden.
        inline for (.{ .{ "Tree", "tree" }, .{ "Tools and properties", "properties" }, .{ "Status line", "status" } }, 0..) |pane, pi| {
            _ = dvui.separator(@src(), .{ .expand = .horizontal, .id_extra = pi });
            inline for (.{ PaneMode.overlay, PaneMode.docked, PaneMode.hidden }, 0..) |mode, mi| {
                var buf: [64]u8 = undefined;
                const on = @field(panes, pane[1]) == mode;
                const text = std.fmt.bufPrint(&buf, "{s}{s}: {s}", .{ if (on) "•  " else "    ", pane[0], @tagName(mode) }) catch pane[0];
                if (dvui.menuItemLabel(@src(), text, .{}, .{ .expand = .horizontal, .id_extra = pi * 3 + mi }) != null) {
                    @field(panes, pane[1]) = mode;
                    m.close();
                }
            }
        }
    }
    return null;
}

/// The component tree: file, panels, regions, rows, tiles. Clicking a node
/// makes it the context; its arrow opens or closes it.
fn treePane() void {
    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = tree_width }, .max_size_content = .width(tree_width), .expand = .vertical, .border = .{ .w = 1 } });
    defer pane.deinit();
    treeContent();
}

/// The tree itself, in whatever holds it; scrolls by wheel, with no bars.
fn treeContent() void {
    var scroll = dvui.scrollArea(@src(), .{ .vertical_bar = .hide, .horizontal_bar = .hide }, .{ .expand = .both, .background = false });
    defer scroll.deinit();

    var name_buf: [64]u8 = undefined;
    // The file holds everything; the worksheet is its one child for now.
    if (!treeNode(.file, state.file_name, 0, true, !state.file_name_set)) return;
    const sheet = state.model.sheet;
    if (!treeNode(.worksheet, sheet.name, 1, state.model.panels.items.len > 0, sheet.default_name)) return;
    for (state.model.panels.items, 0..) |panel, pi| {
        if (!treeNode(.{ .panel = pi }, panel.name, 2, panel.regions.items.len > 0 or panel.labels.items.len > 0, panel.default_name)) continue;
        for (panel.labels.items, 0..) |label, li| {
            const text = std.fmt.bufPrint(&name_buf, "“{s}”", .{label.content}) catch label.content;
            _ = treeNode(.{ .label = .{ .panel = pi, .index = li } }, text, 3, false, label.default_content);
        }
        for (panel.regions.items, 0..) |region, ri| {
            if (!treeNode(.{ .region = .{ .panel = pi, .region = ri } }, region.name, 3, region.rows.items.len > 0, false)) continue;
            for (region.rows.items, 0..) |row, rowi| {
                const title = std.fmt.bufPrint(&name_buf, "Row {d}", .{rowi + 1}) catch "Row";
                if (!treeNode(.{ .row = .{ .panel = pi, .region = ri, .row = rowi } }, title, 4, row.places.items.len > 0, false)) continue;
                for (row.places.items) |p| {
                    const t = state.model.tileConst(p.tile);
                    const legend = if (t.slots.items.len > 0) t.slots.items[0].content else "";
                    const text = std.fmt.bufPrint(&name_buf, "{s}  {s}", .{ t.designator, legend }) catch t.designator;
                    _ = treeNode(.{ .tile = p.tile }, text, 5, false, false);
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
        .file, .worksheet, .panel, .region => true,
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
    })) state.context = ctx;
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
        .file, .worksheet, .panel, .label => false,
    };
}

/// The context's extents on the worksheet, mm.
fn contextExtents() geom.Box {
    switch (state.context) {
        .file, .worksheet => return state.model.sheet.box(),
        .panel => |pi| return state.model.panels.items[pi].box(),
        .label => |l| if (labelBox(l.panel, l.index)) |b| return b,
        else => {},
    }
    var b: geom.Box = .empty;
    for (state.placed.items, 0..) |*p, pi| for (p.tiles) |t| {
        if (inContext(pi, t)) b = b.join(onSheet(pi, t.pitch_box));
    };
    return if (b.isEmpty()) state.model.sheet.box() else b;
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
    missing: dvui.Color = .{ .r = 0xf6, .g = 0xd5, .b = 0xcf },
    overflow: dvui.Color = .{ .r = 0xc2, .g = 0x41, .b = 0x2d },
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

    // The first frame fits the worksheet, leaving room for its rulers.
    if (state.view.ppm == 0 and state.view.fit == null) state.view.fit = sheet.box();
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

    canvasEvents(box, area);
    // Work happens on the worksheet: the view's centre stays on the sheet.
    state.view.cx = std.math.clamp(state.view.cx, 0, sheet.w);
    state.view.cy = std.math.clamp(state.view.cy, 0, sheet.h);

    const px = dvui.windowNaturalScale();
    const sheet_rect = state.view.rect(area, sheet.box());
    sheet_rect.fill(.square, .{ .color = .{ .color = colors.paper } });
    drawMargins(area, sheet);
    sheet_rect.stroke(.square, .{ .thickness = px, .color = .{ .color = colors.edge } });

    // Re-flatten label outlines when the zoom has moved more than 2x.
    const tol = 0.2 / state.view.ppm;
    if (state.flat.tol == 0 or tol < state.flat.tol / 2 or tol > state.flat.tol * 2) state.flat.reset(tol);

    for (0..state.model.panels.items.len) |pi| {
        const outline = state.view.rect(area, panelBox(pi));
        const is_context = switch (state.context) {
            .panel => |c| c == pi,
            else => false,
        };
        // While dragged, compliance is shown live for the preview position.
        const off = if (state.moving != null and state.moving.?.panel == pi) !state.model.compliantAt(pi, panelOrigin(pi)) else panelIssue(pi) != null;
        drawPanelMargins(area, pi);
        // A panel past the sheet's edge is outlined in the warning colour.
        const edge = if (is_context) dvui.themeGet().focus else if (off) colors.overflow else colors.panel_edge;
        outline.stroke(.square, .{ .thickness = if (is_context or off) 2 * px else px, .color = .{ .color = edge } });
        if (pi < state.placed.items.len) drawPanel(area, pi, &state.placed.items[pi]);
    }

    // The panel being drawn out: a translucent fill and its outline.
    if (state.drag) |d| {
        const r = state.view.rect(area, dragBox(d.start, d.at));
        r.fill(.square, .{ .color = .{ .color = dvui.themeGet().focus.opacity(0.12) } });
        r.stroke(.square, .{ .thickness = 1.5 * px, .color = .{ .color = dvui.themeGet().focus } });
    }
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
    const band: dvui.ColorOrGradient = .{ .color = colors.margin.opacity(0.35) };
    for ([_]geom.Box{
        .{ .x0 = s.x0, .y0 = s.y0, .x1 = ink.x0, .y1 = s.y1 },
        .{ .x0 = ink.x1, .y0 = s.y0, .x1 = s.x1, .y1 = s.y1 },
        .{ .x0 = ink.x0, .y0 = ink.y1, .x1 = ink.x1, .y1 = s.y1 },
        .{ .x0 = ink.x0, .y0 = s.y0, .x1 = ink.x1, .y1 = ink.y0 },
    }) |b| {
        if (b.width() > 0 and b.height() > 0) state.view.rect(area, b).fill(.square, .{ .color = band });
    }
    state.view.rect(area, ink).stroke(.square, .{ .thickness = px, .color = .{ .color = colors.margin } });
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
    const band: dvui.ColorOrGradient = .{ .color = colors.margin.opacity(0.18) };
    for ([_]geom.Box{
        .{ .x0 = b.x0, .y0 = b.y0, .x1 = ink.x0, .y1 = b.y1 },
        .{ .x0 = ink.x1, .y0 = b.y0, .x1 = b.x1, .y1 = b.y1 },
        .{ .x0 = ink.x0, .y0 = ink.y1, .x1 = ink.x1, .y1 = b.y1 },
        .{ .x0 = ink.x0, .y0 = b.y0, .x1 = ink.x1, .y1 = ink.y0 },
    }) |r| {
        if (r.width() > 0 and r.height() > 0) state.view.rect(area, r).fill(.square, .{ .color = band });
    }
    if (ink.width() > 0 and ink.height() > 0) state.view.rect(area, ink).stroke(.square, .{ .thickness = px, .color = .{ .color = colors.margin.opacity(0.6) } });
}

fn inMargin(pi: usize, tile: ?TileId, slot: usize) bool {
    for (state.intrusions) |i| if (i.panel == pi and i.tile == tile and i.slot == slot) return true;
    return false;
}

/// A panel label's ink box on the worksheet, from the last solve, moved to
/// its preview place while dragged.
fn labelBox(pi: usize, index: usize) ?geom.Box {
    if (pi >= state.placed.items.len) return null;
    for (state.placed.items[pi].labels) |l| {
        if (l.tile != null or l.slot != index) continue;
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
    if (state.label_style) |s| return s;
    const s = try state.model.addStyle("Label", .{ .upright = 0, .cap_height = 3 });
    state.label_style = s;
    return s;
}

/// Places a new label on panel `pi` at worksheet point `at` (on a 0.5 mm
/// grid), with placeholder text; the context stays the panel.
fn addLabelAt(pi: usize, at: geom.Point) void {
    const o = state.model.panels.items[pi].origin;
    const style = labelStyle() catch return;
    _ = state.model.addLabel(pi, .{
        .at = .{ .x = @round((at.x - o.x) * 2) / 2, .y = @round((at.y - o.y) * 2) / 2 },
        .style = style,
        .content = "LABEL",
        .default_content = true,
    }) catch return;
    state.expanded.put(state.gpa, Context.key(.{ .panel = pi }), true) catch {};
}

/// Tiles and legends of panel `pi`, moved onto the worksheet.
fn drawPanel(area: dvui.Rect.Physical, pi: usize, placed: *const layout.place.Placed) void {
    const px = dvui.windowNaturalScale();
    const radius: f32 = @floatCast(1.0 * state.view.ppm);
    for (placed.tiles) |t| {
        const flagged = tileFlag(placed, t.id);
        const body = state.view.rect(area, onSheet(pi, t.body));
        const face = state.view.rect(area, onSheet(pi, t.face));
        body.fill(.round(radius), .{ .color = .{ .color = colors.body } });
        const in_context = inContext(pi, t);
        body.stroke(.round(radius), .{ .thickness = px, .color = .{ .color = if (in_context) dvui.themeGet().focus else colors.edge } });
        face.fill(.round(radius), .{ .color = .{ .color = if (flagged.missing) colors.missing else colors.face } });
        if (flagged.overflow) face.stroke(.round(radius), .{ .thickness = 1.5 * px, .color = .{ .color = colors.overflow } });
        if (in_context) body.stroke(.round(radius), .{ .thickness = (if (state.context == .tile) @as(f32, 3) else 2) * px, .color = .{ .color = dvui.themeGet().focus } });
    }
    const o = panelOrigin(pi);
    const lifo = dvui.currentWindow().lifo();
    for (placed.labels) |l| {
        const d = if (l.tile == null) labelDelta(pi, l.slot) else geom.Point{ .x = 0, .y = 0 };
        const pieces = state.flat.get(l.render, &state.faces) catch continue;
        // Ink in the sheet's margins is drawn in the warning colour.
        const ink = if (inMargin(pi, l.tile, l.slot)) colors.overflow else colors.ink;
        const at: geom.Point = .{ .x = l.origin.x + o.x + d.x, .y = l.origin.y + o.y + d.y };
        for (pieces) |piece| {
            const color: dvui.Color = switch (piece.kind) {
                .ink => ink,
                .faint => ink.opacity(0.35),
                .placeholder => dvui.themeGet().focus.opacity(0.7),
            };
            if (show_construction and piece.kind == .ink) {
                // Outlines over a translucent fill, so the lines show through.
                fillRegion(area, piece.region, at, color.opacity(0.18));
                for (piece.region.loops) |loop| {
                    const pts = lifo.alloc(dvui.Point.Physical, loop.len) catch break;
                    defer lifo.free(pts);
                    for (loop, pts) |q, *out| out.* = state.view.toPx(area, .{ .x = q.x + at.x, .y = q.y + at.y });
                    dvui.Path.stroke(.{ .points = pts }, .{ .thickness = px, .color = .{ .color = color }, .closed = true });
                }
            } else {
                fillRegion(area, piece.region, at, color);
            }
        }
        if (show_construction) drawConstruction(area, l, .{ .x = o.x + d.x, .y = o.y + d.y });
        if (caretIn(pi, l)) |c| {
            const x = l.origin.x + o.x + d.x + c.x;
            const y = l.origin.y + o.y + d.y;
            const a = state.view.toPx(area, .{ .x = x, .y = y + c.y0 });
            const b = state.view.toPx(area, .{ .x = x, .y = y + c.y1 });
            dvui.Path.stroke(.{ .points = &.{ a, b } }, .{ .thickness = 1.5 * px, .color = .{ .color = dvui.themeGet().focus } });
        }
    }
    // The selected panel label: its ink box, with a little room.
    switch (state.context) {
        .label => |sel| if (sel.panel == pi) if (labelBox(pi, sel.index)) |b| {
            const pad = 0.6;
            state.view.rect(area, .{ .x0 = b.x0 - pad, .y0 = b.y0 - pad, .x1 = b.x1 + pad, .y1 = b.y1 + pad }).stroke(.square, .{ .thickness = 1.5 * px, .color = .{ .color = dvui.themeGet().focus } });
        },
        else => {},
    }
}

/// Fills a resolved region placed at worksheet point `at`: its triangles as
/// they are, then a band one pixel wide fading out past each loop, for
/// antialiasing.
fn fillRegion(area: dvui.Rect.Physical, region: geom.fill.Region, at: geom.Point, color: dvui.Color) void {
    const lifo = dvui.currentWindow().lifo();
    const col: dvui.Color.PMA = .fromColor(color.opacity(dvui.currentWindow().alpha));
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
            for (v) |pos| b.appendVertex(.{ .pos = pos, .col = col });
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
            b.appendVertex(.{ .pos = p, .col = col });
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
        .panel_label => |t| t.panel == pi and l.tile == null and l.slot == t.index,
        .tile_slot => |t| l.tile != null and std.meta.eql(l.tile.?, t.tile) and l.slot == t.slot,
    };
    if (!mine) return null;
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
    switch (state.model.sheet.units) {
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
    const right = sheet.ruler_origin.fromRight();
    const tl = state.view.toPx(area, .{ .x = 0, .y = sheet.h });
    const br = state.view.toPx(area, .{ .x = sheet.w, .y = 0 });

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
        const mark: dvui.ColorOrGradient = .{ .color = dvui.themeGet().focus };
        dvui.Path.stroke(.{ .points = &.{ .{ .x = p.x, .y = top.y }, .{ .x = p.x, .y = top.y + top.h } } }, .{ .thickness = ns, .color = mark });
        dvui.Path.stroke(.{ .points = &.{ .{ .x = side.x, .y = p.y }, .{ .x = side.x + side.w, .y = p.y } } }, .{ .thickness = ns, .color = mark });
    }
}

/// One ruler's ticks and numbers, counted from the ruler origin. Ticks grow
/// from the ruler's edge against the sheet.
fn rulerAxis(r: dvui.Rect.Physical, area: dvui.Rect.Physical, list: []const Tick, horizontal: bool) void {
    if (r.w <= 0 or r.h <= 0) return;
    const ns = dvui.windowNaturalScale();
    const sheet = state.model.sheet;
    const from_far = if (horizontal) sheet.ruler_origin.fromRight() else sheet.ruler_origin.fromTop();
    const length = if (horizontal) sheet.w else sheet.h;
    // The ruler's ends in the worksheet frame, then as the ruler counts.
    const e0 = if (horizontal) state.view.toMm(area, .{ .x = r.x, .y = 0 }).x else state.view.toMm(area, .{ .x = 0, .y = r.y + r.h }).y;
    const e1 = if (horizontal) state.view.toMm(area, .{ .x = r.x + r.w, .y = 0 }).x else state.view.toMm(area, .{ .x = 0, .y = r.y }).y;
    const c0 = if (from_far) length - e0 else e0;
    const c1 = if (from_far) length - e1 else e1;
    // A millimetre of slack each way, so pixel rounding at a sheet edge
    // does not drop the 0 or end tick; still clamped to the sheet.
    const lo = @max(0, @min(c0, c1) - 1);
    const hi = @min(length, @max(c0, c1) + 1);
    if (lo > hi) return;

    // Ticks grow from the edge against the sheet: the horizontal ruler's
    // bottom; the vertical ruler's right side on the left, left side on
    // the right.
    const right_side = !horizontal and sheet.ruler_origin.fromRight();
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
            const rounded = @round(v * sheet.units.perMm());
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

/// Snaps a worksheet point to the 1 mm grid the add panel tool uses, and
/// keeps it on the sheet: panels may not extend past it.
fn snap(p: geom.Point) geom.Point {
    const s = state.model.sheet.box();
    return .{ .x = std.math.clamp(@round(p.x), s.x0, s.x1), .y = std.math.clamp(@round(p.y), s.y0, s.y1) };
}

fn dragBox(a: geom.Point, b: geom.Point) geom.Box {
    return .{ .x0 = @min(a.x, b.x), .y0 = @min(a.y, b.y), .x1 = @max(a.x, b.x), .y1 = @max(a.y, b.y) };
}

fn canvasEvents(box: *dvui.BoxWidget, area: dvui.Rect.Physical) void {
    // A tool waiting for the canvas: Add panel (a drag) or Add label (a click).
    const drawing = state.tool != .select;
    for (dvui.events()) |*e| {
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
                    .panel => |pi| {
                        e.handle(@src(), box.data());
                        state.model.removePanel(pi);
                        state.context = .worksheet;
                        dvui.refresh(null, @src(), box.data().id);
                    },
                    .label => |l| if (state.moving_label == null) {
                        e.handle(@src(), box.data());
                        state.model.removeLabel(l.panel, l.index);
                        state.context = .{ .panel = l.panel };
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
                state.mouse = if (area.contains(me.p) and contains(state.model.sheet.box(), at)) at else null;
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
                    if (state.context == .panel and contains(state.model.panels.items[state.context.panel].box(), at)) {
                        addLabelAt(state.context.panel, at);
                        state.tool = .select;
                        // The release that follows is part of this click, not a pick.
                        state.press_consumed = true;
                    }
                } else if (drawing and me.button.pointer()) {
                    const at = snap(state.view.toMm(area, me.p));
                    state.drag = .{ .start = at, .at = at };
                } else {
                    state.press_at = if (me.button.pointer()) state.view.toMm(area, me.p) else null;
                    dvui.dragPreStart(me.button, me.p, .{});
                }
            },
            .motion => if (dvui.captured(box.data().id)) {
                if (state.drag) |*d| {
                    e.handle(@src(), box.data());
                    d.at = snap(state.view.toMm(area, me.p));
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
                    addPanelFromDrag(dragBox(d.start, d.at));
                } else if (state.moving) |mv| {
                    finishMove(mv.panel);
                } else if (state.moving_label) |mv| {
                    const d = labelDelta(mv.panel, mv.index);
                    state.moving_label = null;
                    const at = state.model.panels.items[mv.panel].labels.items[mv.index].at;
                    state.model.moveLabel(mv.panel, mv.index, .{ .x = at.x + d.x, .y = at.y + d.y });
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

/// The panel a drag from worksheet point `at` would move: the selected
/// panel when `at` is on it; from the worksheet context, the one panel
/// under `at`, if exactly one is (where panels overlap, select one first).
/// The context does not change.
fn panelToMove(at: geom.Point) ?usize {
    switch (state.context) {
        .panel => |pi| return if (contains(state.model.panels.items[pi].box(), at)) pi else null,
        .worksheet => {
            var found: ?usize = null;
            for (state.model.panels.items, 0..) |p, pi| {
                if (!contains(p.box(), at)) continue;
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
    const origin = if (state.model.compliant(pi)) state.model.clampCompliant(pi, target) else target;
    state.model.movePanel(pi, origin) catch |err| dvui.log.err("moving a panel: {s}", .{@errorName(err)});
}

/// Makes what is under worksheet point `at` the context: a tile, else a
/// panel, else the worksheet.
fn pick(at: geom.Point) void {
    state.context = .worksheet;
    for (state.model.panels.items, 0..) |panel, pi| {
        const b = panel.box();
        if (at.x >= b.x0 and at.x <= b.x1 and at.y >= b.y0 and at.y <= b.y1) state.context = .{ .panel = pi };
        if (pi >= state.placed.items.len) continue;
        for (state.placed.items[pi].tiles) |t| {
            const body = onSheet(pi, t.body);
            if (at.x >= body.x0 and at.x <= body.x1 and at.y >= body.y0 and at.y <= body.y1) state.context = .{ .tile = t.id };
        }
        for (state.placed.items[pi].labels) |l| {
            if (l.tile != null) continue;
            if (labelBox(pi, l.slot)) |lb| if (contains(.{ .x0 = lb.x0 - 1, .y0 = lb.y0 - 1, .x1 = lb.x1 + 1, .y1 = lb.y1 + 1 }, at)) {
                state.context = .{ .label = .{ .panel = pi, .index = l.slot } };
            };
        }
    }
    revealInTree(state.context);
}

/// Adds the panel drawn out with the add panel tool. A drag under 1 mm on
/// either side is taken as a slip and ignored, leaving the tool ready.
fn addPanelFromDrag(b: geom.Box) void {
    if (b.width() < 1 or b.height() < 1) return;
    var buf: [32]u8 = undefined;
    const name = state.model.nextPanelName(&buf, "Panel");
    const pi = state.model.placePanel(.{
        .name = name,
        .default_name = true,
        .origin = .{ .x = b.x0, .y = b.y0 },
        .w = b.width(),
        .h = b.height(),
    }) catch |err| {
        dvui.log.err("adding a panel: {s}", .{@errorName(err)});
        return;
    };
    // Tools are not modes: a use ends the tool, and the context it was
    // chosen in stays, so the next panel is one press away.
    _ = pi;
    state.tool = .select;
    state.expanded.put(state.gpa, Context.key(.file), true) catch {};
    state.expanded.put(state.gpa, Context.key(.worksheet), true) catch {};
}

const Flags = struct { missing: bool = false, overflow: bool = false };

fn tileFlag(placed: *const layout.place.Placed, id: TileId) Flags {
    var f: Flags = .{};
    for (placed.issues) |i| {
        if (i.tile != id) continue;
        switch (i.kind) {
            .missing_glyph => f.missing = true,
            .label_overflow => f.overflow = true,
            else => {},
        }
    }
    return f;
}

/// The right side: a tool palette for the current context, then its
/// properties.
fn propertiesPane() !void {
    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = properties_width }, .max_size_content = .width(properties_width), .expand = .vertical, .border = .{ .x = 1 } });
    defer pane.deinit();
    try propertiesContent();
}

/// The tool palette and the properties, in whatever holds them.
fn propertiesContent() !void {
    toolPalette();
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    var scroll = dvui.scrollArea(@src(), .{ .vertical_bar = .hide, .horizontal_bar = .hide }, .{ .expand = .both, .background = false });
    defer scroll.deinit();
    var body = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .horizontal, .padding = .all(8) });
    defer body.deinit();
    try properties();
}

/// Tools for the current context, as icon buttons.
fn toolPalette() void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .padding = .all(4) });
    defer bar.deinit();
    var wd: dvui.WidgetData = undefined;
    if (dvui.buttonIcon(@src(), "Zoom to context", dvui.entypo.resize_full_screen, .{}, .{}, .{ .data_out = &wd })) zoomToContext();
    dvui.tooltip(@src(), .{ .active_rect = wd.borderRectScale().r }, "Zoom to fit the {s}", .{lowerKind()}, .{});

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
    }
    if (state.context == .worksheet) {
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
        if (changed and !std.mem.eql(u8, text, state.model.sheet.name)) try state.model.nameWorksheet(text);
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
            try state.model.setSheet(if (choice < papers.len) .standard(choice, sheet.orientation) else .custom(sheet.w, sheet.h));
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
                try state.model.setSheet(if (sheet.paper) |p| .standard(p, o) else .custom(sheet.h, sheet.w));
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
            state.model.setUnits(@fromBackingInt(@intCast(choice)));
        }
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        propName("Ruler origin");
        const names = [_][]const u8{ "Bottom left", "Top left", "Bottom right", "Top right" };
        var choice: usize = @backingInt(sheet.ruler_origin);
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal, .font = styled(.theme(.body), sheet.default_ruler_origin) })) {
            state.model.setRulerOrigin(@fromBackingInt(@intCast(choice)));
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
            try state.model.setSheet(.custom(w, h));
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
    if (changed) state.model.setMargins(m) catch {};
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
    if (changed) state.model.setPanelMargins(pi, m) catch {};
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
    heading("{s}", .{state.context.kindName()}, 0);
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
        .panel => |pi| {
            const panel = state.model.panels.items[pi];
            propValue("Name", panel.default_name, "{s}", .{panel.name}, 1);
            propText("Origin", "({d:.2}, {d:.2}) mm", .{ panel.origin.x, panel.origin.y }, 2);
            propText("Size", "{d:.2} × {d:.2} mm", .{ panel.w, panel.h }, 3);
            propText("Regions", "{d}", .{panel.regions.items.len}, 4);
            propText("Labels", "{d}", .{panel.labels.items.len}, 7);
            try panelMargins(pi);
            if (panelIssue(pi)) |i| {
                if (i.off_sheet > 0) propText("Issue", "{d:.2} mm off the sheet", .{i.off_sheet}, 20);
                if (i.ink_outside > 0) propText("Issue", "ink area {d:.2} mm in margin", .{i.ink_outside}, 21);
            }
            try propFont("Legend font", 5);
        },
        .region => |r| {
            const region = state.model.panels.items[r.panel].regions.items[r.region];
            propText("Name", "{s}", .{region.name}, 1);
            propText("Origin", "({d:.2}, {d:.2}) mm", .{ region.origin.x, region.origin.y }, 2);
            propText("Size", "{d} × {d} u", .{ region.w, region.h }, 3);
            propText("Pitch", "{d} mm", .{region.pitch}, 4);
            propText("Rows", "{d}", .{region.rows.items.len}, 5);
        },
        .row => |r| {
            const region = state.model.panels.items[r.panel].regions.items[r.region];
            const row = region.rows.items[r.row];
            propText("Row", "{d} of {d} in {s}", .{ r.row + 1, region.rows.items.len, region.name }, 1);
            propText("Gap above", "{d} u", .{row.gap}, 2);
            propText("Tiles", "{d}", .{row.places.items.len}, 3);
        },
        .tile => |id| try tileProperties(id),
        .label => |l| try labelProperties(l.panel, l.index),
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
        if (changed and !std.mem.eql(u8, text, label.content)) try state.model.setLabelContent(pi, index, text);
    }
    {
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        propName("Alignment");
        const names = [_][]const u8{ "Start", "Centre", "End" };
        var choice: usize = @backingInt(label.alignment);
        if (dvui.dropdown(@src(), &names, .{ .choice = &choice }, .{}, .{ .expand = .horizontal })) {
            state.model.alignLabel(pi, index, @fromBackingInt(@intCast(choice)));
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
        if (changed) state.model.moveLabel(pi, index, at);
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
            state.model.setCapHeight(label.style, cap) catch {};
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
    propText("Size", "{d} × {d} u", .{ t.w, t.h }, 2);
    const found = findTile(id);
    if (found) |f| {
        const pt = f.tile;
        propText("Body", "{d:.2} × {d:.2} mm", .{ pt.body.width(), pt.body.height() }, 3);
        propText("Position", "({d:.2}, {d:.2}) mm in panel", .{ pt.body.x0, pt.body.y0 }, 4);
        propText("Row", "{d}", .{pt.row + 1}, 5);
    }

    for (t.slots.items, 0..) |slot, si| {
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
            if (changed and !std.mem.eql(u8, text, slot.content)) try state.model.setContent(id, slot.name, text);
        }
        propText("Style", "{s}", .{state.model.styles.items[slot.style].name}, n + 2);
        try propFont("Font", n + 3);
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
            .label_overflow, .row_overflow => overflow += 1,
            else => {},
        };
    }
    const field: dvui.Options = .{ .gravity_y = 0.5, .padding = .{ .x = 8, .w = 8, .y = 2, .h = 2 } };
    const muted: dvui.Options = .{ .color_text = .{ .color = dvui.themeGet().color(.window, .text).opacity(0.65) } };

    var pos_buf: [64]u8 = undefined;
    const u = state.model.sheet.units;
    const pos = if (state.mouse) |m_sheet| blk: {
        // Shown as the rulers count: from the ruler origin.
        const m = state.model.sheet.toRuler(m_sheet);
        const k = u.perMm();
        break :blk switch (u) {
            .mm => std.fmt.bufPrint(&pos_buf, "x {d:.2}   y {d:.2} mm", .{ m.x * k, m.y * k }),
            .inch => std.fmt.bufPrint(&pos_buf, "x {d:.3}   y {d:.3} in", .{ m.x * k, m.y * k }),
        } catch "";
    } else std.fmt.bufPrint(&pos_buf, "x –   y – {s}", .{u.symbol()}) catch "";
    dvui.labelNoFmt(@src(), pos, .{}, field.override(.{ .min_size_content = .{ .w = 190 }, .font = .theme(.mono) }));

    var counts_buf: [160]u8 = undefined;
    const counts = std.fmt.bufPrint(&counts_buf, "{d} panels ({d} out of compliance) · {d} tiles · {d} labels · {d} missing glyphs · {d} overflows · {d} in margins", .{
        state.model.panels.items.len, state.panel_issues.len, tiles, labels, missing, overflow, state.intrusions.len,
    }) catch "";
    dvui.labelNoFmt(@src(), counts, .{}, field);

    const hint = switch (state.tool) {
        .select => state.status,
        .add_panel => "Add panel: drag out its outline · Esc cancels",
        .add_label => "Add label: click on the panel to place it · Esc cancels",
    };
    dvui.labelNoFmt(@src(), hint, .{}, field.override(.{ .expand = .horizontal }).override(muted));

    var right_buf: [160]u8 = undefined;
    const font = if (state.fonts.len > 0) state.fonts[state.font_choice].name else "-";
    const right = std.fmt.bufPrint(&right_buf, "{s} · zoom {d:.2} px/mm · {d:.1} ms", .{ font, state.view.ppm, state.solve_ms }) catch "";
    dvui.labelNoFmt(@src(), right, .{}, field.override(muted));
}
