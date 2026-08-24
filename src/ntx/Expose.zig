//! `.ntx` tooling Stage 3a (~/.claude/plans/lexical-wishing-penguin.md):
//! composer discovery. Answers "where in a real `.go.ntx` file does a tag
//! tree actually start" -- deliberately *not* answered by `Parser.zig`
//! (which only ever parses a tag tree it's already been handed, see that
//! file's own doc comment) and *not* answered by scanning for a bare `<`
//! anywhere in the file, since disambiguating that from the host
//! language's own use of `<` (comparisons, and -- fatally, for a language
//! like Rust -- generics/turbofish) would require real expression-context
//! parsing this project deliberately avoids building.
//!
//! Confirmed design instead (Quinn, 2026-08-24): a file's first
//! non-comment, non-blank line(s) must be one or more `expose <Name>`
//! lines (multiple supported, on purpose -- a file can define several
//! independently-reusable composers). Each exposed `Name` is then located
//! via a plain `func Name(...) {` text match anywhere later in the file
//! (not real parsing -- an accepted v1 simplification: a literal
//! `func Name(` inside an unrelated string/comment could false-positive
//! match, considered acceptably unlikely, same spirit as
//! `styling/Stylesheet.zig`'s own "no string escapes" simplification).
//! That function's *entire body* is then 100% markup grammar, found via
//! the exact same brace/string/rune-literal/comment-aware scan
//! `Parser.zig`'s `scanUntilMatchingBrace` already implements for
//! attribute values -- reused here, not reimplemented, since a composer's
//! body can itself contain attribute expressions with embedded braces and
//! Go string literals needing the identical care.
//!
//! Finding a named function *declaration* generalizes to any guest
//! language for free (Go's `func`, Rust's `fn`, etc. are all equally
//! unambiguous, keyword-anchored shapes) -- unlike scanning for a bare
//! `<`, which is exactly what made the original approach unsafe for Rust.
//! Only the Go keyword (`func`) is wired up for this arc's Go-only scope;
//! adding another guest language later is a matter of trying another
//! keyword, not redesigning this mechanism.

const std = @import("std");
const Parser = @import("Parser").Parser;

pub const Composer = struct {
    name: []const u8,
    /// Raw text between the function's opening `{` and its matching `}`
    /// (exclusive of both braces) -- handed to `Parser.parseTopLevel`
    /// unmodified by Stage 3b.
    body: []const u8,
    /// `body`'s own byte offsets into the original file -- Stage 3b splices
    /// the logic file by cutting exactly `[body_start, body_end)` and
    /// substituting a call-through statement, leaving everything else in
    /// the original file untouched.
    body_start: usize,
    body_end: usize,
    /// Raw text of the function's parameter list (between its `(` and
    /// matching `)`, exclusive) -- copied verbatim into the generated
    /// builder function's own signature, and used by Stage 3b to extract
    /// each parameter's own name (the leading identifier of each
    /// top-level comma-separated segment -- correct even for Go's
    /// shared-type grouped params like `a, b int`) for the logic file's
    /// forwarding call.
    params: []const u8,
    /// Raw, trimmed text between the parameter list's `)` and the body's
    /// `{` -- empty for a void composer, `"error"` for the idiomatic
    /// error-returning shape this codebase's own hand-written composers
    /// already use (see e.g. `examples/clay-fixture/guest/main.go`'s
    /// `openModal() error`). Stage 3b supports exactly these two shapes;
    /// anything else is an accepted, documented v1 gap.
    return_type: []const u8,
    /// The exact `[start, end)` span of the literal `expose Name` text
    /// (not including surrounding whitespace/comments, which Stage 3b
    /// preserves) -- spliced out of the logic file the same way `body` is
    /// spliced and replaced.
    expose_start: usize,
    expose_end: usize,
    /// Position of the `expose` line that named this composer -- used for
    /// diagnostics about the composer as a whole (e.g. "no matching func"),
    /// not the function declaration's own position.
    line: u32,
    col: u32,
    /// Absolute position of `body`'s own first byte (right after the
    /// function's opening `{`) -- Stage 3b's codegen uses this (not
    /// `line`/`col` above) to translate a `Parser`-relative error position
    /// (always starting at (1, 1) for a fresh `Parser` over just the body
    /// slice) back to a real position in the original file.
    body_line: u32,
    body_col: u32,
};

