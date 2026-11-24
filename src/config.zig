//! ~/.config/pict/config.toml: defaults that command-line flags override.
//!
//! The parser handles the TOML subset pict needs: tables (`[a]`, `[a.b]`), bare or quoted
//! keys, basic and literal strings, integers, floats, booleans and (multi-line) arrays.
//! A bad line is reported with its number and skipped; the rest still applies, and a
//! broken config never stops a capture.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Mode = @import("cli.zig").Mode;
const Format = @import("image/codec.zig").Format;
const Tool = @import("editor/toolbar.zig").Tool;
const Color = @import("editor/doc.zig").Color;

pub const tool_count = @typeInfo(Tool).@"enum".field_names.len;

pub const Config = struct {
    // [capture]
    mode: Mode = .region,
    cursor: bool = false,
    delay: u32 = 0,
    // [output]
    dir: []const u8 = "~/Pictures/Screenshots",
    filename: [:0]const u8 = "Screenshot_%Y-%m-%d_%H-%M-%S",
    format: Format = .png,
    jpeg_quality: u8 = 92,
    save: bool = true,
    copy: bool = true,
    // [editor]
    editor: bool = true,
    auto_copy: bool = true,
    confirm_close: bool = true,
    tool: Tool = .pen,
    font: [:0]const u8 = "Sans Bold",
    palette: [8]Color = default_palette,
    highlighter_color: Color = hex("#fdd835"),
    sizes: [tool_count]f32 = default_sizes,
    // [ocr]
    ocr_language: [:0]const u8 = "eng",
    ocr_notify: bool = true,

    /// `dir` with a leading "~/" expanded. Owned by `gpa`.
    pub fn saveDir(cfg: Config, gpa: Allocator, home: ?[]const u8) ![]u8 {
        if (std.mem.eql(u8, cfg.dir, "~") or std.mem.startsWith(u8, cfg.dir, "~/")) {
            const h = home orelse return error.NoHome;
            return std.fmt.allocPrint(gpa, "{s}{s}", .{ h, cfg.dir[1..] });
        }
        return gpa.dupe(u8, cfg.dir);
    }
};

pub const default_palette = [8]Color{
    hex("#e53935"), hex("#fb8c00"), hex("#fdd835"), hex("#43a047"),
    hex("#1e88e5"), hex("#8e24aa"), hex("#111111"), hex("#ffffff"),
};

pub const default_sizes = blk: {
    var s: [tool_count]f32 = @splat(0);
    s[@backingInt(Tool.pen)] = 4;
    s[@backingInt(Tool.highlighter)] = 20;
    s[@backingInt(Tool.eraser)] = 16;
    s[@backingInt(Tool.line)] = 4;
    s[@backingInt(Tool.arrow)] = 4;
    s[@backingInt(Tool.rect)] = 4;
    s[@backingInt(Tool.ellipse)] = 4;
    s[@backingInt(Tool.text)] = 28;
    s[@backingInt(Tool.blur)] = 12;
    s[@backingInt(Tool.pixelate)] = 14;
    break :blk s;
};

