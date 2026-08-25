//! Stage 2.8 of ~/.claude/plans/lexical-wishing-penguin.md -- `natyv
//! bind`'s pre-flight `zig translate-c` diagnostic pass. Referencing an
//! untranslatable C decl (an unsupported macro, a plain constant, a
//! macro-derived generic function) via `@field` inside the scratch
//! reflector `Bind.zig` generates is either a hard, uncatchable
//! `@compileError` buried deep inside an anonymous generated
//! `cimport.zig` (for a macro translate-c genuinely can't turn into an
//! expression at all -- token-pasting, stringification, a non-expression
//! body), or a real but generic natyv-attributed reflector-runtime error
//! (`Reflect.describe`'s own `error.GenericFunction` check, for a macro
//! that *does* translate but only into a generic function). Neither names
//! the actual problem as clearly as running `zig translate-c` directly
//! and inspecting what shape each requested name actually took -- this
//! file does exactly that, *before* the real reflector compile ever
//! runs, so a dev sees one clean, natyv-attributed diagnostic per bad
//! name instead of a raw compiler dump or a bare error code. Confirmed
//! cheap to run unconditionally (a real spike against this machine's
//! toolchain: ~0.2s warm) -- not gated behind a prior failure.
//!
//! **Real dividing line, confirmed empirically against this machine's
//! real Zig 0.16.0 (Aro-based translate-c), not assumed**: a real C
//! function (declared-only or defined-with-a-body) always translates to
//! `pub extern fn <name>(` or `pub fn <name>(`; a function-like macro
//! that successfully translates always becomes a *generic* `pub inline
//! fn <name>(...anytype...)` -- confirmed a real `static inline` C
//! function never gets emitted this way, via a real spike comparing one
//! directly against a macro; a plain object-like macro or a real
//! `#define`d constant becomes `pub const <name> = <value>;`; a macro
//! translate-c genuinely can't handle becomes `pub const <name> =
//! @compileError("...");` -- the exact same declaration shape as a real,
//! successfully-translated constant, distinguished only by the
//! `@compileError` call itself (which also carries the real, specific
//! reason as its own message, surfaced here rather than re-derived).
const std = @import("std");
const Io = std.Io;

pub const CheckError = struct {
    message: []const u8,
};

pub const CheckOutcome = struct {
    ok: bool,
    err: ?CheckError = null,
};

/// Pulls the human-readable reason out of a `@compileError("...")` call
/// translate-c itself already generated -- reusing its own real message
/// rather than trying to re-derive "why" from scratch.
fn extractCompileErrorMessage(decl_line: []const u8) []const u8 {
    const needle = "@compileError(\"";
    const start = std.mem.indexOf(u8, decl_line, needle) orelse return "translate-c could not translate this declaration";
    const msg_start = start + needle.len;
    const msg_end = std.mem.indexOfScalarPos(u8, decl_line, msg_start, '"') orelse decl_line.len;
    return decl_line[msg_start..msg_end];
}

/// Classifies what shape `name` took in `translated` (the real stdout of
/// `zig translate-c`) -- see this file's own doc comment for the real,
/// confirmed dividing lines. Returns `null` when `name` is bindable as-is
/// (a real function decl); otherwise a clear, dev-facing explanation of
/// why it isn't. Matches on the exact literal declaration prefix
/// (`"pub extern fn <name>("`, etc.) rather than a general identifier
/// search, so a name that's merely a *substring* of some other real
/// declaration (or appears only as a parameter name) can't false-match.
fn diagnose(allocator: std.mem.Allocator, translated: []const u8, name: []const u8) !?[]const u8 {
    // Stack-buffered needles, not `allocPrint` -- these are pure search
    // keys with no need to outlive this function, and `diagnose` is
    // called once per requested function name (small, bounded), so a
    // fixed 512-byte buffer per needle is more than enough for any real
    // C identifier without needing an explicit free (this file's own
    // `check` caller always uses an arena in production, but its own
    // direct unit tests use `std.testing.allocator`, which would
    // otherwise flag every one of these as a real leak).
    var needle_buf: [512]u8 = undefined;

    const extern_needle = try std.fmt.bufPrint(&needle_buf, "pub extern fn {s}(", .{name});
    if (std.mem.indexOf(u8, translated, extern_needle) != null) return null;

    const fn_needle = try std.fmt.bufPrint(&needle_buf, "pub fn {s}(", .{name});
    if (std.mem.indexOf(u8, translated, fn_needle) != null) return null;

    const inline_needle = try std.fmt.bufPrint(&needle_buf, "pub inline fn {s}(", .{name});
    if (std.mem.indexOf(u8, translated, inline_needle) != null) {
        return try std.fmt.allocPrint(allocator, "'{s}' is a function-like macro, and translate-c only turns those into a generic function (no concrete parameter types until it's actually called) -- natyv doesn't support binding these; declare a small real C wrapper function around it instead", .{name});
    }

    const const_needle = try std.fmt.bufPrint(&needle_buf, "pub const {s} = ", .{name});
    if (std.mem.indexOf(u8, translated, const_needle)) |idx| {
        const line_end = std.mem.indexOfScalarPos(u8, translated, idx, '\n') orelse translated.len;
        const decl_line = translated[idx..line_end];
        if (std.mem.indexOf(u8, decl_line, "@compileError(") != null) {
            return try std.fmt.allocPrint(allocator, "'{s}' could not be translated by zig translate-c ({s}) -- if it's a macro, declare a small real C wrapper function around it instead", .{ name, extractCompileErrorMessage(decl_line) });
        }
        return try std.fmt.allocPrint(allocator, "'{s}' is a constant, not a function -- natyv only binds functions", .{name});
    }

    return try std.fmt.allocPrint(allocator, "'{s}' was not found in the header at all -- check the name matches the C declaration exactly", .{name});
}

