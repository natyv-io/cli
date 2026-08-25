//! `natyv bind`'s real implementation -- Stage 2.1 of
//! ~/.claude/plans/lexical-wishing-penguin.md. For each `conf.natyv.json`
//! `bindings` entry, generates a small, throwaway Zig "reflector" program
//! (comptime function-name array from `entry.functions`, a real
//! `@cInclude` of `entry.header`) and compiles+runs it as a real
//! subprocess to actually produce the trampolines -- the only way to turn
//! a runtime-read config's function list into the comptime-known names
//! `src/bindgen/Reflect.zig`'s `describe` requires (`@field` needs the
//! name known at compile time). Exactly what `src/bindgen/dump_generated.zig`
//! already does for Stage 1's own hardcoded fixture allowlist, generalized
//! to read a real config entry.
//!
//! **The scratch reflector must be written into `<natyv_core_src>/src/bindgen/`
//! itself, not some other temp location** -- confirmed the hard way while
//! first building this: `@import("Reflect.zig")`/`@import("Codegen.zig")`
//! only resolve as plain relative imports from a file that's a real
//! sibling of them on disk (`@import` rejects absolute paths outright,
//! confirmed empirically -- a real Zig source-syntax restriction, not
//! just the module-boundary rule `Codegen.zig`'s own header-emission
//! comment already documents). `zig build-exe`'s own CLI *argument* can
//! be an absolute path just fine (confirmed separately) -- only the
//! *source-level* `@import` call is restricted -- so once the scratch
//! file is sitting in `src/bindgen/`, both the compile step and the
//! reflector's own two output-path argv values are passed as plain
//! absolute strings, sidestepping any further cwd bookkeeping.
//!
//! **The generated Zig trampoline's own real destination is not decided
//! yet** (Stage 2.2's job, see the plan file's own still-open
//! architecture question on per-app natyv-core wiring) -- written here to
//! `<natyv_core_src>/src/bindgen/<library>_bindings_generated.zig` purely
//! so this stage's own verification can real-compile it, same spirit as
//! Stage 1's `src/generated_check.zig`. The Go half's destination *is*
//! real: `guest/<library>_bindings_generated.go`, alongside the guest's
//! own other generated output (`styletokens_generated.go`).

const std = @import("std");
const Io = std.Io;
const Config = @import("Config");

pub const BindError = struct {
    message: []const u8,
};

pub const Outcome = struct {
    /// Number of `bindings` entries successfully processed.
    processed: usize,
    err: ?BindError,
};

fn buildReflectorSource(allocator: std.mem.Allocator, entry: Config.BindingEntry) ![]const u8 {
    var funcs_list: std.ArrayList(u8) = .empty;
    for (entry.functions, 0..) |f, i| {
        if (i > 0) try funcs_list.appendSlice(allocator, ", ");
        try funcs_list.appendSlice(allocator, try std.fmt.allocPrint(allocator, "\"{s}\"", .{f}));
    }

    return std.fmt.allocPrint(allocator,
        \\// Real, throwaway scratch program `natyv bind` generates and
        \\// immediately deletes -- never meant to be read or edited by
        \\// hand. See src/cli/Bind.zig's own doc comment for why this has
        \\// to live here, as a real sibling of Reflect.zig/Codegen.zig.
        \\const std = @import("std");
        \\const Reflect = @import("Reflect.zig");
        \\const Codegen = @import("Codegen.zig");
        \\const c = @cImport({{
        \\    @cInclude("{s}");
        \\}});
        \\
        \\const allowlist = [_][]const u8{{ {s} }};
        \\
        \\pub fn main(init: std.process.Init) !void {{
        \\    const io = init.io;
        \\    const argv = init.minimal.args.vector;
        \\    if (argv.len != 3) {{
        \\        std.debug.print("usage: <scratch-reflector> <zig-out-path> <go-out-path>\n", .{{}});
        \\        return error.BadArgs;
        \\    }}
        \\    const zig_out_path = std.mem.span(argv[1]);
        \\    const go_out_path = std.mem.span(argv[2]);
        \\
        \\    var arena = std.heap.ArenaAllocator.init(init.gpa);
        \\    defer arena.deinit();
        \\    const allocator = arena.allocator();
        \\
        \\    var descs: [allowlist.len]Reflect.FnDescriptor = undefined;
        \\    inline for (allowlist, 0..) |name, i| {{
        \\        descs[i] = try Reflect.describe(c, name);
        \\    }}
        \\    const out = try Codegen.generate(allocator, "{s}", "{s}", &descs);
        \\
        \\    try std.Io.Dir.cwd().writeFile(io, .{{ .sub_path = zig_out_path, .data = out.zig_source }});
        \\    try std.Io.Dir.cwd().writeFile(io, .{{ .sub_path = go_out_path, .data = out.go_source }});
        \\}}
        \\
    , .{ entry.header, funcs_list.items, entry.library, entry.header });
}

