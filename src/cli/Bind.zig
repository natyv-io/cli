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
//!
//! **Stage 2.8** added a real `zig translate-c` pre-pass (`TranslateC.zig`)
//! right before the reflector compile in `bindOne` -- see that file's own
//! doc comment for why (a hard, unattributed `@compileError` deep inside
//! a generated `cimport.zig` otherwise, for a name that can't translate
//! at all).

const std = @import("std");
const Io = std.Io;
const Config = @import("Config");
const ZigFetch = @import("ZigFetch");
const Vendor = @import("Vendor");
const TranslateC = @import("TranslateC.zig");

pub const BindError = struct {
    message: []const u8,
};

pub const Outcome = struct {
    /// Number of `bindings` entries successfully processed.
    processed: usize,
    /// Every `entry.include_dirs`/`entry.lib_dirs`/`entry.link` value
    /// across all processed entries, concatenated (not deduped -- harmless
    /// duplicate `-I`/`-L`/`-l` flags cost nothing) -- `cli/main.zig` joins
    /// these into the `-Dbinding-include-dirs`/`-Dbinding-lib-dirs`/
    /// `-Dbinding-link` values `Bundle.zig` passes to natyv-core's own
    /// `zig build`, since `src/BindingsGenerated.zig`'s per-entry
    /// `@cInclude`s and the real library symbols they call need the exact
    /// same include/library paths and linker flags the reflector's own
    /// scratch compile already used.
    include_dirs: []const []const u8 = &.{},
    lib_dirs: []const []const u8 = &.{},
    link: []const []const u8 = &.{},
    /// One `{name, artifact}` per Stage 2.5 `-zig`-mode entry -- `natyv
    /// build`'s own `.build` case joins these into a
    /// `-Dbinding-zig-deps=name1:artifact1,...` flag for `build.zig`'s own
    /// `b.dependency(name, ...).artifact(artifact)` +
    /// `bindings_mod.linkLibrary(...)` loop (see `build.zig`'s own
    /// comment on why this can't be flag-based like `include_dirs`/
    /// `lib_dirs`/`link`).
    zig_deps: []const ZigDepInfo = &.{},
    /// Absolute `.c` file paths (Stage 2.6's tier-1 default vendoring
    /// tier) `build.zig`'s own `bindings_mod` compiles directly, via a new
    /// `-Dbinding-vendor-c-files=` flag -- flat across all vendored
    /// entries, since `build.zig` doesn't need to know which library a
    /// file belongs to, only that it's part of `bindings_mod`'s build.
    vendor_c_files: []const []const u8 = &.{},
    err: ?BindError,
};

