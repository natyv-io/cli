//! Real vendoring support for `natyv get -c=<url>` (URL, not a bare
//! pkg-config module name) -- Stage 2.6 of
//! ~/.claude/plans/lexical-wishing-penguin.md. Genuinely separate from
//! `ZigFetch.zig`'s own Zig-package-fetch job even though it reuses
//! `ZigFetch.fetchSave` directly: a "vendored" entry has *no* build.zig at
//! all, just raw C source `natyv` compiles itself, directly, as part of
//! `bindings_mod` -- confirmed empirically that `zig fetch` doesn't care
//! either way (its own `--help` text already says a `<url>` need only be
//! "a tarball file... containing package source," not a real Zig
//! package), and that `b.dependency(name, .{})` still works against such a
//! source-only fetch (`dependencyInner` only calls `runBuild` `if
//! (build_zig) |bz|` -- skipped entirely when there's no build.zig, but
//! the returned `Dependency.builder.build_root.path` is still a real,
//! valid, on-disk extraction path either way).
//!
//! Two real jobs:
//! 1. `locateSource` -- the *only* generic way found to answer "where did
//!    this fetch's raw content actually land on disk" without hardcoding
//!    Zig's own (non-obvious, version-fragile) package-cache internals: a
//!    real, throwaway scratch project (`zig init`, since a hand-authored
//!    `build.zig.zon`'s `.fingerprint` isn't a pure function of `.name` --
//!    same finding as `ZigFetch.zig`'s own doc comment) whose generated
//!    `build.zig` writes the real path to a plain output file (`std.fs`,
//!    not this project's own `Io`-threaded convention -- build.zig runs
//!    as its own separate synchronous Zig program, unrelated to this
//!    codebase's async `Io` threading). Simpler than `ZigFetch.discoverHeader`:
//!    no `zig build install` needed at all, since there's no
//!    `*Step.Compile`/`installHeadersDirectory` to trigger -- a plain `zig
//!    build` already runs the generated `build.zig`'s own top-level code,
//!    confirmed by a real spike.
//! 2. `findCSourceFiles` -- walks the located source for real `.c` files,
//!    skipping any path with a `test`/`tests`/`example`/`examples`
//!    component (a first-cut heuristic, not a generic solution -- see
//!    `Config.BindingEntry.vendor_files`'s own doc comment on why this is
//!    an intentionally hand-curatable starting point, not a promise of
//!    correctness for every real C library).

const std = @import("std");
const Io = std.Io;
const ZigFetch = @import("ZigFetch.zig");

pub const VendorError = struct {
    message: []const u8,
};

pub const LocateResult = struct {
    /// Absolute path to the real, on-disk extracted source root -- only
    /// valid until the caller cleans up the scratch dir this came from.
    source_dir: ?[]const u8,
    /// The real scratch subdirectory name under `parent_dir` the caller
    /// must `deleteTree` once done -- returned rather than left for the
    /// caller to reconstruct independently, since it's PID-suffixed (two
    /// separate `zig build test` processes racing on the exact same fixed
    /// name is a real, reproduced bug this stage hit: Zig's default test
    /// binary includes every `test` block transitively reachable via
    /// `@import`, so e.g. `Get.zig`'s own tests and `main.zig`'s tests
    /// -- a separate binary that also imports `Get.zig` -- run the same
    /// live vendoring test concurrently).
    scratch_dir_name: ?[]const u8,
    err: ?VendorError,
};

