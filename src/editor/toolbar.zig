//! The editor's one-row toolbar: layout, hit-testing, drawing and tooltips.
//! Everything here is in logical pixels; the caller scales the Cairo context.

const std = @import("std");
const c = @import("c");
const icons = @import("icons.zig");
const Icon = icons.Icon;
const Color = @import("doc.zig").Color;

pub const Tool = enum { pen, highlighter, eraser, line, arrow, rect, ellipse, text, blur, pixelate, crop, picker };

pub const palette = [8]Color{
    .{ .r = 0.898, .g = 0.224, .b = 0.208 }, // red
    .{ .r = 0.984, .g = 0.549, .b = 0.0 }, // orange
    .{ .r = 0.992, .g = 0.847, .b = 0.208 }, // yellow
    .{ .r = 0.263, .g = 0.627, .b = 0.278 }, // green
    .{ .r = 0.118, .g = 0.533, .b = 0.898 }, // blue
    .{ .r = 0.557, .g = 0.141, .b = 0.667 }, // purple
    .{ .r = 0.067, .g = 0.067, .b = 0.067 }, // black
    .{ .r = 1, .g = 1, .b = 1 }, // white
};

pub const Item = union(enum) {
    tool: Tool,
    swatch: u8,
    custom,
    size_down,
    size_value,
    size_up,
    undo,
    redo,
    zoom,
    copy,
    save,
    save_as,

    pub fn eql(a: Item, b: Item) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .tool => |t| t == b.tool,
            .swatch => |s| s == b.swatch,
            else => true,
        };
    }
};

pub const height: f64 = 44;
const btn: f64 = 32;
const gap: f64 = 2;
const sep_w: f64 = 15;
const margin: f64 = 8;
const swatch_slot: f64 = 26;

pub const Slot = struct {
    item: Item,
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    pub fn contains(s: Slot, x: f64, y: f64) bool {
        return x >= s.x and x < s.x + s.w and y >= s.y and y < s.y + s.h;
    }
};

const groups = [_][]const Item{
    &.{ .{ .tool = .pen }, .{ .tool = .highlighter }, .{ .tool = .eraser } },
    &.{ .{ .tool = .line }, .{ .tool = .arrow }, .{ .tool = .rect }, .{ .tool = .ellipse }, .{ .tool = .text } },
    &.{ .{ .tool = .blur }, .{ .tool = .pixelate } },
    &.{ .{ .tool = .crop }, .{ .tool = .picker } },
    &.{ .{ .swatch = 0 }, .{ .swatch = 1 }, .{ .swatch = 2 }, .{ .swatch = 3 }, .{ .swatch = 4 }, .{ .swatch = 5 }, .{ .swatch = 6 }, .{ .swatch = 7 }, .custom },
    &.{ .size_down, .size_value, .size_up },
    &.{ .undo, .redo },
};
const right_items = [_]Item{ .zoom, .copy, .save, .save_as };

fn itemWidth(it: Item) f64 {
    return switch (it) {
        .swatch, .custom => swatch_slot,
        .size_down, .size_up => 26,
        .size_value => 34,
        .zoom => 58,
        else => btn + gap,
    };
}

pub const Layout = struct {
    slots: [48]Slot = undefined,
    n: usize = 0,
    seps: [8]f64 = undefined,
    nsep: usize = 0,

    pub fn items(l: *const Layout) []const Slot {
        return l.slots[0..l.n];
    }

    pub fn hit(l: *const Layout, x: f64, y: f64) ?Item {
        for (l.items()) |s| if (s.contains(x, y)) return s.item;
        return null;
    }

    pub fn find(l: *const Layout, item: Item) ?Slot {
        for (l.items()) |s| if (s.item.eql(item)) return s;
        return null;
    }

    fn push(l: *Layout, item: Item, x: f64) void {
        const w = itemWidth(item);
        l.slots[l.n] = .{ .item = item, .x = x, .y = (height - btn) / 2, .w = w - (if (w == btn + gap) gap else 0), .h = btn };
        l.n += 1;
    }
};

/// Narrowest window that fits every item.
pub fn minWidth() f64 {
    var w: f64 = 2 * margin;
    for (groups) |g| {
        for (g) |it| w += itemWidth(it);
    }
    w += sep_w * @as(f64, @floatFromInt(groups.len));
    for (right_items) |it| w += itemWidth(it);
    return w;
}

