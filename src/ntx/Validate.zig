//! `.ntx` tooling Stage 6b (~/.claude/plans/lexical-wishing-penguin.md):
//! post-codegen dependency validation. Stage 6a's component reuse makes a
//! real Go import cycle newly reachable from natyv-generated code (two
//! sibling feature packages each reusing a component the other owns) --
//! `go list ./...` is the minimal-cost way to catch it: no compilation,
//! no type-checking, cycle detection lives entirely in `cmd/go`'s shared
//! package-loading step (confirmed live 2026-08-24, tracing a genuine
//! cyclic two-package fixture through `go build`/`go vet`/`go list`, all
//! three failing identically). This stays strictly on the "inspection
//! only" side of this project's own "compile step is the app dev's
//! responsibility" line -- `go list` produces no build artifacts.
//!
//! First real use of `std.process` in this repo (via the real
//! `std.process.run` convenience wrapper -- spawns, pipes stdout/stderr,
//! waits, all in one call -- rather than hand-rolling pipe management for
//! what natyv only ever needs as a single blocking round trip).
//!
//! Dispatched by guest-language extension, the same strip-`.ntx`-and-
//! dispatch convention codegen itself uses: an extension without a
//! live-verified check (e.g. Rust's `cargo metadata`/`cargo tree` --
//! well-documented but not confirmed against a real `cargo` install on
//! this machine) is a deliberate no-op, not a stub error.

const std = @import("std");
const Io = std.Io;

pub const ValidateError = struct {
    message: []const u8,
};

pub const Result = struct {
    ok: bool,
    err: ?ValidateError,
};

/// Runs `go list ./...` in `dir_path`. Real stdout/stderr are never
/// swallowed -- a failure's message is the tool's own real diagnostic
/// (which already names the actual cyclic packages, e.g. "import cycle
/// not allowed\npackage foo\n\timports bar\n\timports foo"), prefixed
/// with one natyv-attributed line so it's clear which check produced it,
/// not a bare, unexplained compiler dump.
pub fn goListCheck(allocator: std.mem.Allocator, io: Io, dir: Io.Dir) !Result {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "go", "list", "./..." },
        .cwd = .{ .dir = dir },
    }) catch |e| {
        return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv: could not run 'go list ./...': {s}", .{@errorName(e)}) } };
    };
    defer allocator.free(result.stdout);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                allocator.free(result.stderr);
                return .{ .ok = true, .err = null };
            }
            defer allocator.free(result.stderr);
            return .{ .ok = false, .err = .{
                .message = try std.fmt.allocPrint(allocator, "natyv: 'go list ./...' reported a real dependency problem:\n{s}", .{result.stderr}),
            } };
        },
        else => |term| {
            defer allocator.free(result.stderr);
            return .{ .ok = false, .err = .{
                .message = try std.fmt.allocPrint(allocator, "natyv: 'go list ./...' exited abnormally ({any}):\n{s}", .{ term, result.stderr }),
            } };
        },
    }
}

/// Dispatches on `ext` (the real remaining extension after stripping
/// `.ntx`, no leading dot, e.g. "go") to the right dependency-validation
/// command -- an extension with no live-verified check is a deliberate
/// no-op (`ok = true`), not a stub error.
pub fn validateForExtension(allocator: std.mem.Allocator, io: Io, ext: []const u8, dir: Io.Dir) !Result {
    if (std.mem.eql(u8, ext, "go")) return goListCheck(allocator, io, dir);
    return .{ .ok = true, .err = null };
}

test "a clean, non-cyclic Go module passes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module cleantest\n\ngo 1.23\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.go", .data = "package main\n\nfunc main() {}\n" });

    const result = try goListCheck(std.testing.allocator, io, tmp.dir);
    defer if (result.err) |e| std.testing.allocator.free(e.message);
    try std.testing.expect(result.ok);
    try std.testing.expect(result.err == null);
}

test "a genuine two-package import cycle fails with a clear, natyv-attributed message naming the real packages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module cycletest\n\ngo 1.23\n" });

    var pkg_a = try tmp.dir.createDirPathOpen(io, "a", .{});
    defer pkg_a.close(io);
    try pkg_a.writeFile(io, .{ .sub_path = "a.go", .data = "package a\n\nimport _ \"cycletest/b\"\n" });

    var pkg_b = try tmp.dir.createDirPathOpen(io, "b", .{});
    defer pkg_b.close(io);
    try pkg_b.writeFile(io, .{ .sub_path = "b.go", .data = "package b\n\nimport _ \"cycletest/a\"\n" });

    const result = try goListCheck(std.testing.allocator, io, tmp.dir);
    defer if (result.err) |e| std.testing.allocator.free(e.message);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "natyv:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "import cycle") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "cycletest/a") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "cycletest/b") != null);
}

test "the Stage 6a component-reuse fixture (non-cyclic) passes cleanly for real" {
    const io = std.testing.io;
    std.Io.Dir.cwd().access(std.testing.io, "examples/ntx-components/guest", .{}) catch return error.SkipZigTest;
    var dir = try Io.Dir.cwd().openDir(io, "examples/ntx-components/guest", .{});
    defer dir.close(io);

    const result = try goListCheck(std.testing.allocator, io, dir);
    defer if (result.err) |e| std.testing.allocator.free(e.message);
    try std.testing.expect(result.ok);
}

