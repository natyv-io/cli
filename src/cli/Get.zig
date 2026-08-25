//! `natyv get`'s real implementation -- Stage 2.3 of
//! ~/.claude/plans/lexical-wishing-penguin.md. Deliberately the fully-
//! manual case only: no `-zig`/`-c` discovery flags yet (those select
//! between pkg-config lookup / Zig package fetch / URL vendoring, none of
//! which exist until Stages 2.4-2.6) -- a dev supplies `header`/
//! `include_dirs`/`link` explicitly, exactly what those later discovery
//! mechanisms will eventually fill in automatically.
//!
//! Only ever *declares* a binding (writes/updates one `conf.natyv.json`
//! `bindings` entry) -- never generates anything itself, that's `natyv
//! bind`'s job (`src/cli/Bind.zig`). Re-running `natyv get` for a
//! `library` already present replaces that entire entry wholesale
//! (header/include_dirs/link/functions all taken fresh from this
//! invocation, never merged with whatever was there before) -- the
//! simplest, most predictable semantics, and the only way to let a dev
//! remove a function/include dir/link flag later by just re-running with
//! a shorter list.
//!
//! Rewrites the whole config file via a full `Config.Self` round-trip
//! (parse -> mutate the in-memory `bindings` slice -> `std.json.Stringify`
//! back out) rather than a surgical text edit of just the `bindings` key --
//! `std.json` doesn't preserve original formatting either way, so a
//! generic-tree edit would still reformat the file, just via a messier
//! path. This does mean a `natyv get` invocation reformats/reorders the
//! *entire* file to match `Config.Self`'s own field declaration order, a
//! real but purely cosmetic effect (every field's own default already
//! makes the reformatted file semantically identical on the next parse).

const std = @import("std");
const Io = std.Io;
const Config = @import("Config");
const PkgConfig = @import("PkgConfig.zig");
const Vendor = @import("Vendor");

pub const GetError = struct {
    message: []const u8,
};

pub const Outcome = struct {
    /// `true` if `library` already had an entry (replaced), `false` if a
    /// new one was appended -- lets `main.zig` print an accurate
    /// "added"/"updated" message without re-deriving it.
    updated_existing: bool,
    err: ?GetError,
};

/// `-c`/`-zig` discovery mode -- `.manual` (Stage 2.3) is the original
/// fully-manual behavior; `.c` (Stage 2.4) is real `pkg-config` discovery;
/// `.zig` (Stage 2.5) is a real Zig package fetch (see `ZigFetch.zig`).
/// `natyv get` itself does *not* run the real fetch/discovery subprocess
/// for `.zig` mode -- unlike `.c`, which is a single cheap `pkg-config`
/// call, a Zig package's real discovery means fetching + compiling, which
/// is expensive to do twice (once at `get`, once at `bind`) and would tie
/// a checked-in `conf.natyv.json` to an ephemeral local scratch path that
/// won't survive `git clone`/CI. So `.zig` mode here only writes
/// `zig_url`/`zig_artifact` into the entry (`--header=` still defaults to
/// `<library>.h`, same guess as `.c` mode, just unvalidated) -- the real
/// fetch+discovery happens once, for real, every `natyv bind` run
/// (`Bind.zig`'s job).
pub const Mode = enum { manual, c, zig };