pub fn layout(width: f64) Layout {
    var l: Layout = .{};
    var x: f64 = margin;
    for (groups, 0..) |g, gi| {
        if (gi > 0) {
            l.seps[l.nsep] = x + sep_w / 2 - gap / 2;
            l.nsep += 1;
            x += sep_w;
        }
        for (g) |it| {
            l.push(it, x);
            x += itemWidth(it);
        }
    }
    var rw: f64 = 0;
    for (right_items) |it| rw += itemWidth(it);
    var rx = @max(x + sep_w, width - margin - rw + gap);
    for (right_items) |it| {
        l.push(it, rx);
        rx += itemWidth(it);
    }
    return l;
}

pub const State = struct {
    tool: Tool,
    color: Color,
    size: f32,
    can_undo: bool,
    can_redo: bool,
    zoom_pct: f64,
    hover: ?Item = null,
    pressed: ?Item = null,
    popover: bool = false,

    pub fn hash(s: State) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&s.tool));
        h.update(std.mem.asBytes(&s.color));
        h.update(std.mem.asBytes(&s.size));
        h.update(&.{ @intFromBool(s.can_undo), @intFromBool(s.can_redo), @intFromBool(s.popover) });
        h.update(std.mem.asBytes(&s.zoom_pct));
        hashItem(&h, s.hover);
        hashItem(&h, s.pressed);
        return h.final();
    }

    fn hashItem(h: *std.hash.Wyhash, it: ?Item) void {
        const v = it orelse {
            h.update(&.{0xff});
            return;
        };
        h.update(&.{@intFromEnum(std.meta.activeTag(v))});
        switch (v) {
            .tool => |t| h.update(&.{@intFromEnum(t)}),
            .swatch => |i| h.update(&.{i}),
            else => {},
        }
    }
};

pub const theme = struct {
    pub const bar = [3]f64{ 0.122, 0.125, 0.141 };
    pub const canvas = [3]f64{ 0.078, 0.082, 0.094 };
    pub const hover = [3]f64{ 0.180, 0.188, 0.212 };
    pub const active = [3]f64{ 0.200, 0.255, 0.384 };
    pub const accent = [3]f64{ 0.424, 0.612, 1.0 };
    pub const fg = [3]f64{ 0.890, 0.898, 0.910 };
    pub const dim = [3]f64{ 0.420, 0.431, 0.459 };
    pub const sep = [3]f64{ 0.200, 0.208, 0.231 };
};

fn rgb(cr: *c.cairo_t, v: [3]f64) void {
    c.cairo_set_source_rgb(cr, v[0], v[1], v[2]);
}

fn toolIcon(t: Tool) Icon {
    return switch (t) {
        .pen => .pen,
        .highlighter => .highlighter,
        .eraser => .eraser,
        .line => .line,
        .arrow => .arrow,
        .rect => .rect,
        .ellipse => .ellipse,
        .text => .text,
        .blur => .blur,
        .pixelate => .pixelate,
        .crop => .crop,
        .picker => .picker,
    };
}

