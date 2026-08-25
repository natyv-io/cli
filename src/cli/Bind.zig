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
    /// Every `entry.include_dirs`/`entry.link` value across all processed
    /// entries, concatenated (not deduped -- harmless duplicate `-I`/`-l`
    /// flags cost nothing) -- `cli/main.zig` joins these into the
    /// `-Dbinding-include-dirs`/`-Dbinding-link` values `Bundle.zig` passes
    /// to natyv-core's own `zig build`, since `src/BindingsGenerated.zig`'s
    /// per-entry `@cInclude`s and the real library symbols they call need
    /// the exact same include paths/linker flags the reflector's own
    /// scratch compile already used.
    include_dirs: []const []const u8 = &.{},
    link: []const []const u8 = &.{},
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
        \\    if (argv.len != 4) {{
        \\        std.debug.print("usage: <scratch-reflector> <zig-out-path> <go-out-path> <meta-out-path>\n", .{{}});
        \\        return error.BadArgs;
        \\    }}
        \\    const zig_out_path = std.mem.span(argv[1]);
        \\    const go_out_path = std.mem.span(argv[2]);
        \\    const meta_out_path = std.mem.span(argv[3]);
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
        \\
        \\    // Simple "extism_name|zig_fn_name" lines -- read back by the
        \\    // real `natyv bind` process to build the aggregator registrar
        \\    // (`BindingsGenerated.zig`), since the reflector runs as a
        \\    // separate subprocess and can't hand structured data back any
        \\    // other way.
        \\    var meta: std.ArrayList(u8) = .empty;
        \\    for (out.host_functions) |hf| {{
        \\        try meta.appendSlice(allocator, hf.extism_name);
        \\        try meta.append(allocator, '|');
        \\        try meta.appendSlice(allocator, hf.zig_fn_name);
        \\        try meta.append(allocator, '\n');
        \\    }}
        \\    try std.Io.Dir.cwd().writeFile(io, .{{ .sub_path = meta_out_path, .data = meta.items }});
        \\}}
        \\
    , .{ entry.header, funcs_list.items, entry.library, entry.header });
}

/// Plain local mirror of `src/bindgen/Codegen.zig`'s own
/// `HostFunctionInfo` -- deliberately not a cross-module import of that
/// type (would need a whole new named "Codegen" build.zig module just
/// for one small struct shape); this file only ever reads the meta lines
/// the scratch reflector wrote, it never touches `Codegen.zig` directly.
const HostFunctionInfo = struct {
    extism_name: []const u8,
    zig_fn_name: []const u8,
};

const GeneratedEntry = struct {
    library: []const u8,
    host_functions: []const HostFunctionInfo,
};

const BindOneResult = union(enum) {
    ok: GeneratedEntry,
    err: BindError,
};

fn parseMeta(allocator: std.mem.Allocator, library: []const u8, meta_text: []const u8) !GeneratedEntry {
    var host_functions: std.ArrayList(HostFunctionInfo) = .empty;
    var lines = std.mem.splitScalar(u8, meta_text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const sep = std.mem.indexOfScalar(u8, line, '|') orelse continue;
        try host_functions.append(allocator, .{
            .extism_name = try allocator.dupe(u8, line[0..sep]),
            .zig_fn_name = try allocator.dupe(u8, line[sep + 1 ..]),
        });
    }
    return .{ .library = library, .host_functions = try host_functions.toOwnedSlice(allocator) };
}