pub const ExposeError = struct {
    line: u32,
    col: u32,
    message: []const u8,
};

/// One name bound by a `uses (...)` block (Stage 6a, confirmed 2026-08-24
/// -- replaces the earlier dotted-tag-as-call-site design: a component's
/// import path now lives in one declared block, not encoded into every
/// tag name that uses it). `{ Card, UserCard } from "pkg/path"` produces
/// one `UseImport` per name, all sharing that entry's `path` -- flattened
/// this way (rather than kept grouped) because every real lookup Codegen
/// needs is "given this bare tag name, what's its import path", never
/// "what names does this path expose".
pub const UseImport = struct {
    name: []const u8,
    path: []const u8,
    line: u32,
    col: u32,
};

fn isIdentStart(b: u8) bool {
    return std.ascii.isAlphabetic(b) or b == '_';
}
fn isIdentCont(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

/// Byte-level cursor, deliberately separate from `Parser`'s own -- this
/// file's job (finding structural markers in otherwise-arbitrary host
/// code) is different enough from `Parser`'s (parsing a known tag tree)
/// that sharing one cursor type would blur that boundary for no real
/// benefit; the one piece of logic actually worth sharing
/// (`scanUntilMatchingBrace`) is reused directly instead, see below.
const Cursor = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    col: u32 = 1,

    fn peek(self: Cursor) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }
    fn peekAt(self: Cursor, offset: usize) ?u8 {
        const i = self.pos + offset;
        return if (i < self.src.len) self.src[i] else null;
    }
    fn advance(self: *Cursor) void {
        if (self.pos >= self.src.len) return;
        if (self.src[self.pos] == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        self.pos += 1;
    }
    fn startsWithKeyword(self: Cursor, kw: []const u8) bool {
        if (self.pos + kw.len > self.src.len) return false;
        if (!std.mem.eql(u8, self.src[self.pos .. self.pos + kw.len], kw)) return false;
        const after = self.peekAt(kw.len) orelse return true;
        return !isIdentCont(after);
    }
};

fn skipInsignificant(cur: *Cursor) void {
    while (cur.peek()) |b| {
        if (b == ' ' or b == '\t' or b == '\r' or b == '\n') {
            cur.advance();
        } else if (b == '/' and cur.peekAt(1) == '/') {
            while (cur.peek()) |c| {
                if (c == '\n') break;
                cur.advance();
            }
        } else if (b == '/' and cur.peekAt(1) == '*') {
            cur.advance();
            cur.advance();
            while (cur.peek()) |_| {
                if (cur.peek() == '*' and cur.peekAt(1) == '/') {
                    cur.advance();
                    cur.advance();
                    break;
                }
                cur.advance();
            }
        } else break;
    }
}

/// Skips a leading `package <name>` line and any `import (...)`/
/// `import "..."` block(s), interspersed with the usual insignificant
/// (blank/comment) content -- real Go files must start with `package`,
/// so the `expose` header block realistically begins after it, not
/// literally at byte 0. A no-op (falls straight through) for a file or
/// snippet with neither, so this doesn't change behavior for those.
fn skipPackageAndImports(cur: *Cursor) void {
    while (true) {
        skipInsignificant(cur);
        if (cur.startsWithKeyword("package")) {
            while (cur.peek()) |c| {
                cur.advance();
                if (c == '\n') break;
            }
            continue;
        }
        if (cur.startsWithKeyword("import")) {
            for (0.."import".len) |_| cur.advance();
            skipInsignificant(cur);
            if (cur.peek() == '(') {
                var depth: u32 = 1;
                cur.advance();
                while (cur.peek()) |b| {
                    if (b == '(') {
                        depth += 1;
                        cur.advance();
                    } else if (b == ')') {
                        depth -= 1;
                        cur.advance();
                        if (depth == 0) break;
                    } else cur.advance();
                }
            } else {
                while (cur.peek()) |c| {
                    cur.advance();
                    if (c == '\n') break;
                }
            }
            continue;
        }
        break;
    }
}

