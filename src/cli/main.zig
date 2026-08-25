//! Entry point for the dev-facing `natyv` CLI (`natyv prepare`, `natyv
//! build`, `natyv init`, `natyv get`) -- see
//! ~/.claude/plans/lexical-wishing-penguin.md for the full staged plan.
//! Deliberately a separate binary from natyv-core (`src/main.zig`, the app
//! runtime `natyv build` eventually bundles a compiled guest into): this
//! one only ever reads/writes files and spawns the dev's own configured
//! compile command (`Compile.zig`), so it carries none of natyv-core's
//! SDL3/Extism/Clay dependencies.
//!
//! `natyv build` runs the full prepare -> wasm_compile -> bundle chain
//! (skipping straight to bundling when nothing's changed since the last
//! successful compile), producing a genuinely self-contained binary.
//! `natyv init` interactively scaffolds a new app in place. `natyv get`
//! (Stage 2.3 of the binding generator arc) declares one `bindings` entry
//! in `conf.natyv.json`; `natyv bind`, run automatically as part of
//! `natyv build` today, is what actually generates from it.

const std = @import("std");
const Config = @import("Config");
const Prepare = @import("Prepare");
const Compile = @import("Compile.zig");
const BuildCache = @import("BuildCache");
const Bundle = @import("Bundle.zig");
const Bind = @import("Bind.zig");
const Get = @import("Get.zig");
const Init = @import("Init.zig");
const build_options = @import("build_options");

pub const Subcommand = enum { prepare, build, init, get };

pub const ParsedArgs = struct {
    subcommand: Subcommand,
    /// Meaningless for `.init`/`.get` (see doc comment below) -- always
    /// populated anyway so callers don't need to special-case reading it.
    config_path: []const u8,
};

pub const UsageError = error{
    MissingSubcommand,
    UnknownSubcommand,
};

/// Parses argv (excluding argv[0], the executable's own path) into a
/// subcommand + config path, defaulting the latter to `conf.natyv.json`
/// the same way natyv-core's own single positional arg defaults today.
/// `init` doesn't take a config path at all (it *creates* one, in
/// whatever directory it's invoked from); `get` (Stage 2.3 of
/// ~/.claude/plans/lexical-wishing-penguin.md) always operates on
/// `./conf.natyv.json` and takes a `<library>` positional + flags instead
/// (parsed separately by `parseGetArgs`, since its shape doesn't fit this
/// function's simple "one optional config path" model at all) -- for
/// both, `args[1..]` is deliberately ignored/left for the caller to
/// reinterpret rather than misparsed as a config path here.
/// Kept as a pure function, separate from `main`, so it's testable without
/// a real process.
pub fn parseArgs(args: []const []const u8) UsageError!ParsedArgs {
    if (args.len == 0) return error.MissingSubcommand;
    const subcommand: Subcommand = if (std.mem.eql(u8, args[0], "prepare"))
        .prepare
    else if (std.mem.eql(u8, args[0], "build"))
        .build
    else if (std.mem.eql(u8, args[0], "init"))
        .init
    else if (std.mem.eql(u8, args[0], "get"))
        .get
    else
        return error.UnknownSubcommand;
    const config_path: []const u8 = if (args.len > 1) args[1] else "conf.natyv.json";
    return .{ .subcommand = subcommand, .config_path = config_path };
}

pub const GetUsageError = error{
    MissingLibrary,
    MissingHeader,
    MissingFuncs,
    MissingArtifact,
    UnknownFlag,
    ConflictingMode,
    ZigModeFlagNotApplicable,
    CBuildRequiresVendorUrl,
    MissingLinkForCBuild,
};

/// Returns the value after `prefix` if `arg` starts with it, else `null`.
fn parseFlag(arg: []const u8, comptime prefix: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, arg, prefix)) return arg[prefix.len..];
    return null;
}

