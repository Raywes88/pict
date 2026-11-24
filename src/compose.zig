//! Build the result image for a canvas rect from the frozen output frames.
//!
//! Outputs at the canvas scale are blitted 1:1 (pixel-exact). Lower-scale outputs are
//! upscaled with a good filter. Canvas areas no output covers (gaps between offset
//! monitors) and pixels outside a lasso come out transparent.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c");
const Image = @import("image/Image.zig");
const Rect = @import("geom.zig").Rect;
const Layout = @import("layout.zig").Layout;

pub fn compose(gpa: Allocator, layout: *const Layout, images: []const Image, rect: Rect, lasso: ?[]const [2]f64) !Image {
    if (rect.isEmpty()) return error.EmptySelection;
    var out = try Image.alloc(gpa, @intCast(rect.w), @intCast(rect.h));
    errdefer out.deinit(gpa);
    @memset(out.pixels, 0);

    const surf = c.cairo_image_surface_create_for_data(out.pixels.ptr, c.CAIRO_FORMAT_ARGB32, rect.w, rect.h, @intCast(out.stride));
    defer c.cairo_surface_destroy(surf);
    const cr = c.cairo_create(surf) orelse return error.CairoFailed;
    defer c.cairo_destroy(cr);
    if (c.cairo_status(cr) != c.CAIRO_STATUS_SUCCESS) return error.CairoFailed;

    // Work in canvas coordinates.
    c.cairo_translate(cr, @floatFromInt(-rect.x), @floatFromInt(-rect.y));
    if (lasso) |pts| {
        for (pts, 0..) |p, i| {
            if (i == 0) c.cairo_move_to(cr, p[0], p[1]) else c.cairo_line_to(cr, p[0], p[1]);
        }
        c.cairo_close_path(cr);
        c.cairo_clip(cr);
    }

    var covered: i64 = 0;
    for (images, 0..) |img, i| {
        if (i >= layout.n) break;
        const orect = layout.rects[i];
        const inter = rect.intersect(orect);
        if (inter.isEmpty()) continue;
        covered += @as(i64, inter.w) * inter.h;

        const src = c.cairo_image_surface_create_for_data(img.pixels.ptr, c.CAIRO_FORMAT_ARGB32, @intCast(img.width), @intCast(img.height), @intCast(img.stride));
        defer c.cairo_surface_destroy(src);

        c.cairo_save(cr);
        c.cairo_rectangle(cr, @floatFromInt(inter.x), @floatFromInt(inter.y), @floatFromInt(inter.w), @floatFromInt(inter.h));
        c.cairo_clip(cr);
        c.cairo_translate(cr, @floatFromInt(orect.x), @floatFromInt(orect.y));
        const k = layout.ratio(i);
        if (k != 1) c.cairo_scale(cr, 1 / k, 1 / k);
        c.cairo_set_source_surface(cr, src, 0, 0);
        if (k != 1) c.cairo_pattern_set_filter(c.cairo_get_source(cr), c.CAIRO_FILTER_GOOD);
        c.cairo_paint(cr);
        c.cairo_restore(cr);
    }
    c.cairo_surface_flush(surf);

    out.is_opaque = lasso == null and covered == @as(i64, rect.w) * rect.h;
    return out;
}

test "compose stitches two outputs and marks gaps transparent" {
    const gpa = std.testing.allocator;
    const layout_mod = @import("layout.zig");
    var a = try Image.alloc(gpa, 4, 2);
    defer a.deinit(gpa);
    var b = try Image.alloc(gpa, 4, 2);
    defer b.deinit(gpa);
    @memset(a.pixels, 0x11);
    a.forceOpaque();
    @memset(b.pixels, 0x22);
    b.forceOpaque();
    const l = layout_mod.Layout.init(&.{
        layout_mod.OutputGeom.fromSizes(0, 0, 4, 2, 4, 2, 1),
        layout_mod.OutputGeom.fromSizes(4, 0, 4, 2, 4, 2, 1),
    });

    var r = try compose(gpa, &l, &.{ a, b }, .{ .x = 2, .y = 0, .w = 4, .h = 2 }, null);
    defer r.deinit(gpa);
    try std.testing.expect(r.is_opaque);
    try std.testing.expectEqual(@as(u8, 0x11), r.pixels[4]); // x=1 → output a
    try std.testing.expectEqual(@as(u8, 0x22), r.pixels[8]); // x=2 → output b

    var g = try compose(gpa, &l, &.{ a, b }, .{ .x = 6, .y = 0, .w = 4, .h = 2 }, null);
    defer g.deinit(gpa);
    try std.testing.expect(!g.is_opaque);
    try std.testing.expectEqual(@as(u8, 0), g.pixels[3 * 4 + 3]); // x=9 is off-canvas: alpha 0
}