/// Scans a double-quoted string starting at the opening `"`, returning its
/// raw content. No escape-sequence support -- a real import path
/// structurally never needs one, unlike a Go string literal in general
/// (`Parser.zig`'s own `scanQuotedString` handles that harder case for
/// attribute values; this is the narrower, `uses`-only need).
fn scanQuotedPath(cur: *Cursor) ?[]const u8 {
    if (cur.peek() != '"') return null;
    cur.advance();
    const start = cur.pos;
    while (cur.peek()) |b| {
        if (b == '"') {
            const content = cur.src[start..cur.pos];
            cur.advance();
            return content;
        }
        if (b == '\n') return null;
        cur.advance();
    }
    return null;
}

/// Parses an optional `uses (...)` block -- Stage 6a's real import
/// mechanism (~/.claude/plans/lexical-wishing-penguin.md), confirmed by
/// Quinn 2026-08-24 to replace encoding a component's package directly
/// into its tag name (`<components.Card/>`) with a declared block, so
/// markup only ever uses bare tag names (`<Card/>`), mirroring a real
/// `import { Card } from "..."` in JS/TS-family languages. Sits between
/// `package`/`import` and the `expose` line(s) -- optional, at most one
/// block per file (v1 scope; multiplicity wasn't asked for and isn't
/// obviously useful the way multiple `expose` lines are). Each line
/// inside is `{ Name (, Name)* } from "path"`; every name across every
/// line must be unique (checked here) -- collision with a same-file
/// `expose`d composer name is checked by the caller, which has both
/// lists: collision with a *built-in widget kind* name is checked by
/// `Codegen.zig`, which owns that list, not duplicated here.
fn parseUsesBlock(allocator: std.mem.Allocator, cur: *Cursor) !struct { uses: []UseImport, block_start: usize, block_end: usize, err: ?ExposeError } {
    var uses: std.ArrayList(UseImport) = .empty;
    errdefer uses.deinit(allocator);

    skipInsignificant(cur);
    if (!cur.startsWithKeyword("uses")) return .{ .uses = &.{}, .block_start = 0, .block_end = 0, .err = null };
    // Captured *after* skipping leading whitespace/comments, so the
    // spliced-out span (Stage 3b's edit mechanism, reused here) is
    // exactly the `uses (...)` text itself, matching how `expose_start`/
    // `expose_end` below already exclude their own surrounding
    // whitespace.
    const block_start = cur.pos;
    for (0.."uses".len) |_| cur.advance();
    skipInsignificant(cur);
    if (cur.peek() != '(') return .{ .uses = &.{}, .block_start = 0, .block_end = 0, .err = .{ .line = cur.line, .col = cur.col, .message = "expected '(' after 'uses'" } };
    cur.advance();

    while (true) {
        skipInsignificant(cur);
        if (cur.peek() == ')') {
            cur.advance();
            break;
        }
        const entry_line = cur.line;
        const entry_col = cur.col;
        if (cur.peek() != '{') return .{ .uses = &.{}, .block_start = 0, .block_end = 0, .err = .{ .line = cur.line, .col = cur.col, .message = "expected '{' to start a 'uses' entry, e.g. { Card } from \"...\"" } };
        cur.advance();

        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(allocator);
        while (true) {
            skipInsignificant(cur);
            const name_start = cur.pos;
            const nb = cur.peek() orelse return .{ .uses = &.{}, .block_start = 0, .block_end = 0, .err = .{ .line = cur.line, .col = cur.col, .message = "expected a component name inside 'uses { ... }'" } };
            if (!isIdentStart(nb)) return .{ .uses = &.{}, .block_start = 0, .block_end = 0, .err = .{ .line = cur.line, .col = cur.col, .message = "expected a component name inside 'uses { ... }'" } };
            cur.advance();
            while (cur.peek()) |c| {
                if (!isIdentCont(c)) break;
                cur.advance();
            }
            try names.append(allocator, cur.src[name_start..cur.pos]);
            skipInsignificant(cur);
            if (cur.peek() == ',') {
                cur.advance();
                continue;
            }
            break;
        }
        if (cur.peek() != '}') return .{ .uses = &.{}, .block_start = 0, .block_end = 0, .err = .{ .line = cur.line, .col = cur.col, .message = "expected '}' to close a 'uses' entry" } };
        cur.advance();

        skipInsignificant(cur);
        if (!cur.startsWithKeyword("from")) return .{ .uses = &.{}, .block_start = 0, .block_end = 0, .err = .{ .line = cur.line, .col = cur.col, .message = "expected 'from \"path\"' after '{...}' in a 'uses' entry" } };
        for (0.."from".len) |_| cur.advance();
        skipInsignificant(cur);
        const path = scanQuotedPath(cur) orelse return .{ .uses = &.{}, .block_start = 0, .block_end = 0, .err = .{ .line = cur.line, .col = cur.col, .message = "expected a quoted import path after 'from'" } };

        for (names.items) |name| {
            for (uses.items) |existing| {
                if (std.mem.eql(u8, existing.name, name)) {
                    return .{ .uses = &.{}, .block_start = 0, .block_end = 0, .err = .{ .line = entry_line, .col = entry_col, .message = try std.fmt.allocPrint(allocator, "component name '{s}' is already imported (via 'uses')", .{name}) } };
                }
            }
            try uses.append(allocator, .{ .name = name, .path = path, .line = entry_line, .col = entry_col });
        }
    }

    return .{ .uses = try uses.toOwnedSlice(allocator), .block_start = block_start, .block_end = cur.pos, .err = null };
}

