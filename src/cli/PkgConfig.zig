//! Real `pkg-config` discovery for `natyv get -c <bare-name>` -- Stage 2.4
//! of ~/.claude/plans/lexical-wishing-penguin.md. Only ever called for a
//! bare pkg-config module name (`zlib`, `sqlite3`) -- a `-c` target
//! containing `/` is a URL, routed to Stage 2.6's not-yet-built vendoring
//! path instead (`src/cli/Get.zig`'s own job to distinguish, not this
//! file's).
//!
//! Two real `std.process.run` calls (`pkg-config --cflags <module>`,
//! `--libs <module>`), mirroring `Compile.zig`/`Validate.zig`'s own
//! established precedent exactly -- never mocked. `pkg-config` genuinely
//! wasn't installed on the machine this was first built on (confirmed via
//! `which pkg-config` failing before `brew install pkg-config` was run),
//! so the "tool not installed" path below is real, not a hypothetical
//! edge case -- likely to be hit by a real natyv user too.

const std = @import("std");
const Io = std.Io;

pub const PkgConfigError = struct {
    message: []const u8,
};

pub const Discovery = struct {
    include_dirs: []const []const u8,
    lib_dirs: []const []const u8,
    link: []const []const u8,
};

pub const Result = struct {
    discovery: ?Discovery,
    err: ?PkgConfigError,
};

/// Splits `pkg-config --cflags` output on whitespace and collects `-I`
/// values into `include_dirs` -- anything else (e.g. a stray `-D` define)
/// is silently skipped, since `Config.BindingEntry` has no field for it.
/// A pure function, directly testable with a hand-written fixture string,
/// no subprocess needed.
pub fn parseCflags(allocator: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var include_dirs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |tok| {
        // `dupe`, not a plain slice into `text` -- callers (`discover`
        // below) free the real subprocess stdout buffer `text` itself
        // right after parsing; a bare slice into it would dangle the
        // moment that happens. Confirmed the hard way: a real, standalone
        // debug run of `discover("zlib")` printed a garbage byte instead
        // of "z" before this fix.
        if (std.mem.startsWith(u8, tok, "-I")) try include_dirs.append(allocator, try allocator.dupe(u8, tok[2..]));
    }
    return include_dirs.items;
}

/// Splits `pkg-config --libs` output on whitespace into `-L` (lib_dirs)
/// and `-l` (link, stored bare -- `"z"` not `"-lz"`, matching
/// `Config.BindingEntry.link`'s own convention) -- anything else is
/// silently skipped, same reasoning as `parseCflags`.
pub fn parseLibs(allocator: std.mem.Allocator, text: []const u8) !struct { lib_dirs: []const []const u8, link: []const []const u8 } {
    var lib_dirs: std.ArrayList([]const u8) = .empty;
    var link: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |tok| {
        // `dupe` here too -- same use-after-free reasoning as
        // `parseCflags` above.
        if (std.mem.startsWith(u8, tok, "-L")) {
            try lib_dirs.append(allocator, try allocator.dupe(u8, tok[2..]));
        } else if (std.mem.startsWith(u8, tok, "-l")) {
            try link.append(allocator, try allocator.dupe(u8, tok[2..]));
        }
    }
    return .{ .lib_dirs = lib_dirs.items, .link = link.items };
}

