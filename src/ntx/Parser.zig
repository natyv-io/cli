//! `.ntx` tooling Stage 2 (~/.claude/plans/lexical-wishing-penguin.md): the
//! JSX-like tag-tree syntax's own parser. Hand-rolled recursive descent,
//! same "no external parser library, no reflection" precedent as
//! `styling/Stylesheet.zig` -- mirrors that file's shape (byte-level
//! cursor with line/col tracking, a `ParseError{line, col, message}`,
//! cheap value-type cursor snapshots for lookahead) applied to a
//! genuinely different grammar.
//!
//! Deliberate scope boundary, matching the approved plan: this parses ONE
//! given tag tree (`src` is assumed to start at `<Tag` and run through its
//! matching close), never a full `.go.ntx` source file with arbitrary Go
//! statements around it. Finding *where* a tag tree begins inside a real
//! full guest source file is Stage 3's problem (codegen needs to answer
//! it to do the two-file split) -- deliberately not solved here, so this
//! file's own grammar never needs to understand enough Go to tell "a
//! comparison operator" apart from "a tag open" the way real JSX/TSX
//! parsers must.
//!
//! Everything inside an attribute's `{...}` is opaque host-language text
//! by default -- this parser never parses real Go expressions, only scans
//! for the matching `}` (brace-depth tracking, skipping over the contents
//! of Go string/raw-string/rune literals and `//`/`/* */` comments so a
//! `}` inside one of those doesn't end the block early). `ref={&x}` and
//! `styles={a, b}` are the two confirmed special-cased bare grammars (see
//! CLAUDE.md's JSX-like markup authoring layer section) -- both still
//! captured without ever parsing real Go, just a narrower lexical shape.
//!
//! Grammar:
//!   element   := '<' IDENT attr* ( '/>' | '>' child* '</' IDENT '>' )
//!   attr      := IDENT '=' ( STRING | '{' braced_value '}' )
//!   braced_value := ref_value | styles_value | opaque_text
//!   ref_value    := '&' opaque_text            (attr name must be "ref")
//!   styles_value := token_ident (',' token_ident)*   (attr name "styles";
//!                    falls back to opaque_text on any other shape)
//!   child     := element | text
//!   text      := any run of bytes up to the next '<', insignificant
//!                (whitespace-only) runs are dropped, never produced as a
//!                child node.

const std = @import("std");

pub const AttrValue = union(enum) {
    /// A plain, non-braced `attr="literal"` value -- the raw text between
    /// the quotes, not unescaped (same "store raw source bytes" choice
    /// Stylesheet.zig's own string token makes).
    string_literal: []const u8,
    /// `ref={&x}` -- the raw text after the `&` (usually a bare
    /// identifier, but not constrained to one: `&self.field` etc. are
    /// captured verbatim too, since this parser never validates real Go
    /// expression shapes).
    ref: []const u8,
    /// `styles={a, b}` -- the bare comma-separated style-token-name list,
    /// each with its own real position (`.ntx` LSP Stage 4,
    /// ~/.claude/plans/lexical-wishing-penguin.md) -- distinct names in one
    /// `styles={...}` attribute are otherwise indistinguishable positions
    /// once flattened into `Codegen.zig`'s single `source_map` list.
    styles: []StyleRef,
    /// Any other `{...}` value -- opaque host-language text, pasted
    /// verbatim into generated code by a later stage. Never parsed here.
    expr: []const u8,
};

/// One name inside a `styles={...}` list, with its own real position --
/// `attr.line`/`attr.col` (below) only locate the word "styles" itself,
/// not any individual name in the list.
pub const StyleRef = struct {
    name: []const u8,
    line: u32,
    col: u32,
};

pub const Attr = struct {
    name: []const u8,
    value: AttrValue,
    line: u32,
    col: u32,
};

/// The position of a non-self-closing element's own `</Tag>` -- `line`/
/// `col` mark the tag name's own first character (right after the `</`),
/// matching `Element.line`/`col`'s post-`+1`-correction convention for the
/// opening tag, not the position of `<` itself. `null` for a self-closing
/// element (`<Tag/>`), which has no closing tag to point at.
pub const ClosingTag = struct {
    line: u32,
    col: u32,
};

pub const Element = struct {
    tag: []const u8,
    attrs: []Attr,
    children: []Node,
    line: u32,
    col: u32,
    close: ?ClosingTag = null,
};