/// The CLI's own input contract -- kept as its own type rather than a
/// re-export of `Config.BindingEntry`, even though the fields currently
/// match one-for-one, since this represents "what the dev typed," not
/// "what gets persisted." `header` is optional at this type's own level
/// even though `.manual` mode requires it -- that requirement is enforced
/// by `main.zig`'s `parseGetArgs` (CLI-level validation, mode-aware),
/// since `.c` mode legitimately has no required `header` at all (defaults
/// to `"<library>.h"`, see `run` below).
pub const GetArgs = struct {
    library: []const u8,
    mode: Mode = .manual,
    header: ?[]const u8 = null,
    include_dirs: []const []const u8 = &.{},
    lib_dirs: []const []const u8 = &.{},
    link: []const []const u8 = &.{},
    functions: []const []const u8,
    /// `.zig` mode only -- required alongside it (enforced by `main.zig`'s
    /// `parseGetArgs`).
    zig_url: ?[]const u8 = null,
    zig_artifact: ?[]const u8 = null,
    /// `.c` mode, Stage 2.6's URL-vendoring variant -- non-null means the
    /// `-c` target was a URL (`-c=<url>`), not a bare pkg-config module
    /// name. `vendor_c_build` (opt-in tier 2) is independent of this
    /// field's own presence at the type level, but `main.zig`'s own
    /// `parseGetArgs` never constructs one without the other (enforced
    /// there via `error.CBuildRequiresVendorUrl`).
    vendor_url: ?[]const u8 = null,
    vendor_c_build: ?[]const u8 = null,
};