/// The documented default file, printed by `pict --print-config`. A unit test checks
/// that it parses to exactly the built-in defaults.
pub const default_text =
    \\# pict configuration: ~/.config/pict/config.toml
    \\# Every key is optional; the values below are the defaults. Command-line flags win.
    \\
    \\[capture]
    \\# Mode when no mode flag is given: "region", "freeform", "window" or "fullscreen".
    \\mode = "region"
    \\# Include the mouse pointer.
    \\cursor = false
    \\# Seconds to wait before capturing.
    \\delay = 0
    \\
    \\[output]
    \\# Where captures are saved. A leading "~/" is your home directory.
    \\dir = "~/Pictures/Screenshots"
    \\# File name without the extension, in strftime(3) format.
    \\filename = "Screenshot_%Y-%m-%d_%H-%M-%S"
    \\# "png", "jpg" or "webp" (lossless). The clipboard always gets PNG.
    \\format = "png"
    \\# JPEG quality, 1-100.
    \\jpeg_quality = 92
    \\# Save a file after each capture.
    \\save = true
    \\# Copy each capture to the clipboard.
    \\copy = true
    \\
    \\[editor]
    \\# Open the editor after a capture.
    \\open = true
    \\# Re-copy to the clipboard after every edit.
    \\auto_copy = true
    \\# Ask for a second Esc before closing with unsaved changes.
    \\confirm_close = true
    \\# Tool selected when the editor opens.
    \\tool = "pen"
    \\# Font for the text tool (any fontconfig name).
    \\font = "Sans Bold"
    \\# Colours on keys 1-8.
    \\palette = [
    \\    "#e53935", "#fb8c00", "#fdd835", "#43a047",
    \\    "#1e88e5", "#8e24aa", "#111111", "#ffffff",
    \\]
    \\# The highlighter keeps its own colour.
    \\highlighter_color = "#fdd835"
    \\
    \\[editor.sizes]
    \\# Starting sizes in image pixels (text: font size, blur: radius, pixelate: block).
    \\pen = 4
    \\highlighter = 20
    \\eraser = 16
    \\line = 4
    \\arrow = 4
    \\rect = 4
    \\ellipse = 4
    \\text = 28
    \\blur = 12
    \\pixelate = 14
    \\
    \\[ocr]
    \\# Tesseract language(s), e.g. "eng" or "eng+deu" (needs tesseract-data-<lang>).
    \\language = "eng"
    \\# Show a desktop notification after `pict --ocr`.
    \\notify = true
    \\
;

/// "#rrggbb" → Color. Usable at comptime.
pub fn hex(comptime s: []const u8) Color {
    @setEvalBranchQuota(10_000);
    return comptime parseHex(s) orelse @compileError("bad colour " ++ s);
}

pub fn parseHex(s: []const u8) ?Color {
    if (s.len != 7 or s[0] != '#') return null;
    var v: [3]f32 = undefined;
    for (0..3) |i| {
        const b = std.fmt.parseInt(u8, s[1 + i * 2 ..][0..2], 16) catch return null;
        v[i] = @as(f32, @floatFromInt(b)) / 255;
    }
    return .{ .r = v[0], .g = v[1], .b = v[2] };
}

// ---------------------------------------------------------------------------
// Loading

pub const Loaded = struct {
    config: Config,
    /// Where it came from, or null when no file exists.
    path: ?[]const u8,
};

/// $XDG_CONFIG_HOME/pict/config.toml, else ~/.config/pict/config.toml. Strings live in
/// `arena`. Problems are printed to stderr and skipped.
pub fn load(io: Io, arena: Allocator, env: *const std.process.Environ.Map) Loaded {
    const path = configPath(arena, env) orelse return .{ .config = .{}, .path = null };
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => return .{ .config = .{}, .path = null },
        else => {
            std.debug.print("pict: {s}: {t}; using defaults\n", .{ path, err });
            return .{ .config = .{}, .path = null };
        },
    };
    var diags: std.ArrayList(Diag) = .empty;
    const cfg = fromText(arena, text, &diags);
    for (diags.items) |d| std.debug.print("pict: {s}:{d}: {s}\n", .{ path, d.line, d.msg });
    return .{ .config = cfg, .path = path };
}

pub fn configPath(arena: Allocator, env: *const std.process.Environ.Map) ?[]const u8 {
    if (env.get("XDG_CONFIG_HOME")) |x| if (x.len > 0) {
        return std.fmt.allocPrint(arena, "{s}/pict/config.toml", .{x}) catch null;
    };
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(arena, "{s}/.config/pict/config.toml", .{home}) catch null;
}

pub const Diag = struct { line: u32, msg: []const u8 };

/// Parse `text` and apply it over the defaults. Problems are appended to `diags`.
pub fn fromText(arena: Allocator, text: []const u8, diags: *std.ArrayList(Diag)) Config {
    var cfg: Config = .{};
    var p: Parser = .{ .arena = arena, .src = text, .diags = diags };
    p.run(&cfg);
    return cfg;
}

