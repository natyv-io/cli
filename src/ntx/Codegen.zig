//! `.ntx` tooling Stages 3b-6a (~/.claude/plans/lexical-wishing-penguin.md):
//! codegen + the real two-file split, `ref`/event-handler binding,
//! margin-as-wrapper, and component-tag calls. Consumes
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
//!
//! **Component reuse (Stage 6a)**: a tag that isn't a built-in widget
//! kind is a call to another exposed composer, not an error, *if* it's
//! recognizable as one -- see `Emitter.isComponentTag`. All component
//! tags are bare names now: a `uses (...)` header block (parsed by
//! `Expose.zig`, see `Expose.UseImport`) declares which bare names come
//! from which external package (`uses ( { Card, UserCard } from
//! "some/pkg" ) `), and a bare tag is also accepted if it matches one of
//! the current file's own `expose`d composers (same-package, no `uses`
//! entry needed) -- otherwise it stays the existing clear "not supported"
//! error, worded to mention the composer possibility too. **This
//! replaces an earlier design where a dotted tag name
//! (`<components.Card/>`) encoded its own package directly** -- removed
//! after Quinn's own real-world feedback on the first working fixture:
//! resolving an import path *inside a tag name* is the wrong shape (real
//! JSX/TS-family frameworks never do this either, always preferring a
//! declared import). True cross-file-same-package reuse via a bare name
//! with no `uses` entry still isn't supported -- Codegen only ever sees
//! one file's own composers at a time, since `natyv prepare` doesn't scan
//! a directory yet (Stage 7); use a `uses` entry for now even for what
//! will eventually be the same package. A composer meant to be called
//! this way must declare its own leading parameter as plain `uint32`
//! (`sdk/go/widgets/builder.go`'s new `Builder` type uses the same
//! convention) -- the call site always casts with `uint32(...)`, so a
//! `widgets.Container`-typed leading parameter is a real, Go-compiler-
//! caught mismatch, deliberately not pre-validated here. A `uses`-bound
//! tag's call site is qualified with its resolved package (the import
//! path's last `/`-separated segment, e.g. `components.Card(...)`), and
//! the generated file's own `import` block gains exactly the distinct
//! `uses` paths actually referenced by some component-tag call anywhere
//! in the file -- no more (Go hard-errors on an unused import), no less
//! (deferred until every composer body is emitted, see `generateGo`'s own
//! two-buffer structure). Attributes forward positionally as call
//! arguments (string literals quoted, braced values passed through
//! verbatim, including an `on[A-Z]`-named one -- that convention only
//! binds a real `.OnXxx` method on an actual widget tag, so on a
//! component tag it's just an ordinary forwarded prop, e.g.
//! `onTap={handleTap}`); `ref` is the one explicit error (no widget id
//! here to bind to); `styles` is consumed only for its margin-wrapping
//! effect, never forwarded or passed to `ApplyStyle`. Children compile to
//! a trailing `widgets.Builder` closure argument.
//!
//! **`<children/>` slot tag (Stage 6a)**: inside any composer's own
//! markup, a self-closing `<children/>` compiles to a direct call to a
//! real Go identifier literally named `children` (the composer author's
//! own parameter, conventionally `widgets.Builder`-typed, not
//! structurally checked here). A fixed, reserved single-slot name, not a
//! general "match any Builder-typed parameter" mechanism -- same
//! simplification React's own `props.children` convention makes (a
//! fixed name, not independently validated by JSX itself either). No
//! attributes, no children of its own -- see `emitChildrenSlot`.

