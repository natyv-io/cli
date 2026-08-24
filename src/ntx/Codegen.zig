//! `.ntx` tooling Stages 3b + 4 (~/.claude/plans/lexical-wishing-penguin.md):
//! codegen + the real two-file split, plus `ref`/event-handler binding.
//! `margin` and cross-file component reuse are still Stages 5/6. Consumes
//! `Expose.zig`'s discovered `Composer`s (each already located and
//! body-bounded) and `Parser.zig`'s tag trees, and emits:
//!
//! - a generated builder file (`DO NOT EDIT`, real `widgets.CreateX(...)`
//!   calls, each preceded by a `<var>Layout := widgets.ParentID(uint32(
//!   ...))` built on the real SDK convenience constructor in
//!   `sdk/go/widgets/layout.go` plus per-tag default `Sizing`/`Direction`/
//!   `Padding`/`ChildGap` assignments -- see `LayoutDefaults` -- one
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
//! **`ref={&target}`** (Stage 4): `target` is a plain identifier naming a
//! package-level `*WidgetType` variable declared by hand elsewhere in the
//! logic file -- `emitRefAssign` assigns `target = &varName` right after
//! creation, giving any handler declared anywhere else in the same file a
//! stable way to read this widget later, the same closed-over-slot
//! property React's own `ref` has.
//!
//! **`on[A-Z]...` attributes** (Stage 4, `onClick`, `onChange`, `onBlur`,
//! ...): bind to the real Go method of the same capitalized name
//! (`onClick` -> `.OnClick(handler)`) via a plain string transform, not a
//! hardcoded per-widget-kind method table -- whether a given widget kind
//! actually *has* that method is deliberately left for Go's own compiler
//! to catch as an undefined-method error, not re-validated here.
//!
//! **Widget-kind scope, still deliberately narrow but grown for Stage 4**:
//! `Container`, `Label`, `Button`, `TextField` -- enough to prove the
//! whole mechanism end-to-end including a real ref-bound `TextField` read
//! by a `Button`'s `onClick` handler. Every other real widget kind still
//! errors clearly (`"widget kind 'X' is not yet supported"`) rather than
//! silently misbehaving; extending this to natyv's ~25 remaining widget
//! kinds is real, same-pattern, incremental follow-up work.
//!
//! `ref`/dynamic `styles` expressions and any other braced attribute are
//! also clear codegen errors here, not silently dropped -- they're Stage
//! 4's job.
//!
//! **Margin-as-wrapper (Stage 5)**: `margin` has no runtime representation
//! anywhere in the SDK on purpose (`widgets.ResolvedStyle` in
//! `sdk/go/widgets/style.go` has no `Margin` field) -- see
//! `styling/Codegen.zig`'s own doc comment: margin was always meant to be
//! prepare-time sugar implemented entirely in this transpiler, once it
//! existed, rather than a hand-written-call-era stopgap. `generateGo` now
//! takes the app's real resolved stylesheet tokens (`Resolver.zig`'s
//! output) so it can look up whether any name in a `styles={...}` list
//! resolves (later-wins, same merge order as `widgets.ApplyStyle` itself)
//! to a non-zero margin -- if so, a wrapper `<Container>` is inserted
//! immediately before the real widget's own create-call, parented exactly
//! where the real widget would have been, with `Padding` set to the
//! margin amount on all four sides and `Sizing` left at its default `Fit`
//! (correct here, unlike a leaf widget's own `Fit` pitfall documented
//! above -- a wrapper's only child already has a real resolved size by the
//! time Clay lays out the wrapper). The wrapper is transparent to
//! everything else: `ref`/event bindings still attach to the real widget's
//! own variable, and the real widget's *children* still parent directly
//! under the real widget, never under its wrapper -- only the real
//! widget's *own* attachment point to its parent moves. An unknown style
//! name contributes no margin here, same as `ApplyStyle`'s own token
//! lookup being a runtime-only concern this codegen doesn't duplicate.

