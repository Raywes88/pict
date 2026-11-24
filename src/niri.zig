//! niri IPC over $NIRI_SOCKET (newline-delimited JSON). Talking to the socket directly
//! avoids spawning `niri msg` for every request.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Ipc = struct {
    io: Io,
    gpa: Allocator,
    socket_path: []const u8,

    pub fn fromEnv(io: Io, gpa: Allocator, env: *const std.process.Environ.Map) ?Ipc {
        const path = env.get("NIRI_SOCKET") orelse return null;
        return .{ .io = io, .gpa = gpa, .socket_path = path };
    }

    /// Send one request (a JSON value, e.g. `"FocusedOutput"`) and return the parsed reply's
    /// `Ok` payload. Caller deinits the returned Parsed.
    pub fn request(self: Ipc, req_json: []const u8) !std.json.Parsed(std.json.Value) {
        const addr = try Io.net.UnixAddress.init(self.socket_path);
        const stream = try addr.connect(self.io);
        defer stream.close(self.io);

        var wbuf: [256]u8 = undefined;
        var w = stream.writer(self.io, &wbuf);
        try w.interface.writeAll(req_json);
        try w.interface.writeAll("\n");
        try w.interface.flush();

        var rbuf: [256 * 1024]u8 = undefined;
        var r = stream.reader(self.io, &rbuf);
        const line = try r.interface.takeDelimiterExclusive('\n');

        const parsed = try std.json.parseFromSlice(std.json.Value, self.gpa, line, .{});
        errdefer parsed.deinit();
        if (parsed.value != .object) return error.NiriBadReply;
        if (parsed.value.object.get("Err")) |e| {
            if (e == .string) std.log.err("niri: {s}", .{e.string});
            return error.NiriError;
        }
        if (parsed.value.object.get("Ok") == null) return error.NiriBadReply;
        return parsed;
    }

    /// Windows on every output's active (visible) workspace. Strings live in `arena`.
    pub fn visibleWindows(self: Ipc, arena: Allocator) !Windows {
        const ws_reply = try self.request("\"Workspaces\"");
        defer ws_reply.deinit();
        const ws_list = try okList(ws_reply.value, "Workspaces");

        const win_reply = try self.request("\"Windows\"");
        defer win_reply.deinit();
        const win_list = try okList(win_reply.value, "Windows");

        var out: std.ArrayList(Window) = .empty;
        var tiled_seen = false;
        var tiled_positioned = false;
        var focused: ?u64 = null;

        for (win_list) |wv| {
            if (wv != .object) continue;
            const w = wv.object;
            const id = int(w.get("id")) orelse continue;
            if (boolean(w.get("is_focused"))) focused = @intCast(id);

            const ws_id = int(w.get("workspace_id")) orelse continue;
            const output = activeWorkspaceOutput(ws_list, ws_id) orelse continue;

            const layout = (w.get("layout") orelse continue);
            if (layout != .object) continue;
            const lo = layout.object;
            const tiled = if (lo.get("pos_in_scrolling_layout")) |p| p != .null else false;
            var rect: ?[4]f64 = null;
            if (pair(lo.get("tile_pos_in_workspace_view"))) |tp| {
                const off = pair(lo.get("window_offset_in_tile")) orelse .{ 0, 0 };
                const size = pair(lo.get("window_size")) orelse continue;
                rect = .{ tp[0] + off[0], tp[1] + off[1], size[0], size[1] };
            }
            if (tiled) {
                tiled_seen = true;
                if (rect != null) tiled_positioned = true;
            }

            try out.append(arena, .{
                .id = @intCast(id),
                .app_id = try arena.dupe(u8, str(w.get("app_id")) orelse ""),
                .title = try arena.dupe(u8, str(w.get("title")) orelse ""),
                .output = try arena.dupe(u8, output),
                .is_focused = boolean(w.get("is_focused")),
                .is_floating = boolean(w.get("is_floating")),
                .focus_ts = focusTs(w.get("focus_timestamp")),
                .rect = rect,
            });
        }
        return .{
            .items = out.items,
            .focused_id = focused,
            // niri 26.04 reports positions only for floating windows.
            .tiled_positions_missing = tiled_seen and !tiled_positioned,
        };
    }

    /// Ask niri to render one window (unoccluded, even partly off-screen) to `path`.
    /// niri writes the file asynchronously and also puts it on the clipboard.
    pub fn screenshotWindow(self: Ipc, id: u64, path: []const u8) !void {
        var buf: [1024]u8 = undefined;
        const req = try std.fmt.bufPrint(&buf, "{{\"Action\":{{\"ScreenshotWindow\":{{\"id\":{d},\"write_to_disk\":true,\"show_pointer\":false,\"path\":{f}}}}}}}", .{ id, std.json.fmt(path, .{}) });
        const reply = try self.request(req);
        reply.deinit();
    }

    /// Name of the focused output (e.g. "DP-2"), or null if niri reports none.
    pub fn focusedOutputName(self: Ipc, out: []u8) !?[]const u8 {
        const parsed = try self.request("\"FocusedOutput\"");
        defer parsed.deinit();
        const ok = parsed.value.object.get("Ok").?;
        if (ok != .object) return error.NiriBadReply;
        const fo = ok.object.get("FocusedOutput") orelse return error.NiriBadReply;
        if (fo != .object) return null; // null when no output is focused
        const name = fo.object.get("name") orelse return error.NiriBadReply;
        if (name != .string or name.string.len > out.len) return error.NiriBadReply;
        @memcpy(out[0..name.string.len], name.string);
        return out[0..name.string.len];
    }
};

