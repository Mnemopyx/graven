//! Graven label engine: renders a label's content into geometry.
//!
//! Native geometry is two-level (see render.zig): placed items first, and
//! closed contours (lines, native quadratics, cubics) in mm only on request.
//! The engine knows nothing about any UI, file system or console.

pub const geom = @import("graven_geom");
pub const font = @import("graven_font");
pub const render = @import("render.zig");
pub const markup = @import("markup.zig");
pub const entities = @import("entities.zig");
pub const style = @import("style.zig");
pub const label = @import("label.zig");
pub const shape = @import("shape.zig");

pub const Face = font.Face;
pub const Render = render.Render;
pub const Anchor = render.Anchor;
pub const renderRun = render.renderRun;
pub const renderLabel = label.renderLabel;

/// The engine's version, recorded with every render it caches.
pub const version = "0.0.0";

test {
    @import("std").testing.refAllDecls(@This());
}