pub fn run(allocator: std.mem.Allocator, io: Io, config_path: []const u8, args: GetArgs) !Outcome {
    var header = args.header;
    var include_dirs = args.include_dirs;
    var lib_dirs = args.lib_dirs;
    var link = args.link;
    var vendor_files: []const []const u8 = &.{};

    if (args.mode == .c and args.vendor_url != null) {
        header = args.header orelse try std.fmt.allocPrint(allocator, "{s}.h", .{args.library});
        if (args.vendor_c_build == null) {
            // Tier 1 (default): a real fetch+walk, right now, to compute
            // `vendor_files` -- unlike `.zig` mode's own deferred-to-`bind`
            // discovery, this result (a list of relative filenames) is
            // fully portable and safe to persist in checked-in
            // `conf.natyv.json`, so there's no reason to defer it. Scratch
            // work happens under a hidden dir in the app's own cwd,
            // cleaned up immediately after -- `get` still never touches
            // NATYV_CORE_SRC (the real, permanent vendored copy is
            // `natyv bind`'s own job, at real `bind` time).
            // Unique per invocation (not a fixed name) -- a fixed scratch
            // dir name real-collided during this stage's own live test
            // suite (two `zig build` subprocess invocations racing on the
            // same `zig-pkg/` cache subtree, one of them getting its own
            // partially-extracted files yanked out from under it by the
            // other's cleanup) -- confirmed empirically, not just a
            // theoretical concern, so real uniqueness is required, not
            // just table stakes. Correct as-is; see `Bind.zig`'s own
            // fuller `getpid()` doc comment (`bindOne`) for why, and for a
            // possible future UUID/random-suffix alternative Quinn flagged
            // as worth reconsidering later.
            const scratch_parent_name = try std.fmt.allocPrint(allocator, ".natyv-vendor-discover-{x}", .{std.c.getpid()});
            var scratch_parent = std.Io.Dir.cwd().createDirPathOpen(io, scratch_parent_name, .{}) catch |e| {
                return .{ .updated_existing = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv get: could not create scratch vendor-discovery dir: {s}", .{@errorName(e)}) } };
            };
            defer scratch_parent.close(io);
            defer std.Io.Dir.cwd().deleteTree(io, scratch_parent_name) catch {};

            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const scratch_parent_abs_len = try scratch_parent.realPath(io, &buf);
            const scratch_parent_abs = try allocator.dupe(u8, buf[0..scratch_parent_abs_len]);

            const locate_scratch_name = try std.fmt.allocPrint(allocator, "_natyv_vendor_locate_{s}", .{args.library});
            const located = try Vendor.locateSource(allocator, io, scratch_parent, scratch_parent_abs, args.library, args.vendor_url.?);
            defer scratch_parent.deleteTree(io, locate_scratch_name) catch {};
            if (located.err) |e| return .{ .updated_existing = false, .err = .{ .message = e.message } };

            var source_dir = std.Io.Dir.cwd().openDir(io, located.source_dir.?, .{ .iterate = true }) catch |e| {
                return .{ .updated_existing = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv get: could not open the fetched source at '{s}': {s}", .{ located.source_dir.?, @errorName(e) }) } };
            };
            defer source_dir.close(io);
            vendor_files = try Vendor.findCSourceFiles(allocator, io, source_dir);
            if (vendor_files.len == 0) {
                return .{ .updated_existing = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv get: found no real .c files in the fetched source at '{s}' (skipping any test/tests/example/examples path) -- if this library needs its own build system, use --c-build=<command> instead", .{args.vendor_url.?}) } };
            }
        }
    } else if (args.mode == .c) {
        const disc = try PkgConfig.discover(allocator, io, args.library);
        if (disc.err) |e| return .{ .updated_existing = false, .err = .{ .message = e.message } };
        const d = disc.discovery.?;
        // The dev's own `--header=` always overrides the `<library>.h`
        // guess (pkg-config's own `.pc` format has no field naming which
        // header is the public one) -- matches the confirmed design's own
        // wording exactly. Discovered include_dirs/lib_dirs/link come
        // first, with anything the dev *also* passed manually appended
        // after -- an escape hatch to add one more path pkg-config didn't
        // know about, not a replacement of the discovered set.
        header = args.header orelse try std.fmt.allocPrint(allocator, "{s}.h", .{args.library});
        include_dirs = try std.mem.concat(allocator, []const u8, &.{ d.include_dirs, args.include_dirs });
        lib_dirs = try std.mem.concat(allocator, []const u8, &.{ d.lib_dirs, args.lib_dirs });
        link = try std.mem.concat(allocator, []const u8, &.{ d.link, args.link });
    } else if (args.mode == .zig) {
        // Same `<library>.h` default-guess convention as `.c` mode, just
        // unvalidated here -- see this file's `Mode` doc comment on why
        // `.zig` mode doesn't run real discovery at `get` time.
        header = args.header orelse try std.fmt.allocPrint(allocator, "{s}.h", .{args.library});
    }

    const parsed = Config.load(allocator, io, config_path) catch |e| {
        return .{ .updated_existing = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv get: failed to load {s}: {s}", .{ config_path, @errorName(e) }),
        } };
    };
    defer parsed.deinit();

    var bindings: std.ArrayList(Config.BindingEntry) = .empty;
    try bindings.appendSlice(allocator, parsed.value.bindings);

    const new_entry = Config.BindingEntry{
        .library = args.library,
        .header = header.?, // guaranteed non-null: required in `.manual` mode (main.zig), defaulted above in `.c`/`.zig` mode
        .include_dirs = include_dirs,
        .lib_dirs = lib_dirs,
        .link = link,
        .functions = args.functions,
        .zig_url = if (args.mode == .zig) args.zig_url else null,
        .zig_artifact = if (args.mode == .zig) args.zig_artifact else null,
        .vendor_url = args.vendor_url,
        .vendor_files = vendor_files,
        .vendor_c_build = args.vendor_c_build,
    };

    var updated_existing = false;
    for (bindings.items, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.library, args.library)) {
            bindings.items[i] = new_entry;
            updated_existing = true;
            break;
        }
    }
    if (!updated_existing) try bindings.append(allocator, new_entry);

    var new_config = parsed.value;
    new_config.bindings = bindings.items;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    std.json.Stringify.value(new_config, .{ .whitespace = .indent_2 }, &out.writer) catch |e| {
        return .{ .updated_existing = updated_existing, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv get: failed to serialize {s}: {s}", .{ config_path, @errorName(e) }),
        } };
    };

    std.Io.Dir.cwd().writeFile(io, .{ .sub_path = config_path, .data = out.written() }) catch |e| {
        return .{ .updated_existing = updated_existing, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv get: failed to write {s}: {s}", .{ config_path, @errorName(e) }),
        } };
    };

    return .{ .updated_existing = updated_existing, .err = null };
}