fn lineColAt(src: []const u8, offset: usize) struct { line: u32, col: u32 } {
    var line: u32 = 1;
    var col: u32 = 1;
    var i: usize = 0;
    while (i < offset and i < src.len) : (i += 1) {
        if (src[i] == '\n') {
            line += 1;
            col = 1;
        } else col += 1;
    }
    return .{ .line = line, .col = col };
}

const ExposedName = struct {
    name: []const u8,
    line: u32,
    col: u32,
    expose_start: usize,
    expose_end: usize,
};

/// Parses the leading `expose <Name>` header block, plus an optional
/// preceding `uses (...)` block (Stage 6a). Returns the list of exposed
/// names (each with the position of its `expose` line), the `uses`
/// bindings, and the byte offset where the header ends -- composer
/// function declarations are only ever searched for from that offset
/// onward, so a `func Name(` mentioned in a leading comment can never be
/// mistaken for a real match.
fn parseHeader(allocator: std.mem.Allocator, src: []const u8) !struct { names: []ExposedName, uses: []UseImport, uses_start: usize, uses_end: usize, body_search_start: usize, err: ?ExposeError } {
    var cur: Cursor = .{ .src = src };
    var names: std.ArrayList(ExposedName) = .empty;
    errdefer names.deinit(allocator);

    skipPackageAndImports(&cur);

    const parsed_uses = try parseUsesBlock(allocator, &cur);
    if (parsed_uses.err) |e| return .{ .names = &.{}, .uses = &.{}, .uses_start = 0, .uses_end = 0, .body_search_start = 0, .err = e };

    while (true) {
        skipInsignificant(&cur);
        if (!cur.startsWithKeyword("expose")) break;
        const expose_start = cur.pos;
        const expose_line = cur.line;
        const expose_col = cur.col;
        for (0.."expose".len) |_| cur.advance();

        const ws = cur.peek() orelse return .{ .names = &.{}, .uses = &.{}, .uses_start = 0, .uses_end = 0, .body_search_start = 0, .err = .{ .line = cur.line, .col = cur.col, .message = "expected a name after 'expose'" } };
        if (ws != ' ' and ws != '\t') {
            return .{ .names = &.{}, .uses = &.{}, .uses_start = 0, .uses_end = 0, .body_search_start = 0, .err = .{ .line = cur.line, .col = cur.col, .message = "expected whitespace after 'expose'" } };
        }
        while (cur.peek()) |b| {
            if (b != ' ' and b != '\t') break;
            cur.advance();
        }

        const name_start = cur.pos;
        const nb = cur.peek() orelse return .{ .names = &.{}, .uses = &.{}, .uses_start = 0, .uses_end = 0, .body_search_start = 0, .err = .{ .line = cur.line, .col = cur.col, .message = "expected a name after 'expose'" } };
        if (!isIdentStart(nb)) {
            return .{ .names = &.{}, .uses = &.{}, .uses_start = 0, .uses_end = 0, .body_search_start = 0, .err = .{ .line = cur.line, .col = cur.col, .message = "expected a name after 'expose'" } };
        }
        cur.advance();
        while (cur.peek()) |c| {
            if (!isIdentCont(c)) break;
            cur.advance();
        }
        const name = src[name_start..cur.pos];
        for (names.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) {
                return .{ .names = &.{}, .uses = &.{}, .uses_start = 0, .uses_end = 0, .body_search_start = 0, .err = .{ .line = expose_line, .col = expose_col, .message = "duplicate 'expose' for the same name" } };
            }
        }
        try names.append(allocator, .{ .name = name, .line = expose_line, .col = expose_col, .expose_start = expose_start, .expose_end = cur.pos });
    }

    return .{ .names = try names.toOwnedSlice(allocator), .uses = parsed_uses.uses, .uses_start = parsed_uses.block_start, .uses_end = parsed_uses.block_end, .body_search_start = cur.pos, .err = null };
}

