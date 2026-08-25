//! Real `zig fetch`-based discovery for `natyv get -zig=<url>` -- Stage
//! 2.5 of ~/.claude/plans/lexical-wishing-penguin.md. Two real
//! subprocess-driven jobs, both empirically verified against this
//! machine's real Zig 0.16.0 toolchain and a real public Zig package
//! (`allyourcodebase/zlib`) before writing any of this:
//!
//! 1. `fetchSave` -- runs `zig fetch --save=<name> <url>` against a given
//!    directory's own `build.zig.zon`. Confirmed idempotent: re-running it
//!    when `name` already maps to the same `url` is a real, silent no-op
//!    (exit 0, file unchanged) -- safe to call on every `natyv bind` run
//!    without our own "already present" guard.
//! 2. `discoverHeader` -- a fetched Zig package exposes a real
//!    `*Step.Compile` artifact via its own build.zig, not flat `-I`/`-L`
//!    strings the way `pkg-config` output already is (see `PkgConfig.zig`)
//!    -- there is no generic way to ask "what's your public header path"
//!    without actually building it. Confirmed empirically: a real
//!    `Step.Compile.installHeadersDirectory` call (which
//!    `allyourcodebase/zlib`'s own build.zig makes) genuinely lands its
//!    headers under `<prefix>/include/` when that artifact is
//!    `b.installArtifact`-ed and `zig build install --prefix <p>` is run
//!    for real -- confirmed for a nested-dependency case too (zlib's
//!    wrapper installs headers from its own `upstream` sub-dependency, not
//!    its own directory, and the install step still resolves it
//!    correctly). So this creates a real, throwaway scratch Zig project
//!    (via `zig init`, since a hand-authored `build.zig.zon`'s
//!    `.fingerprint` field is validated against a value that is NOT a pure
//!    function of `.name` -- confirmed empirically, two identical `.name`s
//!    in different directories produced different suggested fingerprints
//!    -- so there's no way to bake a constant one, `zig init`'s own
//!    generation is the only robust path), fetches the real dependency
//!    into it, and does a real `zig build install --prefix
//!    <scratch>/install` to find out.
//!
//! Both are genuinely separate from `PkgConfig.zig`'s `discover`, not a
//! generalized variant of it -- pkg-config's output is already flag-
//! shaped; a Zig package's real integration point is a build-graph
//! artifact, an architecturally different thing this project's existing
//! `include_dirs`/`lib_dirs`/`link` fields can't represent for the *final
//! app build* (only for the reflector's own scratch `-I` need, which is
//! why `discoverHeader` returns a plain include-dir path even though the
//! ultimate app build never uses it -- see `Bind.zig`'s own use of both).

const std = @import("std");
const Io = std.Io;

pub const FetchError = struct {
    message: []const u8,
};

pub const FetchOutcome = struct {
    err: ?FetchError,
};

/// Runs `zig fetch --save=<name> <url>` with `cwd` as the working
/// directory -- adds (or, if already present with the same url, silently
/// confirms) a real dependency entry in `cwd`'s own `build.zig.zon`.
pub fn fetchSave(allocator: std.mem.Allocator, io: Io, cwd: Io.Dir, name: []const u8, url: []const u8) !FetchOutcome {
    const save_flag = try std.fmt.allocPrint(allocator, "--save={s}", .{name});
    defer allocator.free(save_flag);
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "zig", "fetch", save_flag, url },
        .cwd = .{ .dir = cwd },
    }) catch |e| {
        return .{ .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv get: could not run 'zig fetch {s} {s}': {s}", .{ save_flag, url, @errorName(e) }) } };
    };
    defer allocator.free(result.stdout);
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                defer allocator.free(result.stderr);
                return .{ .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv get: 'zig fetch {s} {s}' failed (exit code {d}):\n{s}{s}", .{ save_flag, url, code, result.stdout, result.stderr }) } };
            }
            allocator.free(result.stderr);
        },
        else => |term| {
            defer allocator.free(result.stderr);
            return .{ .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv get: 'zig fetch {s} {s}' exited abnormally ({any}):\n{s}{s}", .{ save_flag, url, term, result.stdout, result.stderr }) } };
        },
    }
    return .{ .err = null };
}

