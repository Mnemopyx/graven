//! The interface's elements, named (decided 2026-11-20): every field,
//! button, choice, toggle and shown value has an id in a logical hierarchy
//! of groups (what it is about: the object's kind, then the aspect), never
//! the panes, sections or dialogs it happens to be drawn in. Moving an
//! element elsewhere does not rename it.
//!
//! Ids are dotted paths, each part kebab-case (`track.origin.across`,
//! `track.flow.show`), as action names are. A button's id is its action's
//! name: the button, the action's key, its menu item and a script share
//! one name.
//!
//! The registry is the discovery path: `children` walks it group by group
//! (`track` → `origin` → `across`); the app says which elements are on
//! screen now (main.zig, `testing_api.discover`). Drawing code places an
//! element by id (`main.zig`'s `…E` helpers) and takes its label from
//! here; it no longer coins names. Everything is checked when built: a
//! malformed or repeated id, an element whose group is not declared, a
//! lookup of an unknown id; and when drawn: an element the registry does
//! not have is logged (which fails the GUI tests).
//!
//! A part `*` stands for any one name or number: the instances of a
//! repeated group (`panel.fab.layer.*.name`: `panel.fab.layer.2.name`).
//!
//! Every button is an action: the keymap takes the registry's buttons'
//! actions (`button_actions`) into its own, so a key, a menu item or a
//! script can run any of them.

const std = @import("std");

pub const Kind = enum {
    /// Text or a number typed in, taken on accept.
    field,
    /// Runs its action.
    button,
    /// One of a list.
    choice,
    /// On or off.
    toggle,
    /// Shown, not edited.
    value,
};

pub const Element = struct {
    id: []const u8,
    kind: Kind,
    /// Its label (the default; a few say more when drawn: "Make tracks of
    /// its 6 rows").
    label: []const u8,
    /// A button's action (its id, unless given).
    action: ?[]const u8 = null,
};

pub const Group = struct {
    id: []const u8,
    /// What its elements are about.
    label: []const u8,
};

pub const groups = [_]Group{
    .{ .id = "track", .label = "A track or a region (rows or columns added as needed)" },
    .{ .id = "track.origin", .label = "Where it starts, mm in its panel" },
    .{ .id = "track.flow", .label = "The flow it holds or continues" },
    .{ .id = "flows", .label = "The document's flows" },
    .{ .id = "flow", .label = "A flow" },
    .{ .id = "panel", .label = "A panel" },
    // Generated from the properties' code (2026-11-20); each group's label
    // is its id until it is written.
    .{ .id = "art", .label = "art" },
    .{ .id = "art.shape", .label = "art.shape" },
    .{ .id = "canvas", .label = "canvas" },
    .{ .id = "checks", .label = "checks" },
    .{ .id = "checks.results", .label = "checks.results" },
    .{ .id = "constraint", .label = "constraint" },
    .{ .id = "constraints", .label = "constraints" },
    .{ .id = "dialog", .label = "dialog" },
    .{ .id = "dialog.constrain", .label = "dialog.constrain" },
    .{ .id = "dialog.contention", .label = "dialog.contention" },
    .{ .id = "dialog.display", .label = "dialog.display" },
    .{ .id = "dialog.export", .label = "dialog.export" },
    .{ .id = "dialog.file", .label = "dialog.file" },
    .{ .id = "dialog.image", .label = "dialog.image" },
    .{ .id = "dialog.layout", .label = "dialog.layout" },
    .{ .id = "dialog.leave", .label = "dialog.leave" },
    .{ .id = "dialog.recovery", .label = "dialog.recovery" },
    .{ .id = "dialog.size", .label = "dialog.size" },
    .{ .id = "expression", .label = "expression" },
    .{ .id = "expression.param", .label = "expression.param" },
    .{ .id = "expression.style", .label = "expression.style" },
    .{ .id = "expression.style.face", .label = "expression.style.face" },
    .{ .id = "file", .label = "file" },
    .{ .id = "flow.track", .label = "The flow's tracks, in order" },
    .{ .id = "plan.part", .label = "A plan's parts, by panel" },
    .{ .id = "palette", .label = "The content palette at the flow cursor" },
    .{ .id = "palette.key", .label = "The palette's tiles, by size" },
    .{ .id = "palette.blank", .label = "The palette's blanks, by size" },
    .{ .id = "move", .label = "The move palette's arrows" },
    .{ .id = "constraints.origin-at", .label = "Which point of it is its origin" },
    .{ .id = "style.rules.*", .label = "A rule of the style" },
    .{ .id = "grid.add-stamp", .label = "Stamps to add to a grid" },
    .{ .id = "materials.library", .label = "The materials library" },
    .{ .id = "material.plan", .label = "The plans using a material" },
    .{ .id = "processes.builtin", .label = "The built-in process profiles" },
    .{ .id = "styles.package", .label = "Styles from a math package" },
    .{ .id = "frame", .label = "frame" },
    .{ .id = "grid", .label = "grid" },
    .{ .id = "grid.stamp", .label = "grid.stamp" },
    .{ .id = "grid.stamp.*", .label = "grid.stamp.*" },
    .{ .id = "group", .label = "group" },
    .{ .id = "image", .label = "image" },
    .{ .id = "instance", .label = "instance" },
    .{ .id = "layer", .label = "layer" },
    .{ .id = "layers", .label = "layers" },
    .{ .id = "material", .label = "material" },
    .{ .id = "materials", .label = "materials" },
    .{ .id = "panel.checks", .label = "panel.checks" },
    .{ .id = "panel.checks.limit", .label = "panel.checks.limit" },
    .{ .id = "panel.editing", .label = "panel.editing" },
    .{ .id = "panel.fab", .label = "panel.fab" },
    .{ .id = "panel.fab.layer", .label = "panel.fab.layer" },
    .{ .id = "panel.fab.layer.*", .label = "panel.fab.layer.*" },
    .{ .id = "panel.grids", .label = "panel.grids" },
    .{ .id = "panel.margins", .label = "panel.margins" },
    .{ .id = "paragraph", .label = "paragraph" },
    .{ .id = "plan", .label = "plan" },
    .{ .id = "plan.checks", .label = "plan.checks" },
    .{ .id = "plan.operation", .label = "plan.operation" },
    .{ .id = "plan.operation.*", .label = "plan.operation.*" },
    .{ .id = "plan.warnings", .label = "plan.warnings" },
    .{ .id = "plans", .label = "plans" },
    .{ .id = "process", .label = "process" },
    .{ .id = "process.panel", .label = "process.panel" },
    .{ .id = "processes", .label = "processes" },
    .{ .id = "prototype", .label = "prototype" },
    .{ .id = "prototype.art-layer", .label = "prototype.art-layer" },
    .{ .id = "prototype.art-layer.*", .label = "prototype.art-layer.*" },
    .{ .id = "prototype.sketch", .label = "prototype.sketch" },
    .{ .id = "prototype.slot", .label = "prototype.slot" },
    .{ .id = "prototype.slot.*", .label = "prototype.slot.*" },
    .{ .id = "prototypes", .label = "prototypes" },
    .{ .id = "row", .label = "row" },
    .{ .id = "selection", .label = "selection" },
    .{ .id = "sheet", .label = "sheet" },
    .{ .id = "sheet.cell", .label = "sheet.cell" },
    .{ .id = "sheets", .label = "sheets" },
    .{ .id = "sketch", .label = "sketch" },
    .{ .id = "sketch-mode", .label = "sketch-mode" },
    .{ .id = "sketch-panel", .label = "sketch-panel" },
    .{ .id = "sketch-view", .label = "sketch-view" },
    .{ .id = "sketch.constrain", .label = "sketch.constrain" },
    .{ .id = "sketch.palette", .label = "sketch.palette" },
    .{ .id = "sketch.parameters", .label = "sketch.parameters" },
    .{ .id = "sketch.physical", .label = "sketch.physical" },
    .{ .id = "sketch.step", .label = "sketch.step" },
    .{ .id = "sketch.summary", .label = "sketch.summary" },
    .{ .id = "sketch.tool", .label = "sketch.tool" },
    .{ .id = "sketches", .label = "sketches" },
    .{ .id = "status", .label = "status" },
    .{ .id = "style", .label = "style" },
    .{ .id = "style.face", .label = "style.face" },
    .{ .id = "style.rules", .label = "style.rules" },
    .{ .id = "styles", .label = "styles" },
    .{ .id = "tile", .label = "tile" },
    .{ .id = "tile.sketch", .label = "tile.sketch" },
    .{ .id = "tile.slot", .label = "tile.slot" },
    .{ .id = "tile.slot.*", .label = "tile.slot.*" },
    .{ .id = "tool", .label = "tool" },
    .{ .id = "guide", .label = "guide" },
    .{ .id = "tool.add-tracks", .label = "tool.add-tracks" },
    .{ .id = "view", .label = "view" },
    .{ .id = "ribbon", .label = "The ribbon: the active view's tools, under the menu bar; a ▾ (or the key held) for more" },
    .{ .id = "ribbon.drop", .label = "The ▾ after a ribbon button: what more it has" },
    .{ .id = "ribbon.shape", .label = "What Add shape draws" },
    .{ .id = "ribbon.tracks", .label = "What Add rows draws: rows, columns or one track" },
    .{ .id = "layers-palette", .label = "The Layers palette: the active view's layers, top first" },
    .{ .id = "layers-palette.*", .label = "A layer in the Layers palette" },
    .{ .id = "views", .label = "The document's views: windows (splits), each with its tabs, a quick-view of contexts recently shown" },
    .{ .id = "views.tabs", .label = "A window's tabs (its quick-view of contexts)" },
    .{ .id = "views.contexts", .label = "The contexts a view can show (canvas and frames, legend sheets, manufacturing plans)" },
    .{ .id = "view.place-in", .label = "Where the view can be placed" },
    .{ .id = "worksheet", .label = "worksheet" },
    .{ .id = "worksheet.margins", .label = "worksheet.margins" },
};

