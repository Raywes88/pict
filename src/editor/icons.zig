//! Toolbar icons as Cairo paths on a 24-unit grid, drawn in the current source colour.

const std = @import("std");
const c = @import("c");

pub const Icon = enum {
    pen,
    highlighter,
    eraser,
    line,
    arrow,
    rect,
    ellipse,
    text,
    blur,
    pixelate,
    crop,
    picker,
    undo,
    redo,
    copy,
    save,
    save_as,
    minus,
    plus,
};

/// Draw `icon` in the box (x, y, size, size).
pub fn draw(cr: *c.cairo_t, icon: Icon, x: f64, y: f64, size: f64) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_translate(cr, x, y);
    c.cairo_scale(cr, size / 24.0, size / 24.0);
    c.cairo_set_line_width(cr, 1.8);
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
    c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);

    switch (icon) {
        .pen => {
            poly(cr, &.{ .{ 15.5, 4.5 }, .{ 19.5, 8.5 }, .{ 8.5, 19.5 }, .{ 4, 20 }, .{ 4.5, 15.5 } }, true);
            c.cairo_stroke(cr);
            seg(cr, 13, 7, 17, 11);
        },
        .highlighter => {
            poly(cr, &.{ .{ 14, 3.5 }, .{ 20.5, 10 }, .{ 12, 18.5 }, .{ 8.5, 18.5 }, .{ 5.5, 15.5 }, .{ 5.5, 12 } }, true);
            c.cairo_stroke(cr);
            c.cairo_rectangle(cr, 3, 20, 10, 2.2);
            c.cairo_fill(cr);
        },
        .eraser => {
            poly(cr, &.{ .{ 9, 19.5 }, .{ 4, 14.5 }, .{ 13.5, 5 }, .{ 20, 11.5 }, .{ 12, 19.5 } }, true);
            c.cairo_stroke(cr);
            seg(cr, 8.5, 10, 14.5, 16);
            seg(cr, 12, 19.5, 20, 19.5);
        },
        .line => seg(cr, 5, 19, 19, 5),
        .arrow => {
            seg(cr, 5, 19, 18, 6);
            poly(cr, &.{ .{ 10, 6 }, .{ 18, 6 }, .{ 18, 14 } }, false);
            c.cairo_stroke(cr);
        },
        .rect => {
            c.cairo_rectangle(cr, 4, 6, 16, 12);
            c.cairo_stroke(cr);
        },
        .ellipse => {
            c.cairo_save(cr);
            c.cairo_translate(cr, 12, 12);
            c.cairo_scale(cr, 8.5, 6.5);
            c.cairo_arc(cr, 0, 0, 1, 0, 2 * std.math.pi);
            c.cairo_restore(cr);
            c.cairo_stroke(cr);
        },
        .text => {
            c.cairo_set_line_width(cr, 2.2);
            seg(cr, 6, 5.5, 18, 5.5);
            seg(cr, 12, 5.5, 12, 19);
            c.cairo_set_line_width(cr, 1.6);
            seg(cr, 9, 19, 15, 19);
        },
        .blur => {
            c.cairo_arc(cr, 12, 12, 3, 0, 2 * std.math.pi);
            c.cairo_fill(cr);
            c.cairo_push_group(cr);
            c.cairo_arc(cr, 12, 12, 6, 0, 2 * std.math.pi);
            c.cairo_stroke(cr);
            c.cairo_pop_group_to_source(cr);
            c.cairo_paint_with_alpha(cr, 0.55);
            c.cairo_push_group(cr);
            c.cairo_arc(cr, 12, 12, 9, 0, 2 * std.math.pi);
            c.cairo_stroke(cr);
            c.cairo_pop_group_to_source(cr);
            c.cairo_paint_with_alpha(cr, 0.25);
        },
        .pixelate => {
            // Checkerboard: solid cells, then the faint ones as one translucent group.
            for (0..3) |i| for (0..3) |j| {
                if ((i + j) % 2 != 0) continue;
                cell(cr, i, j);
            };
            c.cairo_fill(cr);
            c.cairo_push_group(cr);
            for (0..3) |i| for (0..3) |j| {
                if ((i + j) % 2 == 0) continue;
                cell(cr, i, j);
            };
            c.cairo_fill(cr);
            c.cairo_pop_group_to_source(cr);
            c.cairo_paint_with_alpha(cr, 0.35);
        },
        .crop => {
            poly(cr, &.{ .{ 7, 3 }, .{ 7, 17 }, .{ 21, 17 } }, false);
            c.cairo_stroke(cr);
            poly(cr, &.{ .{ 3, 7 }, .{ 17, 7 }, .{ 17, 21 } }, false);
            c.cairo_stroke(cr);
        },
        .picker => {
            c.cairo_set_line_width(cr, 2.2);
            seg(cr, 4.5, 19.5, 13, 11);
            c.cairo_set_line_width(cr, 1.8);
            seg(cr, 10.5, 8.5, 15.5, 13.5);
            c.cairo_arc(cr, 16.5, 7.5, 3.6, 0, 2 * std.math.pi);
            c.cairo_fill(cr);
        },
        .undo, .redo => {
            if (icon == .redo) {
                c.cairo_translate(cr, 24, 0);
                c.cairo_scale(cr, -1, 1);
            }
            c.cairo_move_to(cr, 6, 10);
            c.cairo_line_to(cr, 14, 10);
            c.cairo_curve_to(cr, 17.5, 10, 19.5, 12.3, 19.5, 14.75);
            c.cairo_curve_to(cr, 19.5, 17.2, 17.5, 19.5, 14, 19.5);
            c.cairo_line_to(cr, 10, 19.5);
            c.cairo_stroke(cr);
            poly(cr, &.{ .{ 9.5, 6.5 }, .{ 6, 10 }, .{ 9.5, 13.5 } }, false);
            c.cairo_stroke(cr);
        },
        .copy => {
            roundRect(cr, 8.5, 8.5, 11.5, 11.5, 2);
            c.cairo_stroke(cr);
            c.cairo_move_to(cr, 4.5, 15.5);
            c.cairo_line_to(cr, 4.5, 6.5);
            c.cairo_curve_to(cr, 4.5, 5.4, 5.4, 4.5, 6.5, 4.5);
            c.cairo_line_to(cr, 15.5, 4.5);
            c.cairo_stroke(cr);
        },
        .save => {
            seg(cr, 12, 4, 12, 15);
            poly(cr, &.{ .{ 7.5, 10.5 }, .{ 12, 15 }, .{ 16.5, 10.5 } }, false);
            c.cairo_stroke(cr);
            poly(cr, &.{ .{ 4.5, 15 }, .{ 4.5, 19.5 }, .{ 19.5, 19.5 }, .{ 19.5, 15 } }, false);
            c.cairo_stroke(cr);
        },
        .save_as => {
            // Folder: choose where to save.
            c.cairo_move_to(cr, 3.5, 18.5);
            c.cairo_line_to(cr, 3.5, 6.5);
            c.cairo_line_to(cr, 9, 6.5);
            c.cairo_line_to(cr, 11, 8.5);
            c.cairo_line_to(cr, 20.5, 8.5);
            c.cairo_line_to(cr, 20.5, 18.5);
            c.cairo_close_path(cr);
            c.cairo_stroke(cr);
            seg(cr, 12, 11.5, 12, 16.5);
            seg(cr, 9.5, 14, 14.5, 14);
        },
        .minus => seg(cr, 7, 12, 17, 12),
        .plus => {
            seg(cr, 7, 12, 17, 12);
            seg(cr, 12, 7, 12, 17);
        },
    }
}

