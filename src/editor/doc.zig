//! The editor's document: the captured image's size, vector annotations on top of it,
//! a non-destructive crop, and an undo/redo history.
//!
//! Annotations are never rasterized into the image until export, so undo and redo
//! only flip visibility or swap a crop rect; nothing stores pixel snapshots. Objects
//! are immutable once added: editing one (re-opening text) hides the old object and
//! adds a new one as a single `replace` step. Pure: no Cairo, no Wayland.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Rect = @import("../geom.zig").Rect;

pub const Kind = enum { pen, highlighter, line, arrow, rect, ellipse, text, blur, pixelate };

/// Straight (non-premultiplied) RGBA, 0..1.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,

    pub fn eql(x: Color, y: Color) bool {
        return x.r == y.r and x.g == y.g and x.b == y.b and x.a == y.a;
    }
};

pub const Pt = [2]f32;

pub const Obj = struct {
    kind: Kind,
    color: Color,
    /// Image px. Stroke width for strokes and shapes, font size for text, radius for
    /// blur, block size for pixelate.
    size: f32,
    /// pen/highlighter: the polyline. text: [anchor]. Everything else: [start, end].
    points: []Pt,
    text: []u8 = &.{},
    /// text only: layout box in image px (x, y, w, h), measured by the renderer.
    text_box: [4]f32 = .{ 0, 0, 0, 0 },
    visible: bool = true,

    fn deinit(o: *Obj, gpa: Allocator) void {
        gpa.free(o.points);
        if (o.text.len > 0) gpa.free(o.text);
    }

    /// Axis-aligned box of the two control points (shapes, blur, pixelate).
    pub fn box(o: Obj) [4]f32 {
        const a = o.points[0];
        const b = o.points[o.points.len - 1];
        const x0 = @min(a[0], b[0]);
        const y0 = @min(a[1], b[1]);
        return .{ x0, y0, @max(a[0], b[0]) - x0, @max(a[1], b[1]) - y0 };
    }

    /// Integer image-px rect covered by a blur/pixelate object.
    pub fn pixelBox(o: Obj) Rect {
        const b = o.box();
        const x0: i32 = @intFromFloat(@floor(b[0]));
        const y0: i32 = @intFromFloat(@floor(b[1]));
        const x1: i32 = @intFromFloat(@ceil(b[0] + b[2]));
        const y1: i32 = @intFromFloat(@ceil(b[1] + b[3]));
        return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
    }

    /// Conservative bounds in image px, including stroke width and arrow heads.
    pub fn bounds(o: Obj) [4]f32 {
        switch (o.kind) {
            .text => return o.text_box,
            .blur, .pixelate => return o.box(),
            else => {},
        }
        var x0: f32 = std.math.inf(f32);
        var y0: f32 = std.math.inf(f32);
        var x1: f32 = -std.math.inf(f32);
        var y1: f32 = -std.math.inf(f32);
        for (o.points) |p| {
            x0 = @min(x0, p[0]);
            y0 = @min(y0, p[1]);
            x1 = @max(x1, p[0]);
            y1 = @max(y1, p[1]);
        }
        const pad = if (o.kind == .arrow) arrowHeadLen(o.size) else o.size / 2 + 1;
        return .{ x0 - pad, y0 - pad, x1 - x0 + 2 * pad, y1 - y0 + 2 * pad };
    }

    /// Distance from p to the object's visible ink (0 when inside a filled area).
    pub fn distance(o: Obj, p: Pt) f32 {
        const half = o.size / 2;
        switch (o.kind) {
            .pen, .highlighter, .line, .arrow => {
                if (o.points.len == 1) return @max(0, dist(p, o.points[0]) - half);
                var best: f32 = std.math.inf(f32);
                for (o.points[0 .. o.points.len - 1], o.points[1..]) |a, b| best = @min(best, segDist(p, a, b));
                return @max(0, best - half);
            },
            .rect => {
                const b = o.box();
                return @max(0, rectOutlineDist(p, b) - half);
            },
            .ellipse => {
                const b = o.box();
                return @max(0, ellipseOutlineDist(p, b) - half);
            },
            .text => return rectFillDist(p, o.text_box),
            .blur, .pixelate => return rectFillDist(p, o.box()),
        }
    }
};

/// Arrow head length for a given stroke width (shared with the renderer).
pub fn arrowHeadLen(width: f32) f32 {
    return @max(14, width * 4);
}

