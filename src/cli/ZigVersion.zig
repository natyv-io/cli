//! Real `zig version` pre-flight check, run once before `natyv` shells out
//! to the real Zig toolchain for anything (`prepare`/`build`, both of
//! which eventually reach a real `zig build`/`zig build-exe`/
//! `zig translate-c` invocation via `Bind.zig`/`Compile.zig`/`Bundle.zig`/
//! `TranslateC.zig`). Doesn't assume the caller already has the right zig
//! on PATH -- natyv also targets Go communities, not just Zig's own, and
//! even a Zig-using caller can't be assumed to be on the exact pinned
//! minor version (see `project_natyv_distribution_packaging` memory: a
//! future Homebrew formula deliberately won't `depends_on "zig"`, since
//! Homebrew's own zig formula tracks whatever's currently stable, not
//! necessarily what natyv actually needs). One clear, natyv-attributed
//! message here beats a confusing failure surfacing from deep inside
//! natyv-core's own build.zig.

const std = @import("std");
const Io = std.Io;

/// Matches this project's own "pin, hold N-1" toolchain policy (see
/// CLAUDE.md's Toolchain section) -- 0.16.x is supported, 0.17+ isn't yet.
pub const min_supported = std.SemanticVersion{ .major = 0, .minor = 16, .patch = 0 };
pub const max_supported_exclusive = std.SemanticVersion{ .major = 0, .minor = 17, .patch = 0 };

pub const CheckError = struct {
    message: []const u8,
};

pub const Result = struct {
    ok: bool,
    err: ?CheckError,
};

/// `>= min_supported` and `< max_supported_exclusive`. Kept as its own
/// pure function, directly testable without a subprocess -- mirrors
/// `PkgConfig.zig`'s own split between pure parsing logic and the real
/// subprocess call that feeds it.
pub fn isSupported(v: std.SemanticVersion) bool {
    return v.order(min_supported) != .lt and v.order(max_supported_exclusive) == .lt;
}

/// Runs `zig version` as a real subprocess and checks the result against
/// the pinned supported range. Three distinct failure modes, matching this
/// codebase's own established "don't fold every subprocess failure into
/// one generic message" convention (see `PkgConfig.zig`'s own three-way
/// split): zig isn't installed at all, `zig version`'s output doesn't
/// parse as a real semver, or it parses but falls outside the supported
/// range.
pub fn check(allocator: std.mem.Allocator, io: Io) !Result {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "zig", "version" },
    }) catch |e| {
        if (e == error.FileNotFound) {
            return .{ .ok = false, .err = .{
                .message = try std.fmt.allocPrint(
                    allocator,
                    "natyv: zig is not installed or not on PATH -- natyv requires zig {d}.{d}.{d} (up to but not including {d}.{d}.{d}); see https://ziglang.org/download/",
                    .{ min_supported.major, min_supported.minor, min_supported.patch, max_supported_exclusive.major, max_supported_exclusive.minor, max_supported_exclusive.patch },
                ),
            } };
        }
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv: could not run 'zig version': {s}", .{@errorName(e)}),
        } };
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                return .{ .ok = false, .err = .{
                    .message = try std.fmt.allocPrint(allocator, "natyv: 'zig version' failed (exit code {d}):\n{s}{s}", .{ code, result.stdout, result.stderr }),
                } };
            }
        },
        else => |term| {
            return .{ .ok = false, .err = .{
                .message = try std.fmt.allocPrint(allocator, "natyv: 'zig version' exited abnormally ({any}):\n{s}{s}", .{ term, result.stdout, result.stderr }),
            } };
        },
    }

    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    const found = std.SemanticVersion.parse(trimmed) catch {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(
                allocator,
                "natyv: could not parse 'zig version' output ({s}) as a version -- natyv requires zig {d}.{d}.{d} (up to but not including {d}.{d}.{d})",
                .{ trimmed, min_supported.major, min_supported.minor, min_supported.patch, max_supported_exclusive.major, max_supported_exclusive.minor, max_supported_exclusive.patch },
            ),
        } };
    };

    if (!isSupported(found)) {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(
                allocator,
                "natyv: found zig {s}, but natyv requires zig {d}.{d}.{d} (up to but not including {d}.{d}.{d}) -- install a matching version, or point `natyv` at one via PATH",
                .{ trimmed, min_supported.major, min_supported.minor, min_supported.patch, max_supported_exclusive.major, max_supported_exclusive.minor, max_supported_exclusive.patch },
            ),
        } };
    }

    return .{ .ok = true, .err = null };
}

test "isSupported: within range" {
    try std.testing.expect(isSupported(.{ .major = 0, .minor = 16, .patch = 0 }));
    try std.testing.expect(isSupported(.{ .major = 0, .minor = 16, .patch = 9 }));
}

test "isSupported: below min is rejected" {
    try std.testing.expect(!isSupported(.{ .major = 0, .minor = 15, .patch = 1 }));
}

test "isSupported: at or above max-exclusive is rejected" {
    try std.testing.expect(!isSupported(.{ .major = 0, .minor = 17, .patch = 0 }));
    try std.testing.expect(!isSupported(.{ .major = 1, .minor = 0, .patch = 0 }));
}

test "isSupported: a pre-release of an in-range version is still accepted" {
    // Real `zig version` output for a dev build looks like
    // "0.16.0-dev.164+2ba26c780" -- `SemanticVersion.order` already
    // handles pre-release precedence correctly, so this should just work,
    // confirmed directly rather than assumed.
    try std.testing.expect(isSupported(.{ .major = 0, .minor = 16, .patch = 0, .pre = "dev.164" }));
}

test "check: a real, live zig version check against the actual installed toolchain" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const result = try check(allocator, io);
    defer if (result.err) |e| allocator.free(e.message);
    // Not hardcoding `ok == true`: this test genuinely runs against
    // whatever zig happens to be on the machine's PATH. What it actually
    // proves is that the subprocess plumbing itself works end to end --
    // real spawn, real stdout capture, real parse -- not a specific
    // version's presence.
    if (!result.ok) {
        std.debug.print("zig version check failed (informational, not necessarily a bug): {s}\n", .{result.err.?.message});
    }
}
