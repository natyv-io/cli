//! `natyv init` (`.ntx` tooling, ~/.claude/plans/lexical-wishing-penguin.md's
//! last remaining open item): interactively asks which guest language the
//! dev is using, then scaffolds a real natyv app in the current working
//! directory -- in place, not a new subdirectory (matching `cargo init`'s
//! convention, not `cargo new`'s, per Quinn's own original phrasing:
//! "scaffolds a new natyv app for them in the current working directory
//! it was run from"). Go is the only real guest language with a shipped
//! SDK today; anything else is a clear "not supported yet" error, not a
//! silent stub -- matches every other closed-vocabulary surface in this
//! project (widget kinds, `.ntx` guest-language dispatch, etc.).
//!
//! The scaffold's `go.mod` `replace` directive points at natyv-core's own
//! `sdk/go`, resolved via the exact same "where's natyv-core" mechanism
//! `src/cli/Bundle.zig` already needed (env var override, else the
//! compile-time-baked `-Dnatyv-core-src` default) -- `main.zig` resolves
//! it once and passes it in here, rather than this file reading the env
//! var/build_options itself, for the same testability reason `Bundle.zig`
//! takes `natyv_core_src` as a parameter instead of resolving it inline.
//!
//! **Deliberately does not run `Prepare.run`** -- Quinn's own explicit
//! call: `natyv init` only ever scaffolds, it never transpiles. The
//! starter `.ntx` file is left exactly as scaffolded; running `natyv
//! prepare`/`natyv build` afterward is a separate, real step the dev
//! takes on their own, same as any other change to `.ntx` source.

const std = @import("std");
const Io = std.Io;

pub const InitError = struct {
    message: []const u8,
};

pub const Result = struct {
    ok: bool,
    err: ?InitError,
};

const go_sum_content =
    \\github.com/extism/go-pdk v1.1.3 h1:hfViMPWrqjN6u67cIYRALZTZLk/enSPpNKa+rZ9X2SQ=
    \\github.com/extism/go-pdk v1.1.3/go.mod h1:Gz+LIU/YCKnKXhgge8yo5Yu1F/lbv7KtKFkiCSzW/P4=
    \\
;

const main_go_content =
    \\package main
    \\
    \\import (
    \\    "natyv/sdk/widgets"
    \\
    \\    "github.com/extism/go-pdk"
    \\)
    \\
    \\//go:wasmexport natyv_init
    \\func natyvInit() int32 {
    \\    root, err := widgets.CreateContainer(widgets.Layout{
    \\        Sizing: widgets.Sizing{Width: widgets.Fixed(400), Height: widgets.Fixed(400)},
    \\    }, false, 0)
    \\    if err != nil {
    \\        pdk.SetErrorString(err.Error())
    \\        return 1
    \\    }
    \\    if err := App(root); err != nil {
    \\        pdk.SetErrorString(err.Error())
    \\        return 1
    \\    }
    \\    return 0
    \\}
    \\
    \\func main() {}
    \\
;

const app_go_ntx_content =
    \\package main
    \\
    \\import "natyv/sdk/widgets"
    \\
    \\expose App
    \\
    \\func App(parent widgets.Container) error {
    \\    <Container>
    \\        <Label>Hello from natyv!</Label>
    \\    </Container>
    \\}
    \\
;

/// Lowercases and replaces every run of characters that aren't
/// `[a-z0-9-]` with a single `-`, trimming leading/trailing `-` --
/// directory names can contain spaces/mixed case/etc., but this same
/// sanitized string is used as both a Go module path segment (which
/// can't) and the compiled wasm's own filename (passed through a real
/// shell via `Compile.zig`, where spaces would break argv parsing).
/// Falls back to `natyv-app` (matching `Config.zig`'s own default) if
/// nothing valid survives.
fn sanitizeName(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var last_was_dash = false;
    for (raw) |b| {
        const lower = std.ascii.toLower(b);
        if (std.ascii.isAlphanumeric(lower)) {
            try out.append(allocator, lower);
            last_was_dash = false;
        } else if (!last_was_dash and out.items.len > 0) {
            try out.append(allocator, '-');
            last_was_dash = true;
        }
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '-') {
        _ = out.pop();
    }
    if (out.items.len == 0) return "natyv-app";
    return out.toOwnedSlice(allocator);
}

fn confNatyvJson(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{
        \\  "name": "{s}",
        \\  "wasm_compile": "tinygo build -target wasip1 -buildmode=c-shared -o {s}.wasm .",
        \\  "sqlite": {{
        \\    "enabled": false
        \\  }},
        \\  "network": {{
        \\    "enabled": false
        \\  }},
        \\  "widgets": {{
        \\    "button": false,
        \\    "textfield": false,
        \\    "label": false
        \\  }},
        \\  "ui": {{
        \\    "backend": "clay"
        \\  }}
        \\}}
        \\
    , .{ name, name });
}

fn goMod(allocator: std.mem.Allocator, name: []const u8, natyv_core_src: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\module natyv/{s}-guest
        \\
        \\go 1.23
        \\
        \\require (
        \\    github.com/extism/go-pdk v1.1.3
        \\    natyv/sdk v0.0.0
        \\)
        \\
        \\replace natyv/sdk => {s}/sdk/go
        \\
    , .{ name, natyv_core_src });
}

