const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const cli = @import("cli.zig");
const Client = @import("wl/Client.zig");
const screencopy = @import("capture/screencopy.zig");
const Image = @import("image/Image.zig");
const png = @import("image/png.zig");
const clipboard = @import("clipboard.zig");
const niri = @import("niri.zig");
const save = @import("save.zig");
const Overlay = @import("overlay/Overlay.zig");

pub const version = "0.1.0";

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 2;
    var diag: cli.Diag = .{};
    const action = cli.parse(if (args.len > 0) args[1..] else args, &diag) catch {
        std.debug.print("pict: {s}: {s}\n\n{s}", .{ diag.arg, diag.msg, cli.usage });
        return 2;
    };
    switch (action) {
        .help => {
            writeStdout(init.io, cli.usage) catch {};
            return 0;
        },
        .version => {
            writeStdout(init.io, "pict " ++ version ++ "\n") catch {};
            return 0;
        },
        .serve_clipboard => |s| return clipboard.serve(s.data_fd, s.ready_fd),
        .run => |o| return run(init, o) catch |err| {
            std.debug.print("pict: {s}\n", .{describe(err)});
            return 2;
        },
    }
}

const Outcome = enum(u8) { captured = 0, cancelled = 1 };

fn run(init: std.process.Init, o: cli.Options) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    if (o.edit_path != null) return error.EditorNotImplemented;
    switch (o.mode) {
        .window, .freeform => return error.ModeNotImplemented,
        .region, .fullscreen => {},
    }

    var t = Timings.init(io, o.timings);
    if (o.delay_s > 0) try io.sleep(.fromSeconds(o.delay_s), .awake);

    const client = try Client.connect(gpa);
    defer client.deinit();
    if (client.outputs.items.len == 0) return error.NoOutputs;
    t.mark("connect");

    var result: Image = undefined;
    switch (o.mode) {
        .fullscreen => {
            const target = focusedOutput(init, client);
            const frames = try screencopy.capture(client, &.{target}, o.cursor);
            defer screencopy.freeFrames(gpa, frames);
            t.mark("capture");
            result = try frames[0].image().crop(gpa, frames[0].image().bounds());
        },
        .region => {
            const frames = try screencopy.capture(client, client.outputs.items, o.cursor);
            defer screencopy.freeFrames(gpa, frames);
            t.mark("capture");
            const auto = testAutoselect(init.environ_map, frames);
            const sel = try Overlay.select(client, frames, .{ .adjust = o.adjust, .timings = &t, .autoselect = auto });
            t.mark("select");
            const s = sel orelse return @backingInt(Outcome.cancelled);
            result = try frames[s.frame].image().crop(gpa, s.rect);
        },
        .window, .freeform => unreachable,
    }
    defer result.deinit(gpa);

    const bytes = try png.encode(gpa, result);
    defer gpa.free(bytes);
    t.mark("encode");

    if (o.save) {
        if (o.output_path) |p| {
            if (std.mem.eql(u8, p, "-")) {
                try Io.File.stdout().writeStreamingAll(io, bytes);
            } else {
                const path = try save.saveTo(io, gpa, p, bytes);
                defer gpa.free(path);
                try printStdout(io, "{s}\n", .{path});
            }
        } else {
            const home = init.environ_map.get("HOME") orelse return error.NoHome;
            const path = try save.saveDefault(io, gpa, home, bytes, "png");
            defer gpa.free(path);
            try printStdout(io, "{s}\n", .{path});
        }
        t.mark("save");
    }

    if (o.copy) {
        try clipboard.copyPng(bytes, init.environ_map.get("PICT_DEBUG") != null);
        t.mark("clipboard");
    }

    t.report(result.width, result.height, bytes.len);
    return @backingInt(Outcome.captured);
}

fn focusedOutput(init: std.process.Init, client: *Client) *Client.Output {
    if (niri.Ipc.fromEnv(init.io, init.gpa, init.environ_map)) |ipc| {
        var buf: [128]u8 = undefined;
        if (ipc.focusedOutputName(&buf)) |maybe| {
            if (maybe) |name| if (client.findOutput(name)) |out| return out;
        } else |err| std.log.warn("niri IPC failed ({t}); using the first output", .{err});
    }
    return client.outputs.items[0];
}