/// A run of plain text between tags, with its own real position (`.ntx`
/// LSP Stage 4) -- position marks the start of the *trimmed* content, not
/// any stripped leading whitespace/newline.
pub const TextNode = struct {
    text: []const u8,
    line: u32,
    col: u32,
};

pub const Node = union(enum) {
    element: Element,
    text: TextNode,
};

pub const ParseError = struct {
    line: u32,
    col: u32,
    message: []const u8,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    col: u32 = 1,
    /// Set only when a parse function returns `error.ParseError` -- carries
    /// a real position + message, matching Stylesheet.zig's own
    /// `last_error` convention.
    last_error: ?ParseError = null,

    pub fn init(allocator: std.mem.Allocator, src: []const u8) Parser {
        return .{ .allocator = allocator, .src = src };
    }

    fn peek(self: Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn peekAt(self: Parser, offset: usize) ?u8 {
        const i = self.pos + offset;
        return if (i < self.src.len) self.src[i] else null;
    }

    fn advance(self: *Parser) void {
        if (self.pos >= self.src.len) return;
        if (self.src[self.pos] == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        self.pos += 1;
    }

    fn fail(self: *Parser, line: u32, col: u32, comptime fmt: []const u8, args: anytype) error{ParseError} {
        self.last_error = .{
            .line = line,
            .col = col,
            .message = std.fmt.allocPrint(self.allocator, fmt, args) catch fmt,
        };
        return error.ParseError;
    }

    fn failHere(self: *Parser, comptime fmt: []const u8, args: anytype) error{ParseError} {
        return self.fail(self.line, self.col, fmt, args);
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.peek()) |b| {
            if (b == ' ' or b == '\t' or b == '\r' or b == '\n') self.advance() else break;
        }
    }

    fn isIdentStart(b: u8) bool {
        return std.ascii.isAlphabetic(b) or b == '_';
    }
    fn isIdentCont(b: u8) bool {
        return std.ascii.isAlphanumeric(b) or b == '_';
    }
    /// Style-token names allow '-' (e.g. "card-header") -- a different,
    /// wider charset than a real Go identifier's, matching
    /// Stylesheet.zig's own `isIdentCont` for the same reason (these are
    /// stylesheet token names, not host-language symbols).
    fn isTokenIdentCont(b: u8) bool {
        return std.ascii.isAlphanumeric(b) or b == '_' or b == '-';
    }

    fn parseIdentRaw(self: *Parser, comptime cont: fn (u8) bool, comptime what: []const u8) error{ParseError}![]const u8 {
        const b = self.peek() orelse return self.failHere("expected {s}, found end of input", .{what});
        if (!isIdentStart(b)) return self.failHere("expected {s}, found '{c}'", .{ what, b });
        const start = self.pos;
        self.advance();
        while (self.peek()) |c| {
            if (!cont(c)) break;
            self.advance();
        }
        return self.src[start..self.pos];
    }

    fn parseIdent(self: *Parser) error{ParseError}![]const u8 {
        return self.parseIdentRaw(isIdentCont, "an identifier");
    }

    /// A tag name is a plain identifier, optionally followed by `.` and a
    /// second identifier (`pkg.Name`) -- `.ntx` tooling Stage 6a's
    /// component-reuse convention (~/.claude/plans/lexical-wishing-penguin.md):
    /// a dotted tag calls a composer exposed by another package, forwarded
    /// verbatim as a qualified Go selector. Only tag names get this;
    /// attribute names/`ref` targets/etc. still use plain `parseIdent`.
    fn parseTagName(self: *Parser) error{ParseError}![]const u8 {
        const start = self.pos;
        _ = try self.parseIdentRaw(isIdentCont, "a tag name");
        if (self.peek() == '.') {
            self.advance();
            _ = try self.parseIdentRaw(isIdentCont, "an identifier after '.'");
        }
        return self.src[start..self.pos];
    }

    fn expectByte(self: *Parser, b: u8) error{ParseError}!void {
        if (self.peek() != b) {
            return self.failHere("expected '{c}', found {s}", .{ b, if (self.peek()) |c| &[_]u8{c} else "end of input" });
        }
        self.advance();
    }

    /// Top-level entry point: parses exactly one element (see file doc
    /// comment for the deliberate "one given tag tree" scope boundary).
    pub fn parseTopLevel(self: *Parser) error{ ParseError, OutOfMemory }!Node {
        self.skipWhitespace();
        const node = try self.parseElement();
        self.skipWhitespace();
        if (self.peek() != null) return self.failHere("unexpected trailing content after the top-level element", .{});
        return node;
    }

    fn parseElement(self: *Parser) error{ ParseError, OutOfMemory }!Node {
        const start_line = self.line;
        const start_col = self.col;
        try self.expectByte('<');
        const tag = try self.parseTagName();

        var attrs: std.ArrayList(Attr) = .empty;
        errdefer attrs.deinit(self.allocator);
        self.skipWhitespace();
        while (self.peek()) |b| {
            if (b == '/' or b == '>') break;
            try attrs.append(self.allocator, try self.parseAttr());
            self.skipWhitespace();
        }

        if (self.peek() == '/') {
            self.advance();
            self.skipWhitespace();
            try self.expectByte('>');
            return .{ .element = .{
                .tag = tag,
                .attrs = try attrs.toOwnedSlice(self.allocator),
                .children = &.{},
                .line = start_line,
                .col = start_col,
            } };
        }

        try self.expectByte('>');
        const closed = try self.parseChildren(tag);
        return .{ .element = .{
            .tag = tag,
            .attrs = try attrs.toOwnedSlice(self.allocator),
            .children = closed.children,
            .line = start_line,
            .col = start_col,
            .close = .{ .line = closed.close_line, .col = closed.close_col },
        } };
    }

    fn parseAttr(self: *Parser) error{ ParseError, OutOfMemory }!Attr {
        const name_line = self.line;
        const name_col = self.col;
        const name = try self.parseIdent();
        self.skipWhitespace();
        try self.expectByte('=');
        self.skipWhitespace();

        const value: AttrValue = switch (self.peek() orelse return self.failHere("expected a value for attribute '{s}'", .{name})) {
            '"' => .{ .string_literal = try self.scanQuotedString() },
            '{' => try self.parseBracedAttrValue(name),
            else => return self.failHere("expected '\"' or '{{' for attribute '{s}'", .{name}),
        };
        return .{ .name = name, .value = value, .line = name_line, .col = name_col };
    }

    /// Scans a double-quoted Go string literal starting at the opening
    /// `"`, returning the raw (unescaped) content between the quotes.
    /// Escape-aware only enough to find the real closing quote -- `\"`
    /// never ends the literal early -- never interprets what an escape
    /// means, same "store raw source bytes" choice as the returned value.
    fn scanQuotedString(self: *Parser) error{ParseError}![]const u8 {
        const quote_line = self.line;
        const quote_col = self.col;
        self.advance(); // consume opening '"'
        const start = self.pos;
        while (self.peek()) |b| {
            if (b == '"') {
                const content = self.src[start..self.pos];
                self.advance();
                return content;
            }
            if (b == '\\' and self.peekAt(1) != null) {
                self.advance();
                self.advance();
                continue;
            }
            self.advance();
        }
        return self.fail(quote_line, quote_col, "unterminated string literal", .{});
    }

    fn parseBracedAttrValue(self: *Parser, attr_name: []const u8) error{ ParseError, OutOfMemory }!AttrValue {
        const brace_line = self.line;
        const brace_col = self.col;
        self.advance(); // consume '{'
        self.skipWhitespace();

        if (std.mem.eql(u8, attr_name, "ref")) {
            try self.expectByte('&');
            const target_start = self.pos;
            const target_end = try self.scanUntilMatchingBrace(brace_line, brace_col);
            const target = std.mem.trim(u8, self.src[target_start..target_end], " \t\r\n");
            if (target.len == 0) return self.fail(brace_line, brace_col, "ref={{&...}} is missing its target", .{});
            return .{ .ref = target };
        }

        if (std.mem.eql(u8, attr_name, "styles")) {
            if (try self.tryParseStylesList()) |list| return .{ .styles = list };
            // Fallback rule (confirmed design): anything that doesn't
            // parse as a bare comma-separated token-name list falls
            // through to a real host-language expression -- re-scan the
            // same span as opaque text instead of erroring.
        }

        const expr_start = self.pos;
        const expr_end = try self.scanUntilMatchingBrace(brace_line, brace_col);
        return .{ .expr = std.mem.trim(u8, self.src[expr_start..expr_end], " \t\r\n") };
    }

    /// Attempts the `styles={a, b}` bare-list grammar starting right after
    /// the opening `{`. On success, consumes through the matching `}` and
    /// returns the list. On any shape mismatch, restores the cursor to
    /// where it started (a cheap value-type snapshot, same trick
    /// Stylesheet.zig's `parseBraced` uses for its own one-token
    /// lookahead) and returns `null` so the caller can fall back to
    /// opaque-expression scanning of the identical span.
    fn tryParseStylesList(self: *Parser) error{OutOfMemory}!?[]StyleRef {
        const snapshot = self.*;
        var names: std.ArrayList(StyleRef) = .empty;
        defer names.deinit(self.allocator);

        while (true) {
            self.skipWhitespace();
            const b = self.peek() orelse {
                self.* = snapshot;
                return null;
            };
            if (!isIdentStart(b)) {
                self.* = snapshot;
                return null;
            }
            const name_line = self.line;
            const name_col = self.col;
            const start = self.pos;
            self.advance();
            while (self.peek()) |c| {
                if (!isTokenIdentCont(c)) break;
                self.advance();
            }
            names.append(self.allocator, .{ .name = self.src[start..self.pos], .line = name_line, .col = name_col }) catch |err| {
                self.* = snapshot;
                return err;
            };
            self.skipWhitespace();
            switch (self.peek() orelse 0) {
                ',' => {
                    self.advance();
                    continue;
                },
                '}' => {
                    self.advance();
                    return names.toOwnedSlice(self.allocator) catch |err| {
                        self.* = snapshot;
                        return err;
                    };
                },
                else => {
                    self.* = snapshot;
                    return null;
                },
            }
        }
    }

    /// Scans opaque host-language text from the current position (right
    /// after a consumed `{`) through its matching `}`, tracking brace
    /// depth and skipping over the contents of Go string/raw-string/rune
    /// literals and `//`/`/* */` comments so a `}` inside any of those
    /// never closes the block early. Never inspects parens/brackets --
    /// unnecessary for finding the matching `}`, since valid Go can't
    /// interleave mismatched bracket kinds. Returns the end offset
    /// (exclusive) of the opaque span; the matching `}` itself is
    /// consumed but not included in that span.
    ///
    /// `pub` (not just an internal attribute-value helper): `Expose.zig`'s
    /// composer-body discovery reuses this exact scan -- a `func Name(...)
    /// {`'s body needs the identical brace/string/comment-aware treatment
    /// (it can contain attribute expressions with their own embedded
    /// braces/strings), and duplicating this logic there was explicitly
    /// rejected in favor of sharing it. Callers from outside this file
    /// position a `Parser` at the byte right after the `{` they want
    /// matched (via `pos`/`line`/`col` -- plain struct fields, not
    /// private) before calling this.
    pub fn scanUntilMatchingBrace(self: *Parser, open_line: u32, open_col: u32) error{ParseError}!usize {
        var depth: u32 = 1;
        while (self.peek()) |b| {
            switch (b) {
                '{' => {
                    depth += 1;
                    self.advance();
                },
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        const end = self.pos;
                        self.advance();
                        return end;
                    }
                    self.advance();
                },
                '"' => _ = try self.scanQuotedString(),
                '`' => try self.scanRawString(),
                '\'' => try self.scanRuneLiteral(),
                '/' => {
                    if (self.peekAt(1) == '/') {
                        while (self.peek()) |c| {
                            if (c == '\n') break;
                            self.advance();
                        }
                    } else if (self.peekAt(1) == '*') {
                        self.advance();
                        self.advance();
                        while (self.peek()) |_| {
                            if (self.peek() == '*' and self.peekAt(1) == '/') {
                                self.advance();
                                self.advance();
                                break;
                            }
                            self.advance();
                        }
                    } else {
                        self.advance();
                    }
                },
                else => self.advance(),
            }
        }
        return self.fail(open_line, open_col, "unterminated '{{' (missing matching '}}')", .{});
    }

    fn scanRawString(self: *Parser) error{ParseError}!void {
        const line = self.line;
        const col = self.col;
        self.advance(); // opening '`'
        while (self.peek()) |b| {
            self.advance();
            if (b == '`') return;
        }
        return self.fail(line, col, "unterminated raw string literal", .{});
    }

    fn scanRuneLiteral(self: *Parser) error{ParseError}!void {
        const line = self.line;
        const col = self.col;
        self.advance(); // opening '\''
        while (self.peek()) |b| {
            if (b == '\\' and self.peekAt(1) != null) {
                self.advance();
                self.advance();
                continue;
            }
            self.advance();
            if (b == '\'') return;
        }
        return self.fail(line, col, "unterminated rune literal", .{});
    }

    fn parseChildren(self: *Parser, open_tag: []const u8) error{ ParseError, OutOfMemory }!struct { children: []Node, close_line: u32, close_col: u32 } {
        var children: std.ArrayList(Node) = .empty;
        errdefer children.deinit(self.allocator);

        while (true) {
            if (self.peek() == null) return self.failHere("unexpected end of input inside <{s}> (missing '</{s}'>')", .{ open_tag, open_tag });

            if (self.peek() == '<' and self.peekAt(1) == '/') {
                self.advance();
                self.advance();
                const close_line = self.line;
                const close_col = self.col;
                const close_tag = try self.parseTagName();
                if (!std.mem.eql(u8, close_tag, open_tag)) {
                    return self.fail(close_line, close_col, "mismatched closing tag: expected </{s}>, found </{s}>", .{ open_tag, close_tag });
                }
                self.skipWhitespace();
                try self.expectByte('>');
                return .{ .children = try children.toOwnedSlice(self.allocator), .close_line = close_line, .close_col = close_col };
            }

            if (self.peek() == '<' and self.peekAt(1) != null and isIdentStart(self.peekAt(1).?)) {
                try children.append(self.allocator, try self.parseElement());
                continue;
            }

            const text_start = self.pos;
            const text_start_line = self.line;
            const text_start_col = self.col;
            while (self.peek()) |b| {
                if (b == '<') break;
                self.advance();
            }
            const raw = self.src[text_start..self.pos];
            const after_leading = std.mem.trimStart(u8, raw, " \t\r\n");
            const trimmed = std.mem.trimEnd(u8, after_leading, " \t\r\n");
            if (trimmed.len > 0) {
                // Advance a local (line, col) tracker past whatever leading
                // whitespace/newlines were trimmed off, so the recorded
                // position marks the start of `trimmed` itself, not
                // `text_start` (which may sit on an earlier line, e.g. the
                // newline right after a tag's own `>`).
                var line = text_start_line;
                var col = text_start_col;
                for (raw[0 .. raw.len - after_leading.len]) |b| {
                    if (b == '\n') {
                        line += 1;
                        col = 1;
                    } else {
                        col += 1;
                    }
                }
                try children.append(self.allocator, .{ .text = .{ .text = trimmed, .line = line, .col = col } });
            }
        }
    }
};

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !struct { node: ?Node, err: ?ParseError } {
    var parser = Parser.init(allocator, src);
    const node = parser.parseTopLevel() catch |e| {
        if (e == error.ParseError) return .{ .node = null, .err = parser.last_error };
        return e;
    };
    return .{ .node = node, .err = null };
}

