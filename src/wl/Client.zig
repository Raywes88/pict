//! Wayland connection, globals and outputs.

const Client = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const wp = wayland.client.wp;
const zxdg = wayland.client.zxdg;
const zwlr = wayland.client.zwlr;
const xdg = wayland.client.xdg;

gpa: Allocator,
display: *wl.Display,
registry: *wl.Registry,

compositor: ?*wl.Compositor = null,
subcompositor: ?*wl.Subcompositor = null,
shm: ?*wl.Shm = null,
seat: ?*wl.Seat = null,
seat_caps: wl.Seat.Capability = .{},
xdg_output_manager: ?*zxdg.OutputManagerV1 = null,
layer_shell: ?*zwlr.LayerShellV1 = null,
screencopy: ?*zwlr.ScreencopyManagerV1 = null,
viewporter: ?*wp.Viewporter = null,
cursor_shape: ?*wp.CursorShapeManagerV1 = null,
fractional_scale: ?*wp.FractionalScaleManagerV1 = null,
wm_base: ?*xdg.WmBase = null,

outputs: std.ArrayList(*Output) = .empty,

pub const Output = struct {
    client: *Client,
    wl_output: *wl.Output,
    global_name: u32,
    xdg_output: ?*zxdg.OutputV1 = null,

    name: ?[]u8 = null,
    transform: wl.Output.Transform = .normal,
    /// Current mode, in physical pixels.
    mode_w: i32 = 0,
    mode_h: i32 = 0,
    /// Integer wl_output scale (informational; fractional scale comes from logical size).
    scale: i32 = 1,
    /// Position and size in the compositor's logical coordinate space (xdg-output).
    logical_x: i32 = 0,
    logical_y: i32 = 0,
    logical_w: i32 = 0,
    logical_h: i32 = 0,

    pub fn displayName(o: *const Output) []const u8 {
        return o.name orelse "(unnamed)";
    }

    fn deinit(o: *Output, gpa: Allocator) void {
        if (o.xdg_output) |x| x.destroy();
        o.wl_output.release();
        if (o.name) |n| gpa.free(n);
        gpa.destroy(o);
    }
};

pub fn connect(gpa: Allocator) !*Client {
    const display = wl.Display.connect(null) catch return error.NoWaylandDisplay;
    errdefer display.disconnect();
    const registry = try display.getRegistry();

    const self = try gpa.create(Client);
    errdefer gpa.destroy(self);
    self.* = .{ .gpa = gpa, .display = display, .registry = registry };

    registry.setListener(*Client, registryListener, self);
    try self.roundtrip(); // globals
    if (self.xdg_output_manager) |mgr| {
        for (self.outputs.items) |o| self.attachXdgOutput(mgr, o);
    }
    try self.roundtrip(); // output geometry, names, seat capabilities
    return self;
}

pub fn deinit(self: *Client) void {
    for (self.outputs.items) |o| o.deinit(self.gpa);
    self.outputs.deinit(self.gpa);
    if (self.wm_base) |g| g.destroy();
    if (self.fractional_scale) |g| g.destroy();
    if (self.cursor_shape) |g| g.destroy();
    if (self.viewporter) |g| g.destroy();
    if (self.screencopy) |g| g.destroy();
    if (self.layer_shell) |g| g.destroy();
    if (self.xdg_output_manager) |g| g.destroy();
    if (self.seat) |g| g.release();
    if (self.shm) |g| g.destroy();
    if (self.subcompositor) |g| g.destroy();
    if (self.compositor) |g| g.destroy();
    self.registry.destroy();
    self.display.disconnect();
    self.gpa.destroy(self);
}

pub fn roundtrip(self: *Client) !void {
    if (self.display.roundtrip() != .SUCCESS) return error.WaylandRoundtripFailed;
}

pub fn dispatch(self: *Client) !void {
    if (self.display.dispatch() != .SUCCESS) return error.WaylandDispatchFailed;
}

pub fn findOutput(self: *Client, name: []const u8) ?*Output {
    for (self.outputs.items) |o| {
        if (o.name) |n| if (std.mem.eql(u8, n, name)) return o;
    }
    return null;
}

