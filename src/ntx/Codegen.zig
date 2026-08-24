//! `.ntx` tooling Stage 3b (~/.claude/plans/lexical-wishing-penguin.md):
//! codegen + the real two-file split, for a flat tree (no `ref`/event
//! handlers, no `margin`, no cross-file component reuse yet -- Stages 4,
//! 5, and 6 respectively). Consumes `Expose.zig`'s discovered `Composer`s
//! (each already located and body-bounded) and `Parser.zig`'s tag trees,
//! and emits:
//!
//! - a generated builder file (`DO NOT EDIT`, real `widgets.CreateX(...)`
//!   calls wired via `widgets.ParentID(uint32(...))`, matching the real
//!   SDK convention in `sdk/go/widgets/layout.go`) -- one
//!   `func natyvBuild<Name>(<original params>) error { ... }` per exposed
//!   composer.
//! - a rewritten logic file: the original source, byte-identical except
//!   each composer's `expose Name` line and markup body are spliced out
//!   and replaced with `return natyvBuild<Name>(<forwarded param names>)`
//!   -- everything else (imports, other functions, comments, formatting)
//!   untouched.
//!
//! **Composer functions must have signature `func Name(...) error`** --
//! not void. This corrects an earlier, untested illustrative example in
//! project memory: every *real* hand-written composing function already
//! in this codebase (e.g. `examples/clay-fixture/guest/main.go`'s
//! `openModal() error`) returns `error` and propagates every
//! `widgets.CreateX` failure with `if err != nil { return err }` --
//! there's no way to do that from a void function, and no real precedent
//! for a void one. A void composer is an accepted, documented v1 gap.
//!
//! **Deliberately narrow widget-kind scope**: only `Container` and
//! `Label` -- the two attribute-light kinds needed to prove the whole
//! mechanism end-to-end (nesting, static `styles`, parent wiring, the
//! two-file split, the content-hash header). Every other real widget kind
//! errors clearly (`"widget kind 'X' is not yet supported"`) rather than
//! silently misbehaving. Extending this to natyv's ~30 other widget kinds
//! is real, same-pattern, incremental follow-up work -- not automatic
//! just because the mechanism exists.
//!
//! `ref`/dynamic `styles` expressions and any other braced attribute are
//! also clear codegen errors here, not silently dropped -- they're Stage
//! 4's job.

const std = @import("std");
const Parser = @import("Parser.zig");
const Expose = @import("Expose.zig");

pub const CodegenError = struct {
    line: u32,
    col: u32,
    message: []const u8,
};

pub const Output = struct {
    generated: []const u8,
    logic: []const u8,
};

fn writeGoStringLiteral(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try out.appendSlice(allocator, "\"");
    for (s) |ch| {
        if (ch == '"' or ch == '\\') try out.append(allocator, '\\');
        try out.append(allocator, ch);
    }
    try out.appendSlice(allocator, "\"");
}

/// Splits `text` on top-level commas (tracking paren/bracket depth, so a
/// parameter type like `cb func(int, string) error` doesn't get split
/// inside its own parens). Used both to forward every parameter in the
/// logic file's call-through and (via `leadingIdent`) to find each
/// segment's own name.
fn splitTopLevelCommas(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    errdefer parts.deinit(allocator);
    if (std.mem.trim(u8, text, " \t\r\n").len == 0) return parts.toOwnedSlice(allocator);

    var depth: i32 = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '(', '[' => depth += 1,
            ')', ']' => depth -= 1,
            ',' => if (depth == 0) {
                try parts.append(allocator, std.mem.trim(u8, text[start..i], " \t\r\n"));
                start = i + 1;
            },
            else => {},
        }
    }
    try parts.append(allocator, std.mem.trim(u8, text[start..], " \t\r\n"));
    return parts.toOwnedSlice(allocator);
}

