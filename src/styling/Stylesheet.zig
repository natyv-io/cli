//! Styling system Stage 2: the stylesheet syntax's own parser (amber-woven-
//! lantern.md). Hand-rolled recursive-descent, per the confirmed full-Zig
//! CLI decision (see CLAUDE.md's CLI build flow section) -- no external
//! parser library, no reflection.
//!
//! Deliberately split into two passes, not one:
//! 1. This file's `Parser`: pure syntax -> a generic `StyleSheet` tree.
//!    Knows nothing about which field names are real or what shape their
//!    values should take -- `cornerRadius: "banana"` parses just fine here.
//! 2. `Resolver.zig`'s `resolve`: walks that generic tree and validates it
//!    against the real v1 vocabulary, producing a strongly-typed
//!    `ResolvedStyleToken`.
//! Keeping these separate means the syntax-level grammar (braces, colons,
//! lists vs. blocks) never needs touching again as the *vocabulary* grows
//! (e.g. `text`/`transition`'s still-undecided real schemas, per
//! amber-woven-lantern.md's own open sign-off list) -- only the resolver
//! would need new cases.
//!
//! Grammar:
//!   file   := token*
//!   token  := IDENT block
//!   block  := '{' field* '}'
//!   field  := IDENT ':' value ','?
//!   value  := STRING | NUMBER | IDENT | list | block
//!   list   := '{' (value ','?)* '}'
//! `{` is ambiguous between `list` and `block` -- resolved with one token
//! of lookahead past it: IDENT immediately followed by ':' means a block,
//! anything else means a list (see `parseBraced`). Commas are optional
//! everywhere (accepts both the newline-separated top-level style shown in
//! every design doc and comma-separated inline nested blocks like
//! `{ width: 2, color: "#..." }` with the same rule).

const std = @import("std");

pub const TokenKind = enum { ident, number, string, lbrace, rbrace, colon, comma, eof };

pub const Token = struct {
    kind: TokenKind,
    text: []const u8,
    line: u32,
    col: u32,
};

/// Plain value type (no allocator, no pointers into itself) -- trivially
/// copyable, which is what lets `Parser.parseBraced` save a full lexer
/// snapshot for its one-block-of-lookahead check and restore it cheaply.
pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    col: u32 = 1,

    fn peekByte(self: Lexer) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn advanceByte(self: *Lexer) void {
        if (self.pos >= self.src.len) return;
        if (self.src[self.pos] == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        self.pos += 1;
    }

    fn skipWhitespaceAndComments(self: *Lexer) void {
        while (self.peekByte()) |b| {
            if (b == ' ' or b == '\t' or b == '\r' or b == '\n') {
                self.advanceByte();
            } else if (b == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                while (self.peekByte()) |c| {
                    if (c == '\n') break;
                    self.advanceByte();
                }
            } else break;
        }
    }

    fn isIdentStart(b: u8) bool {
        return std.ascii.isAlphabetic(b) or b == '_';
    }
    fn isIdentCont(b: u8) bool {
        // '-' is allowed mid-identifier (not as a start) so real-world
        // token names like `button-primary`/`card-header` lex as one
        // ident -- doesn't conflict with negative numbers, which only ever
        // start with '-' immediately before a digit (see `next`'s number
        // branch), never appear after an identifier has already started.
        return std.ascii.isAlphanumeric(b) or b == '_' or b == '-';
    }

    pub fn next(self: *Lexer) Token {
        self.skipWhitespaceAndComments();
        const start_line = self.line;
        const start_col = self.col;
        const b = self.peekByte() orelse return .{ .kind = .eof, .text = "", .line = start_line, .col = start_col };

        switch (b) {
            '{' => {
                self.advanceByte();
                return .{ .kind = .lbrace, .text = "{", .line = start_line, .col = start_col };
            },
            '}' => {
                self.advanceByte();
                return .{ .kind = .rbrace, .text = "}", .line = start_line, .col = start_col };
            },
            ':' => {
                self.advanceByte();
                return .{ .kind = .colon, .text = ":", .line = start_line, .col = start_col };
            },
            ',' => {
                self.advanceByte();
                return .{ .kind = .comma, .text = ",", .line = start_line, .col = start_col };
            },
            '"' => {
                self.advanceByte();
                const content_start = self.pos;
                // v1 simplification, deliberate: no escape sequences at
                // all inside strings (a real, accepted limitation -- none
                // of the v1 field types (hex colors, plain text) need one,
                // and it keeps the lexer honest about what it actually
                // supports instead of half-implementing escaping).
                while (self.peekByte()) |c| {
                    if (c == '"') break;
                    self.advanceByte();
                }
                const content = self.src[content_start..self.pos];
                if (self.peekByte() == '"') self.advanceByte();
                return .{ .kind = .string, .text = content, .line = start_line, .col = start_col };
            },
            else => {
                if (isIdentStart(b)) {
                    const start = self.pos;
                    while (self.peekByte()) |c| {
                        if (!isIdentCont(c)) break;
                        self.advanceByte();
                    }
                    return .{ .kind = .ident, .text = self.src[start..self.pos], .line = start_line, .col = start_col };
                }
                if (std.ascii.isDigit(b) or (b == '-' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1]))) {
                    const start = self.pos;
                    self.advanceByte();
                    while (self.peekByte()) |c| {
                        if (!std.ascii.isDigit(c) and c != '.') break;
                        self.advanceByte();
                    }
                    return .{ .kind = .number, .text = self.src[start..self.pos], .line = start_line, .col = start_col };
                }
                self.advanceByte();
                return .{ .kind = .eof, .text = self.src[self.pos - 1 .. self.pos], .line = start_line, .col = start_col };
            },
        }
    }
};