const std = @import("std");
const Parser = @import("Parser");
const Expose = @import("Expose");
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
    /// `<Image src="...">` sugar (2026-08-26): resolved by `Prepare.zig`'s
    /// own pre-scan + asset-staging pass *before* this file's own real
    /// transpile pass runs, so every `src` value reaching `emitElement` is
    /// already guaranteed staged with a real id -- see that file's own doc
    /// comment for why this can't be resolved lazily here.
    image_texture_ids: std.StringHashMapUnmanaged(u32) = .{},
    /// Names of every composer `expose`d in the file currently being
    /// processed (Stage 6a) -- lets a bare, non-builtin tag be recognized
    /// as a same-file component call rather than an unsupported widget
    /// kind -- see `isComponentTag`.
    composers: []const []const u8 = &.{},
    /// `uses (...)` bindings from this file's own header (Stage 6a,
    /// confirmed 2026-08-24 -- replaces an earlier, since-removed design
    /// where a component's package was encoded directly in a dotted tag
    /// name like `<components.Card/>`; markup now only ever writes bare
    /// tag names, resolved against this list instead). See
    /// `resolveUsesPath`/`emitComponentCall`.
    uses: []const Expose.UseImport = &.{},
    /// Shared across every `Emitter` for this file (including nested ones
    /// created for a `widgets.Builder` closure body, which copy this
    /// pointer from `self`) -- every `uses` path actually referenced by a
    /// component-tag call, so `generateGo` can build the generated file's
    /// own `import` block with exactly what's needed, no more and no less
    /// (Go hard-errors on an unused import).
    used_paths: *std.ArrayList([]const u8),
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

    /// `<Image src="...">` sugar: merges `names` (any `styles={...}` also
    /// present on the tag) exactly like `emitApplyStyle`, then overrides
    /// just the merged result's `TextureID` with `texture_id` -- `src`
    /// always wins over whatever `texture` (if any) the named tokens
    /// themselves carry, per Quinn's own explicit call; every other merged
    /// field from `names` is untouched. `names` may be empty (a bare
    /// `<Image src="..."/>` with no `styles=` at all still needs its
    /// texture applied).
    fn emitApplyStyleWithTexture(self: *Emitter, var_name: []const u8, names: [][]const u8, texture_id: u32) EmitError!void {
        try self.out.appendSlice(self.allocator, "\tif err := widgets.ApplyStyleWithTexture(uint32(");
        try self.out.appendSlice(self.allocator, var_name);
        try self.out.appendSlice(self.allocator, "), StyleTokens, ");
        var buf: [10]u8 = undefined;
        const id_str = std.fmt.bufPrint(&buf, "{d}", .{texture_id}) catch unreachable;
        try self.out.appendSlice(self.allocator, id_str);
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

    fn isBuiltinWidgetKind(tag: []const u8) bool {
        return std.mem.eql(u8, tag, "Container") or std.mem.eql(u8, tag, "Label") or std.mem.eql(u8, tag, "Button") or std.mem.eql(u8, tag, "TextField") or std.mem.eql(u8, tag, "Image");
    }

    /// Stage 6a (component reuse), bare-name resolution only -- an
    /// earlier design let a dotted tag (`<components.Card/>`) encode its
    /// own package directly, but Quinn's own real-world feedback after
    /// seeing the first fixture run was that resolving a path *inside a
    /// tag name* is the wrong shape (real JSX/TS never does this either);
    /// `uses (...)` replaces it with a declared import block, so markup
    /// only ever writes bare tag names. A bare tag is a component call if
    /// it names either a `uses`-imported component (cross-package) or one
    /// of `self.composers` (the current file's own exposed composers,
    /// same-package). A bare tag matching neither, nor a builtin widget
    /// kind, stays the existing clear "not supported" error below --
    /// natyv can't see another `.ntx` file's own composers yet (that
    /// needs `natyv prepare`'s not-yet-built directory scan, Stage 7), so
    /// true cross-file-same-package reuse via a bare name with no `uses`
    /// entry isn't distinguishable from a typo today.
    fn isComponentTag(self: *Emitter, tag: []const u8) bool {
        if (isBuiltinWidgetKind(tag)) return false;
        if (self.resolveUsesPath(tag) != null) return true;
        for (self.composers) |name| {
            if (std.mem.eql(u8, name, tag)) return true;
        }
        return false;
    }

    /// Looks up a bare tag name against this file's own `uses (...)`
    /// bindings, returning its import path if found.
    fn resolveUsesPath(self: *Emitter, tag: []const u8) ?[]const u8 {
        for (self.uses) |u| {
            if (std.mem.eql(u8, u.name, tag)) return u.path;
        }
        return null;
    }

    /// The real Go package qualifier a `uses` path resolves to at the
    /// call site -- its last `/`-separated segment, matching plain Go
    /// convention (no import alias support in `uses` yet; a package whose
    /// real `package X` name differs from its directory's last segment is
    /// an accepted, documented v1 gap, not handled here).
    fn lastPathSegment(path: []const u8) []const u8 {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
        return path;
    }

    /// Records `path` as needed by the generated file's own `import`
    /// block (deduped) -- see `used_paths`'s own doc comment.
    fn recordUsedPath(self: *Emitter, path: []const u8) EmitError!void {
        for (self.used_paths.items) |p| {
            if (std.mem.eql(u8, p, path)) return;
        }
        try self.used_paths.append(self.allocator, path);
    }

    /// A tag that isn't a built-in widget kind is a call to another
    /// exposed composer (see `isComponentTag`). The composer being
    /// called must declare its own leading parameter as plain `uint32`,
    /// not `widgets.Container` -- the call site always casts with
    /// `uint32(...)`, same as `emitLayout` already does for every
    /// widget's own parent id (matches `widgets.Builder`'s own
    /// convention, see `sdk/go/widgets/builder.go`); a
    /// `widgets.Container`-typed leading parameter is a real, Go-
    /// compiler-caught type mismatch here, deliberately not
    /// pre-validated natyv-side, same "let the host compiler catch it"
    /// posture as `ref`/event-attribute binding.
    ///
    /// Attributes forward positionally as plain call arguments in
    /// declaration order (string literals quoted, braced values passed
    /// through verbatim) -- including one named `onSomething`: the
    /// `on[A-Z]` event-binding convention only applies to a real widget
    /// tag's own attributes (there's a real `.OnXxx` method to call
    /// there); on a component tag it's just an ordinary prop name, e.g.
    /// `onTap={handleTap}` forwarding a plain `func() error` value for
    /// the *component's own* markup to bind however it likes. `ref` is
    /// the one explicit error -- there's no widget id here for it to
    /// bind to. `styles` is consumed only for its already-applied
    /// margin-wrapping effect (see `marginFor`/`emitMarginWrapper` in
    /// `emitElement`) and never forwarded as an arg or passed to
    /// `ApplyStyle` -- a styled component's own internal widgets are
    /// that component's own business, not something this call site has a
    /// widget id to target. Children (if any) compile to a trailing
    /// `widgets.Builder` closure argument, appended after every other
    /// prop.
    fn emitComponentCall(self: *Emitter, el: Parser.Element, parent_expr: []const u8) EmitError![]const u8 {
        var call_target: []const u8 = el.tag;
        if (self.resolveUsesPath(el.tag)) |path| {
            try self.recordUsedPath(path);
            call_target = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ lastPathSegment(path), el.tag });
        }

        var args: std.ArrayList(u8) = .empty;
        for (el.attrs) |attr| {
            switch (attr.value) {
                .ref => return self.fail(attr.line, attr.col, "'ref' isn't supported on component tag <{s}> -- a component call has no widget id of its own to bind", .{el.tag}),
                .styles => {},
                .string_literal => |s| {
                    if (args.items.len > 0) try args.appendSlice(self.allocator, ", ");
                    try writeGoStringLiteral(&args, self.allocator, s);
                },
                .expr => |e| {
                    if (args.items.len > 0) try args.appendSlice(self.allocator, ", ");
                    try args.appendSlice(self.allocator, e);
                },
            }
        }

        if (el.children.len > 0) {
            const child_var = try std.fmt.allocPrint(self.allocator, "p{d}", .{self.counter});
            self.counter += 1;
            var body: std.ArrayList(u8) = .empty;
            var child_emitter: Emitter = .{ .allocator = self.allocator, .out = &body, .style_tokens = self.style_tokens, .composers = self.composers, .uses = self.uses, .used_paths = self.used_paths, .counter = self.counter, .image_texture_ids = self.image_texture_ids };
            for (el.children) |child| {
                switch (child) {
                    .text => return self.fail(el.line, el.col, "<{s}> doesn't accept text content -- a component tag's children become its widgets.Builder callback", .{el.tag}),
                    .element => |child_el| _ = child_emitter.emitElement(child_el, child_var) catch |e| {
                        self.err = child_emitter.err;
                        return e;
                    },
                }
            }
            self.counter = child_emitter.counter;

            if (args.items.len > 0) try args.appendSlice(self.allocator, ", ");
            try args.appendSlice(self.allocator, "func(");
            try args.appendSlice(self.allocator, child_var);
            try args.appendSlice(self.allocator, " uint32) error {\n");
            try args.appendSlice(self.allocator, body.items);
            try args.appendSlice(self.allocator, "\treturn nil\n\t}");
        }

        try self.out.appendSlice(self.allocator, "\tif err := ");
        try self.out.appendSlice(self.allocator, call_target);
        try self.out.appendSlice(self.allocator, "(uint32(");
        try self.out.appendSlice(self.allocator, parent_expr);
        try self.out.appendSlice(self.allocator, ")");
        if (args.items.len > 0) {
            try self.out.appendSlice(self.allocator, ", ");
            try self.out.appendSlice(self.allocator, args.items);
        }
        try self.out.appendSlice(self.allocator, "); err != nil {\n\t\treturn err\n\t}\n");

        return el.tag;
    }

    /// `<children/>` -- a fixed, reserved slot tag (Stage 6a), not a
    /// general "match against any Builder-typed parameter" mechanism:
    /// the composer author must declare a real parameter literally named
    /// `children` (conventionally `widgets.Builder`-typed, not
    /// structurally checked here -- same "let Go's compiler catch it"
    /// posture as everywhere else in this file). Compiles to a direct
    /// call to that identifier, parented at whatever `attach_expr`
    /// margin-wrapping already resolved to. Self-closing only -- it has
    /// no natural meaning for attributes (there's no widget id to apply
    /// them to) or its own children (its whole purpose is rendering the
    /// *caller's* content, not authoring new content of its own).
    fn emitChildrenSlot(self: *Emitter, el: Parser.Element, parent_expr: []const u8) EmitError![]const u8 {
        if (el.attrs.len > 0) return self.fail(el.line, el.col, "<children/> doesn't accept attributes -- it's a fixed slot for the composer's own 'children widgets.Builder' parameter", .{});
        if (el.children.len > 0) return self.fail(el.line, el.col, "<children/> doesn't accept its own children -- it renders the composer's caller-supplied content", .{});
        try self.out.appendSlice(self.allocator, "\tif err := children(uint32(");
        try self.out.appendSlice(self.allocator, parent_expr);
        try self.out.appendSlice(self.allocator, ")); err != nil {\n\t\treturn err\n\t}\n");
        return "children";
    }

    fn emitElement(self: *Emitter, el: Parser.Element, parent_expr: []const u8) EmitError![]const u8 {
        var attach_expr = parent_expr;
        if (self.marginFor(el)) |margin| {
            if (margin > 0) attach_expr = try self.emitMarginWrapper(parent_expr, margin);
        }

        if (std.mem.eql(u8, el.tag, "children")) return self.emitChildrenSlot(el, attach_expr);
        if (self.isComponentTag(el.tag)) return self.emitComponentCall(el, attach_expr);

        const var_name = try std.fmt.allocPrint(self.allocator, "{s}{d}", .{ el.tag, self.counter });
        self.counter += 1;
        const layout_var = try std.fmt.allocPrint(self.allocator, "{s}Layout", .{var_name});
        var skip_attr: ?[]const u8 = null;
        var is_image_tag = false;
        var image_texture_id: u32 = undefined;
        var image_styles_emitted = false;

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
        } else if (std.mem.eql(u8, el.tag, "Image")) {
            // `background: true` (not false) is required -- Container's
            // own fillRect() dispatch returns null entirely when
            // background is false, which would silently skip drawStyledFill
            // (and therefore the texture itself) regardless of any style
            // applied below. A real gotcha found the hard way wiring up
            // examples/clay-fixture's own demo -- see that fixture's own
            // commit message and natyv_styling_system memory.
            if (el.children.len > 0) return self.fail(el.line, el.col, "<Image> doesn't accept children -- it renders its own src, nothing else", .{});
            const src = (try self.stringAttr(el, "src")) orelse return self.fail(el.line, el.col, "<Image> requires a src=\"...\" attribute", .{});
            image_texture_id = self.image_texture_ids.get(src) orelse return self.fail(el.line, el.col, "image asset \"{s}\" was never staged -- this shouldn't happen if natyv prepare's own pre-scan ran first", .{src});
            is_image_tag = true;
            // A leaf widget like Label/Button, not a layout container --
            // 300x200 is a plain, reasonable default "image box" size
            // (no real sizing/layout attribute grammar exists yet, see the
            // LayoutDefaults doc comment above), not a real design.
            try self.emitLayout(layout_var, attach_expr, .{ .width_fixed = 300, .height_fixed = 200 });
            try self.out.appendSlice(self.allocator, "\t");
            try self.out.appendSlice(self.allocator, var_name);
            try self.out.appendSlice(self.allocator, ", err := widgets.CreateContainer(");
            try self.out.appendSlice(self.allocator, layout_var);
            try self.out.appendSlice(self.allocator, ", true, 0)\n\tif err != nil {\n\t\treturn err\n\t}\n");
            skip_attr = "src";
        } else {
            return self.fail(el.line, el.col, "'{s}' isn't a supported widget kind, and no composer named '{s}' is exposed in this file", .{ el.tag, el.tag });
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
                    .styles => |names| {
                        if (is_image_tag) {
                            try self.emitApplyStyleWithTexture(var_name, names, image_texture_id);
                            image_styles_emitted = true;
                        } else {
                            try self.emitApplyStyle(var_name, names);
                        }
                    },
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
        // A bare <Image src="..."/> with no styles={} attribute at all
        // still needs its texture applied -- the branch above only fires
        // when a real 'styles' attribute is present on the tag.
        if (is_image_tag and !image_styles_emitted) {
            try self.emitApplyStyleWithTexture(var_name, &.{}, image_texture_id);
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

/// The exact hex digest `generateGo` embeds as `// source-hash: <hex>` in
/// every generated file's header -- exported so Stage 7's `natyv build`
/// staleness check (hard-error if a `.ntx` source's current hash diverges
/// from what its already-generated output embeds) computes the *same*
/// hash over the *current* source bytes, not a reimplementation that
/// could silently drift from this one.
pub fn sourceHashHex(src: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(src, &digest, .{});
    return hexDigest(digest);
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

pub fn generateGo(allocator: std.mem.Allocator, package_name: []const u8, src: []const u8, composers: []const Expose.Composer, style_tokens: []const Resolver.ResolvedStyleToken, uses: []const Expose.UseImport, uses_start: usize, uses_end: usize, image_texture_ids: std.StringHashMapUnmanaged(u32)) !struct { output: ?Output, err: ?CodegenError } {
    const hash_hex = sourceHashHex(src);

    for (uses) |u| {
        if (Emitter.isBuiltinWidgetKind(u.name)) {
            return .{ .output = null, .err = .{
                .line = u.line,
                .col = u.col,
                .message = try std.fmt.allocPrint(allocator, "'{s}' can't be imported via 'uses' -- it's already a built-in widget kind name", .{u.name}),
            } };
        }
    }

    // Composer bodies are built into their own buffer, separate from the
    // final header -- the header's own `import` block can't be written
    // until every composer's body has actually been emitted, since only
    // then do we know which `uses` paths a component-tag call actually
    // touched (see `Emitter.used_paths`). Emitting straight into one
    // combined buffer, as earlier stages did, would require the fixed
    // `import "natyv/sdk/widgets"` line to be written before any `uses`
    // path could be known to be needed.
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);

    var edits: std.ArrayList(Edit) = .empty;
    errdefer edits.deinit(allocator);

    // `uses (...)` is `.ntx`-only syntax, not real Go -- it must be
    // spliced out of the logic file exactly like each composer's own
    // `expose Name` line below, or the logic file would contain literal
    // invalid Go (a real bug caught by actually compiling the real
    // examples/ntx-components fixture, not by inspection).
    if (uses_end > uses_start) try edits.append(allocator, .{ .start = uses_start, .end = uses_end, .replacement = "" });

    // Stage 6a: the plain names of every composer exposed in this file,
    // so a bare non-builtin tag can be recognized as a same-file
    // component call -- see `Emitter.isComponentTag`.
    var composer_names: std.ArrayList([]const u8) = .empty;
    errdefer composer_names.deinit(allocator);
    for (composers) |c| try composer_names.append(allocator, c.name);

    // Every `uses` path actually referenced by a component-tag call
    // anywhere in this file's composers, shared across every `Emitter`
    // instance (including nested ones created for a `widgets.Builder`
    // closure body in `emitComponentCall`) so the final header's
    // `import` block names exactly what's used, no more and no less.
    var used_paths: std.ArrayList([]const u8) = .empty;
    errdefer used_paths.deinit(allocator);

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

        try body.appendSlice(allocator, "\nfunc natyvBuild");
        try body.appendSlice(allocator, composer.name);
        try body.appendSlice(allocator, "(");
        try body.appendSlice(allocator, composer.params);
        try body.appendSlice(allocator, ") error {\n");

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

        var emitter: Emitter = .{ .allocator = allocator, .out = &body, .style_tokens = style_tokens, .composers = composer_names.items, .uses = uses, .used_paths = &used_paths, .image_texture_ids = image_texture_ids };
        _ = emitter.emitElement(node.element, parent_name) catch |e| {
            if (e == error.CodegenError) {
                const eerr = emitter.err.?;
                const abs = translatePosition(composer.body_line, composer.body_col, eerr.line, eerr.col);
                return .{ .output = null, .err = .{ .line = abs.line, .col = abs.col, .message = eerr.message } };
            }
            return e;
        };
        try body.appendSlice(allocator, "\treturn nil\n}\n");

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

    var generated: std.ArrayList(u8) = .empty;
    errdefer generated.deinit(allocator);
    try generated.appendSlice(allocator, "// Code generated by natyv prepare. DO NOT EDIT.\n// source-hash: ");
    try generated.appendSlice(allocator, &hash_hex);
    try generated.appendSlice(allocator, "\n\npackage ");
    try generated.appendSlice(allocator, package_name);
    try generated.appendSlice(allocator, "\n\n");
    // `natyv/sdk/widgets` is included only if `body` actually references
    // it -- real, necessary since Stage 6a made it possible for a
    // composer's entire body to be nothing but a bare component-tag call
    // (e.g. `<children/>`) that never touches a real widget kind, which
    // would otherwise get an unconditional, unused `widgets` import and
    // fail real `go build`/`tinygo build` with "imported and not used"
    // (a real bug found this way, not by inspection). A plain substring
    // search over the already-fully-emitted `body` -- rather than a
    // hand-tracked flag threaded through every call site that might emit
    // `widgets.` (`emitLayout`, `emitApplyStyle`, and any composer's own
    // verbatim-copied signature text, e.g. `children widgets.Builder`,
    // which Codegen never structurally parses) -- catches every real
    // case in one place, at the cost of a narrow, accepted false-positive
    // risk: a widget's own literal text content coincidentally containing
    // the substring "widgets." (e.g. a Label reading "our widgets. Now!")
    // would reintroduce the same unused-import failure in that one rare
    // case. Same "acceptable v1 simplification" posture as `Expose.zig`'s
    // own literal `func Name(` text-match already accepts.
    const uses_widgets = std.mem.indexOf(u8, body.items, "widgets.") != null;

    var all_imports: std.ArrayList([]const u8) = .empty;
    if (uses_widgets) try all_imports.append(allocator, "natyv/sdk/widgets");
    try all_imports.appendSlice(allocator, used_paths.items);

    if (all_imports.items.len == 1) {
        try generated.appendSlice(allocator, "import ");
        try writeGoStringLiteral(&generated, allocator, all_imports.items[0]);
        try generated.appendSlice(allocator, "\n");
    } else if (all_imports.items.len > 1) {
        try generated.appendSlice(allocator, "import (\n");
        for (all_imports.items) |p| {
            try generated.appendSlice(allocator, "\t");
            try writeGoStringLiteral(&generated, allocator, p);
            try generated.appendSlice(allocator, "\n");
        }
        try generated.appendSlice(allocator, ")\n");
    }
    try generated.appendSlice(allocator, body.items);

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
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, .{});
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
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, .{});
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
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, .{});
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
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, .{});
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
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, .{});
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
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, .{});
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
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, .{});
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
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, .{});
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
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, .{});
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
    const result = try generateGo(allocator, "main", src, found.composers, &tokens, &.{}, 0, 0, .{});
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
    const result = try generateGo(allocator, "main", src, found.composers, &tokens, &.{}, 0, 0, .{});
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
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, .{});
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
    const result = try generateGo(allocator, "main", src, found.composers, &tokens, &.{}, 0, 0, .{});
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
    const result = try generateGo(allocator, "main", src, found.composers, &tokens, &.{}, 0, 0, .{});
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