fn attachXdgOutput(self: *Client, mgr: *zxdg.OutputManagerV1, o: *Output) void {
    _ = self;
    if (o.xdg_output != null) return;
    const x = mgr.getXdgOutput(o.wl_output) catch return;
    o.xdg_output = x;
    x.setListener(*Output, xdgOutputListener, o);
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, self: *Client) void {
    switch (event) {
        .global => |g| {
            const iface = std.mem.span(g.interface);
            if (is(iface, wl.Compositor)) {
                self.compositor = registry.bind(g.name, wl.Compositor, g.version) catch null;
            } else if (is(iface, wl.Subcompositor)) {
                self.subcompositor = registry.bind(g.name, wl.Subcompositor, g.version) catch null;
            } else if (is(iface, wl.Shm)) {
                self.shm = registry.bind(g.name, wl.Shm, g.version) catch null;
            } else if (is(iface, wl.Seat)) {
                if (self.seat == null) {
                    const seat = registry.bind(g.name, wl.Seat, g.version) catch return;
                    self.seat = seat;
                    seat.setListener(*Client, seatListener, self);
                }
            } else if (is(iface, zxdg.OutputManagerV1)) {
                self.xdg_output_manager = registry.bind(g.name, zxdg.OutputManagerV1, g.version) catch null;
            } else if (is(iface, zwlr.LayerShellV1)) {
                self.layer_shell = registry.bind(g.name, zwlr.LayerShellV1, g.version) catch null;
            } else if (is(iface, zwlr.ScreencopyManagerV1)) {
                self.screencopy = registry.bind(g.name, zwlr.ScreencopyManagerV1, g.version) catch null;
            } else if (is(iface, wp.Viewporter)) {
                self.viewporter = registry.bind(g.name, wp.Viewporter, g.version) catch null;
            } else if (is(iface, wp.CursorShapeManagerV1)) {
                self.cursor_shape = registry.bind(g.name, wp.CursorShapeManagerV1, g.version) catch null;
            } else if (is(iface, wp.FractionalScaleManagerV1)) {
                self.fractional_scale = registry.bind(g.name, wp.FractionalScaleManagerV1, g.version) catch null;
            } else if (is(iface, xdg.WmBase)) {
                const wm = registry.bind(g.name, xdg.WmBase, g.version) catch return;
                self.wm_base = wm;
                wm.setListener(?*anyopaque, wmBaseListener, null);
            } else if (is(iface, wl.Output)) {
                const wl_output = registry.bind(g.name, wl.Output, g.version) catch return;
                const o = self.gpa.create(Output) catch {
                    wl_output.release();
                    return;
                };
                o.* = .{ .client = self, .wl_output = wl_output, .global_name = g.name };
                self.outputs.append(self.gpa, o) catch {
                    wl_output.release();
                    self.gpa.destroy(o);
                    return;
                };
                wl_output.setListener(*Output, outputListener, o);
                if (self.xdg_output_manager) |mgr| self.attachXdgOutput(mgr, o);
            }
        },
        .global_remove => |g| {
            for (self.outputs.items, 0..) |o, i| {
                if (o.global_name == g.name) {
                    _ = self.outputs.orderedRemove(i);
                    o.deinit(self.gpa);
                    break;
                }
            }
        },
    }
}

fn wmBaseListener(wm: *xdg.WmBase, event: xdg.WmBase.Event, _: ?*anyopaque) void {
    switch (event) {
        .ping => |p| wm.pong(p.serial),
    }
}

fn is(iface: []const u8, comptime T: type) bool {
    return std.mem.eql(u8, iface, std.mem.span(T.interface.name));
}

fn seatListener(_: *wl.Seat, event: wl.Seat.Event, self: *Client) void {
    switch (event) {
        .capabilities => |caps| self.seat_caps = caps.capabilities,
        .name => {},
    }
}

fn outputListener(_: *wl.Output, event: wl.Output.Event, o: *Output) void {
    switch (event) {
        .geometry => |g| o.transform = g.transform,
        .mode => |m| if (m.flags.current) {
            o.mode_w = m.width;
            o.mode_h = m.height;
        },
        .scale => |s| o.scale = s.factor,
        .name => |n| {
            if (o.name) |old| o.client.gpa.free(old);
            o.name = o.client.gpa.dupe(u8, std.mem.span(n.name)) catch null;
        },
        .description, .done => {},
    }
}

fn xdgOutputListener(_: *zxdg.OutputV1, event: zxdg.OutputV1.Event, o: *Output) void {
    switch (event) {
        .logical_position => |p| {
            o.logical_x = p.x;
            o.logical_y = p.y;
        },
        .logical_size => |s| {
            o.logical_w = s.width;
            o.logical_h = s.height;
        },
        .name, .description, .done => {},
    }
}