/// Runs both `pkg-config --cflags <module>` and `--libs <module>` as real
/// subprocesses and returns the parsed, combined result. `module` must
/// already be confirmed bare (no `/`) by the caller (`Get.zig`).
pub fn discover(allocator: std.mem.Allocator, io: Io, module: []const u8) !Result {
    const cflags_result = std.process.run(allocator, io, .{
        .argv = &.{ "pkg-config", "--cflags", module },
    }) catch |e| {
        if (e == error.FileNotFound) {
            return .{ .discovery = null, .err = .{
                .message = try std.fmt.allocPrint(allocator, "natyv get: pkg-config is not installed (required for `-c {s}` discovery) -- install it, or use natyv get's manual mode (--header=/--include-dir=/--link=) instead", .{module}),
            } };
        }
        return .{ .discovery = null, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv get: could not run 'pkg-config --cflags {s}': {s}", .{ module, @errorName(e) }),
        } };
    };
    defer allocator.free(cflags_result.stdout);
    switch (cflags_result.term) {
        .exited => |code| {
            if (code != 0) {
                defer allocator.free(cflags_result.stderr);
                return .{ .discovery = null, .err = .{
                    .message = try std.fmt.allocPrint(allocator, "natyv get: 'pkg-config --cflags {s}' failed (exit code {d}):\n{s}{s}", .{ module, code, cflags_result.stdout, cflags_result.stderr }),
                } };
            }
            allocator.free(cflags_result.stderr);
        },
        else => |term| {
            defer allocator.free(cflags_result.stderr);
            return .{ .discovery = null, .err = .{
                .message = try std.fmt.allocPrint(allocator, "natyv get: 'pkg-config --cflags {s}' exited abnormally ({any}):\n{s}{s}", .{ module, term, cflags_result.stdout, cflags_result.stderr }),
            } };
        },
    }
    const include_dirs = try parseCflags(allocator, cflags_result.stdout);

    const libs_result = std.process.run(allocator, io, .{
        .argv = &.{ "pkg-config", "--libs", module },
    }) catch |e| {
        return .{ .discovery = null, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv get: could not run 'pkg-config --libs {s}': {s}", .{ module, @errorName(e) }),
        } };
    };
    defer allocator.free(libs_result.stdout);
    switch (libs_result.term) {
        .exited => |code| {
            if (code != 0) {
                defer allocator.free(libs_result.stderr);
                return .{ .discovery = null, .err = .{
                    .message = try std.fmt.allocPrint(allocator, "natyv get: 'pkg-config --libs {s}' failed (exit code {d}):\n{s}{s}", .{ module, code, libs_result.stdout, libs_result.stderr }),
                } };
            }
            allocator.free(libs_result.stderr);
        },
        else => |term| {
            defer allocator.free(libs_result.stderr);
            return .{ .discovery = null, .err = .{
                .message = try std.fmt.allocPrint(allocator, "natyv get: 'pkg-config --libs {s}' exited abnormally ({any}):\n{s}{s}", .{ module, term, libs_result.stdout, libs_result.stderr }),
            } };
        },
    }
    const libs = try parseLibs(allocator, libs_result.stdout);

    return .{ .discovery = .{ .include_dirs = include_dirs, .lib_dirs = libs.lib_dirs, .link = libs.link }, .err = null };
}

test "parseCflags: -I flags collected, other tokens ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const dirs = try parseCflags(arena.allocator(), "-I/opt/homebrew/opt/zlib/include -DFOO=1\n");
    try std.testing.expectEqual(@as(usize, 1), dirs.len);
    try std.testing.expectEqualStrings("/opt/homebrew/opt/zlib/include", dirs[0]);
}

test "parseCflags: empty output is an empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const dirs = try parseCflags(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), dirs.len);
}

test "parseLibs: -L and -l split correctly, -l stored bare" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseLibs(arena.allocator(), "-L/opt/homebrew/opt/zlib/lib -lz\n");
    try std.testing.expectEqual(@as(usize, 1), result.lib_dirs.len);
    try std.testing.expectEqualStrings("/opt/homebrew/opt/zlib/lib", result.lib_dirs[0]);
    try std.testing.expectEqual(@as(usize, 1), result.link.len);
    try std.testing.expectEqualStrings("z", result.link[0]);
}

test "parseLibs: multiple -l flags, no -L present" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseLibs(arena.allocator(), "-lfoo -lbar");
    try std.testing.expectEqual(@as(usize, 0), result.lib_dirs.len);
    try std.testing.expectEqual(@as(usize, 2), result.link.len);
    try std.testing.expectEqualStrings("foo", result.link[0]);
    try std.testing.expectEqualStrings("bar", result.link[1]);
}

test "discover: a real, live zlib lookup via the now-installed pkg-config" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try discover(allocator, io, "zlib");
    try std.testing.expect(result.err == null);
    const d = result.discovery.?;
    // `-l` is the one flag pkg-config always emits for zlib regardless of
    // which real .pc file resolves -- confirmed empirically: without an
    // explicit PKG_CONFIG_PATH override, `pkgconf` resolves a Homebrew-
    // maintained stub describing *macOS's own built-in* zlib (already on
    // every default search path, so a real, correct `-I`/`-L`-free
    // response), not the separately-installed Homebrew zlib formula's own
    // keg-only .pc (which does carry real `-I`/`-L`, confirmed via a
    // manual `PKG_CONFIG_PATH=/opt/homebrew/opt/zlib/lib/pkgconfig`
    // override) -- so asserting a specific `-I`/`-L` shape here would be
    // asserting a machine-dependent pkg-config resolution detail, not this
    // function's own real behavior. `parseCflags`/`parseLibs`'s own tests
    // above already cover real `-I`/`-L` extraction directly against
    // pkg-config's documented output format; this test's job is proving
    // the real subprocess call + wiring works, not re-proving that.
    try std.testing.expect(d.link.len >= 1);
    try std.testing.expect(std.mem.eql(u8, d.link[0], "z"));
}

test "discover: an unknown module produces pkg-config's own real error, natyv-attributed" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const result = try discover(allocator, io, "this_pkgconfig_module_does_not_exist");
    defer if (result.err) |e| allocator.free(e.message);
    try std.testing.expect(result.discovery == null);
    try std.testing.expect(result.err != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "natyv get:") != null);
}