/// Reads one line from stdin, trimmed of whitespace/line endings. Empty
/// string on EOF (e.g. non-interactive/piped-closed stdin) rather than an
/// error -- the caller treats an empty answer the same as any other
/// unrecognized one.
pub fn readLine(io: Io, buffer: []u8) ![]const u8 {
    var stdin_file = Io.File.stdin();
    var reader = stdin_file.reader(io, buffer);
    const line = try reader.interface.takeDelimiter('\n') orelse return "";
    return std.mem.trim(u8, line, " \t\r\n");
}

/// `language` is already-read, trimmed user input (see `readLine`) --
/// kept as a plain parameter, not read from stdin inside this function,
/// so the actual scaffolding logic is testable without a real terminal.
/// `cwd_name` is the raw current-directory basename the app's own name
/// gets sanitized from; `natyv_core_src` is natyv-core's own resolved
/// source root (see this file's own doc comment).
pub fn run(allocator: std.mem.Allocator, io: Io, language: []const u8, cwd_name: []const u8, natyv_core_src: []const u8, cwd: Io.Dir) !Result {
    if (!std.ascii.eqlIgnoreCase(language, "go")) {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv init: '{s}' isn't a supported guest language yet (only 'go' is implemented)", .{language}),
        } };
    }

    if (cwd.access(io, "conf.natyv.json", .{})) {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv init: conf.natyv.json already exists here -- refusing to overwrite an existing app", .{}),
        } };
    } else |e| {
        if (e != error.FileNotFound) return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv init: could not check for an existing conf.natyv.json: {s}", .{@errorName(e)}),
        } };
        // FileNotFound is the expected, good case -- fall through.
    }

    const name = try sanitizeName(allocator, cwd_name);

    const conf_json = try confNatyvJson(allocator, name);
    try cwd.writeFile(io, .{ .sub_path = "conf.natyv.json", .data = conf_json });

    var guest_dir = try cwd.createDirPathOpen(io, "guest", .{ .open_options = .{ .iterate = true } });
    defer guest_dir.close(io);

    const go_mod_content = try goMod(allocator, name, natyv_core_src);
    try guest_dir.writeFile(io, .{ .sub_path = "go.mod", .data = go_mod_content });
    try guest_dir.writeFile(io, .{ .sub_path = "go.sum", .data = go_sum_content });
    try guest_dir.writeFile(io, .{ .sub_path = "main.go", .data = main_go_content });
    try guest_dir.writeFile(io, .{ .sub_path = "app.go.ntx", .data = app_go_ntx_content });

    return .{ .ok = true, .err = null };
}

test "sanitizeName lowercases, hyphenates, and trims" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("my-app", try sanitizeName(allocator, "My App"));
    try std.testing.expectEqualStrings("my-app", try sanitizeName(allocator, "  my_app!! "));
    try std.testing.expectEqualStrings("natyv-app", try sanitizeName(allocator, "###"));
    try std.testing.expectEqualStrings("bookstore", try sanitizeName(allocator, "bookstore"));
}

test "an unsupported language is a clear, natyv-attributed error, no files written" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try run(allocator, io, "rust", "myapp", "/fake/natyv/src", tmp.dir);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "rust") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "supported") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "conf.natyv.json", .{}));
}

test "a real Go scaffold produces every real file, untranspiled" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = try run(allocator, io, "Go", "My Cool App", "/fake/natyv/src", tmp.dir);
    try std.testing.expect(result.ok);
    try std.testing.expect(result.err == null);

    const conf = try tmp.dir.readFileAlloc(io, "conf.natyv.json", allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, conf, "\"name\": \"my-cool-app\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, conf, "my-cool-app.wasm") != null);

    var guest_dir = try tmp.dir.openDir(io, "guest", .{});
    defer guest_dir.close(io);

    const go_mod_content = try guest_dir.readFileAlloc(io, "go.mod", allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, go_mod_content, "module natyv/my-cool-app-guest") != null);
    try std.testing.expect(std.mem.indexOf(u8, go_mod_content, "replace natyv/sdk => /fake/natyv/src/sdk/go") != null);

    _ = try guest_dir.readFileAlloc(io, "go.sum", allocator, .unlimited);
    _ = try guest_dir.readFileAlloc(io, "main.go", allocator, .unlimited);
    _ = try guest_dir.readFileAlloc(io, "app.go.ntx", allocator, .unlimited);

    // `natyv init` only ever scaffolds -- it must never also transpile
    // (Quinn's own explicit call). Real proof: neither generated output
    // file exists yet.
    try std.testing.expectError(error.FileNotFound, guest_dir.access(io, "app.natyv.go", .{}));
    try std.testing.expectError(error.FileNotFound, guest_dir.access(io, "app.go", .{}));
}

test "refuses to scaffold over an existing conf.natyv.json" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "conf.natyv.json", .data = "{}" });

    const result = try run(allocator, io, "go", "myapp", "/fake/natyv/src", tmp.dir);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "already exists") != null);
}
