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

const geom = engine.geom;
const Model = layout.Model;
const TileId = layout.TileId;

pub const dvui_app: dvui.App = .{
    .config = .{ .options = .{
        .size = .{ .w = 1500, .h = 820 },
        .min_size = .{ .w = 800, .h = 500 },
        .title = "Graven",
        .app = "Graven",
        .org = "com.mnemopyx.graven",
    } },
    .frameFn = frame,
    .initFn = init,
    .deinitFn = deinit,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{ .logFn = dvui.App.logFn };

const default_font = "/usr/share/fonts/opentype/inter/Inter-Medium.otf";

const Font = struct { name: []const u8, path: []const u8 };

const State = struct {
    gpa: std.mem.Allocator,
    fonts: []Font = &.{},
    font_choice: usize = 0,
    font_loaded: ?usize = null,
    face: ?*engine.Face = null,
    faces: [1]*engine.Face = undefined,
    model: Model,
    panel: usize = 0,
    labels: ?layout.Labels = null,
    placed: ?layout.place.Placed = null,
    placed_rev: u64 = std.math.maxInt(u64),
    solve_ms: f64 = 0,
    flat: Flat,
    view: View = .{},
    selected: ?TileId = null,
    status: []const u8 = "",
};

/// The canvas view: the mm point at the canvas centre, and physical pixels
/// per mm. Fitted to the panel until the user zooms or pans.
const View = struct {
    cx: f64 = 0,
    cy: f64 = 0,
    ppm: f64 = 0,
    fit: bool = true,

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

/// Label outlines flattened to polylines in mm, per render, at a tolerance
/// matched to the zoom. Rebuilt when the zoom changes a lot or the panel is
/// re-solved (renders may be freed then).
const Flat = struct {
    arena: std.heap.ArenaAllocator,
    map: std.AutoHashMapUnmanaged(*const engine.Render, []const []const geom.Point) = .empty,
    tol: f64 = 0,

    fn reset(f: *Flat, tol: f64) void {
        f.map = .empty;
        _ = f.arena.reset(.retain_capacity);
        f.tol = tol;
    }

    fn get(f: *Flat, r: *const engine.Render, faces: []const *engine.Face) ![]const []const geom.Point {
        if (f.map.get(r)) |c| return c;
        const a = f.arena.allocator();
        var contours: std.ArrayList([]const geom.Point) = .empty;
        for (try r.outlines(a, faces)) |o| for (o.contours) |c| {
            var pts: std.ArrayList(geom.Point) = .empty;
            for (c.segments) |s| try flatten(a, &pts, s, f.tol);
            try contours.append(a, pts.items);
        };
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
    state = .{ .gpa = gpa, .model = .init(gpa), .flat = .{ .arena = .init(gpa) } };
    state.fonts = listFonts(gpa) catch &.{};
    for (state.fonts, 0..) |f, i| if (std.mem.eql(u8, f.path, default_font)) {
        state.font_choice = i;
    };
    const main_style = try state.model.addStyle("legend", .{ .upright = 0, .cap_height = 2.6 });
    const small = try state.model.addStyle("legend words", .{ .upright = 0, .cap_height = 1.6 });
    state.panel = try samples.pc_keyboard.build(gpa, &state.model, .{ .main = main_style, .small = small });
}

fn deinit(_: *dvui.Window) void {
    if (state.placed) |*p| p.deinit();
    if (state.labels) |*l| l.deinit();
    if (state.face) |f| f.deinit();
    state.flat.arena.deinit();
    state.model.deinit();
}

/// Installed outline fonts from fontconfig, sorted by name.
fn listFonts(gpa: std.mem.Allocator) ![]Font {
    const r = try std.process.run(gpa, dvui.io, .{ .argv = &.{ "fc-list", "--format", "%{family[0]} %{style[0]}\t%{file}\n" } });
    defer gpa.free(r.stderr);
    var list: std.ArrayList(Font) = .empty;
    var lines = std.mem.splitScalar(u8, r.stdout, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const path = line[tab + 1 ..];
        if (!std.mem.endsWith(u8, path, ".otf") and !std.mem.endsWith(u8, path, ".ttf")) continue;
        try list.append(gpa, .{ .name = line[0..tab], .path = path });
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
        const face = try engine.Face.init(state.gpa, bytes, 0);
        if (state.placed) |*p| p.deinit();
        state.placed = null;
        if (state.labels) |*l| l.deinit();
        if (state.face) |old| old.deinit();
        state.face = face;
        state.faces = .{face};
        state.labels = .init(state.gpa, &state.faces);
        state.font_loaded = state.font_choice;
        state.placed_rev = std.math.maxInt(u64);
    }
    const labels = if (state.labels) |*l| l else return;
    if (state.placed_rev == state.model.revision and state.placed != null) return;
    const t0: std.Io.Timestamp = .now(dvui.io, .awake);
    const placed = try layout.solve(state.gpa, &state.model, state.panel, labels);
    state.solve_ms = @as(f64, @floatFromInt(t0.untilNow(dvui.io, .awake).toNanoseconds())) / 1e6;
    if (state.placed) |*p| p.deinit();
    state.placed = placed;
    state.placed_rev = state.model.revision;
    state.flat.reset(state.flat.tol);
}

fn frame() !dvui.App.Result {
    try update();

    var root = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both, .background = true, .style = .window });
    defer root.deinit();

    if (menu()) |r| return r;

    {
        var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
        defer body.deinit();
        treePane();
        canvas();
        try propertiesPane();
    }
    statusBar();
    return .ok;
}

fn menu() ?dvui.App.Result {
    var m = dvui.menu(@src(), .horizontal, .{ .expand = .horizontal, .background = true });
    defer m.deinit();
    if (dvui.menuItemLabel(@src(), "File", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        if (dvui.menuItemLabel(@src(), "Quit", .{}, .{ .expand = .horizontal }) != null) return .close;
    }
    if (dvui.menuItemLabel(@src(), "View", .{ .submenu = true }, .{})) |r| {
        var fw = dvui.floatingMenu(@src(), .{ .from = r }, .{});
        defer fw.deinit();
        if (dvui.menuItemLabel(@src(), "Fit panel", .{}, .{ .expand = .horizontal }) != null) {
            state.view.fit = true;
            m.close();
        }
    }
    return null;
}

/// The component tree: panel, rows, tiles.
fn treePane() void {
    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = 230 }, .max_size_content = .width(230), .expand = .vertical, .border = .{ .w = 1 } });
    defer pane.deinit();
    const panel = state.model.panels.items[state.panel];
    dvui.labelNoFmt(@src(), panel.name, .{}, .{ .font = .theme(.heading), .padding = .all(6) });
    var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
    defer scroll.deinit();
    for (panel.regions.items, 0..) |region, ri| {
        for (region.rows.items, 0..) |row, rowi| {
            var name_buf: [32]u8 = undefined;
            const title = std.fmt.bufPrint(&name_buf, "{s} · row {d}", .{ region.name, rowi + 1 }) catch "row";
            if (dvui.expander(@src(), title, .{ .default_expanded = rowi == 0 }, .{ .expand = .horizontal, .id_extra = ri * 1000 + rowi })) {
                var inner = dvui.box(@src(), .{ .dir = .vertical }, .{ .margin = .{ .x = 14 }, .id_extra = ri * 1000 + rowi, .expand = .horizontal });
                defer inner.deinit();
                for (row.places.items, 0..) |p, i| {
                    const t = state.model.tileConst(p.tile);
                    const legend = if (t.slots.items.len > 0) t.slots.items[0].content else "";
                    const selected = state.selected == p.tile;
                    if (dvui.labelClick(@src(), "{s}  {s}", .{ t.designator, legend }, .{}, .{
                        .id_extra = i,
                        .expand = .horizontal,
                        .background = selected,
                        .color_fill = if (selected) .{ .color = dvui.themeGet().focus.opacity(0.25) } else null,
                    })) state.selected = p.tile;
                }
            }
        }
    }
}

