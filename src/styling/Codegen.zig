//! Styling system Stage 2: emits a real Go source file from resolved style
//! tokens (amber-woven-lantern.md's Stage 2). The only guest-language
//! target for now -- Go is the only real guest SDK that exists (sdk/go) --
//! so this is deliberately not a generic multi-language codegen framework
//! yet; that's real, but premature, work for languages with no SDK to
//! receive it.
//!
//! Emits `BackgroundColor`/`Padding`/`CornerRadius`/`Border`/`Gradient`
//! into the generated `widgets.ResolvedStyle` literals -- everything
//! `widgets.ApplyStyle`/`natyv_set_style` consume as of Stage 5b.
//! `gradient`'s named anchor (`topLeft`, etc.) is resolved to a plain 0..1
//! UV position *here*, at prepare time -- the host/rendering side
//! (ShapeCache.drawRoundedRectGradient) is deliberately anchor-agnostic,
//! same as how a hex color is resolved to floats here rather than crossing
//! the wire as a string.
//!
//! `texture` resolves correctly (Resolver.zig validates/stores it) but is
//! **deliberately silently dropped here**, not even a warning yet --
//! confirmed 2026-08-21: a real capability-gated warning/error needs
//! `conf.natyv.json`'s image-capability flag to actually exist and reach
//! this pipeline, and neither does until asset staging is implemented.
//! Revisit this exact spot once it is; don't add a stub check against a
//! flag that isn't real yet.
//!
//! `margin` is never emitted here at all, and deliberately not implemented
//! anywhere else in the SDK either right now -- confirmed 2026-08-21:
//! margin-as-implicit-Container-wrap is real "build system" sugar (see
//! CLAUDE.md's styling section), and the only widget-authoring surface
//! today is hand-written direct `widgets.CreateX(...)` calls, which v1
//! deliberately won't keep as the real authoring model once the `.ntx`
//! JSX layer ships (guests will *only* author through `.ntx` post-v1).
//! Building a margin-wrapping helper against the interim direct-call API
//! now would target a surface that's going away -- real margin support
//! belongs entirely in the `.ntx` transpiler's own implementation pass
//! (see `natyv_jsx_markup_layer` memory), not here.
//!
//! `text`/`transition` are also never emitted -- their own real schemas
//! are still open decisions (amber-woven-lantern.md's own sign-off list).
//!
//! Not yet wrapped in a CLI (`natyv prepare` doesn't exist as a real
//! executable) -- deliberately deferred to the tooling arc, alongside the
//! `.ntx` transpiler, per Quinn's own explicit scoping.

const std = @import("std");
const Resolver = @import("Resolver");

/// Resolves a stylesheet gradient anchor to a plain 0..1 shape-space UV
/// position -- see this file's own doc comment for why this happens here,
/// at prepare time, rather than crossing the wire as a name.
fn anchorUV(anchor: Resolver.GradientAnchor) [2]f32 {
    return switch (anchor) {
        .top => .{ 0.5, 0 },
        .bottom => .{ 0.5, 1 },
        .left => .{ 0, 0.5 },
        .right => .{ 1, 0.5 },
        .topLeft => .{ 0, 0 },
        .topRight => .{ 1, 0 },
        .bottomLeft => .{ 0, 1 },
        .bottomRight => .{ 1, 1 },
    };
}

fn writeGoFloat(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: f32) !void {
    // Formatting `v` directly as f32 (not widened to f64 first) matters:
    // Zig's `{d}` float formatting produces the shortest decimal string
    // that round-trips back to the exact same bit pattern *for the given
    // float type* -- widening an f32 to f64 first bakes in that f32's own
    // binary imprecision as a "real" f64 value (e.g. 0.1's nearest f32,
    // widened, prints as 0.10000000149011612), which isn't what a real
    // human-authored hex color's resolved channel value should ever look
    // like in generated Go source.
    var buf: [64]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
    try out.appendSlice(allocator, s);
}

fn writeColorLiteral(out: *std.ArrayList(u8), allocator: std.mem.Allocator, c: Resolver.Color) !void {
    try out.appendSlice(allocator, "&widgets.Color{R: ");
    try writeGoFloat(out, allocator, c.r);
    try out.appendSlice(allocator, ", G: ");
    try writeGoFloat(out, allocator, c.g);
    try out.appendSlice(allocator, ", B: ");
    try writeGoFloat(out, allocator, c.b);
    try out.appendSlice(allocator, ", A: ");
    try writeGoFloat(out, allocator, c.a);
    try out.appendSlice(allocator, "}");
}