fn bindOne(allocator: std.mem.Allocator, io: Io, entry: Config.BindingEntry, bindgen_dir: Io.Dir, bindgen_abs: []const u8, guest_abs: []const u8) !BindOneResult {
    const scratch_name = try std.fmt.allocPrint(allocator, "_natyv_bind_scratch_{s}.zig", .{entry.library});
    const exe_name = try std.fmt.allocPrint(allocator, "_natyv_bind_scratch_{s}_exe", .{entry.library});
    const meta_name = try std.fmt.allocPrint(allocator, "_natyv_bind_scratch_{s}.meta", .{entry.library});
    defer bindgen_dir.deleteFile(io, scratch_name) catch {};
    defer bindgen_dir.deleteFile(io, exe_name) catch {};
    defer bindgen_dir.deleteFile(io, meta_name) catch {};

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
        return .{ .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: could not run 'zig build-exe' for '{s}': {s}", .{ entry.library, @errorName(e) }) } };
    };
    defer allocator.free(compile_result.stdout);
    switch (compile_result.term) {
        .exited => |code| {
            if (code != 0) {
                defer allocator.free(compile_result.stderr);
                return .{ .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: '{s}' failed to compile against '{s}' (exit code {d}):\n{s}{s}", .{ entry.library, entry.header, code, compile_result.stdout, compile_result.stderr }) } };
            }
            allocator.free(compile_result.stderr);
        },
        else => |term| {
            defer allocator.free(compile_result.stderr);
            return .{ .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: '{s}' compile exited abnormally ({any}):\n{s}{s}", .{ entry.library, term, compile_result.stdout, compile_result.stderr }) } };
        },
    }

    const zig_out_name = try std.fmt.allocPrint(allocator, "{s}_bindings_generated.zig", .{entry.library});
    const zig_out_abs = try std.fs.path.join(allocator, &.{ bindgen_abs, zig_out_name });
    const go_out_name = try std.fmt.allocPrint(allocator, "{s}_bindings_generated.go", .{entry.library});
    const go_out_abs = try std.fs.path.join(allocator, &.{ guest_abs, go_out_name });
    const meta_abs = try std.fs.path.join(allocator, &.{ bindgen_abs, meta_name });
    const exe_abs = try std.fs.path.join(allocator, &.{ bindgen_abs, exe_name });

    const run_result = std.process.run(allocator, io, .{
        .argv = &.{ exe_abs, zig_out_abs, go_out_abs, meta_abs },
    }) catch |e| {
        return .{ .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: could not run the compiled reflector for '{s}': {s}", .{ entry.library, @errorName(e) }) } };
    };
    defer allocator.free(run_result.stdout);
    switch (run_result.term) {
        .exited => |code| {
            if (code != 0) {
                defer allocator.free(run_result.stderr);
                return .{ .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: '{s}' reflector failed (exit code {d}):\n{s}{s}", .{ entry.library, code, run_result.stdout, run_result.stderr }) } };
            }
            allocator.free(run_result.stderr);
        },
        else => |term| {
            defer allocator.free(run_result.stderr);
            return .{ .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: '{s}' reflector exited abnormally ({any}):\n{s}{s}", .{ entry.library, term, run_result.stdout, run_result.stderr }) } };
        },
    }

    const meta_text = bindgen_dir.readFileAlloc(io, meta_name, allocator, .unlimited) catch |e| {
        return .{ .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: '{s}' reflector didn't produce its metadata file: {s}", .{ entry.library, @errorName(e) }) } };
    };
    return .{ .ok = try parseMeta(allocator, entry.library, meta_text) };
}

/// The aggregator `Runtime.zig` actually links against via the
/// `-Dhas-bindings`-swapped `Bindings` named import (see build.zig) --
/// imports each entry's own `<library>_bindings_generated.zig` by real
/// relative filename (a downward subdirectory import from `src/`, always
/// fine -- only `../`-escaping upward is restricted, confirmed in Stage
/// 2.1) and combines every one of their host functions into one
/// `registerInto`, matching `WidgetHost.registerInto`'s own exact
/// `extism_function_new` call shape. `user_data`/the free-function arg
/// are always `null` -- unlike WidgetHost/Sqlite, a generated binding
/// closes over its own module-level handle table directly, it never
/// needs a capability-instance pointer threaded through.
fn writeAggregator(allocator: std.mem.Allocator, io: Io, core_dir: Io.Dir, generated: []const GeneratedEntry) !void {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator,
        \\// Code generated by natyv bind. DO NOT EDIT.
        \\const c = @import("bindgen/BindingsC.zig").c;
        \\
    );
    for (generated) |g| {
        try out.appendSlice(allocator, try std.fmt.allocPrint(allocator, "const {s}_bindings = @import(\"bindgen/{s}_bindings_generated.zig\");\n", .{ g.library, g.library }));
    }

    var total: usize = 0;
    for (generated) |g| total += g.host_functions.len;
    try out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
        \\
        \\pub const host_function_count = {d};
        \\
        \\pub fn registerInto(funcs_out: []?*anyopaque) usize {{
        \\    const in_types = [_]c.ExtismValType{{c.ExtismValType_I64}};
        \\    const out_types = [_]c.ExtismValType{{c.ExtismValType_I64}};
        \\    var n: usize = 0;
        \\
    , .{total}));
    for (generated) |g| {
        for (g.host_functions) |hf| {
            try out.appendSlice(allocator, try std.fmt.allocPrint(allocator,
                \\    funcs_out[n] = @ptrCast(c.extism_function_new("{s}", &in_types[0], 1, &out_types[0], 1, {s}_bindings.{s}, null, null));
                \\    n += 1;
                \\
            , .{ hf.extism_name, g.library, hf.zig_fn_name }));
        }
    }
    try out.appendSlice(allocator, "    return n;\n}\n");

    try core_dir.writeFile(io, .{ .sub_path = "src/BindingsGenerated.zig", .data = out.items });
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

    var generated: std.ArrayList(GeneratedEntry) = .empty;
    var include_dirs: std.ArrayList([]const u8) = .empty;
    var link: std.ArrayList([]const u8) = .empty;
    var processed: usize = 0;
    for (bindings) |entry| {
        const result = try bindOne(allocator, io, entry, bindgen_dir, bindgen_abs, guest_abs);
        switch (result) {
            .err => |e| return .{ .processed = processed, .err = e },
            .ok => |ge| try generated.append(allocator, ge),
        }
        try include_dirs.appendSlice(allocator, entry.include_dirs);
        try link.appendSlice(allocator, entry.link);
        processed += 1;
    }

    try writeAggregator(allocator, io, core_dir, generated.items);

    return .{ .processed = processed, .include_dirs = include_dirs.items, .link = link.items, .err = null };
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
        // `fixture_ping` (zero parameters) proves the config-driven
        // pipeline handles the same real shape Stage 2.2's own zlib
        // end-to-end proof needed (`zlibCompileFlags(void)`) -- a
        // zero-arg bound function.
        .functions = &.{ "fixture_create", "fixture_destroy", "fixture_ping" },
    }};

    const outcome = try run(allocator, io, &bindings, cwd_path, guest_dir);
    try std.testing.expect(outcome.err == null);
    try std.testing.expectEqual(@as(usize, 1), outcome.processed);

    const go_out = try guest_dir.readFileAlloc(io, "fixture_bindings_generated.go", allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, go_out, "package main") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_out, "func FixtureCreate(") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_out, "func FixtureDestroy(") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_out, "func FixturePing(") != null);

    // The scratch reflector's own compile step above already really
    // compiled and ran `Reflect.describe`/`Codegen.generate` (not a
    // mock) -- `build.zig`'s own `bindgen_generated_check` test already
    // proves output shaped like this compiles for real against
    // `BindingsC.zig`/`BindingsHostFnUtil.zig`, so this test only checks
    // the emitted Zig text directly. The Zig half lands in src/bindgen/
    // itself (this stage's own real, final destination, see this file's
    // doc comment); clean it up so it doesn't linger as a stray real file.
    var bindgen_dir = try std.Io.Dir.cwd().openDir(io, "src/bindgen", .{});
    defer bindgen_dir.close(io);
    defer bindgen_dir.deleteFile(io, "fixture_bindings_generated.zig") catch {};
    const zig_out = try bindgen_dir.readFileAlloc(io, "fixture_bindings_generated.zig", allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, zig_out, "pub fn fixtureCreateHostFn") != null);

    // The real aggregator `Runtime.zig` links against -- same "real file,
    // cleaned up by the test" treatment as the per-library output above.
    var src_dir = try std.Io.Dir.cwd().openDir(io, "src", .{});
    defer src_dir.close(io);
    defer src_dir.deleteFile(io, "BindingsGenerated.zig") catch {};
    const aggregator = try src_dir.readFileAlloc(io, "BindingsGenerated.zig", allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, aggregator, "fixture_bindings_generated.zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, aggregator, "pub const host_function_count = 3;") != null);
    try std.testing.expect(std.mem.indexOf(u8, aggregator, "extism_function_new(\"fixture_create\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aggregator, "extism_function_new(\"fixture_ping\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, aggregator, "fixture_bindings.fixtureCreateHostFn") != null);
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
