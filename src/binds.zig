//! `pict --print-niri-binds`: a ready-to-paste niri `binds {}` block.
//!
//! Each action has key combos in order of preference. The first one that isn't already
//! bound in the user's niri config is used; if every combo is taken the line is printed
//! commented out, naming what holds it. Binds that already spawn pict the same way are
//! commented out as "already set up". Only the main config file is read (not includes).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Entry = struct {
    title: []const u8,
    args: []const []const u8,
    combos: []const []const u8,
};

const entries = [_]Entry{
    .{ .title = "Snip a region", .args = &.{}, .combos = &.{ "Mod+Shift+S", "Print" } },
    .{ .title = "Snip a window", .args = &.{"--window"}, .combos = &.{ "Alt+Print", "Mod+Shift+W" } },
    .{ .title = "Snip freeform", .args = &.{"--freeform"}, .combos = &.{ "Shift+Print", "Mod+Alt+S" } },
    .{ .title = "Screenshot this monitor", .args = &.{"--fullscreen"}, .combos = &.{ "Ctrl+Print", "Mod+Ctrl+S" } },
    .{ .title = "Screenshot all monitors", .args = &.{ "--fullscreen", "--all" }, .combos = &.{"Ctrl+Shift+Print"} },
    .{ .title = "Snip straight to the clipboard", .args = &.{"--copy-only"}, .combos = &.{ "Mod+Print", "Mod+Ctrl+Shift+S" } },
    .{ .title = "Copy text from the screen", .args = &.{"--ocr"}, .combos = &.{ "Mod+Shift+T", "Mod+Alt+T", "Mod+Ctrl+T" } },
    .{ .title = "Snip in 5 seconds", .args = &.{ "--delay", "5" }, .combos = &.{"Mod+Shift+Print"} },
};

pub const Existing = struct {
    /// Normalised combo (see `normalize`).
    combo: []const u8,
    /// The text between the bind's braces, trimmed.
    action: []const u8,
};

/// Render the block. `config` is the user's niri config text (null if none was found);
/// `exe` is how binds should name pict ("pict" when it's on PATH).
pub fn render(gpa: Allocator, config: ?[]const u8, config_path: ?[]const u8, exe: []const u8) ![]u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const existing = if (config) |t| try parseBinds(arena, t) else &.{};

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const w = struct {
        fn print(o: *std.ArrayList(u8), a: Allocator, comptime f: []const u8, args: anytype) !void {
            try o.print(a, f, args);
        }
    }.print;

    try w(&out, gpa, "// pict keybinds for niri. Paste the lines into your binds {{ }} block, or save\n", .{});
    try w(&out, gpa, "// this as ~/.config/niri/pict.kdl and add  include \"pict.kdl\"  to config.kdl.\n", .{});
    if (config_path) |p| {
        try w(&out, gpa, "// Combos already bound in {s} were skipped.\n", .{p});
    } else {
        try w(&out, gpa, "// No niri config was found, so conflicts weren't checked.\n", .{});
    }
    try w(&out, gpa, "binds {{\n", .{});

    for (entries) |e| {
        var spawn: std.ArrayList(u8) = .empty;
        try spawn.print(arena, "spawn \"{s}\"", .{exe});
        for (e.args) |a| try spawn.print(arena, " \"{s}\"", .{a});
        try spawn.appendSlice(arena, ";");

        // Already set up: some bind spawns pict with exactly these arguments.
        if (findPictBind(existing, e.args)) |ex| {
            try w(&out, gpa, "    // {s}: already bound ({s})\n", .{ e.title, ex.combo });
            continue;
        }
        var chosen: ?[]const u8 = null;
        for (e.combos) |combo| {
            if (lookup(existing, try normalize(arena, combo)) == null) {
                chosen = combo;
                break;
            }
        }
        if (chosen) |combo| {
            try w(&out, gpa, "    {s} hotkey-overlay-title=\"{s}\" {{ {s} }}\n", .{ combo, e.title, spawn.items });
        } else {
            const holder = lookup(existing, try normalize(arena, e.combos[0])).?;
            const what = if (holder.action.len > 0) holder.action else "another bind";
            try w(&out, gpa, "    // {s} hotkey-overlay-title=\"{s}\" {{ {s} }}  // taken: {s}\n", .{ e.combos[0], e.title, spawn.items, what });
        }
    }
    try w(&out, gpa, "}}\n", .{});
    return out.toOwnedSlice(gpa);
}

fn lookup(existing: []const Existing, combo: []const u8) ?Existing {
    for (existing) |ex| if (std.mem.eql(u8, ex.combo, combo)) return ex;
    return null;
}