test "a fresh config gets a new bindings entry appended" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}/conf.natyv.json", .{ cwd_path, tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs_path, .data = "{\"name\":\"myapp\",\"wasm_compile\":\"tinygo build -o app.wasm .\"}" });

    const outcome = try run(allocator, io, abs_path, .{
        .library = "zlib",
        .header = "zlib.h",
        .link = &.{"z"},
        .functions = &.{"zlibCompileFlags"},
    });
    try std.testing.expect(outcome.err == null);
    try std.testing.expect(!outcome.updated_existing);

    const reparsed = try Config.load(allocator, io, abs_path);
    try std.testing.expectEqualStrings("myapp", reparsed.value.name);
    try std.testing.expectEqual(@as(usize, 1), reparsed.value.bindings.len);
    try std.testing.expectEqualStrings("zlib", reparsed.value.bindings[0].library);
    try std.testing.expectEqualStrings("zlib.h", reparsed.value.bindings[0].header);
    try std.testing.expectEqual(@as(usize, 1), reparsed.value.bindings[0].link.len);
    try std.testing.expectEqualStrings("z", reparsed.value.bindings[0].link[0]);
}

test "re-running for the same library replaces the entry wholesale, not merged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}/conf.natyv.json", .{ cwd_path, tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs_path, .data = "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}" });

    _ = try run(allocator, io, abs_path, .{
        .library = "zlib",
        .header = "zlib.h",
        .include_dirs = &.{"/opt/homebrew/include"},
        .link = &.{"z"},
        .functions = &.{ "compress", "uncompress" },
    });

    const outcome = try run(allocator, io, abs_path, .{
        .library = "zlib",
        .header = "zlib.h",
        .functions = &.{"zlibCompileFlags"},
    });
    try std.testing.expect(outcome.err == null);
    try std.testing.expect(outcome.updated_existing);

    const reparsed = try Config.load(allocator, io, abs_path);
    try std.testing.expectEqual(@as(usize, 1), reparsed.value.bindings.len);
    const entry = reparsed.value.bindings[0];
    // The old include_dirs/link/functions must be gone, not merged in.
    try std.testing.expectEqual(@as(usize, 0), entry.include_dirs.len);
    try std.testing.expectEqual(@as(usize, 0), entry.link.len);
    try std.testing.expectEqual(@as(usize, 1), entry.functions.len);
    try std.testing.expectEqualStrings("zlibCompileFlags", entry.functions[0]);
}

test "a second, distinctly-named library is appended alongside the first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}/conf.natyv.json", .{ cwd_path, tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs_path, .data = "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}" });

    _ = try run(allocator, io, abs_path, .{ .library = "zlib", .header = "zlib.h", .functions = &.{"zlibCompileFlags"} });
    _ = try run(allocator, io, abs_path, .{ .library = "sqlite3", .header = "sqlite3.h", .functions = &.{"sqlite3_libversion"} });

    const reparsed = try Config.load(allocator, io, abs_path);
    try std.testing.expectEqual(@as(usize, 2), reparsed.value.bindings.len);
    try std.testing.expectEqualStrings("zlib", reparsed.value.bindings[0].library);
    try std.testing.expectEqualStrings("sqlite3", reparsed.value.bindings[1].library);
}