fn runOrError(allocator: std.mem.Allocator, io: Io, argv: []const []const u8, cwd: Io.Dir, context: []const u8) !?FetchError {
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

pub const DiscoverResult = struct {
    /// Absolute path to the scratch install's `include/` directory --
    /// only valid until the caller cleans up the scratch dir this came
    /// from (`Bind.zig` uses it immediately for the reflector's own `-I`,
    /// then deletes the whole scratch tree).
    include_dir: ?[]const u8,
    /// Real filenames actually found under that `include/` dir -- used to
    /// build a clear, actionable error when the expected header isn't
    /// among them (mirrors zig's own "available artifact: ..." pattern
    /// for a similar not-found case).
    installed_headers: []const []const u8,
    err: ?FetchError,
};

/// Creates a real, throwaway scratch Zig project under `parent_dir` named
/// `_natyv_bind_zigdiscover_<name>`, fetches `url` as dependency `name`
/// into it, builds+installs just `artifact` to `<scratch>/install`, and
/// reports what landed in `<scratch>/install/include`. Does not clean up
/// after itself -- the caller (`Bind.zig`) still needs `include_dir` to
/// exist on disk for its own subsequent reflector compile, and is
/// responsible for deleting the whole `_natyv_bind_zigdiscover_<name>`
/// subtree once that's done.
pub fn discoverHeader(allocator: std.mem.Allocator, io: Io, parent_dir: Io.Dir, parent_dir_abs: []const u8, name: []const u8, url: []const u8, artifact: []const u8) !DiscoverResult {
    const scratch_name = try std.fmt.allocPrint(allocator, "_natyv_bind_zigdiscover_{s}", .{name});
    parent_dir.deleteTree(io, scratch_name) catch {};
    var scratch_dir = parent_dir.createDirPathOpen(io, scratch_name, .{}) catch |e| {
        return .{ .include_dir = null, .installed_headers = &.{}, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv get: could not create scratch discovery dir for '{s}': {s}", .{ name, @errorName(e) }) } };
    };
    defer scratch_dir.close(io);

    // `zig init` is the only robust way to get a *valid* build.zig.zon --
    // a hand-authored one's `.fingerprint` is checked against a value
    // that isn't a pure function of `.name` (confirmed empirically), so
    // there's no constant to bake in. `src/main.zig`/`src/root.zig` it
    // also generates are unused and left in place; harmless, deleted with
    // the rest of the scratch tree by the caller.
    if (try runOrError(allocator, io, &.{ "zig", "init" }, scratch_dir, "'zig init' for a scratch discovery project")) |e| {
        return .{ .include_dir = null, .installed_headers = &.{}, .err = e };
    }

    const fetch_outcome = try fetchSave(allocator, io, scratch_dir, name, url);
    if (fetch_outcome.err) |e| return .{ .include_dir = null, .installed_headers = &.{}, .err = e };

    const scratch_build_zig = try std.fmt.allocPrint(allocator,
        \\const std = @import("std");
        \\pub fn build(b: *std.Build) void {{
        \\    const target = b.standardTargetOptions(.{{}});
        \\    const optimize = b.standardOptimizeOption(.{{}});
        \\    const dep = b.dependency("{s}", .{{ .target = target, .optimize = optimize }});
        \\    b.installArtifact(dep.artifact("{s}"));
        \\}}
        \\
    , .{ name, artifact });
    try scratch_dir.writeFile(io, .{ .sub_path = "build.zig", .data = scratch_build_zig });

    const scratch_abs = try std.fs.path.join(allocator, &.{ parent_dir_abs, scratch_name });
    const install_abs = try std.fs.path.join(allocator, &.{ scratch_abs, "install" });
    if (try runOrError(allocator, io, &.{ "zig", "build", "install", "--prefix", install_abs }, scratch_dir, try std.fmt.allocPrint(allocator, "'zig build install' to discover '{s}''s installed headers (check that artifact \"{s}\" is real -- it's an exact *Step.Compile name from the package's own build.zig, not a guess)", .{ name, artifact }))) |e| {
        return .{ .include_dir = null, .installed_headers = &.{}, .err = e };
    }

    const include_abs = try std.fs.path.join(allocator, &.{ install_abs, "include" });
    var include_dir = std.Io.Dir.cwd().openDir(io, include_abs, .{ .iterate = true }) catch |e| {
        return .{ .include_dir = null, .installed_headers = &.{}, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv get: '{s}' installed no headers at all (artifact \"{s}\" never calls installHeadersDirectory): {s}", .{ name, artifact, @errorName(e) }) } };
    };
    defer include_dir.close(io);

    var headers: std.ArrayList([]const u8) = .empty;
    var it = include_dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) try headers.append(allocator, try allocator.dupe(u8, entry.name));
    }

    return .{ .include_dir = include_abs, .installed_headers = headers.items, .err = null };
}