fn findPictBind(existing: []const Existing, args: []const []const u8) ?Existing {
    for (existing) |ex| {
        var toks: [16][]const u8 = undefined;
        const n = spawnArgs(ex.action, &toks) orelse continue;
        if (n == 0 or !std.mem.eql(u8, std.fs.path.basename(toks[0]), "pict")) continue;
        if (n - 1 != args.len) continue;
        for (toks[1..n], args) |a, b| {
            if (!std.mem.eql(u8, a, b)) break;
        } else return ex;
    }
    return null;
}

/// The quoted arguments of a `spawn "a" "b";` action, or null if it isn't one.
fn spawnArgs(action: []const u8, out: *[16][]const u8) ?usize {
    const rest = std.mem.trim(u8, action, " \t;");
    if (!std.mem.startsWith(u8, rest, "spawn ")) return null;
    var n: usize = 0;
    var i: usize = "spawn".len;
    while (i < rest.len) {
        if (rest[i] == '"') {
            const end = std.mem.indexOfScalarPos(u8, rest, i + 1, '"') orelse return null;
            if (n == out.len) return null;
            out[n] = rest[i + 1 .. end];
            n += 1;
            i = end + 1;
        } else if (rest[i] == ';') {
            break;
        } else i += 1;
    }
    return n;
}

/// "MOD+shift+s" → "Super+Shift+S": modifiers in a fixed order and spelling, key
/// upper-cased. Mod is treated as Super (niri's default outside a nested session).
pub fn normalize(arena: Allocator, combo: []const u8) ![]const u8 {
    const order = [_][]const u8{ "Super", "Ctrl", "Alt", "Shift", "ISO_Level3_Shift", "ISO_Level5_Shift" };
    var has: [order.len]bool = @splat(false);
    var key: []const u8 = "";
    var it = std.mem.splitScalar(u8, combo, '+');
    while (it.next()) |part| {
        const m: ?usize = if (ieq(part, "Mod") or ieq(part, "Super") or ieq(part, "Win") or ieq(part, "Mod4"))
            0
        else if (ieq(part, "Ctrl") or ieq(part, "Control"))
            1
        else if (ieq(part, "Alt") or ieq(part, "Mod1"))
            2
        else if (ieq(part, "Shift"))
            3
        else if (ieq(part, "ISO_Level3_Shift") or ieq(part, "Mod5"))
            4
        else if (ieq(part, "ISO_Level5_Shift") or ieq(part, "Mod3"))
            5
        else
            null;
        if (m) |i| has[i] = true else key = part;
    }
    var out: std.ArrayList(u8) = .empty;
    for (order, has) |name, h| if (h) {
        try out.appendSlice(arena, name);
        try out.append(arena, '+');
    };
    for (key) |ch| try out.append(arena, std.ascii.toUpper(ch));
    return out.items;
}

fn ieq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// Binds in the top-level `binds {}` sections of a niri KDL config. A light scanner,
/// not a KDL parser: it tracks strings (including raw strings), comments and brace
/// depth, and reads each node directly inside `binds` as "<combo> [props] { action }".
pub fn parseBinds(arena: Allocator, text: []const u8) ![]Existing {
    var list: std.ArrayList(Existing) = .empty;
    var depth: usize = 0;
    var binds_depth: ?usize = null;
    var i: usize = 0;
    var line_start = true;
    while (i < text.len) {
        const ch = text[i];
        if (ch == '\n') {
            line_start = true;
            i += 1;
            continue;
        }
        if (ch == ' ' or ch == '\t' or ch == '\r') {
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], "//")) {
            i = std.mem.indexOfScalarPos(u8, text, i, '\n') orelse text.len;
            continue;
        }
        if (std.mem.startsWith(u8, text[i..], "/*")) {
            i = if (std.mem.indexOfPos(u8, text, i + 2, "*/")) |e| e + 2 else text.len;
            continue;
        }
        if (ch == '"' or (ch == 'r' and i + 1 < text.len and (text[i + 1] == '#' or text[i + 1] == '"'))) {
            i = skipString(text, i);
            line_start = false;
            continue;
        }
        if (ch == '{') {
            depth += 1;
            i += 1;
            continue;
        }
        if (ch == '}') {
            if (depth > 0) depth -= 1;
            if (binds_depth) |bd| if (depth < bd) {
                binds_depth = null;
            };
            i += 1;
            continue;
        }
        // Start of a node at the beginning of a line.
        if (line_start) {
            line_start = false;
            const tok_end = tokenEnd(text, i);
            const tok = text[i..tok_end];
            if (depth == 0 and std.mem.eql(u8, tok, "binds")) {
                binds_depth = 1;
            } else if (binds_depth != null and depth == binds_depth.? and !std.mem.startsWith(u8, tok, "/-")) {
                const open = std.mem.indexOfScalarPos(u8, text, tok_end, '{');
                const nl = std.mem.indexOfScalarPos(u8, text, tok_end, '\n') orelse text.len;
                var action: []const u8 = "";
                if (open) |o| if (o < nl) {
                    const close = std.mem.indexOfScalarPos(u8, text, o, '}') orelse nl;
                    action = std.mem.trim(u8, text[o + 1 .. @min(close, nl)], " \t");
                };
                try list.append(arena, .{ .combo = try normalize(arena, tok), .action = action });
            }
            i = tok_end;
            continue;
        }
        i += 1;
    }
    return list.items;
}