fn bindOne(allocator: std.mem.Allocator, io: Io, entry: Config.BindingEntry, bindgen_dir: Io.Dir, bindgen_abs: []const u8, guest_abs: []const u8) !?BindError {
    const scratch_name = try std.fmt.allocPrint(allocator, "_natyv_bind_scratch_{s}.zig", .{entry.library});
    const exe_name = try std.fmt.allocPrint(allocator, "_natyv_bind_scratch_{s}_exe", .{entry.library});
    defer bindgen_dir.deleteFile(io, scratch_name) catch {};
    defer bindgen_dir.deleteFile(io, exe_name) catch {};

    const reflector_src = try buildReflectorSource(allocator, entry);
    try bindgen_dir.writeFile(io, .{ .sub_path = scratch_name, .data = reflector_src });

    var compile_argv: std.ArrayList([]const u8) = .empty;
    try compile_argv.appendSlice(allocator, &.{ "zig", "build-exe", scratch_name, try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{exe_name}) });
    for (entry.include_dirs) |dir| {
        try compile_argv.append(allocator, "-I");
        try compile_argv.append(allocator, dir);
    }

    const compile_result = std.process.run(allocator, io, .{
        .argv = compile_argv.items,
        .cwd = .{ .dir = bindgen_dir },
    }) catch |e| {
        return .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: could not run 'zig build-exe' for '{s}': {s}", .{ entry.library, @errorName(e) }) };
    };
    defer allocator.free(compile_result.stdout);
    switch (compile_result.term) {
        .exited => |code| {
            if (code != 0) {
                defer allocator.free(compile_result.stderr);
                return .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: '{s}' failed to compile against '{s}' (exit code {d}):\n{s}{s}", .{ entry.library, entry.header, code, compile_result.stdout, compile_result.stderr }) };
            }
            allocator.free(compile_result.stderr);
        },
        else => |term| {
            defer allocator.free(compile_result.stderr);
            return .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: '{s}' compile exited abnormally ({any}):\n{s}{s}", .{ entry.library, term, compile_result.stdout, compile_result.stderr }) };
        },
    }

    const zig_out_name = try std.fmt.allocPrint(allocator, "{s}_bindings_generated.zig", .{entry.library});
    const zig_out_abs = try std.fs.path.join(allocator, &.{ bindgen_abs, zig_out_name });
    const go_out_name = try std.fmt.allocPrint(allocator, "{s}_bindings_generated.go", .{entry.library});
    const go_out_abs = try std.fs.path.join(allocator, &.{ guest_abs, go_out_name });
    const exe_abs = try std.fs.path.join(allocator, &.{ bindgen_abs, exe_name });

    const run_result = std.process.run(allocator, io, .{
        .argv = &.{ exe_abs, zig_out_abs, go_out_abs },
    }) catch |e| {
        return .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: could not run the compiled reflector for '{s}': {s}", .{ entry.library, @errorName(e) }) };
    };
    defer allocator.free(run_result.stdout);
    switch (run_result.term) {
        .exited => |code| {
            if (code != 0) {
                defer allocator.free(run_result.stderr);
                return .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: '{s}' reflector failed (exit code {d}):\n{s}{s}", .{ entry.library, code, run_result.stdout, run_result.stderr }) };
            }
            allocator.free(run_result.stderr);
        },
        else => |term| {
            defer allocator.free(run_result.stderr);
            return .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: '{s}' reflector exited abnormally ({any}):\n{s}{s}", .{ entry.library, term, run_result.stdout, run_result.stderr }) };
        },
    }

    return null;
}

