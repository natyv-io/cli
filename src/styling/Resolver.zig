//! Styling system Stage 2: the semantic pass over `Stylesheet.zig`'s
//! generic AST -- validates each field against the real v1 vocabulary
//! (amber-woven-lantern.md) and produces a strongly-typed
//! `ResolvedStyleToken`. Deliberately separate from the parser (see that
//! file's own doc comment) so vocabulary growth never touches the syntax
//! grammar.
//!
//! An unrecognized top-level field name is a hard error, not silently
//! ignored -- a closed vocabulary catches a typo'd `boarder: {...}`
//! instead of quietly doing nothing, matching every other natyv
//! guest-facing surface (widget kinds, host functions) already being
//! host-validated rather than best-effort.
//!
//! `text`/`transition` are carried through unresolved (their real schemas
//! are still open decisions, per amber-woven-lantern.md's own sign-off
//! list) -- accepted as any value, stored as the raw AST node, not
//! type-checked yet.

const std = @import("std");
const Stylesheet = @import("Stylesheet.zig");

pub const GradientAnchor = enum {
    top,
    bottom,
    left,
    right,
    topLeft,
    topRight,
    bottomLeft,
    bottomRight,
};

pub const Color = struct { r: f32, g: f32, b: f32, a: f32 };

pub const Border = struct { width: u16, color: Color };
pub const GradientStop = struct { pos: GradientAnchor, color: Color };
pub const Gradient = struct { start: GradientStop, end: GradientStop };

pub const ResolvedStyleToken = struct {
    name: []const u8,
    corner_radius: ?[4]u16 = null,
    border: ?Border = null,
    background_color: ?Color = null,
    gradient: ?Gradient = null,
    padding: ?u16 = null,
    margin: ?u16 = null,
    texture: ?[]const u8 = null,
    /// Raw passthrough -- see file doc comment.
    text: ?Stylesheet.Value = null,
    /// Raw passthrough -- see file doc comment.
    transition: ?Stylesheet.Value = null,
};

pub const ResolveError = struct {
    line: u32,
    col: u32,
    message: []const u8,
};

const Error = error{ ResolveError, OutOfMemory };

