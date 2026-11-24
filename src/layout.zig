//! The canvas: one pixel grid spanning every output.
//!
//! Selections live in canvas pixels so they can cross monitors. The canvas scale is the
//! highest output scale, so the densest output maps 1:1 (exact crops) and lower-scale
//! outputs are upscaled when a selection includes them. Each output's canvas origin is
//! rounded to a whole pixel, which keeps same-scale outputs pixel-exact.

const std = @import("std");
const Rect = @import("geom.zig").Rect;

pub const OutputGeom = struct {
    /// Logical position and size (compositor coordinates).
    lx: f64,
    ly: f64,
    lw: f64,
    lh: f64,
    /// Frame size in physical pixels.
    pw: i32,
    ph: i32,
    /// Physical pixels per logical pixel. Exact value from wp_fractional_scale when known,
    /// otherwise pw / lw.
    scale: f64,

    pub fn fromSizes(lx: f64, ly: f64, lw: f64, lh: f64, pw: i32, ph: i32, exact_scale: ?f64) OutputGeom {
        const fallback = if (lw > 0) @as(f64, @floatFromInt(pw)) / lw else 1;
        return .{ .lx = lx, .ly = ly, .lw = lw, .lh = lh, .pw = pw, .ph = ph, .scale = exact_scale orelse fallback };
    }
};

pub const max_outputs = 16;

pub const Layout = struct {
    geoms: [max_outputs]OutputGeom = undefined,
    n: usize = 0,
    /// Canvas pixels per logical pixel.
    scale: f64 = 1,
    /// Canvas rect of each output.
    rects: [max_outputs]Rect = undefined,
    bounds: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },

    pub fn init(geoms: []const OutputGeom) Layout {
        var l: Layout = .{};
        l.n = @min(geoms.len, max_outputs);
        @memcpy(l.geoms[0..l.n], geoms[0..l.n]);
        if (l.n == 0) return l;

        var min_x = geoms[0].lx;
        var min_y = geoms[0].ly;
        l.scale = geoms[0].scale;
        for (geoms[0..l.n]) |g| {
            l.scale = @max(l.scale, g.scale);
            min_x = @min(min_x, g.lx);
            min_y = @min(min_y, g.ly);
        }
        for (geoms[0..l.n], 0..) |g, i| {
            const same = g.scale == l.scale;
            l.rects[i] = .{
                .x = rnd((g.lx - min_x) * l.scale),
                .y = rnd((g.ly - min_y) * l.scale),
                .w = if (same) g.pw else rnd(@as(f64, @floatFromInt(g.pw)) * l.scale / g.scale),
                .h = if (same) g.ph else rnd(@as(f64, @floatFromInt(g.ph)) * l.scale / g.scale),
            };
            l.bounds = if (i == 0) l.rects[0] else l.bounds.bbox(l.rects[i]);
        }
        return l;
    }

    /// Physical pixels on output i per canvas pixel (1 for the densest outputs).
    pub fn ratio(l: *const Layout, i: usize) f64 {
        const r = l.rects[i];
        if (r.w == 0) return 1;
        return @as(f64, @floatFromInt(l.geoms[i].pw)) / @as(f64, @floatFromInt(r.w));
    }

    /// Surface-local logical coordinates on output i → canvas pixels (unrounded).
    pub fn toCanvas(l: *const Layout, i: usize, x: f64, y: f64) [2]f64 {
        const g = l.geoms[i];
        const k = l.ratio(i);
        return .{
            @as(f64, @floatFromInt(l.rects[i].x)) + x * g.scale / k,
            @as(f64, @floatFromInt(l.rects[i].y)) + y * g.scale / k,
        };
    }

    /// Canvas point → output i physical pixels (unrounded).
    pub fn toLocal(l: *const Layout, i: usize, cx: f64, cy: f64) [2]f64 {
        const k = l.ratio(i);
        return .{
            (cx - @as(f64, @floatFromInt(l.rects[i].x))) * k,
            (cy - @as(f64, @floatFromInt(l.rects[i].y))) * k,
        };
    }

    /// Canvas rect → output i physical pixels. May extend past the output.
    pub fn rectToLocal(l: *const Layout, i: usize, r: Rect) Rect {
        const a = l.toLocal(i, @floatFromInt(r.x), @floatFromInt(r.y));
        const b = l.toLocal(i, @floatFromInt(r.x2()), @floatFromInt(r.y2()));
        const x0 = rnd(a[0]);
        const y0 = rnd(a[1]);
        return .{ .x = x0, .y = y0, .w = rnd(b[0]) - x0, .h = rnd(b[1]) - y0 };
    }

    /// Output-local logical rect (e.g. a niri window) → canvas rect.
    pub fn logicalRectToCanvas(l: *const Layout, i: usize, x: f64, y: f64, w: f64, h: f64) Rect {
        const a = l.toCanvas(i, x, y);
        const b = l.toCanvas(i, x + w, y + h);
        const x0 = rnd(a[0]);
        const y0 = rnd(a[1]);
        return .{ .x = x0, .y = y0, .w = rnd(b[0]) - x0, .h = rnd(b[1]) - y0 };
    }

    /// Index of the output containing canvas point (x, y), if any.
    pub fn outputAt(l: *const Layout, x: i32, y: i32) ?usize {
        for (l.rects[0..l.n], 0..) |r, i| {
            if (x >= r.x and x < r.x2() and y >= r.y and y < r.y2()) return i;
        }
        return null;
    }
};

fn rnd(v: f64) i32 {
    return @intFromFloat(@round(v));
}

// ---- tests ----

const dp2 = OutputGeom.fromSizes(0, 0, 2560, 1440, 2560, 1440, 1.0);
const dp3 = OutputGeom.fromSizes(2560, 0, 2560, 1440, 2560, 1440, 1.0);
const dp3_15 = OutputGeom.fromSizes(2560, 0, 1707, 960, 2560, 1440, 1.5);

test "side-by-side same-scale outputs tile the canvas exactly" {
    const l = Layout.init(&.{ dp2, dp3 });
    try std.testing.expectEqual(Rect{ .x = 2560, .y = 0, .w = 2560, .h = 1440 }, l.rects[1]);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 5120, .h = 1440 }, l.bounds);
    try std.testing.expectEqual([2]f64{ 2660, 50 }, l.toCanvas(1, 100, 50));
    try std.testing.expectEqual(Rect{ .x = 100, .y = 50, .w = 10, .h = 10 }, l.rectToLocal(1, .{ .x = 2660, .y = 50, .w = 10, .h = 10 }));
}

test "exact fractional scale maps logical to physical" {
    const l = Layout.init(&.{dp3_15});
    try std.testing.expectEqual(@as(f64, 1.5), l.scale);
    try std.testing.expectEqual([2]f64{ 1500, 600 }, l.toCanvas(0, 1000, 400));
    try std.testing.expectEqual(@as(i32, 2560), l.rects[0].w);
}

test "mixed scales: the 1.0 output is upscaled onto the 1.5 canvas" {
    const l = Layout.init(&.{ dp2, dp3_15 });
    try std.testing.expectEqual(@as(f64, 1.5), l.scale);
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 3840, .h = 2160 }, l.rects[0]);
    try std.testing.expectEqual(Rect{ .x = 3840, .y = 0, .w = 2560, .h = 1440 }, l.rects[1]);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0 / 3.0), l.ratio(0), 1e-9);
    try std.testing.expectEqual(@as(?usize, 1), l.outputAt(3840, 10));
}