pub const Value = union(enum) {
    number: f64,
    string: []const u8,
    ident: []const u8,
    list: []Value,
    block: []Field,
};

pub const Field = struct {
    key: []const u8,
    value: Value,
    line: u32,
    col: u32,
};

pub const StyleToken = struct {
    name: []const u8,
    fields: []Field,
};

pub const StyleSheet = struct {
    tokens: []StyleToken,
};

pub const ParseError = struct {
    line: u32,
    col: u32,
    message: []const u8,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    lexer: Lexer,
    current: Token,
    /// Set only when `parse()` returns `error.ParseError` -- carries real
    /// position + a real message, not just a bare error code, matching
    /// this project's "always surface real failures" rule.
    last_error: ?ParseError = null,

    pub fn init(allocator: std.mem.Allocator, src: []const u8) Parser {
        var lexer: Lexer = .{ .src = src };
        const first = lexer.next();
        return .{ .allocator = allocator, .lexer = lexer, .current = first };
    }

    fn advance(self: *Parser) void {
        self.current = self.lexer.next();
    }

    fn fail(self: *Parser, tok: Token, comptime fmt: []const u8, args: anytype) error{ParseError} {
        self.last_error = .{
            .line = tok.line,
            .col = tok.col,
            .message = std.fmt.allocPrint(self.allocator, fmt, args) catch fmt,
        };
        return error.ParseError;
    }

    fn expect(self: *Parser, kind: TokenKind) error{ParseError}!Token {
        if (self.current.kind != kind) {
            return self.fail(self.current, "expected {s}, found {s} '{s}'", .{ @tagName(kind), @tagName(self.current.kind), self.current.text });
        }
        const tok = self.current;
        self.advance();
        return tok;
    }

    pub fn parse(self: *Parser) error{ ParseError, OutOfMemory }!StyleSheet {
        var tokens: std.ArrayList(StyleToken) = .empty;
        errdefer tokens.deinit(self.allocator);
        while (self.current.kind != .eof) {
            const name_tok = try self.expect(.ident);
            _ = try self.expect(.lbrace);
            const fields = try self.parseFieldsUntilRBrace();
            try tokens.append(self.allocator, .{ .name = name_tok.text, .fields = fields });
        }
        return .{ .tokens = try tokens.toOwnedSlice(self.allocator) };
    }

    /// Assumes the opening '{' has already been consumed -- shared by the
    /// top-level `name { ... }` block and any nested `key: { ... }` block
    /// value (see `parseBraced`), so the field-parsing logic (and its
    /// error messages) exist in exactly one place.
    fn parseFieldsUntilRBrace(self: *Parser) error{ ParseError, OutOfMemory }![]Field {
        var fields: std.ArrayList(Field) = .empty;
        errdefer fields.deinit(self.allocator);
        while (self.current.kind != .rbrace) {
            if (self.current.kind == .eof) return self.fail(self.current, "unexpected end of input inside block (missing '}}')", .{});
            const key_tok = try self.expect(.ident);
            _ = try self.expect(.colon);
            const value = try self.parseValue();
            try fields.append(self.allocator, .{ .key = key_tok.text, .value = value, .line = key_tok.line, .col = key_tok.col });
            if (self.current.kind == .comma) self.advance();
        }
        self.advance(); // consume '}'
        return fields.toOwnedSlice(self.allocator);
    }

    fn parseListUntilRBrace(self: *Parser) error{ ParseError, OutOfMemory }![]Value {
        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(self.allocator);
        while (self.current.kind != .rbrace) {
            if (self.current.kind == .eof) return self.fail(self.current, "unexpected end of input inside list (missing '}}')", .{});
            const value = try self.parseValue();
            try items.append(self.allocator, value);
            if (self.current.kind == .comma) self.advance();
        }
        self.advance(); // consume '}'
        return items.toOwnedSlice(self.allocator);
    }

    fn parseValue(self: *Parser) error{ ParseError, OutOfMemory }!Value {
        switch (self.current.kind) {
            .string => {
                const tok = self.current;
                self.advance();
                return .{ .string = tok.text };
            },
            .number => {
                const tok = self.current;
                self.advance();
                const n = std.fmt.parseFloat(f64, tok.text) catch return self.fail(tok, "invalid number '{s}'", .{tok.text});
                return .{ .number = n };
            },
            .ident => {
                const tok = self.current;
                self.advance();
                return .{ .ident = tok.text };
            },
            .lbrace => return self.parseBraced(),
            else => return self.fail(self.current, "unexpected token '{s}' where a value was expected", .{self.current.text}),
        }
    }

    /// Disambiguates `list` from `block` with one token of lookahead past
    /// the `{` this consumes: a plain `Lexer` is a small value type with no
    /// pointers into itself, so snapshotting it (`self.lexer`, a copy) to
    /// peek one more token ahead and then simply not using that snapshot
    /// is cheaper and simpler than a general token-buffering lookahead
    /// mechanism would be for a grammar this small.
    fn parseBraced(self: *Parser) error{ ParseError, OutOfMemory }!Value {
        _ = try self.expect(.lbrace);
        if (self.current.kind == .ident) {
            var lookahead = self.lexer;
            const after = lookahead.next();
            if (after.kind == .colon) {
                return .{ .block = try self.parseFieldsUntilRBrace() };
            }
        }
        return .{ .list = try self.parseListUntilRBrace() };
    }
};

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !struct { sheet: StyleSheet, err: ?ParseError } {
    var parser = Parser.init(allocator, src);
    const sheet = parser.parse() catch |e| {
        if (e == error.ParseError) return .{ .sheet = .{ .tokens = &.{} }, .err = parser.last_error };
        return e;
    };
    return .{ .sheet = sheet, .err = null };
}