const std = @import("std");
const Parser = @import("Parser.zig");
const Expose = @import("Expose.zig");
const Resolver = @import("Resolver");

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
    style_tokens: []const Resolver.ResolvedStyleToken = &.{},
    counter: u32 = 0,
    err: ?CodegenError = null,

    fn fail(self: *Emitter, line: u32, col: u32, comptime fmt: []const u8, args: anytype) EmitError {
        self.err = .{ .line = line, .col = col, .message = std.fmt.allocPrint(self.allocator, fmt, args) catch fmt };
        return error.CodegenError;
    }

    /// Concatenates every direct text child, erroring on a nested element
    /// -- shared by `Label` and `Button`, both of which take their real
    /// text/label param from child content, not an attribute (matching
    /// every real design-doc example, e.g. `<Button ...>Save</Button>`).
    fn childText(self: *Emitter, el: Parser.Element) EmitError![]const u8 {
        var text: std.ArrayList(u8) = .empty;
        for (el.children) |child| {
            switch (child) {
                .text => |t| try text.appendSlice(self.allocator, t),
                .element => return self.fail(el.line, el.col, "<{s}> doesn't accept nested elements", .{el.tag}),
            }
        }
        return text.toOwnedSlice(self.allocator);
    }

    fn consumesTextChildren(tag: []const u8) bool {
        return std.mem.eql(u8, tag, "Label") or std.mem.eql(u8, tag, "Button");
    }

    /// Looks up a plain (non-braced) string attribute by name -- e.g.
    /// `TextField`'s `placeholder="..."`, a real per-tag constructor
    /// param, not a generic post-creation attribute like `styles`/`ref`/
    /// an event handler. Returns `null` if absent (caller supplies its
    /// own default); errors if present but not a plain string.
    fn stringAttr(self: *Emitter, el: Parser.Element, name: []const u8) EmitError!?[]const u8 {
        for (el.attrs) |attr| {
            if (!std.mem.eql(u8, attr.name, name)) continue;
            switch (attr.value) {
                .string_literal => |s| return s,
                else => return self.fail(attr.line, attr.col, "'{s}' must be a plain string, e.g. {s}=\"...\"", .{ name, name }),
            }
        }
        return null;
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

    /// `ref={&target}` -- `target` (already stripped of its leading `&` by
    /// `Parser`) is a plain identifier naming a package-level `*WidgetType`
    /// variable declared by hand elsewhere in the logic file, untouched by
    /// natyv. Assigning `target = &varName` here is what lets a handler
    /// declared anywhere else in the same file read this widget later --
    /// same "closed-over stable slot" property React's own `ref` has.
    /// Real type mismatches (e.g. a `*widgets.Label` ref on a `<Button>`)
    /// are deliberately left for Go's own compiler to catch -- natyv
    /// doesn't re-implement Go's type checker to pre-validate this.
    fn emitRefAssign(self: *Emitter, target: []const u8, var_name: []const u8) EmitError!void {
        try self.out.appendSlice(self.allocator, "\t");
        try self.out.appendSlice(self.allocator, target);
        try self.out.appendSlice(self.allocator, " = &");
        try self.out.appendSlice(self.allocator, var_name);
        try self.out.appendSlice(self.allocator, "\n");
    }

    /// An `on[A-Z]...` attribute (`onClick`, `onChange`, `onBlur`, ...)
    /// binds to the real Go method of the same name (`onClick` ->
    /// `.OnClick(...)`) -- a plain capitalize-first-letter transform, not
    /// a hardcoded per-widget-kind method table. Whether a given widget
    /// kind actually *has* that method (e.g. `<Label onClick=...>` doesn't)
    /// is deliberately left for Go's own compiler to catch as an undefined-
    /// method error -- natyv doesn't duplicate the SDK's own method set
    /// here just to pre-validate it.
    fn isEventAttr(name: []const u8) bool {
        return name.len > 2 and name[0] == 'o' and name[1] == 'n' and std.ascii.isUpper(name[2]);
    }

    fn emitEventBinding(self: *Emitter, var_name: []const u8, attr_name: []const u8, handler_expr: []const u8) EmitError!void {
        try self.out.appendSlice(self.allocator, "\t");
        try self.out.appendSlice(self.allocator, var_name);
        try self.out.appendSlice(self.allocator, ".On");
        try self.out.append(self.allocator, attr_name[2]); // already uppercase, see isEventAttr
        try self.out.appendSlice(self.allocator, attr_name[3..]);
        try self.out.appendSlice(self.allocator, "(");
        try self.out.appendSlice(self.allocator, handler_expr);
        try self.out.appendSlice(self.allocator, ")\n");
    }

    /// Sensible per-tag layout defaults, applied unconditionally until a
    /// real sizing/layout attribute grammar is designed (not yet -- no
    /// `.ntx` example anywhere authors explicit sizing/padding/direction
    /// today). Real, necessary fix, not cosmetic: every real hand-written
    /// widget in this codebase always sets explicit `Sizing`/`Direction`
    /// -- a bare `widgets.ParentID(...)` Layout leaves every other field
    /// at Go's zero value, which for `Sizing` means both axes `Fit` with
    /// a 0 min (see `sdk/go/widgets/layout.go`'s own `Fit` doc comment:
    /// "leaf widgets ... collapse toward their min size [0] until natyv
    /// has real font-driven text measurement"). Found by actually running
    /// the generated code, not by inspection -- every widget rendered on
    /// top of every other at (0,0) until these defaults were added.
    const LayoutDefaults = struct {
        direction: ?[]const u8 = null, // raw Go expr, e.g. "widgets.TopToBottom"
        child_gap: ?u16 = null,
        padding: ?u16 = null, // uniform on all four sides
        width_fixed: ?f32 = null,
        height_fixed: ?f32 = null,
    };

    fn appendNum(self: *Emitter, comptime fmt: []const u8, value: anytype) EmitError!void {
        var buf: [32]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, .{value}) catch unreachable; // 32 bytes is ample for any u16/f32 here
        try self.out.appendSlice(self.allocator, s);
    }

    /// Emits `<layout_var> := widgets.ParentID(uint32(<parent_expr>))`
    /// plus one assignment statement per non-null `LayoutDefaults` field --
    /// building on the SDK's own real `ParentID` convenience constructor
    /// (see `layout.go`) rather than hand-rolling the pointer-taking
    /// ourselves.
    fn emitLayout(self: *Emitter, layout_var: []const u8, parent_expr: []const u8, d: LayoutDefaults) EmitError!void {
        try self.out.appendSlice(self.allocator, "\t");
        try self.out.appendSlice(self.allocator, layout_var);
        try self.out.appendSlice(self.allocator, " := widgets.ParentID(uint32(");
        try self.out.appendSlice(self.allocator, parent_expr);
        try self.out.appendSlice(self.allocator, "))\n");
        if (d.direction) |dir| {
            try self.out.appendSlice(self.allocator, "\t");
            try self.out.appendSlice(self.allocator, layout_var);
            try self.out.appendSlice(self.allocator, ".Direction = ");
            try self.out.appendSlice(self.allocator, dir);
            try self.out.appendSlice(self.allocator, "\n");
        }
        if (d.child_gap) |g| {
            try self.out.appendSlice(self.allocator, "\t");
            try self.out.appendSlice(self.allocator, layout_var);
            try self.out.appendSlice(self.allocator, ".ChildGap = ");
            try self.appendNum("{d}", g);
            try self.out.appendSlice(self.allocator, "\n");
        }
        if (d.padding) |p| {
            try self.out.appendSlice(self.allocator, "\t");
            try self.out.appendSlice(self.allocator, layout_var);
            try self.out.appendSlice(self.allocator, ".Padding = widgets.Padding{Left: ");
            try self.appendNum("{d}", p);
            try self.out.appendSlice(self.allocator, ", Right: ");
            try self.appendNum("{d}", p);
            try self.out.appendSlice(self.allocator, ", Top: ");
            try self.appendNum("{d}", p);
            try self.out.appendSlice(self.allocator, ", Bottom: ");
            try self.appendNum("{d}", p);
            try self.out.appendSlice(self.allocator, "}\n");
        }
        if (d.width_fixed) |w| {
            const h = d.height_fixed orelse 0;
            try self.out.appendSlice(self.allocator, "\t");
            try self.out.appendSlice(self.allocator, layout_var);
            try self.out.appendSlice(self.allocator, ".Sizing = widgets.Sizing{Width: widgets.Fixed(");
            try self.appendNum("{d}", w);
            try self.out.appendSlice(self.allocator, "), Height: widgets.Fixed(");
            try self.appendNum("{d}", h);
            try self.out.appendSlice(self.allocator, ")}\n");
        }
    }

    /// Looks up the `styles={...}` attribute (if any) and resolves its
    /// names against `self.style_tokens`, later-wins, same merge order
    /// `widgets.ApplyStyle`/`mergeStyles` itself uses -- returns the
    /// resolved margin, or `null` if no name sets one (including when the
    /// attribute is absent, dynamic, or names an unknown token: unknown
    /// names are a runtime `ApplyStyle` concern, not re-validated here).
    fn marginFor(self: *Emitter, el: Parser.Element) ?u16 {
        for (el.attrs) |attr| {
            if (!std.mem.eql(u8, attr.name, "styles")) continue;
            const names = switch (attr.value) {
                .styles => |n| n,
                else => return null,
            };
            var margin: ?u16 = null;
            for (names) |name| {
                for (self.style_tokens) |tok| {
                    if (std.mem.eql(u8, tok.name, name)) {
                        if (tok.margin) |m| margin = m;
                        break;
                    }
                }
            }
            return margin;
        }
        return null;
    }

    /// Inserts a wrapper `<Container>` between `parent_expr` and whatever
    /// real widget is about to be created, giving margin's visual effect
    /// (space *outside* the widget) via `Padding` on a `Fit`-sized
    /// container -- see this file's own doc comment for why `Fit` is
    /// correct here even though it isn't for a bare leaf widget. Returns
    /// the wrapper's own variable name, to use as the real widget's
    /// `parent_expr` in its place.
    fn emitMarginWrapper(self: *Emitter, parent_expr: []const u8, margin: u16) EmitError![]const u8 {
        const wrap_var = try std.fmt.allocPrint(self.allocator, "Margin{d}", .{self.counter});
        self.counter += 1;
        const layout_var = try std.fmt.allocPrint(self.allocator, "{s}Layout", .{wrap_var});
        try self.emitLayout(layout_var, parent_expr, .{ .direction = "widgets.TopToBottom", .child_gap = 0, .padding = margin });
        try self.out.appendSlice(self.allocator, "\t");
        try self.out.appendSlice(self.allocator, wrap_var);
        try self.out.appendSlice(self.allocator, ", err := widgets.CreateContainer(");
        try self.out.appendSlice(self.allocator, layout_var);
        try self.out.appendSlice(self.allocator, ", false, 0)\n\tif err != nil {\n\t\treturn err\n\t}\n\t_ = ");
        try self.out.appendSlice(self.allocator, wrap_var);
        try self.out.appendSlice(self.allocator, "\n");
        return wrap_var;
    }

    fn emitElement(self: *Emitter, el: Parser.Element, parent_expr: []const u8) EmitError![]const u8 {
        var attach_expr = parent_expr;
        if (self.marginFor(el)) |margin| {
            if (margin > 0) attach_expr = try self.emitMarginWrapper(parent_expr, margin);
        }

        const var_name = try std.fmt.allocPrint(self.allocator, "{s}{d}", .{ el.tag, self.counter });
        self.counter += 1;
        const layout_var = try std.fmt.allocPrint(self.allocator, "{s}Layout", .{var_name});
        var skip_attr: ?[]const u8 = null;

        if (std.mem.eql(u8, el.tag, "Container")) {
            try self.emitLayout(layout_var, attach_expr, .{ .direction = "widgets.TopToBottom", .child_gap = 8, .padding = 8 });
            try self.out.appendSlice(self.allocator, "\t");
            try self.out.appendSlice(self.allocator, var_name);
            try self.out.appendSlice(self.allocator, ", err := widgets.CreateContainer(");
            try self.out.appendSlice(self.allocator, layout_var);
            try self.out.appendSlice(self.allocator, ", false, 0)\n\tif err != nil {\n\t\treturn err\n\t}\n");
        } else if (std.mem.eql(u8, el.tag, "Label")) {
            const text = try self.childText(el);
            try self.emitLayout(layout_var, attach_expr, .{ .width_fixed = 300, .height_fixed = 24 });
            try self.out.appendSlice(self.allocator, "\t");
            try self.out.appendSlice(self.allocator, var_name);
            try self.out.appendSlice(self.allocator, ", err := widgets.CreateLabel(");
            try self.out.appendSlice(self.allocator, layout_var);
            try self.out.appendSlice(self.allocator, ", ");
            try writeGoStringLiteral(self.out, self.allocator, text);
            try self.out.appendSlice(self.allocator, ")\n\tif err != nil {\n\t\treturn err\n\t}\n");
        } else if (std.mem.eql(u8, el.tag, "Button")) {
            const text = try self.childText(el);
            try self.emitLayout(layout_var, attach_expr, .{ .width_fixed = 120, .height_fixed = 32 });
            try self.out.appendSlice(self.allocator, "\t");
            try self.out.appendSlice(self.allocator, var_name);
            try self.out.appendSlice(self.allocator, ", err := widgets.CreateButton(");
            try self.out.appendSlice(self.allocator, layout_var);
            try self.out.appendSlice(self.allocator, ", ");
            try writeGoStringLiteral(self.out, self.allocator, text);
            try self.out.appendSlice(self.allocator, ")\n\tif err != nil {\n\t\treturn err\n\t}\n");
        } else if (std.mem.eql(u8, el.tag, "TextField")) {
            const placeholder = (try self.stringAttr(el, "placeholder")) orelse "";
            try self.emitLayout(layout_var, attach_expr, .{ .width_fixed = 240, .height_fixed = 32 });
            try self.out.appendSlice(self.allocator, "\t");
            try self.out.appendSlice(self.allocator, var_name);
            try self.out.appendSlice(self.allocator, ", err := widgets.CreateTextField(");
            try self.out.appendSlice(self.allocator, layout_var);
            try self.out.appendSlice(self.allocator, ", ");
            try writeGoStringLiteral(self.out, self.allocator, placeholder);
            try self.out.appendSlice(self.allocator, ")\n\tif err != nil {\n\t\treturn err\n\t}\n");
            skip_attr = "placeholder";
        } else {
            return self.fail(el.line, el.col, "widget kind '{s}' is not yet supported by natyv prepare's .ntx codegen", .{el.tag});
        }
        // A leaf widget with no styles/children never references its own
        // id again -- Go rejects a declared-and-unused local outright, so
        // this blank-identifier use is required for real compilability,
        // not just style. Harmless even when the id *is* used again below
        // (ApplyStyle, ref, an event binding, or as a child's parent_expr)
        // -- Go permits `_ = x` alongside a later real use of `x`.
        try self.out.appendSlice(self.allocator, "\t_ = ");
        try self.out.appendSlice(self.allocator, var_name);
        try self.out.appendSlice(self.allocator, "\n");

        for (el.attrs) |attr| {
            if (skip_attr != null and std.mem.eql(u8, attr.name, skip_attr.?)) continue;
            if (std.mem.eql(u8, attr.name, "styles")) {
                switch (attr.value) {
                    .styles => |names| try self.emitApplyStyle(var_name, names),
                    else => return self.fail(attr.line, attr.col, "dynamic 'styles' expressions aren't supported until a future stage", .{}),
                }
            } else if (std.mem.eql(u8, attr.name, "ref")) {
                switch (attr.value) {
                    .ref => |target| try self.emitRefAssign(target, var_name),
                    else => return self.fail(attr.line, attr.col, "malformed 'ref' attribute", .{}),
                }
            } else if (isEventAttr(attr.name)) {
                switch (attr.value) {
                    .expr => |handler| try self.emitEventBinding(var_name, attr.name, handler),
                    else => return self.fail(attr.line, attr.col, "'{s}' must be a real handler expression, e.g. {s}={{handleX}}", .{ attr.name, attr.name }),
                }
            } else {
                return self.fail(attr.line, attr.col, "attribute '{s}' isn't supported yet", .{attr.name});
            }
        }

        if (!consumesTextChildren(el.tag)) {
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

pub fn generateGo(allocator: std.mem.Allocator, package_name: []const u8, src: []const u8, composers: []const Expose.Composer, style_tokens: []const Resolver.ResolvedStyleToken) !struct { output: ?Output, err: ?CodegenError } {
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

        var emitter: Emitter = .{ .allocator = allocator, .out = &generated, .style_tokens = style_tokens };
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
    const result = try generateGo(allocator, "main", src, found.composers, &.{});
    try std.testing.expect(result.err == null);
    const out = result.output.?;

    try std.testing.expect(std.mem.indexOf(u8, out.generated, "// Code generated by natyv prepare. DO NOT EDIT.") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.generated, "// source-hash: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.generated, "func natyvBuildNavBar(parent widgets.Container) error {") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.generated, "Container0Layout := widgets.ParentID(uint32(parent))") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.generated, "widgets.CreateContainer(Container0Layout, false, 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.generated, "widgets.ApplyStyle(uint32(Container0), StyleTokens, \"nav\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.generated, "widgets.CreateLabel(Label1Layout, \"Home\")") != null);

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
    const result = try generateGo(allocator, "main", src, found.composers, &.{});
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
    const result = try generateGo(allocator, "main", src, found.composers, &.{});
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
    const result = try generateGo(allocator, "main", src, found.composers, &.{});
    try std.testing.expect(result.output == null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "Slider") != null);
}

test "ref={&x} assigns the created widget's address to the named package-level variable" {
    const src =
        \\expose Form
        \\
        \\func Form(parent widgets.Container) error {
        \\  <TextField ref={&nameField} placeholder="Your name" />
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &.{});
    try std.testing.expect(result.err == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output.?.generated, "widgets.CreateTextField(TextField0Layout, \"Your name\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output.?.generated, "nameField = &TextField0") != null);
}

test "onClick={handler} binds the real .OnClick(...) method, and onClick reads a ref-bound sibling" {
    const src =
        \\expose Form
        \\
        \\func Form(parent widgets.Container) error {
        \\  <Container>
        \\    <TextField ref={&nameField} placeholder="Your name" />
        \\    <Button onClick={handleSave}>Save</Button>
        \\  </Container>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &.{});
    try std.testing.expect(result.err == null);
    const gen = result.output.?.generated;
    try std.testing.expect(std.mem.indexOf(u8, gen, "widgets.CreateButton(Button2Layout, \"Save\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "Button2.OnClick(handleSave)") != null);
}

test "rejects an unrecognized attribute with a clear error, translated to an absolute file position" {
    const src =
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Label bogus={1}>hi</Label>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &.{});
    try std.testing.expect(result.output == null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "bogus") != null);
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
    const result = try generateGo(allocator, "main", src, found.composers, &.{});
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
    const result = try generateGo(allocator, "main", src, found.composers, &.{});
    try std.testing.expect(result.err == null);
    const out = result.output.?;
    try std.testing.expect(std.mem.indexOf(u8, out.generated, "func natyvBuildNavBar") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.generated, "func natyvBuildFooter") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.logic, "return natyvBuildNavBar(parent)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.logic, "return natyvBuildFooter(parent)") != null);
}

test "styles naming a token with margin inserts a wrapper Container, transparent to the real widget's own var name" {
    const src =
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Label styles={card}>hi</Label>
        \\}
    ;
    const tokens = [_]Resolver.ResolvedStyleToken{.{ .name = "card", .margin = 12 }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &tokens);
    try std.testing.expect(result.err == null);
    const gen = result.output.?.generated;
    try std.testing.expect(std.mem.indexOf(u8, gen, "Margin0Layout := widgets.ParentID(uint32(parent))") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "Margin0Layout.Padding = widgets.Padding{Left: 12, Right: 12, Top: 12, Bottom: 12}") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "Margin0, err := widgets.CreateContainer(Margin0Layout, false, 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "Label1Layout := widgets.ParentID(uint32(Margin0))") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "widgets.CreateLabel(Label1Layout, \"hi\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "widgets.ApplyStyle(uint32(Label1), StyleTokens, \"card\")") != null);
}

test "a token with no margin never inserts a wrapper" {
    const src =
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Label styles={plain}>hi</Label>
        \\}
    ;
    const tokens = [_]Resolver.ResolvedStyleToken{.{ .name = "plain", .padding = 4 }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &tokens);
    try std.testing.expect(result.err == null);
    const gen = result.output.?.generated;
    try std.testing.expect(std.mem.indexOf(u8, gen, "widgets.CreateContainer") == null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "Label0Layout := widgets.ParentID(uint32(parent))") != null);
}

test "an unknown style name contributes no margin and causes no error" {
    const src =
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Label styles={mystery}>hi</Label>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &.{});
    try std.testing.expect(result.err == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output.?.generated, "widgets.CreateContainer") == null);
}