/// Parses `natyv get`'s own flag-heavy shape: `args[0]` is `<library>`,
/// the rest are `-c`/`-zig` (bare mode-selector flags, optional -- mode
/// defaults to `.manual`, Stage 2.3's original behavior) and
/// `--header=`/`--include-dir=`/`--lib-dir=`/`--link=`/`--funcs=` (`=`-
/// valued, `--include-dir=`/`--lib-dir=`/`--link=` repeatable, each
/// occurrence appending one value) in any order. Kept separate from
/// `parseArgs` since prepare/build/init have no flags today and don't
/// need this machinery -- allocator-backed (unlike `parseArgs`) since the
/// repeatable flags need real growable storage.
///
/// Bare `-c`'s own target reuses `args[0]` (`<library>`) rather than a
/// separate positional -- the confirmed design already treats the library
/// name and the discovery target as the same value for a pkg-config
/// module lookup. `-c=<url>` (Stage 2.6) is a second, `=`-valued form of
/// `-c` for real URL vendoring (fetches raw C source, no build.zig
/// assumed, see `src/cli/Vendor.zig`) -- `<library>` stays the short
/// identifier-safe name in this form too, same reasoning as `-zig=`
/// below. `--c-build=<command>` (mirrors `wasm_compile`'s shape) opts
/// into Stage 2.6's tier 2: `natyv bind` runs this exact command inside
/// the fetched source instead of compiling every `.c` file itself --
/// only meaningful alongside `-c=<url>`, and then requires at least one
/// `--link=` (natyv can't guess what a dev's own custom build produces).
///
/// `-zig=<url>` (Stage 2.5) is `=`-valued, not a bare flag like `-c` --
/// unlike `-c`, whose discovery target is always identical to `<library>`
/// (a pkg-config module name), a Zig package fetch genuinely needs two
/// distinct values: `<library>` stays the short, identifier-safe config
/// key/generated-symbol-prefix (as in every other mode), while the URL is
/// its own value. Requires `--artifact=<name>` (the exact `*Step.Compile`
/// name the fetched package's own build.zig exposes -- no viable default
/// guess exists, unlike `header`). Rejects `--include-dir=`/`--lib-dir=`/
/// `--link=` with a clear error rather than silently ignoring them --
/// `-zig` mode links via the fetched package's own build.zig
/// (`linkLibrary`, see `build.zig`), never via flags.
///
/// `--header=` is required only in `.manual` mode -- `.c`/`.zig` modes
/// legitimately have none (default to `"<library>.h"`, see `Get.run`).
pub fn parseGetArgs(allocator: std.mem.Allocator, args: []const []const u8) !Get.GetArgs {
    if (args.len == 0) return error.MissingLibrary;
    const library = args[0];

    var mode: Get.Mode = .manual;
    var header: ?[]const u8 = null;
    var functions: ?[]const []const u8 = null;
    var include_dirs: std.ArrayList([]const u8) = .empty;
    var lib_dirs: std.ArrayList([]const u8) = .empty;
    var link: std.ArrayList([]const u8) = .empty;
    var zig_url: ?[]const u8 = null;
    var artifact: ?[]const u8 = null;
    var vendor_url: ?[]const u8 = null;
    var vendor_c_build: ?[]const u8 = null;

    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-c")) {
            if (mode != .manual) return error.ConflictingMode;
            mode = .c;
        } else if (parseFlag(arg, "-c=")) |v| {
            if (mode != .manual) return error.ConflictingMode;
            mode = .c;
            vendor_url = v;
        } else if (parseFlag(arg, "-zig=")) |v| {
            if (mode != .manual) return error.ConflictingMode;
            mode = .zig;
            zig_url = v;
        } else if (parseFlag(arg, "--c-build=")) |v| {
            vendor_c_build = v;
        } else if (parseFlag(arg, "--header=")) |v| {
            header = v;
        } else if (parseFlag(arg, "--include-dir=")) |v| {
            try include_dirs.append(allocator, v);
        } else if (parseFlag(arg, "--lib-dir=")) |v| {
            try lib_dirs.append(allocator, v);
        } else if (parseFlag(arg, "--link=")) |v| {
            try link.append(allocator, v);
        } else if (parseFlag(arg, "--artifact=")) |v| {
            artifact = v;
        } else if (parseFlag(arg, "--funcs=")) |v| {
            var list: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, v, ',');
            while (it.next()) |f| try list.append(allocator, f);
            functions = list.items;
        } else {
            return error.UnknownFlag;
        }
    }

    if (mode == .manual and header == null) return error.MissingHeader;
    if (mode == .zig and artifact == null) return error.MissingArtifact;
    if (mode == .zig and (include_dirs.items.len > 0 or lib_dirs.items.len > 0 or link.items.len > 0)) return error.ZigModeFlagNotApplicable;
    if (vendor_c_build != null and vendor_url == null) return error.CBuildRequiresVendorUrl;
    if (vendor_c_build != null and link.items.len == 0) return error.MissingLinkForCBuild;

    return .{
        .library = library,
        .mode = mode,
        .header = header,
        .include_dirs = include_dirs.items,
        .lib_dirs = lib_dirs.items,
        .link = link.items,
        .functions = functions orelse return error.MissingFuncs,
        .zig_url = zig_url,
        .zig_artifact = artifact,
        .vendor_url = vendor_url,
        .vendor_c_build = vendor_c_build,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = init.minimal.args.vector;

    // 64, not the original 8 -- `natyv get`'s repeatable
    // `--include-dir=`/`--link=` flags (Stage 2.3) can realistically add
    // up to more than 8 total args including the subcommand, and the
    // original bound would have silently truncated anything past it with
    // no error at all.
    var arg_slices: [64][]const u8 = undefined;
    var arg_count: usize = 0;
    var i: usize = 1; // argv[0] is this executable's own path.
    while (i < argv.len and arg_count < arg_slices.len) : (i += 1) {
        arg_slices[arg_count] = std.mem.span(argv[i]);
        arg_count += 1;
    }
    const args = arg_slices[0..arg_count];

    const parsed = parseArgs(args) catch |err| {
        switch (err) {
            error.MissingSubcommand => std.debug.print("usage: natyv <prepare|build|init|get> [args...]\n", .{}),
            error.UnknownSubcommand => std.debug.print("natyv: unknown subcommand '{s}' (expected 'prepare', 'build', 'init', or 'get')\n", .{args[0]}),
        }
        return err;
    };

    // `get` only ever declares a `bindings` entry -- it never reads a
    // guest directory or a compiled wasm, so it deliberately never reaches
    // any of the `Config.load`/guest-dir logic below either (same
    // reasoning as `init`, right above).
    if (parsed.subcommand == .get) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const get_args = parseGetArgs(arena_alloc, args[1..]) catch |err| {
            switch (err) {
                error.MissingLibrary => std.debug.print("usage: natyv get <library> [-c|-c=<url>|-zig=<url>] --funcs=fn1,fn2 [--header=<header>] [--include-dir=<dir>]... [--lib-dir=<dir>]... [--link=<lib>]... [--artifact=<name>] [--c-build=<command>]\n", .{}),
                error.MissingHeader => std.debug.print("natyv get: missing required --header=<header> (only optional in -c/-zig mode, where it defaults to <library>.h)\n", .{}),
                error.MissingFuncs => std.debug.print("natyv get: missing required --funcs=fn1,fn2,...\n", .{}),
                error.MissingArtifact => std.debug.print("natyv get: -zig mode requires --artifact=<name> -- the exact *Step.Compile artifact name the fetched package's own build.zig exposes\n", .{}),
                error.UnknownFlag => std.debug.print("natyv get: unrecognized flag (expected -c, -c=, -zig=, --header=, --include-dir=, --lib-dir=, --link=, --artifact=, --c-build=, or --funcs=)\n", .{}),
                error.ConflictingMode => std.debug.print("natyv get: -c/-c=/-zig= can only be given once, and not together\n", .{}),
                error.ZigModeFlagNotApplicable => std.debug.print("natyv get: --include-dir=/--lib-dir=/--link= have no effect in -zig mode -- linking happens automatically via the fetched package's own build.zig\n", .{}),
                error.CBuildRequiresVendorUrl => std.debug.print("natyv get: --c-build= only makes sense alongside -c=<url> (vendoring) -- for a bare pkg-config module, natyv doesn't build anything itself\n", .{}),
                error.MissingLinkForCBuild => std.debug.print("natyv get: --c-build= requires at least one --link= -- natyv can't guess what your own build command produces\n", .{}),
                else => std.debug.print("natyv get: could not parse arguments: {}\n", .{err}),
            }
            return err;
        };

        const outcome = try Get.run(arena_alloc, io, "conf.natyv.json", get_args);
        if (outcome.err) |e| {
            std.debug.print("{s}\n", .{e.message});
            return error.GetFailed;
        }
        std.debug.print("natyv get: {s} {s} in conf.natyv.json\n", .{ if (outcome.updated_existing) "updated" else "added", get_args.library });
        return;
    }

    // `init` creates a config, rather than reading one -- it deliberately
    // never reaches the `Config.load` call below.
    if (parsed.subcommand == .init) {
        std.debug.print("What language is your guest code in? (go): ", .{});
        var line_buf: [256]u8 = undefined;
        const language = Init.readLine(io, &line_buf) catch |err| {
            std.debug.print("natyv init: could not read input: {}\n", .{err});
            return err;
        };

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        const cwd_path = try std.process.currentPathAlloc(io, arena_alloc);
        const cwd_name = std.fs.path.basename(cwd_path);
        const natyv_core_src = init.environ_map.get("NATYV_CORE_SRC") orelse build_options.natyv_core_src_default;

        const result = try Init.run(arena_alloc, io, language, cwd_name, natyv_core_src, std.Io.Dir.cwd());
        if (result.err) |e| {
            std.debug.print("{s}\n", .{e.message});
            return error.InitFailed;
        }
        std.debug.print("natyv init: scaffolded a new Go natyv app here -- try `natyv build` next\n", .{});
        return;
    }

    const config = Config.load(allocator, io, parsed.config_path) catch |err| {
        std.debug.print("[natyv] failed to load {s}: {}\n", .{ parsed.config_path, err });
        return err;
    };
    defer config.deinit();

    // Guest source lives under `guest/`, relative to the *config file's*
    // own directory (not the process's cwd) -- matches every real example
    // and the same convention `src/main.zig`'s own wasm-path resolution
    // already uses.
    const config_dir = std.fs.path.dirname(parsed.config_path) orelse ".";
    const guest_dir_path = try std.fs.path.join(allocator, &.{ config_dir, "guest" });
    defer allocator.free(guest_dir_path);

    switch (parsed.subcommand) {
        .prepare => {
            var guest_dir = std.Io.Dir.cwd().openDir(io, guest_dir_path, .{ .iterate = true }) catch |err| {
                std.debug.print("natyv prepare: could not open '{s}': {}\n", .{ guest_dir_path, err });
                return err;
            };
            defer guest_dir.close(io);

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const outcome = try Prepare.run(arena.allocator(), io, guest_dir);
            if (outcome.err) |e| {
                std.debug.print("{s}\n", .{e.message});
                return error.PrepareFailed;
            }
            std.debug.print("natyv prepare: {s} -- transpiled {d} file(s)\n", .{ config.value.name, outcome.processed });
        },
        .build => {
            var guest_dir = std.Io.Dir.cwd().openDir(io, guest_dir_path, .{ .iterate = true }) catch |err| {
                std.debug.print("natyv build: could not open '{s}': {}\n", .{ guest_dir_path, err });
                return err;
            };
            defer guest_dir.close(io);

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const arena_alloc = arena.allocator();

            // `NATYV_CORE_SRC` overrides the compile-time-baked default
            // (`build_options.natyv_core_src_default` -- this repo's own
            // root for a local dev build, or wherever a real packaging
            // wrapper installs natyv-core's source for a real install)
            // when set, but a real install never needs to set it at all.
            // Resolved early (not just before bundling, as originally
            // written) since Stage 2.2's `Bind.run` below also needs it.
            const natyv_core_src = init.environ_map.get("NATYV_CORE_SRC") orelse build_options.natyv_core_src_default;

            // Stage 2.2 of the binding generator arc
            // (~/.claude/plans/lexical-wishing-penguin.md): a real, if
            // provisional, integration point ahead of the
            // freshness/prepare/compile sequence below -- folding `natyv
            // bind` properly into `natyv prepare` itself (with its own
            // `--codegen` fast-path flag) is Stage 2.7's job, not this
            // one; this is the minimum real wiring needed to prove a
            // generated binding actually works end to end.
            var binding_include_dirs: []const u8 = "";
            var binding_lib_dirs: []const u8 = "";
            var binding_link: []const u8 = "";
            var binding_zig_deps: []const u8 = "";
            var binding_vendor_c_files: []const u8 = "";
            if (config.value.bindings.len > 0) {
                const bind_outcome = try Bind.run(arena_alloc, io, config.value.bindings, natyv_core_src, guest_dir);
                if (bind_outcome.err) |e| {
                    std.debug.print("{s}\n", .{e.message});
                    return error.BindFailed;
                }
                binding_include_dirs = try std.mem.join(arena_alloc, ",", bind_outcome.include_dirs);
                binding_lib_dirs = try std.mem.join(arena_alloc, ",", bind_outcome.lib_dirs);
                binding_link = try std.mem.join(arena_alloc, ",", bind_outcome.link);

                // Stage 2.5: `name:artifact` pairs for `build.zig`'s own
                // `-Dbinding-zig-deps` loop (see that file's comment on
                // why a `-zig`-mode entry needs `b.dependency(...).artifact(...)`
                // + `linkLibrary`, not flags like the other three above).
                var zig_deps_parts: std.ArrayList(u8) = .empty;
                for (bind_outcome.zig_deps, 0..) |zd, zi| {
                    if (zi > 0) try zig_deps_parts.append(arena_alloc, ',');
                    try zig_deps_parts.appendSlice(arena_alloc, try std.fmt.allocPrint(arena_alloc, "{s}:{s}", .{ zd.name, zd.artifact }));
                }
                binding_zig_deps = zig_deps_parts.items;

                // Stage 2.6: absolute `.c` file paths (tier-1 default
                // vendoring) for `build.zig`'s own `-Dbinding-vendor-c-files`
                // -- a plain comma list, unlike `zig_deps` above, since
                // `build.zig` doesn't need to know which library a file
                // belongs to, only that it's part of `bindings_mod`.
                binding_vendor_c_files = try std.mem.join(arena_alloc, ",", bind_outcome.vendor_c_files);
            }

            // Checked once, up front, before running anything -- Quinn's
            // own design: if nothing that affects the compiled wasm has
            // changed since the last successful wasm_compile, skip
            // straight to bundling instead of redoing prepare/compile.
            const wasm_basename = try config.value.wasmFilename(arena_alloc);
            if (try BuildCache.isFresh(arena_alloc, io, guest_dir, wasm_basename)) {
                std.debug.print("natyv build: {s} -- wasm is already up to date, skipping prepare/wasm_compile\n", .{config.value.name});
            } else {
                const outcome = try Prepare.run(arena_alloc, io, guest_dir);
                if (outcome.err) |e| {
                    std.debug.print("{s}\n", .{e.message});
                    return error.PrepareFailed;
                }

                std.debug.print("natyv build: {s} -- running wasm_compile...\n", .{config.value.name});
                const compile_result = try Compile.run(arena_alloc, io, config.value.wasm_compile, guest_dir);
                if (compile_result.err) |e| {
                    std.debug.print("{s}\n", .{e.message});
                    return error.WasmCompileFailed;
                }

                const new_hash = try BuildCache.computeSourceHash(arena_alloc, io, guest_dir);
                try BuildCache.writeCachedHash(io, guest_dir, new_hash);
            }

            // Bundling always runs regardless of freshness -- freshness
            // only ever skips prepare/wasm_compile, never the final
            // bundle step, per Quinn's own explicit design.
            const dist_dir_path = try std.fs.path.join(arena_alloc, &.{ config_dir, "dist" });
            var dist_dir = try std.Io.Dir.cwd().createDirPathOpen(io, dist_dir_path, .{});
            defer dist_dir.close(io);

            const wasm_full_path = try std.fs.path.join(arena_alloc, &.{ guest_dir_path, wasm_basename });

            std.debug.print("natyv build: {s} -- bundling...\n", .{config.value.name});
            const bundle_result = try Bundle.run(arena_alloc, io, natyv_core_src, wasm_full_path, dist_dir, config.value.name, config.value.bindings.len > 0, binding_include_dirs, binding_lib_dirs, binding_link, binding_zig_deps, binding_vendor_c_files);
            if (bundle_result.err) |e| {
                std.debug.print("{s}\n", .{e.message});
                return error.BundleFailed;
            }
            std.debug.print("natyv build: {s} -- built {s}/{s}\n", .{ config.value.name, dist_dir_path, config.value.name });
        },
        .init, .get => unreachable, // both handled above
    }
}