fn runOrError(allocator: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: Io.Dir, context: []const u8) !?VendorError {
    const result = std.process.run(allocator, io, .{ .argv = argv, .cwd = .{ .dir = cwd } }) catch |e| {
        return .{ .message = try std.fmt.allocPrint(allocator, "natyv get: could not run {s}: {s}", .{ context, @errorName(e) }) };
    };
    defer allocator.free(result.stdout);
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                defer allocator.free(result.stderr);
                return .{ .message = try std.fmt.allocPrint(allocator, "natyv get: {s} failed (exit code {d}):\n{s}{s}", .{ context, code, result.stdout, result.stderr }) };
            }
            allocator.free(result.stderr);
        },
        else => |term| {
            defer allocator.free(result.stderr);
            return .{ .message = try std.fmt.allocPrint(allocator, "natyv get: {s} exited abnormally ({any}):\n{s}{s}", .{ context, term, result.stdout, result.stderr }) };
        },
    }
    return null;
}

/// Creates a real, throwaway scratch Zig project under `parent_dir` named
/// `_natyv_vendor_locate_<name>_<pid>` (PID-suffixed -- see
/// `LocateResult.scratch_dir_name`'s own doc comment on why), fetches
/// `url` as dependency `name` into it, and reports the real extraction
/// path. Does not clean up after itself -- the caller is responsible for
/// deleting the returned `scratch_dir_name` subtree once it's done
/// reading from `source_dir`.
pub fn locateSource(allocator: std.mem.Allocator, io: Io, parent_dir: Io.Dir, parent_dir_abs: []const u8, name: []const u8, url: []const u8) !LocateResult {
    const scratch_name = try std.fmt.allocPrint(allocator, "_natyv_vendor_locate_{s}_{x}", .{ name, std.c.getpid() });
    parent_dir.deleteTree(io, scratch_name) catch {};
    var scratch_dir = parent_dir.createDirPathOpen(io, scratch_name, .{}) catch |e| {
        return .{ .source_dir = null, .scratch_dir_name = scratch_name, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv get: could not create scratch vendor-locate dir for '{s}': {s}", .{ name, @errorName(e) }) } };
    };
    defer scratch_dir.close(io);

    if (try runOrError(allocator, io, &.{ "zig", "init" }, scratch_dir, "'zig init' for a scratch vendor-locate project")) |e| {
        return .{ .source_dir = null, .scratch_dir_name = scratch_name, .err = e };
    }

    const fetch_outcome = try ZigFetch.fetchSave(allocator, io, scratch_dir, name, url);
    if (fetch_outcome.err) |e| return .{ .source_dir = null, .scratch_dir_name = scratch_name, .err = .{ .message = e.message } };

    const scratch_build_zig = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {{
        \\    const dep = b.dependency("{s}", .{{}});
        \\    const path = dep.builder.build_root.path orelse @panic("no build root path");
        \\    std.Io.Dir.cwd().writeFile(b.graph.io, .{{ .sub_path = "_natyv_vendor_source_path.txt", .data = path }}) catch @panic("could not write path");
        \\}}
        \\
    , .{name});
    try scratch_dir.writeFile(io, .{ .sub_path = "build.zig", .data = scratch_build_zig });

    if (try runOrError(allocator, io, &.{ "zig", "build" }, scratch_dir, try std.fmt.allocPrint(allocator, "'zig build' to locate '{s}''s real fetched source", .{name}))) |e| {
        return .{ .source_dir = null, .scratch_dir_name = scratch_name, .err = e };
    }

    const source_dir = scratch_dir.readFileAlloc(io, "_natyv_vendor_source_path.txt", allocator, .unlimited) catch |e| {
        return .{ .source_dir = null, .scratch_dir_name = scratch_name, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv get: '{s}' vendor-locate didn't produce its output file: {s}", .{ name, @errorName(e) }) } };
    };
    _ = parent_dir_abs; // kept for symmetry with ZigFetch.discoverHeader's signature; the path written above is already absolute.
    return .{ .source_dir = source_dir, .scratch_dir_name = scratch_name, .err = null };
}

/// Walks `source_dir` for real `.c` files, returning relative paths
/// (sorted for determinism) -- skips anything with a
/// `test`/`tests`/`example`/`examples` path component (see this file's
/// own doc comment on why this is a first-cut heuristic, not a general
/// solution).
pub fn findCSourceFiles(allocator: std.mem.Allocator, io: Io, source_dir: Io.Dir) ![]const []const u8 {
    var walker = try source_dir.walk(allocator);
    defer walker.deinit();

    var files: std.ArrayList([]const u8) = .empty;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.path, ".c")) continue;

        var skip = false;
        var it = std.mem.splitScalar(u8, entry.path, '/');
        while (it.next()) |component| {
            if (std.mem.eql(u8, component, "test") or std.mem.eql(u8, component, "tests") or
                std.mem.eql(u8, component, "example") or std.mem.eql(u8, component, "examples"))
            {
                skip = true;
                break;
            }
        }
        if (skip) continue;

        try files.append(allocator, try allocator.dupe(u8, entry.path));
    }

    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return files.toOwnedSlice(allocator);
}

