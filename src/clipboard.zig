//! Clipboard that outlives pict.
//!
//! Wayland clipboard data is served on demand by its owner, so the owner has to stay
//! alive after pict exits. `copyPng` double-forks and re-execs pict as
//! `pict __serve-clipboard <data_fd> <ready_fd>`. That process takes the selection with
//! ext-data-control (falling back to wlr-data-control), signals readiness over a pipe,
//! serves `image/png` until someone else takes the clipboard, then exits. No daemon.
//! If neither protocol is available, falls back to `wl-copy`.

const std = @import("std");
const posix = std.posix;
const Allocator = std.mem.Allocator;
const c = @import("c");
const wayland = @import("wayland");
const wl = wayland.client.wl;
const ext = wayland.client.ext;
const zwlr = wayland.client.zwlr;

pub const mime = "image/png";

pub fn copyPng(bytes: []const u8, keep_stderr: bool) !void {
    const data_fd = try posix.memfd_create("pict-clipboard", 0); // inherited across exec
    defer _ = c.close(data_fd);
    try writeAll(data_fd, bytes);

    if (spawnServer(data_fd, keep_stderr)) return else |err| {
        std.log.debug("clipboard server unavailable ({t}); falling back to wl-copy", .{err});
    }
    try wlCopy(data_fd);
}

fn spawnServer(data_fd: c_int, keep_stderr: bool) !void {
    var pipe_fds: [2]c_int = undefined;
    if (c.pipe2(&pipe_fds, c.O_CLOEXEC) != 0) return error.PipeFailed;
    const ready_r = pipe_fds[0];
    const ready_w = pipe_fds[1];
    defer _ = c.close(ready_r);

    // Everything the child needs is prepared before fork.
    var data_buf: [16]u8 = undefined;
    var ready_buf: [16]u8 = undefined;
    const data_arg = try std.fmt.bufPrintSentinel(&data_buf, "{d}", .{data_fd}, 0);
    const ready_arg = try std.fmt.bufPrintSentinel(&ready_buf, "{d}", .{ready_w}, 0);
    const argv = [_:null]?[*:0]const u8{ "pict", "__serve-clipboard", data_arg.ptr, ready_arg.ptr };

    const pid = c.fork();
    if (pid < 0) {
        _ = c.close(ready_w);
        return error.ForkFailed;
    }
    if (pid == 0) {
        // Child: new session, then fork again so the server is reparented and never a zombie.
        _ = c.setsid();
        const pid2 = c.fork();
        if (pid2 == 0) {
            _ = c.fcntl(ready_w, c.F_SETFD, @as(c_int, 0)); // keep the write end across exec
            redirectStdio(keep_stderr);
            _ = c.execv("/proc/self/exe", @ptrCast(&argv));
            c._exit(127);
        }
        c._exit(if (pid2 < 0) 1 else 0);
    }
    _ = c.close(ready_w);
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);

    var pfd = [_]posix.pollfd{.{ .fd = ready_r, .events = posix.POLL.IN, .revents = 0 }};
    const n = posix.poll(&pfd, 2000) catch return error.ServerNotReady;
    if (n == 0) return error.ServerTimedOut;
    var b: [1]u8 = undefined;
    const got = posix.read(ready_r, &b) catch return error.ServerNotReady;
    if (got != 1 or b[0] != 'k') return error.ServerNotReady;
}

fn wlCopy(data_fd: c_int) !void {
    if (c.lseek(data_fd, 0, c.SEEK_SET) != 0) return error.SeekFailed;
    const argv = [_:null]?[*:0]const u8{ "wl-copy", "--type", mime };
    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        _ = c.dup2(data_fd, 0);
        _ = c.execvp("wl-copy", @ptrCast(&argv));
        c._exit(127);
    }
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
    // wl-copy forks itself into the background; the foreground process exits 0 on success.
    if (!(c.WIFEXITED(status) and c.WEXITSTATUS(status) == 0)) return error.WlCopyFailed;
}

fn redirectStdio(keep_stderr: bool) void {
    const devnull = c.open("/dev/null", c.O_RDWR);
    if (devnull < 0) return;
    _ = c.dup2(devnull, 0);
    _ = c.dup2(devnull, 1);
    if (!keep_stderr) _ = c.dup2(devnull, 2);
    if (devnull > 2) _ = c.close(devnull);
}

