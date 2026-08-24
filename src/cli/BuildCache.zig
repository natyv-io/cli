//! `natyv build`'s freshness check (`.ntx` tooling Stage 7 continued,
//! ~/.claude/plans/lexical-wishing-penguin.md). Quinn's own design:
//! check freshness once, up front, before running anything -- if nothing
//! that affects the compiled wasm has changed since the last successful
//! `wasm_compile`, `natyv build` skips straight to bundling instead of
//! redoing `prepare`/`wasm_compile`.
//!
//! Distinct from (and doesn't touch) the per-file `// source-hash: <hex>`
//! header `ntx/Codegen.zig` already embeds in each generated `.ntx`
//! output -- that one is a separate, still-to-be-built hard-error check
//! (a dev compiling generated code directly, bypassing `natyv prepare`
//! entirely, ends up with generated output that's diverged from its real
//! `.ntx` source). This is `natyv build`'s own internal "has anything
//! changed" cache, covering the guest directory's full real input
//! surface: every `.ntx`/`.ntss` source, every hand-written `.go` file
//! (anything that isn't itself pure `natyv prepare` output), and
//! `go.mod`/`go.sum` (a dependency bump should trigger a rebuild too).
//! Reuses `Codegen.sourceHashHex` -- exported specifically for this --
//! rather than reimplementing SHA-256+hex a second time.

const std = @import("std");
const Io = std.Io;
const Codegen = @import("Codegen");

const cache_file_name = ".natyv-build-cache";

fn isGeneratedFile(basename: []const u8) bool {
    return std.mem.endsWith(u8, basename, ".natyv.go") or std.mem.eql(u8, basename, "styletokens_generated.go");
}

fn isRelevantFile(basename: []const u8) bool {
    if (isGeneratedFile(basename)) return false;
    return std.mem.endsWith(u8, basename, ".go") or
        std.mem.endsWith(u8, basename, ".ntx") or
        std.mem.endsWith(u8, basename, ".ntss") or
        std.mem.eql(u8, basename, "go.mod") or
        std.mem.eql(u8, basename, "go.sum");
}

fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Computes one combined hash over every real input file in `guest_dir`
/// that affects the compiled wasm. Sorted by path first, so the result is
/// stable regardless of filesystem iteration order -- the same directory
/// hashed twice always produces the same digest.
pub fn computeSourceHash(allocator: std.mem.Allocator, io: Io, guest_dir: Io.Dir) ![64]u8 {
    var walker = try guest_dir.walk(allocator);
    defer walker.deinit();

    var paths: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!isRelevantFile(entry.basename)) continue;
        try paths.append(allocator, try allocator.dupe(u8, entry.path));
    }
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    var combined: std.ArrayList(u8) = .empty;
    for (paths.items) |path| {
        const content = try guest_dir.readFileAlloc(io, path, allocator, .unlimited);
        try combined.appendSlice(allocator, path);
        try combined.append(allocator, '\n');
        try combined.appendSlice(allocator, content);
        try combined.append(allocator, '\n');
    }

    return Codegen.sourceHashHex(combined.items);
}

/// `null` if no cache exists yet (first-ever build) or the file is
/// malformed -- either way, treated as "not fresh" by the caller, never
/// an error.
pub fn readCachedHash(allocator: std.mem.Allocator, io: Io, guest_dir: Io.Dir) !?[64]u8 {
    const content = guest_dir.readFileAlloc(io, cache_file_name, allocator, .limited(128)) catch |e| {
        if (e == error.FileNotFound) return null;
        return e;
    };
    if (content.len != 64) return null;
    var out: [64]u8 = undefined;
    @memcpy(&out, content[0..64]);
    return out;
}

pub fn writeCachedHash(io: Io, guest_dir: Io.Dir, hash: [64]u8) !void {
    try guest_dir.writeFile(io, .{ .sub_path = cache_file_name, .data = &hash });
}

/// True only if the compiled wasm still actually exists on disk (a fresh
/// hash with a since-deleted wasm has nothing to bundle) *and* the
/// guest directory's current combined source hash matches the one cached
/// after the last successful `wasm_compile`.
pub fn isFresh(allocator: std.mem.Allocator, io: Io, guest_dir: Io.Dir, wasm_basename: []const u8) !bool {
    guest_dir.access(io, wasm_basename, .{}) catch return false;
    const cached = try readCachedHash(allocator, io, guest_dir) orelse return false;
    const current = try computeSourceHash(allocator, io, guest_dir);
    return std.mem.eql(u8, &cached, &current);
}