test "a bare tag matching a same-file exposed composer compiles to a direct component call" {
    const src =
        \\expose Header
        \\expose Page
        \\
        \\func Header(parent uint32) error {
        \\  <Label>Hi</Label>
        \\}
        \\
        \\func Page(parent widgets.Container) error {
        \\  <Header/>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, .{});
    try std.testing.expect(result.err == null);
    const gen = result.output.?.generated;
    try std.testing.expect(std.mem.indexOf(u8, gen, "func natyvBuildHeader(parent uint32) error {") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "if err := Header(uint32(parent)); err != nil {\n\t\treturn err\n\t}\n") != null);
}

test "a bare tag resolved via 'uses' compiles to a qualified cross-package component call, and the import gets added" {
    const src =
        \\uses (
        \\  { UserCard } from "natyv/ntx-components-guest/components"
        \\)
        \\
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <UserCard name="Bob" age={user.Age} />
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    try std.testing.expect(found.err == null);
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, found.uses, found.uses_start, found.uses_end, .{});
    try std.testing.expect(result.err == null);
    const gen = result.output.?.generated;
    try std.testing.expect(std.mem.indexOf(u8, gen, "import (\n\t\"natyv/sdk/widgets\"\n\t\"natyv/ntx-components-guest/components\"\n)\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "if err := components.UserCard(uint32(parent), \"Bob\", user.Age); err != nil {\n\t\treturn err\n\t}\n") != null);
    // The `uses (...)` block is .ntx-only syntax -- a real bug (caught by
    // actually compiling examples/ntx-components) had it survive into the
    // logic file as literal invalid Go. It must be spliced out exactly
    // like `expose Foo` is.
    try std.testing.expect(std.mem.indexOf(u8, result.output.?.logic, "uses (") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output.?.logic, "UserCard") == null);
}

