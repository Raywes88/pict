//! Draws a document with Cairo: the base image, then every visible annotation in
//! order. The same code paints the editor's view (under a zoom/pan matrix) and the
//! exported image (identity), so what you see is what gets saved.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c");
const Image = @import("../image/Image.zig");
const Rect = @import("../geom.zig").Rect;
const doc_mod = @import("doc.zig");
const Doc = doc_mod.Doc;
const Obj = doc_mod.Obj;
const Pt = doc_mod.Pt;
const effects = @import("effects.zig");

pub const font_family = "Sans Bold";

const Effect = struct { img: Image, surf: *c.cairo_surface_t };

pub const Renderer = struct {
    gpa: Allocator,
    base: *const Image,
    base_surf: *c.cairo_surface_t,
    /// Blur/pixelate results per object id. Objects never change, so entries never go
    /// stale.
    effects: std.AutoHashMapUnmanaged(u32, Effect) = .empty,
    font_opts: *c.cairo_font_options_t,

    pub fn init(gpa: Allocator, base: *const Image) !Renderer {
        const surf = c.cairo_image_surface_create_for_data(base.pixels.ptr, c.CAIRO_FORMAT_ARGB32, @intCast(base.width), @intCast(base.height), @intCast(base.stride)) orelse return error.CairoFailed;
        if (c.cairo_surface_status(surf) != c.CAIRO_STATUS_SUCCESS) return error.CairoFailed;
        // Unhinted metrics so a text box measures the same at every zoom level.
        const fo = c.cairo_font_options_create() orelse return error.CairoFailed;
        c.cairo_font_options_set_hint_metrics(fo, c.CAIRO_HINT_METRICS_OFF);
        c.cairo_font_options_set_hint_style(fo, c.CAIRO_HINT_STYLE_NONE);
        c.cairo_font_options_set_antialias(fo, c.CAIRO_ANTIALIAS_GRAY);
        return .{ .gpa = gpa, .base = base, .base_surf = surf, .font_opts = fo };
    }

    pub fn deinit(r: *Renderer) void {
        var it = r.effects.valueIterator();
        while (it.next()) |e| {
            c.cairo_surface_destroy(e.surf);
            e.img.deinit(r.gpa);
        }
        r.effects.deinit(r.gpa);
        c.cairo_font_options_destroy(r.font_opts);
        c.cairo_surface_destroy(r.base_surf);
    }

    /// Paint the base image and visible objects in image coordinates. The caller sets
    /// the matrix and clip. `filter` is the Cairo filter for image pixels.
    /// `skip` leaves one object out (the text being re-edited).
    pub fn drawDoc(r: *Renderer, cr: *c.cairo_t, doc: *const Doc, filter: c.cairo_filter_t, skip: ?u32) void {
        c.cairo_save(cr);
        c.cairo_set_source_surface(cr, r.base_surf, 0, 0);
        c.cairo_pattern_set_filter(c.cairo_get_source(cr), filter);
        c.cairo_rectangle(cr, 0, 0, @floatFromInt(r.base.width), @floatFromInt(r.base.height));
        c.cairo_fill(cr);
        c.cairo_restore(cr);
        for (doc.objs.items, 0..) |o, i| {
            if (!o.visible) continue;
            if (skip) |sk| if (sk == i) continue;
            r.drawObj(cr, o, @intCast(i), filter);
        }
    }

    /// Draw one object. `id` keys the effect cache; null draws a cheap preview for
    /// blur/pixelate (used while dragging).
    pub fn drawObj(r: *Renderer, cr: *c.cairo_t, o: Obj, id: ?u32, filter: c.cairo_filter_t) void {
        c.cairo_save(cr);
        defer c.cairo_restore(cr);
        const col = o.color;
        c.cairo_set_source_rgba(cr, col.r, col.g, col.b, col.a);
        c.cairo_set_line_width(cr, o.size);
        c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_ROUND);
        c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_ROUND);

        switch (o.kind) {
            .pen, .highlighter => {
                // Multiply keeps text under the highlighter readable, like real ink.
                if (o.kind == .highlighter) c.cairo_set_operator(cr, c.CAIRO_OPERATOR_MULTIPLY);
                if (o.points.len == 1) {
                    const p = o.points[0];
                    c.cairo_arc(cr, p[0], p[1], o.size / 2, 0, 2 * std.math.pi);
                    c.cairo_fill(cr);
                    return;
                }
                smoothPath(cr, o.points);
                c.cairo_stroke(cr);
            },
            .line => {
                const a = o.points[0];
                const b = o.points[o.points.len - 1];
                c.cairo_move_to(cr, a[0], a[1]);
                c.cairo_line_to(cr, b[0], b[1]);
                c.cairo_stroke(cr);
            },
            .arrow => drawArrow(cr, o.points[0], o.points[o.points.len - 1], o.size),
            .rect => {
                const b = o.box();
                c.cairo_set_line_join(cr, c.CAIRO_LINE_JOIN_MITER);
                c.cairo_rectangle(cr, b[0], b[1], b[2], b[3]);
                c.cairo_stroke(cr);
            },
            .ellipse => {
                const b = o.box();
                if (b[2] < 0.5 or b[3] < 0.5) return;
                c.cairo_save(cr);
                c.cairo_translate(cr, b[0] + b[2] / 2, b[1] + b[3] / 2);
                c.cairo_scale(cr, b[2] / 2, b[3] / 2);
                c.cairo_arc(cr, 0, 0, 1, 0, 2 * std.math.pi);
                c.cairo_restore(cr); // stroke with an unscaled pen
                c.cairo_stroke(cr);
            },
            .text => {
                if (o.text.len == 0) return;
                const l = r.makeLayout(cr, o.text, o.size) orelse return;
                defer c.g_object_unref(l);
                c.cairo_move_to(cr, o.points[0][0], o.points[0][1]);
                c.pango_cairo_show_layout(cr, l);
            },
            .blur, .pixelate => {
                const pb = o.pixelBox().clampTo(.{ .x = 0, .y = 0, .w = @intCast(r.base.width), .h = @intCast(r.base.height) });
                if (pb.isEmpty()) return;
                const e = if (id) |i| r.effect(i, o, pb) else null;
                if (e) |eff| {
                    c.cairo_set_source_surface(cr, eff.surf, @floatFromInt(pb.x), @floatFromInt(pb.y));
                    c.cairo_pattern_set_filter(c.cairo_get_source(cr), filter);
                    rect(cr, pb);
                    c.cairo_fill(cr);
                } else {
                    rect(cr, pb);
                    c.cairo_set_source_rgba(cr, 0.5, 0.5, 0.55, 0.55);
                    c.cairo_fill(cr);
                }
            },
        }
    }

    fn effect(r: *Renderer, id: u32, o: Obj, pb: Rect) ?Effect {
        if (r.effects.get(id)) |e| return e;
        const img = switch (o.kind) {
            .blur => effects.blur(r.gpa, r.base.*, pb, @intFromFloat(@max(1, o.size))),
            else => effects.pixelate(r.gpa, r.base.*, pb, @intFromFloat(@max(2, o.size))),
        } catch return null;
        const surf = c.cairo_image_surface_create_for_data(img.pixels.ptr, c.CAIRO_FORMAT_ARGB32, @intCast(img.width), @intCast(img.height), @intCast(img.stride)) orelse {
            var m = img;
            m.deinit(r.gpa);
            return null;
        };
        const e: Effect = .{ .img = img, .surf = surf };
        r.effects.put(r.gpa, id, e) catch {
            c.cairo_surface_destroy(surf);
            var m = img;
            m.deinit(r.gpa);
            return null;
        };
        return e;
    }

    /// A Pango layout for `text` at `size` image px. Caller unrefs.
    pub fn makeLayout(r: *Renderer, cr: *c.cairo_t, text: []const u8, size: f32) ?*c.PangoLayout {
        const l = c.pango_cairo_create_layout(cr) orelse return null;
        const ctx = c.pango_layout_get_context(l);
        c.pango_cairo_context_set_font_options(ctx, r.font_opts);
        c.pango_context_set_round_glyph_positions(ctx, 0);
        c.pango_layout_context_changed(l);
        const desc = c.pango_font_description_from_string(font_family);
        defer c.pango_font_description_free(desc);
        c.pango_font_description_set_absolute_size(desc, @as(f64, size) * c.PANGO_SCALE);
        c.pango_layout_set_font_description(l, desc);
        c.pango_layout_set_text(l, text.ptr, @intCast(text.len));
        return l;
    }

    /// Text layout box (x, y, w, h) in image px for text anchored at `at`. Empty text
    /// still gets one line's height so the caret has somewhere to go.
    pub fn measureText(r: *Renderer, text: []const u8, size: f32, at: Pt) [4]f32 {
        const surf = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 1, 1);
        defer c.cairo_surface_destroy(surf);
        const cr = c.cairo_create(surf) orelse return .{ at[0], at[1], 0, size };
        defer c.cairo_destroy(cr);
        const l = r.makeLayout(cr, if (text.len == 0) " " else text, size) orelse return .{ at[0], at[1], 0, size };
        defer c.g_object_unref(l);
        var ink: c.PangoRectangle = undefined;
        var logical: c.PangoRectangle = undefined;
        c.pango_layout_get_extents(l, &ink, &logical);
        const s: f32 = c.PANGO_SCALE;
        const w: f32 = if (text.len == 0) 0 else @as(f32, @floatFromInt(logical.width)) / s;
        return .{ at[0], at[1], w, @as(f32, @floatFromInt(logical.height)) / s };
    }

    /// Caret (x, y, h) after the last character of `text`, in image px.
    pub fn caret(r: *Renderer, text: []const u8, size: f32, at: Pt) [3]f32 {
        const surf = c.cairo_image_surface_create(c.CAIRO_FORMAT_ARGB32, 1, 1);
        defer c.cairo_surface_destroy(surf);
        const cr = c.cairo_create(surf) orelse return .{ at[0], at[1], size };
        defer c.cairo_destroy(cr);
        const l = r.makeLayout(cr, text, size) orelse return .{ at[0], at[1], size };
        defer c.g_object_unref(l);
        var strong: c.PangoRectangle = undefined;
        c.pango_layout_get_cursor_pos(l, @intCast(text.len), &strong, null);
        const s: f32 = c.PANGO_SCALE;
        const h = if (strong.height > 0) @as(f32, @floatFromInt(strong.height)) / s else size * 1.2;
        return .{ at[0] + @as(f32, @floatFromInt(strong.x)) / s, at[1] + @as(f32, @floatFromInt(strong.y)) / s, h };
    }

    /// Render the exported image: the crop of base + annotations. Owned by `gpa`.
    pub fn flatten(r: *Renderer, gpa: Allocator, doc: *const Doc) !Image {
        const v = doc.view();
        var out = try Image.alloc(gpa, @intCast(v.w), @intCast(v.h));
        errdefer out.deinit(gpa);
        @memset(out.pixels, 0);
        const surf = c.cairo_image_surface_create_for_data(out.pixels.ptr, c.CAIRO_FORMAT_ARGB32, v.w, v.h, @intCast(out.stride));
        defer c.cairo_surface_destroy(surf);
        const cr = c.cairo_create(surf) orelse return error.CairoFailed;
        defer c.cairo_destroy(cr);
        if (c.cairo_status(cr) != c.CAIRO_STATUS_SUCCESS) return error.CairoFailed;
        c.cairo_translate(cr, @floatFromInt(-v.x), @floatFromInt(-v.y));
        r.drawDoc(cr, doc, c.CAIRO_FILTER_NEAREST, null);
        c.cairo_surface_flush(surf);
        // Annotations only ever paint over the base, so an opaque base stays opaque.
        out.is_opaque = r.base.is_opaque;
        return out;
    }
};