test "parseArgs: prepare with default config path" {
    const parsed = try parseArgs(&.{"prepare"});
    try std.testing.expectEqual(Subcommand.prepare, parsed.subcommand);
    try std.testing.expectEqualStrings("conf.natyv.json", parsed.config_path);
}

test "parseArgs: init" {
    const parsed = try parseArgs(&.{"init"});
    try std.testing.expectEqual(Subcommand.init, parsed.subcommand);
}

test "parseArgs: build with explicit config path" {
    const parsed = try parseArgs(&.{ "build", "examples/clay-fixture/conf.natyv.json" });
    try std.testing.expectEqual(Subcommand.build, parsed.subcommand);
    try std.testing.expectEqualStrings("examples/clay-fixture/conf.natyv.json", parsed.config_path);
}

test "parseArgs: missing subcommand errors clearly" {
    try std.testing.expectError(error.MissingSubcommand, parseArgs(&.{}));
}

test "parseArgs: unknown subcommand errors clearly" {
    try std.testing.expectError(error.UnknownSubcommand, parseArgs(&.{"frobnicate"}));
}

test "parseArgs: get" {
    const parsed = try parseArgs(&.{ "get", "zlib" });
    try std.testing.expectEqual(Subcommand.get, parsed.subcommand);
}

test "parseGetArgs: a full, valid flag set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try parseGetArgs(arena.allocator(), &.{
        "zlib",
        "--header=zlib.h",
        "--include-dir=/opt/homebrew/include",
        "--include-dir=/usr/local/include",
        "--link=z",
        "--funcs=compress,uncompress,zlibCompileFlags",
    });
    try std.testing.expectEqualStrings("zlib", args.library);
    try std.testing.expectEqualStrings("zlib.h", args.header.?);
    try std.testing.expectEqual(@as(usize, 2), args.include_dirs.len);
    try std.testing.expectEqualStrings("/opt/homebrew/include", args.include_dirs[0]);
    try std.testing.expectEqualStrings("/usr/local/include", args.include_dirs[1]);
    try std.testing.expectEqual(@as(usize, 1), args.link.len);
    try std.testing.expectEqualStrings("z", args.link[0]);
    try std.testing.expectEqual(@as(usize, 3), args.functions.len);
    try std.testing.expectEqualStrings("compress", args.functions[0]);
    try std.testing.expectEqualStrings("zlibCompileFlags", args.functions[2]);
}