// ---------------------------------------------------------------------------
// TOML subset

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    array: []const Value,
};

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    i: usize = 0,
    line: u32 = 1,
    table: []const u8 = "",
    diags: *std.ArrayList(Diag),

    const Error = error{ Syntax, OutOfMemory };

    fn run(p: *Parser, cfg: *Config) void {
        while (p.i < p.src.len) {
            p.skipSpace();
            if (p.i >= p.src.len) break;
            const ch = p.src[p.i];
            if (ch == '\n' or ch == '\r') {
                p.newline();
                continue;
            }
            if (ch == '#') {
                p.skipLine();
                continue;
            }
            const start_line = p.line;
            const ok = if (ch == '[') p.header() else p.keyval(cfg);
            ok catch |err| {
                if (err == error.OutOfMemory) return;
                p.skipLine();
                continue;
            };
            // Only a comment may follow on the same line.
            p.skipSpace();
            if (p.i < p.src.len and p.src[p.i] != '\n' and p.src[p.i] != '\r' and p.src[p.i] != '#') {
                p.diag(start_line, "unexpected text after the value");
                p.skipLine();
            }
        }
    }

    fn diag(p: *Parser, line: u32, msg: []const u8) void {
        p.diags.append(p.arena, .{ .line = line, .msg = msg }) catch {};
    }

    fn diagf(p: *Parser, line: u32, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(p.arena, fmt, args) catch return;
        p.diag(line, msg);
    }

    fn fail(p: *Parser, msg: []const u8) Error {
        p.diag(p.line, msg);
        return error.Syntax;
    }

    fn skipSpace(p: *Parser) void {
        while (p.i < p.src.len and (p.src[p.i] == ' ' or p.src[p.i] == '\t')) p.i += 1;
    }

    fn newline(p: *Parser) void {
        if (p.src[p.i] == '\r') p.i += 1;
        if (p.i < p.src.len and p.src[p.i] == '\n') p.i += 1;
        p.line += 1;
    }

    fn skipLine(p: *Parser) void {
        while (p.i < p.src.len and p.src[p.i] != '\n') p.i += 1;
    }

    /// Whitespace, newlines and comments (inside arrays).
    fn skipAll(p: *Parser) void {
        while (p.i < p.src.len) {
            const ch = p.src[p.i];
            if (ch == ' ' or ch == '\t') {
                p.i += 1;
            } else if (ch == '\n' or ch == '\r') {
                p.newline();
            } else if (ch == '#') {
                p.skipLine();
            } else break;
        }
    }

    fn header(p: *Parser) Error!void {
        p.i += 1;
        if (p.i < p.src.len and p.src[p.i] == '[') return p.fail("arrays of tables are not supported");
        var name: std.ArrayList(u8) = .empty;
        while (true) {
            p.skipSpace();
            const k = try p.key();
            try name.appendSlice(p.arena, k);
            p.skipSpace();
            if (p.i >= p.src.len) return p.fail("unterminated table header");
            if (p.src[p.i] == '.') {
                try name.append(p.arena, '.');
                p.i += 1;
                continue;
            }
            if (p.src[p.i] == ']') {
                p.i += 1;
                break;
            }
            return p.fail("expected ']' or '.' in table header");
        }
        p.table = name.items;
    }

    fn key(p: *Parser) Error![]const u8 {
        if (p.i < p.src.len and (p.src[p.i] == '"' or p.src[p.i] == '\'')) return p.string();
        const start = p.i;
        while (p.i < p.src.len) {
            const ch = p.src[p.i];
            if (std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-') p.i += 1 else break;
        }
        if (p.i == start) return p.fail("expected a key");
        return p.src[start..p.i];
    }

    fn keyval(p: *Parser, cfg: *Config) Error!void {
        const line = p.line;
        const k = try p.key();
        p.skipSpace();
        if (p.i >= p.src.len or p.src[p.i] != '=') return p.fail("expected '=' after the key");
        p.i += 1;
        p.skipSpace();
        const v = try p.value();
        p.apply(cfg, line, k, v);
    }

    fn value(p: *Parser) Error!Value {
        if (p.i >= p.src.len) return p.fail("expected a value");
        const ch = p.src[p.i];
        if (ch == '"' or ch == '\'') return .{ .string = try p.string() };
        if (ch == '[') return p.array();
        if (std.mem.startsWith(u8, p.src[p.i..], "true")) {
            p.i += 4;
            return .{ .boolean = true };
        }
        if (std.mem.startsWith(u8, p.src[p.i..], "false")) {
            p.i += 5;
            return .{ .boolean = false };
        }
        return p.number();
    }

    fn number(p: *Parser) Error!Value {
        const start = p.i;
        var is_float = false;
        while (p.i < p.src.len) {
            const ch = p.src[p.i];
            if (std.ascii.isDigit(ch) or ch == '_' or ch == '+' or ch == '-') {
                p.i += 1;
            } else if (ch == '.' or ch == 'e' or ch == 'E') {
                is_float = true;
                p.i += 1;
            } else break;
        }
        if (p.i == start) return p.fail("expected a value");
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        for (p.src[start..p.i]) |ch| {
            if (ch == '_') continue;
            if (n == buf.len) return p.fail("number too long");
            buf[n] = ch;
            n += 1;
        }
        if (is_float) {
            const f = std.fmt.parseFloat(f64, buf[0..n]) catch return p.fail("bad number");
            return .{ .float = f };
        }
        const v = std.fmt.parseInt(i64, buf[0..n], 10) catch return p.fail("bad number");
        return .{ .int = v };
    }

    fn string(p: *Parser) Error![]const u8 {
        const q = p.src[p.i];
        p.i += 1;
        if (q == '\'') {
            const start = p.i;
            while (p.i < p.src.len and p.src[p.i] != '\'' and p.src[p.i] != '\n') p.i += 1;
            if (p.i >= p.src.len or p.src[p.i] != '\'') return p.fail("unterminated string");
            p.i += 1;
            return p.src[start .. p.i - 1];
        }
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            if (p.i >= p.src.len or p.src[p.i] == '\n') return p.fail("unterminated string");
            const ch = p.src[p.i];
            p.i += 1;
            if (ch == '"') break;
            if (ch != '\\') {
                try out.append(p.arena, ch);
                continue;
            }
            if (p.i >= p.src.len) return p.fail("unterminated string");
            const e = p.src[p.i];
            p.i += 1;
            switch (e) {
                'n' => try out.append(p.arena, '\n'),
                't' => try out.append(p.arena, '\t'),
                'r' => try out.append(p.arena, '\r'),
                '"' => try out.append(p.arena, '"'),
                '\\' => try out.append(p.arena, '\\'),
                'u', 'U' => {
                    const len: usize = if (e == 'u') 4 else 8;
                    if (p.i + len > p.src.len) return p.fail("bad \\u escape");
                    const cp = std.fmt.parseInt(u21, p.src[p.i .. p.i + len], 16) catch return p.fail("bad \\u escape");
                    p.i += len;
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &enc) catch return p.fail("bad \\u escape");
                    try out.appendSlice(p.arena, enc[0..n]);
                },
                else => return p.fail("unknown escape in string"),
            }
        }
        return out.items;
    }

    fn array(p: *Parser) Error!Value {
        p.i += 1;
        var items: std.ArrayList(Value) = .empty;
        while (true) {
            p.skipAll();
            if (p.i >= p.src.len) return p.fail("unterminated array");
            if (p.src[p.i] == ']') {
                p.i += 1;
                break;
            }
            try items.append(p.arena, try p.value());
            p.skipAll();
            if (p.i < p.src.len and p.src[p.i] == ',') {
                p.i += 1;
                continue;
            }
            p.skipAll();
            if (p.i < p.src.len and p.src[p.i] == ']') {
                p.i += 1;
                break;
            }
            return p.fail("expected ',' or ']' in array");
        }
        return .{ .array = items.items };
    }

    // ---- mapping onto Config ----

    fn apply(p: *Parser, cfg: *Config, line: u32, k: []const u8, v: Value) void {
        const t = p.table;
        if (eq(t, "capture")) {
            if (eq(k, "mode")) return p.setEnum(Mode, &cfg.mode, line, k, v);
            if (eq(k, "cursor")) return p.setBool(&cfg.cursor, line, k, v);
            if (eq(k, "delay")) return p.setInt(u32, &cfg.delay, 0, 600, line, k, v);
        } else if (eq(t, "output")) {
            if (eq(k, "dir")) return p.setStr(&cfg.dir, line, k, v);
            if (eq(k, "filename")) {
                const s = p.str(line, k, v) orelse return;
                if (s.len == 0 or std.mem.indexOfScalar(u8, s, '/') != null)
                    return p.diag(line, "filename must be non-empty and contain no '/'");
                cfg.filename = p.arena.dupeSentinel(u8, s, 0) catch return;
                return;
            }
            if (eq(k, "format")) {
                const s = p.str(line, k, v) orelse return;
                cfg.format = Format.fromPath(std.fmt.allocPrint(p.arena, "x.{s}", .{s}) catch return) orelse
                    return p.diagf(line, "format must be \"png\", \"jpg\" or \"webp\", not \"{s}\"", .{s});
                return;
            }
            if (eq(k, "jpeg_quality")) return p.setInt(u8, &cfg.jpeg_quality, 1, 100, line, k, v);
            if (eq(k, "save")) return p.setBool(&cfg.save, line, k, v);
            if (eq(k, "copy")) return p.setBool(&cfg.copy, line, k, v);
        } else if (eq(t, "editor")) {
            if (eq(k, "open")) return p.setBool(&cfg.editor, line, k, v);
            if (eq(k, "auto_copy")) return p.setBool(&cfg.auto_copy, line, k, v);
            if (eq(k, "confirm_close")) return p.setBool(&cfg.confirm_close, line, k, v);
            if (eq(k, "tool")) {
                var tool = cfg.tool;
                p.setEnum(Tool, &tool, line, k, v);
                if (tool == .crop or tool == .picker) return p.diag(line, "tool can't be crop or picker");
                cfg.tool = tool;
                return;
            }
            if (eq(k, "font")) {
                const s = p.str(line, k, v) orelse return;
                cfg.font = p.arena.dupeSentinel(u8, s, 0) catch return;
                return;
            }
            if (eq(k, "highlighter_color")) return p.setColor(&cfg.highlighter_color, line, v);
            if (eq(k, "palette")) {
                const arr = switch (v) {
                    .array => |a| a,
                    else => return p.diag(line, "palette must be an array of 8 \"#rrggbb\" colours"),
                };
                if (arr.len != 8) return p.diag(line, "palette must have exactly 8 colours");
                var pal: [8]Color = undefined;
                for (arr, 0..) |item, i| {
                    const s = switch (item) {
                        .string => |s| s,
                        else => return p.diag(line, "palette entries must be \"#rrggbb\" strings"),
                    };
                    pal[i] = parseHex(s) orelse return p.diagf(line, "bad colour \"{s}\" (want \"#rrggbb\")", .{s});
                }
                cfg.palette = pal;
                return;
            }
        } else if (eq(t, "editor.sizes")) {
            const tool = std.meta.stringToEnum(Tool, k) orelse return p.diagf(line, "unknown tool \"{s}\" in [editor.sizes]", .{k});
            if (tool == .crop or tool == .picker) return p.diagf(line, "{s} has no size", .{k});
            const f: f64 = switch (v) {
                .int => |x| @floatFromInt(x),
                .float => |x| x,
                else => return p.diagf(line, "{s} must be a number", .{k}),
            };
            if (f < 1 or f > 256) return p.diagf(line, "{s} must be between 1 and 256", .{k});
            cfg.sizes[@backingInt(tool)] = @floatCast(f);
            return;
        } else if (eq(t, "ocr")) {
            if (eq(k, "language")) {
                const s = p.str(line, k, v) orelse return;
                cfg.ocr_language = p.arena.dupeSentinel(u8, s, 0) catch return;
                return;
            }
            if (eq(k, "notify")) return p.setBool(&cfg.ocr_notify, line, k, v);
        } else {
            return p.diagf(line, "unknown table [{s}]", .{t});
        }
        p.diagf(line, "unknown key \"{s}\" in [{s}]", .{ k, t });
    }

    fn str(p: *Parser, line: u32, k: []const u8, v: Value) ?[]const u8 {
        return switch (v) {
            .string => |s| s,
            else => {
                p.diagf(line, "{s} must be a string", .{k});
                return null;
            },
        };
    }

    fn setStr(p: *Parser, dst: *[]const u8, line: u32, k: []const u8, v: Value) void {
        dst.* = p.str(line, k, v) orelse return;
    }

    fn setBool(p: *Parser, dst: *bool, line: u32, k: []const u8, v: Value) void {
        switch (v) {
            .boolean => |b| dst.* = b,
            else => p.diagf(line, "{s} must be true or false", .{k}),
        }
    }

    fn setInt(p: *Parser, comptime T: type, dst: *T, lo: i64, hi: i64, line: u32, k: []const u8, v: Value) void {
        switch (v) {
            .int => |x| {
                if (x < lo or x > hi) return p.diagf(line, "{s} must be between {d} and {d}", .{ k, lo, hi });
                dst.* = @intCast(x);
            },
            else => p.diagf(line, "{s} must be a whole number", .{k}),
        }
    }

    fn setEnum(p: *Parser, comptime T: type, dst: *T, line: u32, k: []const u8, v: Value) void {
        const s = p.str(line, k, v) orelse return;
        dst.* = std.meta.stringToEnum(T, s) orelse return p.diagf(line, "unknown {s} \"{s}\"", .{ k, s });
    }

    fn setColor(p: *Parser, dst: *Color, line: u32, v: Value) void {
        const s = switch (v) {
            .string => |s| s,
            else => return p.diag(line, "colours are \"#rrggbb\" strings"),
        };
        dst.* = parseHex(s) orelse return p.diagf(line, "bad colour \"{s}\" (want \"#rrggbb\")", .{s});
    }
};

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---- tests ----