test "later-wins margin resolution across multiple style names, matching ApplyStyle's own merge order" {
    const src =
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Label styles={a, b}>hi</Label>
        \\}
    ;
    const tokens = [_]Resolver.ResolvedStyleToken{
        .{ .name = "a", .margin = 4 },
        .{ .name = "b", .margin = 20 },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &tokens);
    try std.testing.expect(result.err == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output.?.generated, "Margin0Layout.Padding = widgets.Padding{Left: 20, Right: 20, Top: 20, Bottom: 20}") != null);
}

test "nested margins produce a two-level wrapper chain, and ref still binds the real inner widget" {
    const src =
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Container styles={outer}>
        \\    <TextField ref={&nameField} styles={inner} placeholder="hi" />
        \\  </Container>
        \\}
    ;
    const tokens = [_]Resolver.ResolvedStyleToken{
        .{ .name = "outer", .margin = 8 },
        .{ .name = "inner", .margin = 4 },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &tokens);
    try std.testing.expect(result.err == null);
    const gen = result.output.?.generated;
    // Outer wrapper attaches to the composer's own parent param.
    try std.testing.expect(std.mem.indexOf(u8, gen, "Margin0Layout := widgets.ParentID(uint32(parent))") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "Margin0Layout.Padding = widgets.Padding{Left: 8, Right: 8, Top: 8, Bottom: 8}") != null);
    // The real outer Container attaches to that wrapper, not directly to parent.
    try std.testing.expect(std.mem.indexOf(u8, gen, "Container1Layout := widgets.ParentID(uint32(Margin0))") != null);
    // The inner wrapper attaches to the real outer Container.
    try std.testing.expect(std.mem.indexOf(u8, gen, "Margin2Layout := widgets.ParentID(uint32(Container1))") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "Margin2Layout.Padding = widgets.Padding{Left: 4, Right: 4, Top: 4, Bottom: 4}") != null);
    // The real TextField attaches to the inner wrapper, and ref still names the real widget.
    try std.testing.expect(std.mem.indexOf(u8, gen, "TextField3Layout := widgets.ParentID(uint32(Margin2))") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "nameField = &TextField3") != null);
}
