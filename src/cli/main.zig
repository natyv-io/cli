//! Entry point for the dev-facing `natyv` CLI (`natyv prepare`, `natyv
//! build`, `natyv init`, `natyv get`) -- see
//! ~/.claude/plans/lexical-wishing-penguin.md for the full staged plan.
//! Deliberately a separate binary from natyv-core (`src/main.zig`, the app
//! runtime `natyv build` eventually bundles a compiled guest into): this
//! one only ever reads/writes files and spawns the dev's own configured
//! compile command (`Compile.zig`), so it carries none of natyv-core's
//! SDL3/Clay/FreeType dependencies. **Confirmed 2026-08-29: it does now
//! link real Extism** (see `build.zig`'s `linkExtism`) -- the Linux
//! AppImage-packing plugin (`PackageAppImage.zig`, reached via `Bundle.zig`)
//! calls a real embedded Extism plugin, and there's no standalone tool to
//! shell out to the way `sips`/`iconutil` already exist on every Mac for
//! macOS packaging.
//!
//! `natyv build` runs the full prepare -> wasm_compile -> bundle chain
//! (skipping straight to bundling when nothing's changed since the last
//! successful compile), producing a genuinely self-contained binary.
//! `natyv init` interactively scaffolds a new app in place. `natyv get`
//! (Stage 2.3 of the binding generator arc) declares one `bindings` entry
//! in `conf.natyv.json`; `natyv bind` is what actually generates from it --
//! Stage 2.7 folded that generation step into `Prepare.run` itself (its
//! own first step, real Bind.zig import via the named "Bind" module, not
//! this file directly -- see `Prepare.zig`'s own doc comment for why: a
//! plain `@import("Bind.zig")` here would conflict with `Prepare`'s own
//! named "Bind" import once both land in this same executable's build
//! graph, confirmed the hard way via a real "file exists in modules
//! 'root' and 'Bind'" compile error). `natyv prepare --codegen` limits
//! `Prepare.run` to just the stylesheet pass + bind, skipping `.ntx`
//! transpilation -- `natyv build`'s own pipeline picks the equivalent
//! mode from its existing `BuildCache` freshness check instead of a CLI
//! flag, so bind always runs exactly once per invocation regardless of
//! freshness, while `.ntx` transpile + `wasm_compile` stay skippable.

const std = @import("std");
const builtin = @import("builtin");
const Config = @import("Config");
const Prepare = @import("Prepare");
const Compile = @import("Compile.zig");
const BuildCache = @import("BuildCache");
const Bundle = @import("Bundle.zig");
const CompileTargets = @import("CompileTargets.zig");
const Get = @import("Get.zig");
const Init = @import("Init.zig");
const ZigVersion = @import("ZigVersion.zig");
const build_options = @import("build_options");

pub const Subcommand = enum { prepare, build, init, get };

pub const ParsedArgs = struct {
    subcommand: Subcommand,
    /// Meaningless for `.init`/`.get` (see doc comment below) -- always
    /// populated anyway so callers don't need to special-case reading it.
    config_path: []const u8,
    /// Only meaningful for `.prepare` (Stage 2.7) -- limits it to the
    /// stylesheet pass + `natyv bind`, skipping `.ntx` transpilation.
    /// Always `false` for every other subcommand; `.build` computes its
    /// own equivalent mode from `BuildCache`'s freshness check instead of
    /// reading this field.
    codegen: bool = false,
    /// Only meaningful for `.build` -- unconditionally treats
    /// `BuildCache`'s freshness check as stale for this invocation, so
    /// `prepare`/`wasm_compile` always re-run regardless of the cached
    /// hash. A manual escape hatch alongside the freshness check itself
    /// now also hashing `wasm_compile` (see `BuildCache.zig`) -- that fix
    /// closes the specific gap that motivated adding this flag (editing
    /// compile flags alone didn't invalidate the cache), but a flag is
    /// still worth having for any other cache surprise (e.g. a corrupted
    /// `.natyv-build-cache` file) without resorting to deleting the wasm
    /// output by hand.
    force: bool = false,
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
///
/// `--codegen` (Stage 2.7, only meaningful for `.prepare`) and `--force`
/// (only meaningful for `.build`, see `ParsedArgs.force`) can each appear
/// anywhere in `args[1..]`, in any order relative to an optional config
/// path -- the first non-flag argument is still taken as `config_path`,
/// exactly matching pre-Stage-2.7 behavior when neither flag is present.
///
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

    var config_path: []const u8 = "conf.natyv.json";
    var codegen = false;
    var force = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--codegen")) {
            codegen = true;
        } else if (std.mem.eql(u8, arg, "--force")) {
            force = true;
        } else {
            config_path = arg;
        }
    }
    return .{ .subcommand = subcommand, .config_path = config_path, .codegen = codegen, .force = force };
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