fn isIdentStart(b: u8) bool {
    return std.ascii.isAlphabetic(b) or b == '_';
}
fn isIdentCont(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

/// The leading identifier of a single parameter segment (e.g. "parent" out
/// of "parent widgets.Container") -- correct even for Go's shared-type
/// grouped params (`a, b int` splits into segments "a" and "b int", each
/// of whose leading identifier is exactly that parameter's own name).
fn leadingIdent(segment: []const u8) ?[]const u8 {
    if (segment.len == 0 or !isIdentStart(segment[0])) return null;
    var end: usize = 1;
    while (end < segment.len and isIdentCont(segment[end])) : (end += 1) {}
    return segment[0..end];
}

const EmitError = error{CodegenError} || std.mem.Allocator.Error;

const Emitter = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    counter: u32 = 0,
    err: ?CodegenError = null,

    fn fail(self: *Emitter, line: u32, col: u32, comptime fmt: []const u8, args: anytype) EmitError {
        self.err = .{ .line = line, .col = col, .message = std.fmt.allocPrint(self.allocator, fmt, args) catch fmt };
        return error.CodegenError;
    }

    fn labelText(self: *Emitter, el: Parser.Element) EmitError![]const u8 {
        var text: std.ArrayList(u8) = .empty;
        for (el.children) |child| {
            switch (child) {
                .text => |t| try text.appendSlice(self.allocator, t),
                .element => return self.fail(el.line, el.col, "<Label> doesn't accept nested elements", .{}),
            }
        }
        return text.toOwnedSlice(self.allocator);
    }

    fn emitApplyStyle(self: *Emitter, var_name: []const u8, names: [][]const u8) EmitError!void {
        try self.out.appendSlice(self.allocator, "\tif err := widgets.ApplyStyle(uint32(");
        try self.out.appendSlice(self.allocator, var_name);
        try self.out.appendSlice(self.allocator, "), StyleTokens");
        for (names) |n| {
            try self.out.appendSlice(self.allocator, ", ");
            try writeGoStringLiteral(self.out, self.allocator, n);
        }
        try self.out.appendSlice(self.allocator, "); err != nil {\n\t\treturn err\n\t}\n");
    }

    fn emitElement(self: *Emitter, el: Parser.Element, parent_expr: []const u8) EmitError![]const u8 {
        const var_name = try std.fmt.allocPrint(self.allocator, "{s}{d}", .{ el.tag, self.counter });
        self.counter += 1;

        if (std.mem.eql(u8, el.tag, "Container")) {
            try self.out.appendSlice(self.allocator, "\t");
            try self.out.appendSlice(self.allocator, var_name);
            try self.out.appendSlice(self.allocator, ", err := widgets.CreateContainer(widgets.ParentID(uint32(");
            try self.out.appendSlice(self.allocator, parent_expr);
            try self.out.appendSlice(self.allocator, ")), false, 0)\n\tif err != nil {\n\t\treturn err\n\t}\n");
        } else if (std.mem.eql(u8, el.tag, "Label")) {
            const text = try self.labelText(el);
            try self.out.appendSlice(self.allocator, "\t");
            try self.out.appendSlice(self.allocator, var_name);
            try self.out.appendSlice(self.allocator, ", err := widgets.CreateLabel(widgets.ParentID(uint32(");
            try self.out.appendSlice(self.allocator, parent_expr);
            try self.out.appendSlice(self.allocator, ")), ");
            try writeGoStringLiteral(self.out, self.allocator, text);
            try self.out.appendSlice(self.allocator, ")\n\tif err != nil {\n\t\treturn err\n\t}\n");
        } else {
            return self.fail(el.line, el.col, "widget kind '{s}' is not yet supported by natyv prepare's .ntx codegen", .{el.tag});
        }
        // A leaf widget with no styles/children never references its own
        // id again -- Go rejects a declared-and-unused local outright, so
        // this blank-identifier use is required for real compilability,
        // not just style. Harmless even when the id *is* used again below
        // (ApplyStyle, or as a child's parent_expr) -- Go permits `_ = x`
        // alongside a later real use of the same variable.
        try self.out.appendSlice(self.allocator, "\t_ = ");
        try self.out.appendSlice(self.allocator, var_name);
        try self.out.appendSlice(self.allocator, "\n");

        for (el.attrs) |attr| {
            if (std.mem.eql(u8, attr.name, "styles")) {
                switch (attr.value) {
                    .styles => |names| try self.emitApplyStyle(var_name, names),
                    else => return self.fail(attr.line, attr.col, "dynamic 'styles' expressions aren't supported until Stage 4", .{}),
                }
            } else {
                return self.fail(attr.line, attr.col, "attribute '{s}' isn't supported until Stage 4", .{attr.name});
            }
        }

        if (!std.mem.eql(u8, el.tag, "Label")) {
            for (el.children) |child| {
                switch (child) {
                    .text => return self.fail(el.line, el.col, "<{s}> doesn't accept text content", .{el.tag}),
                    .element => |child_el| _ = try self.emitElement(child_el, var_name),
                }
            }
        }

        return var_name;
    }
};

fn hexDigest(bytes: [32]u8) [64]u8 {
    var out: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{x}", .{bytes}) catch unreachable;
    return out;
}