/// Finds `func <name>(` at or after `search_start`, verifying real word
/// boundaries on both sides so e.g. searching for "NavBar" never matches
/// inside "NavBarExtra". Returns the byte offset of the matched `(`.
fn findFuncSignature(src: []const u8, search_start: usize, name: []const u8) ?usize {
    var pos = search_start;
    while (std.mem.indexOfPos(u8, src, pos, "func")) |func_at| {
        pos = func_at + 1;
        if (func_at > 0 and isIdentCont(src[func_at - 1])) continue;
        var cur: Cursor = .{ .src = src, .pos = func_at + "func".len };
        skipInsignificant(&cur);
        const name_start = cur.pos;
        if (cur.peek() == null or !isIdentStart(cur.peek().?)) continue;
        cur.advance();
        while (cur.peek()) |c| {
            if (!isIdentCont(c)) break;
            cur.advance();
        }
        if (!std.mem.eql(u8, src[name_start..cur.pos], name)) continue;
        skipInsignificant(&cur);
        if (cur.peek() != '(') continue;
        return cur.pos;
    }
    return null;
}

/// From a function's parameter-list opening `(` (as returned by
/// `findFuncSignature`), finds the byte offset of the matching `)`.
/// Tracks paren depth (a param's own type can itself contain parens, e.g.
/// a callback param `cb func(int) error`) and skips comments (so a
/// comment containing a stray `)` doesn't end the list early) -- no
/// string-literal awareness needed, since a real Go parameter list
/// structurally can never contain one.
fn findMatchingCloseParen(src: []const u8, open_paren_pos: usize) ?usize {
    var cur: Cursor = .{ .src = src, .pos = open_paren_pos + 1 };
    var depth: u32 = 1;
    while (cur.peek()) |b| {
        if (b == '/' and (cur.peekAt(1) == '/' or cur.peekAt(1) == '*')) {
            skipInsignificant(&cur);
            continue;
        }
        switch (b) {
            '(' => {
                depth += 1;
                cur.advance();
            },
            ')' => {
                depth -= 1;
                if (depth == 0) return cur.pos;
                cur.advance();
            },
            else => cur.advance(),
        }
    }
    return null;
}