pub const Cmd = union(enum) {
    add: u32,
    erase: []u32,
    replace: struct { old: u32, new: u32 },
    crop: struct { old: ?Rect, new: ?Rect },

    fn deinit(c: Cmd, gpa: Allocator) void {
        switch (c) {
            .erase => |ids| gpa.free(ids),
            else => {},
        }
    }
};

pub const Doc = struct {
    gpa: Allocator,
    width: u32,
    height: u32,
    objs: std.ArrayList(Obj) = .empty,
    /// Image px; null means the whole image.
    crop: ?Rect = null,
    done: std.ArrayList(Cmd) = .empty,
    undone: std.ArrayList(Cmd) = .empty,
    /// Bumped on every visible change. Render caches and the clipboard key on it.
    rev: u64 = 0,
    /// `rev` when the document was last written to disk.
    saved_rev: u64 = 0,

    pub fn init(gpa: Allocator, width: u32, height: u32) Doc {
        return .{ .gpa = gpa, .width = width, .height = height };
    }

    pub fn deinit(d: *Doc) void {
        for (d.objs.items) |*o| o.deinit(d.gpa);
        d.objs.deinit(d.gpa);
        for (d.done.items) |c| c.deinit(d.gpa);
        d.done.deinit(d.gpa);
        for (d.undone.items) |c| c.deinit(d.gpa);
        d.undone.deinit(d.gpa);
    }

    pub fn dirty(d: *const Doc) bool {
        return d.rev != d.saved_rev;
    }

    pub fn bounds(d: *const Doc) Rect {
        return .{ .x = 0, .y = 0, .w = @intCast(d.width), .h = @intCast(d.height) };
    }

    /// The part of the image that's exported.
    pub fn view(d: *const Doc) Rect {
        return d.crop orelse d.bounds();
    }

    pub fn canUndo(d: *const Doc) bool {
        return d.done.items.len > 0;
    }

    pub fn canRedo(d: *const Doc) bool {
        return d.undone.items.len > 0;
    }

    /// Add an object. Takes ownership of `o.points` and `o.text` (allocated with `gpa`),
    /// freeing them on error.
    pub fn add(d: *Doc, o: Obj) !u32 {
        var obj = o;
        errdefer obj.deinit(d.gpa);
        try d.objs.ensureUnusedCapacity(d.gpa, 1);
        try d.done.ensureUnusedCapacity(d.gpa, 1);
        const id: u32 = @intCast(d.objs.items.len);
        obj.visible = true;
        d.objs.appendAssumeCapacity(obj);
        d.push(.{ .add = id });
        return id;
    }

    /// Hide `old` and add `o` in its place, as one undo step. Ownership as for `add`.
    pub fn replace(d: *Doc, old: u32, o: Obj) !u32 {
        var obj = o;
        errdefer obj.deinit(d.gpa);
        try d.objs.ensureUnusedCapacity(d.gpa, 1);
        try d.done.ensureUnusedCapacity(d.gpa, 1);
        const id: u32 = @intCast(d.objs.items.len);
        obj.visible = true;
        d.objs.appendAssumeCapacity(obj);
        d.objs.items[old].visible = false;
        d.push(.{ .replace = .{ .old = old, .new = id } });
        return id;
    }

    /// Hide an object immediately (eraser feedback during a drag). Pair with `commitErase`.
    pub fn hide(d: *Doc, id: u32) void {
        if (!d.objs.items[id].visible) return;
        d.objs.items[id].visible = false;
        d.rev += 1;
    }

    /// Record already-hidden objects as one erase step. Takes ownership of `ids`.
    pub fn commitErase(d: *Doc, ids: []u32) !void {
        if (ids.len == 0) {
            d.gpa.free(ids);
            return;
        }
        errdefer d.gpa.free(ids);
        try d.done.ensureUnusedCapacity(d.gpa, 1);
        for (ids) |id| d.objs.items[id].visible = false;
        d.push(.{ .erase = ids });
    }

    pub fn setCrop(d: *Doc, r: ?Rect) !void {
        const new: ?Rect = if (r) |x| blk: {
            const cl = x.clampTo(d.bounds());
            if (cl.isEmpty() or cl.eql(d.bounds())) break :blk null;
            break :blk cl;
        } else null;
        if (optEql(new, d.crop)) return;
        try d.done.ensureUnusedCapacity(d.gpa, 1);
        const old = d.crop;
        d.crop = new;
        d.push(.{ .crop = .{ .old = old, .new = new } });
    }

    pub fn undo(d: *Doc) bool {
        const c = d.done.pop() orelse return false;
        d.undone.append(d.gpa, c) catch {
            d.done.appendAssumeCapacity(c);
            return false;
        };
        d.apply(c, false);
        return true;
    }

    pub fn redo(d: *Doc) bool {
        const c = d.undone.pop() orelse return false;
        d.done.append(d.gpa, c) catch {
            d.undone.appendAssumeCapacity(c);
            return false;
        };
        d.apply(c, true);
        return true;
    }

    /// Topmost visible object whose ink is within `radius` of p.
    pub fn hitTest(d: *const Doc, p: Pt, radius: f32) ?u32 {
        var i = d.objs.items.len;
        while (i > 0) {
            i -= 1;
            const o = d.objs.items[i];
            if (!o.visible) continue;
            if (o.distance(p) <= radius) return @intCast(i);
        }
        return null;
    }

    /// Capacity for the command must already be reserved.
    fn push(d: *Doc, c: Cmd) void {
        d.done.appendAssumeCapacity(c);
        for (d.undone.items) |u| u.deinit(d.gpa);
        d.undone.clearRetainingCapacity();
        d.rev += 1;
    }

    fn apply(d: *Doc, c: Cmd, forward: bool) void {
        switch (c) {
            .add => |id| d.objs.items[id].visible = forward,
            .erase => |ids| for (ids) |id| {
                d.objs.items[id].visible = !forward;
            },
            .replace => |r| {
                d.objs.items[r.old].visible = !forward;
                d.objs.items[r.new].visible = forward;
            },
            .crop => |cr| d.crop = if (forward) cr.new else cr.old,
        }
        d.rev += 1;
    }
};