fn writeAll(fd: c_int, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (n < 0) {
            if (std.c._errno().* == @backingInt(posix.E.INTR)) continue;
            if (std.c._errno().* == @backingInt(posix.E.AGAIN)) {
                var pfd = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
                _ = posix.poll(&pfd, 5000) catch return error.WriteFailed;
                continue;
            }
            return error.WriteFailed;
        }
        off += @intCast(n);
    }
}

// ---------------------------------------------------------------------------
// Server side (runs in the re-exec'd child)

const Globals = struct {
    seat: ?*wl.Seat = null,
    ext_mgr: ?*ext.DataControlManagerV1 = null,
    wlr_mgr: ?*zwlr.DataControlManagerV1 = null,
};

/// Entry point for `pict __serve-clipboard`. Returns the process exit code.
pub fn serve(data_fd: i32, ready_fd: i32) u8 {
    _ = c.signal(c.SIGPIPE, sigIgn());

    const size_off = c.lseek(data_fd, 0, c.SEEK_END);
    if (size_off <= 0) return 2;
    const size: usize = @intCast(size_off);
    const data = posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, data_fd, 0) catch return 2;
    _ = c.close(data_fd);

    const display = wl.Display.connect(null) catch return 2;
    defer display.disconnect();
    const registry = display.getRegistry() catch return 2;
    var g: Globals = .{};
    registry.setListener(*Globals, registryListener, &g);
    if (display.roundtrip() != .SUCCESS) return 2;
    const seat = g.seat orelse return 2;

    if (g.ext_mgr) |m| return run(ext, m, seat, display, data, ready_fd);
    if (g.wlr_mgr) |m| return run(zwlr, m, seat, display, data, ready_fd);
    return 3; // parent falls back to wl-copy
}

fn sigIgn() c.__sighandler_t {
    return @ptrFromInt(1); // SIG_IGN
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, g: *Globals) void {
    switch (event) {
        .global => |gl| {
            const iface = std.mem.span(gl.interface);
            if (std.mem.eql(u8, iface, std.mem.span(wl.Seat.interface.name)) and g.seat == null) {
                g.seat = registry.bind(gl.name, wl.Seat, gl.version) catch null;
            } else if (std.mem.eql(u8, iface, std.mem.span(ext.DataControlManagerV1.interface.name))) {
                g.ext_mgr = registry.bind(gl.name, ext.DataControlManagerV1, gl.version) catch null;
            } else if (std.mem.eql(u8, iface, std.mem.span(zwlr.DataControlManagerV1.interface.name))) {
                g.wlr_mgr = registry.bind(gl.name, zwlr.DataControlManagerV1, gl.version) catch null;
            }
        },
        .global_remove => {},
    }
}

fn ServeState(comptime ns: type) type {
    return struct {
        data: []const u8,
        done: bool = false,

        fn sourceListener(_: *ns.DataControlSourceV1, event: ns.DataControlSourceV1.Event, s: *@This()) void {
            switch (event) {
                .send => |req| {
                    if (std.mem.eql(u8, std.mem.span(req.mime_type), mime)) writeAll(req.fd, s.data) catch {};
                    _ = c.close(req.fd);
                },
                .cancelled => s.done = true,
            }
        }

        fn deviceListener(_: *ns.DataControlDeviceV1, event: ns.DataControlDeviceV1.Event, s: *@This()) void {
            switch (event) {
                .data_offer => |o| o.id.destroy(),
                .finished => s.done = true,
                .selection, .primary_selection => {},
            }
        }
    };
}

fn run(comptime ns: type, mgr: *ns.DataControlManagerV1, seat: *wl.Seat, display: *wl.Display, data: []const u8, ready_fd: i32) u8 {
    const State = ServeState(ns);
    var state: State = .{ .data = data };

    const source = mgr.createDataSource() catch return 2;
    source.setListener(*State, State.sourceListener, &state);
    source.offer(mime);
    const device = mgr.getDataDevice(seat) catch return 2;
    device.setListener(*State, State.deviceListener, &state);
    device.setSelection(source);
    if (display.roundtrip() != .SUCCESS) return 2;

    _ = c.write(ready_fd, "k", 1);
    _ = c.close(ready_fd);

    while (!state.done) {
        if (display.dispatch() != .SUCCESS) break;
    }
    return 0;
}