/// Translates a `Parser`-relative (line, col) -- relative to a composer's
/// own body slice, always starting at (1, 1) -- back to an absolute
/// position in the original file, using the body's own known starting
/// line/col. Correct because a newline resets column to 1 identically in
/// both coordinate systems; only the first relative line needs its column
/// offset by the body's own starting column.
fn translatePosition(body_line: u32, body_col: u32, rel_line: u32, rel_col: u32) struct { line: u32, col: u32 } {
    if (rel_line == 1) return .{ .line = body_line, .col = body_col + rel_col - 1 };
    return .{ .line = body_line + rel_line - 1, .col = rel_col };
}

const Edit = struct {
    start: usize,
    end: usize,
    replacement: []const u8,
};

fn applyEdits(allocator: std.mem.Allocator, src: []const u8, edits: []Edit) ![]const u8 {
    std.mem.sort(Edit, edits, {}, struct {
        fn lessThan(_: void, a: Edit, b: Edit) bool {
            return a.start < b.start;
        }
    }.lessThan);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var cursor: usize = 0;
    for (edits) |edit| {
        try out.appendSlice(allocator, src[cursor..edit.start]);
        try out.appendSlice(allocator, edit.replacement);
        cursor = edit.end;
    }
    try out.appendSlice(allocator, src[cursor..]);
    return out.toOwnedSlice(allocator);
}

pub fn generateGo(allocator: std.mem.Allocator, package_name: []const u8, src: []const u8, composers: []const Expose.Composer) !struct { output: ?Output, err: ?CodegenError } {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(src, &digest, .{});
    const hash_hex = hexDigest(digest);

    var generated: std.ArrayList(u8) = .empty;
    errdefer generated.deinit(allocator);
    try generated.appendSlice(allocator, "// Code generated by natyv prepare. DO NOT EDIT.\n// source-hash: ");
    try generated.appendSlice(allocator, &hash_hex);
    try generated.appendSlice(allocator, "\n\npackage ");
    try generated.appendSlice(allocator, package_name);
    try generated.appendSlice(allocator, "\n\nimport \"natyv/sdk/widgets\"\n");

    var edits: std.ArrayList(Edit) = .empty;
    errdefer edits.deinit(allocator);

    for (composers) |composer| {
        if (!std.mem.eql(u8, composer.return_type, "error")) {
            return .{ .output = null, .err = .{
                .line = composer.line,
                .col = composer.col,
                .message = try std.fmt.allocPrint(allocator, "composer '{s}' must have signature 'func {s}(...) error' (void composers aren't supported yet)", .{ composer.name, composer.name }),
            } };
        }

        var body_parser = Parser.Parser.init(allocator, composer.body);
        const node = body_parser.parseTopLevel() catch |e| {
            if (e == error.ParseError) {
                const perr = body_parser.last_error.?;
                const abs = translatePosition(composer.body_line, composer.body_col, perr.line, perr.col);
                return .{ .output = null, .err = .{ .line = abs.line, .col = abs.col, .message = perr.message } };
            }
            return e;
        };

        try generated.appendSlice(allocator, "\nfunc natyvBuild");
        try generated.appendSlice(allocator, composer.name);
        try generated.appendSlice(allocator, "(");
        try generated.appendSlice(allocator, composer.params);
        try generated.appendSlice(allocator, ") error {\n");

        const param_segments = try splitTopLevelCommas(allocator, composer.params);
        if (param_segments.len == 0) {
            return .{ .output = null, .err = .{
                .line = composer.line,
                .col = composer.col,
                .message = try std.fmt.allocPrint(allocator, "composer '{s}' needs at least one parameter to attach its root element under", .{composer.name}),
            } };
        }
        const parent_name = leadingIdent(param_segments[0]) orelse {
            return .{ .output = null, .err = .{
                .line = composer.line,
                .col = composer.col,
                .message = try std.fmt.allocPrint(allocator, "composer '{s}': could not find a parameter name to attach its root element under", .{composer.name}),
            } };
        };

        var emitter: Emitter = .{ .allocator = allocator, .out = &generated };
        _ = emitter.emitElement(node.element, parent_name) catch |e| {
            if (e == error.CodegenError) {
                const eerr = emitter.err.?;
                const abs = translatePosition(composer.body_line, composer.body_col, eerr.line, eerr.col);
                return .{ .output = null, .err = .{ .line = abs.line, .col = abs.col, .message = eerr.message } };
            }
            return e;
        };
        try generated.appendSlice(allocator, "\treturn nil\n}\n");

        var call_args: std.ArrayList(u8) = .empty;
        for (param_segments, 0..) |seg, i| {
            const name = leadingIdent(seg) orelse return .{ .output = null, .err = .{
                .line = composer.line,
                .col = composer.col,
                .message = try std.fmt.allocPrint(allocator, "composer '{s}': could not find a parameter name in '{s}'", .{ composer.name, seg }),
            } };
            if (i > 0) try call_args.appendSlice(allocator, ", ");
            try call_args.appendSlice(allocator, name);
        }
        // Leading/trailing newline+tab, not a bare statement: `body_start`
        // through `body_end` spans the *entire* original markup including
        // its own surrounding whitespace, so a bare replacement would
        // collapse the whole function body onto one line.
        const call_through = try std.fmt.allocPrint(allocator, "\n\treturn natyvBuild{s}({s})\n", .{ composer.name, try call_args.toOwnedSlice(allocator) });

        try edits.append(allocator, .{ .start = composer.expose_start, .end = composer.expose_end, .replacement = "" });
        try edits.append(allocator, .{ .start = composer.body_start, .end = composer.body_end, .replacement = call_through });
    }

    const logic = try applyEdits(allocator, src, edits.items);
    return .{ .output = .{ .generated = try generated.toOwnedSlice(allocator), .logic = logic }, .err = null };
}