pub const all = [_]Element{
    // A track or region.
    .{ .id = "track.name", .kind = .field, .label = "Name" },
    .{ .id = "track.origin.across", .kind = .field, .label = "Origin across, mm" },
    .{ .id = "track.origin.up", .kind = .field, .label = "Origin up, mm" },
    .{ .id = "track.kind", .kind = .value, .label = "Kind" },
    .{ .id = "track.direction", .kind = .field, .label = "Direction, °" },
    .{ .id = "track.rotation", .kind = .field, .label = "Rotation, °" },
    .{ .id = "track.orientation-issue", .kind = .value, .label = "Issue" },
    .{ .id = "track.length", .kind = .field, .label = "Length, u" },
    .{ .id = "track.depth", .kind = .field, .label = "Depth, rows" },
    .{ .id = "track.size", .kind = .value, .label = "Size" },
    .{ .id = "track.pitch", .kind = .value, .label = "Pitch" },
    .{ .id = "track.rows", .kind = .value, .label = "Rows" },
    .{ .id = "track.items", .kind = .value, .label = "Items" },
    .{ .id = "track.key-prefix", .kind = .field, .label = "Key name prefix" },
    .{ .id = "track.name-keys", .kind = .button, .label = "Name keys in order" },
    .{ .id = "track.outside-issue", .kind = .value, .label = "Issue" },
    .{ .id = "track.prototype", .kind = .value, .label = "Prototype" },
    .{ .id = "track.style", .kind = .value, .label = "Sized to" },
    .{ .id = "track.make-tracks", .kind = .button, .label = "Make tracks of its rows" },
    .{ .id = "track.remove", .kind = .button, .label = "Remove track" },
    .{ .id = "track.content", .kind = .choice, .label = "Content" },
    .{ .id = "track.indent", .kind = .field, .label = "Indent, u" },
    .{ .id = "track.gap", .kind = .field, .label = "Row gap, u" },
    // Its flow.
    .{ .id = "track.flow.choice", .kind = .choice, .label = "Flow" },
    .{ .id = "track.flow.position", .kind = .value, .label = "In it" },
    .{ .id = "track.flow.show", .kind = .button, .label = "Show the flow" },
    .{ .id = "track.flow.before", .kind = .value, .label = "Continues" },
    .{ .id = "track.flow.after", .kind = .value, .label = "Goes on into" },
    .{ .id = "track.flow.join-after", .kind = .button, .label = "Join a track after this…" },
    .{ .id = "track.flow.take-out", .kind = .button, .label = "Take out of its flow" },
    // Flows, a flow, a panel.
    .{ .id = "flows.new", .kind = .button, .label = "New flow" },
    .{ .id = "flow.remove", .kind = .button, .label = "Remove flow" },
    .{ .id = "panel.edit", .kind = .button, .label = "Edit panel" },
    .{ .id = "panel.release", .kind = .button, .label = "Release panel" },
    // Generated from the properties' code (2026-11-20), by what each is
    // about; a `*` entry stands for a list of named things.
    .{ .id = "art.box", .kind = .value, .label = "Box" },
    .{ .id = "art.clearance", .kind = .field, .label = "Clearance, mm" },
    .{ .id = "art.move-out-from-under-it", .kind = .toggle, .label = "Move out from under it" },
    .{ .id = "art.moves", .kind = .value, .label = "Moves" },
    .{ .id = "art.name", .kind = .value, .label = "Name" },
    .{ .id = "art.shape.corner-radius", .kind = .field, .label = "Corner radius, mm" },
    .{ .id = "art.shape.cut-through-the-panel", .kind = .toggle, .label = "Cut through the panel" },
    .{ .id = "art.shape.cutout", .kind = .choice, .label = "Cutout" },
    .{ .id = "art.shape.diameter", .kind = .value, .label = "Diameter" },
    .{ .id = "art.shape.make-panel", .kind = .button, .label = "Make panel" },
    .{ .id = "art.shape.panel", .kind = .value, .label = "Panel" },
    .{ .id = "art.shape.shape", .kind = .value, .label = "Shape" },
    .{ .id = "art.tiles", .kind = .choice, .label = "Tiles" },
    .{ .id = "art.tracks-under-it", .kind = .choice, .label = "Tracks under it" },
    .{ .id = "canvas.language", .kind = .value, .label = "Language" },
    .{ .id = "canvas.line-art", .kind = .value, .label = "Line art" },
    .{ .id = "canvas.measures", .kind = .value, .label = "Measures" },
    .{ .id = "canvas.panels", .kind = .value, .label = "Panels" },
    .{ .id = "canvas.tracks", .kind = .value, .label = "Tracks" },
    .{ .id = "canvas.units", .kind = .choice, .label = "Units" },
    .{ .id = "checks.results.check-again", .kind = .button, .label = "Check again" },
    .{ .id = "checks.results.clear-results", .kind = .button, .label = "Clear results" },
    .{ .id = "constraint.place-it-as-at-first", .kind = .button, .label = "Place it as at first" },
    .{ .id = "constraint.remove", .kind = .button, .label = "Remove" },
    .{ .id = "constraint.value", .kind = .choice, .label = "Value" },
    .{ .id = "constraints.issue", .kind = .value, .label = "Issue" },
    .{ .id = "dialog.constrain.apply", .kind = .button, .label = "Apply", .action = "dialog.confirm" },
    .{ .id = "dialog.constrain.cancel", .kind = .button, .label = "Cancel", .action = "dialog.cancel" },
    .{ .id = "dialog.constrain.relation", .kind = .choice, .label = "Relation" },
    .{ .id = "dialog.constrain.value", .kind = .field, .label = "Value" },
    .{ .id = "dialog.contention.load-theirs", .kind = .button, .label = "Load theirs" },
    .{ .id = "dialog.contention.not-now", .kind = .button, .label = "Not now" },
    .{ .id = "dialog.contention.overwrite-with-mine", .kind = .button, .label = "Overwrite with mine" },
    .{ .id = "dialog.contention.save-mine-as", .kind = .button, .label = "Save mine as…" },
    .{ .id = "dialog.display.close", .kind = .button, .label = "Close" },
    .{ .id = "dialog.display.reset", .kind = .button, .label = "Reset" },
    .{ .id = "dialog.display.screen-size", .kind = .button, .label = "Screen size…" },
    .{ .id = "dialog.export.cancel", .kind = .button, .label = "Cancel", .action = "dialog.cancel" },
    .{ .id = "dialog.export.export", .kind = .button, .label = "Export", .action = "dialog.confirm" },
    .{ .id = "dialog.export.file", .kind = .choice, .label = "File" },
    .{ .id = "dialog.file.cancel", .kind = .button, .label = "Cancel", .action = "dialog.cancel" },
    .{ .id = "dialog.file.file", .kind = .choice, .label = "File" },
    .{ .id = "dialog.image.cancel", .kind = .button, .label = "Cancel", .action = "dialog.cancel" },
    .{ .id = "dialog.image.file", .kind = .choice, .label = "File" },
    .{ .id = "dialog.image.place", .kind = .button, .label = "Place", .action = "dialog.confirm" },
    .{ .id = "dialog.layout.cancel", .kind = .button, .label = "Cancel", .action = "dialog.cancel" },
    .{ .id = "dialog.layout.name", .kind = .choice, .label = "Name" },
    .{ .id = "dialog.layout.save", .kind = .button, .label = "Save", .action = "dialog.confirm" },
    .{ .id = "dialog.leave.cancel", .kind = .button, .label = "Cancel" },
    .{ .id = "dialog.leave.don-t-save", .kind = .button, .label = "Don't save" },
    .{ .id = "dialog.leave.save", .kind = .button, .label = "Save" },
    .{ .id = "dialog.recovery.cancel", .kind = .button, .label = "Cancel" },
    .{ .id = "dialog.recovery.discard-them", .kind = .button, .label = "Discard them" },
    .{ .id = "dialog.recovery.keep-them", .kind = .button, .label = "Keep them" },
    .{ .id = "dialog.size.cancel", .kind = .button, .label = "Cancel", .action = "dialog.cancel" },
    .{ .id = "dialog.size.save", .kind = .button, .label = "Save", .action = "dialog.confirm" },
    .{ .id = "dialog.size.use-estimate", .kind = .button, .label = "Use estimate" },
    .{ .id = "expression.at-the-cursor", .kind = .value, .label = "At the cursor" },
    .{ .id = "expression.editing", .kind = .value, .label = "Editing" },
    .{ .id = "expression.gap-before", .kind = .value, .label = "Gap before" },
    .{ .id = "expression.gap-after", .kind = .value, .label = "Gap after" },
    .{ .id = "expression.baseline", .kind = .value, .label = "Baseline" },
    .{ .id = "expression.box", .kind = .value, .label = "Box" },
    .{ .id = "expression.overrides", .kind = .value, .label = "Overrides" },
    .{ .id = "expression.style.based-on", .kind = .value, .label = "Based on" },
    .{ .id = "expression.style.faces", .kind = .value, .label = "Faces" },
    .{ .id = "file.engine", .kind = .value, .label = "Engine" },
    .{ .id = "file.saved", .kind = .value, .label = "Saved" },
    .{ .id = "flow.name", .kind = .choice, .label = "Name" },
    .{ .id = "flow.source", .kind = .value, .label = "Source" },
    .{ .id = "flow.track.holds", .kind = .value, .label = "Holds" },
    .{ .id = "flow.tracks", .kind = .value, .label = "Tracks" },
    .{ .id = "flows.flows", .kind = .value, .label = "Flows" },
    .{ .id = "flows.unplaced", .kind = .value, .label = "Unplaced" },
    .{ .id = "frame.boundary", .kind = .value, .label = "Boundary" },
    .{ .id = "frame.fit-frame-to-its-contents", .kind = .button, .label = "Fit frame to its contents" },
    .{ .id = "frame.groups", .kind = .value, .label = "Groups" },
    .{ .id = "frame.name", .kind = .value, .label = "Name" },
    .{ .id = "frame.panels", .kind = .value, .label = "Panels" },
    .{ .id = "grid.add-stamp.follow-it-on", .kind = .choice, .label = "Follow it on" },
    .{ .id = "grid.remove-grid", .kind = .button, .label = "Remove grid" },
    .{ .id = "grid.columns", .kind = .field, .label = "Columns" },
    .{ .id = "grid.first-point-across", .kind = .field, .label = "First point across, mm" },
    .{ .id = "grid.first-point-up", .kind = .field, .label = "First point up, mm" },
    .{ .id = "grid.followed-by", .kind = .value, .label = "Followed by" },
    .{ .id = "grid.follows", .kind = .value, .label = "Follows" },
    .{ .id = "grid.make-a-legend-sheet", .kind = .button, .label = "Make a legend sheet" },
    .{ .id = "grid.name", .kind = .value, .label = "Name" },
    .{ .id = "grid.on", .kind = .value, .label = "On" },
    .{ .id = "grid.points-removed", .kind = .choice, .label = "Points removed" },
    .{ .id = "grid.rows", .kind = .field, .label = "Rows" },
    .{ .id = "grid.show-the-grid-it-follows", .kind = .button, .label = "Show the grid it follows" },
    .{ .id = "grid.spacing-across", .kind = .field, .label = "Spacing across, mm" },
    .{ .id = "grid.spacing-down", .kind = .field, .label = "Spacing down, mm" },
    .{ .id = "grid.stamp.*.fill-empty-points", .kind = .button, .label = "Fill empty points" },
    .{ .id = "grid.stamp.*.height", .kind = .field, .label = "Height, mm" },
    .{ .id = "grid.stamp.*.instances", .kind = .value, .label = "Instances" },
    .{ .id = "grid.stamp.*.made-as", .kind = .choice, .label = "Made as" },
    .{ .id = "grid.stamp.*.offset-across", .kind = .field, .label = "Offset across, mm" },
    .{ .id = "grid.stamp.*.offset-up", .kind = .field, .label = "Offset up, mm" },
    .{ .id = "grid.stamp.*.prototype", .kind = .choice, .label = "Prototype" },
    .{ .id = "grid.stamp.*.remove-stamp", .kind = .button, .label = "Remove stamp" },
    .{ .id = "grid.stamp.*.width", .kind = .field, .label = "Width, mm" },
    .{ .id = "grid.stretch-across", .kind = .field, .label = "Stretch across" },
    .{ .id = "grid.stretch-down", .kind = .field, .label = "Stretch down" },
    .{ .id = "grid.x", .kind = .value, .label = "" },
    .{ .id = "group.in-group", .kind = .value, .label = "In group" },
    .{ .id = "group.members", .kind = .value, .label = "Members" },
    .{ .id = "group.moves", .kind = .value, .label = "Moves" },
    .{ .id = "group.name", .kind = .value, .label = "Name" },
    .{ .id = "group.ungroup", .kind = .button, .label = "Ungroup" },
    .{ .id = "image.height", .kind = .value, .label = "Height" },
    .{ .id = "image.moves", .kind = .value, .label = "Moves" },
    .{ .id = "image.name", .kind = .value, .label = "Name" },
    .{ .id = "image.pixels", .kind = .value, .label = "Pixels" },
    .{ .id = "image.place", .kind = .value, .label = "Place" },
    .{ .id = "image.remove-image", .kind = .button, .label = "Remove image" },
    .{ .id = "image.resolution", .kind = .value, .label = "Resolution" },
    .{ .id = "image.width", .kind = .field, .label = "Width, mm" },
    .{ .id = "instance.bind-to-the-nearest-point", .kind = .button, .label = "Bind to the nearest point" },
    .{ .id = "instance.box", .kind = .value, .label = "Box" },
    .{ .id = "instance.point", .kind = .value, .label = "Point" },
    .{ .id = "instance.remove-from-the-grid", .kind = .button, .label = "Remove from the grid" },
    .{ .id = "instance.spans-columns", .kind = .field, .label = "Spans columns" },
    .{ .id = "instance.spans-rows", .kind = .field, .label = "Spans rows" },
    .{ .id = "instance.stamp", .kind = .value, .label = "Stamp" },
    .{ .id = "layer.blend", .kind = .choice, .label = "Blend" },
    .{ .id = "layer.lock", .kind = .choice, .label = "Lock" },
    .{ .id = "layer.locked-nothing-on-it-can-be-picked", .kind = .toggle, .label = "Locked: nothing on it can be picked" },
    .{ .id = "layer.move-down", .kind = .button, .label = "Move down" },
    .{ .id = "layer.move-up", .kind = .button, .label = "Move up" },
    .{ .id = "layer.name", .kind = .value, .label = "Name" },
    .{ .id = "layer.new-objects", .kind = .value, .label = "New objects" },
    .{ .id = "layer.opacity", .kind = .field, .label = "Opacity, %" },
    .{ .id = "layer.output", .kind = .choice, .label = "Output" },
    .{ .id = "layer.place", .kind = .value, .label = "Place" },
    .{ .id = "layer.remove", .kind = .button, .label = "Remove" },
    .{ .id = "layer.shown", .kind = .choice, .label = "Shown" },
    .{ .id = "layer.visible", .kind = .toggle, .label = "Visible" },
    .{ .id = "layers.add-layer", .kind = .button, .label = "Add layer" },
    .{ .id = "material.colours", .kind = .value, .label = "Colours" },
    .{ .id = "material.comes-as", .kind = .value, .label = "Comes as" },
    .{ .id = "material.kind", .kind = .value, .label = "Kind" },
    .{ .id = "material.name", .kind = .field, .label = "Name" },
    .{ .id = "material.parts", .kind = .value, .label = "Parts" },
    .{ .id = "material.remove-this-material", .kind = .button, .label = "Remove this material" },
    .{ .id = "material.surface", .kind = .value, .label = "Surface" },
    .{ .id = "material.thicknesses", .kind = .value, .label = "Thicknesses, mm" },
    .{ .id = "material.under-it", .kind = .value, .label = "Under it" },
    .{ .id = "materials.materials", .kind = .value, .label = "Materials" },
    .{ .id = "panel.checks.check-this-panel", .kind = .button, .label = "Check this panel" },
    .{ .id = "panel.checks.checked", .kind = .value, .label = "Checked" },
    .{ .id = "panel.checks.part", .kind = .value, .label = "Part" },
    .{ .id = "panel.cutouts", .kind = .value, .label = "Cutouts" },
    .{ .id = "panel.editing.grid", .kind = .choice, .label = "Grid" },
    .{ .id = "panel.editing.grid-settings", .kind = .button, .label = "Grid settings" },
    .{ .id = "panel.editing.grids", .kind = .value, .label = "Grids" },
    .{ .id = "panel.editing.leave-panel-editing", .kind = .button, .label = "Leave panel editing" },
    .{ .id = "panel.editing.places", .kind = .choice, .label = "Places" },
    .{ .id = "panel.editing.stamps", .kind = .value, .label = "Stamps" },
    .{ .id = "panel.fab.layer.*.colour", .kind = .field, .label = "Colour" },
    .{ .id = "panel.fab.layer.*.colour-name", .kind = .field, .label = "Colour name" },
    .{ .id = "panel.fab.layer.*.depth", .kind = .field, .label = "Depth, mm" },
    .{ .id = "panel.fab.layer.*.earlier", .kind = .button, .label = "Earlier" },
    .{ .id = "panel.fab.layer.*.from", .kind = .choice, .label = "From" },
    .{ .id = "panel.fab.layer.*.goes", .kind = .choice, .label = "Goes" },
    .{ .id = "panel.fab.layer.*.later", .kind = .button, .label = "Later" },
    .{ .id = "panel.fab.layer.*.makes", .kind = .choice, .label = "Makes" },
    .{ .id = "panel.fab.layer.*.name", .kind = .field, .label = "Name" },
    .{ .id = "panel.fab.layer.*.offset", .kind = .field, .label = "Offset, mm" },
    .{ .id = "panel.fab.layer.*.remove-layer", .kind = .button, .label = "Remove layer" },
    .{ .id = "panel.fab.layer.*.slot", .kind = .choice, .label = "Slot" },
    .{ .id = "panel.fab.layer.*.starts-at", .kind = .choice, .label = "Starts at" },
    .{ .id = "panel.fab.layer.*.through-the-whole-part", .kind = .toggle, .label = "Through the whole part" },
    .{ .id = "panel.fab.thickness", .kind = .field, .label = "Thickness, mm" },
    .{ .id = "panel.grids.add-grid", .kind = .button, .label = "Add grid" },
    .{ .id = "panel.height", .kind = .field, .label = "Height, mm" },
    .{ .id = "panel.issue", .kind = .value, .label = "Issue" },
    .{ .id = "panel.margins.bottom", .kind = .field, .label = "Bottom, mm" },
    .{ .id = "panel.margins.left", .kind = .field, .label = "Left, mm" },
    .{ .id = "panel.margins.right", .kind = .field, .label = "Right, mm" },
    .{ .id = "panel.margins.top", .kind = .field, .label = "Top, mm" },
    .{ .id = "panel.name", .kind = .field, .label = "Name" },
    .{ .id = "panel.origin-across", .kind = .field, .label = "Origin across, mm" },
    .{ .id = "panel.origin-up", .kind = .field, .label = "Origin up, mm" },
    .{ .id = "panel.outline", .kind = .value, .label = "Outline" },
    .{ .id = "panel.regions", .kind = .value, .label = "Regions" },
    .{ .id = "panel.size", .kind = .value, .label = "Size" },
    .{ .id = "panel.width", .kind = .field, .label = "Width, mm" },
    .{ .id = "paragraph.between-lines", .kind = .field, .label = "Between lines, pt" },
    .{ .id = "paragraph.lines", .kind = .choice, .label = "Lines" },
    .{ .id = "paragraph.name", .kind = .field, .label = "Name" },
    .{ .id = "paragraph.space-after", .kind = .field, .label = "Space after, pt" },
    .{ .id = "paragraph.space-before", .kind = .field, .label = "Space before, pt" },
    .{ .id = "paragraph.style", .kind = .choice, .label = "Style" },
    .{ .id = "plan.add-an-operation", .kind = .button, .label = "Add an operation" },
    .{ .id = "plan.checks.check-this-plan", .kind = .button, .label = "Check this plan" },
    .{ .id = "plan.checks.clear-results", .kind = .button, .label = "Clear results" },
    .{ .id = "plan.checks.findings", .kind = .toggle, .label = "Findings" },
    .{ .id = "plan.checks.simulation", .kind = .toggle, .label = "Simulation" },
    .{ .id = "plan.export-this-plan-make-it-active", .kind = .button, .label = "Export this plan (make it active)" },
    .{ .id = "plan.exported", .kind = .value, .label = "Exported" },
    .{ .id = "plan.max-error", .kind = .field, .label = "Max error, mm" },
    .{ .id = "plan.name", .kind = .field, .label = "Name" },
    .{ .id = "plan.open-in-a-manufacturing-view", .kind = .button, .label = "Open in a manufacturing view" },
    .{ .id = "plan.operation.*.checked", .kind = .value, .label = "Checked" },
    .{ .id = "plan.operation.*.earlier", .kind = .button, .label = "Earlier" },
    .{ .id = "plan.operation.*.later", .kind = .button, .label = "Later" },
    .{ .id = "plan.operation.*.name", .kind = .field, .label = "Name" },
    .{ .id = "plan.operation.*.passes", .kind = .field, .label = "Passes" },
    .{ .id = "plan.operation.*.remove", .kind = .button, .label = "Remove" },
    .{ .id = "plan.operation.*.shown", .kind = .toggle, .label = "Shown" },
    .{ .id = "plan.remove-this-plan", .kind = .button, .label = "Remove this plan" },
    .{ .id = "plans.add-a-plan", .kind = .button, .label = "Add a plan" },
    .{ .id = "plans.exported", .kind = .value, .label = "Exported" },
    .{ .id = "plans.plans", .kind = .value, .label = "Plans" },
    .{ .id = "process.bed", .kind = .field, .label = "Bed " },
    .{ .id = "process.build-volume", .kind = .field, .label = "Build volume " },
    .{ .id = "process.class", .kind = .value, .label = "Class" },
    .{ .id = "process.colours", .kind = .value, .label = "Colours" },
    .{ .id = "process.depth-a-pass", .kind = .field, .label = "Depth a pass, mm" },
    .{ .id = "process.depths", .kind = .value, .label = "Depths" },
    .{ .id = "process.filament-slots", .kind = .field, .label = "Filament slots" },
    .{ .id = "process.first-layer", .kind = .field, .label = "First layer, mm" },
    .{ .id = "process.kerf", .kind = .field, .label = "Kerf, mm" },
    .{ .id = "process.layer-height", .kind = .field, .label = "Layer height, mm" },
    .{ .id = "process.line-width", .kind = .field, .label = "Line width, mm" },
    .{ .id = "process.name", .kind = .field, .label = "Name" },
    .{ .id = "process.nozzle", .kind = .field, .label = "Nozzle, mm" },
    .{ .id = "process.panels", .kind = .value, .label = "Panels" },
    .{ .id = "process.process", .kind = .value, .label = "Process" },
    .{ .id = "process.remove-this-profile", .kind = .button, .label = "Remove this profile" },
    .{ .id = "process.set-by", .kind = .value, .label = "Set by" },
    .{ .id = "process.spot", .kind = .field, .label = "Spot, mm" },
    .{ .id = "process.thickest-plate", .kind = .field, .label = "Thickest plate, mm" },
    .{ .id = "process.thickest-sheet", .kind = .field, .label = "Thickest sheet, mm" },
    .{ .id = "process.use-the-limits-its-settings-give", .kind = .button, .label = "Use the limits its settings give" },
    .{ .id = "processes.profiles", .kind = .value, .label = "Profiles" },
    .{ .id = "prototype.add-keycap-art", .kind = .button, .label = "Add keycap art" },
    .{ .id = "prototype.redraw-from-insets", .kind = .button, .label = "Redraw from insets" },
    .{ .id = "prototype.remove-art", .kind = .button, .label = "Remove art" },
    .{ .id = "prototype.as-a-letter", .kind = .choice, .label = "As a letter" },
    .{ .id = "prototype.baseline", .kind = .field, .label = "Baseline, u up" },
    .{ .id = "prototype.binds-to-its-word", .kind = .toggle, .label = "Binds to its word" },
    .{ .id = "prototype.body-inset-bottom", .kind = .field, .label = "Body inset bottom, mm" },
    .{ .id = "prototype.body-inset-left", .kind = .field, .label = "Body inset left, mm" },
    .{ .id = "prototype.body-inset-right", .kind = .field, .label = "Body inset right, mm" },
    .{ .id = "prototype.body-inset-top", .kind = .field, .label = "Body inset top, mm" },
    .{ .id = "prototype.dropped-at-a-wrap", .kind = .toggle, .label = "Dropped at a wrap" },
    .{ .id = "prototype.face-inset-bottom", .kind = .field, .label = "Face inset bottom, mm" },
    .{ .id = "prototype.face-inset-left", .kind = .field, .label = "Face inset left, mm" },
    .{ .id = "prototype.face-inset-right", .kind = .field, .label = "Face inset right, mm" },
    .{ .id = "prototype.face-inset-top", .kind = .field, .label = "Face inset top, mm" },
    .{ .id = "prototype.grows", .kind = .choice, .label = "Grows" },
    .{ .id = "prototype.heights", .kind = .field, .label = "Heights, u" },
    .{ .id = "prototype.in-the-flow", .kind = .choice, .label = "In the flow" },
    .{ .id = "prototype.look", .kind = .value, .label = "Look" },
    .{ .id = "prototype.name", .kind = .field, .label = "Name" },
    .{ .id = "prototype.sketch.apply-again", .kind = .button, .label = "Apply again" },
    .{ .id = "prototype.sketch.apply-sketch-to-this-prototype", .kind = .button, .label = "Apply sketch to this prototype" },
    .{ .id = "prototype.sketch.copy-of", .kind = .value, .label = "Copy of" },
    .{ .id = "prototype.sketch.height-from", .kind = .value, .label = "Height from" },
    .{ .id = "prototype.sketch.offset", .kind = .value, .label = "Offset" },
    .{ .id = "prototype.sketch.parameters", .kind = .value, .label = "Parameters" },
    .{ .id = "prototype.sketch.remove", .kind = .button, .label = "Remove" },
    .{ .id = "prototype.sketch.sketch", .kind = .choice, .label = "Sketch" },
    .{ .id = "prototype.sketch.sketches", .kind = .value, .label = "Sketches" },
    .{ .id = "prototype.sketch.width-from", .kind = .value, .label = "Width from" },
    .{ .id = "prototype.add-track", .kind = .button, .label = "Add track" },
    .{ .id = "prototype.slot.*.inset-bottom", .kind = .field, .label = "Inset bottom, mm" },
    .{ .id = "prototype.slot.*.inset-left", .kind = .field, .label = "Inset left, mm" },
    .{ .id = "prototype.slot.*.inset-right", .kind = .field, .label = "Inset right, mm" },
    .{ .id = "prototype.slot.*.inset-top", .kind = .field, .label = "Inset top, mm" },
    .{ .id = "prototype.slot.*.name", .kind = .field, .label = "Name" },
    .{ .id = "prototype.slot.*.remove-track", .kind = .button, .label = "Remove track" },
    .{ .id = "prototype.slot.*.runs", .kind = .choice, .label = "Runs" },
    .{ .id = "prototype.slot.*.set-from", .kind = .choice, .label = "Set from" },
    .{ .id = "prototype.spacer", .kind = .toggle, .label = "Spacer" },
    .{ .id = "prototype.taller", .kind = .toggle, .label = "Taller" },
    .{ .id = "prototype.unit", .kind = .field, .label = "Unit, mm per u" },
    .{ .id = "prototype.used-by", .kind = .value, .label = "Used by" },
    .{ .id = "prototype.wider", .kind = .toggle, .label = "Wider" },
    .{ .id = "prototype.widths", .kind = .field, .label = "Widths, u" },
    .{ .id = "prototypes.prototypes", .kind = .value, .label = "Prototypes" },
    .{ .id = "row.column", .kind = .value, .label = "Column" },
    .{ .id = "row.items", .kind = .value, .label = "Items" },
    .{ .id = "row.placed", .kind = .value, .label = "Placed" },
    .{ .id = "row.row", .kind = .value, .label = "Row" },
    .{ .id = "selection.copy-to-a-new-frame", .kind = .button, .label = "Copy to a new frame" },
    .{ .id = "selection.group", .kind = .button, .label = "Group" },
    .{ .id = "selection.move-to-a-new-frame", .kind = .button, .label = "Move to a new frame" },
    .{ .id = "selection.object", .kind = .value, .label = "Object" },
    .{ .id = "selection.objects", .kind = .value, .label = "Objects" },
    .{ .id = "sheet.cell.add-a-row", .kind = .button, .label = "Add a row" },
    .{ .id = "sheet.cell.key", .kind = .value, .label = "Key" },
    .{ .id = "sheet.cell.name-keys-by-grid-position-r1c1", .kind = .button, .label = "Name keys by grid position (R1C1…)" },
    .{ .id = "sheet.cell.name-keys-by-their-first-legend", .kind = .button, .label = "Name keys by their first legend" },
    .{ .id = "sheet.cell.remove-this-row", .kind = .button, .label = "Remove this row" },
    .{ .id = "sheet.cell.row", .kind = .value, .label = "Row" },
    .{ .id = "sheet.cell.slot", .kind = .value, .label = "Slot" },
    .{ .id = "sheet.columns", .kind = .value, .label = "Columns" },
    .{ .id = "sheet.name", .kind = .value, .label = "Name" },
    .{ .id = "sheet.not-found", .kind = .value, .label = "Not found" },
    .{ .id = "sheet.open-it-beside-the-canvas", .kind = .button, .label = "Open it beside the canvas" },
    .{ .id = "sheet.remove-sheet", .kind = .button, .label = "Remove sheet" },
    .{ .id = "sheet.rows", .kind = .value, .label = "Rows" },
    .{ .id = "sheet.unused", .kind = .value, .label = "Unused" },
    .{ .id = "sheet.x", .kind = .value, .label = "" },
    .{ .id = "sheets.legend-sheets", .kind = .value, .label = "Legend sheets" },
    .{ .id = "sketch-mode.conflicts", .kind = .value, .label = "Conflicts" },
    .{ .id = "sketch-mode.finish-sketch-enter", .kind = .button, .label = "Finish sketch…  Enter" },
    .{ .id = "sketch-mode.freedom", .kind = .value, .label = "Freedom" },
    .{ .id = "sketch-mode.redundant", .kind = .value, .label = "Redundant" },
    .{ .id = "sketch-mode.remove-constraint", .kind = .button, .label = "Remove constraint" },
    .{ .id = "sketch-mode.sketch", .kind = .value, .label = "Sketch" },
    .{ .id = "sketch-mode.state", .kind = .value, .label = "State" },
    .{ .id = "sketch-panel.edit-its-sketch", .kind = .button, .label = "Edit its sketch" },
    .{ .id = "sketch-panel.islands-a-hole-s-holes-stay-solid", .kind = .toggle, .label = "Islands: a hole's holes stay solid" },
    .{ .id = "sketch-panel.outline-from", .kind = .value, .label = "Outline from" },
    .{ .id = "sketch-view.box", .kind = .value, .label = "Box" },
    .{ .id = "sketch-view.constrained", .kind = .value, .label = "Constrained" },
    .{ .id = "sketch-view.edit-sketch", .kind = .button, .label = "Edit sketch" },
    .{ .id = "sketch-view.make-panel", .kind = .button, .label = "Make panel" },
    .{ .id = "sketch-view.origin", .kind = .value, .label = "Origin" },
    .{ .id = "sketch-view.sketch", .kind = .value, .label = "Sketch" },
    .{ .id = "sketch.constrained", .kind = .value, .label = "Constrained" },
    .{ .id = "sketch.delete-sketch", .kind = .button, .label = "Delete sketch" },
    .{ .id = "sketch.name", .kind = .value, .label = "Name" },
    .{ .id = "sketch.palette.construction", .kind = .button, .label = "Construction" },
    .{ .id = "sketch.palette.select", .kind = .button, .label = "Select" },
    .{ .id = "sketch.panels", .kind = .value, .label = "Panels" },
    .{ .id = "sketch.parameters.remove-parameter", .kind = .button, .label = "Remove parameter" },
    .{ .id = "sketch.parameters.set", .kind = .button, .label = "Set" },
    .{ .id = "sketch.physical.set", .kind = .button, .label = "Set" },
    .{ .id = "sketch.place-a-view-here", .kind = .button, .label = "Place a view here" },
    .{ .id = "sketch.step.angle", .kind = .field, .label = "Angle, °" },
    .{ .id = "sketch.step.end-angle", .kind = .field, .label = "End angle, °" },
    .{ .id = "sketch.step.length", .kind = .field, .label = "Length, mm" },
    .{ .id = "sketch.step.radius", .kind = .field, .label = "Radius, mm" },
    .{ .id = "sketch.step.x", .kind = .field, .label = "x, mm" },
    .{ .id = "sketch.step.y", .kind = .field, .label = "y, mm" },
    .{ .id = "sketch.summary.accept-and-leave", .kind = .button, .label = "Accept and leave" },
    .{ .id = "sketch.summary.back-to-sketching", .kind = .button, .label = "Back to sketching" },
    .{ .id = "sketch.views", .kind = .value, .label = "Views" },
    .{ .id = "sketches.sketches", .kind = .value, .label = "Sketches" },
    .{ .id = "style.based-on", .kind = .choice, .label = "Based on" },
    .{ .id = "style.fonts-every-face", .kind = .button, .label = "Fonts… (every face, and searching the installed fonts)" },
    .{ .id = "style.line-pitch", .kind = .choice, .label = "Line pitch, cap heights" },
    .{ .id = "style.name", .kind = .field, .label = "Name" },
    .{ .id = "style.rules.add-a-rule", .kind = .button, .label = "Add a rule" },
    .{ .id = "style.rules.rules", .kind = .value, .label = "Rules" },
    .{ .id = "style.text-face-family", .kind = .field, .label = "Text face family" },
    .{ .id = "style.text-face-style", .kind = .field, .label = "Text face style" },
    .{ .id = "styles.add-a-style", .kind = .button, .label = "Add a style" },
    .{ .id = "styles.text-styles", .kind = .value, .label = "Text styles" },
    .{ .id = "tile.body", .kind = .value, .label = "Body" },
    .{ .id = "tile.designator", .kind = .value, .label = "Designator" },
    .{ .id = "tile.gap-before", .kind = .field, .label = "Gap before, u" },
    .{ .id = "tile.position", .kind = .value, .label = "Position" },
    .{ .id = "tile.prototype", .kind = .choice, .label = "Prototype" },
    .{ .id = "tile.row", .kind = .value, .label = "Row" },
    .{ .id = "tile.slot.*.issue", .kind = .value, .label = "Issue" },
    .{ .id = "tile.slot.*.runs", .kind = .value, .label = "Runs" },
    .{ .id = "tool.add-panel", .kind = .button, .label = "Add panel" },
    .{ .id = "tool.add-prototype", .kind = .button, .label = "Add prototype" },
    .{ .id = "tool.add-rows", .kind = .button, .label = "Add rows" },
    .{ .id = "tool.add-columns", .kind = .button, .label = "Add columns" },
    .{ .id = "tool.add-track", .kind = .button, .label = "Add track" },
    .{ .id = "tool.add-shape", .kind = .button, .label = "Add shape" },
    .{ .id = "tool.add-tracks.runs", .kind = .choice, .label = "Runs" },
    .{ .id = "tool.add-tracks.size-to", .kind = .choice, .label = "Size to" },
    .{ .id = "tool.add-tracks.snaps-to", .kind = .value, .label = "Snaps to" },
    .{ .id = "tool.add-tracks.tracks", .kind = .choice, .label = "Tracks" },
    .{ .id = "tool.constrain", .kind = .button, .label = "Constrain" },
    .{ .id = "tool.delete-prototype", .kind = .button, .label = "Delete prototype" },
    .{ .id = "tool.duplicate-prototype", .kind = .button, .label = "Duplicate prototype" },
    .{ .id = "tool.fit-to-tiles", .kind = .button, .label = "Fit to tiles" },
    .{ .id = "tool.new-sketch", .kind = .button, .label = "New sketch" },
    .{ .id = "tool.select-area", .kind = .button, .label = "Select area" },
    .{ .id = "tool.select-boundaries", .kind = .button, .label = "Select boundaries" },
    .{ .id = "tool.construction-line", .kind = .button, .label = "Construction line" },
    .{ .id = "guide.name", .kind = .value, .label = "Name" },
    .{ .id = "guide.through-across", .kind = .field, .label = "Through across, mm" },
    .{ .id = "guide.through-up", .kind = .field, .label = "Through up, mm" },
    .{ .id = "guide.angle", .kind = .field, .label = "Angle, °" },
    .{ .id = "guide.held", .kind = .choice, .label = "Held" },
    .{ .id = "guide.remove", .kind = .button, .label = "Remove" },
    .{ .id = "ribbon.layers", .kind = .button, .label = "Layers: show or hide, reorder, the chosen layer's settings" },
    .{ .id = "ribbon.drop.shape", .kind = .button, .label = "Shapes" },
    .{ .id = "ribbon.drop.tracks", .kind = .button, .label = "Rows, columns, track" },
    .{ .id = "ribbon.shape.*", .kind = .button, .label = "A shape to draw" },
    .{ .id = "ribbon.tracks.*", .kind = .button, .label = "Rows, columns, or one track" },
    .{ .id = "layers-palette.*.choose", .kind = .button, .label = "Choose this layer: new objects go on it" },
    .{ .id = "layers-palette.*.shown", .kind = .button, .label = "Show or hide this layer" },
    .{ .id = "layers-palette.add-layer", .kind = .button, .label = "Add layer" },
    .{ .id = "views.add", .kind = .button, .label = "This window's tabs, and the document's contexts to show" },
    .{ .id = "views.tabs.*", .kind = .button, .label = "A tab of this window: shown" },
    .{ .id = "views.page-prev", .kind = .button, .label = "The page before" },
    .{ .id = "views.page-next", .kind = .button, .label = "The next page" },
    .{ .id = "views.close", .kind = .button, .label = "Remove from this window's tabs" },
    .{ .id = "views.split-across", .kind = .button, .label = "Split this window (Alt: stacked)" },
    .{ .id = "views.divider", .kind = .button, .label = "The split's options (drag to resize; double-click to even out)" },
    .{ .id = "views.swap", .kind = .button, .label = "Swap sides" },
    .{ .id = "views.even-out", .kind = .button, .label = "Even out" },
    .{ .id = "views.turn", .kind = .button, .label = "Stacked ⇄ side by side" },
    .{ .id = "views.filter", .kind = .field, .label = "Find a context" },
    .{ .id = "views.contexts.*", .kind = .button, .label = "A context to show in this window" },
    .{ .id = "tool.shape", .kind = .choice, .label = "Shape" },
    .{ .id = "tool.zoom-to-context", .kind = .button, .action = "view.zoom-fit", .label = "Zoom to context" },
    .{ .id = "view.edits", .kind = .value, .label = "Edits" },
    .{ .id = "view.moves", .kind = .value, .label = "Moves" },
    .{ .id = "view.name", .kind = .value, .label = "Name" },
    .{ .id = "view.place", .kind = .value, .label = "Place" },
    .{ .id = "view.reads-as", .kind = .value, .label = "Reads as" },
    .{ .id = "view.remove-view", .kind = .button, .label = "Remove view" },
    .{ .id = "view.scale", .kind = .field, .label = "Scale" },
    .{ .id = "view.show-its-source", .kind = .button, .label = "Show its source" },
    .{ .id = "view.shows", .kind = .value, .label = "Shows" },
    .{ .id = "view.size", .kind = .value, .label = "Size" },
    .{ .id = "worksheet.height", .kind = .choice, .label = "Height, mm" },
    .{ .id = "worksheet.margins.bottom", .kind = .field, .label = "Bottom, mm" },
    .{ .id = "worksheet.margins.ink-in-margins", .kind = .value, .label = "Ink in margins" },
    .{ .id = "worksheet.margins.left", .kind = .field, .label = "Left, mm" },
    .{ .id = "worksheet.margins.out-of-compliance", .kind = .value, .label = "Out of compliance" },
    .{ .id = "worksheet.margins.right", .kind = .field, .label = "Right, mm" },
    .{ .id = "worksheet.margins.top", .kind = .field, .label = "Top, mm" },
    .{ .id = "worksheet.name", .kind = .choice, .label = "Name" },
    .{ .id = "worksheet.orientation", .kind = .choice, .label = "Orientation" },
    .{ .id = "worksheet.panels", .kind = .value, .label = "Panels" },
    .{ .id = "worksheet.ruler-origin", .kind = .choice, .label = "Ruler origin" },
    .{ .id = "worksheet.sheet", .kind = .choice, .label = "Sheet" },
    .{ .id = "worksheet.size", .kind = .value, .label = "Size" },
    .{ .id = "worksheet.tiles", .kind = .value, .label = "Tiles" },
    .{ .id = "worksheet.units", .kind = .choice, .label = "Units" },
    .{ .id = "worksheet.width", .kind = .choice, .label = "Width, mm" },
    .{ .id = "dialog.file.*", .kind = .button, .label = "A file prompt's choices", .action = "dialog.confirm" },
    .{ .id = "selection.*", .kind = .button, .label = "Where to move the selection" },
    .{ .id = "panel.grids.*", .kind = .button, .label = "A grid of the panel" },
    .{ .id = "plan.operation.*.*", .kind = .toggle, .label = "What an operation works on" },
    .{ .id = "materials.library.*", .kind = .button, .label = "A library material" },
    .{ .id = "material.plan.*", .kind = .button, .label = "A plan using it" },
    .{ .id = "panel.checks.limit.*", .kind = .value, .label = "A limit checked" },
    .{ .id = "layers.*", .kind = .button, .label = "A layer" },
    .{ .id = "view.place-in.*", .kind = .button, .label = "Where to place the view" },
    .{ .id = "expression.param.*", .kind = .choice, .label = "A parameter" },
    .{ .id = "expression.style.face.*", .kind = .value, .label = "A face of the style" },
    .{ .id = "style.face.*", .kind = .value, .label = "A face of the style" },
    .{ .id = "processes.builtin.*", .kind = .button, .label = "A built-in profile" },
    .{ .id = "process.panel.*", .kind = .button, .label = "A panel using it" },
    .{ .id = "styles.package.*", .kind = .button, .label = "A package style" },
    .{ .id = "status.*", .kind = .button, .label = "The zoom" },
    .{ .id = "flow.track.*", .kind = .value, .label = "A track of the flow" },
    .{ .id = "sketch.palette.*", .kind = .button, .label = "A sketch tool" },
    .{ .id = "sketch.tool.*", .kind = .button, .label = "A sketch tool" },
    .{ .id = "sketch.constrain.*", .kind = .button, .label = "A constraint" },
    .{ .id = "sketch-mode.*", .kind = .button, .label = "Driving or reference" },
    .{ .id = "prototype.sketch.*", .kind = .field, .label = "A parameter" },
    .{ .id = "tile.sketch.*", .kind = .toggle, .label = "A parameter" },
    .{ .id = "plan.part.*", .kind = .choice, .label = "A part's material" },
    .{ .id = "palette.key.*", .kind = .button, .label = "A tile of that size" },
    .{ .id = "palette.blank.*", .kind = .button, .label = "A blank of that size" },
    .{ .id = "palette.run", .kind = .button, .label = "Text or equation" },
    .{ .id = "palette.join", .kind = .button, .label = "Join or part" },
    .{ .id = "palette.next-prototype", .kind = .button, .label = "Tiles: next kind" },
    .{ .id = "palette.hard-break", .kind = .button, .label = "Line break" },
    .{ .id = "palette.paragraph", .kind = .button, .label = "New paragraph" },
    .{ .id = "move.*", .kind = .button, .label = "Move it that way" },
    // Found by the GUI tests drawing them (drawn through helpers).
    .{ .id = "constraints.origin", .kind = .choice, .label = "Origin" },
    .{ .id = "constraints.origin-at.*", .kind = .button, .label = "A point of it as its origin" },
    .{ .id = "style.rules.*.kind", .kind = .choice, .label = "A rule: what it applies to" },
    .{ .id = "style.rules.*.parameter", .kind = .choice, .label = "A rule: its parameter" },
    .{ .id = "style.rules.*.value", .kind = .field, .label = "A rule: its value" },
    .{ .id = "expression.style.size", .kind = .field, .label = "Size, pt" },
    .{ .id = "expression.style.cap-height", .kind = .field, .label = "Cap height, mm" },
    .{ .id = "style.size", .kind = .field, .label = "Size, pt" },
    .{ .id = "style.cap-height", .kind = .field, .label = "Cap height, mm" },
    .{ .id = "paragraph.new-paragraph-style", .kind = .choice, .label = "New paragraph style" },
    .{ .id = "panel.previous-font", .kind = .button, .label = "The font before" },
    .{ .id = "panel.next-font", .kind = .button, .label = "The font after" },
    .{ .id = "canvas.previous-font", .kind = .button, .label = "The font before" },
    .{ .id = "canvas.next-font", .kind = .button, .label = "The font after" },
    .{ .id = "panel.layer", .kind = .choice, .label = "Layer" },
    .{ .id = "panel.fab.process", .kind = .choice, .label = "Process" },
    .{ .id = "panel.fab.add-layer", .kind = .button, .label = "Add layer" },
    .{ .id = "prototype.slot.*.style", .kind = .choice, .label = "Style" },
    .{ .id = "tile.slot.*.style", .kind = .choice, .label = "Style" },
    .{ .id = "prototype.art-layer.*.fill-kind", .kind = .choice, .label = "Fill kind" },
    .{ .id = "prototype.art-layer.*.fill", .kind = .field, .label = "Fill" },
    .{ .id = "prototype.art-layer.*.edge", .kind = .field, .label = "Edge" },
    .{ .id = "prototype.art-layer.*.edge-width", .kind = .field, .label = "Edge width, mm" },
    .{ .id = "prototype.art-layer.*.gradient-from", .kind = .field, .label = "Gradient from" },
    .{ .id = "prototype.art-layer.*.gradient-to", .kind = .field, .label = "Gradient to" },
    .{ .id = "prototype.art-layer.*.gradient-runs", .kind = .choice, .label = "Gradient runs" },
    .{ .id = "tile.width", .kind = .field, .label = "Width, u" },
    .{ .id = "tile.height", .kind = .field, .label = "Height, u" },
    .{ .id = "grid.stamp.*.shape", .kind = .choice, .label = "Shape" },
    .{ .id = "grid.stamp.*.*", .kind = .field, .label = "A parameter of its shape" },
    .{ .id = "plan.shown-as", .kind = .choice, .label = "Shown as" },
    .{ .id = "process.stroke-passes-at", .kind = .field, .label = "Stroke passes at, mm" },
    .{ .id = "process.stroke-fails-below", .kind = .field, .label = "Stroke fails below, mm" },
    .{ .id = "process.gap-passes-at", .kind = .field, .label = "Gap passes at, mm" },
    .{ .id = "process.gap-fails-below", .kind = .field, .label = "Gap fails below, mm" },
    .{ .id = "process.cap-height-passes-at", .kind = .field, .label = "Cap height passes at, mm" },
    .{ .id = "process.cap-height-fails-below", .kind = .field, .label = "Cap height fails below, mm" },
    .{ .id = "process.build-volume-across", .kind = .field, .label = "Build volume across, mm" },
    .{ .id = "process.build-volume-deep", .kind = .field, .label = "Build volume deep, mm" },
    .{ .id = "process.build-volume-high", .kind = .field, .label = "Build volume high, mm" },
    .{ .id = "flow.holds", .kind = .value, .label = "Holds" },
    .{ .id = "instance.grid", .kind = .button, .label = "Its grid" },
    .{ .id = "grid.add-stamp.parts", .kind = .button, .label = "Parts" },
    .{ .id = "grid.add-stamp.holes", .kind = .button, .label = "Holes" },
    .{ .id = "grid.add-stamp.legends", .kind = .button, .label = "Legends" },
};

