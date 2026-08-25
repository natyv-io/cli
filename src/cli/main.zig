//! Entry point for the dev-facing `natyv` CLI (`natyv prepare`, `natyv
//! build`, `natyv init`) -- see ~/.claude/plans/lexical-wishing-penguin.md
//! for the full staged plan. Deliberately a separate binary from
//! natyv-core (`src/main.zig`, the app runtime `natyv build` eventually
//! bundles a compiled guest into): this one only ever reads/writes files
//! and spawns the dev's own configured compile command (`Compile.zig`),
//! so it carries none of natyv-core's SDL3/Extism/Clay dependencies.
//!
//! `natyv build` runs the full prepare -> wasm_compile -> bundle chain
//! (skipping straight to bundling when nothing's changed since the last
//! successful compile), producing a genuinely self-contained binary.
//! `natyv init` interactively scaffolds a new app in place.

const std = @import("std");
const Config = @import("Config");
const Prepare = @import("Prepare");
const Compile = @import("Compile.zig");
const BuildCache = @import("BuildCache");
const Bundle = @import("Bundle.zig");
const Bind = @import("Bind.zig");
const Init = @import("Init.zig");
const build_options = @import("build_options");

pub const Subcommand = enum { prepare, build, init };

pub const ParsedArgs = struct {
    subcommand: Subcommand,
    /// Meaningless for `.init` (see doc comment below) -- always populated
    /// anyway so callers don't need to special-case reading it.
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
/// whatever directory it's invoked from) -- its second positional arg
/// slot, if present, is deliberately ignored here rather than
/// misinterpreted as one.
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
    else
        return error.UnknownSubcommand;
    const config_path: []const u8 = if (args.len > 1) args[1] else "conf.natyv.json";
    return .{ .subcommand = subcommand, .config_path = config_path };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;
    const argv = init.minimal.args.vector;

    var arg_slices: [8][]const u8 = undefined;
    var arg_count: usize = 0;
    var i: usize = 1; // argv[0] is this executable's own path.
    while (i < argv.len and arg_count < arg_slices.len) : (i += 1) {
        arg_slices[arg_count] = std.mem.span(argv[i]);
        arg_count += 1;
    }
    const args = arg_slices[0..arg_count];

    const parsed = parseArgs(args) catch |err| {
        switch (err) {
            error.MissingSubcommand => std.debug.print("usage: natyv <prepare|build|init> [conf.natyv.json path]\n", .{}),
            error.UnknownSubcommand => std.debug.print("natyv: unknown subcommand '{s}' (expected 'prepare', 'build', or 'init')\n", .{args[0]}),
        }
        return err;
    };

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
            var binding_link: []const u8 = "";
            if (config.value.bindings.len > 0) {
                const bind_outcome = try Bind.run(arena_alloc, io, config.value.bindings, natyv_core_src, guest_dir);
                if (bind_outcome.err) |e| {
                    std.debug.print("{s}\n", .{e.message});
                    return error.BindFailed;
                }
                binding_include_dirs = try std.mem.join(arena_alloc, ",", bind_outcome.include_dirs);
                binding_link = try std.mem.join(arena_alloc, ",", bind_outcome.link);
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
            const bundle_result = try Bundle.run(arena_alloc, io, natyv_core_src, wasm_full_path, dist_dir, config.value.name, config.value.bindings.len > 0, binding_include_dirs, binding_link);
            if (bundle_result.err) |e| {
                std.debug.print("{s}\n", .{e.message});
                return error.BundleFailed;
            }
            std.debug.print("natyv build: {s} -- built {s}/{s}\n", .{ config.value.name, dist_dir_path, config.value.name });
        },
        .init => unreachable, // handled above
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
