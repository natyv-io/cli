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

/// Exact `(line, col)` match against a recorded mapping's own `.ntx`-side
/// position -- `Codegen.zig` only ever records one entry per attribute,
/// at that attribute's own start position, so an exact match is the
/// right (and only) lookup shape for now.
pub fn ntxToGenerated(map: []const Codegen.SourceMapping, line: u32, col: u32) ?struct { start: usize, end: usize } {
    for (map) |m| {
        if (m.ntx_line == line and m.ntx_col == col) return .{ .start = m.gen_start, .end = m.gen_end };
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

test "ntxToGenerated: empty map always misses" {
    try std.testing.expect(ntxToGenerated(&.{}, 3, 5) == null);
}

test "ntxToGenerated: exact line/col match hits, anything else misses" {
    const map = [_]Codegen.SourceMapping{
        .{ .ntx_line = 3, .ntx_col = 20, .gen_start = 10, .gen_end = 20, .kind = .event_handler },
    };
    const hit = ntxToGenerated(&map, 3, 20).?;
    try std.testing.expectEqual(@as(usize, 10), hit.start);
    try std.testing.expectEqual(@as(usize, 20), hit.end);

    try std.testing.expect(ntxToGenerated(&map, 3, 21) == null);
    try std.testing.expect(ntxToGenerated(&map, 4, 20) == null);
}

test "generatedToNtx: empty map always misses" {
    try std.testing.expect(generatedToNtx(&.{}, 15) == null);
}

test "generatedToNtx: an offset inside the range hits, the exclusive end and anything outside misses" {
    const map = [_]Codegen.SourceMapping{
        .{ .ntx_line = 3, .ntx_col = 20, .gen_start = 10, .gen_end = 20, .kind = .event_handler },
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
        .{ .ntx_line = 3, .ntx_col = 20, .gen_start = 10, .gen_end = 20, .kind = .event_handler },
        .{ .ntx_line = 5, .ntx_col = 8, .gen_start = 30, .gen_end = 40, .kind = .event_handler },
    };
    try std.testing.expect(generatedToNtx(&map, 25) == null);
    const second = generatedToNtx(&map, 35).?;
    try std.testing.expectEqual(@as(u32, 5), second.line);
    try std.testing.expectEqual(@as(u32, 8), second.col);
}