/// Polyline smoothed with quadratic segments through the midpoints.
fn smoothPath(cr: *c.cairo_t, pts: []const Pt) void {
    c.cairo_move_to(cr, pts[0][0], pts[0][1]);
    if (pts.len == 2) {
        c.cairo_line_to(cr, pts[1][0], pts[1][1]);
        return;
    }
    var cur = pts[0];
    for (1..pts.len - 1) |i| {
        const ctl = pts[i];
        const end: Pt = .{ (pts[i][0] + pts[i + 1][0]) / 2, (pts[i][1] + pts[i + 1][1]) / 2 };
        quadTo(cr, cur, ctl, end);
        cur = end;
    }
    const last = pts[pts.len - 1];
    c.cairo_line_to(cr, last[0], last[1]);
}

fn quadTo(cr: *c.cairo_t, p0: Pt, ctl: Pt, p2: Pt) void {
    const k = 2.0 / 3.0;
    c.cairo_curve_to(
        cr,
        p0[0] + k * (ctl[0] - p0[0]),
        p0[1] + k * (ctl[1] - p0[1]),
        p2[0] + k * (ctl[0] - p2[0]),
        p2[1] + k * (ctl[1] - p2[1]),
        p2[0],
        p2[1],
    );
}

fn drawArrow(cr: *c.cairo_t, a: Pt, b: Pt, w: f32) void {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = std.math.hypot(dx, dy);
    if (len < 0.5) return;
    const ux = dx / len;
    const uy = dy / len;
    const head = @min(doc_mod.arrowHeadLen(w), len);
    const half = head * 0.5;
    const base: Pt = .{ b[0] - ux * head, b[1] - uy * head };
    // Shaft stops inside the head so a thick line never pokes past the tip.
    const shaft_end: Pt = .{ b[0] - ux * head * 0.6, b[1] - uy * head * 0.6 };
    c.cairo_set_line_cap(cr, c.CAIRO_LINE_CAP_BUTT);
    c.cairo_move_to(cr, a[0], a[1]);
    c.cairo_line_to(cr, shaft_end[0], shaft_end[1]);
    c.cairo_stroke(cr);
    c.cairo_move_to(cr, b[0], b[1]);
    c.cairo_line_to(cr, base[0] - uy * half, base[1] + ux * half);
    c.cairo_line_to(cr, base[0] + uy * half, base[1] - ux * half);
    c.cairo_close_path(cr);
    c.cairo_fill(cr);
}