test "parseGetArgs: repeated --link= flags all accumulate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try parseGetArgs(arena.allocator(), &.{
        "mylib", "--header=my.h", "--funcs=f", "--link=a", "--link=b", "--link=c",
    });
    try std.testing.expectEqual(@as(usize, 3), args.link.len);
    try std.testing.expectEqualStrings("a", args.link[0]);
    try std.testing.expectEqualStrings("c", args.link[2]);
}

test "parseGetArgs: missing library is a clear error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingLibrary, parseGetArgs(arena.allocator(), &.{}));
}

test "parseGetArgs: missing --header= is a clear error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingHeader, parseGetArgs(arena.allocator(), &.{ "zlib", "--funcs=f" }));
}

test "parseGetArgs: missing --funcs= is a clear error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingFuncs, parseGetArgs(arena.allocator(), &.{ "zlib", "--header=zlib.h" }));
}

test "parseGetArgs: an unrecognized flag is a clear error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnknownFlag, parseGetArgs(arena.allocator(), &.{ "zlib", "--header=zlib.h", "--funcs=f", "--liink=z" }));
}

test "parseGetArgs: -c mode does not require --header=" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try parseGetArgs(arena.allocator(), &.{ "zlib", "-c", "--funcs=zlibCompileFlags" });
    try std.testing.expectEqual(Get.Mode.c, args.mode);
    try std.testing.expectEqual(@as(?[]const u8, null), args.header);
}