fn optEql(a: ?Rect, b: ?Rect) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.eql(b.?);
}

// ---- geometry ----

pub fn dist(a: Pt, b: Pt) f32 {
    return std.math.hypot(a[0] - b[0], a[1] - b[1]);
}

pub fn segDist(p: Pt, a: Pt, b: Pt) f32 {
    const vx = b[0] - a[0];
    const vy = b[1] - a[1];
    const len2 = vx * vx + vy * vy;
    if (len2 == 0) return dist(p, a);
    const t = std.math.clamp(((p[0] - a[0]) * vx + (p[1] - a[1]) * vy) / len2, 0, 1);
    return dist(p, .{ a[0] + t * vx, a[1] + t * vy });
}

fn rectOutlineDist(p: Pt, b: [4]f32) f32 {
    const x0 = b[0];
    const y0 = b[1];
    const x1 = b[0] + b[2];
    const y1 = b[1] + b[3];
    const d1 = segDist(p, .{ x0, y0 }, .{ x1, y0 });
    const d2 = segDist(p, .{ x1, y0 }, .{ x1, y1 });
    const d3 = segDist(p, .{ x1, y1 }, .{ x0, y1 });
    const d4 = segDist(p, .{ x0, y1 }, .{ x0, y0 });
    return @min(@min(d1, d2), @min(d3, d4));
}

fn rectFillDist(p: Pt, b: [4]f32) f32 {
    const dx = @max(@max(b[0] - p[0], 0), p[0] - (b[0] + b[2]));
    const dy = @max(@max(b[1] - p[1], 0), p[1] - (b[1] + b[3]));
    return std.math.hypot(dx, dy);
}

fn ellipseOutlineDist(p: Pt, b: [4]f32) f32 {
    const cx = b[0] + b[2] / 2;
    const cy = b[1] + b[3] / 2;
    const rx = b[2] / 2;
    const ry = b[3] / 2;
    const n = 72;
    var best: f32 = std.math.inf(f32);
    var prev: Pt = .{ cx + rx, cy };
    for (1..n + 1) |i| {
        const t = @as(f32, @floatFromInt(i)) / n * 2 * std.math.pi;
        const q: Pt = .{ cx + rx * @cos(t), cy + ry * @sin(t) };
        best = @min(best, segDist(p, prev, q));
        prev = q;
    }
    return best;
}

/// Snap `b` relative to `a` to the nearest multiple of 45° (Shift with lines).
pub fn snap45(a: Pt, b: Pt) Pt {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = std.math.hypot(dx, dy);
    if (len == 0) return b;
    const step = std.math.pi / 4.0;
    const ang = @round(std.math.atan2(dy, dx) / step) * step;
    return .{ a[0] + len * @cos(ang), a[1] + len * @sin(ang) };
}