test "parses a self-closing element with a string and a braced attribute" {
    const src = "<TextField placeholder=\"Your name\" onChange={handleChange} />";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    const node = try parser.parseTopLevel();
    const el = node.element;
    try std.testing.expectEqualStrings("TextField", el.tag);
    try std.testing.expectEqual(@as(usize, 0), el.children.len);
    try std.testing.expectEqual(@as(usize, 2), el.attrs.len);
    try std.testing.expectEqualStrings("placeholder", el.attrs[0].name);
    try std.testing.expectEqualStrings("Your name", el.attrs[0].value.string_literal);
    try std.testing.expectEqualStrings("onChange", el.attrs[1].name);
    try std.testing.expectEqualStrings("handleChange", el.attrs[1].value.expr);
}

test "parses nested tags, ref, styles, and text children (the confirmed design doc example shape)" {
    const src =
        \\<Container parent={parent} styles={form-card}>
        \\  <Label styles={form-title}>Save your profile</Label>
        \\  <TextField ref={&nameField} styles={input} placeholder="Your name" />
        \\  <Button styles={primary-button} onClick={handleSave}>
        \\    Save
        \\  </Button>
        \\  <Label ref={&statusLabel} styles={status-text} />
        \\</Container>
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    const node = try parser.parseTopLevel();
    const container = node.element;
    try std.testing.expectEqualStrings("Container", container.tag);
    try std.testing.expectEqual(@as(usize, 4), container.children.len);

    const label1 = container.children[0].element;
    try std.testing.expectEqualStrings("Label", label1.tag);
    try std.testing.expectEqual(@as(usize, 1), label1.children.len);
    try std.testing.expectEqualStrings("Save your profile", label1.children[0].text.text);
    try std.testing.expectEqualStrings("form-title", label1.attrs[0].value.styles[0].name);

    const text_field = container.children[1].element;
    try std.testing.expectEqualStrings("nameField", text_field.attrs[0].value.ref);
    try std.testing.expectEqualStrings("input", text_field.attrs[1].value.styles[0].name);
    try std.testing.expectEqualStrings("Your name", text_field.attrs[2].value.string_literal);

    const button = container.children[2].element;
    try std.testing.expectEqual(@as(usize, 1), button.children.len);
    try std.testing.expectEqualStrings("Save", button.children[0].text.text);
    try std.testing.expectEqualStrings("primary-button", button.attrs[0].value.styles[0].name);
    try std.testing.expectEqualStrings("handleSave", button.attrs[1].value.expr);

    const label2 = container.children[3].element;
    try std.testing.expectEqualStrings("statusLabel", label2.attrs[0].value.ref);
}

