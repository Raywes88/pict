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