test "validateForExtension is a deliberate no-op for an extension with no live-verified check" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Deliberately empty -- no go.mod, nothing "go list"-shaped at all.
    // If this dispatched to a Go-specific check despite ext="rs", it
    // would fail loudly; succeeding proves the no-op path never even
    // inspects the directory.
    const result = try validateForExtension(std.testing.allocator, io, "rs", tmp.dir);
    try std.testing.expect(result.ok);
    try std.testing.expect(result.err == null);
}

test "validateForExtension dispatches 'go' to the real go list check" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    try tmp.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module cleantest\n\ngo 1.23\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.go", .data = "package main\n\nfunc main() {}\n" });

    const result = try validateForExtension(std.testing.allocator, io, "go", tmp.dir);
    defer if (result.err) |e| std.testing.allocator.free(e.message);
    try std.testing.expect(result.ok);
}

// The plan's own verify step for this stage names a specific scenario:
// "a deliberately-authored two-package fixture with a genuine mutual
// component reference." The tests above already prove `goListCheck`
// against a hand-written Go cycle; this one goes further and proves the
// *full pipeline* -- two real `.ntx` files, each `uses`-importing a
// composer from the other's package, actually transpiled through
// `Expose`/`Codegen`, catch a real cycle *created entirely through
// natyv's own Stage 6a component-reuse mechanism*, not a hand-written
// Go cycle unrelated to `.ntx` codegen. Deliberately test-only cross-
// module use of `Expose`/`Codegen` -- `Validate.zig`'s own production
// code needs neither.
const Expose = @import("Expose");
const Codegen = @import("Codegen");
const Resolver = @import("Resolver");

test "a genuine mutual component-reuse cycle, produced through the real .ntx uses+codegen pipeline, is caught by goListCheck" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    // `Codegen.generateGo` allocates many small strings it never frees
    // individually, by design (see its own tests, all arena-backed) --
    // an arena here, not `std.testing.allocator` directly, matches that
    // existing convention. `goListCheck` itself is called with the real
    // leak-checking allocator further down, since its own result *is*
    // meant to be freed by the caller.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module cycletest\n\ngo 1.23\n" });

    // Package "a": exposes CompA, which renders package "b"'s Comp.
    const src_a =
        \\package a
        \\
        \\uses (
        \\  { Comp } from "cycletest/b"
        \\)
        \\
        \\expose CompA
        \\
        \\func CompA(parent uint32) error {
        \\  <Comp/>
        \\}
    ;
    // Package "b": exposes Comp, which renders package "a"'s CompA --
    // the genuine mutual reference.
    const src_b =
        \\package b
        \\
        \\uses (
        \\  { CompA } from "cycletest/a"
        \\)
        \\
        \\expose Comp
        \\
        \\func Comp(parent uint32) error {
        \\  <CompA/>
        \\}
    ;

    var pkg_a = try tmp.dir.createDirPathOpen(io, "a", .{});
    defer pkg_a.close(io);
    const found_a = try Expose.findComposers(allocator, src_a);
    const gen_a = try Codegen.generateGo(allocator, "a", src_a, found_a.composers, &[_]Resolver.ResolvedStyleToken{}, found_a.uses, found_a.uses_start, found_a.uses_end, .{}, false);
    try std.testing.expect(gen_a.err == null);
    try pkg_a.writeFile(io, .{ .sub_path = "a.natyv.go", .data = gen_a.output.?.generated });
    try pkg_a.writeFile(io, .{ .sub_path = "a.go", .data = gen_a.output.?.logic });

    var pkg_b = try tmp.dir.createDirPathOpen(io, "b", .{});
    defer pkg_b.close(io);
    const found_b = try Expose.findComposers(allocator, src_b);
    const gen_b = try Codegen.generateGo(allocator, "b", src_b, found_b.composers, &[_]Resolver.ResolvedStyleToken{}, found_b.uses, found_b.uses_start, found_b.uses_end, .{}, false);
    try std.testing.expect(gen_b.err == null);
    try pkg_b.writeFile(io, .{ .sub_path = "b.natyv.go", .data = gen_b.output.?.generated });
    try pkg_b.writeFile(io, .{ .sub_path = "b.go", .data = gen_b.output.?.logic });

    // Sanity check: the generated calls really are cross-package,
    // proving this cycle comes from real `uses`-based codegen, not
    // hand-authored Go standing in for it.
    try std.testing.expect(std.mem.indexOf(u8, gen_a.output.?.generated, "b.Comp(uint32(parent))") != null);
    try std.testing.expect(std.mem.indexOf(u8, gen_b.output.?.generated, "a.CompA(uint32(parent))") != null);

    const result = try goListCheck(std.testing.allocator, io, tmp.dir);
    defer if (result.err) |e| std.testing.allocator.free(e.message);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "natyv:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "import cycle") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "cycletest/a") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "cycletest/b") != null);
}