test "two 'uses'-bound tags sharing one path only add that import once" {
    const src =
        \\uses (
        \\  { Card, UserCard } from "natyv/ntx-components-guest/components"
        \\)
        \\
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Container>
        \\    <UserCard/>
        \\    <Card><Label>hi</Label></Card>
        \\  </Container>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, found.uses, found.uses_start, found.uses_end, .{});
    try std.testing.expect(result.err == null);
    const gen = result.output.?.generated;
    var count: usize = 0;
    var idx: usize = 0;
    while (std.mem.indexOfPos(u8, gen, idx, "natyv/ntx-components-guest/components")) |found_idx| {
        count += 1;
        idx = found_idx + 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expect(std.mem.indexOf(u8, gen, "components.UserCard(uint32(Container0))") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "components.Card(uint32(Container0), func(") != null);
}

test "a component tag not referenced by any composer body adds no unused import" {
    const src =
        \\uses (
        \\  { UserCard } from "natyv/ntx-components-guest/components"
        \\)
        \\
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Label>hi</Label>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, found.uses, found.uses_start, found.uses_end, .{});
    try std.testing.expect(result.err == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output.?.generated, "import \"natyv/sdk/widgets\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output.?.generated, "components") == null);
}

test "children of a 'uses'-bound component tag compile to a trailing widgets.Builder closure" {
    const src =
        \\uses (
        \\  { Card } from "natyv/ntx-components-guest/components"
        \\)
        \\
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Card>
        \\    <Label>hi</Label>
        \\  </Card>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, found.uses, found.uses_start, found.uses_end, .{});
    try std.testing.expect(result.err == null);
    const gen = result.output.?.generated;
    try std.testing.expect(std.mem.indexOf(u8, gen, "if err := components.Card(uint32(parent), func(p0 uint32) error {") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "widgets.CreateLabel(Label1Layout, \"hi\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "Label1Layout := widgets.ParentID(uint32(p0))") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "\treturn nil\n\t}); err != nil {\n\t\treturn err\n\t}\n") != null);
}

