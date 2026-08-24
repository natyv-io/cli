//! Entry point for the dev-facing `natyv` CLI (`natyv prepare`, `natyv
//! build`) -- see ~/.claude/plans/lexical-wishing-penguin.md for the full
//! staged plan this is Stage 1 of. Deliberately a separate binary from
//! natyv-core (`src/main.zig`, the app runtime `natyv build` eventually
//! bundles a compiled guest into): this one only ever reads/writes files
//! and (later stages) spawns the dev's own configured compile command, so
//! it carries none of natyv-core's SDL3/Extism/Clay dependencies.
//!
//! Stage 1 scope, deliberately narrow: recognize the two subcommands and
//! validate `conf.natyv.json` (including the new `wasm_compile` field --
//! see Config.zig). Neither subcommand does any real work yet -- that's
//! Stage 3 onward.

const std = @import("std");
const Config = @import("Config");
const Prepare = @import("Prepare");

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
        std.debug.print("natyv init: not yet implemented\n", .{});
        return;
    }

    const config = Config.load(allocator, io, parsed.config_path) catch |err| {
        std.debug.print("[natyv] failed to load {s}: {}\n", .{ parsed.config_path, err });
        return err;
    };
    defer config.deinit();

    // Guest source lives under `guest/`, relative to the *config file's*
    // own directory (not the process's cwd) -- matches every real example
    // and the same convention `app_wasm` resolution already uses in
    // `src/main.zig`.
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
        .build => std.debug.print("natyv build: config OK for '{s}' (Stage 1 skeleton -- bundling not yet implemented)\n", .{config.value.name}),
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