/// PICT_TEST_AUTOSELECT="OUTPUT:x,y,w,h" (physical px on that output) drives the overlay
/// without input, for automated smoke tests.
fn testAutoselect(env: *const std.process.Environ.Map, frames: []const screencopy.Frame) ?Overlay.Result {
    const spec = env.get("PICT_TEST_AUTOSELECT") orelse return null;
    const colon = std.mem.indexOfScalar(u8, spec, ':') orelse return null;
    const name = spec[0..colon];
    var it = std.mem.splitScalar(u8, spec[colon + 1 ..], ',');
    var v: [4]i32 = undefined;
    for (&v) |*x| x.* = std.fmt.parseInt(i32, it.next() orelse return null, 10) catch return null;
    for (frames, 0..) |f, i| {
        if (f.output.name) |n| if (std.mem.eql(u8, n, name)) {
            return .{ .frame = i, .rect = .{ .x = v[0], .y = v[1], .w = v[2], .h = v[3] } };
        };
    }
    return null;
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.NoWaylandDisplay => "cannot connect to a Wayland display (is WAYLAND_DISPLAY set?)",
        error.NoScreencopy => "compositor offers no capture protocol (need zwlr_screencopy_manager_v1)",
        error.NoLayerShell => "compositor offers no zwlr_layer_shell_v1; the overlay needs it",
        error.NoSeat => "no input seat; the overlay needs a pointer",
        error.CaptureFailed => "screen capture failed",
        error.UnsupportedFormat => "compositor offered an unsupported pixel format",
        error.NoOutputs => "no outputs found",
        error.NoHome => "HOME is not set",
        error.ModeNotImplemented => "--window and --freeform arrive in Phase 2",
        error.EditorNotImplemented => "--edit arrives in Phase 3 (the editor)",
        error.WlCopyFailed => "clipboard: no data-control protocol and wl-copy failed",
        else => @errorName(err),
    };
}

fn writeStdout(io: Io, s: []const u8) !void {
    try Io.File.stdout().writeStreamingAll(io, s);
}

fn printStdout(io: Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w = Io.File.stdout().writer(io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

pub const Timings = struct {
    io: Io,
    enabled: bool,
    start: Io.Timestamp,
    last: Io.Timestamp,
    marks: [12]Mark = undefined,
    n: usize = 0,

    const Mark = struct { name: []const u8, ns: i96 };

    pub fn init(io: Io, enabled: bool) Timings {
        const now = Io.Timestamp.now(io, .awake);
        return .{ .io = io, .enabled = enabled, .start = now, .last = now };
    }

    pub fn mark(t: *Timings, name: []const u8) void {
        if (!t.enabled or t.n == t.marks.len) return;
        const now = Io.Timestamp.now(t.io, .awake);
        t.marks[t.n] = .{ .name = name, .ns = t.last.durationTo(now).toNanoseconds() };
        t.n += 1;
        t.last = now;
    }

    fn report(t: *Timings, w: u32, h: u32, png_len: usize) void {
        if (!t.enabled) return;
        std.debug.print("pict timings ({d}x{d}, {d} KiB PNG):\n", .{ w, h, png_len / 1024 });
        for (t.marks[0..t.n]) |m| std.debug.print("  {s:<10} {d:>8.2} ms\n", .{ m.name, ms(m.ns) });
        std.debug.print("  {s:<10} {d:>8.2} ms\n", .{ "total", ms(t.start.durationTo(t.last).toNanoseconds()) });
    }

    fn ms(ns: i96) f64 {
        return @as(f64, @floatFromInt(ns)) / 1e6;
    }
};

test {
    _ = @import("geom.zig");
    _ = cli;
    _ = Image;
    _ = png;
    _ = save;
    _ = @import("overlay/selection.zig");
}