/// From a function's parameter-list closing `)` (as returned by
/// `findMatchingCloseParen`), finds the byte offset of that function's own
/// opening `{`. Deliberately does not track brace/bracket depth or
/// string-literal contents: a real Go function *return type* structurally
/// can never contain a string literal, and essentially never contains a
/// bare `{` outside the vanishingly-rare anonymous-struct-type return
/// case, which is an accepted, documented v1 gap rather than something
/// worth real parsing to handle. Comments are still skipped, since
/// `func Foo() /* returns { nothing } */ {` is real, valid Go.
fn findFuncOpenBrace(src: []const u8, close_paren_pos: usize) ?usize {
    var cur: Cursor = .{ .src = src, .pos = close_paren_pos + 1 };
    while (cur.peek()) |_| {
        skipInsignificant(&cur);
        if (cur.peek() == '{') return cur.pos;
        if (cur.peek() == null) break;
        cur.advance();
    }
    return null;
}

pub fn findComposers(allocator: std.mem.Allocator, src: []const u8) !struct { composers: []Composer, uses: []UseImport, uses_start: usize, uses_end: usize, err: ?ExposeError } {
    const header = try parseHeader(allocator, src);
    if (header.err) |e| return .{ .composers = &.{}, .uses = &.{}, .uses_start = 0, .uses_end = 0, .err = e };

    for (header.uses) |use| {
        for (header.names) |exposed| {
            if (std.mem.eql(u8, use.name, exposed.name)) {
                return .{ .composers = &.{}, .uses = &.{}, .uses_start = 0, .uses_end = 0, .err = .{
                    .line = use.line,
                    .col = use.col,
                    .message = try std.fmt.allocPrint(allocator, "'{s}' is both a 'uses' import and a composer exposed in this file -- pick one name", .{use.name}),
                } };
            }
        }
    }

    var composers: std.ArrayList(Composer) = .empty;
    errdefer composers.deinit(allocator);

    for (header.names) |exposed| {
        const paren_pos = findFuncSignature(src, header.body_search_start, exposed.name) orelse {
            return .{ .composers = &.{}, .uses = &.{}, .uses_start = 0, .uses_end = 0, .err = .{
                .line = exposed.line,
                .col = exposed.col,
                .message = try std.fmt.allocPrint(allocator, "expose '{s}' has no matching 'func {s}(...) {{ ... }}' in this file", .{ exposed.name, exposed.name }),
            } };
        };
        const close_paren_pos = findMatchingCloseParen(src, paren_pos) orelse {
            return .{ .composers = &.{}, .uses = &.{}, .uses_start = 0, .uses_end = 0, .err = .{
                .line = exposed.line,
                .col = exposed.col,
                .message = try std.fmt.allocPrint(allocator, "could not find the closing ')' of 'func {s}('", .{exposed.name}),
            } };
        };
        const open_brace_pos = findFuncOpenBrace(src, close_paren_pos) orelse {
            return .{ .composers = &.{}, .uses = &.{}, .uses_start = 0, .uses_end = 0, .err = .{
                .line = exposed.line,
                .col = exposed.col,
                .message = try std.fmt.allocPrint(allocator, "could not find the opening '{{' of 'func {s}(...)'", .{exposed.name}),
            } };
        };

        var body_parser = Parser.init(allocator, src);
        const pos = lineColAt(src, open_brace_pos + 1);
        body_parser.pos = open_brace_pos + 1;
        body_parser.line = pos.line;
        body_parser.col = pos.col;
        const body_end = body_parser.scanUntilMatchingBrace(pos.line, pos.col) catch |e| {
            if (e == error.ParseError) {
                const perr = body_parser.last_error.?;
                return .{ .composers = &.{}, .uses = &.{}, .uses_start = 0, .uses_end = 0, .err = .{ .line = perr.line, .col = perr.col, .message = perr.message } };
            }
            return e;
        };

        try composers.append(allocator, .{
            .name = exposed.name,
            .body = src[open_brace_pos + 1 .. body_end],
            .body_start = open_brace_pos + 1,
            .body_end = body_end,
            .params = src[paren_pos + 1 .. close_paren_pos],
            .return_type = std.mem.trim(u8, src[close_paren_pos + 1 .. open_brace_pos], " \t\r\n"),
            .expose_start = exposed.expose_start,
            .expose_end = exposed.expose_end,
            .line = exposed.line,
            .col = exposed.col,
            .body_line = pos.line,
            .body_col = pos.col,
        });
    }

    return .{ .composers = try composers.toOwnedSlice(allocator), .uses = header.uses, .uses_start = header.uses_start, .uses_end = header.uses_end, .err = null };
}

