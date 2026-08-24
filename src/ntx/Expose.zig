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
const Parser = @import("Parser.zig").Parser;

pub const Composer = struct {
    name: []const u8,
    /// Raw text between the function's opening `{` and its matching `}`
    /// (exclusive of both braces) -- handed to `Parser.parseTopLevel`
    /// unmodified by Stage 3b.
    body: []const u8,
    /// Position of the `expose` line that named this composer -- used for
    /// diagnostics, not the function declaration's own position.
    line: u32,
    col: u32,
};

pub const ExposeError = struct {
    line: u32,
    col: u32,
    message: []const u8,
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
};

/// Parses the leading `expose <Name>` header block. Returns the list of
/// exposed names (each with the position of its `expose` line) and the
/// byte offset where the header ends -- composer function declarations
/// are only ever searched for from that offset onward, so a `func Name(`
/// mentioned in a leading comment can never be mistaken for a real match.
fn parseHeader(allocator: std.mem.Allocator, src: []const u8) !struct { names: []ExposedName, body_search_start: usize, err: ?ExposeError } {
    var cur: Cursor = .{ .src = src };
    var names: std.ArrayList(ExposedName) = .empty;
    errdefer names.deinit(allocator);

    while (true) {
        skipInsignificant(&cur);
        if (!cur.startsWithKeyword("expose")) break;
        const expose_line = cur.line;
        const expose_col = cur.col;
        for (0.."expose".len) |_| cur.advance();

        const ws = cur.peek() orelse return .{ .names = &.{}, .body_search_start = 0, .err = .{ .line = cur.line, .col = cur.col, .message = "expected a name after 'expose'" } };
        if (ws != ' ' and ws != '\t') {
            return .{ .names = &.{}, .body_search_start = 0, .err = .{ .line = cur.line, .col = cur.col, .message = "expected whitespace after 'expose'" } };
        }
        while (cur.peek()) |b| {
            if (b != ' ' and b != '\t') break;
            cur.advance();
        }

        const name_start = cur.pos;
        const nb = cur.peek() orelse return .{ .names = &.{}, .body_search_start = 0, .err = .{ .line = cur.line, .col = cur.col, .message = "expected a name after 'expose'" } };
        if (!isIdentStart(nb)) {
            return .{ .names = &.{}, .body_search_start = 0, .err = .{ .line = cur.line, .col = cur.col, .message = "expected a name after 'expose'" } };
        }
        cur.advance();
        while (cur.peek()) |c| {
            if (!isIdentCont(c)) break;
            cur.advance();
        }
        const name = src[name_start..cur.pos];
        for (names.items) |existing| {
            if (std.mem.eql(u8, existing.name, name)) {
                return .{ .names = &.{}, .body_search_start = 0, .err = .{ .line = expose_line, .col = expose_col, .message = "duplicate 'expose' for the same name" } };
            }
        }
        try names.append(allocator, .{ .name = name, .line = expose_line, .col = expose_col });
    }

    return .{ .names = try names.toOwnedSlice(allocator), .body_search_start = cur.pos, .err = null };
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

/// From the byte right after a function's parameter-list opening `(`
/// (`paren_open_pos + 1`), finds the byte offset of that function's own
/// opening `{`. Deliberately does not track paren/bracket depth or
/// string-literal contents: a real Go function *signature* (parameter
/// list + optional return type) structurally can never contain a string
/// literal, and essentially never contains a bare `{` outside the
/// vanishingly-rare anonymous-struct-type parameter/return case, which is
/// an accepted, documented v1 gap rather than something worth real
/// parsing to handle. Comments are still skipped, since
/// `func Foo() /* returns { nothing } */ {` is real, valid Go.
fn findFuncOpenBrace(src: []const u8, paren_open_pos: usize) ?usize {
    var cur: Cursor = .{ .src = src, .pos = paren_open_pos + 1 };
    while (cur.peek()) |_| {
        skipInsignificant(&cur);
        if (cur.peek() == '{') return cur.pos;
        if (cur.peek() == null) break;
        cur.advance();
    }
    return null;
}

pub fn findComposers(allocator: std.mem.Allocator, src: []const u8) !struct { composers: []Composer, err: ?ExposeError } {
    const header = try parseHeader(allocator, src);
    if (header.err) |e| return .{ .composers = &.{}, .err = e };

    var composers: std.ArrayList(Composer) = .empty;
    errdefer composers.deinit(allocator);

    for (header.names) |exposed| {
        const paren_pos = findFuncSignature(src, header.body_search_start, exposed.name) orelse {
            return .{ .composers = &.{}, .err = .{
                .line = exposed.line,
                .col = exposed.col,
                .message = try std.fmt.allocPrint(allocator, "expose '{s}' has no matching 'func {s}(...) {{ ... }}' in this file", .{ exposed.name, exposed.name }),
            } };
        };
        const open_brace_pos = findFuncOpenBrace(src, paren_pos) orelse {
            return .{ .composers = &.{}, .err = .{
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
                return .{ .composers = &.{}, .err = .{ .line = perr.line, .col = perr.col, .message = perr.message } };
            }
            return e;
        };

        try composers.append(allocator, .{
            .name = exposed.name,
            .body = src[open_brace_pos + 1 .. body_end],
            .line = exposed.line,
            .col = exposed.col,
        });
    }

    return .{ .composers = try composers.toOwnedSlice(allocator), .err = null };
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