test "every other config section round-trips unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}/conf.natyv.json", .{ cwd_path, tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs_path, .data =
        \\{
        \\  "name": "bookstore",
        \\  "wasm_compile": "tinygo build -target wasip1 -buildmode=c-shared -o bookstore.wasm .",
        \\  "sqlite": {"enabled": true, "filename": "books.sqlite3"},
        \\  "network": {"enabled": true, "allowed_hosts": ["www.google.com"]},
        \\  "widgets": {"button": true, "label": true}
        \\}
    });

    _ = try run(allocator, io, abs_path, .{ .library = "zlib", .header = "zlib.h", .functions = &.{"zlibCompileFlags"} });

    const reparsed = try Config.load(allocator, io, abs_path);
    try std.testing.expectEqualStrings("bookstore", reparsed.value.name);
    try std.testing.expectEqualStrings("tinygo build -target wasip1 -buildmode=c-shared -o bookstore.wasm .", reparsed.value.wasm_compile);
    try std.testing.expect(reparsed.value.sqlite.enabled);
    try std.testing.expectEqualStrings("books.sqlite3", reparsed.value.sqlite.filename);
    try std.testing.expect(reparsed.value.network.enabled);
    try std.testing.expectEqualStrings("www.google.com", reparsed.value.network.allowed_hosts[0]);
    try std.testing.expect(reparsed.value.widgets.button and reparsed.value.widgets.label);
}

test "a missing config file is a clear, natyv-attributed error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const outcome = try run(allocator, io, "/definitely/not/a/real/conf.natyv.json", .{ .library = "zlib", .header = "zlib.h", .functions = &.{"zlibCompileFlags"} });
    defer if (outcome.err) |e| allocator.free(e.message);
    try std.testing.expect(outcome.err != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "natyv get:") != null);
}

test "-c mode: real pkg-config discovery fills in header/link, no --header= given" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}/conf.natyv.json", .{ cwd_path, tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs_path, .data = "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}" });

    const outcome = try run(allocator, io, abs_path, .{
        .library = "zlib",
        .mode = .c,
        .functions = &.{"zlibCompileFlags"},
    });
    try std.testing.expect(outcome.err == null);

    const reparsed = try Config.load(allocator, io, abs_path);
    const entry = reparsed.value.bindings[0];
    try std.testing.expectEqualStrings("zlib.h", entry.header); // the <library>.h default guess
    try std.testing.expect(entry.link.len >= 1);
    try std.testing.expectEqualStrings("z", entry.link[0]); // real pkg-config output, not hand-typed
}

test "-c mode: an explicit --header= overrides the <library>.h default guess" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}/conf.natyv.json", .{ cwd_path, tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs_path, .data = "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}" });

    _ = try run(allocator, io, abs_path, .{
        .library = "zlib",
        .mode = .c,
        .header = "zconf.h",
        .functions = &.{"zlibCompileFlags"},
    });

    const reparsed = try Config.load(allocator, io, abs_path);
    try std.testing.expectEqualStrings("zconf.h", reparsed.value.bindings[0].header);
}

test "-c mode: a manually-supplied --link= is appended after the discovered ones, not replacing them" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}/conf.natyv.json", .{ cwd_path, tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs_path, .data = "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}" });

    _ = try run(allocator, io, abs_path, .{
        .library = "zlib",
        .mode = .c,
        .link = &.{"extrastub"},
        .functions = &.{"zlibCompileFlags"},
    });

    const reparsed = try Config.load(allocator, io, abs_path);
    const link = reparsed.value.bindings[0].link;
    try std.testing.expectEqual(@as(usize, 2), link.len);
    try std.testing.expectEqualStrings("z", link[0]); // discovered, comes first
    try std.testing.expectEqualStrings("extrastub", link[1]); // manual, appended after
}

test "-zig mode: writes zig_url/zig_artifact and the <library>.h default guess, no real fetch performed" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}/conf.natyv.json", .{ cwd_path, tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs_path, .data = "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}" });

    const outcome = try run(allocator, io, abs_path, .{
        .library = "zlib",
        .mode = .zig,
        .zig_url = "https://github.com/allyourcodebase/zlib/archive/refs/heads/main.tar.gz",
        .zig_artifact = "z",
        .functions = &.{"zlibCompileFlags"},
    });
    try std.testing.expect(outcome.err == null);

    const reparsed = try Config.load(allocator, io, abs_path);
    const entry = reparsed.value.bindings[0];
    try std.testing.expectEqualStrings("zlib.h", entry.header);
    try std.testing.expectEqualStrings("https://github.com/allyourcodebase/zlib/archive/refs/heads/main.tar.gz", entry.zig_url.?);
    try std.testing.expectEqualStrings("z", entry.zig_artifact.?);
    try std.testing.expectEqual(@as(usize, 0), entry.include_dirs.len);
    try std.testing.expectEqual(@as(usize, 0), entry.link.len);
}

