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
//! (anything that isn't itself pure `natyv prepare` output),
//! `go.mod`/`go.sum` (a dependency bump should trigger a rebuild too),
//! and `conf.natyv.json`'s own `wasm_compile` string (a dev editing
//! compile flags -- e.g. adding `-no-debug` -- changes the compiled wasm
//! just as much as editing a source file does, so it's part of the same
//! input surface even though it doesn't live inside `guest_dir`; found
//! the hard way when a `wasm_compile` edit alone silently didn't trigger
//! a recompile), and the `toolchain` string -- the natyv CLI's own
//! version, which stands in for "whatever transpiler produced the
//! generated code." Reuses `Codegen.sourceHashHex` -- exported
//! specifically for this -- rather than reimplementing SHA-256+hex a
//! second time.
//!
//! **Why `toolchain` is in here (2026-09-23).** Generated output is a
//! function of the source files *and* the transpiler that read them, but
//! the hash only ever covered the first half, and it deliberately
//! excludes generated files (`isGeneratedFile`) so that re-running
//! `natyv prepare` isn't self-invalidating. So a codegen change with no
//! source change was invisible: `natyv build` printed "wasm is already up
//! to date" and bundled a stale wasm built by the *previous* transpiler.
//! Found for real while verifying mail-natyv against v0.2.0's new
//! Label/Button Fit-sizing defaults -- `natyv prepare` regenerated the Go
//! correctly and `natyv build` then skipped the recompile. Left unfixed
//! this would mean every existing app silently keeps its v0.1.0 wasm
//! after `brew upgrade natyv`, with nothing to explain why its layout
//! didn't change. Mixing the version in makes a release invalidate every
//! app's cache exactly once; the upgrade *to* the first version that has
//! this is covered too, since adding a value the old CLI never hashed
//! changes the digest by itself.

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
/// that affects the compiled wasm, plus `toolchain` (this binary's own
/// version -- see this file's header for why it belongs in the hash),
/// `wasm_compile` and
/// `recycle_threshold_mb` (the latter two live in `conf.natyv.json`, outside
/// `guest_dir`, but changing either changes what the compiled wasm must
/// actually support -- `recycle_threshold_mb` specifically gates whether
/// codegen emits real handler-reattachment/ref-persistence plumbing at
/// all, so flipping it with zero `.ntx`/`.go` edits must still invalidate
/// the cache, the same class of gap `wasm_compile`'s own inclusion here
/// already fixed once). Sorted by path first, so the result is stable
/// regardless of filesystem iteration order -- the same directory hashed
/// twice always produces the same digest.
pub fn computeSourceHash(allocator: std.mem.Allocator, io: Io, guest_dir: Io.Dir, toolchain: []const u8, wasm_compile: []const u8, recycle_threshold_mb: ?u32) ![64]u8 {
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
    try combined.appendSlice(allocator, toolchain);
    try combined.append(allocator, '\n');
    try combined.appendSlice(allocator, wasm_compile);
    try combined.append(allocator, '\n');
    if (recycle_threshold_mb) |mb| {
        try combined.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}\n", .{mb}));
    } else {
        try combined.appendSlice(allocator, "null\n");
    }
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
/// guest directory's current combined source hash (including the current
/// `toolchain` string, `wasm_compile` string and `recycle_threshold_mb`)
/// matches the one cached after the last successful `wasm_compile`.
pub fn isFresh(allocator: std.mem.Allocator, io: Io, guest_dir: Io.Dir, wasm_basename: []const u8, toolchain: []const u8, wasm_compile: []const u8, recycle_threshold_mb: ?u32) !bool {
    guest_dir.access(io, wasm_basename, .{}) catch return false;
    const cached = try readCachedHash(allocator, io, guest_dir) orelse return false;
    const current = try computeSourceHash(allocator, io, guest_dir, toolchain, wasm_compile, recycle_threshold_mb);
    return std.mem.eql(u8, &cached, &current);
}

/// Stand-in toolchain version for the tests below -- these exercise the
/// guest-directory side of the hash, so they hold it fixed and the two
/// tests that specifically cover toolchain invalidation vary it instead.
const test_toolchain = "0.0.0-test";

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

    const first = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", null);
    const second = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", null);
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
    const before = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", null);

    try tmp.dir.writeFile(io, .{ .sub_path = "page.go.ntx", .data = "package main\nexpose Page\n// edited\n" });
    const after = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", null);

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
    const before = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", null);

    try tmp.dir.writeFile(io, .{ .sub_path = "main.go", .data = "package main\nfunc main() { println(1) }\n" });
    const after = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", null);

    try std.testing.expect(!std.mem.eql(u8, &before, &after));
}

test "changing wasm_compile alone changes the hash" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "main.go", .data = "package main\nfunc main() {}\n" });
    const before = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", null);

    // Same source files, only the compile command itself changes (e.g. a
    // dev adding -no-debug) -- this must be caught the same way an edited
    // source file is, since it changes the compiled wasm just as much.
    const after = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -no-debug -o app.wasm .", null);

    try std.testing.expect(!std.mem.eql(u8, &before, &after));
}