/// Paint the bar across `width` logical px.
pub fn draw(cr: *c.cairo_t, l: *const Layout, s: State, width: f64) void {
    c.cairo_save(cr);
    defer c.cairo_restore(cr);
    c.cairo_rectangle(cr, 0, 0, width, height);
    rgb(cr, theme.bar);
    c.cairo_fill(cr);
    c.cairo_rectangle(cr, 0, height - 1, width, 1);
    rgb(cr, theme.sep);
    c.cairo_fill(cr);

    for (l.seps[0..l.nsep]) |x| {
        c.cairo_rectangle(cr, @round(x), 11, 1, height - 22);
        rgb(cr, theme.sep);
        c.cairo_fill(cr);
    }

    for (l.items()) |slot| {
        const hovered = if (s.hover) |h| h.eql(slot.item) else false;
        const pressed = if (s.pressed) |p| p.eql(slot.item) else false;
        switch (slot.item) {
            .tool => |t| {
                const active = t == s.tool;
                if (active or hovered) {
                    icons.roundRect(cr, slot.x, slot.y, slot.w, slot.h, 6);
                    rgb(cr, if (active) theme.active else theme.hover);
                    c.cairo_fill(cr);
                }
                if (active) {
                    icons.roundRect(cr, slot.x + 0.5, slot.y + 0.5, slot.w - 1, slot.h - 1, 6);
                    c.cairo_set_line_width(cr, 1);
                    rgb(cr, theme.accent);
                    c.cairo_stroke(cr);
                }
                rgb(cr, theme.fg);
                icons.draw(cr, toolIcon(t), slot.x + 5, slot.y + 5, 22);
            },
            .swatch => |i| drawSwatch(cr, slot, palette[i], s.color.eql(palette[i]), hovered),
            .custom => {
                const cx = slot.x + slot.w / 2;
                const cy = slot.y + slot.h / 2;
                const selected = !isPalette(s.color);
                if (selected or hovered or s.popover) ring(cr, cx, cy, 10.5, if (selected or s.popover) theme.accent else theme.dim);
                icons.hueRing(cr, cx, cy, 8);
                if (selected) {
                    c.cairo_arc(cr, cx, cy, 4.5, 0, 2 * std.math.pi);
                    c.cairo_set_source_rgb(cr, s.color.r, s.color.g, s.color.b);
                    c.cairo_fill(cr);
                }
            },
            .size_down, .size_up => {
                if (hovered) {
                    icons.roundRect(cr, slot.x, slot.y + 4, slot.w, slot.h - 8, 5);
                    rgb(cr, theme.hover);
                    c.cairo_fill(cr);
                }
                rgb(cr, theme.fg);
                icons.draw(cr, if (slot.item == .size_down) .minus else .plus, slot.x + slot.w / 2 - 8, slot.y + slot.h / 2 - 8, 16);
            },
            .size_value => {
                var buf: [16]u8 = undefined;
                const txt = std.fmt.bufPrint(&buf, "{d}", .{@as(u32, @intFromFloat(@round(s.size)))}) catch "?";
                rgb(cr, theme.fg);
                label(cr, txt, slot.x, slot.y, slot.w, slot.h, 12, true);
            },
            .undo, .redo => {
                const enabled = if (slot.item == .undo) s.can_undo else s.can_redo;
                button(cr, slot, hovered and enabled, pressed and enabled);
                rgb(cr, if (enabled) theme.fg else theme.dim);
                icons.draw(cr, if (slot.item == .undo) .undo else .redo, slot.x + 5, slot.y + 5, 22);
            },
            .zoom => {
                if (hovered) {
                    icons.roundRect(cr, slot.x, slot.y + 4, slot.w - 4, slot.h - 8, 5);
                    rgb(cr, theme.hover);
                    c.cairo_fill(cr);
                }
                var buf: [16]u8 = undefined;
                const txt = std.fmt.bufPrint(&buf, "{d}%", .{@as(u32, @intFromFloat(@round(s.zoom_pct)))}) catch "?";
                rgb(cr, theme.fg);
                label(cr, txt, slot.x, slot.y, slot.w - 4, slot.h, 12, true);
            },
            .copy, .save, .save_as => {
                button(cr, slot, hovered, pressed);
                rgb(cr, theme.fg);
                const ic: Icon = switch (slot.item) {
                    .copy => .copy,
                    .save => .save,
                    else => .save_as,
                };
                icons.draw(cr, ic, slot.x + 5, slot.y + 5, 22);
            },
        }
    }
}

fn button(cr: *c.cairo_t, slot: Slot, hovered: bool, pressed: bool) void {
    if (!hovered and !pressed) return;
    icons.roundRect(cr, slot.x, slot.y, slot.w, slot.h, 6);
    rgb(cr, if (pressed) theme.active else theme.hover);
    c.cairo_fill(cr);
}

fn isPalette(col: Color) bool {
    for (palette) |p| if (p.eql(col)) return true;
    return false;
}

fn ring(cr: *c.cairo_t, cx: f64, cy: f64, r: f64, col: [3]f64) void {
    c.cairo_arc(cr, cx, cy, r, 0, 2 * std.math.pi);
    c.cairo_set_line_width(cr, 2);
    rgb(cr, col);
    c.cairo_stroke(cr);
}

