//! Command-line parsing. Pure (no I/O) so it can be unit-tested.

const std = @import("std");

pub const Mode = enum { region, window, fullscreen, freeform };

pub const Options = struct {
    mode: Mode = .region,
    delay_s: u32 = 0,
    cursor: bool = false,
    /// Copy the result to the clipboard.
    copy: bool = true,
    /// Write the result to disk.
    save: bool = true,
    /// Explicit output path; "-" means stdout. Null means the default directory and template.
    output_path: ?[]const u8 = null,
    /// `--edit <path>`: open an existing image in the editor (Phase 3).
    edit_path: ?[]const u8 = null,
    /// Keep the selection editable after mouse release; Enter confirms.
    adjust: bool = false,
    timings: bool = false,
};

pub const ServeArgs = struct { data_fd: i32, ready_fd: i32 };

pub const Action = union(enum) {
    run: Options,
    help,
    version,
    /// Internal: the forked clipboard owner (`pict __serve-clipboard <data_fd> <ready_fd>`).
    serve_clipboard: ServeArgs,
};

pub const Error = error{ UnknownFlag, MissingValue, InvalidValue, ConflictingFlags };

pub const Diag = struct {
    arg: []const u8 = "",
    msg: []const u8 = "",
};

pub const usage =
    \\Usage: pict [MODE] [OPTIONS]
    \\
    \\Modes (default: --region):
    \\  --region            Drag a rectangle on a frozen screen
    \\  --fullscreen        Capture the focused output
    \\  --window            Capture a window              (Phase 2)
    \\  --freeform          Lasso selection               (Phase 2)
    \\  --edit <path>       Open an image in the editor   (Phase 3)
    \\
    \\Options:
    \\  --delay <seconds>   Wait before capturing
    \\  --cursor            Include the mouse cursor
    \\  --no-cursor         Exclude the mouse cursor (default)
    \\  --copy-only         Copy to the clipboard, don't save a file
    \\  --no-copy           Save a file, don't touch the clipboard
    \\  -o, --output <path> Save to <path> ("-" writes PNG to stdout)
    \\  --adjust            Keep the selection editable after release; Enter confirms
    \\  --timings           Print stage timings to stderr
    \\  -h, --help          Show this help
    \\  -V, --version       Show the version
    \\
    \\Keys in the overlay: Esc or right-click cancels. With --adjust, arrows move the
    \\selection, Shift+arrows resize it, Enter confirms.
    \\
    \\Exit status: 0 captured, 1 cancelled, 2 error.
    \\
;