test "parseGetArgs: -c mode still honors an explicit --header= override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try parseGetArgs(arena.allocator(), &.{ "zlib", "-c", "--header=zconf.h", "--funcs=f" });
    try std.testing.expectEqualStrings("zconf.h", args.header.?);
}

test "parseGetArgs: --lib-dir= is repeatable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try parseGetArgs(arena.allocator(), &.{ "zlib", "--header=zlib.h", "--funcs=f", "--lib-dir=/a", "--lib-dir=/b" });
    try std.testing.expectEqual(@as(usize, 2), args.lib_dirs.len);
    try std.testing.expectEqualStrings("/a", args.lib_dirs[0]);
    try std.testing.expectEqualStrings("/b", args.lib_dirs[1]);
}

test "parseGetArgs: -zig= mode with a valid --artifact= parses correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try parseGetArgs(arena.allocator(), &.{
        "zlib", "-zig=https://github.com/allyourcodebase/zlib/archive/refs/heads/main.tar.gz", "--artifact=z", "--funcs=zlibCompileFlags",
    });
    try std.testing.expectEqual(Get.Mode.zig, args.mode);
    try std.testing.expectEqualStrings("https://github.com/allyourcodebase/zlib/archive/refs/heads/main.tar.gz", args.zig_url.?);
    try std.testing.expectEqualStrings("z", args.zig_artifact.?);
    try std.testing.expectEqual(@as(?[]const u8, null), args.header);
}