fn drawSwatch(cr: *c.cairo_t, slot: Slot, col: Color, selected: bool, hovered: bool) void {
    const cx = slot.x + slot.w / 2;
    const cy = slot.y + slot.h / 2;
    if (selected or hovered) ring(cr, cx, cy, 10.5, if (selected) theme.accent else theme.dim);
    c.cairo_arc(cr, cx, cy, 8, 0, 2 * std.math.pi);
    c.cairo_set_source_rgb(cr, col.r, col.g, col.b);
    c.cairo_fill_preserve(cr);
    // Thin outline so black and white swatches read on the dark bar.
    c.cairo_set_line_width(cr, 1);
    c.cairo_set_source_rgba(cr, 1, 1, 1, 0.18);
    c.cairo_stroke(cr);
}

/// Draw `text` in the box with Pango (UI font), centred or left-aligned.
pub fn label(cr: *c.cairo_t, text: []const u8, x: f64, y: f64, w: f64, h: f64, size: f64, center: bool) void {
    const l = c.pango_cairo_create_layout(cr) orelse return;
    defer c.g_object_unref(l);
    const desc = c.pango_font_description_from_string("Sans");
    defer c.pango_font_description_free(desc);
    c.pango_font_description_set_absolute_size(desc, size * c.PANGO_SCALE);
    c.pango_layout_set_font_description(l, desc);
    c.pango_layout_set_text(l, text.ptr, @intCast(text.len));
    var tw: c_int = 0;
    var th: c_int = 0;
    c.pango_layout_get_pixel_size(l, &tw, &th);
    const fw: f64 = @floatFromInt(tw);
    const fh: f64 = @floatFromInt(th);
    const tx = if (center) x + (w - fw) / 2 else x;
    c.cairo_move_to(cr, @round(tx), @round(y + (h - fh) / 2));
    c.pango_cairo_show_layout(cr, l);
}

/// Width and height of `text` in the UI font.
pub fn measure(cr: *c.cairo_t, text: []const u8, size: f64) [2]f64 {
    const l = c.pango_cairo_create_layout(cr) orelse return .{ 0, 0 };
    defer c.g_object_unref(l);
    const desc = c.pango_font_description_from_string("Sans");
    defer c.pango_font_description_free(desc);
    c.pango_font_description_set_absolute_size(desc, size * c.PANGO_SCALE);
    c.pango_layout_set_font_description(l, desc);
    c.pango_layout_set_text(l, text.ptr, @intCast(text.len));
    var tw: c_int = 0;
    var th: c_int = 0;
    c.pango_layout_get_pixel_size(l, &tw, &th);
    return .{ @floatFromInt(tw), @floatFromInt(th) };
}

pub fn tooltip(item: Item, buf: []u8) []const u8 {
    return switch (item) {
        .tool => |t| switch (t) {
            .pen => "Pen   P   (Shift: straight)",
            .highlighter => "Highlighter   H   (Shift: straight)",
            .eraser => "Eraser   E   (removes whole marks)",
            .line => "Line   L   (Shift: 45\u{00b0})",
            .arrow => "Arrow   A   (Shift: 45\u{00b0})",
            .rect => "Rectangle   R   (Shift: square)",
            .ellipse => "Ellipse   O   (Shift: circle)",
            .text => "Text   T   (Esc or click away to finish)",
            .blur => "Blur   B",
            .pixelate => "Pixelate   X",
            .crop => "Crop   C   (Enter applies, Esc cancels)",
            .picker => "Pick a colour from the image   I",
        },
        .swatch => |i| std.fmt.bufPrint(buf, "Colour   {d}", .{i + 1}) catch "Colour",
        .custom => "Custom colour",
        .size_down => "Thinner   [",
        .size_value => "Size",
        .size_up => "Thicker   ]",
        .undo => "Undo   Ctrl+Z",
        .redo => "Redo   Ctrl+Shift+Z",
        .zoom => "Fit   Ctrl+0     100%   Ctrl+1",
        .copy => "Copy   Ctrl+C",
        .save => "Save   Ctrl+S",
        .save_as => "Save as\u{2026}   Ctrl+Shift+S",
    };
}

test "layout hit-tests and stays inside its minimum width" {
    const w = minWidth();
    const l = layout(w);
    try std.testing.expect(l.n == 3 + 5 + 2 + 2 + 9 + 3 + 2 + 4);
    const pen = l.find(.{ .tool = .pen }).?;
    try std.testing.expect(l.hit(pen.x + 2, pen.y + 2).?.eql(.{ .tool = .pen }));
    const last = l.slots[l.n - 1];
    try std.testing.expect(last.x + last.w <= w);
}
