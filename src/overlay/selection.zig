//! Selection state and coordinate mapping. Pure, so it's unit-tested.
//!
//! Coordinates are physical pixel *boundaries* on one output's frozen frame
//! (0..width inclusive), so a rect from 10 to 20 covers pixels 10..19.

const std = @import("std");
const Rect = @import("../geom.zig").Rect;

/// Where an output sits in the compositor's logical space and how big its frame is.
pub const OutputGeom = struct {
    lx: f64,
    ly: f64,
    lw: f64,
    lh: f64,
    /// Physical (frame buffer) size.
    pw: i32,
    ph: i32,

    pub fn bounds(g: OutputGeom) Rect {
        return .{ .x = 0, .y = 0, .w = g.pw, .h = g.ph };
    }
};

/// Map a pointer position (surface-local logical coords on `from`) to a physical pixel
/// boundary on `to`, clamped to `to`'s frame. With from == to this is the plain
/// logical→physical conversion; otherwise it goes through global logical space, which
/// keeps a drag confined to the output it started on.
pub fn toPhysical(from: OutputGeom, to: OutputGeom, x: f64, y: f64) [2]i32 {
    const gx = from.lx + x;
    const gy = from.ly + y;
    const local_x = gx - to.lx;
    const local_y = gy - to.ly;
    const sx = @as(f64, @floatFromInt(to.pw)) / to.lw;
    const sy = @as(f64, @floatFromInt(to.ph)) / to.lh;
    const px: i32 = @intFromFloat(@round(std.math.clamp(local_x * sx, 0, @as(f64, @floatFromInt(to.pw)))));
    const py: i32 = @intFromFloat(@round(std.math.clamp(local_y * sy, 0, @as(f64, @floatFromInt(to.ph)))));
    return .{ px, py };
}

pub const Selection = struct {
    /// Index of the output/frame the selection lives on; null = nothing selected.
    frame: ?usize = null,
    bounds: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    anchor: [2]i32 = .{ 0, 0 },
    cursor: [2]i32 = .{ 0, 0 },
    dragging: bool = false,

    pub fn begin(s: *Selection, frame: usize, bounds: Rect, p: [2]i32) void {
        s.* = .{ .frame = frame, .bounds = bounds, .anchor = p, .cursor = p, .dragging = true };
    }

    pub fn update(s: *Selection, p: [2]i32) void {
        s.cursor = p;
    }

    pub fn clear(s: *Selection) void {
        s.* = .{};
    }

    /// The selected rect, or null if nothing (or a zero-area rect) is selected.
    pub fn rect(s: Selection) ?Rect {
        if (s.frame == null) return null;
        const r = Rect.fromCorners(s.anchor[0], s.anchor[1], s.cursor[0], s.cursor[1]).clampTo(s.bounds);
        return if (r.isEmpty()) null else r;
    }

    /// Move the whole selection (resize = false) or just the cursor corner (resize = true),
    /// staying inside the frame.
    pub fn nudge(s: *Selection, dx: i32, dy: i32, resize: bool) void {
        const r = s.rect() orelse return;
        if (resize) {
            s.cursor[0] = std.math.clamp(s.cursor[0] + dx, s.bounds.x, s.bounds.x2());
            s.cursor[1] = std.math.clamp(s.cursor[1] + dy, s.bounds.y, s.bounds.y2());
            return;
        }
        const mx = std.math.clamp(dx, s.bounds.x - r.x, s.bounds.x2() - r.x2());
        const my = std.math.clamp(dy, s.bounds.y - r.y, s.bounds.y2() - r.y2());
        s.anchor = .{ s.anchor[0] + mx, s.anchor[1] + my };
        s.cursor = .{ s.cursor[0] + mx, s.cursor[1] + my };
    }
};

// ---- tests ----

const one = OutputGeom{ .lx = 0, .ly = 0, .lw = 2560, .lh = 1440, .pw = 2560, .ph = 1440 };
const right = OutputGeom{ .lx = 2560, .ly = 0, .lw = 2560, .lh = 1440, .pw = 2560, .ph = 1440 };
const frac = OutputGeom{ .lx = 0, .ly = 0, .lw = 2560.0 / 1.5, .lh = 960, .pw = 2560, .ph = 1440 };

test "identity mapping at scale 1" {
    try std.testing.expectEqual([2]i32{ 100, 200 }, toPhysical(one, one, 100, 200));
}

test "fractional scale maps to physical pixels" {
    try std.testing.expectEqual([2]i32{ 1280, 720 }, toPhysical(frac, frac, 2560.0 / 3.0, 480));
    try std.testing.expectEqual([2]i32{ 2560, 1440 }, toPhysical(frac, frac, 2560.0 / 1.5, 960));
}

test "pointer on the neighbouring output clamps to the selection's output" {
    // Pointer 300px into the right-hand output while the drag started on the left one.
    try std.testing.expectEqual([2]i32{ 2560, 50 }, toPhysical(right, one, 300, 50));
}

test "zero-area selection is null; drag produces a normalized rect" {
    var s: Selection = .{};
    s.begin(0, one.bounds(), .{ 50, 50 });
    try std.testing.expect(s.rect() == null);
    s.update(.{ 10, 20 });
    try std.testing.expectEqual(Rect{ .x = 10, .y = 20, .w = 40, .h = 30 }, s.rect().?);
}

test "nudge stays in bounds; resize moves one corner" {
    var s: Selection = .{};
    s.begin(0, .{ .x = 0, .y = 0, .w = 100, .h = 100 }, .{ 90, 90 });
    s.update(.{ 100, 100 });
    s.nudge(5, 5, false);
    try std.testing.expectEqual(Rect{ .x = 90, .y = 90, .w = 10, .h = 10 }, s.rect().?);
    s.nudge(-3, 0, true);
    try std.testing.expectEqual(Rect{ .x = 90, .y = 90, .w = 7, .h = 10 }, s.rect().?);
}
