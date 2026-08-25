//! `natyv build`'s final sub-step (`.ntx` tooling Stage 7,
//! ~/.claude/plans/lexical-wishing-penguin.md): invokes a real
//! `zig build -Dembed-app-wasm=true` against natyv-core's own source tree
//! to produce one self-contained distributable binary with the dev's
//! compiled guest wasm embedded via `@embedFile` (see build.zig's
//! `embed-app-wasm` option and `src/assets/EmbeddedWasm{Present,Absent}.zig`).
//!
//! This needs natyv-core's own buildable source tree on disk somewhere --
//! `natyv_core_src` (the caller-supplied param below) resolves it the
//! same way `build.zig`'s own `extismPrefix()` already solves a
//! near-identical problem (an external dependency's location): a
//! compile-time-baked default (`build.zig`'s `-Dnatyv-core-src`, this
//! repo's own root for a local dev build), overridable at runtime via a
//! `NATYV_CORE_SRC` env var (see `main.zig`) -- not a fragile
//! self-locating guess, since Zig 0.16's stdlib has no
//! `selfExePath`-equivalent to guess with anyway (confirmed absent from
//! every relevant std file). Confirmed design, brought forward now
//! rather than deferred: the CLI and natyv-core are meant to always ship
//! *together* as one real package (Homebrew/Chocolatey/Scoop/a Linux
//! equivalent, not yet built) -- so a real future packaging "wrapper" is
//! nothing more than building natyv with `-Dnatyv-core-src=<wherever
//! that package installs natyv-core's source>`, then packaging the
//! result; no code here needs to change once that packaging exists.
//!
//! `@embedFile` can only ever reach a path inside its own module's root
//! (Zig 0.16 rejects paths escaping it -- confirmed while building
//! `src/assets/` originally), so the compiled wasm has to physically be
//! copied into natyv-core's own source tree, however briefly, before the
//! embed can work at all.

const std = @import("std");
const Io = std.Io;

pub const BundleError = struct {
    message: []const u8,
};

pub const Result = struct {
    ok: bool,
    err: ?BundleError,
};