test "parses a single flat token" {
    const src =
        \\button-primary {
        \\  backgroundColor: "#8B5CF6"
        \\  padding: 8
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    const sheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 1), sheet.tokens.len);
    try std.testing.expectEqualStrings("button-primary", sheet.tokens[0].name);
    try std.testing.expectEqual(@as(usize, 2), sheet.tokens[0].fields.len);
    try std.testing.expectEqualStrings("backgroundColor", sheet.tokens[0].fields[0].key);
    try std.testing.expectEqualStrings("#8B5CF6", sheet.tokens[0].fields[0].value.string);
    try std.testing.expectEqualStrings("padding", sheet.tokens[0].fields[1].key);
    try std.testing.expectEqual(@as(f64, 8), sheet.tokens[0].fields[1].value.number);
}

test "disambiguates a bare number list from a nested block" {
    const src =
        \\card {
        \\  cornerRadius: {4, 4, 4, 4}
        \\  border: { width: 2, color: "#000000" }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    const sheet = try parser.parse();
    const corner = sheet.tokens[0].fields[0].value;
    try std.testing.expect(corner == .list);
    try std.testing.expectEqual(@as(usize, 4), corner.list.len);
    try std.testing.expectEqual(@as(f64, 4), corner.list[0].number);

    const border = sheet.tokens[0].fields[1].value;
    try std.testing.expect(border == .block);
    try std.testing.expectEqual(@as(usize, 2), border.block.len);
    try std.testing.expectEqualStrings("width", border.block[0].key);
    try std.testing.expectEqual(@as(f64, 2), border.block[0].value.number);
    try std.testing.expectEqualStrings("color", border.block[1].key);
    try std.testing.expectEqualStrings("#000000", border.block[1].value.string);
}

test "parses multiple tokens and gradient anchors as idents" {
    const src =
        \\a { padding: 4 }
        \\b {
        \\  gradient: { start: { pos: top, color: "#111111" }, end: { pos: bottomRight, color: "#222222" } }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    const sheet = try parser.parse();
    try std.testing.expectEqual(@as(usize, 2), sheet.tokens.len);
    const gradient = sheet.tokens[1].fields[0].value;
    try std.testing.expect(gradient == .block);
    const start = gradient.block[0].value;
    try std.testing.expect(start == .block);
    try std.testing.expectEqualStrings("pos", start.block[0].key);
    try std.testing.expectEqualStrings("top", start.block[0].value.ident);
}

test "reports real line/column on a missing colon" {
    const src =
        \\broken {
        \\  padding 4
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    try std.testing.expectError(error.ParseError, parser.parse());
    const err = parser.last_error orelse return error.TestExpectedError;
    try std.testing.expectEqual(@as(u32, 2), err.line);
}

test "reports a real error on an unterminated block" {
    const src = "broken { padding: 4";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    try std.testing.expectError(error.ParseError, parser.parse());
    try std.testing.expect(parser.last_error != null);
}

test "supports line comments" {
    const src =
        \\token { // a comment
        \\  padding: 4 // trailing comment
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = Parser.init(arena.allocator(), src);
    const sheet = try parser.parse();
    try std.testing.expectEqual(@as(f64, 4), sheet.tokens[0].fields[0].value.number);
}