pub const Window = struct {
    id: u64,
    app_id: []const u8,
    title: []const u8,
    /// Output name of the (active) workspace the window is on.
    output: []const u8,
    is_focused: bool,
    is_floating: bool,
    /// Seconds; higher = focused more recently. Used to approximate stacking order.
    focus_ts: f64,
    /// Window geometry (excluding niri borders), output-local logical px: x, y, w, h.
    /// Null when niri doesn't report a position (tiled windows on niri 26.04, or off-screen).
    rect: ?[4]f64,
};

pub const Windows = struct {
    items: []Window,
    focused_id: ?u64,
    tiled_positions_missing: bool,
};

fn okList(v: std.json.Value, key: []const u8) ![]std.json.Value {
    const ok = v.object.get("Ok") orelse return error.NiriBadReply;
    if (ok != .object) return error.NiriBadReply;
    const list = ok.object.get(key) orelse return error.NiriBadReply;
    if (list != .array) return error.NiriBadReply;
    return list.array.items;
}

fn activeWorkspaceOutput(workspaces: []const std.json.Value, id: i64) ?[]const u8 {
    for (workspaces) |wv| {
        if (wv != .object) continue;
        const w = wv.object;
        if (int(w.get("id")) != id) continue;
        if (!boolean(w.get("is_active"))) return null;
        return str(w.get("output"));
    }
    return null;
}

fn int(v: ?std.json.Value) ?i64 {
    const x = v orelse return null;
    return switch (x) {
        .integer => |i| i,
        else => null,
    };
}

fn num(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

fn str(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn boolean(v: ?std.json.Value) bool {
    const x = v orelse return false;
    return x == .bool and x.bool;
}

fn pair(v: ?std.json.Value) ?[2]f64 {
    const x = v orelse return null;
    if (x != .array or x.array.items.len != 2) return null;
    return .{ num(x.array.items[0]) orelse return null, num(x.array.items[1]) orelse return null };
}

fn focusTs(v: ?std.json.Value) f64 {
    const x = v orelse return 0;
    if (x != .object) return 0;
    const secs = num(x.object.get("secs") orelse return 0) orelse 0;
    const nanos = num(x.object.get("nanos") orelse return secs) orelse 0;
    return secs + nanos / 1e9;
}