/// A ring of hues (the custom-colour swatch).
pub fn hueRing(cr: *c.cairo_t, cx: f64, cy: f64, r: f64) void {
    const n = 12;
    for (0..n) |i| {
        const a0 = @as(f64, @floatFromInt(i)) / n * 2 * std.math.pi;
        const a1 = @as(f64, @floatFromInt(i + 1)) / n * 2 * std.math.pi + 0.02;
        const rgb = hsv(@as(f32, @floatFromInt(i)) / n, 0.85, 0.95);
        c.cairo_move_to(cr, cx, cy);
        c.cairo_arc(cr, cx, cy, r, a0, a1);
        c.cairo_close_path(cr);
        c.cairo_set_source_rgb(cr, rgb[0], rgb[1], rgb[2]);
        c.cairo_fill(cr);
    }
}

/// HSV (all 0..1) to RGB.
pub fn hsv(h: f32, s: f32, v: f32) [3]f32 {
    const hh = (h - @floor(h)) * 6;
    const i: u32 = @intFromFloat(@floor(hh));
    const f = hh - @floor(hh);
    const p = v * (1 - s);
    const q = v * (1 - s * f);
    const t = v * (1 - s * (1 - f));
    return switch (i % 6) {
        0 => .{ v, t, p },
        1 => .{ q, v, p },
        2 => .{ p, v, t },
        3 => .{ p, q, v },
        4 => .{ t, p, v },
        else => .{ v, p, q },
    };
}

