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

/// The CLI's own input contract -- kept as its own type rather than a
/// re-export of `Config.BindingEntry`, even though the fields currently
/// match one-for-one, since this represents "what the dev typed," not
/// "what gets persisted."
pub const GetArgs = struct {
    library: []const u8,
    header: []const u8,
    include_dirs: []const []const u8 = &.{},
    link: []const []const u8 = &.{},
    functions: []const []const u8,
};

pub fn run(allocator: std.mem.Allocator, io: Io, config_path: []const u8, args: GetArgs) !Outcome {
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
        .header = args.header,
        .include_dirs = args.include_dirs,
        .link = args.link,
        .functions = args.functions,
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
