//! `.ntx` LSP position-mapping spike (see
//! `~/.claude/plans/lexical-wishing-penguin.md`): two small, pure lookup
//! functions over `Codegen.SourceMapping` -- no parser/codegen knowledge
//! needed here at all, matching this project's own established split
//! between pure lookup logic and the real emission code that produces its
//! input (e.g. `PkgConfig.zig`'s `parseCflags`/`parseLibs`).
//!
//! `ntxToGenerated` is the direction a real LSP needs to *forward* a
//! request (hover, go-to-definition) from the real `.ntx` document to the
//! virtual generated one; `generatedToNtx` is the direction needed to map
//! the backend language server's response (e.g. gopls, working entirely
//! in generated-Go-document terms) back to a real `.ntx` position for the
//! editor. Deliberately narrow: only positions `Codegen.zig` actually
//! recorded a mapping for (today, just an `on[A-Z]...` event-handler
//! attribute's own position) resolve to anything -- everything else is a
//! clean `null`, not a guess.

const std = @import("std");
const Codegen = @import("Codegen.zig");

/// Matches `(line, col)` against any position *inside* a recorded
/// mapping's own `.ntx`-side span (`[ntx_col, ntx_col + ntx_len)` on
/// `ntx_line`), not just its exact first character -- a real fix, not the
/// original design: a plain exact-position match only ever resolved a
/// request landing on a token's very first byte, which real mouse-driven
/// hover requests essentially never do (confirmed live during `.ntx` LSP
/// Stage 5's own VS Code click-through -- hovering mid-word, e.g. over the
/// "S" in "handleSave" rather than its leading "h", returned nothing under
/// the old exact-match behavior). Always returns the *whole* token's own
/// `[gen_start, gen_end)` regardless of where within its span `col` fell,
/// since a real backend language server's hover/go-to-definition result is
/// the same for any position inside one identifier.
pub fn ntxToGenerated(map: []const Codegen.SourceMapping, line: u32, col: u32) ?struct { start: usize, end: usize, ntx_col: u32, ntx_len: u32 } {
    for (map) |m| {
        if (m.ntx_line == line and col >= m.ntx_col and col < m.ntx_col + m.ntx_len) return .{ .start = m.gen_start, .end = m.gen_end, .ntx_col = m.ntx_col, .ntx_len = m.ntx_len };
    }
    return null;
}

/// Finds the recorded mapping whose generated-side range `[gen_start,
/// gen_end)` contains `offset`, and returns its `.ntx`-side position.
pub fn generatedToNtx(map: []const Codegen.SourceMapping, offset: usize) ?struct { line: u32, col: u32 } {
    for (map) |m| {
        if (offset >= m.gen_start and offset < m.gen_end) return .{ .line = m.ntx_line, .col = m.ntx_col };
    }
    return null;
}

/// Converts a byte offset into `text` to a 0-based LSP `{line, character}`
/// position -- needed by Stage 5 (`gopls` proxying) to translate a
/// `SourceMapping`'s byte-offset-based `gen_start` into the line/character
/// shape the real LSP `textDocument/hover` request to `gopls` requires.
/// `character` is computed as a UTF-8 byte offset within the line, not a
/// UTF-16 code unit count -- a deliberate, documented scope limit (real
/// LSP `character` is UTF-16 by default unless a client/server negotiate
/// otherwise): correct for any ASCII content, which covers every real
/// Stage 5 hover target (Go identifiers/keywords), and only wrong for a
/// position landing inside a multi-byte UTF-8 sequence earlier on the same
/// line -- not a case hovering over an identifier ever hits.
pub fn offsetToPosition(text: []const u8, offset: usize) struct { line: u32, character: u32 } {
    var line: u32 = 0;
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < offset and i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            line += 1;
            line_start = i + 1;
        }
    }
    return .{ .line = line, .character = @intCast(offset - line_start) };
}

/// The inverse of `offsetToPosition` -- converts a 0-based LSP
/// `{line, character}` position (as returned by `gopls`'s own hover
/// response) back to a byte offset into `text`, ready to feed into
/// `generatedToNtx`. Same UTF-8-byte-offset scope limit as
/// `offsetToPosition`. A `line`/`character` past the end of `text` clamps
/// to `text.len`, rather than indexing out of bounds -- a defensive
/// clamp, not a real expected input (a well-behaved `gopls` never reports
/// a position outside the document it was just handed).
pub fn positionToOffset(text: []const u8, line: u32, character: u32) usize {
    var cur_line: u32 = 0;
    var i: usize = 0;
    while (cur_line < line and i < text.len) : (i += 1) {
        if (text[i] == '\n') cur_line += 1;
    }
    const line_start = i;
    var end = line_start;
    while (end < text.len and text[end] != '\n') : (end += 1) {}
    const offset = line_start + character;
    return @min(offset, end);
}