/// `natyv_core_src` locates `src/bindgen/` the same way `Bundle.zig`
/// already resolves natyv-core's own source tree (a plain parameter, not
/// read from an env var here, for the same testability reason). `guest_dir`
/// is the app's own guest source directory, where the real Go output
/// lands.
pub fn run(allocator: std.mem.Allocator, io: Io, bindings: []const Config.BindingEntry, natyv_core_src: []const u8, guest_dir: Io.Dir) !Outcome {
    if (bindings.len == 0) return .{ .processed = 0, .err = null };

    var core_dir = std.Io.Dir.cwd().openDir(io, natyv_core_src, .{}) catch |e| {
        return .{ .processed = 0, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: could not open NATYV_CORE_SRC ('{s}'): {s}", .{ natyv_core_src, @errorName(e) }) } };
    };
    defer core_dir.close(io);

    var bindgen_dir = core_dir.openDir(io, "src/bindgen", .{}) catch |e| {
        return .{ .processed = 0, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: could not open '{s}/src/bindgen': {s}", .{ natyv_core_src, @errorName(e) }) } };
    };
    defer bindgen_dir.close(io);

    var buf1: [std.fs.max_path_bytes]u8 = undefined;
    const bindgen_abs_len = try bindgen_dir.realPath(io, &buf1);
    const bindgen_abs = try allocator.dupe(u8, buf1[0..bindgen_abs_len]);

    var buf2: [std.fs.max_path_bytes]u8 = undefined;
    const guest_abs_len = try guest_dir.realPath(io, &buf2);
    const guest_abs = try allocator.dupe(u8, buf2[0..guest_abs_len]);

    var processed: usize = 0;
    for (bindings) |entry| {
        if (try bindOne(allocator, io, entry, bindgen_dir, bindgen_abs, guest_abs)) |e| {
            return .{ .processed = processed, .err = e };
        }
        processed += 1;
    }

    return .{ .processed = processed, .err = null };
}

test "binds the real fixture against a real config entry, producing correct Go output in the guest dir" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var guest_dir = try tmp.dir.createDirPathOpen(io, "guest", .{});
    defer guest_dir.close(io);

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const fixture_include_dir = try std.fs.path.join(allocator, &.{ cwd_path, "fixtures/bindgen" });

    const bindings = [_]Config.BindingEntry{.{
        .library = "fixture",
        .header = "fixture.h",
        .include_dirs = &.{fixture_include_dir},
        .functions = &.{ "fixture_create", "fixture_destroy" },
    }};

    const outcome = try run(allocator, io, &bindings, cwd_path, guest_dir);
    try std.testing.expect(outcome.err == null);
    try std.testing.expectEqual(@as(usize, 1), outcome.processed);

    const go_out = try guest_dir.readFileAlloc(io, "fixture_bindings_generated.go", allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, go_out, "package fixture") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_out, "func FixtureCreate(") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_out, "func FixtureDestroy(") != null);

    // The scratch reflector's own compile step above already really
    // compiled and ran `Reflect.describe`/`Codegen.generate` (not a
    // mock) -- Stage 1's own `GeneratedFixtureCheck.zig` already proves
    // output shaped like this compiles for real against `c.zig`/
    // `host_fn_util.zig`, so this test only checks the emitted Zig text
    // directly. The Zig half lands in src/bindgen/ itself (this stage's
    // own scratch/verification location, see this file's doc comment);
    // clean it up so it doesn't linger as a stray real file.
    var bindgen_dir = try std.Io.Dir.cwd().openDir(io, "src/bindgen", .{});
    defer bindgen_dir.close(io);
    defer bindgen_dir.deleteFile(io, "fixture_bindings_generated.zig") catch {};
    const zig_out = try bindgen_dir.readFileAlloc(io, "fixture_bindings_generated.zig", allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, zig_out, "pub fn fixtureCreateHostFn") != null);
}

test "an empty bindings list is a real no-op, no error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    const outcome = try run(std.testing.allocator, io, &.{}, "/nonexistent", tmp.dir);
    try std.testing.expect(outcome.err == null);
    try std.testing.expectEqual(@as(usize, 0), outcome.processed);
}

test "a bad NATYV_CORE_SRC is a clear, natyv-attributed error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const bindings = [_]Config.BindingEntry{.{ .library = "x", .header = "x.h", .functions = &.{"x"} }};
    const outcome = try run(allocator, io, &bindings, "/definitely/not/a/real/path", tmp.dir);
    defer if (outcome.err) |e| allocator.free(e.message);
    try std.testing.expect(outcome.err != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "natyv bind:") != null);
}

test "a real compile failure (unknown function name) surfaces a clear, real, natyv-attributed error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var guest_dir = try tmp.dir.createDirPathOpen(io, "guest", .{});
    defer guest_dir.close(io);

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const fixture_include_dir = try std.fs.path.join(allocator, &.{ cwd_path, "fixtures/bindgen" });

    const bindings = [_]Config.BindingEntry{.{
        .library = "fixture",
        .header = "fixture.h",
        .include_dirs = &.{fixture_include_dir},
        .functions = &.{"this_function_does_not_exist"},
    }};

    const outcome = try run(allocator, io, &bindings, cwd_path, guest_dir);
    try std.testing.expect(outcome.err != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "natyv bind:") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "fixture") != null);
}