test "parseGetArgs: -zig= without --artifact= is a clear error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingArtifact, parseGetArgs(arena.allocator(), &.{ "zlib", "-zig=https://example.com/z.tar.gz", "--funcs=f" }));
}

test "parseGetArgs: -zig= mode rejects --link= (linking happens via linkLibrary, not flags)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ZigModeFlagNotApplicable, parseGetArgs(arena.allocator(), &.{
        "zlib", "-zig=https://example.com/z.tar.gz", "--artifact=z", "--funcs=f", "--link=z",
    }));
}

test "parseGetArgs: -c then -zig= together is a clear conflicting-mode error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ConflictingMode, parseGetArgs(arena.allocator(), &.{
        "zlib", "-c", "-zig=https://example.com/z.tar.gz", "--artifact=z", "--funcs=f",
    }));
}

test "parseGetArgs: -c given twice is a clear conflicting-mode error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ConflictingMode, parseGetArgs(arena.allocator(), &.{ "zlib", "-c", "-c", "--funcs=f" }));
}

test "parseGetArgs: -c=<url> vendoring mode parses correctly, library stays the short identifier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try parseGetArgs(arena.allocator(), &.{
        "zlib", "-c=https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz", "--funcs=zlibCompileFlags",
    });
    try std.testing.expectEqual(Get.Mode.c, args.mode);
    try std.testing.expectEqualStrings("zlib", args.library);
    try std.testing.expectEqualStrings("https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz", args.vendor_url.?);
    try std.testing.expectEqual(@as(?[]const u8, null), args.header);
}