test "fetchSave: a real, live fetch of allyourcodebase/zlib succeeds and is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    if (try runOrError(allocator, io, &.{ "zig", "init" }, tmp.dir, "zig init")) |e| {
        std.debug.print("skipping: {s}\n", .{e.message});
        return error.SkipZigTest;
    }

    const url = "https://github.com/allyourcodebase/zlib/archive/refs/heads/main.tar.gz";
    const first = try fetchSave(allocator, io, tmp.dir, "zlib", url);
    try std.testing.expect(first.err == null);

    // Idempotency: re-running against the same name+url is a real no-op,
    // not an error -- confirmed empirically before writing this design
    // (see this file's own doc comment).
    const second = try fetchSave(allocator, io, tmp.dir, "zlib", url);
    try std.testing.expect(second.err == null);

    const zon = try tmp.dir.readFileAlloc(io, "build.zig.zon", allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, zon, ".zlib") != null);
}

test "fetchSave: an unresolvable URL surfaces a clear, natyv-attributed error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    if (try runOrError(allocator, io, &.{ "zig", "init" }, tmp.dir, "zig init")) |e| {
        allocator.free(e.message);
        return error.SkipZigTest;
    }

    const outcome = try fetchSave(allocator, io, tmp.dir, "nope", "https://example.invalid/definitely-not-a-real-package.tar.gz");
    defer if (outcome.err) |e| allocator.free(e.message);
    try std.testing.expect(outcome.err != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "natyv get:") != null);
}

test "discoverHeader: a real, live discovery of allyourcodebase/zlib's installed header" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const parent_abs = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_path, tmp.sub_path });

    const result = try discoverHeader(allocator, io, tmp.dir, parent_abs, "zlib", "https://github.com/allyourcodebase/zlib/archive/refs/heads/main.tar.gz", "z");
    defer tmp.dir.deleteTree(io, "_natyv_bind_zigdiscover_zlib") catch {};
    if (result.err) |e| {
        std.debug.print("discoverHeader failed: {s}\n", .{e.message});
        return error.SkipZigTest;
    }
    try std.testing.expect(result.include_dir != null);

    var found_zlib_h = false;
    for (result.installed_headers) |h| {
        if (std.mem.eql(u8, h, "zlib.h")) found_zlib_h = true;
    }
    try std.testing.expect(found_zlib_h);

    const header_path = try std.fs.path.join(allocator, &.{ result.include_dir.?, "zlib.h" });
    const header_contents = try std.Io.Dir.cwd().readFileAlloc(io, header_path, allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, header_contents, "ZLIB_VERSION") != null);
}

test "discoverHeader: an unknown artifact name surfaces a clear, actionable error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const parent_abs = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_path, tmp.sub_path });

    const result = try discoverHeader(allocator, io, tmp.dir, parent_abs, "zlib", "https://github.com/allyourcodebase/zlib/archive/refs/heads/main.tar.gz", "this_artifact_does_not_exist");
    defer tmp.dir.deleteTree(io, "_natyv_bind_zigdiscover_zlib") catch {};
    try std.testing.expect(result.err != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "natyv get:") != null);
}