/// Go identifiers can't contain '-', but real token names do (e.g.
/// `button-primary`, per Stylesheet.zig's lexer supporting it) -- token
/// names are only ever used as Go string/map-key literals here, never as
/// identifiers, so no escaping/renaming is needed, just a quoted string.
fn writeGoU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, v: u16) !void {
    var buf: [8]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
    try out.appendSlice(allocator, s);
}

fn writeGoStringLiteral(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.appendSlice(allocator, "\"");
    for (s) |ch| {
        if (ch == '"' or ch == '\\') try out.append(allocator, '\\');
        try out.append(allocator, ch);
    }
    try out.appendSlice(allocator, "\"");
}

pub fn generateGo(allocator: std.mem.Allocator, package_name: []const u8, tokens: []const Resolver.ResolvedStyleToken) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "// Code generated by natyv prepare. DO NOT EDIT.\n\npackage ");
    try out.appendSlice(allocator, package_name);
    try out.appendSlice(allocator, "\n\nimport \"natyv/sdk/widgets\"\n\nvar StyleTokens = map[string]widgets.ResolvedStyle{\n");

    for (tokens) |tok| {
        try out.appendSlice(allocator, "\t");
        try writeGoStringLiteral(&out, allocator, tok.name);
        try out.appendSlice(allocator, ": {\n");
        if (tok.background_color) |bg| {
            try out.appendSlice(allocator, "\t\tBackgroundColor: ");
            try writeColorLiteral(&out, allocator, bg);
            try out.appendSlice(allocator, ",\n");
        }
        if (tok.padding) |p| {
            try out.appendSlice(allocator, "\t\tPadding: &widgets.Padding{Left: ");
            try writeGoU16(&out, allocator, p);
            try out.appendSlice(allocator, ", Right: ");
            try writeGoU16(&out, allocator, p);
            try out.appendSlice(allocator, ", Top: ");
            try writeGoU16(&out, allocator, p);
            try out.appendSlice(allocator, ", Bottom: ");
            try writeGoU16(&out, allocator, p);
            try out.appendSlice(allocator, "},\n");
        }
        if (tok.corner_radius) |cr| {
            // Bare integer literals (untyped constants) assign straight
            // into widgets.CornerRadius's float32 fields -- no separate
            // float formatter needed for what's always an integer-pixel
            // value coming out of the resolver.
            try out.appendSlice(allocator, "\t\tCornerRadius: &widgets.CornerRadius{TopLeft: ");
            try writeGoU16(&out, allocator, cr[0]);
            try out.appendSlice(allocator, ", TopRight: ");
            try writeGoU16(&out, allocator, cr[1]);
            try out.appendSlice(allocator, ", BottomRight: ");
            try writeGoU16(&out, allocator, cr[2]);
            try out.appendSlice(allocator, ", BottomLeft: ");
            try writeGoU16(&out, allocator, cr[3]);
            try out.appendSlice(allocator, "},\n");
        }
        if (tok.border) |b| {
            try out.appendSlice(allocator, "\t\tBorder: &widgets.Border{Width: ");
            try writeGoU16(&out, allocator, b.width);
            try out.appendSlice(allocator, ", Color: widgets.Color{R: ");
            try writeGoFloat(&out, allocator, b.color.r);
            try out.appendSlice(allocator, ", G: ");
            try writeGoFloat(&out, allocator, b.color.g);
            try out.appendSlice(allocator, ", B: ");
            try writeGoFloat(&out, allocator, b.color.b);
            try out.appendSlice(allocator, ", A: ");
            try writeGoFloat(&out, allocator, b.color.a);
            try out.appendSlice(allocator, "}},\n");
        }
        if (tok.gradient) |g| {
            const start_uv = anchorUV(g.start.pos);
            const end_uv = anchorUV(g.end.pos);
            try out.appendSlice(allocator, "\t\tGradient: &widgets.Gradient{StartPos: [2]float32{");
            try writeGoFloat(&out, allocator, start_uv[0]);
            try out.appendSlice(allocator, ", ");
            try writeGoFloat(&out, allocator, start_uv[1]);
            try out.appendSlice(allocator, "}, StartColor: widgets.Color{R: ");
            try writeGoFloat(&out, allocator, g.start.color.r);
            try out.appendSlice(allocator, ", G: ");
            try writeGoFloat(&out, allocator, g.start.color.g);
            try out.appendSlice(allocator, ", B: ");
            try writeGoFloat(&out, allocator, g.start.color.b);
            try out.appendSlice(allocator, ", A: ");
            try writeGoFloat(&out, allocator, g.start.color.a);
            try out.appendSlice(allocator, "}, EndPos: [2]float32{");
            try writeGoFloat(&out, allocator, end_uv[0]);
            try out.appendSlice(allocator, ", ");
            try writeGoFloat(&out, allocator, end_uv[1]);
            try out.appendSlice(allocator, "}, EndColor: widgets.Color{R: ");
            try writeGoFloat(&out, allocator, g.end.color.r);
            try out.appendSlice(allocator, ", G: ");
            try writeGoFloat(&out, allocator, g.end.color.g);
            try out.appendSlice(allocator, ", B: ");
            try writeGoFloat(&out, allocator, g.end.color.b);
            try out.appendSlice(allocator, ", A: ");
            try writeGoFloat(&out, allocator, g.end.color.a);
            try out.appendSlice(allocator, "}},\n");
        }
        try out.appendSlice(allocator, "\t},\n");
    }

    try out.appendSlice(allocator, "}\n");
    return out.toOwnedSlice(allocator);
}