test "-zig mode: an explicit --header= overrides the <library>.h default guess" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}/conf.natyv.json", .{ cwd_path, tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs_path, .data = "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}" });

    _ = try run(allocator, io, abs_path, .{
        .library = "zlib",
        .mode = .zig,
        .header = "zconf.h",
        .zig_url = "https://github.com/allyourcodebase/zlib/archive/refs/heads/main.tar.gz",
        .zig_artifact = "z",
        .functions = &.{"zlibCompileFlags"},
    });

    const reparsed = try Config.load(allocator, io, abs_path);
    try std.testing.expectEqualStrings("zconf.h", reparsed.value.bindings[0].header);
}

test "-c=<url> mode (tier 1): a real, live fetch+walk populates vendor_files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}/conf.natyv.json", .{ cwd_path, tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs_path, .data = "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}" });

    const outcome = try run(allocator, io, abs_path, .{
        .library = "zlibsrc",
        .mode = .c,
        .vendor_url = "https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz",
        .functions = &.{"zlibCompileFlags"},
    });
    if (outcome.err) |e| {
        std.debug.print("vendoring get failed: {s}\n", .{e.message});
        return error.SkipZigTest;
    }

    const reparsed = try Config.load(allocator, io, abs_path);
    const entry = reparsed.value.bindings[0];
    try std.testing.expectEqualStrings("zlibsrc.h", entry.header);
    try std.testing.expectEqualStrings("https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz", entry.vendor_url.?);
    try std.testing.expect(entry.vendor_files.len > 5); // real zlib has ~15 top-level .c files
    var found_deflate = false;
    for (entry.vendor_files) |f| {
        if (std.mem.eql(u8, f, "deflate.c")) found_deflate = true;
    }
    try std.testing.expect(found_deflate);
}

test "-c=<url> mode (tier 2, --c-build=): declares vendor_c_build + manual link with no real fetch at get time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}/conf.natyv.json", .{ cwd_path, tmp.sub_path });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs_path, .data = "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}" });

    // A deliberately unreachable URL -- proves tier 2 never fetches at
    // `get` time (would otherwise fail on a real network call).
    const outcome = try run(allocator, io, abs_path, .{
        .library = "zlibsrc",
        .mode = .c,
        .vendor_url = "https://example.invalid/never-actually-fetched.tar.gz",
        .vendor_c_build = "./configure && make",
        .link = &.{"z"},
        .functions = &.{"zlibCompileFlags"},
    });
    try std.testing.expect(outcome.err == null);

    const reparsed = try Config.load(allocator, io, abs_path);
    const entry = reparsed.value.bindings[0];
    try std.testing.expectEqualStrings("zlibsrc.h", entry.header);
    try std.testing.expectEqualStrings("./configure && make", entry.vendor_c_build.?);
    try std.testing.expectEqual(@as(usize, 0), entry.vendor_files.len);
    try std.testing.expectEqual(@as(usize, 1), entry.link.len);
}

test "-c mode: an unknown pkg-config module surfaces pkg-config's own real error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    const abs_path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}/conf.natyv.json", .{ cwd_path, tmp.sub_path });
    defer allocator.free(abs_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = abs_path, .data = "{\"wasm_compile\":\"tinygo build -o app.wasm .\"}" });

    const outcome = try run(allocator, io, abs_path, .{
        .library = "this_pkgconfig_module_does_not_exist",
        .mode = .c,
        .functions = &.{"f"},
    });
    defer if (outcome.err) |e| allocator.free(e.message);
    try std.testing.expect(outcome.err != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "natyv get:") != null);
}
