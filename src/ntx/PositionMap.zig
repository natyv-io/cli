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

/// Matches `(line, col)` against any position *inside or immediately after*
/// a recorded mapping's own `.ntx`-side span (`[ntx_col, ntx_col +
/// ntx_len]` on `ntx_line`, inclusive of the position one past the last
/// real character), not just its exact first character -- a real fix, not
/// the original design: a plain exact-position match only ever resolved a
/// request landing on a token's very first byte, which real mouse-driven
/// hover requests essentially never do (confirmed live during `.ntx` LSP
/// Stage 5's own VS Code click-through -- hovering mid-word, e.g. over the
/// "S" in "handleSave" rather than its leading "h", returned nothing under
/// the old exact-match behavior). The upper bound is *inclusive* (unlike
/// `generatedToNtx`'s own `[start, end)` convention below) specifically
/// for real-time completion (Stage 6): a completion request's cursor sits
/// immediately *after* the last character of whatever's been typed so far
/// (`onClick={handle|}`, cursor right after "e") -- an exclusive upper
/// bound would miss exactly that position, the one completion actually
/// needs. Always returns the *whole* token's own `[gen_start, gen_end)`
/// regardless of where within its span `col` fell, since a real backend
/// language server's hover/go-to-definition result is the same for any
/// position inside one identifier.
pub fn ntxToGenerated(map: []const Codegen.SourceMapping, line: u32, col: u32) ?struct { start: usize, end: usize, ntx_col: u32, ntx_len: u32 } {
    for (map) |m| {
        if (m.ntx_line == line and col >= m.ntx_col and col <= m.ntx_col + m.ntx_len) return .{ .start = m.gen_start, .end = m.gen_end, .ntx_col = m.ntx_col, .ntx_len = m.ntx_len };
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

/// `.ntx` LSP Stage 7: maps a byte offset in the *original* `.ntx` source
/// to the corresponding byte offset in `Codegen.Output.logic` -- the
/// spliced logic file where hand-written code (an `onClick` handler's own
/// body, its doc comment, etc.) actually lives untouched. A piecewise-
/// constant-offset problem, not full per-token tracking like
/// `ntxToGenerated` needs: `edits` (`Codegen.Output.edits`, sorted by
/// `start`) only ever *removes* text (a composer's own body/`expose`
/// line) or replaces it with a short forwarding call -- everything else
/// in the file is copied through byte-for-byte, so a position outside
/// every edit's own span just shifts by the running total of
/// `(original_span_len - replacement_len)` for every edit fully before
/// it. `null` when `ntx_offset` falls *inside* an edit's own original
/// span (the composer body/`expose` line itself) -- that text was
/// spliced *out* of the logic file entirely, so there's no real
/// correspondence to map to.
pub fn ntxToLogic(edits: []const Codegen.Edit, ntx_offset: usize) ?usize {
    var shift: i64 = 0;
    for (edits) |e| {
        if (ntx_offset >= e.start and ntx_offset < e.end) return null;
        if (e.end <= ntx_offset) {
            shift += @as(i64, @intCast(e.end - e.start)) - @as(i64, @intCast(e.replacement.len));
        }
    }
    return @intCast(@as(i64, @intCast(ntx_offset)) - shift);
}

/// The inverse of `ntxToLogic` -- maps a byte offset in the real logic
/// file back to the original `.ntx` source. `null` when `logic_offset`
/// falls inside one of `edits`'s own synthetic *replacement* text (e.g.
/// the generated `return natyvBuildForm(parent)` forwarding call) -- that
/// text was never in the `.ntx` source at all, so there's nothing real to
/// map back to.
pub fn logicToNtx(edits: []const Codegen.Edit, logic_offset: usize) ?usize {
    var ntx_cursor: usize = 0;
    var logic_cursor: usize = 0;
    for (edits) |e| {
        const gap_len = e.start - ntx_cursor;
        if (logic_offset < logic_cursor + gap_len) return ntx_cursor + (logic_offset - logic_cursor);
        logic_cursor += gap_len;
        ntx_cursor = e.start;

        if (logic_offset < logic_cursor + e.replacement.len) return null;
        logic_cursor += e.replacement.len;
        ntx_cursor = e.end;
    }
    return ntx_cursor + (logic_offset - logic_cursor);
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
    try std.testing.expect(ntxToGenerated(&map, 3, 19) == null); // one before the start: a real miss
    try std.testing.expect(ntxToGenerated(&map, 4, 25) == null); // right span, wrong line
}

test "ntxToGenerated: the position immediately after the token's last byte also hits -- the real completion-cursor case" {
    // `ntx_len = 10` spans columns 20 through 29 inclusive; column 30 is
    // one past the last real character -- exactly where a completion
    // request's cursor sits right after typing "handleSave" and asking
    // for suggestions (`{handleSave|}`). Column 31 (two past) is a real
    // miss -- the inclusive bound extends by exactly one, not open-ended.
    const map = [_]Codegen.SourceMapping{
        .{ .ntx_line = 3, .ntx_col = 20, .ntx_len = 10, .gen_start = 10, .gen_end = 20, .kind = .event_handler },
    };
    try std.testing.expect(ntxToGenerated(&map, 3, 30) != null);
    try std.testing.expect(ntxToGenerated(&map, 3, 31) == null);
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

// `ntxToLogic`/`logicToNtx` fixture, conceptually: a `.ntx` source shaped
// like `[header][expose-line][middle][composer-body][tail]` --
//   [0, 10)  header, untouched
//   [10, 20) the `expose` line, spliced out entirely (replacement "")
//   [20, 30) untouched code between the expose line and the composer
//   [30, 50) the composer's own markup body, replaced with an 11-byte
//            forwarding call ("RETURN_CALL")
//   [50, ..) tail, untouched
// matching `Codegen.zig`'s own real edit shape (`uses`/`expose` lines get
// a `""` replacement, a composer body gets a real forwarding-call
// replacement), just with placeholder text instead of real Go/`.ntx`
// source, to keep the arithmetic easy to hand-verify.
const edit_fixture = [_]Codegen.Edit{
    .{ .start = 10, .end = 20, .replacement = "" },
    .{ .start = 30, .end = 50, .replacement = "RETURN_CALL" },
};

test "ntxToLogic: empty edit list is the identity mapping" {
    try std.testing.expectEqual(@as(usize, 5), ntxToLogic(&.{}, 5).?);
    try std.testing.expectEqual(@as(usize, 1000), ntxToLogic(&.{}, 1000).?);
}

test "ntxToLogic: a position before any edit is unshifted" {
    try std.testing.expectEqual(@as(usize, 5), ntxToLogic(&edit_fixture, 5).?);
}

test "ntxToLogic: a position inside a spliced-out span is a clean null" {
    try std.testing.expect(ntxToLogic(&edit_fixture, 15) == null); // inside the expose line
    try std.testing.expect(ntxToLogic(&edit_fixture, 45) == null); // inside the composer body
}

test "ntxToLogic: a position between two edits shifts by the first edit's own delta only" {
    // ntx 25 is 5 bytes into the untouched [20,30) region; the expose
    // line's own 10-byte deletion (10 removed, 0 replacement) shifts
    // everything after it left by 10 -- logic offset 15, not 25.
    try std.testing.expectEqual(@as(usize, 15), ntxToLogic(&edit_fixture, 25).?);
}

test "ntxToLogic: a position after both edits shifts by their combined delta" {
    // Expose line: -10 (10 removed, 0 replacement). Composer body: -9 (20
    // removed, 11-byte replacement). Combined shift: 19. ntx 55 -> 36.
    try std.testing.expectEqual(@as(usize, 36), ntxToLogic(&edit_fixture, 55).?);
}

test "logicToNtx: round-trips exactly with ntxToLogic for every real (non-spliced-out) ntx offset" {
    for ([_]usize{ 0, 5, 9, 25, 29, 55, 100 }) |ntx_offset| {
        const logic_offset = ntxToLogic(&edit_fixture, ntx_offset).?;
        try std.testing.expectEqual(ntx_offset, logicToNtx(&edit_fixture, logic_offset).?);
    }
}

test "logicToNtx: a position inside a replacement's own synthetic text is a clean null" {
    // Logic offset 25 falls inside "RETURN_CALL" (logic [20, 31)) -- text
    // that was never in the real `.ntx` source at all.
    try std.testing.expect(logicToNtx(&edit_fixture, 25) == null);
}
