//! Maps `conf.natyv.json`'s `compile_targets` friendly names (e.g.
//! `"macos-arm64"`) to the real Zig target triple `natyv build` passes to
//! `zig build install-core -Dtarget=<triple>` (see `Bundle.zig`), plus an
//! `Os` classification `Bundle.zig` uses instead of `builtin.target.os.tag`
//! for its own macOS-`.app`-vs-flat-binary branching -- `builtin.target` is
//! the *natyv CLI's own* compile target, not necessarily the OS actually
//! being cross-compiled for, so it's the wrong thing to branch on once a
//! single host can produce binaries for more than one OS at a time.
//!
//! **Deliberately a small, curated allowlist, not every triple Zig can
//! theoretically cross-compile to.** Confirmed 2026-08-28/29: `natyv-core`
//! genuinely *runs* correctly (not just compiles) on `aarch64-macos`/
//! `x86_64-macos` (native, always true), `aarch64-linux-gnu`, and
//! `x86_64-windows-gnu` -- real VM verification for all three (see the
//! `natyv-vm-verification-windows` memory). `x86_64-linux-gnu` compiles
//! cleanly too but has never been runtime-verified, so it's deliberately
//! left out of this list rather than sitting in the config surface looking
//! equally trustworthy -- add it once someone actually runs it.

const std = @import("std");
const builtin = @import("builtin");

pub const Os = enum { macos, windows, linux };

pub const Target = struct {
    /// The exact string passed to `zig build install-core -Dtarget=`.
    triple: []const u8,
    os: Os,
};

const Entry = struct {
    name: []const u8,
    target: Target,
};

const table = [_]Entry{
    .{ .name = "macos-arm64", .target = .{ .triple = "aarch64-macos", .os = .macos } },
    .{ .name = "macos-x64", .target = .{ .triple = "x86_64-macos", .os = .macos } },
    .{ .name = "windows-x64", .target = .{ .triple = "x86_64-windows-gnu", .os = .windows } },
    .{ .name = "linux-arm64", .target = .{ .triple = "aarch64-linux-gnu", .os = .linux } },
};

/// `null` on an unrecognized name -- callers surface this as a clear,
/// natyv-attributed error listing the real accepted names (see
/// `cli/main.zig`), never a bare "not found" or a silent skip.
pub fn resolve(name: []const u8) ?Target {
    for (table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.target;
    }
    return null;
}

/// True when `t` names the exact same OS+arch the natyv CLI itself is
/// running on -- real, found empirically 2026-08-29: passing an explicit
/// `-Dtarget=` matching the host exactly is *not* equivalent to omitting
/// it, at least for `allyourcodebase/SDL3`'s own build.zig (its `iconv`
/// auto-detection apparently only fires for the true default-native path,
/// not an explicitly-specified-but-identical target) -- so a
/// `compile_targets` entry that happens to match the host gets built the
/// same way an empty `compile_targets` list already does (`target: null`,
/// no `-Dtarget=` flag at all), not by passing its triple through anyway.
pub fn isNativeTarget(t: Target) bool {
    const host_os: Os = switch (builtin.target.os.tag) {
        .macos => .macos,
        .windows => .windows,
        .linux => .linux,
        else => return false,
    };
    if (t.os != host_os) return false;
    return switch (builtin.cpu.arch) {
        .aarch64 => std.mem.startsWith(u8, t.triple, "aarch64"),
        .x86_64 => std.mem.startsWith(u8, t.triple, "x86_64"),
        else => false,
    };
}

/// For error messages -- the real, current list of accepted names, so a
/// typo'd `compile_targets` entry gets told exactly what *is* valid
/// instead of just that it failed.
pub fn acceptedNamesJoined(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (table, 0..) |entry, i| {
        if (i != 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, entry.name);
    }
    return out.toOwnedSlice(allocator);
}

test "resolve: every real accepted name maps to the right triple/os" {
    try std.testing.expectEqualStrings("aarch64-macos", resolve("macos-arm64").?.triple);
    try std.testing.expectEqual(Os.macos, resolve("macos-arm64").?.os);
    try std.testing.expectEqualStrings("x86_64-macos", resolve("macos-x64").?.triple);
    try std.testing.expectEqualStrings("x86_64-windows-gnu", resolve("windows-x64").?.triple);
    try std.testing.expectEqual(Os.windows, resolve("windows-x64").?.os);
    try std.testing.expectEqualStrings("aarch64-linux-gnu", resolve("linux-arm64").?.triple);
    try std.testing.expectEqual(Os.linux, resolve("linux-arm64").?.os);
}

test "resolve: an unrecognized name (including the deliberately-omitted linux-x64) returns null" {
    try std.testing.expect(resolve("linux-x64") == null);
    try std.testing.expect(resolve("bogus") == null);
}

test "acceptedNamesJoined lists every real name" {
    const allocator = std.testing.allocator;
    const joined = try acceptedNamesJoined(allocator);
    defer allocator.free(joined);
    try std.testing.expectEqualStrings("macos-arm64, macos-x64, windows-x64, linux-arm64", joined);
}

test "isNativeTarget: a target matching the current host's real os+arch is native" {
    const host_name = switch (builtin.target.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => "macos-arm64",
            .x86_64 => "macos-x64",
            else => return error.SkipZigTest,
        },
        .linux => switch (builtin.cpu.arch) {
            .aarch64 => "linux-arm64",
            else => return error.SkipZigTest,
        },
        else => return error.SkipZigTest,
    };
    try std.testing.expect(isNativeTarget(resolve(host_name).?));
}

test "isNativeTarget: a target for a different OS is never native" {
    const other_os_name = if (builtin.target.os.tag == .windows) "linux-arm64" else "windows-x64";
    try std.testing.expect(!isNativeTarget(resolve(other_os_name).?));
}