fn validPart(p: []const u8) bool {
    if (std.mem.eql(u8, p, "*")) return true;
    if (p.len == 0 or !std.ascii.isLower(p[0])) return false;
    var dash = false;
    for (p) |c| {
        if (c == '-') {
            if (dash) return false;
            dash = true;
        } else if (std.ascii.isLower(c) or std.ascii.isDigit(c)) {
            dash = false;
        } else return false;
    }
    return !dash;
}

fn validId(id: []const u8) bool {
    var it = std.mem.splitScalar(u8, id, '.');
    while (it.next()) |p| if (!validPart(p)) return false;
    return true;
}

fn groupDeclared(id: []const u8) bool {
    for (groups) |g| if (std.mem.eql(u8, g.id, id)) return true;
    return false;
}

comptime {
    @setEvalBranchQuota(1_000_000);
    for (groups) |g| {
        if (!validId(g.id)) @compileError("malformed group id: " ++ g.id);
        if (std.mem.lastIndexOfScalar(u8, g.id, '.')) |k| if (!groupDeclared(g.id[0..k])) @compileError("group " ++ g.id ++ " in an undeclared group");
    }
    for (all, 0..) |e, i| {
        if (!validId(e.id)) @compileError("malformed element id: " ++ e.id);
        const k = std.mem.lastIndexOfScalar(u8, e.id, '.') orelse @compileError("element " ++ e.id ++ " in no group");
        if (!groupDeclared(e.id[0..k])) @compileError("element " ++ e.id ++ " in an undeclared group");
        if (groupDeclared(e.id)) @compileError("element " ++ e.id ++ " is also a group");
        for (all[0..i]) |o| if (std.mem.eql(u8, o.id, e.id)) @compileError("element id twice: " ++ e.id);
        if (e.kind != .button and e.action != null) @compileError("only a button has an action: " ++ e.id);
    }
}