test "parseGetArgs: -c= then -zig= together is a clear conflicting-mode error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ConflictingMode, parseGetArgs(arena.allocator(), &.{
        "zlib", "-c=https://example.com/z.tar.gz", "-zig=https://example.com/z.tar.gz", "--artifact=z", "--funcs=f",
    }));
}

test "parseGetArgs: --c-build= without -c=<url> is a clear error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.CBuildRequiresVendorUrl, parseGetArgs(arena.allocator(), &.{
        "zlib", "-c", "--c-build=make", "--funcs=f",
    }));
}

test "parseGetArgs: --c-build= requires at least one --link=" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MissingLinkForCBuild, parseGetArgs(arena.allocator(), &.{
        "zlib", "-c=https://example.com/z.tar.gz", "--c-build=make", "--funcs=f",
    }));
}

test "parseGetArgs: -c=<url> with --c-build= and --link= is a valid tier-2 vendoring config" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const args = try parseGetArgs(arena.allocator(), &.{
        "zlib", "-c=https://example.com/z.tar.gz", "--c-build=./configure && make", "--link=z", "--funcs=f",
    });
    try std.testing.expectEqualStrings("./configure && make", args.vendor_c_build.?);
    try std.testing.expectEqual(@as(usize, 1), args.link.len);
}