test "generates valid-looking Go for a full token" {
    const tokens = [_]Resolver.ResolvedStyleToken{
        .{
            .name = "card-header",
            .background_color = .{ .r = 0.1, .g = 0.2, .b = 0.3, .a = 1.0 },
            .padding = 8,
        },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = try generateGo(arena.allocator(), "main", &tokens);
    try std.testing.expect(std.mem.indexOf(u8, src, "package main") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "\"card-header\": {") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "BackgroundColor: &widgets.Color{R: 0.1, G: 0.2, B: 0.3, A: 1}") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "Padding: &widgets.Padding{Left: 8, Right: 8, Top: 8, Bottom: 8}") != null);
}

test "generates cornerRadius and border for a styled token" {
    const tokens = [_]Resolver.ResolvedStyleToken{
        .{
            .name = "card-style",
            .corner_radius = .{ 4, 8, 12, 16 },
            .border = .{ .width = 2, .color = .{ .r = 0.545, .g = 0.361, .b = 0.965, .a = 1.0 } },
        },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = try generateGo(arena.allocator(), "main", &tokens);
    try std.testing.expect(std.mem.indexOf(u8, src, "CornerRadius: &widgets.CornerRadius{TopLeft: 4, TopRight: 8, BottomRight: 12, BottomLeft: 16}") != null);
    try std.testing.expect(std.mem.indexOf(u8, src, "Border: &widgets.Border{Width: 2, Color: widgets.Color{R: 0.545, G: 0.361, B: 0.965, A: 1}}") != null);
}

test "generates gradient with anchors resolved to UV positions" {
    const tokens = [_]Resolver.ResolvedStyleToken{
        .{
            .name = "fade",
            .gradient = .{
                .start = .{ .pos = .topLeft, .color = .{ .r = 0, .g = 0, .b = 0, .a = 1 } },
                .end = .{ .pos = .bottomRight, .color = .{ .r = 1, .g = 1, .b = 1, .a = 1 } },
            },
        },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = try generateGo(arena.allocator(), "main", &tokens);
    try std.testing.expect(std.mem.indexOf(u8, src, "Gradient: &widgets.Gradient{StartPos: [2]float32{0, 0}, StartColor: widgets.Color{R: 0, G: 0, B: 0, A: 1}, EndPos: [2]float32{1, 1}, EndColor: widgets.Color{R: 1, G: 1, B: 1, A: 1}}") != null);
}

test "omits fields that were never resolved" {
    const tokens = [_]Resolver.ResolvedStyleToken{.{ .name = "bare" }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src = try generateGo(arena.allocator(), "main", &tokens);
    try std.testing.expect(std.mem.indexOf(u8, src, "\"bare\": {\n\t},\n") != null);
}