/// Runs a real `zig translate-c` against a synthetic `#include "<header>"`
/// scratch file (mirrors exactly how the real reflector's own `@cInclude`
/// resolves a header via `-I`, so a header-not-found failure surfaces
/// here identically to how it'd surface at the real reflector compile)
/// and diagnoses every name in `functions`, returning one combined,
/// natyv-attributed error listing every problem found -- not just the
/// first -- so a dev fixing several bad names doesn't have to re-run
/// `natyv bind` once per name. `scratch_name` is the caller's
/// responsibility (mirrors every other real-subprocess scratch file in
/// this arc -- PID-suffixed by `Bind.zig`'s own caller, see its own doc
/// comment on why).
///
/// **Deliberately shells out via `/bin/sh -c "... > outfile 2> errfile"`
/// and reads the files back, rather than passing `zig translate-c`
/// directly as `argv` to `std.process.run` and reading its returned
/// `stdout`/`stderr`.** Found the hard way: a real, reproducible hang in
/// this exact Zig 0.16.0 `std.process.run` (confirmed via a from-scratch
/// 15-line repro program, nothing to do with this file's own logic) --
/// the child process spins at ~99% CPU indefinitely once its real stdout
/// volume gets into the tens of KB, which a real header's translated
/// output routinely does (unlike every other real subprocess call in
/// this codebase, whose successful stdout is empty/tiny -- this is the
/// first one in the whole arc where a *successful* run's own output is
/// this large, which is presumably why nothing else has hit it). Routing
/// the child's own stdout/stderr to real files via shell redirection
/// sidesteps `std.process.run`'s live in-memory pipe-draining path
/// entirely -- confirmed the exact same command completes in ~1s this
/// way, vs. hanging indefinitely the direct-argv way. Worth remembering
/// for any *future* subprocess call in this codebase whose expected
/// successful output could also be large -- this same workaround, not
/// `std.process.run`'s direct-argv form.
pub fn check(allocator: std.mem.Allocator, io: Io, scratch_dir: Io.Dir, header: []const u8, include_dirs: []const []const u8, functions: []const []const u8, scratch_name: []const u8) !CheckOutcome {
    const synth_src = try std.fmt.allocPrint(allocator, "#include \"{s}\"\n", .{header});
    try scratch_dir.writeFile(io, .{ .sub_path = scratch_name, .data = synth_src });
    defer scratch_dir.deleteFile(io, scratch_name) catch {};

    const out_name = try std.fmt.allocPrint(allocator, "{s}.out", .{scratch_name});
    const err_name = try std.fmt.allocPrint(allocator, "{s}.err", .{scratch_name});
    defer scratch_dir.deleteFile(io, out_name) catch {};
    defer scratch_dir.deleteFile(io, err_name) catch {};

    var cmd: std.ArrayList(u8) = .empty;
    try cmd.appendSlice(allocator, "zig translate-c ");
    try cmd.appendSlice(allocator, scratch_name);
    for (include_dirs) |dir| {
        try cmd.appendSlice(allocator, " -I '");
        try cmd.appendSlice(allocator, dir);
        try cmd.appendSlice(allocator, "'");
    }
    try cmd.appendSlice(allocator, " > ");
    try cmd.appendSlice(allocator, out_name);
    try cmd.appendSlice(allocator, " 2> ");
    try cmd.appendSlice(allocator, err_name);

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "/bin/sh", "-c", cmd.items },
        .cwd = .{ .dir = scratch_dir },
    }) catch |e| {
        return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: could not run 'zig translate-c' against '{s}': {s}", .{ header, @errorName(e) }) } };
    };
    allocator.free(result.stdout);
    allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                const stderr_text = scratch_dir.readFileAlloc(io, err_name, allocator, .unlimited) catch "";
                return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: 'zig translate-c' failed against '{s}' (exit code {d}):\n{s}", .{ header, code, stderr_text }) } };
            }
        },
        else => |term| {
            const stderr_text = scratch_dir.readFileAlloc(io, err_name, allocator, .unlimited) catch "";
            return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: 'zig translate-c' exited abnormally against '{s}' ({any}):\n{s}", .{ header, term, stderr_text }) } };
        },
    }

    const translated = scratch_dir.readFileAlloc(io, out_name, allocator, .unlimited) catch |e| {
        return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: 'zig translate-c' produced no output for '{s}': {s}", .{ header, @errorName(e) }) } };
    };

    var problems: std.ArrayList(u8) = .empty;
    var bad_count: usize = 0;
    for (functions) |name| {
        if (try diagnose(allocator, translated, name)) |problem| {
            try problems.appendSlice(allocator, "  - ");
            try problems.appendSlice(allocator, problem);
            try problems.append(allocator, '\n');
            bad_count += 1;
        }
    }
    if (bad_count == 0) return .{ .ok = true };
    return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: can't bind against '{s}':\n{s}", .{ header, problems.items }) } };
}