const testing = std.testing;

fn parseForTest(text: []const u8, diags: *std.ArrayList(Diag), arena: Allocator) Config {
    return fromText(arena, text, diags);
}

test "the documented default file parses to the built-in defaults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags: std.ArrayList(Diag) = .empty;
    const cfg = parseForTest(default_text, &diags, arena);
    for (diags.items) |d| std.debug.print("line {d}: {s}\n", .{ d.line, d.msg });
    try testing.expectEqual(@as(usize, 0), diags.items.len);
    const def: Config = .{};
    inline for (@typeInfo(Config).@"struct".field_names) |name| {
        const a = @field(cfg, name);
        const b = @field(def, name);
        switch (@TypeOf(a)) {
            []const u8, [:0]const u8 => try testing.expectEqualStrings(b, a),
            else => try testing.expect(std.meta.eql(a, b)),
        }
    }
}

test "values, tables, comments and errors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diags: std.ArrayList(Diag) = .empty;
    const cfg = parseForTest(
        \\# comment
        \\[capture]
        \\mode = "window"   # trailing comment
        \\delay = 1_0
        \\bogus = 1
        \\[output]
        \\format = 'webp'
        \\dir = "~/Shots é"
        \\jpeg_quality = 500
        \\[editor.sizes]
        \\pen = 6.5
        \\[editor]
        \\palette = ["#000000", "#111111", "#222222", "#333333",
        \\  "#444444", "#555555", "#666666", "#777777", # last
        \\]
        \\tool = "crop"
        \\[nope]
        \\x = true
        \\
    , &diags, arena);
    try testing.expectEqual(Mode.window, cfg.mode);
    try testing.expectEqual(@as(u32, 10), cfg.delay);
    try testing.expectEqual(Format.webp, cfg.format);
    try testing.expectEqualStrings("~/Shots \u{e9}", cfg.dir);
    try testing.expectEqual(@as(u8, 92), cfg.jpeg_quality); // out of range: kept default
    try testing.expectEqual(@as(f32, 6.5), cfg.sizes[@backingInt(Tool.pen)]);
    try testing.expectEqual(@as(f32, 0x22) / 255, cfg.palette[2].r);
    try testing.expectEqual(Tool.pen, cfg.tool);
    // bogus key, quality range, crop tool, unknown table
    try testing.expectEqual(@as(usize, 4), diags.items.len);
    try testing.expectEqual(@as(u32, 5), diags.items[0].line);
}

test "saveDir expands ~" {
    const cfg: Config = .{ .dir = "~/Pictures/x" };
    const d = try cfg.saveDir(testing.allocator, "/home/w");
    defer testing.allocator.free(d);
    try testing.expectEqualStrings("/home/w/Pictures/x", d);
}