test "ref on a component tag is a clear error, not silently dropped" {
    const src =
        \\uses (
        \\  { UserCard } from "natyv/ntx-components-guest/components"
        \\)
        \\
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <UserCard ref={&x} />
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, found.uses, found.uses_start, found.uses_end, .{});
    try std.testing.expect(result.output == null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "ref") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "component tag") != null);
}

test "an onXxx-named attribute on a component tag forwards as a plain prop, not a widget event binding" {
    const src =
        \\uses (
        \\  { UserCard } from "natyv/ntx-components-guest/components"
        \\)
        \\
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <UserCard onTap={handleTap} />
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, found.uses, found.uses_start, found.uses_end, .{});
    try std.testing.expect(result.err == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output.?.generated, "if err := components.UserCard(uint32(parent), handleTap); err != nil {\n\t\treturn err\n\t}\n") != null);
}

test "styles on a component tag only applies its margin-wrapping effect, never forwarded as an arg" {
    const src =
        \\uses (
        \\  { Card } from "natyv/ntx-components-guest/components"
        \\)
        \\
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Card styles={spacer}>
        \\    <Label>hi</Label>
        \\  </Card>
        \\}
    ;
    const tokens = [_]Resolver.ResolvedStyleToken{.{ .name = "spacer", .margin = 16 }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &tokens, found.uses, found.uses_start, found.uses_end, .{});
    try std.testing.expect(result.err == null);
    const gen = result.output.?.generated;
    try std.testing.expect(std.mem.indexOf(u8, gen, "Margin0Layout.Padding = widgets.Padding{Left: 16, Right: 16, Top: 16, Bottom: 16}") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "if err := components.Card(uint32(Margin0), func(") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "\"spacer\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "ApplyStyle") == null);
}