const Resolver = struct {
    allocator: std.mem.Allocator,
    last_error: ?ResolveError = null,

    fn fail(self: *Resolver, line: u32, col: u32, comptime fmt: []const u8, args: anytype) Error {
        self.last_error = .{ .line = line, .col = col, .message = std.fmt.allocPrint(self.allocator, fmt, args) catch fmt };
        return error.ResolveError;
    }

    fn expectNumber(self: *Resolver, field: Stylesheet.Field) Error!f64 {
        return switch (field.value) {
            .number => |n| n,
            else => self.fail(field.line, field.col, "field '{s}' must be a number", .{field.key}),
        };
    }

    fn expectString(self: *Resolver, field: Stylesheet.Field) Error![]const u8 {
        return switch (field.value) {
            .string => |s| s,
            else => self.fail(field.line, field.col, "field '{s}' must be a string", .{field.key}),
        };
    }

    fn expectU16(self: *Resolver, field: Stylesheet.Field) Error!u16 {
        const n = try self.expectNumber(field);
        if (n < 0 or n > std.math.maxInt(u16)) return self.fail(field.line, field.col, "field '{s}' value {d} is out of range", .{ field.key, n });
        return @intFromFloat(n);
    }

    fn parseHexColor(self: *Resolver, field: Stylesheet.Field, s: []const u8) Error!Color {
        if (s.len != 7 and s.len != 9) return self.fail(field.line, field.col, "field '{s}': '{s}' is not a real hex color (expected #RRGGBB or #RRGGBBAA)", .{ field.key, s });
        if (s[0] != '#') return self.fail(field.line, field.col, "field '{s}': '{s}' must start with '#'", .{ field.key, s });
        const r = std.fmt.parseInt(u8, s[1..3], 16) catch return self.fail(field.line, field.col, "field '{s}': '{s}' has invalid hex digits", .{ field.key, s });
        const g = std.fmt.parseInt(u8, s[3..5], 16) catch return self.fail(field.line, field.col, "field '{s}': '{s}' has invalid hex digits", .{ field.key, s });
        const b = std.fmt.parseInt(u8, s[5..7], 16) catch return self.fail(field.line, field.col, "field '{s}': '{s}' has invalid hex digits", .{ field.key, s });
        const a: u8 = if (s.len == 9) std.fmt.parseInt(u8, s[7..9], 16) catch return self.fail(field.line, field.col, "field '{s}': '{s}' has invalid hex digits", .{ field.key, s }) else 255;
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = @as(f32, @floatFromInt(a)) / 255.0,
        };
    }

    fn resolveColorField(self: *Resolver, field: Stylesheet.Field) Error!Color {
        const s = try self.expectString(field);
        return self.parseHexColor(field, s);
    }

    fn resolveCornerRadius(self: *Resolver, field: Stylesheet.Field) Error![4]u16 {
        const list = switch (field.value) {
            .list => |l| l,
            else => return self.fail(field.line, field.col, "field 'cornerRadius' must be a 4-number list, e.g. {{4, 4, 4, 4}}", .{}),
        };
        if (list.len != 4) return self.fail(field.line, field.col, "field 'cornerRadius' must have exactly 4 values (TL, TR, BR, BL), found {d}", .{list.len});
        var out: [4]u16 = undefined;
        for (list, 0..) |v, i| {
            const n = switch (v) {
                .number => |n| n,
                else => return self.fail(field.line, field.col, "field 'cornerRadius' entries must all be numbers", .{}),
            };
            if (n < 0 or n > std.math.maxInt(u16)) return self.fail(field.line, field.col, "field 'cornerRadius' value {d} is out of range", .{n});
            out[i] = @intFromFloat(n);
        }
        return out;
    }

    fn findField(fields: []const Stylesheet.Field, key: []const u8) ?Stylesheet.Field {
        for (fields) |f| {
            if (std.mem.eql(u8, f.key, key)) return f;
        }
        return null;
    }

    fn resolveBorder(self: *Resolver, field: Stylesheet.Field) Error!Border {
        const inner = switch (field.value) {
            .block => |b| b,
            else => return self.fail(field.line, field.col, "field 'border' must be a block, e.g. {{ width: 2, color: \"#...\" }}", .{}),
        };
        const width_field = findField(inner, "width") orelse return self.fail(field.line, field.col, "field 'border' is missing required 'width'", .{});
        const color_field = findField(inner, "color") orelse return self.fail(field.line, field.col, "field 'border' is missing required 'color'", .{});
        return .{ .width = try self.expectU16(width_field), .color = try self.resolveColorField(color_field) };
    }

    fn resolveAnchor(self: *Resolver, field: Stylesheet.Field, s: []const u8) Error!GradientAnchor {
        return std.meta.stringToEnum(GradientAnchor, s) orelse
            self.fail(field.line, field.col, "field '{s}': '{s}' is not one of the 8 real anchor keywords (top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight)", .{ field.key, s });
    }

    fn resolveGradientStop(self: *Resolver, parent: Stylesheet.Field, key: []const u8, value: Stylesheet.Value) Error!GradientStop {
        const inner = switch (value) {
            .block => |b| b,
            else => return self.fail(parent.line, parent.col, "field 'gradient.{s}' must be a block, e.g. {{ pos: top, color: \"#...\" }}", .{key}),
        };
        const pos_field = findField(inner, "pos") orelse return self.fail(parent.line, parent.col, "field 'gradient.{s}' is missing required 'pos'", .{key});
        const color_field = findField(inner, "color") orelse return self.fail(parent.line, parent.col, "field 'gradient.{s}' is missing required 'color'", .{key});
        const pos_str = switch (pos_field.value) {
            .ident => |id| id,
            else => return self.fail(pos_field.line, pos_field.col, "field 'pos' must be a bare anchor keyword, not a string or number", .{}),
        };
        return .{ .pos = try self.resolveAnchor(pos_field, pos_str), .color = try self.resolveColorField(color_field) };
    }

    fn resolveGradient(self: *Resolver, field: Stylesheet.Field) Error!Gradient {
        const inner = switch (field.value) {
            .block => |b| b,
            else => return self.fail(field.line, field.col, "field 'gradient' must be a block with 'start'/'end'", .{}),
        };
        const start_field = findField(inner, "start") orelse return self.fail(field.line, field.col, "field 'gradient' is missing required 'start'", .{});
        const end_field = findField(inner, "end") orelse return self.fail(field.line, field.col, "field 'gradient' is missing required 'end'", .{});
        return .{
            .start = try self.resolveGradientStop(field, "start", start_field.value),
            .end = try self.resolveGradientStop(field, "end", end_field.value),
        };
    }

    fn resolveToken(self: *Resolver, token: Stylesheet.StyleToken) Error!ResolvedStyleToken {
        var out: ResolvedStyleToken = .{ .name = token.name };
        for (token.fields) |field| {
            if (std.mem.eql(u8, field.key, "cornerRadius")) {
                out.corner_radius = try self.resolveCornerRadius(field);
            } else if (std.mem.eql(u8, field.key, "border")) {
                out.border = try self.resolveBorder(field);
            } else if (std.mem.eql(u8, field.key, "backgroundColor")) {
                out.background_color = try self.resolveColorField(field);
            } else if (std.mem.eql(u8, field.key, "gradient")) {
                out.gradient = try self.resolveGradient(field);
            } else if (std.mem.eql(u8, field.key, "padding")) {
                out.padding = try self.expectU16(field);
            } else if (std.mem.eql(u8, field.key, "margin")) {
                out.margin = try self.expectU16(field);
            } else if (std.mem.eql(u8, field.key, "texture")) {
                out.texture = try self.expectString(field);
            } else if (std.mem.eql(u8, field.key, "text")) {
                out.text = field.value;
            } else if (std.mem.eql(u8, field.key, "transition")) {
                out.transition = field.value;
            } else {
                return self.fail(field.line, field.col, "unrecognized style field '{s}' (not part of the v1 vocabulary)", .{field.key});
            }
        }
        return out;
    }
};