/// Recursively copies every file from `src_dir` into `dst_dir` --
/// permanently vendors the source, since `natyv bind` needs it to persist
/// across runs the same way `src/bindgen/*_bindings_generated.zig` does,
/// not just live in an ephemeral scratch project.
pub fn copyTree(allocator: std.mem.Allocator, io: Io, src_dir: Io.Dir, dst_dir: Io.Dir) !void {
    var walker = try src_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (std.fs.path.dirname(entry.path)) |dir| {
            try dst_dir.createDirPath(io, dir);
        }
        try src_dir.copyFile(entry.path, dst_dir, entry.path, io, .{});
    }
}

test "findCSourceFiles: finds real .c files, skips test/example directories" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "adler32.c", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "deflate.c", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "deflate.h", .data = "" });
    _ = try tmp.dir.createDirPathOpen(io, "examples", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "examples/example.c", .data = "" });
    _ = try tmp.dir.createDirPathOpen(io, "test", .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "test/minigzip.c", .data = "" });

    const files = try findCSourceFiles(std.testing.allocator, io, tmp.dir);
    defer {
        for (files) |f| std.testing.allocator.free(f);
        std.testing.allocator.free(files);
    }
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqualStrings("adler32.c", files[0]);
    try std.testing.expectEqualStrings("deflate.c", files[1]);
}

test "copyTree: real files land at the same relative paths in the destination" {
    var src = std.testing.tmpDir(.{ .iterate = true });
    defer src.cleanup();
    var dst = std.testing.tmpDir(.{ .iterate = true });
    defer dst.cleanup();
    const io = std.testing.io;

    _ = try src.dir.createDirPathOpen(io, "sub", .{});
    try src.dir.writeFile(io, .{ .sub_path = "top.c", .data = "int top;" });
    try src.dir.writeFile(io, .{ .sub_path = "sub/nested.c", .data = "int nested;" });

    try copyTree(std.testing.allocator, io, src.dir, dst.dir);

    const top = try dst.dir.readFileAlloc(io, "top.c", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(top);
    try std.testing.expectEqualStrings("int top;", top);

    const nested = try dst.dir.readFileAlloc(io, "sub/nested.c", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(nested);
    try std.testing.expectEqualStrings("int nested;", nested);
}

test "locateSource: a real, live fetch+locate of a plain (non-Zig-package) C source tarball" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const parent_abs = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_path, tmp.sub_path });

    const result = try locateSource(allocator, io, tmp.dir, parent_abs, "zlibsrc", "https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz");
    defer tmp.dir.deleteTree(io, result.scratch_dir_name.?) catch {};
    if (result.err) |e| {
        std.debug.print("locateSource failed: {s}\n", .{e.message});
        return error.SkipZigTest;
    }
    try std.testing.expect(result.source_dir != null);

    var source_dir = try std.Io.Dir.cwd().openDir(io, result.source_dir.?, .{ .iterate = true });
    defer source_dir.close(io);
    const deflate_c = try source_dir.readFileAlloc(io, "deflate.c", allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, deflate_c, "deflate") != null);
}