test "diagnose: a real extern fn decl is bindable" {
    const allocator = std.testing.allocator;
    const translated = "pub extern fn fixture_create(initial: c_int) ?*FixtureHandle;\n";
    const result = try diagnose(allocator, translated, "fixture_create");
    defer if (result) |r| allocator.free(r);
    try std.testing.expect(result == null);
}

test "diagnose: a real fn-with-body decl (static inline) is bindable" {
    const allocator = std.testing.allocator;
    const translated = "pub fn real_inline_add(arg_a: c_int, arg_b: c_int) callconv(.c) c_int {\n    return arg_a + arg_b;\n}\n";
    const result = try diagnose(allocator, translated, "real_inline_add");
    defer if (result) |r| allocator.free(r);
    try std.testing.expect(result == null);
}

test "diagnose: a macro-derived generic function is rejected with a clear reason" {
    const allocator = std.testing.allocator;
    const translated = "pub inline fn FIXTURE_DOUBLE(x: anytype) @TypeOf(x * @as(c_int, 2)) {\n    return x * @as(c_int, 2);\n}\n";
    const result = try diagnose(allocator, translated, "FIXTURE_DOUBLE");
    defer if (result) |r| allocator.free(r);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "generic function") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "FIXTURE_DOUBLE") != null);
}

test "diagnose: a plain constant is rejected as not-a-function" {
    const allocator = std.testing.allocator;
    const translated = "pub const FIXTURE_VERSION = @as(c_int, 1);\n";
    const result = try diagnose(allocator, translated, "FIXTURE_VERSION");
    defer if (result) |r| allocator.free(r);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "constant, not a function") != null);
}

test "diagnose: an untranslatable macro surfaces translate-c's own real reason" {
    const allocator = std.testing.allocator;
    const translated = "pub const PASTE = @compileError(\"unable to translate C expr: unexpected token '##'\"); // spike.h:4:9\n";
    const result = try diagnose(allocator, translated, "PASTE");
    defer if (result) |r| allocator.free(r);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "unexpected token '##'") != null);
}

test "diagnose: a name absent entirely is reported as not found" {
    const allocator = std.testing.allocator;
    const translated = "pub extern fn something_else(x: c_int) c_int;\n";
    const result = try diagnose(allocator, translated, "not_a_real_name");
    defer if (result) |r| allocator.free(r);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "not found") != null);
}

test "diagnose: a name that's only a substring of a real decl doesn't false-match" {
    const allocator = std.testing.allocator;
    const translated = "pub extern fn fixture_pingx(x: c_int) c_int;\n";
    const result = try diagnose(allocator, translated, "fixture_ping");
    defer if (result) |r| allocator.free(r);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "not found") != null);
}

test "check: real, live pass -- every requested fixture function is bindable" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const fixture_include_dir = try std.fs.path.join(allocator, &.{ cwd_path, "fixtures/bindgen" });

    const outcome = try check(allocator, io, tmp.dir, "fixture.h", &.{fixture_include_dir}, &.{ "fixture_create", "fixture_ping" }, "_natyv_tc_check_test_pass.c");
    if (outcome.err) |e| std.debug.print("unexpected failure: {s}\n", .{e.message});
    try std.testing.expect(outcome.ok);
}

test "check: real, live failure -- combines every bad name into one message" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const fixture_include_dir = try std.fs.path.join(allocator, &.{ cwd_path, "fixtures/bindgen" });

    const outcome = try check(allocator, io, tmp.dir, "fixture.h", &.{fixture_include_dir}, &.{ "fixture_create", "FIXTURE_DOUBLE", "FIXTURE_VERSION", "not_a_real_name" }, "_natyv_tc_check_test_fail.c");
    try std.testing.expect(!outcome.ok);
    const msg = outcome.err.?.message;
    try std.testing.expect(std.mem.indexOf(u8, msg, "fixture_create") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "FIXTURE_DOUBLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "FIXTURE_VERSION") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "not_a_real_name") != null);
}