test "computeSourceHash is stable across repeated calls over the same directory" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module x\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.go", .data = "package main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "page.go.ntx", .data = "package main\nexpose Page\n" });

    const first = try computeSourceHash(allocator, io, tmp.dir);
    const second = try computeSourceHash(allocator, io, tmp.dir);
    try std.testing.expectEqualStrings(&first, &second);
}

test "changing a .ntx file's content changes the hash" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "page.go.ntx", .data = "package main\nexpose Page\n" });
    const before = try computeSourceHash(allocator, io, tmp.dir);

    try tmp.dir.writeFile(io, .{ .sub_path = "page.go.ntx", .data = "package main\nexpose Page\n// edited\n" });
    const after = try computeSourceHash(allocator, io, tmp.dir);

    try std.testing.expect(!std.mem.eql(u8, &before, &after));
}

test "changing an unrelated hand-written .go file also changes the hash" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "main.go", .data = "package main\nfunc main() {}\n" });
    const before = try computeSourceHash(allocator, io, tmp.dir);

    try tmp.dir.writeFile(io, .{ .sub_path = "main.go", .data = "package main\nfunc main() { println(1) }\n" });
    const after = try computeSourceHash(allocator, io, tmp.dir);

    try std.testing.expect(!std.mem.eql(u8, &before, &after));
}

test "generated output files are excluded from the hash" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "page.go.ntx", .data = "package main\nexpose Page\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "page.natyv.go", .data = "// generated v1\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "styletokens_generated.go", .data = "// generated v1\n" });
    const before = try computeSourceHash(allocator, io, tmp.dir);

    // Rewriting the generated files (as a real `natyv prepare` re-run
    // would, even byte-for-byte identically) must never change the hash
    // -- only the real .ntx/.ntss/hand-written source should.
    try tmp.dir.writeFile(io, .{ .sub_path = "page.natyv.go", .data = "// generated v2, totally different\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "styletokens_generated.go", .data = "// generated v2, totally different\n" });
    const after = try computeSourceHash(allocator, io, tmp.dir);

    try std.testing.expectEqualStrings(&before, &after);
}

test "a go.mod change affects the hash" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module x\n\ngo 1.23\n" });
    const before = try computeSourceHash(allocator, io, tmp.dir);

    try tmp.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module x\n\ngo 1.23\n\nrequire y v1.0.0\n" });
    const after = try computeSourceHash(allocator, io, tmp.dir);

    try std.testing.expect(!std.mem.eql(u8, &before, &after));
}

test "readCachedHash/writeCachedHash round-trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expect(try readCachedHash(allocator, io, tmp.dir) == null);

    const hash = Codegen.sourceHashHex("hello");
    try writeCachedHash(io, tmp.dir, hash);

    const read_back = try readCachedHash(allocator, io, tmp.dir);
    try std.testing.expect(read_back != null);
    try std.testing.expectEqualStrings(&hash, &read_back.?);
}

test "isFresh: no cache yet is never fresh" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "app.wasm", .data = "fake wasm bytes" });
    try std.testing.expect(!(try isFresh(allocator, io, tmp.dir, "app.wasm")));
}

test "isFresh: a matching cached hash with the wasm present is fresh" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "main.go", .data = "package main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app.wasm", .data = "fake wasm bytes" });
    const hash = try computeSourceHash(allocator, io, tmp.dir);
    try writeCachedHash(io, tmp.dir, hash);

    try std.testing.expect(try isFresh(allocator, io, tmp.dir, "app.wasm"));
}

test "isFresh: a matching cached hash but a missing wasm is not fresh" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "main.go", .data = "package main\n" });
    const hash = try computeSourceHash(allocator, io, tmp.dir);
    try writeCachedHash(io, tmp.dir, hash);

    try std.testing.expect(!(try isFresh(allocator, io, tmp.dir, "app.wasm")));
}

test "isFresh: source changed since the cached hash is not fresh" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "main.go", .data = "package main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app.wasm", .data = "fake wasm bytes" });
    const hash = try computeSourceHash(allocator, io, tmp.dir);
    try writeCachedHash(io, tmp.dir, hash);

    try tmp.dir.writeFile(io, .{ .sub_path = "main.go", .data = "package main\nfunc main() {}\n" });
    try std.testing.expect(!(try isFresh(allocator, io, tmp.dir, "app.wasm")));
}