/// The element `id` (checked when built).
pub fn get(comptime id: []const u8) Element {
    comptime {
        @setEvalBranchQuota(100_000);
        for (all) |e| if (std.mem.eql(u8, e.id, id)) return e;
        @compileError("no element \"" ++ id ++ "\"");
    }
}

/// Whether concrete id `id` is an instance of registry id `pattern` (a
/// `*` part matching any one part).
pub fn matches(pattern: []const u8, id: []const u8) bool {
    var pi = std.mem.splitScalar(u8, pattern, '.');
    var ii = std.mem.splitScalar(u8, id, '.');
    while (true) {
        const p = pi.next();
        const q = ii.next();
        if (p == null or q == null) return p == null and q == null;
        if (q.?.len == 0) return false;
        if (!std.mem.eql(u8, p.?, "*") and !std.mem.eql(u8, p.?, q.?)) return false;
    }
}

/// The element concrete id `id` is, if the registry has it (a repeat's
/// "#n" aside).
pub fn find(id: []const u8) ?Element {
    const base = if (std.mem.indexOfScalar(u8, id, '#')) |k| id[0..k] else id;
    for (all) |e| if (matches(e.id, base)) return e;
    return null;
}

/// The name of the action button `id` stands for: its registry id (a
/// pattern's, for an instance), or its own action.
pub fn actionName(id: []const u8) ?[]const u8 {
    const e = find(id) orelse return null;
    if (e.kind != .button) return null;
    return e.action orelse e.id;
}