/// Make the box from a to b square (Shift with rect/ellipse), keeping a fixed.
pub fn squareFrom(a: Pt, b: Pt) Pt {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const s = @max(@abs(dx), @abs(dy));
    return .{ a[0] + std.math.copysign(s, if (dx == 0) 1 else dx), a[1] + std.math.copysign(s, if (dy == 0) 1 else dy) };
}

// ---- tests ----

const testing = std.testing;

fn testObj(gpa: Allocator, kind: Kind, pts: []const Pt) !Obj {
    return .{ .kind = kind, .color = .{ .r = 1, .g = 0, .b = 0 }, .size = 4, .points = try gpa.dupe(Pt, pts) };
}

test "add, undo, redo, and a new edit drops the redo stack" {
    const gpa = testing.allocator;
    var d = Doc.init(gpa, 100, 100);
    defer d.deinit();
    const a = try d.add(try testObj(gpa, .line, &.{ .{ 0, 0 }, .{ 10, 10 } }));
    const b = try d.add(try testObj(gpa, .rect, &.{ .{ 20, 20 }, .{ 40, 40 } }));
    try testing.expect(d.objs.items[b].visible);
    try testing.expect(d.undo());
    try testing.expect(!d.objs.items[b].visible);
    try testing.expect(d.canRedo());
    try testing.expect(d.redo());
    try testing.expect(d.objs.items[b].visible);
    try testing.expect(d.undo());
    _ = try d.add(try testObj(gpa, .ellipse, &.{ .{ 0, 0 }, .{ 5, 5 } }));
    try testing.expect(!d.canRedo());
    try testing.expect(d.objs.items[a].visible);
}

test "erase and replace are single undo steps" {
    const gpa = testing.allocator;
    var d = Doc.init(gpa, 100, 100);
    defer d.deinit();
    const a = try d.add(try testObj(gpa, .line, &.{ .{ 0, 0 }, .{ 10, 0 } }));
    const b = try d.add(try testObj(gpa, .line, &.{ .{ 0, 5 }, .{ 10, 5 } }));
    d.hide(a);
    d.hide(b);
    try d.commitErase(try gpa.dupe(u32, &.{ a, b }));
    try testing.expect(!d.objs.items[a].visible and !d.objs.items[b].visible);
    try testing.expect(d.undo());
    try testing.expect(d.objs.items[a].visible and d.objs.items[b].visible);

    const c = try d.replace(a, try testObj(gpa, .line, &.{ .{ 0, 50 }, .{ 10, 50 } }));
    try testing.expect(!d.objs.items[a].visible and d.objs.items[c].visible);
    try testing.expect(d.undo());
    try testing.expect(d.objs.items[a].visible and !d.objs.items[c].visible);
}

test "crop is clamped, undoable, and a full-image crop means none" {
    const gpa = testing.allocator;
    var d = Doc.init(gpa, 100, 50);
    defer d.deinit();
    try d.setCrop(.{ .x = -10, .y = 10, .w = 50, .h = 100 });
    try testing.expect(d.view().eql(.{ .x = 0, .y = 10, .w = 40, .h = 40 }));
    try d.setCrop(d.bounds());
    try testing.expect(d.crop == null);
    try testing.expect(d.undo());
    try testing.expect(d.crop != null);
    try testing.expect(d.undo());
    try testing.expect(d.crop == null);
}

test "hitTest finds the topmost object near its ink" {
    const gpa = testing.allocator;
    var d = Doc.init(gpa, 100, 100);
    defer d.deinit();
    const r = try d.add(try testObj(gpa, .rect, &.{ .{ 10, 10 }, .{ 50, 50 } }));
    const l = try d.add(try testObj(gpa, .line, &.{ .{ 0, 30 }, .{ 100, 30 } }));
    try testing.expectEqual(@as(?u32, l), d.hitTest(.{ 30, 31 }, 2));
    try testing.expectEqual(@as(?u32, r), d.hitTest(.{ 10, 40 }, 2));
    // Inside an outlined rect, away from its edges: nothing.
    try testing.expectEqual(@as(?u32, null), d.hitTest(.{ 25, 45 }, 2));
    d.hide(l);
    try testing.expectEqual(@as(?u32, null), d.hitTest(.{ 30, 31 }, 1));
}

test "snap45 and squareFrom" {
    const s = snap45(.{ 0, 0 }, .{ 10, 1 });
    try testing.expectApproxEqAbs(@as(f32, 0), s[1], 1e-4);
    const q = squareFrom(.{ 0, 0 }, .{ -3, 8 });
    try testing.expectEqual(Pt{ -8, 8 }, q);
}