const colors = struct {
    const paper: dvui.Color = .{ .r = 0xfb, .g = 0xfa, .b = 0xf7 };
    const body: dvui.Color = .{ .r = 0xe4, .g = 0xe2, .b = 0xdc };
    const edge: dvui.Color = .{ .r = 0x9a, .g = 0x97, .b = 0x8f };
    const face: dvui.Color = .{ .r = 0xf6, .g = 0xf5, .b = 0xf1 };
    const ink: dvui.Color = .{ .r = 0x1d, .g = 0x1d, .b = 0x1b };
    const missing: dvui.Color = .{ .r = 0xf6, .g = 0xd5, .b = 0xcf };
    const overflow: dvui.Color = .{ .r = 0xc2, .g = 0x41, .b = 0x2d };
};

/// The canvas: the placed panel at true proportions. Wheel zooms about the
/// pointer, dragging pans, a click selects a tile.
fn canvas() void {
    var box = dvui.box(@src(), .{}, .{ .expand = .both, .background = true, .color_fill = .{ .color = colors.paper } });
    defer box.deinit();
    const placed = if (state.placed) |*p| p else return;
    const area = box.data().contentRectScale().r;
    if (area.w <= 0 or area.h <= 0) return;

    if (state.view.fit) {
        const b = placed.bounds;
        state.view = .{
            .cx = (b.x0 + b.x1) / 2,
            .cy = (b.y0 + b.y1) / 2,
            .ppm = 0.94 * @min(area.w / b.width(), area.h / b.height()),
        };
    }
    const clip = dvui.clip(area);
    defer dvui.clipSet(clip);

    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, box.data())) continue;
        if (e.evt != .mouse) continue;
        const me = e.evt.mouse;
        switch (me.action) {
            .wheel_y => |dy| {
                e.handle(@src(), box.data());
                const at = state.view.toMm(area, me.p);
                const z = @exp(@log(1.003) * @as(f64, dy));
                state.view.ppm *= z;
                state.view.fit = false;
                // Keep the point under the pointer fixed.
                state.view.cx = at.x - (at.x - state.view.cx) / z;
                state.view.cy = at.y - (at.y - state.view.cy) / z;
                dvui.refresh(null, @src(), box.data().id);
            },
            .press => if (me.button.pointer() or me.button == .middle) {
                e.handle(@src(), box.data());
                dvui.captureMouse(box.data(), e.num);
                dvui.dragPreStart(me.button, me.p, .{});
            },
            .motion => if (dvui.captured(box.data().id)) {
                if (dvui.dragging(me, null)) |d| {
                    e.handle(@src(), box.data());
                    state.view.fit = false;
                    state.view.cx -= d.x / state.view.ppm;
                    state.view.cy += d.y / state.view.ppm;
                    dvui.refresh(null, @src(), box.data().id);
                }
            },
            .release => if (dvui.captured(box.data().id)) {
                e.handle(@src(), box.data());
                if (dvui.dragging(me, null) == null) {
                    const at = state.view.toMm(area, me.p);
                    state.selected = null;
                    for (placed.tiles) |t| {
                        if (at.x >= t.body.x0 and at.x <= t.body.x1 and at.y >= t.body.y0 and at.y <= t.body.y1) state.selected = t.id;
                    }
                }
                dvui.captureMouse(null, e.num);
                dvui.dragEnd(me.button);
            },
            else => {},
        }
    }

    const radius: f32 = @floatCast(1.0 * state.view.ppm);
    for (placed.tiles) |t| {
        const flagged = tileFlag(placed, t.id);
        const body = state.view.rect(area, t.body);
        body.fill(.round(radius), .{ .color = .{ .color = colors.body } });
        body.stroke(.round(radius), .{ .thickness = 1, .color = .{ .color = if (state.selected == t.id) dvui.themeGet().focus else colors.edge } });
        state.view.rect(area, t.face).fill(.round(radius), .{ .color = .{ .color = if (flagged.missing) colors.missing else colors.face } });
        if (flagged.overflow) state.view.rect(area, t.face).stroke(.round(radius), .{ .thickness = 1.5, .color = .{ .color = colors.overflow } });
        if (state.selected == t.id) body.stroke(.round(radius), .{ .thickness = 3, .color = .{ .color = dvui.themeGet().focus } });
    }

    // Re-flatten when the zoom has moved more than 2x since the last time.
    const tol = 0.2 / state.view.ppm;
    if (state.flat.tol == 0 or tol < state.flat.tol / 2 or tol > state.flat.tol * 2) state.flat.reset(tol);
    const lifo = dvui.currentWindow().lifo();
    for (placed.labels) |l| {
        const contours = state.flat.get(l.render, &state.faces) catch continue;
        const paths = lifo.alloc(dvui.Path, contours.len) catch continue;
        defer lifo.free(paths);
        var made: usize = 0;
        defer for (paths[0..made]) |p| lifo.free(p.points);
        for (contours, paths) |c, *p| {
            const pts = lifo.alloc(dvui.Point.Physical, c.len) catch break;
            for (c, pts) |q, *o| o.* = state.view.toPx(area, .{ .x = q.x + l.origin.x, .y = q.y + l.origin.y });
            p.* = .{ .points = pts };
            made += 1;
        }
        dvui.Path.fill(paths[0..made], .{ .color = .{ .color = colors.ink }, .fade = 1 });
    }
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