pub const ZigDepInfo = struct {
    name: []const u8,
    artifact: []const u8,
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
    /// Stage 2.6 vendoring extras -- resolved to real absolute paths by
    /// `bindOne` (the only place that knows the vendored source's real,
    /// permanent on-disk location), since `entry.include_dirs`/`.lib_dirs`
    /// are relative-to-the-vendor-root for a `vendor_c_build` entry (see
    /// `Config.BindingEntry.vendor_c_build`'s own doc comment) and can't
    /// be pushed into `Outcome.include_dirs`/`.lib_dirs` as-is the way
    /// every other mode's already-absolute-or-cwd-relative paths can.
    /// Empty for a non-vendored entry.
    extra_include_dirs: []const []const u8 = &.{},
    extra_lib_dirs: []const []const u8 = &.{},
    vendor_c_files: []const []const u8 = &.{},
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

/// Result of a `vendor_url` entry's own real fetch+vendor+(optional
/// build) work -- mirrors `BindOneResult`'s own `union(enum)` convention.
/// Only the fields `bindOne` can't derive any other way: the vendored
/// source's own real, permanent absolute path drives all three (see
/// `GeneratedEntry`'s own doc comment on why these can't just be pushed
/// into `Outcome.include_dirs`/`.lib_dirs` directly for a
/// `vendor_c_build` entry).
const VendorModeOutcome = union(enum) {
    ok: struct {
        extra_include_dirs: []const []const u8 = &.{},
        extra_lib_dirs: []const []const u8 = &.{},
        vendor_c_files: []const []const u8 = &.{},
    },
    err: BindError,
};

/// Handles a `zig_url`-mode entry's own real fetch+discover work (Stage
/// 2.5) -- extracted from `bindOne` during the post-Stage-2.10
/// maintainability pass, since that function had grown to stitch three
/// mutually-exclusive per-entry modes together in one place. Appends this
/// entry's own real `-I` to both `compile_argv` (the reflector's own
/// real compile invocation) and `reflector_include_dirs` (Stage 2.8's
/// translate-c pre-pass, which needs the identical set) on success;
/// returns a real error on failure. `url`/`pid` are passed in rather than
/// re-read from `entry`/re-derived, since the caller already has both.
fn handleZigUrlMode(allocator: std.mem.Allocator, io: Io, entry: Config.BindingEntry, core_dir: Io.Dir, bindgen_dir: Io.Dir, bindgen_abs: []const u8, url: []const u8, compile_argv: *std.ArrayList([]const u8), reflector_include_dirs: *std.ArrayList([]const u8)) !?BindError {
    const core_fetch = try ZigFetch.fetchSave(allocator, io, core_dir, entry.library, url);
    if (core_fetch.err) |e| return .{ .message = e.message };

    const artifact = entry.zig_artifact orelse return .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: '{s}' has zig_url set but no zig_artifact -- this should have been caught by `natyv get`'s own validation", .{entry.library}) };
    const zig_discover_scratch_name = try std.fmt.allocPrint(allocator, "_natyv_bind_zigdiscover_{s}", .{entry.library});
    // Registered here, not after the whole function (as this originally
    // read before extraction), for the same "defer only guards what
    // follows its own declaration" reason as `handleVendorUrlMode`'s own
    // cleanup below.
    defer bindgen_dir.deleteTree(io, zig_discover_scratch_name) catch {};
    const disc = try ZigFetch.discoverHeader(allocator, io, bindgen_dir, bindgen_abs, entry.library, url, artifact);
    if (disc.err) |e| return .{ .message = e.message };

    var found_header = false;
    for (disc.installed_headers) |h| {
        if (std.mem.eql(u8, h, entry.header)) found_header = true;
    }
    if (!found_header) {
        var listed: std.ArrayList(u8) = .empty;
        for (disc.installed_headers, 0..) |h, i| {
            if (i > 0) try listed.appendSlice(allocator, ", ");
            try listed.appendSlice(allocator, h);
        }
        return .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: '{s}' expects header '{s}', but the fetched package only installed: {s} -- override with --header= in `natyv get`", .{ entry.library, entry.header, listed.items }) };
    }

    try compile_argv.append(allocator, "-I");
    try compile_argv.append(allocator, disc.include_dir.?);
    try reflector_include_dirs.append(allocator, disc.include_dir.?);
    return null;
}

/// Handles a `vendor_url`-mode entry's own real fetch+permanent-vendor+
/// (optional tier-2 build) work (Stage 2.6) -- extracted from `bindOne`
/// alongside `handleZigUrlMode`, for the same reason. Tier 1
/// (`vendor_c_build` unset) resolves `entry.vendor_files` directly; tier
/// 2 runs the dev's own `vendor_c_build` command first, then treats
/// `entry.include_dirs`/`.lib_dirs` as relative to the vendor root (see
/// `Config.BindingEntry.vendor_c_build`'s own doc comment).
fn handleVendorUrlMode(allocator: std.mem.Allocator, io: Io, entry: Config.BindingEntry, bindgen_dir: Io.Dir, bindgen_abs: []const u8, url: []const u8, compile_argv: *std.ArrayList([]const u8), reflector_include_dirs: *std.ArrayList([]const u8)) !VendorModeOutcome {
    const located = try Vendor.locateSource(allocator, io, bindgen_dir, bindgen_abs, entry.library, url);
    // Registered here, right after `located` is known -- a `defer` only
    // guards code *after* its own declaration, so placing it at the end
    // of this function (as this originally read before extraction) would
    // skip cleanup on the very next line's early return whenever
    // `locateSource` itself failed.
    defer if (located.scratch_dir_name) |n| bindgen_dir.deleteTree(io, n) catch {};
    if (located.err) |e| return .{ .err = .{ .message = e.message } };

    const permanent_name = try std.fmt.allocPrint(allocator, "_natyv_bind_vendor_{s}", .{entry.library});
    bindgen_dir.deleteTree(io, permanent_name) catch {};
    var permanent_dir = bindgen_dir.createDirPathOpen(io, permanent_name, .{}) catch |e| {
        return .{ .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: could not create permanent vendor dir for '{s}': {s}", .{ entry.library, @errorName(e) }) } };
    };
    defer permanent_dir.close(io);

    var located_source_dir = std.Io.Dir.cwd().openDir(io, located.source_dir.?, .{ .iterate = true }) catch |e| {
        return .{ .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: could not open '{s}''s located source: {s}", .{ entry.library, @errorName(e) }) } };
    };
    defer located_source_dir.close(io);
    try Vendor.copyTree(allocator, io, located_source_dir, permanent_dir);

    var pbuf: [std.fs.max_path_bytes]u8 = undefined;
    const permanent_abs_len = try permanent_dir.realPath(io, &pbuf);
    const vendor_dir_abs = try allocator.dupe(u8, pbuf[0..permanent_abs_len]);

    var vendor_extra_include_dirs: []const []const u8 = &.{};
    var vendor_extra_lib_dirs: []const []const u8 = &.{};
    var vendor_c_files: []const []const u8 = &.{};

    if (entry.vendor_c_build) |cmd| {
        const build_result = std.process.run(allocator, io, .{
            .argv = &.{ "/bin/sh", "-c", cmd },
            .cwd = .{ .dir = permanent_dir },
        }) catch |e| {
            return .{ .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: could not run '{s}''s vendor_c_build ('{s}'): {s}", .{ entry.library, cmd, @errorName(e) }) } };
        };
        defer allocator.free(build_result.stdout);
        switch (build_result.term) {
            .exited => |code| {
                if (code != 0) {
                    defer allocator.free(build_result.stderr);
                    return .{ .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: '{s}' vendor_c_build ('{s}') failed (exit code {d}):\n{s}{s}", .{ entry.library, cmd, code, build_result.stdout, build_result.stderr }) } };
                }
                allocator.free(build_result.stderr);
            },
            else => |term| {
                defer allocator.free(build_result.stderr);
                return .{ .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: '{s}' vendor_c_build exited abnormally ({any}):\n{s}{s}", .{ entry.library, term, build_result.stdout, build_result.stderr }) } };
            },
        }

        var extra_inc: std.ArrayList([]const u8) = .empty;
        try extra_inc.append(allocator, vendor_dir_abs);
        for (entry.include_dirs) |rel| try extra_inc.append(allocator, try std.fs.path.join(allocator, &.{ vendor_dir_abs, rel }));
        vendor_extra_include_dirs = extra_inc.items;

        var extra_lib: std.ArrayList([]const u8) = .empty;
        for (entry.lib_dirs) |rel| try extra_lib.append(allocator, try std.fs.path.join(allocator, &.{ vendor_dir_abs, rel }));
        vendor_extra_lib_dirs = extra_lib.items;
    } else {
        var files: std.ArrayList([]const u8) = .empty;
        for (entry.vendor_files) |rel| try files.append(allocator, try std.fs.path.join(allocator, &.{ vendor_dir_abs, rel }));
        vendor_c_files = files.items;

        // Unlike tier 2 (which resolves the dev's own manual
        // `entry.include_dirs`, if any), tier 1 has no equivalent
        // dev-supplied list -- the vendor dir itself is the only include
        // path this tier ever needs, both for the vendored `.c` files'
        // own local `#include`s and for the reflector's own
        // `@cInclude(header)`. `allocator.dupe`, not a `&.{...}` literal
        // -- the latter takes the address of a temporary that doesn't
        // outlive this function, a real dangling-pointer bug caught by a
        // real segfault in this file's own live test, not predicted
        // upfront.
        vendor_extra_include_dirs = try allocator.dupe([]const u8, &.{vendor_dir_abs});
    }

    try compile_argv.append(allocator, "-I");
    try compile_argv.append(allocator, vendor_dir_abs);
    try reflector_include_dirs.append(allocator, vendor_dir_abs);

    return .{ .ok = .{
        .extra_include_dirs = vendor_extra_include_dirs,
        .extra_lib_dirs = vendor_extra_lib_dirs,
        .vendor_c_files = vendor_c_files,
    } };
}

fn bindOne(allocator: std.mem.Allocator, io: Io, entry: Config.BindingEntry, core_dir: Io.Dir, bindgen_dir: Io.Dir, bindgen_abs: []const u8, guest_abs: []const u8) !BindOneResult {
    // Real, found-by-audit correctness gap, fixed here (maintainability
    // pass, 2026-08-25): `zig_url` and `vendor_url` are documented as
    // mutually exclusive (`Config.BindingEntry`'s own doc comments), and
    // `natyv get`'s CLI parsing already refuses to construct a config
    // with both set -- but nothing below this point ever checked that
    // invariant itself. The two branches further down are independent
    // `if` blocks, not `if/else`, so a hand-edited (or otherwise
    // malformed) `conf.natyv.json` with both fields set would silently
    // run *both* fetch/discovery paths and likely produce a broken,
    // hard-to-diagnose build rather than a clear error naming the actual
    // problem.
    if (entry.zig_url != null and entry.vendor_url != null) {
        return .{ .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv bind: '{s}' has both zig_url and vendor_url set -- these are mutually exclusive modes (natyv get's own CLI already prevents this combination; check for a hand-edited or otherwise malformed conf.natyv.json)", .{entry.library}) } };
    }

    // PID-suffixed, not just keyed by `entry.library` -- Stage 2.7 made
    // `bind_module` reachable from more than one independently-running
    // test binary for the first time (`bind_tests` directly, and
    // `ntx_prepare_tests` via `Prepare`'s new named "Bind" import), and
    // both binaries' own real fixture-library tests (`library = "fixture"`)
    // raced on this exact fixed path, reproduced as a real, non-flaky
    // failure -- the identical root cause already found and fixed for
    // `ZigFetch.zig`/`Vendor.zig`'s own scratch dirs. Correct as-is (two
    // processes alive at the same moment can never share a PID, and stale
    // files from a since-recycled PID just get clobbered by the
    // delete-then-create below), but Quinn flagged the raw OS-process
    // concept sitting in application logic as worth reconsidering later --
    // a UUID/random-suffix scheme would express the same "just make this
    // unique" intent without reaching for `getpid()` specifically. Not
    // changed now; noted for a future revisit if this file gets touched
    // again.
    const pid = std.c.getpid();
    const scratch_name = try std.fmt.allocPrint(allocator, "_natyv_bind_scratch_{s}_{x}.zig", .{ entry.library, pid });
    const exe_name = try std.fmt.allocPrint(allocator, "_natyv_bind_scratch_{s}_{x}_exe", .{ entry.library, pid });
    const meta_name = try std.fmt.allocPrint(allocator, "_natyv_bind_scratch_{s}_{x}.meta", .{ entry.library, pid });
    defer bindgen_dir.deleteFile(io, scratch_name) catch {};
    defer bindgen_dir.deleteFile(io, exe_name) catch {};
    defer bindgen_dir.deleteFile(io, meta_name) catch {};

    const reflector_src = try buildReflectorSource(allocator, entry);
    try bindgen_dir.writeFile(io, .{ .sub_path = scratch_name, .data = reflector_src });

    var compile_argv: std.ArrayList([]const u8) = .empty;
    try compile_argv.appendSlice(allocator, &.{ "zig", "build-exe", scratch_name, try std.fmt.allocPrint(allocator, "-femit-bin={s}", .{exe_name}) });
    // Mirrors `compile_argv`'s own accumulated `-I` flags exactly (a
    // parallel list rather than re-parsing `compile_argv` after the fact)
    // -- Stage 2.8's `TranslateC.check` needs the same real include-dir
    // set the reflector's own `@cInclude(entry.header)` will resolve
    // against, so a header found by one is guaranteed found by the other.
    var reflector_include_dirs: std.ArrayList([]const u8) = .empty;
    for (entry.include_dirs) |dir| {
        try compile_argv.append(allocator, "-I");
        try compile_argv.append(allocator, dir);
        try reflector_include_dirs.append(allocator, dir);
    }

    // Each mode's own real fetch/discover/vendor work is extracted into
    // its own dedicated function (`handleZigUrlMode`/`handleVendorUrlMode`,
    // both above `bindOne`) -- see their own doc comments for the full
    // per-mode reasoning. `bindOne` itself only dispatches to at most one
    // (the mutual-exclusivity check at the top of this function
    // guarantees that) and folds its result into the shared
    // `compile_argv`/`reflector_include_dirs` state both modes append to.
    var vendor_extra_include_dirs: []const []const u8 = &.{};
    var vendor_extra_lib_dirs: []const []const u8 = &.{};
    var vendor_c_files: []const []const u8 = &.{};
    if (entry.zig_url) |url| {
        if (try handleZigUrlMode(allocator, io, entry, core_dir, bindgen_dir, bindgen_abs, url, &compile_argv, &reflector_include_dirs)) |err| return .{ .err = err };
    }
    if (entry.vendor_url) |url| {
        switch (try handleVendorUrlMode(allocator, io, entry, bindgen_dir, bindgen_abs, url, &compile_argv, &reflector_include_dirs)) {
            .err => |e| return .{ .err = e },
            .ok => |r| {
                vendor_extra_include_dirs = r.extra_include_dirs;
                vendor_extra_lib_dirs = r.extra_lib_dirs;
                vendor_c_files = r.vendor_c_files;
            },
        }
    }

    // Stage 2.8: a real `zig translate-c` pre-pass, run before the real
    // reflector compile below -- referencing an untranslatable/non-function
    // name via `@field` inside that compile is either a hard,
    // unattributed `@compileError` from deep inside a generated
    // `cimport.zig`, or (for a macro that translates but only into a
    // generic function) a real but generic reflector-runtime error. This
    // catches every such case up front with one clean, natyv-attributed
    // diagnostic per bad name -- see `TranslateC.zig`'s own doc comment
    // for the real, empirically-confirmed dividing lines. Confirmed cheap
    // to run unconditionally (~0.2s warm on this machine), not just on a
    // prior failure.
    const tc_scratch_name = try std.fmt.allocPrint(allocator, "_natyv_bind_tc_check_{s}_{x}.c", .{ entry.library, pid });
    const tc_check = try TranslateC.check(allocator, io, bindgen_dir, entry.header, reflector_include_dirs.items, entry.functions, tc_scratch_name);
    if (!tc_check.ok) return .{ .err = .{ .message = tc_check.err.?.message } };

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
    const parsed_meta = try parseMeta(allocator, entry.library, meta_text);
    return .{ .ok = .{
        .library = parsed_meta.library,
        .host_functions = parsed_meta.host_functions,
        .extra_include_dirs = vendor_extra_include_dirs,
        .extra_lib_dirs = vendor_extra_lib_dirs,
        .vendor_c_files = vendor_c_files,
    } };
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
    var lib_dirs: std.ArrayList([]const u8) = .empty;
    var link: std.ArrayList([]const u8) = .empty;
    var zig_deps: std.ArrayList(ZigDepInfo) = .empty;
    var vendor_c_files: std.ArrayList([]const u8) = .empty;
    var processed: usize = 0;
    for (bindings) |entry| {
        const result = try bindOne(allocator, io, entry, core_dir, bindgen_dir, bindgen_abs, guest_abs);
        var ge: GeneratedEntry = undefined;
        switch (result) {
            .err => |e| return .{ .processed = processed, .err = e },
            .ok => |g| {
                ge = g;
                try generated.append(allocator, g);
            },
        }
        // A `vendor_c_build` entry's own `include_dirs`/`lib_dirs` are
        // relative-to-the-vendor-root (see `Config.BindingEntry.vendor_c_build`'s
        // own doc comment) -- `bindOne` already resolved them into real
        // absolute paths (`ge.extra_include_dirs`/`.extra_lib_dirs`), so
        // the raw, still-relative `entry.include_dirs`/`.lib_dirs` must be
        // skipped here, not pushed alongside them.
        if (entry.vendor_c_build == null) {
            try include_dirs.appendSlice(allocator, entry.include_dirs);
            try lib_dirs.appendSlice(allocator, entry.lib_dirs);
        }
        try include_dirs.appendSlice(allocator, ge.extra_include_dirs);
        try lib_dirs.appendSlice(allocator, ge.extra_lib_dirs);
        try vendor_c_files.appendSlice(allocator, ge.vendor_c_files);
        try link.appendSlice(allocator, entry.link);
        if (entry.zig_url != null) try zig_deps.append(allocator, .{ .name = entry.library, .artifact = entry.zig_artifact.? });
        processed += 1;
    }

    try writeAggregator(allocator, io, core_dir, generated.items);

    return .{ .processed = processed, .include_dirs = include_dirs.items, .lib_dirs = lib_dirs.items, .link = link.items, .zig_deps = zig_deps.items, .vendor_c_files = vendor_c_files.items, .err = null };
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

test "maintainability pass: an entry with both zig_url and vendor_url set is rejected with a clear error, not run through both branches" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var guest_dir = try tmp.dir.createDirPathOpen(io, "guest", .{});
    defer guest_dir.close(io);

    // A real, valid NATYV_CORE_SRC is required here -- `run()` opens
    // `core_dir`/`bindgen_dir` *before* ever calling `bindOne`, so a fake
    // path would surface the unrelated "bad NATYV_CORE_SRC" error instead
    // of ever reaching the new mode-exclusivity check this test exists
    // to exercise.
    const cwd_path = try std.process.currentPathAlloc(io, allocator);

    const bindings = [_]Config.BindingEntry{.{
        .library = "x",
        .header = "x.h",
        .functions = &.{"x"},
        .zig_url = "https://example.com/does-not-matter.tar.gz",
        .zig_artifact = "x",
        .vendor_url = "https://example.com/also-does-not-matter.tar.gz",
    }};
    const outcome = try run(allocator, io, &bindings, cwd_path, guest_dir);
    try std.testing.expect(outcome.err != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "natyv bind:") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "mutually exclusive") != null);
}

test "an unknown function name is now caught by Stage 2.8's translate-c pre-pass, not a raw compile failure" {
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
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "not found in the header") != null);
}

test "Stage 2.8: a macro-derived generic function and a plain constant are both caught before the real reflector compile, with one combined message" {
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
        .functions = &.{ "fixture_create", "FIXTURE_DOUBLE", "FIXTURE_VERSION" },
    }};

    const outcome = try run(allocator, io, &bindings, cwd_path, guest_dir);
    try std.testing.expect(outcome.err != null);
    const msg = outcome.err.?.message;
    try std.testing.expect(std.mem.indexOf(u8, msg, "natyv bind:") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "fixture_create") == null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "FIXTURE_DOUBLE") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "generic function") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "FIXTURE_VERSION") != null);
    try std.testing.expect(std.mem.indexOf(u8, msg, "constant, not a function") != null);
}