/// The actions the registry's buttons stand for, each once.
pub const button_actions: []const []const u8 = blk: {
    @setEvalBranchQuota(10_000_000);
    var out: []const []const u8 = &.{};
    for (all) |e| if (e.kind == .button) {
        const name = e.action orelse e.id;
        for (out) |o| {
            if (std.mem.eql(u8, o, name)) break;
        } else out = out ++ .{name};
    };
    break :blk out;
};

/// One step down the discovery path: a group's member, a group itself or
/// an element.
pub const Child = struct {
    /// Its full id.
    id: []const u8,
    /// Its last part.
    name: []const u8,
    group: bool,
    kind: ?Kind = null,
    label: []const u8,
};

/// The groups and elements directly in group `parent` ("" for the top),
/// in the registry's order, into `out`.
pub fn children(parent: []const u8, out: []Child) []Child {
    var n: usize = 0;
    for (groups) |g| {
        if (n == out.len) break;
        if (!directlyIn(g.id, parent)) continue;
        out[n] = .{ .id = g.id, .name = lastPart(g.id), .group = true, .label = g.label };
        n += 1;
    }
    for (all) |e| {
        if (n == out.len) break;
        if (!directlyIn(e.id, parent)) continue;
        out[n] = .{ .id = e.id, .name = lastPart(e.id), .group = false, .kind = e.kind, .label = e.label };
        n += 1;
    }
    return out[0..n];
}