test "offsetToPosition: offset 0 is always line 0, character 0" {
    const pos = offsetToPosition("hello\nworld", 0);
    try std.testing.expectEqual(@as(u32, 0), pos.line);
    try std.testing.expectEqual(@as(u32, 0), pos.character);
}

test "offsetToPosition: an offset on a later line resets character to count from that line's own start" {
    const text = "line one\nline two\nline three";
    // "line two" starts at offset 9; "two" itself starts at offset 14.
    const pos = offsetToPosition(text, 14);
    try std.testing.expectEqual(@as(u32, 1), pos.line);
    try std.testing.expectEqual(@as(u32, 5), pos.character);
}

test "positionToOffset: round-trips exactly with offsetToPosition" {
    const text = "line one\nline two\nline three";
    for ([_]usize{ 0, 5, 9, 14, 20, text.len - 1 }) |offset| {
        const pos = offsetToPosition(text, offset);
        try std.testing.expectEqual(offset, positionToOffset(text, pos.line, pos.character));
    }
}

test "positionToOffset: a character past the end of a real line clamps to that line's own end" {
    const text = "short\nlonger line here";
    // Line 0 ("short") is only 5 bytes -- character 99 must clamp to 5, not
    // spill into line 1's own bytes.
    try std.testing.expectEqual(@as(usize, 5), positionToOffset(text, 0, 99));
}

test "ntxToGenerated: empty map always misses" {
    try std.testing.expect(ntxToGenerated(&.{}, 3, 5) == null);
}

test "ntxToGenerated: a token's own start position hits" {
    const map = [_]Codegen.SourceMapping{
        .{ .ntx_line = 3, .ntx_col = 20, .ntx_len = 10, .gen_start = 10, .gen_end = 20, .kind = .event_handler },
    };
    const hit = ntxToGenerated(&map, 3, 20).?;
    try std.testing.expectEqual(@as(usize, 10), hit.start);
    try std.testing.expectEqual(@as(usize, 20), hit.end);
    try std.testing.expectEqual(@as(u32, 20), hit.ntx_col);
    try std.testing.expectEqual(@as(u32, 10), hit.ntx_len);
}

test "ntxToGenerated: any position inside the token's own span hits too, not just its first character" {
    // A real fix, not the original design -- a real mouse-driven hover
    // request almost never lands on a token's very first byte. `ntx_len =
    // 10` here spans columns 20 through 29 inclusive (`[20, 30)`).
    const map = [_]Codegen.SourceMapping{
        .{ .ntx_line = 3, .ntx_col = 20, .ntx_len = 10, .gen_start = 10, .gen_end = 20, .kind = .event_handler },
    };
    try std.testing.expect(ntxToGenerated(&map, 3, 25).?.start == 10); // mid-token
    try std.testing.expect(ntxToGenerated(&map, 3, 29) != null); // last real byte
    try std.testing.expect(ntxToGenerated(&map, 3, 30) == null); // one past the end: a real miss
    try std.testing.expect(ntxToGenerated(&map, 3, 19) == null); // one before the start: a real miss
    try std.testing.expect(ntxToGenerated(&map, 4, 25) == null); // right span, wrong line
}

test "generatedToNtx: empty map always misses" {
    try std.testing.expect(generatedToNtx(&.{}, 15) == null);
}

test "generatedToNtx: an offset inside the range hits, the exclusive end and anything outside misses" {
    const map = [_]Codegen.SourceMapping{
        .{ .ntx_line = 3, .ntx_col = 20, .ntx_len = 5, .gen_start = 10, .gen_end = 20, .kind = .event_handler },
    };
    const hit = generatedToNtx(&map, 15).?;
    try std.testing.expectEqual(@as(u32, 3), hit.line);
    try std.testing.expectEqual(@as(u32, 20), hit.col);

    // The range's own start is inclusive...
    try std.testing.expect(generatedToNtx(&map, 10) != null);
    // ...but its end is exclusive, matching `[start, end)` slicing convention.
    try std.testing.expect(generatedToNtx(&map, 20) == null);
    try std.testing.expect(generatedToNtx(&map, 9) == null);
}

test "generatedToNtx: an offset between two entries resolves to the containing one, not its neighbor" {
    const map = [_]Codegen.SourceMapping{
        .{ .ntx_line = 3, .ntx_col = 20, .ntx_len = 5, .gen_start = 10, .gen_end = 20, .kind = .event_handler },
        .{ .ntx_line = 5, .ntx_col = 8, .ntx_len = 5, .gen_start = 30, .gen_end = 40, .kind = .event_handler },
    };
    try std.testing.expect(generatedToNtx(&map, 25) == null);
    const second = generatedToNtx(&map, 35).?;
    try std.testing.expectEqual(@as(u32, 5), second.line);
    try std.testing.expectEqual(@as(u32, 8), second.col);
}
