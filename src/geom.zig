//! Integer rectangles in physical (buffer) pixels.

const std = @import("std");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn x2(r: Rect) i32 {
        return r.x + r.w;
    }
    pub fn y2(r: Rect) i32 {
        return r.y + r.h;
    }
    pub fn isEmpty(r: Rect) bool {
        return r.w <= 0 or r.h <= 0;
    }
    pub fn eql(a: Rect, b: Rect) bool {
        return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
    }

    /// Rect spanning two corner points given as pixel *boundaries* (0..W inclusive).
    pub fn fromCorners(ax: i32, ay: i32, bx: i32, by: i32) Rect {
        const x0 = @min(ax, bx);
        const y0 = @min(ay, by);
        return .{ .x = x0, .y = y0, .w = @max(ax, bx) - x0, .h = @max(ay, by) - y0 };
    }

    pub fn inflate(r: Rect, d: i32) Rect {
        return .{ .x = r.x - d, .y = r.y - d, .w = r.w + 2 * d, .h = r.h + 2 * d };
    }

    pub fn intersect(a: Rect, b: Rect) Rect {
        const x0 = @max(a.x, b.x);
        const y0 = @max(a.y, b.y);
        const x1 = @min(a.x2(), b.x2());
        const y1 = @min(a.y2(), b.y2());
        return .{ .x = x0, .y = y0, .w = @max(0, x1 - x0), .h = @max(0, y1 - y0) };
    }

    pub fn bbox(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        const x0 = @min(a.x, b.x);
        const y0 = @min(a.y, b.y);
        return .{ .x = x0, .y = y0, .w = @max(a.x2(), b.x2()) - x0, .h = @max(a.y2(), b.y2()) - y0 };
    }

    pub fn clampTo(r: Rect, bounds: Rect) Rect {
        return r.intersect(bounds);
    }
};

/// Up to 4 rects covering `outer` minus `hole` (hole is assumed inside outer or empty).
pub fn subtract(outer: Rect, hole: Rect, out: *[4]Rect) []Rect {
    const h = hole.intersect(outer);
    if (h.isEmpty()) {
        out[0] = outer;
        return out[0..1];
    }
    var n: usize = 0;
    const bands = [_]Rect{
        .{ .x = outer.x, .y = outer.y, .w = outer.w, .h = h.y - outer.y }, // top
        .{ .x = outer.x, .y = h.y2(), .w = outer.w, .h = outer.y2() - h.y2() }, // bottom
        .{ .x = outer.x, .y = h.y, .w = h.x - outer.x, .h = h.h }, // left
        .{ .x = h.x2(), .y = h.y, .w = outer.x2() - h.x2(), .h = h.h }, // right
    };
    for (bands) |b| {
        if (!b.isEmpty()) {
            out[n] = b;
            n += 1;
        }
    }
    return out[0..n];
}

test "fromCorners normalizes" {
    const r = Rect.fromCorners(20, 5, 10, 15);
    try std.testing.expectEqual(Rect{ .x = 10, .y = 5, .w = 10, .h = 10 }, r);
}

test "subtract covers exactly outer minus hole" {
    var buf: [4]Rect = undefined;
    const outer = Rect{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const hole = Rect{ .x = 2, .y = 3, .w = 4, .h = 5 };
    const parts = subtract(outer, hole, &buf);
    var area: i32 = 0;
    for (parts) |p| {
        area += p.w * p.h;
        try std.testing.expect(p.intersect(hole).isEmpty());
    }
    try std.testing.expectEqual(@as(i32, 100 - 20), area);
}

test "subtract with empty hole returns outer" {
    var buf: [4]Rect = undefined;
    const outer = Rect{ .x = 1, .y = 1, .w = 3, .h = 3 };
    const parts = subtract(outer, .{ .x = 50, .y = 50, .w = 2, .h = 2 }, &buf);
    try std.testing.expectEqual(@as(usize, 1), parts.len);
    try std.testing.expectEqual(outer, parts[0]);
}