/// Font choice, then the selected tile's properties and legends.
fn propertiesPane() !void {
    var pane = dvui.box(@src(), .{ .dir = .vertical }, .{ .min_size_content = .{ .w = 300 }, .max_size_content = .width(300), .expand = .vertical, .border = .{ .x = 1 }, .padding = .all(8) });
    defer pane.deinit();

    dvui.labelNoFmt(@src(), "Legend font", .{}, .{ .font = .theme(.heading) });
    if (state.fonts.len > 0) {
        var names = try dvui.currentWindow().lifo().alloc([]const u8, state.fonts.len);
        defer dvui.currentWindow().lifo().free(names);
        for (state.fonts, 0..) |f, i| names[i] = f.name;
        _ = dvui.dropdown(@src(), names, .{ .choice = &state.font_choice }, .{}, .{ .expand = .horizontal });
        var row = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer row.deinit();
        if (dvui.button(@src(), "Previous", .{}, .{ .expand = .horizontal })) {
            state.font_choice = (state.font_choice + state.fonts.len - 1) % state.fonts.len;
        }
        if (dvui.button(@src(), "Next", .{}, .{ .expand = .horizontal })) {
            state.font_choice = (state.font_choice + 1) % state.fonts.len;
        }
    } else {
        dvui.labelNoFmt(@src(), "No fonts found (fc-list)", .{}, .{});
    }

    _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 12 } });
    const id = state.selected orelse {
        dvui.labelNoFmt(@src(), "Select a tile on the canvas or in the tree.", .{}, .{});
        return;
    };
    const t = state.model.tileConst(id);
    dvui.label(@src(), "Tile {s}", .{t.designator}, .{ .font = .theme(.heading) });
    dvui.label(@src(), "Size {d} x {d} u", .{ t.w, t.h }, .{});
    if (state.placed) |*p| if (p.findTile(id)) |pt| {
        dvui.label(@src(), "Body {d:.2} x {d:.2} mm at ({d:.2}, {d:.2})", .{ pt.body.width(), pt.body.height(), pt.body.x0, pt.body.y0 }, .{});
    };

    for (t.slots.items, 0..) |slot, si| {
        _ = dvui.spacer(@src(), .{ .min_size_content = .{ .h = 8 }, .id_extra = si });
        dvui.label(@src(), "Slot {s} · style {s}", .{ slot.name, state.model.styles.items[slot.style].name }, .{ .id_extra = si });
        var te = dvui.textEntry(@src(), .{ .text_initial = slot.content }, .{
            .expand = .horizontal,
            .id_extra = @backingInt(id) * 16 + si,
        });
        const changed = te.text_changed;
        const text = te.textGet();
        te.deinit();
        if (changed) try state.model.setContent(id, slot.name, text);
    }

    if (state.placed) |*p| {
        for (p.issues, 0..) |i, k| if (i.tile == id) {
            dvui.label(@src(), "{s}", .{@tagName(i.kind)}, .{ .id_extra = k, .color_text = .{ .color = colors.overflow } });
        };
    }
}

fn statusBar() void {
    var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal, .background = true, .border = .{ .y = 1 }, .padding = .{ .x = 8, .y = 3, .w = 8, .h = 3 } });
    defer bar.deinit();
    const p = if (state.placed) |*p| p else return;
    var missing: usize = 0;
    var overflow: usize = 0;
    for (p.issues) |i| switch (i.kind) {
        .missing_glyph => missing += 1,
        .label_overflow, .row_overflow => overflow += 1,
        else => {},
    };
    const font = if (state.fonts.len > 0) state.fonts[state.font_choice].name else "-";
    dvui.label(@src(), "{s} · {d} tiles · {d} labels · solved in {d:.1} ms · {d} missing glyphs · {d} overflows · zoom {d:.2} px/mm", .{
        font, p.tiles.len, p.labels.len, state.solve_ms, missing, overflow, state.view.ppm,
    }, .{});
}