/// `natyv_core_src` is a real natyv-core checkout's root -- callers
/// resolve this however they like (`main.zig` reads it from the
/// `NATYV_CORE_SRC` env var; kept as a plain parameter here, rather than
/// this function reading the env var itself, so tests can exercise real
/// error paths -- a missing/bad `NATYV_CORE_SRC`, a missing wasm file --
/// without needing real process-wide env var mutation). `wasm_path` is
/// the dev's already-compiled guest wasm, resolved relative to the
/// process's own cwd. `dist_dir` is where the final binary lands
/// (already created by the caller); `output_name` is what it gets
/// renamed to there (dropping Zig's own default `bin/<exe-name>`
/// nesting -- a real end-user distributable should be one flat,
/// sensibly-named file, not a path a dev has to go hunting for).
/// `has_bindings` passes `-Dhas-bindings=true` (Stage 2.2 of the binding
/// generator arc) so this build picks up the real `src/BindingsGenerated.zig`
/// `natyv bind` already wrote, instead of the empty `BindingsAbsent.zig`
/// stub -- same "app-specific option, only when actually needed" shape as
/// `-Dembed-app-wasm` itself. `binding_include_dirs`/`binding_link` are
/// already comma-joined (built by `cli/main.zig` from `Bind.Outcome`'s own
/// aggregated per-entry values) -- passed through verbatim as
/// `-Dbinding-include-dirs=`/`-Dbinding-link=` so `build.zig` can apply the
/// exact same include paths/linker flags the reflector's own scratch
/// compile already used against `src/BindingsGenerated.zig`'s per-entry
/// `@cInclude`s and real library symbol calls. Empty strings mean "add
/// nothing" and are simply omitted from argv.
pub fn run(allocator: std.mem.Allocator, io: Io, natyv_core_src: []const u8, wasm_path: []const u8, dist_dir: Io.Dir, output_name: []const u8, has_bindings: bool, binding_include_dirs: []const u8, binding_link: []const u8) !Result {
    var core_dir = std.Io.Dir.cwd().openDir(io, natyv_core_src, .{}) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: could not open NATYV_CORE_SRC ('{s}'): {s}", .{ natyv_core_src, @errorName(e) }),
        } };
    };
    defer core_dir.close(io);

    core_dir.access(io, "build.zig", .{}) catch {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: NATYV_CORE_SRC ('{s}') doesn't look like a real natyv-core checkout (no build.zig found there)", .{natyv_core_src}),
        } };
    };

    const wasm_bytes = std.Io.Dir.cwd().readFileAlloc(io, wasm_path, allocator, .unlimited) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: could not read compiled wasm '{s}': {s}", .{ wasm_path, @errorName(e) }),
        } };
    };

    var assets_dir = core_dir.openDir(io, "src/assets", .{}) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: could not open '{s}/src/assets': {s}", .{ natyv_core_src, @errorName(e) }),
        } };
    };
    defer assets_dir.close(io);
    try assets_dir.writeFile(io, .{ .sub_path = "embedded_app.wasm", .data = wasm_bytes });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dist_abs_len = try dist_dir.realPath(io, &path_buf);
    const dist_abs = path_buf[0..dist_abs_len];

    var argv: std.ArrayList([]const u8) = .empty;
    // `install-core`, not the bare default step -- the default "install"
    // step installs every artifact in natyv-core's build graph, including
    // the `natyv` CLI itself, which would leave a stray, useless second
    // binary inside the app's own bundled output (confirmed by actually
    // running a bundle and inspecting what came out).
    try argv.appendSlice(allocator, &.{ "zig", "build", "install-core", "-Dembed-app-wasm=true", "--prefix", dist_abs });
    if (has_bindings) try argv.append(allocator, "-Dhas-bindings=true");
    if (binding_include_dirs.len > 0) try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Dbinding-include-dirs={s}", .{binding_include_dirs}));
    if (binding_link.len > 0) try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Dbinding-link={s}", .{binding_link}));

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = core_dir },
    }) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: could not run 'zig build' in NATYV_CORE_SRC ('{s}'): {s}", .{ natyv_core_src, @errorName(e) }),
        } };
    };
    defer allocator.free(result.stdout);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                defer allocator.free(result.stderr);
                return .{ .ok = false, .err = .{
                    .message = try std.fmt.allocPrint(allocator, "natyv build: bundling failed (zig build exit code {d}):\n{s}{s}", .{ code, result.stdout, result.stderr }),
                } };
            }
            allocator.free(result.stderr);
        },
        else => |term| {
            defer allocator.free(result.stderr);
            return .{ .ok = false, .err = .{
                .message = try std.fmt.allocPrint(allocator, "natyv build: bundling exited abnormally ({any}):\n{s}{s}", .{ term, result.stdout, result.stderr }),
            } };
        },
    }

    // Zig's own install step always produces `<prefix>/bin/natyv-core` --
    // renamed to `output_name` directly in `dist_dir` so the real
    // deliverable is one flat, sensibly-named file, not something a dev
    // has to go find inside a `bin/` subdirectory.
    var bin_dir = dist_dir.openDir(io, "bin", .{}) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: bundling reported success but '{s}/bin' wasn't created: {s}", .{ dist_abs, @errorName(e) }),
        } };
    };
    bin_dir.rename("natyv-core", dist_dir, output_name, io) catch |e| {
        bin_dir.close(io);
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: bundling reported success but the built binary couldn't be moved out of '{s}/bin': {s}", .{ dist_abs, @errorName(e) }),
        } };
    };
    bin_dir.close(io);
    dist_dir.deleteDir(io, "bin") catch {};

    return .{ .ok = true, .err = null };
}

test "a NATYV_CORE_SRC that doesn't exist is a clear error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    const result = try run(std.testing.allocator, io, "/definitely/not/a/real/path", "app.wasm", tmp.dir, "myapp", false, "", "");
    defer if (result.err) |e| std.testing.allocator.free(e.message);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "NATYV_CORE_SRC") != null);
}

test "a NATYV_CORE_SRC with no build.zig is a clear error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var not_core = try tmp.dir.createDirPathOpen(io, "not-natyv-core", .{});
    defer not_core.close(io);

    const cwd_path = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd_path);
    // `std.testing.tmpDir` resolves to `<cwd>/.zig-cache/tmp/<sub_path>`
    // -- an absolute path built from the real cwd avoids depending on
    // that nesting depth, same reasoning Prepare.zig's own tmpDir-based
    // go.mod tests already established.
    const abs_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}/not-natyv-core", .{ cwd_path, tmp.sub_path });
    defer std.testing.allocator.free(abs_path);

    const result = try run(std.testing.allocator, io, abs_path, "app.wasm", tmp.dir, "myapp", false, "", "");
    defer if (result.err) |e| std.testing.allocator.free(e.message);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "build.zig") != null);
}

test "a missing compiled wasm file is a clear error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.createDirPath(io, "src/assets");

    const cwd_path = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd_path);
    const abs_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_path, tmp.sub_path });
    defer std.testing.allocator.free(abs_path);

    const result = try run(std.testing.allocator, io, abs_path, "/definitely/not/a/real/wasm/path.wasm", tmp.dir, "myapp", false, "", "");
    defer if (result.err) |e| std.testing.allocator.free(e.message);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "compiled wasm") != null);
}