test "changing the toolchain version alone changes the hash" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "page.go.ntx", .data = "package main\nexpose Page\n" });
    const before = try computeSourceHash(allocator, io, tmp.dir, "0.1.0", "tinygo build -o app.wasm .", null);

    // Byte-identical sources, a newer natyv. The transpiler that reads
    // those sources is half of what determines the generated output, so
    // this has to invalidate exactly like an edited source file does --
    // otherwise `brew upgrade natyv` leaves every app on the wasm its
    // previous transpiler produced.
    const after = try computeSourceHash(allocator, io, tmp.dir, "0.2.0", "tinygo build -o app.wasm .", null);

    try std.testing.expect(!std.mem.eql(u8, &before, &after));
}

test "isFresh: a cache written by an older toolchain is not fresh" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "app.wasm", .data = "fake wasm bytes" });
    try tmp.dir.writeFile(io, .{ .sub_path = "page.go.ntx", .data = "package main\nexpose Page\n" });

    // What the previous release left behind after its own successful build.
    const old_hash = try computeSourceHash(allocator, io, tmp.dir, "0.1.0", "tinygo build -o app.wasm .", null);
    try writeCachedHash(io, tmp.dir, old_hash);

    // Same app, same wasm on disk, newer CLI asking.
    try std.testing.expect(!(try isFresh(allocator, io, tmp.dir, "app.wasm", "0.2.0", "tinygo build -o app.wasm .", null)));
    // ...and the same CLI that wrote it still sees a real cache hit, so
    // this costs nothing on the ordinary no-upgrade path.
    try std.testing.expect(try isFresh(allocator, io, tmp.dir, "app.wasm", "0.1.0", "tinygo build -o app.wasm .", null));
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
    const before = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", null);

    // Rewriting the generated files (as a real `natyv prepare` re-run
    // would, even byte-for-byte identically) must never change the hash
    // -- only the real .ntx/.ntss/hand-written source should.
    try tmp.dir.writeFile(io, .{ .sub_path = "page.natyv.go", .data = "// generated v2, totally different\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "styletokens_generated.go", .data = "// generated v2, totally different\n" });
    const after = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", null);

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
    const before = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", null);

    try tmp.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module x\n\ngo 1.23\n\nrequire y v1.0.0\n" });
    const after = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", null);

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
    try std.testing.expect(!(try isFresh(allocator, io, tmp.dir, "app.wasm", test_toolchain, "tinygo build -o app.wasm .", null)));
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
    const hash = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", null);
    try writeCachedHash(io, tmp.dir, hash);

    try std.testing.expect(try isFresh(allocator, io, tmp.dir, "app.wasm", test_toolchain, "tinygo build -o app.wasm .", null));
}

test "isFresh: a matching cached hash but a missing wasm is not fresh" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "main.go", .data = "package main\n" });
    const hash = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", null);
    try writeCachedHash(io, tmp.dir, hash);

    try std.testing.expect(!(try isFresh(allocator, io, tmp.dir, "app.wasm", test_toolchain, "tinygo build -o app.wasm .", null)));
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
    const hash = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", null);
    try writeCachedHash(io, tmp.dir, hash);

    try tmp.dir.writeFile(io, .{ .sub_path = "main.go", .data = "package main\nfunc main() {}\n" });
    try std.testing.expect(!(try isFresh(allocator, io, tmp.dir, "app.wasm", test_toolchain, "tinygo build -o app.wasm .", null)));
}

test "isFresh: wasm_compile changed since the cached hash is not fresh" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "main.go", .data = "package main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app.wasm", .data = "fake wasm bytes" });
    const hash = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", null);
    try writeCachedHash(io, tmp.dir, hash);

    // No source file touched at all -- only conf.natyv.json's wasm_compile
    // itself changed (e.g. a dev adding -no-debug). Must not be reported
    // fresh, since the previously-compiled wasm no longer reflects the
    // current compile command.
    try std.testing.expect(!(try isFresh(allocator, io, tmp.dir, "app.wasm", test_toolchain, "tinygo build -no-debug -o app.wasm .", null)));
}

test "isFresh: recycle_threshold_mb changed since the cached hash is not fresh" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "main.go", .data = "package main\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "app.wasm", .data = "fake wasm bytes" });
    const hash = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", null);
    try writeCachedHash(io, tmp.dir, hash);

    // No source file touched at all -- only conf.natyv.json's
    // memory.recycle_threshold_mb itself changed (null -> a real value,
    // opting an already-built app into recycling). Must not be reported
    // fresh: the previously-compiled wasm was built without any handler-
    // reattachment/ref-persistence codegen, so the host would believe
    // recycling is safe for a guest that was never built to support it.
    try std.testing.expect(!(try isFresh(allocator, io, tmp.dir, "app.wasm", test_toolchain, "tinygo build -o app.wasm .", 105)));

    // Round-trip: caching the new value makes it fresh again, and a
    // *different* nonzero value still invalidates (not just "null vs.
    // set").
    const hash_with_threshold = try computeSourceHash(allocator, io, tmp.dir, test_toolchain, "tinygo build -o app.wasm .", 105);
    try writeCachedHash(io, tmp.dir, hash_with_threshold);
    try std.testing.expect(try isFresh(allocator, io, tmp.dir, "app.wasm", test_toolchain, "tinygo build -o app.wasm .", 105));
    try std.testing.expect(!(try isFresh(allocator, io, tmp.dir, "app.wasm", test_toolchain, "tinygo build -o app.wasm .", 80)));
}