pub fn parse(args: []const []const u8, diag: *Diag) Error!Action {
    var o: Options = .{};
    var mode_set = false;
    var copy_only = false;
    var no_copy = false;

    if (args.len >= 1 and std.mem.eql(u8, args[0], "__serve-clipboard")) {
        if (args.len != 3) return fail(diag, args[0], "expects <data_fd> <ready_fd>", error.MissingValue);
        const data_fd = std.fmt.parseInt(i32, args[1], 10) catch return fail(diag, args[1], "not an fd", error.InvalidValue);
        const ready_fd = std.fmt.parseInt(i32, args[2], 10) catch return fail(diag, args[2], "not an fd", error.InvalidValue);
        return .{ .serve_clipboard = .{ .data_fd = data_fd, .ready_fd = ready_fd } };
    }

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (eq(a, "-h") or eq(a, "--help")) return .help;
        if (eq(a, "-V") or eq(a, "--version")) return .version;

        if (modeFlag(a)) |m| {
            if (mode_set and o.mode != m) return fail(diag, a, "only one mode may be given", error.ConflictingFlags);
            o.mode = m;
            mode_set = true;
        } else if (eq(a, "--edit")) {
            if (mode_set) return fail(diag, a, "--edit cannot be combined with a capture mode", error.ConflictingFlags);
            o.edit_path = try value(args, &i, diag);
        } else if (eq(a, "--delay")) {
            const v = try value(args, &i, diag);
            o.delay_s = std.fmt.parseInt(u32, v, 10) catch return fail(diag, v, "delay must be a whole number of seconds", error.InvalidValue);
            if (o.delay_s > 600) return fail(diag, v, "delay is capped at 600 seconds", error.InvalidValue);
        } else if (eq(a, "--cursor")) {
            o.cursor = true;
        } else if (eq(a, "--no-cursor")) {
            o.cursor = false;
        } else if (eq(a, "--copy-only")) {
            copy_only = true;
        } else if (eq(a, "--no-copy")) {
            no_copy = true;
        } else if (eq(a, "-o") or eq(a, "--output")) {
            o.output_path = try value(args, &i, diag);
        } else if (eq(a, "--adjust")) {
            o.adjust = true;
        } else if (eq(a, "--timings")) {
            o.timings = true;
        } else {
            return fail(diag, a, "unknown flag", error.UnknownFlag);
        }
    }

    if (o.edit_path != null and mode_set) return fail(diag, "--edit", "--edit cannot be combined with a capture mode", error.ConflictingFlags);
    if (copy_only and no_copy) return fail(diag, "--copy-only", "conflicts with --no-copy", error.ConflictingFlags);
    if (copy_only and o.output_path != null) return fail(diag, "--copy-only", "conflicts with --output", error.ConflictingFlags);
    if (copy_only) o.save = false;
    if (no_copy) o.copy = false;
    return .{ .run = o };
}

fn modeFlag(a: []const u8) ?Mode {
    if (eq(a, "--region")) return .region;
    if (eq(a, "--window")) return .window;
    if (eq(a, "--fullscreen")) return .fullscreen;
    if (eq(a, "--freeform")) return .freeform;
    return null;
}

fn value(args: []const []const u8, i: *usize, diag: *Diag) Error![]const u8 {
    if (i.* + 1 >= args.len) return fail(diag, args[i.*], "needs a value", error.MissingValue);
    i.* += 1;
    return args[i.*];
}

fn fail(diag: *Diag, arg: []const u8, msg: []const u8, err: Error) Error {
    diag.* = .{ .arg = arg, .msg = msg };
    return err;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---- tests ----

fn parseOk(args: []const []const u8) !Options {
    var d: Diag = .{};
    return switch (try parse(args, &d)) {
        .run => |o| o,
        else => error.TestUnexpectedResult,
    };
}

test "defaults to region, save and copy" {
    const o = try parseOk(&.{});
    try std.testing.expectEqual(Mode.region, o.mode);
    try std.testing.expect(o.save and o.copy and !o.cursor);
}

test "copy-only disables save" {
    const o = try parseOk(&.{ "--fullscreen", "--copy-only", "--cursor", "--delay", "3" });
    try std.testing.expectEqual(Mode.fullscreen, o.mode);
    try std.testing.expect(!o.save and o.copy and o.cursor);
    try std.testing.expectEqual(@as(u32, 3), o.delay_s);
}

test "rejects conflicting modes and bad values" {
    var d: Diag = .{};
    try std.testing.expectError(error.ConflictingFlags, parse(&.{ "--region", "--window" }, &d));
    try std.testing.expectError(error.InvalidValue, parse(&.{ "--delay", "abc" }, &d));
    try std.testing.expectError(error.MissingValue, parse(&.{"--delay"}, &d));
    try std.testing.expectError(error.UnknownFlag, parse(&.{"--bogus"}, &d));
    try std.testing.expectError(error.ConflictingFlags, parse(&.{ "--copy-only", "--no-copy" }, &d));
}

test "serve-clipboard internal command" {
    var d: Diag = .{};
    const a = try parse(&.{ "__serve-clipboard", "5", "7" }, &d);
    try std.testing.expectEqual(@as(i32, 5), a.serve_clipboard.data_fd);
    try std.testing.expectEqual(@as(i32, 7), a.serve_clipboard.ready_fd);
}