test "generates a builder function and a spliced logic file for a single flat composer" {
    const src =
        \\package main
        \\
        \\expose NavBar
        \\
        \\func NavBar(parent widgets.Container) error {
        \\  <Container styles={nav}>
        \\    <Label>Home</Label>
        \\  </Container>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const found = try Expose.findComposers(allocator, src);
    try std.testing.expect(found.err == null);
    const result = try generateGo(allocator, "main", src, found.composers);
    try std.testing.expect(result.err == null);
    const out = result.output.?;

    try std.testing.expect(std.mem.indexOf(u8, out.generated, "// Code generated by natyv prepare. DO NOT EDIT.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.generated, "// source-hash: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.generated, "func natyvBuildNavBar(parent widgets.Container) error {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.generated, "widgets.CreateContainer(widgets.ParentID(uint32(parent)), false, 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.generated, "widgets.ApplyStyle(uint32(Container0), StyleTokens, \"nav\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.generated, "widgets.CreateLabel(widgets.ParentID(uint32(Container0)), \"Home\")") != null);

    try std.testing.expect(std.mem.indexOf(u8, out.logic, "expose NavBar") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.logic, "<Container") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.logic, "func NavBar(parent widgets.Container) error {\n\treturn natyvBuildNavBar(parent)\n}") != null);
}

test "forwards multiple parameters positionally in the logic file's call-through" {
    const src =
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container, extra int) error {
        \\  <Label>hi</Label>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers);
    try std.testing.expect(result.err == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output.?.generated, "func natyvBuildFoo(parent widgets.Container, extra int) error {") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output.?.logic, "return natyvBuildFoo(parent, extra)") != null);
}

test "rejects a void composer with a clear error" {
    const src =
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) {
        \\  <Label>hi</Label>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers);
    try std.testing.expect(result.output == null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "must have signature") != null);
}

test "rejects an unsupported widget kind with a clear error" {
    const src =
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Slider />
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers);
    try std.testing.expect(result.output == null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "Slider") != null);
}

test "rejects ref (Stage 4's job) with a clear error, translated to an absolute file position" {
    const src =
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Label ref={&x}>hi</Label>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers);
    try std.testing.expect(result.output == null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "ref") != null);
    try std.testing.expectEqual(@as(u32, 4), result.err.?.line);
}

test "rejects <Container> with text content" {
    const src =
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Container>not a label</Container>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers);
    try std.testing.expect(result.output == null);
}

test "multiple composers each get their own generated function and splice" {
    const src =
        \\expose NavBar
        \\expose Footer
        \\
        \\func NavBar(parent widgets.Container) error {
        \\  <Label>Home</Label>
        \\}
        \\
        \\func Footer(parent widgets.Container) error {
        \\  <Label>Copyright</Label>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers);
    try std.testing.expect(result.err == null);
    const out = result.output.?;
    try std.testing.expect(std.mem.indexOf(u8, out.generated, "func natyvBuildNavBar") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.generated, "func natyvBuildFooter") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.logic, "return natyvBuildNavBar(parent)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.logic, "return natyvBuildFooter(parent)") != null);
}