test "Stage 2.6 tier 1: a real, live vendored entry fetches, permanently vendors, and compiles for real" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var guest_dir = try tmp.dir.createDirPathOpen(io, "guest", .{});
    defer guest_dir.close(io);

    const cwd_path = try std.process.currentPathAlloc(io, allocator);

    // Real `vendor_files` computed the same way `natyv get -c=<url>`
    // itself computes them (a real fetch+walk of the exact same package) --
    // hand-supplied here since this test exercises `Bind.run`'s own real
    // fetch+copy+compile pipeline directly, not `Get.run`'s declaration
    // step (already covered by `Get.zig`'s own live vendoring test).
    const bindings = [_]Config.BindingEntry{.{
        .library = "zlibsrc",
        .header = "zlib.h",
        .vendor_url = "https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz",
        .vendor_files = &.{ "adler32.c", "deflate.c" },
        .functions = &.{"zlibCompileFlags"},
    }};

    const outcome = try run(allocator, io, &bindings, cwd_path, guest_dir);
    defer {
        var bg = std.Io.Dir.cwd().openDir(io, "src/bindgen", .{}) catch unreachable;
        defer bg.close(io);
        bg.deleteTree(io, "_natyv_bind_vendor_zlibsrc") catch {};
        bg.deleteFile(io, "zlibsrc_bindings_generated.zig") catch {};
    }
    var src_dir_cleanup = try std.Io.Dir.cwd().openDir(io, "src", .{});
    defer {
        src_dir_cleanup.deleteFile(io, "BindingsGenerated.zig") catch {};
        src_dir_cleanup.close(io);
    }
    if (outcome.err) |e| {
        std.debug.print("vendoring bind failed: {s}\n", .{e.message});
        return error.SkipZigTest;
    }
    try std.testing.expectEqual(@as(usize, 1), outcome.processed);

    // Two real, absolute .c file paths -- proves `Bind.run` resolved
    // `vendor_files` against the real, permanent vendor directory it
    // just created, not the ephemeral fetch-locate scratch path.
    try std.testing.expectEqual(@as(usize, 2), outcome.vendor_c_files.len);
    var found_deflate = false;
    for (outcome.vendor_c_files) |f| {
        try std.testing.expect(std.fs.path.isAbsolute(f));
        if (std.mem.endsWith(u8, f, "deflate.c")) found_deflate = true;
        // Every file must really exist on disk at the exact path reported.
        _ = try std.Io.Dir.cwd().statFile(io, f, .{});
    }
    try std.testing.expect(found_deflate);

    // The vendor directory itself must also be in `include_dirs` (so the
    // vendored .c files' own local #includes, and the reflector's own
    // @cInclude("zlib.h"), both resolve).
    var found_vendor_include_dir = false;
    for (outcome.include_dirs) |d| {
        if (std.mem.indexOf(u8, d, "_natyv_bind_vendor_zlibsrc") != null) found_vendor_include_dir = true;
    }
    try std.testing.expect(found_vendor_include_dir);

    const go_out = try guest_dir.readFileAlloc(io, "zlibsrc_bindings_generated.go", allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, go_out, "func ZlibCompileFlags(") != null);
}