fn tokenEnd(text: []const u8, start: usize) usize {
    var j = start;
    while (j < text.len and !std.ascii.isWhitespace(text[j]) and text[j] != '{' and text[j] != ';') j += 1;
    return j;
}

/// Index just past a "..." or r#"..."# string starting at `i`.
fn skipString(text: []const u8, i: usize) usize {
    if (text[i] == '"') {
        var j = i + 1;
        while (j < text.len) : (j += 1) {
            if (text[j] == '\\') {
                j += 1;
                continue;
            }
            if (text[j] == '"') return j + 1;
        }
        return text.len;
    }
    // Raw: r, N hashes, quote ... quote, N hashes.
    var j = i + 1;
    var hashes: usize = 0;
    while (j < text.len and text[j] == '#') : (j += 1) hashes += 1;
    if (j >= text.len or text[j] != '"') return i + 1; // just an identifier starting with r
    j += 1;
    while (j < text.len) : (j += 1) {
        if (text[j] != '"') continue;
        var k: usize = 0;
        while (k < hashes and j + 1 + k < text.len and text[j + 1 + k] == '#') k += 1;
        if (k == hashes) return j + 1 + hashes;
    }
    return text.len;
}

const testing = std.testing;

test "normalize orders modifiers and maps Mod to Super" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    try testing.expectEqualStrings("Super+Shift+S", try normalize(a.allocator(), "MOD+SHIFT+s"));
    try testing.expectEqualStrings("Super+Ctrl+Alt+T", try normalize(a.allocator(), "Alt+Ctrl+Super+T"));
    try testing.expectEqualStrings("PRINT", try normalize(a.allocator(), "Print"));
}

test "parseBinds reads only binds, skipping strings and comments" {
    var a = std.heap.ArenaAllocator.init(testing.allocator);
    defer a.deinit();
    const cfg =
        \\input { keyboard { xkb { layout "us"; } } }
        \\window-rule { match app-id=r#"^x{$"# }
        \\binds {
        \\    // Mod+Q { close-window; }
        \\    MOD+SHIFT+T { toggle-window-floating; }
        \\    /-Mod+X { quit; }
        \\    Mod+Shift+S  { spawn "pict"; }  // region
        \\    Print repeat=false { screenshot; }
        \\    Mod+Return {
        \\        spawn "alacritty";
        \\    }
        \\    /* Mod+Y { quit; } */
        \\}
        \\layout { Mod+Z { } }
        \\
    ;
    const binds = try parseBinds(a.allocator(), cfg);
    try testing.expectEqual(@as(usize, 4), binds.len);
    try testing.expectEqualStrings("Super+Shift+T", binds[0].combo);
    try testing.expectEqualStrings("toggle-window-floating;", binds[0].action);
    try testing.expectEqualStrings("spawn \"pict\";", binds[1].action);
    try testing.expectEqualStrings("PRINT", binds[2].combo);
    try testing.expectEqualStrings("Super+RETURN", binds[3].combo);
}

test "render skips taken combos and existing pict binds" {
    const cfg =
        \\binds {
        \\    MOD+SHIFT+T { toggle-window-floating; }
        \\    Mod+Alt+T { spawn "x"; }
        \\    Mod+Ctrl+T { spawn "y"; }
        \\    Mod+Shift+S { spawn "pict"; }
        \\    Alt+Print { screenshot-window; }
        \\}
    ;
    const out = try render(testing.allocator, cfg, "/c.kdl", "pict");
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "// Snip a region: already bound (Super+Shift+S)") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    Mod+Shift+W hotkey-overlay-title=\"Snip a window\" { spawn \"pict\" \"--window\"; }") != null);
    try testing.expect(std.mem.indexOf(u8, out, "// Mod+Shift+T hotkey-overlay-title=\"Copy text from the screen\" { spawn \"pict\" \"--ocr\"; }  // taken: toggle-window-floating;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "    Ctrl+Print hotkey-overlay-title=\"Screenshot this monitor\" { spawn \"pict\" \"--fullscreen\"; }") != null);
}