pub fn resolve(allocator: std.mem.Allocator, sheet: Stylesheet.StyleSheet) error{OutOfMemory}!struct { tokens: []ResolvedStyleToken, err: ?ResolveError } {
    var resolver: Resolver = .{ .allocator = allocator };
    var out: std.ArrayList(ResolvedStyleToken) = .empty;
    errdefer out.deinit(allocator);
    for (sheet.tokens) |token| {
        const resolved = resolver.resolveToken(token) catch |e| {
            if (e == error.ResolveError) return .{ .tokens = &.{}, .err = resolver.last_error };
            return error.OutOfMemory;
        };
        try out.append(allocator, resolved);
    }
    return .{ .tokens = try out.toOwnedSlice(allocator), .err = null };
}

fn parseAndResolve(allocator: std.mem.Allocator, src: []const u8) !struct { tokens: []ResolvedStyleToken, parse_err: ?Stylesheet.ParseError, resolve_err: ?ResolveError } {
    const parsed = try Stylesheet.parse(allocator, src);
    if (parsed.err) |e| return .{ .tokens = &.{}, .parse_err = e, .resolve_err = null };
    const resolved = try resolve(allocator, parsed.sheet);
    return .{ .tokens = resolved.tokens, .parse_err = null, .resolve_err = resolved.err };
}

test "resolves a full valid token" {
    const src =
        \\card {
        \\  cornerRadius: {4, 4, 4, 4}
        \\  border: { width: 2, color: "#8B5CF6" }
        \\  backgroundColor: "#1A1A1EFF"
        \\  gradient: { start: { pos: top, color: "#111111" }, end: { pos: bottomRight, color: "#222222" } }
        \\  padding: 8
        \\  margin: 4
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseAndResolve(arena.allocator(), src);
    try std.testing.expect(result.parse_err == null);
    try std.testing.expect(result.resolve_err == null);
    try std.testing.expectEqual(@as(usize, 1), result.tokens.len);
    const tok = result.tokens[0];
    try std.testing.expectEqualStrings("card", tok.name);
    try std.testing.expectEqual([4]u16{ 4, 4, 4, 4 }, tok.corner_radius.?);
    try std.testing.expectEqual(@as(u16, 2), tok.border.?.width);
    try std.testing.expectApproxEqAbs(@as(f32, 139.0 / 255.0), tok.border.?.color.r, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), tok.background_color.?.a, 0.001);
    try std.testing.expectEqual(GradientAnchor.top, tok.gradient.?.start.pos);
    try std.testing.expectEqual(GradientAnchor.bottomRight, tok.gradient.?.end.pos);
    try std.testing.expectEqual(@as(u16, 8), tok.padding.?);
    try std.testing.expectEqual(@as(u16, 4), tok.margin.?);
}

test "rejects an unrecognized field name" {
    const src =
        \\bad {
        \\  boarder: { width: 1, color: "#000000" }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseAndResolve(arena.allocator(), src);
    try std.testing.expect(result.resolve_err != null);
}

test "rejects a cornerRadius with the wrong count" {
    const src =
        \\bad { cornerRadius: {4, 4, 4} }
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseAndResolve(arena.allocator(), src);
    try std.testing.expect(result.resolve_err != null);
}

test "rejects a malformed hex color" {
    const src =
        \\bad { backgroundColor: "not-a-color" }
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseAndResolve(arena.allocator(), src);
    try std.testing.expect(result.resolve_err != null);
}

test "rejects an invalid gradient anchor keyword" {
    const src =
        \\bad {
        \\  gradient: { start: { pos: diagonal, color: "#000000" }, end: { pos: top, color: "#ffffff" } }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseAndResolve(arena.allocator(), src);
    try std.testing.expect(result.resolve_err != null);
}

test "carries text/transition through unresolved" {
    const src =
        \\bad {
        \\  text: { fontSize: 14 }
        \\  transition: { duration: 200 }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseAndResolve(arena.allocator(), src);
    try std.testing.expect(result.resolve_err == null);
    try std.testing.expect(result.tokens[0].text != null);
    try std.testing.expect(result.tokens[0].transition != null);
}