test "styles={a, b} parses multiple bare token names" {
    const src = "<Card styles={card-header, elevated} />";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    const node = try parser.parseTopLevel();
    const styles = node.element.attrs[0].value.styles;
    try std.testing.expectEqual(@as(usize, 2), styles.len);
    try std.testing.expectEqualStrings("card-header", styles[0].name);
    try std.testing.expectEqualStrings("elevated", styles[1].name);
}

test "styles={...} falls back to an opaque expression when it isn't a bare identifier list" {
    const src = "<Card styles={isActive ? \"active\" : \"default\"} />";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    const node = try parser.parseTopLevel();
    const value = node.element.attrs[0].value;
    try std.testing.expect(value == .expr);
    try std.testing.expectEqualStrings("isActive ? \"active\" : \"default\"", value.expr);
}

test "a Go string literal inside a braced attribute can contain '{' and '}' without ending the block early" {
    const src = "<Button onClick={func() { fmt.Println(\"weird } input {\") }} />";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    const node = try parser.parseTopLevel();
    const expr = node.element.attrs[0].value.expr;
    try std.testing.expectEqualStrings("func() { fmt.Println(\"weird } input {\") }", expr);
}

test "a line comment inside a braced attribute containing '}' doesn't end the block early" {
    const src = "<Button onClick={ // handles the click }\n  handleClick\n} />";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    const node = try parser.parseTopLevel();
    const expr = node.element.attrs[0].value.expr;
    try std.testing.expect(std.mem.indexOf(u8, expr, "handleClick") != null);
}