fn rect(cr: *c.cairo_t, r: Rect) void {
    c.cairo_rectangle(cr, @floatFromInt(r.x), @floatFromInt(r.y), @floatFromInt(r.w), @floatFromInt(r.h));
}

// ---- tests ----

test "flatten paints annotations over the crop" {
    const gpa = std.testing.allocator;
    var base = try Image.alloc(gpa, 40, 20);
    defer base.deinit(gpa);
    @memset(base.pixels, 0xff); // opaque white
    base.is_opaque = true;
    var r = try Renderer.init(gpa, &base);
    defer r.deinit();
    var d = Doc.init(gpa, 40, 20);
    defer d.deinit();
    _ = try d.add(.{ .kind = .rect, .color = .{ .r = 1, .g = 0, .b = 0 }, .size = 2, .points = try gpa.dupe(Pt, &.{ .{ 10, 5 }, .{ 30, 15 } }) });
    try d.setCrop(.{ .x = 5, .y = 0, .w = 30, .h = 20 });
    var out = try r.flatten(gpa, &d);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(u32, 30), out.width);
    try std.testing.expect(out.is_opaque);
    // Left edge of the rect (x = 10 in the image) is at x = 5 in the crop: red.
    const p = out.pixels[10 * out.stride + 5 * 4 ..][0..4];
    try std.testing.expectEqual(@as(u8, 0xff), p[2]);
    try std.testing.expect(p[1] < 0x40);
    // Inside the outline stays white.
    try std.testing.expectEqual(@as(u8, 0xff), out.pixels[10 * out.stride + 15 * 4 + 1]);
}

test "text measures wider for more characters" {
    const gpa = std.testing.allocator;
    var base = try Image.alloc(gpa, 4, 4);
    defer base.deinit(gpa);
    @memset(base.pixels, 0);
    var r = try Renderer.init(gpa, &base);
    defer r.deinit();
    const a = r.measureText("Hi", 20, .{ 0, 0 });
    const b = r.measureText("Hello there", 20, .{ 0, 0 });
    try std.testing.expect(b[2] > a[2] and a[2] > 0);
    try std.testing.expect(a[3] >= 20);
}