test "a 'uses' name colliding with a built-in widget kind is a clear error" {
    const src =
        \\uses (
        \\  { Container } from "some/pkg"
        \\)
        \\
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Label>hi</Label>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    try std.testing.expect(found.err == null);
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, found.uses, found.uses_start, found.uses_end, .{});
    try std.testing.expect(result.output == null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "Container") != null);
}

test "<children/> compiles to a direct call to the composer's own 'children' parameter" {
    const src =
        \\expose Card
        \\
        \\func Card(parent uint32, children widgets.Builder) error {
        \\  <Container>
        \\    <children/>
        \\  </Container>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, .{});
    try std.testing.expect(result.err == null);
    const gen = result.output.?.generated;
    try std.testing.expect(std.mem.indexOf(u8, gen, "widgets.CreateContainer(Container0Layout, false, 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "if err := children(uint32(Container0)); err != nil {\n\t\treturn err\n\t}\n") != null);
}

test "<children/> rejects attributes and its own children with a clear error" {
    const src_with_attr =
        \\expose Card
        \\
        \\func Card(parent uint32, children widgets.Builder) error {
        \\  <children foo="bar"/>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found1 = try Expose.findComposers(allocator, src_with_attr);
    const result1 = try generateGo(allocator, "main", src_with_attr, found1.composers, &.{}, &.{}, 0, 0, .{});
    try std.testing.expect(result1.output == null);
    try std.testing.expect(std.mem.indexOf(u8, result1.err.?.message, "attributes") != null);

    const src_with_children =
        \\expose Card
        \\
        \\func Card(parent uint32, children widgets.Builder) error {
        \\  <children><Label>hi</Label></children>
        \\}
    ;
    const found2 = try Expose.findComposers(allocator, src_with_children);
    const result2 = try generateGo(allocator, "main", src_with_children, found2.composers, &.{}, &.{}, 0, 0, .{});
    try std.testing.expect(result2.output == null);
    try std.testing.expect(std.mem.indexOf(u8, result2.err.?.message, "its own children") != null);
}

test "a composer body that never references a real widget kind gets no unused 'widgets' import, even when its own signature does" {
    // `children widgets.Builder` in the signature is copied verbatim and
    // does mention `widgets.` -- correctly still needs the import, even
    // though the body itself (a bare `<children/>` call) never emits
    // widgets.CreateX/ApplyStyle/ParentID anywhere.
    const src =
        \\expose Card
        \\
        \\func Card(parent uint32, children widgets.Builder) error {
        \\  <children/>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, .{});
    try std.testing.expect(result.err == null);
    try std.testing.expect(std.mem.indexOf(u8, result.output.?.generated, "import \"natyv/sdk/widgets\"\n") != null);
}

test "a composer body whose signature and body both never mention 'widgets' gets no import block at all" {
    const src =
        \\expose Card
        \\
        \\func Card(parent uint32, children func(uint32) error) error {
        \\  <children/>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, .{});
    try std.testing.expect(result.err == null);
    const gen = result.output.?.generated;
    try std.testing.expect(std.mem.indexOf(u8, gen, "widgets") == null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "import") == null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "if err := children(uint32(parent)); err != nil {") != null);
}

test "a component-only composer body needing a 'uses' import but no real widget gets only that import, no unused widgets import" {
    const src =
        \\uses (
        \\  { OtherComp } from "some/other/pkg"
        \\)
        \\
        \\expose Card
        \\
        \\func Card(parent uint32) error {
        \\  <OtherComp/>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, found.uses, found.uses_start, found.uses_end, .{});
    try std.testing.expect(result.err == null);
    const gen = result.output.?.generated;
    try std.testing.expect(std.mem.indexOf(u8, gen, "import \"some/other/pkg\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "natyv/sdk/widgets") == null);
}

test "<Image src=...> with no styles= still applies its texture, background true" {
    const src =
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Image src="hero.png"/>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    var image_texture_ids: std.StringHashMapUnmanaged(u32) = .{};
    try image_texture_ids.put(allocator, "hero.png", 0);
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, image_texture_ids);
    try std.testing.expect(result.err == null);
    const gen = result.output.?.generated;
    try std.testing.expect(std.mem.indexOf(u8, gen, "widgets.CreateContainer(Image0Layout, true, 0)") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen, "widgets.ApplyStyleWithTexture(uint32(Image0), StyleTokens, 0)") != null);
}

test "<Image src=...> with styles= merges names, src's texture still applied via the same call" {
    const src =
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Image src="hero.png" styles={card}/>
        \\}
    ;
    const tokens = [_]Resolver.ResolvedStyleToken{.{ .name = "card", .padding = 4 }};
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    var image_texture_ids: std.StringHashMapUnmanaged(u32) = .{};
    try image_texture_ids.put(allocator, "hero.png", 2);
    const result = try generateGo(allocator, "main", src, found.composers, &tokens, &.{}, 0, 0, image_texture_ids);
    try std.testing.expect(result.err == null);
    const gen = result.output.?.generated;
    try std.testing.expect(std.mem.indexOf(u8, gen, "widgets.ApplyStyleWithTexture(uint32(Image0), StyleTokens, 2, \"card\")") != null);
}

test "<Image> requires a src attribute" {
    const src =
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Image/>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, .{});
    try std.testing.expect(result.err != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "src") != null);
}

test "<Image> rejects children" {
    const src =
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Image src="hero.png"><Label>no</Label></Image>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    var image_texture_ids: std.StringHashMapUnmanaged(u32) = .{};
    try image_texture_ids.put(allocator, "hero.png", 0);
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, image_texture_ids);
    try std.testing.expect(result.err != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "children") != null);
}

test "<Image src=...> naming a path never staged is a clear error, not a crash" {
    const src =
        \\expose Foo
        \\
        \\func Foo(parent widgets.Container) error {
        \\  <Image src="never-staged.png"/>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const found = try Expose.findComposers(allocator, src);
    const result = try generateGo(allocator, "main", src, found.composers, &.{}, &.{}, 0, 0, .{});
    try std.testing.expect(result.err != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "never-staged.png") != null);
}