/// RGB (0..1) to HSV (0..1).
pub fn toHsv(r: f32, g: f32, b: f32) [3]f32 {
    const mx = @max(r, @max(g, b));
    const mn = @min(r, @min(g, b));
    const d = mx - mn;
    var h: f32 = 0;
    if (d > 0) {
        if (mx == r) {
            h = (g - b) / d;
            if (h < 0) h += 6;
        } else if (mx == g) {
            h = (b - r) / d + 2;
        } else {
            h = (r - g) / d + 4;
        }
        h /= 6;
    }
    return .{ h, if (mx > 0) d / mx else 0, mx };
}

fn cell(cr: *c.cairo_t, i: usize, j: usize) void {
    const fx: f64 = @floatFromInt(i);
    const fy: f64 = @floatFromInt(j);
    c.cairo_rectangle(cr, 4.5 + fx * 5.2, 4.5 + fy * 5.2, 4.6, 4.6);
}

fn seg(cr: *c.cairo_t, x0: f64, y0: f64, x1: f64, y1: f64) void {
    c.cairo_move_to(cr, x0, y0);
    c.cairo_line_to(cr, x1, y1);
    c.cairo_stroke(cr);
}

fn poly(cr: *c.cairo_t, pts: []const [2]f64, close: bool) void {
    for (pts, 0..) |p, i| {
        if (i == 0) c.cairo_move_to(cr, p[0], p[1]) else c.cairo_line_to(cr, p[0], p[1]);
    }
    if (close) c.cairo_close_path(cr);
}

pub fn roundRect(cr: *c.cairo_t, x: f64, y: f64, w: f64, h: f64, radius: f64) void {
    const rad = @min(radius, @min(w, h) / 2.0);
    const pi = std.math.pi;
    c.cairo_new_sub_path(cr);
    c.cairo_arc(cr, x + w - rad, y + rad, rad, -pi / 2.0, 0);
    c.cairo_arc(cr, x + w - rad, y + h - rad, rad, 0, pi / 2.0);
    c.cairo_arc(cr, x + rad, y + h - rad, rad, pi / 2.0, pi);
    c.cairo_arc(cr, x + rad, y + rad, rad, pi, 3.0 * pi / 2.0);
    c.cairo_close_path(cr);
}

test "hsv round trip" {
    const rgb = hsv(0.6, 0.5, 0.8);
    const back = toHsv(rgb[0], rgb[1], rgb[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.6), back[0], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), back[1], 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), back[2], 1e-4);
}