fn lastPart(id: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, id, '.')) |k| id[k + 1 ..] else id;
}

fn directlyIn(id: []const u8, parent: []const u8) bool {
    if (parent.len == 0) return std.mem.indexOfScalar(u8, id, '.') == null;
    return id.len > parent.len + 1 and std.mem.startsWith(u8, id, parent) and id[parent.len] == '.' and std.mem.indexOfScalar(u8, id[parent.len + 1 ..], '.') == null;
}

const testing = std.testing;

test "the discovery path walks the groups: track, its origin, its fields" {
    var buf: [64]Child = undefined;
    const top = children("", &buf);
    var has_track = false;
    for (top) |c| has_track = has_track or (c.group and std.mem.eql(u8, c.id, "track"));
    try testing.expect(has_track);
    const origin = children("track.origin", &buf);
    try testing.expectEqual(2, origin.len);
    try testing.expectEqualStrings("across", origin[0].name);
    try testing.expectEqual(Kind.field, origin[1].kind.?);
    try testing.expect(find("track.make-tracks#2") != null);
    try testing.expect(find("paragraph.showTheFlow") == null);
    try testing.expect(matches("panel.fab.layer.*.name", "panel.fab.layer.2.name"));
    try testing.expect(!matches("panel.fab.layer.*.name", "panel.fab.layer.name"));
    try testing.expect(!matches("panel.fab.layer.*.name", "panel.fab.layer.2.name.x"));
}

test "ids: dotted kebab-case parts" {
    try testing.expect(validId("track.flow.join-after"));
    try testing.expect(validId("panel.fab.layer.*.name"));
    try testing.expect(!validId("track.flow.joinAfter"));
    try testing.expect(!validId("track..name"));
    try testing.expect(!validId("track.-name"));
}