const CaCertEntry = struct {
    host: []const u8,
    port: u16,
    pem: []const u8,
};

/// Builds the real `embedded_ca_certs.json` payload `Bundle.run` stages --
/// reads every `allowed_sockets[].ca_cert_path` (relative to `config_dir`,
/// same convention as `icon`) now, at real `natyv build` time, so a bundled
/// `.app` never needs to resolve a relative path against a directory it
/// has no reliable notion of at runtime (see `EmbeddedWasmPresent.zig`'s
/// own doc comment). `std.json.Stringify.valueAlloc` (not manual string
/// building) handles real PEM content correctly -- a PEM file's own
/// embedded newlines need real JSON string escaping, not just naive
/// concatenation.
fn buildCaCertsJson(allocator: std.mem.Allocator, io: std.Io, allowed_sockets: []const Config.AllowedSocket, config_dir: []const u8) ![]const u8 {
    var entries: std.ArrayList(CaCertEntry) = .empty;
    for (allowed_sockets) |entry| {
        const cert_path = entry.ca_cert_path orelse continue;
        const full_path = try std.fs.path.join(allocator, &.{ config_dir, cert_path });
        const pem = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .unlimited) catch |e| {
            std.debug.print("natyv build: could not read ca_cert_path '{s}' for {s}:{d}: {s}\n", .{ full_path, entry.host, entry.port, @errorName(e) });
            return error.CaCertReadFailed;
        };
        try entries.append(allocator, .{ .host = entry.host, .port = entry.port, .pem = pem });
    }
    return std.json.Stringify.valueAlloc(allocator, entries.items, .{});
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
    // `Args.Iterator.initAllocator`, not raw `argv[i]` indexing --
    // `init.minimal.args.vector` isn't an array of C-string pointers on
    // every target the way it is on POSIX: on Windows it's the single raw
    // UTF-16 command-line string the OS actually hands a process, which
    // `std.mem.span`-style indexing can't even typecheck against. The
    // iterator does the real cross-platform (and Windows-specific)
    // parsing so this file doesn't have to.
    var arg_iter = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_iter.deinit();
    _ = arg_iter.skip(); // argv[0] is this executable's own path.

    // 64, not the original 8 -- `natyv get`'s repeatable
    // `--include-dir=`/`--link=` flags (Stage 2.3) can realistically add
    // up to more than 8 total args including the subcommand, and the
    // original bound would have silently truncated anything past it with
    // no error at all.
    var arg_slices: [64][]const u8 = undefined;
    var arg_count: usize = 0;
    while (arg_count < arg_slices.len) {
        const arg = arg_iter.next() orelse break;
        arg_slices[arg_count] = arg;
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

        const result = try Init.run(arena_alloc, io, language, cwd_name, std.Io.Dir.cwd());
        if (result.err) |e| {
            std.debug.print("{s}\n", .{e.message});
            return error.InitFailed;
        }
        std.debug.print("natyv init: scaffolded a new Go natyv app here -- try `natyv build` next\n", .{});
        return;
    }

    // `.prepare`/`.build` are the only two subcommands that ever shell out
    // to a real `zig` toolchain (via `Bind.zig`/`Compile.zig`/`Bundle.zig`/
    // `TranslateC.zig`) -- `.get`/`.init` already returned above without
    // reaching this point. Checked once, up front, so a missing or
    // mismatched zig install fails with one clear, natyv-attributed
    // message instead of a confusing failure surfacing later from deep
    // inside natyv-core's own build.zig.
    const zig_check = try ZigVersion.check(allocator, io);
    if (!zig_check.ok) {
        std.debug.print("{s}\n", .{zig_check.err.?.message});
        return error.UnsupportedZigVersion;
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

    // Texture-fill styling system: the app dev's own asset files, staged
    // by `Prepare.run` whenever the stylesheet references a `texture` --
    // see that file's own `stageTextureAssets` doc comment. A missing
    // `assets/` directory is not an error here -- most apps have no
    // texture fill at all, and `Prepare.run` itself only treats it as a
    // real error if a texture is actually referenced with none present.
    const assets_dir_path = try std.fs.path.join(allocator, &.{ config_dir, "assets" });
    defer allocator.free(assets_dir_path);
    var assets_dir_opt: ?std.Io.Dir = std.Io.Dir.cwd().openDir(io, assets_dir_path, .{}) catch null;
    defer if (assets_dir_opt) |*d| d.close(io);

    switch (parsed.subcommand) {
        .prepare => {
            var guest_dir = std.Io.Dir.cwd().openDir(io, guest_dir_path, .{ .iterate = true }) catch |err| {
                std.debug.print("natyv prepare: could not open '{s}': {}\n", .{ guest_dir_path, err });
                return err;
            };
            defer guest_dir.close(io);

            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();

            // Stage 2.7: `natyv bind` runs as `Prepare.run`'s own first
            // step now -- `NATYV_CORE_SRC` resolved here (never needed by
            // this subcommand before) the same way `.build`'s case
            // already does, since bind needs it whenever there are any
            // `bindings` entries at all.
            const natyv_core_src = init.environ_map.get("NATYV_CORE_SRC") orelse build_options.natyv_core_src_default;
            const mode: Prepare.Mode = if (parsed.codegen) .codegen_only else .full;
            const outcome = try Prepare.run(arena.allocator(), io, guest_dir, config.value.bindings, natyv_core_src, mode, config.value.images.enabled, assets_dir_opt);
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
            // Resolved early since `Prepare.run` below needs it whenever
            // there are any `bindings` entries.
            const natyv_core_src = init.environ_map.get("NATYV_CORE_SRC") orelse build_options.natyv_core_src_default;

            // `zig build install-core` writes its own real `.zig-cache`/
            // `zig-pkg` directories into wherever it's invoked from
            // (`natyv_core_src`) -- fine for a normal project checkout a
            // dev already gitignores, but confirmed for real to be a
            // genuine problem once `natyv_core_src` is a Homebrew-managed
            // (or any other packaging-managed) install location: repeated
            // `natyv build` runs would keep growing a package directory
            // that's supposed to stay read-only after install (found via
            // a real natyv-core Homebrew formula ballooning to 2GB after
            // one real app build). Redirected here to a real, dedicated
            // location instead -- `natyv cache --clear`/`natyv cache
            // --dir=` (an explicit override) are confirmed future,
            // post-v1 work; hardcoded to `~/.cache/natyv` for now.
            const home = init.environ_map.get("HOME") orelse {
                std.debug.print("natyv build: could not determine cache directory (HOME is not set)\n", .{});
                return error.BundleFailed;
            };
            const cache_dir = try std.fs.path.join(arena_alloc, &.{ home, ".cache", "natyv" });

            // Checked once, up front, before running anything -- Quinn's
            // own design: if nothing that affects the compiled wasm has
            // changed since the last successful wasm_compile, skip
            // straight to `.ntx` transpile + wasm_compile in favor of
            // going straight to bundling. Stage 2.7: this now picks
            // `Prepare.run`'s own `Mode` instead of gating a separate call
            // to it entirely -- `natyv bind` (folded into `Prepare.run`'s
            // own first step) must always run regardless, since
            // `Bundle.run` below needs its aggregated output on every
            // invocation, fresh or not; only the `.ntx` walk/transpile
            // itself (and, further down, `wasm_compile`) are skippable.
            const wasm_basename = try config.value.wasmFilename(arena_alloc);
            const fresh = !parsed.force and try BuildCache.isFresh(arena_alloc, io, guest_dir, wasm_basename, config.value.wasm_compile, config.value.memory.recycle_threshold_mb);
            const mode: Prepare.Mode = if (fresh) .codegen_only else .full;

            const outcome = try Prepare.run(arena_alloc, io, guest_dir, config.value.bindings, natyv_core_src, mode, config.value.images.enabled, assets_dir_opt);
            if (outcome.err) |e| {
                std.debug.print("{s}\n", .{e.message});
                return error.PrepareFailed;
            }

            // Stage 2.2/2.5/2.6: `Bundle.run`'s own build.zig flags, now
            // read from `Prepare.run`'s own `Outcome` (which folds in
            // `Bind.run`'s aggregated output as of Stage 2.7) instead of a
            // separate `Bind.run` call this case used to make itself.
            const binding_include_dirs = try std.mem.join(arena_alloc, ",", outcome.binding_include_dirs);
            const binding_lib_dirs = try std.mem.join(arena_alloc, ",", outcome.binding_lib_dirs);
            const binding_link = try std.mem.join(arena_alloc, ",", outcome.binding_link);

            // Stage 2.5: `name:artifact` pairs for `build.zig`'s own
            // `-Dbinding-zig-deps` loop (see that file's comment on why a
            // `-zig`-mode entry needs `b.dependency(...).artifact(...)` +
            // `linkLibrary`, not flags like the other three above).
            var zig_deps_parts: std.ArrayList(u8) = .empty;
            for (outcome.binding_zig_deps, 0..) |zd, zi| {
                if (zi > 0) try zig_deps_parts.append(arena_alloc, ',');
                try zig_deps_parts.appendSlice(arena_alloc, try std.fmt.allocPrint(arena_alloc, "{s}:{s}", .{ zd.name, zd.artifact }));
            }
            const binding_zig_deps = zig_deps_parts.items;

            // Stage 2.6: absolute `.c` file paths (tier-1 default
            // vendoring) for `build.zig`'s own `-Dbinding-vendor-c-files`
            // -- a plain comma list, unlike `zig_deps` above, since
            // `build.zig` doesn't need to know which library a file
            // belongs to, only that it's part of `bindings_mod`.
            const binding_vendor_c_files = try std.mem.join(arena_alloc, ",", outcome.binding_vendor_c_files);

            if (fresh) {
                std.debug.print("natyv build: {s} -- wasm is already up to date, skipping prepare/wasm_compile\n", .{config.value.name});
            } else {
                std.debug.print("natyv build: {s} -- running wasm_compile...\n", .{config.value.name});
                const compile_result = try Compile.run(arena_alloc, io, config.value.wasm_compile, guest_dir);
                if (compile_result.err) |e| {
                    std.debug.print("{s}\n", .{e.message});
                    return error.WasmCompileFailed;
                }

                const new_hash = try BuildCache.computeSourceHash(arena_alloc, io, guest_dir, config.value.wasm_compile, config.value.memory.recycle_threshold_mb);
                try BuildCache.writeCachedHash(io, guest_dir, new_hash);
            }

            // Bundling always runs regardless of freshness -- freshness
            // only ever skips prepare/wasm_compile, never the final
            // bundle step, per Quinn's own explicit design.
            const wasm_full_path = try std.fs.path.join(arena_alloc, &.{ guest_dir_path, wasm_basename });

            // Only meaningful on macOS (see `Bundle.zig`'s own doc
            // comment) -- resolved unconditionally regardless of host OS
            // since it's cheap and keeps `Bundle.run`'s own signature
            // simple; the icon path is `Config.icon`, relative to the
            // config file's own directory, same convention as `assets/`.
            const bundle_id = try config.value.effectiveBundleId(arena_alloc);
            const icon_path: ?[]const u8 = if (config.value.icon) |icon| try std.fs.path.join(arena_alloc, &.{ config_dir, icon }) else null;

            // Real custom-CA staging: read each `allowed_sockets[].
            // ca_cert_path` (relative to `config_dir`, same convention as
            // `icon` above) now, at real `natyv build` time, so
            // `Bundle.run` just stages already-resolved bytes -- see its
            // own doc comment and `EmbeddedWasmPresent.zig`'s for why a
            // bundled `.app` can't do this relative-path resolution again
            // at runtime.
            const ca_certs_json = try buildCaCertsJson(arena_alloc, io, config.value.network.tcp.allowed_sockets, config_dir);

            // `compile_targets` fan-out (confirmed 2026-08-29): empty (the
            // default) means "build for whatever OS `natyv build` itself
            // is running on," exactly the original single-target behavior
            // -- one `dist/` directly, `target`/`target_os` resolved from
            // the CLI's own compile-time OS. A non-empty list produces one
            // real cross-compiled binary per declared friendly name (see
            // `CompileTargets.resolve`), each into its own `dist/<name>/`
            // subdirectory so multiple targets never collide with each
            // other or with the single-target default layout.
            if (config.value.compile_targets.len == 0) {
                const dist_dir_path = try std.fs.path.join(arena_alloc, &.{ config_dir, "dist" });
                var dist_dir = try std.Io.Dir.cwd().createDirPathOpen(io, dist_dir_path, .{});
                defer dist_dir.close(io);

                const native_os: Bundle.TargetOs = switch (builtin.target.os.tag) {
                    .macos => .macos,
                    .windows => .windows,
                    .linux => .linux,
                    else => std.process.fatal("natyv build: unsupported host OS {s}", .{@tagName(builtin.target.os.tag)}),
                };

                std.debug.print("natyv build: {s} -- bundling...\n", .{config.value.name});
                const bundle_result = try Bundle.run(arena_alloc, io, natyv_core_src, wasm_full_path, parsed.config_path, dist_dir, config.value.name, config.value.bindings.len > 0, binding_include_dirs, binding_lib_dirs, binding_link, binding_zig_deps, binding_vendor_c_files, outcome.has_textures, config.value.sqlite.enabled, bundle_id, icon_path, null, native_os, config.value.linux_package, ca_certs_json, cache_dir, config.value.build_mode.optimizeFlag());
                if (bundle_result.err) |e| {
                    std.debug.print("{s}\n", .{e.message});
                    return error.BundleFailed;
                }
                const output_suffix = switch (native_os) {
                    .macos => ".app",
                    .windows => ".exe",
                    .linux => "",
                };
                std.debug.print("natyv build: {s} -- built {s}/{s}{s}\n", .{ config.value.name, dist_dir_path, config.value.name, output_suffix });
            } else {
                for (config.value.compile_targets) |target_name| {
                    const resolved = CompileTargets.resolve(target_name) orelse {
                        const accepted = try CompileTargets.acceptedNamesJoined(arena_alloc);
                        std.debug.print("natyv build: unrecognized compile_targets entry '{s}' (accepted: {s})\n", .{ target_name, accepted });
                        return error.BundleFailed;
                    };
                    const dist_dir_path = try std.fs.path.join(arena_alloc, &.{ config_dir, "dist", target_name });
                    var dist_dir = try std.Io.Dir.cwd().createDirPathOpen(io, dist_dir_path, .{});
                    defer dist_dir.close(io);

                    const resolved_os: Bundle.TargetOs = switch (resolved.os) {
                        .macos => .macos,
                        .windows => .windows,
                        .linux => .linux,
                    };
                    // See `CompileTargets.isNativeTarget`'s own doc comment --
                    // a declared target matching the host exactly is built
                    // the same way an empty `compile_targets` list already
                    // is (no `-Dtarget=` flag at all), not by passing its
                    // triple through anyway.
                    const target_triple: ?[]const u8 = if (CompileTargets.isNativeTarget(resolved)) null else resolved.triple;

                    std.debug.print("natyv build: {s} -- bundling for {s}...\n", .{ config.value.name, target_name });
                    const bundle_result = try Bundle.run(arena_alloc, io, natyv_core_src, wasm_full_path, parsed.config_path, dist_dir, config.value.name, config.value.bindings.len > 0, binding_include_dirs, binding_lib_dirs, binding_link, binding_zig_deps, binding_vendor_c_files, outcome.has_textures, config.value.sqlite.enabled, bundle_id, icon_path, target_triple, resolved_os, config.value.linux_package, ca_certs_json, cache_dir, config.value.build_mode.optimizeFlag());
                    if (bundle_result.err) |e| {
                        std.debug.print("{s}\n", .{e.message});
                        return error.BundleFailed;
                    }
                    const output_suffix = switch (resolved.os) {
                        .macos => ".app",
                        .windows => ".exe",
                        .linux => "",
                    };
                    std.debug.print("natyv build: {s} -- built {s}/{s}{s}\n", .{ config.value.name, dist_dir_path, config.value.name, output_suffix });
                }
            }
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
    try std.testing.expect(!parsed.force);
}

test "parseArgs: build --force, either order relative to the config path" {
    const before = try parseArgs(&.{ "build", "--force", "examples/clay-fixture/conf.natyv.json" });
    try std.testing.expect(before.force);
    try std.testing.expectEqualStrings("examples/clay-fixture/conf.natyv.json", before.config_path);

    const after = try parseArgs(&.{ "build", "examples/clay-fixture/conf.natyv.json", "--force" });
    try std.testing.expect(after.force);
    try std.testing.expectEqualStrings("examples/clay-fixture/conf.natyv.json", after.config_path);
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

test "buildCaCertsJson: reads a real PEM file relative to config_dir, escapes real newlines correctly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const config_dir = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_path, tmp.sub_path });
    const pem = "-----BEGIN CERTIFICATE-----\nFAKEFAKEFAKE\n-----END CERTIFICATE-----\n";
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}/internal-ca.pem", .{config_dir}), .data = pem });

    const allowed_sockets = [_]Config.AllowedSocket{
        .{ .host = "internal.example.com", .port = 993, .tls = .implicit, .ca_cert_path = "internal-ca.pem" },
        .{ .host = "imap.gmail.com", .port = 993, .tls = .implicit }, // no ca_cert_path -- must be skipped
    };
    const json = try buildCaCertsJson(allocator, io, &allowed_sockets, config_dir);

    const parsed = try std.json.parseFromSlice([]const CaCertEntry, allocator, json, .{});
    try std.testing.expectEqual(@as(usize, 1), parsed.value.len); // only the entry with ca_cert_path set
    try std.testing.expectEqualStrings("internal.example.com", parsed.value[0].host);
    try std.testing.expectEqual(@as(u16, 993), parsed.value[0].port);
    try std.testing.expectEqualStrings(pem, parsed.value[0].pem); // real newlines survived the JSON round trip
}

test "buildCaCertsJson: no ca_cert_path anywhere produces a real empty array, not an error" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const allowed_sockets = [_]Config.AllowedSocket{
        .{ .host = "imap.gmail.com", .port = 993, .tls = .implicit },
    };
    const json = try buildCaCertsJson(allocator, io, &allowed_sockets, "/irrelevant");
    try std.testing.expectEqualStrings("[]", json);
}