test "finds a single exposed composer's body after a leading comment block" {
    const src =
        \\// this is
        \\// a block
        \\// of comments
        \\expose NavBar
        \\
        \\func NavBar(parent widgets.Container) {
        \\  <Container styles={nav}>
        \\    <Label>Home</Label>
        \\  </Container>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findComposers(arena.allocator(), src);
    try std.testing.expect(result.err == null);
    try std.testing.expectEqual(@as(usize, 1), result.composers.len);
    try std.testing.expectEqualStrings("NavBar", result.composers[0].name);

    var body_parser = Parser.init(arena.allocator(), std.mem.trim(u8, result.composers[0].body, " \t\r\n"));
    const parsed = try body_parser.parseTopLevel();
    _ = parsed;
}

test "finds multiple exposed composers, each with their own body" {
    const src =
        \\expose NavBar
        \\expose Footer
        \\
        \\func NavBar(parent widgets.Container) {
        \\  <Container styles={nav}><Label>Home</Label></Container>
        \\}
        \\
        \\func helper() int { return 1 }
        \\
        \\func Footer(parent widgets.Container) {
        \\  <Container styles={footer}><Label>Copyright</Label></Container>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findComposers(arena.allocator(), src);
    try std.testing.expect(result.err == null);
    try std.testing.expectEqual(@as(usize, 2), result.composers.len);
    try std.testing.expectEqualStrings("NavBar", result.composers[0].name);
    try std.testing.expectEqualStrings("Footer", result.composers[1].name);
    try std.testing.expect(std.mem.indexOf(u8, result.composers[0].body, "Home") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.composers[1].body, "Copyright") != null);
}

test "a non-exposed helper function's body is never touched, even if it mentions the exposed name" {
    const src =
        \\expose Card
        \\
        \\func notCard() { fmt.Println("func Card( in a string, not a real match") }
        \\
        \\func Card(parent widgets.Container) {
        \\  <Container styles={card}><Label>Real</Label></Container>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findComposers(arena.allocator(), src);
    try std.testing.expect(result.err == null);
    try std.testing.expectEqual(@as(usize, 1), result.composers.len);
    try std.testing.expect(std.mem.indexOf(u8, result.composers[0].body, "Real") != null);
}

test "a file with zero expose lines yields zero composers, not an error" {
    const src =
        \\// pure logic, no markup at all
        \\func helper() int { return 1 }
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findComposers(arena.allocator(), src);
    try std.testing.expect(result.err == null);
    try std.testing.expectEqual(@as(usize, 0), result.composers.len);
}

test "reports a real error when an exposed name has no matching func" {
    const src = "expose Missing\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findComposers(arena.allocator(), src);
    try std.testing.expect(result.err != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "Missing") != null);
}

test "reports a real error on a duplicate expose" {
    const src = "expose NavBar\nexpose NavBar\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findComposers(arena.allocator(), src);
    try std.testing.expect(result.err != null);
}

test "captures params, return type, and exact splice offsets for Stage 3b codegen" {
    const src =
        \\expose NavBar
        \\
        \\func NavBar(parent widgets.Container) error {
        \\  <Label>Home</Label>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findComposers(arena.allocator(), src);
    try std.testing.expect(result.err == null);
    const c = result.composers[0];
    try std.testing.expectEqualStrings("parent widgets.Container", c.params);
    try std.testing.expectEqualStrings("error", c.return_type);
    try std.testing.expectEqualStrings(c.body, src[c.body_start..c.body_end]);
    try std.testing.expectEqualStrings("expose NavBar", src[c.expose_start..c.expose_end]);
}

test "a func signature's own comment containing a brace doesn't confuse open-brace discovery" {
    const src =
        \\expose Weird
        \\
        \\func Weird() /* returns { nothing } */ {
        \\  <Label>hi</Label>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findComposers(arena.allocator(), src);
    try std.testing.expect(result.err == null);
    try std.testing.expect(std.mem.indexOf(u8, result.composers[0].body, "hi") != null);
}

test "parses a 'uses' block with multiple entries and multiple names per entry" {
    const src =
        \\package main
        \\
        \\import "natyv/sdk/widgets"
        \\
        \\uses (
        \\  { Card, UserCard } from "natyv/ntx-components-guest/components"
        \\  { Badge } from "natyv/ntx-badges-guest/badges"
        \\)
        \\
        \\expose Page
        \\
        \\func Page(parent widgets.Container) error {
        \\  <Label>hi</Label>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findComposers(arena.allocator(), src);
    try std.testing.expect(result.err == null);
    try std.testing.expectEqual(@as(usize, 3), result.uses.len);
    try std.testing.expectEqualStrings("Card", result.uses[0].name);
    try std.testing.expectEqualStrings("natyv/ntx-components-guest/components", result.uses[0].path);
    try std.testing.expectEqualStrings("UserCard", result.uses[1].name);
    try std.testing.expectEqualStrings("natyv/ntx-components-guest/components", result.uses[1].path);
    try std.testing.expectEqualStrings("Badge", result.uses[2].name);
    try std.testing.expectEqualStrings("natyv/ntx-badges-guest/badges", result.uses[2].path);
}

test "a file with no 'uses' block yields zero uses entries, not an error" {
    const src =
        \\expose Page
        \\
        \\func Page(parent widgets.Container) error {
        \\  <Label>hi</Label>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findComposers(arena.allocator(), src);
    try std.testing.expect(result.err == null);
    try std.testing.expectEqual(@as(usize, 0), result.uses.len);
}

test "reports a real error on a duplicate name across 'uses' entries" {
    const src =
        \\uses (
        \\  { Card } from "a/components"
        \\  { Card } from "b/components"
        \\)
        \\
        \\expose Page
        \\
        \\func Page(parent widgets.Container) error {
        \\  <Label>hi</Label>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findComposers(arena.allocator(), src);
    try std.testing.expect(result.err != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "Card") != null);
}

test "reports a real error when a 'uses' name collides with a same-file exposed composer" {
    const src =
        \\uses (
        \\  { Header } from "a/components"
        \\)
        \\
        \\expose Header
        \\expose Page
        \\
        \\func Header(parent uint32) error {
        \\  <Label>hi</Label>
        \\}
        \\
        \\func Page(parent widgets.Container) error {
        \\  <Label>hi</Label>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findComposers(arena.allocator(), src);
    try std.testing.expect(result.err != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "Header") != null);
}

test "reports a clear error on a malformed 'uses' block (missing 'from')" {
    const src =
        \\uses (
        \\  { Card } "a/components"
        \\)
        \\
        \\expose Page
        \\
        \\func Page(parent widgets.Container) error {
        \\  <Label>hi</Label>
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try findComposers(arena.allocator(), src);
    try std.testing.expect(result.err != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "from") != null);
}
