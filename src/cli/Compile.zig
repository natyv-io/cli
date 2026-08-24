//! `natyv build`'s first real sub-step (`.ntx` tooling Stage 7 continued,
//! ~/.claude/plans/lexical-wishing-penguin.md): spawns the dev's own
//! configured `wasm_compile` command from `conf.natyv.json`. natyv never
//! shells out to N different guest-language compilers itself (see
//! CLAUDE.md's CLI build flow section) -- it only spawns whatever command
//! the dev already uses (e.g. `tinygo build -target wasip1
//! -buildmode=c-shared -o app.wasm .`).
//!
//! Invoked through the platform's own shell (`/bin/sh -c <command>`)
//! rather than a hand-rolled argv splitter: `wasm_compile` is one
//! free-form string from JSON config, and real commands rely on real
//! shell quoting/escaping (paths with spaces, etc.) that natyv would
//! otherwise have to reimplement -- exactly the kind of natyv-invented
//! shell convention CLAUDE.md already rejected for multi-step chaining,
//! at higher risk here for a single step too. Second real
//! `std.process.run` use in this repo (first: `src/ntx/Validate.zig`'s
//! `goListCheck` -- spawn + pipe stdout/stderr + wait in one call).

const std = @import("std");
const Io = std.Io;

pub const CompileError = struct {
    message: []const u8,
};

pub const Result = struct {
    ok: bool,
    err: ?CompileError,
};

/// Runs `command` via `/bin/sh -c` inside `guest_dir` -- every real
/// example's own `wasm_compile` value (e.g. `... -o app.wasm .`) assumes
/// the guest source directory as cwd. Real stdout/stderr are surfaced
/// verbatim on failure -- CLAUDE.md's own hard rule -- prefixed with one
/// natyv-attributed line, same convention `Validate.zig`'s `goListCheck`
/// already established.
pub fn run(allocator: std.mem.Allocator, io: Io, command: []const u8, guest_dir: Io.Dir) !Result {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", command },
        .cwd = .{ .dir = guest_dir },
    }) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: could not run wasm_compile ('{s}'): {s}", .{ command, @errorName(e) }),
        } };
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
                .message = try std.fmt.allocPrint(allocator, "natyv build: wasm_compile ('{s}') failed (exit code {d}):\n{s}{s}", .{ command, code, result.stdout, result.stderr }),
            } };
        },
        else => |term| {
            defer allocator.free(result.stderr);
            return .{ .ok = false, .err = .{
                .message = try std.fmt.allocPrint(allocator, "natyv build: wasm_compile ('{s}') exited abnormally ({any}):\n{s}{s}", .{ command, term, result.stdout, result.stderr }),
            } };
        },
    }
}

test "a successful compile command reports ok with no error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const result = try run(std.testing.allocator, io, "exit 0", tmp.dir);
    defer if (result.err) |e| std.testing.allocator.free(e.message);
    try std.testing.expect(result.ok);
    try std.testing.expect(result.err == null);
}

test "a failing compile command surfaces its real stderr verbatim, natyv-attributed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const result = try run(std.testing.allocator, io, "echo 'fake compiler error: undefined symbol' >&2; exit 1", tmp.dir);
    defer if (result.err) |e| std.testing.allocator.free(e.message);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "natyv build:") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "exit code 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "fake compiler error: undefined symbol") != null);
}

test "runs in the given guest directory, not the process's own cwd" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    const result = try run(std.testing.allocator, io, "pwd > pwd.txt", tmp.dir);
    defer if (result.err) |e| std.testing.allocator.free(e.message);
    try std.testing.expect(result.ok);

    const contents = try tmp.dir.readFileAlloc(io, "pwd.txt", std.testing.allocator, .unlimited);
    defer std.testing.allocator.free(contents);
    // `pwd`'s own output ends in a real trailing newline -- trimming is
    // the correct comparison, not an approximation.
    try std.testing.expect(std.mem.trimEnd(u8, contents, "\n").len > 0);
}

test "real stdout is also captured, not swallowed, on failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;

    const result = try run(std.testing.allocator, io, "echo 'compiling...'; exit 1", tmp.dir);
    defer if (result.err) |e| std.testing.allocator.free(e.message);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "compiling...") != null);
}
