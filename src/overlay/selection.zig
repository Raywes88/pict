//! Selection state in canvas pixels (see layout.zig). Pure, so it's unit-tested.
//!
//! Rect corners are pixel *boundaries* (0..W inclusive), so a rect from 10 to 20
//! covers pixels 10..19.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rect = @import("../geom.zig").Rect;

pub const Selection = struct {
    active: bool = false,
    bounds: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    anchor: [2]i32 = .{ 0, 0 },
    cursor: [2]i32 = .{ 0, 0 },
    dragging: bool = false,

    pub fn begin(s: *Selection, bounds: Rect, p: [2]i32) void {
        s.* = .{ .active = true, .bounds = bounds, .anchor = clampPt(bounds, p), .cursor = clampPt(bounds, p), .dragging = true };
    }

    pub fn update(s: *Selection, p: [2]i32) void {
        s.cursor = clampPt(s.bounds, p);
    }

    pub fn clear(s: *Selection) void {
        s.* = .{};
    }

    /// The selected rect, or null if nothing (or a zero-area rect) is selected.
    pub fn rect(s: Selection) ?Rect {
        if (!s.active) return null;
        const r = Rect.fromCorners(s.anchor[0], s.anchor[1], s.cursor[0], s.cursor[1]).clampTo(s.bounds);
        return if (r.isEmpty()) null else r;
    }

    /// Move the whole selection (resize = false) or just the cursor corner (resize = true),
    /// staying inside the bounds.
    pub fn nudge(s: *Selection, dx: i32, dy: i32, resize: bool) void {
        const r = s.rect() orelse return;
        if (resize) {
            s.cursor = clampPt(s.bounds, .{ s.cursor[0] + dx, s.cursor[1] + dy });
            return;
        }
        const mx = std.math.clamp(dx, s.bounds.x - r.x, s.bounds.x2() - r.x2());
        const my = std.math.clamp(dy, s.bounds.y - r.y, s.bounds.y2() - r.y2());
        s.anchor = .{ s.anchor[0] + mx, s.anchor[1] + my };
        s.cursor = .{ s.cursor[0] + mx, s.cursor[1] + my };
    }
};

/// Freeform selection: a polygon in canvas pixels, implicitly closed.
pub const Lasso = struct {
    points: std.ArrayList([2]f64) = .empty,
    bounds: Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    dragging: bool = false,

    pub fn deinit(l: *Lasso, gpa: Allocator) void {
        l.points.deinit(gpa);
        l.* = .{};
    }

    pub fn begin(l: *Lasso, gpa: Allocator, bounds: Rect, p: [2]f64) !void {
        l.points.clearRetainingCapacity();
        l.bounds = bounds;
        l.dragging = true;
        try l.points.append(gpa, clampPtF(bounds, p));
    }

    /// Append a point if it moved at least one pixel. Returns true if the shape changed.
    pub fn add(l: *Lasso, gpa: Allocator, p: [2]f64) !bool {
        const q = clampPtF(l.bounds, p);
        if (l.points.items.len > 0) {
            const last = l.points.items[l.points.items.len - 1];
            if (@abs(q[0] - last[0]) < 1 and @abs(q[1] - last[1]) < 1) return false;
        }
        try l.points.append(gpa, q);
        return true;
    }

    pub fn clear(l: *Lasso) void {
        l.points.clearRetainingCapacity();
        l.dragging = false;
    }

    /// Bounding box (whole pixels), or null if the shape is too small to be a selection.
    pub fn bbox(l: *const Lasso) ?Rect {
        if (l.points.items.len < 3) return null;
        var x0 = l.points.items[0][0];
        var y0 = l.points.items[0][1];
        var x1 = x0;
        var y1 = y0;
        for (l.points.items[1..]) |p| {
            x0 = @min(x0, p[0]);
            y0 = @min(y0, p[1]);
            x1 = @max(x1, p[0]);
            y1 = @max(y1, p[1]);
        }
        const r = Rect{
            .x = @intFromFloat(@floor(x0)),
            .y = @intFromFloat(@floor(y0)),
            .w = @as(i32, @intFromFloat(@ceil(x1))) - @as(i32, @intFromFloat(@floor(x0))),
            .h = @as(i32, @intFromFloat(@ceil(y1))) - @as(i32, @intFromFloat(@floor(y0))),
        };
        return if (r.w < 2 or r.h < 2) null else r;
    }
};

fn clampPt(b: Rect, p: [2]i32) [2]i32 {
    return .{ std.math.clamp(p[0], b.x, b.x2()), std.math.clamp(p[1], b.y, b.y2()) };
}

fn clampPtF(b: Rect, p: [2]f64) [2]f64 {
    return .{
        std.math.clamp(p[0], @as(f64, @floatFromInt(b.x)), @as(f64, @floatFromInt(b.x2()))),
        std.math.clamp(p[1], @as(f64, @floatFromInt(b.y)), @as(f64, @floatFromInt(b.y2()))),
    };
}

// ---- tests ----

const canvas = Rect{ .x = 0, .y = 0, .w = 5120, .h = 1440 };

test "zero-area selection is null; drag produces a normalized rect" {
    var s: Selection = .{};
    s.begin(canvas, .{ 50, 50 });
    try std.testing.expect(s.rect() == null);
    s.update(.{ 10, 20 });
    try std.testing.expectEqual(Rect{ .x = 10, .y = 20, .w = 40, .h = 30 }, s.rect().?);
}

test "selection can span outputs and clamps to the canvas" {
    var s: Selection = .{};
    s.begin(canvas, .{ 2000, 100 });
    s.update(.{ 9000, 200 });
    try std.testing.expectEqual(Rect{ .x = 2000, .y = 100, .w = 3120, .h = 100 }, s.rect().?);
}

test "nudge stays in bounds; resize moves one corner" {
    var s: Selection = .{};
    const b = Rect{ .x = 0, .y = 0, .w = 100, .h = 100 };
    s.begin(b, .{ 90, 90 });
    s.update(.{ 100, 100 });
    s.nudge(5, 5, false);
    try std.testing.expectEqual(Rect{ .x = 90, .y = 90, .w = 10, .h = 10 }, s.rect().?);
    s.nudge(-3, 0, true);
    try std.testing.expectEqual(Rect{ .x = 90, .y = 90, .w = 7, .h = 10 }, s.rect().?);
}

test "lasso ignores sub-pixel jitter and reports a bbox" {
    const gpa = std.testing.allocator;
    var l: Lasso = .{};
    defer l.deinit(gpa);
    try l.begin(gpa, canvas, .{ 10, 10 });
    try std.testing.expect(!try l.add(gpa, .{ 10.4, 10.2 }));
    try std.testing.expect(try l.add(gpa, .{ 30, 10 }));
    try std.testing.expect(l.bbox() == null); // two points
    _ = try l.add(gpa, .{ 20.5, 40.5 });
    try std.testing.expectEqual(Rect{ .x = 10, .y = 10, .w = 20, .h = 31 }, l.bbox().?);
}