test "reports a real line/column on a mismatched closing tag" {
    const src =
        \\<Container>
        \\  <Label>hi</Label>
        \\</Wrong>
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    try std.testing.expectError(error.ParseError, parser.parseTopLevel());
    const err = parser.last_error orelse return error.TestExpectedError;
    try std.testing.expectEqual(@as(u32, 3), err.line);
}

test "reports a real error on an unterminated element" {
    const src = "<Container><Label>hi</Label>";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    try std.testing.expectError(error.ParseError, parser.parseTopLevel());
    try std.testing.expect(parser.last_error != null);
}

test "reports a real error on an unterminated braced attribute value" {
    const src = "<Button onClick={handleSave />";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    try std.testing.expectError(error.ParseError, parser.parseTopLevel());
    try std.testing.expect(parser.last_error != null);
}

test "rejects ref not shaped as an address-of expression" {
    const src = "<TextField ref={nameField} />";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    try std.testing.expectError(error.ParseError, parser.parseTopLevel());
    try std.testing.expect(parser.last_error != null);
}

test "a dotted tag name (pkg.Name) parses as a single tag, self-closing" {
    const src = "<components.UserCard name=\"Bob\" />";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    const node = try parser.parseTopLevel();
    try std.testing.expectEqualStrings("components.UserCard", node.element.tag);
}

test "a dotted tag name with children requires a matching dotted closing tag" {
    const src = "<components.Card><Label>hi</Label></components.Card>";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    const node = try parser.parseTopLevel();
    try std.testing.expectEqualStrings("components.Card", node.element.tag);
    try std.testing.expectEqual(@as(usize, 1), node.element.children.len);
}

test "reports a clear error on a mismatched dotted closing tag" {
    const src = "<components.Card>hi</components.OtherThing>";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    try std.testing.expectError(error.ParseError, parser.parseTopLevel());
    try std.testing.expect(std.mem.indexOf(u8, parser.last_error.?.message, "components.OtherThing") != null);
}
