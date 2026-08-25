//! `natyv prepare`'s real implementation (`.ntx` tooling Stage 7,
//! ~/.claude/plans/lexical-wishing-penguin.md). Everything before this was
//! hand-invoked -- every real example (`examples/ntx-form`,
//! `examples/ntx-components`) had its generated output produced by a
//! throwaway scratch script, since nothing walked a real directory and
//! dispatched by extension yet. This does that for real, Go-only (the
//! only real guest target this arc has ever implemented), matching the
//! same "strip `.ntx`, dispatch on what's left" convention already used
//! for codegen and Stage 6b's post-codegen validation.
//!
//! Deliberately narrow: walks one directory (the app's guest source
//! root) for `*.ntx` files, transpiles each via `Expose`/`Codegen`, and
//! runs `Validate.validateForExtension` once at the end if anything was
//! processed.
//!
//! Real stylesheet ingestion (closes the gap flagged repeatedly since
//! Stage 5's margin work -- every real `.ntx` example's margin/token
//! behavior was previously produced by hand-feeding a Zig literal through
//! a throwaway scratch script, never a real parsed stylesheet file): a
//! first pass (`findStyleTokens`) walks the same guest tree for a real
//! `.ntss` file (natyv's own stylesheet extension -- see
//! `src/styling/Stylesheet.zig`'s grammar doc comment), parses + resolves
//! it via the same `Stylesheet`/`Resolver` pipeline the styling system's
//! own tests already exercise, and hands the resulting resolved tokens to
//! *both* real consumers in one pass: `ntx/Codegen.zig`'s margin-as-
//! wrapper decision, and `styling/Codegen.zig`'s `StyleTokens` runtime map
//! (written as `styletokens_generated.go` into every package directory
//! that gets any `.ntx` output at all -- cheap and idempotent to write it
//! per-package rather than tracking which packages actually reference
//! which token names). Deliberately v1-narrow: at most one `.ntss` file
//! per guest tree is supported (a clear error, not silent pick-first, if
//! more than one is found) -- matches the styling system's own "one
//! shared stylesheet regardless of guest language" design; per-package
//! stylesheets are an easy, undesigned future extension if a real need
//! shows up. A guest tree with zero `.ntss` files is unchanged from
//! before this: no error, no styletokens_generated.go, an empty token
//! slice handed to `Codegen.generateGo` exactly as it was hardcoded to
//! before.
//!
//! **Stage 2.7 of the binding generator arc** (~/.claude/plans/lexical-wishing-penguin.md):
//! `natyv bind` now runs as this function's own first step (via `Bind.run`),
//! not just a separate step `cli/main.zig`'s `.build` case ran in front of
//! this file on its own -- so the LSP's own confirmed design (reusing this
//! exact transpile logic in-process for virtual documents, see CLAUDE.md)
//! gets binding freshness for free, with zero special-casing. `mode:
//! .codegen_only` (the real `--codegen` flag's own effect) limits this to
//! just the stylesheet pass + bind, skipping the `.ntx` walk/transpile
//! entirely -- Quinn's own reasoning: running real `.ntx` transpilation on
//! every fast-path invocation would write real `.natyv.go` files into the
//! dev's guest directory speculatively/frequently, making the codebase
//! harder to mentally model (which files are hand-written vs. generated)
//! and slowing down anything calling this often. `natyv build`'s own
//! pipeline picks `mode` from its existing `BuildCache` freshness check
//! (`.codegen_only` when fresh, `.full` otherwise) so bind always runs
//! exactly once per invocation regardless -- it never skips, only the
//! `.ntx` transpile + `wasm_compile` pair does.

const std = @import("std");
const Io = std.Io;
const Expose = @import("Expose");
const Codegen = @import("Codegen");
const Validate = @import("Validate");
const Resolver = @import("Resolver");
const Stylesheet = @import("Stylesheet");
const StylingCodegen = @import("StylingCodegen");
const Config = @import("Config");
const Bind = @import("Bind");

pub const PrepareError = struct {
    message: []const u8,
};

fn isIdentStart(b: u8) bool {
    return std.ascii.isAlphabetic(b) or b == '_';
}
fn isIdentCont(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

/// Extracts the name from a real Go source's own leading `package <name>`
/// line -- `natyv prepare` uses the *file's own* declared package as
/// `generateGo`'s `package_name` param, rather than inferring one from
/// directory structure, since the dev's source already states it
/// authoritatively and unambiguously.
///
/// Only accepts a `package` keyword that's the first token on its own
/// line (real Go syntax always requires this) -- a plain
/// `indexOf(src, "package")` false-positives on a leading doc comment
/// that merely mentions the word in prose, found via a real fixture:
/// `examples/ntx-components/guest/page.go.ntx`'s own header comment says
/// "...sibling `components` package (card.go.ntx)...", which the naive
/// version matched instead of the real declaration several lines later.
fn extractPackageName(src: []const u8) ?[]const u8 {
    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, src, search_start, "package")) |idx| {
        var line_start = idx;
        while (line_start > 0 and src[line_start - 1] != '\n') : (line_start -= 1) {}
        const only_leading_whitespace = for (src[line_start..idx]) |b| {
            if (b != ' ' and b != '\t') break false;
        } else true;

        if (only_leading_whitespace) {
            var i = idx + "package".len;
            if (i < src.len and (src[i] == ' ' or src[i] == '\t')) {
                while (i < src.len and (src[i] == ' ' or src[i] == '\t')) : (i += 1) {}
                const start = i;
                if (start < src.len and isIdentStart(src[start])) {
                    i += 1;
                    while (i < src.len and isIdentCont(src[i])) : (i += 1) {}
                    return src[start..i];
                }
            }
        }
        search_start = idx + 1;
    }
    return null;
}

/// Limits `run` to just the stylesheet pass + `natyv bind` (the real
/// `--codegen` flag's own effect) when `.codegen_only`; `.full` (the
/// default, matching this function's pre-Stage-2.7 behavior) also does
/// the `.ntx` walk/transpile + validation pass.
pub const Mode = enum { full, codegen_only };

pub const Outcome = struct {
    /// Number of `.ntx` files successfully transpiled -- always 0 in
    /// `.codegen_only` mode, since that mode never reaches the `.ntx`
    /// walk at all.
    processed: usize,
    /// Stage 2.7: `natyv bind`'s own aggregated output (see
    /// `Bind.Outcome`'s own doc comment on each field) -- surfaced here so
    /// `cli/main.zig`'s `.build` case can build `Bundle.run`'s flags
    /// without a separate `Bind.run` call of its own. Empty/default when
    /// there are no `bindings` entries at all (`Bind.run` itself is never
    /// called in that case, matching its own established "empty list is a
    /// real no-op" behavior).
    binding_include_dirs: []const []const u8 = &.{},
    binding_lib_dirs: []const []const u8 = &.{},
    binding_link: []const []const u8 = &.{},
    binding_zig_deps: []const Bind.ZigDepInfo = &.{},
    binding_vendor_c_files: []const []const u8 = &.{},
    err: ?PrepareError,
};

const StyleTokensResult = struct {
    tokens: []const Resolver.ResolvedStyleToken,
    err: ?PrepareError,
};

/// Walks `guest_dir` for a real `.ntss` stylesheet source, parsing +
/// resolving it if found. At most one is supported for v1 (see this
/// file's own doc comment) -- a second one found anywhere in the tree is
/// a clear error naming both real paths, not a silent pick-first.
fn findStyleTokens(allocator: std.mem.Allocator, io: Io, guest_dir: Io.Dir) !StyleTokensResult {
    var walker = try guest_dir.walk(allocator);
    defer walker.deinit();

    var found_path: ?[]const u8 = null;
    var tokens: []const Resolver.ResolvedStyleToken = &.{};
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".ntss")) continue;

        if (found_path) |first| {
            return .{ .tokens = &.{}, .err = .{
                .message = try std.fmt.allocPrint(allocator, "natyv prepare: multiple .ntss stylesheets found ('{s}' and '{s}') -- only one is supported right now", .{ first, entry.path }),
            } };
        }
        found_path = try allocator.dupe(u8, entry.path);

        const src = try entry.dir.readFileAlloc(io, entry.basename, allocator, .unlimited);

        const parsed = try Stylesheet.parse(allocator, src);
        if (parsed.err) |e| return .{ .tokens = &.{}, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv prepare: {s}:{d}:{d}: {s}", .{ entry.path, e.line, e.col, e.message }),
        } };

        const resolved = try Resolver.resolve(allocator, parsed.sheet);
        if (resolved.err) |e| return .{ .tokens = &.{}, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv prepare: {s}:{d}:{d}: {s}", .{ entry.path, e.line, e.col, e.message }),
        } };
        tokens = resolved.tokens;
    }

    return .{ .tokens = tokens, .err = null };
}

/// Walks `guest_dir` recursively for `*.ntx` files, transpiles each one in
/// place (writing its two split output files into the same directory the
/// source was found in -- `Walker.Entry.dir`/`.basename` already resolve
/// this correctly regardless of nesting depth), then runs a Go dependency
/// validation pass once if anything was processed. Stops at the first
/// real error rather than partially-processing the rest of the tree --
/// matches every other stage's "clear error over silent partial success"
/// posture.
///
/// `allocator` is expected to be arena-backed (or otherwise tolerant of
/// not-individually-freed allocations) -- `Codegen.generateGo` itself
/// already allocates many small strings it never frees individually, by
/// design (see its own tests), and this only ever runs once per real CLI
/// invocation, so bulk-freeing on process exit is the correct, simplest
/// choice, not a leak.
///
/// `bindings`/`natyv_core_src` feed `Bind.run` (Stage 2.7's own fold-in,
/// see this file's doc comment) -- `natyv_core_src` is unused and may be
/// anything (e.g. `""`) when `bindings.len == 0`, mirroring `Bind.run`'s
/// own "empty list is a real no-op, `natyv_core_src` never opened" shape.
pub fn run(allocator: std.mem.Allocator, io: Io, guest_dir: Io.Dir, bindings: []const Config.BindingEntry, natyv_core_src: []const u8, mode: Mode) !Outcome {
    var binding_include_dirs: []const []const u8 = &.{};
    var binding_lib_dirs: []const []const u8 = &.{};
    var binding_link: []const []const u8 = &.{};
    var binding_zig_deps: []const Bind.ZigDepInfo = &.{};
    var binding_vendor_c_files: []const []const u8 = &.{};
    if (bindings.len > 0) {
        const bind_outcome = try Bind.run(allocator, io, bindings, natyv_core_src, guest_dir);
        if (bind_outcome.err) |e| return .{ .processed = 0, .err = .{ .message = e.message } };
        binding_include_dirs = bind_outcome.include_dirs;
        binding_lib_dirs = bind_outcome.lib_dirs;
        binding_link = bind_outcome.link;
        binding_zig_deps = bind_outcome.zig_deps;
        binding_vendor_c_files = bind_outcome.vendor_c_files;
    }

    const style_result = try findStyleTokens(allocator, io, guest_dir);
    if (style_result.err) |e| return .{
        .processed = 0,
        .binding_include_dirs = binding_include_dirs,
        .binding_lib_dirs = binding_lib_dirs,
        .binding_link = binding_link,
        .binding_zig_deps = binding_zig_deps,
        .binding_vendor_c_files = binding_vendor_c_files,
        .err = e,
    };
    const style_tokens = style_result.tokens;

    if (mode == .codegen_only) return .{
        .processed = 0,
        .binding_include_dirs = binding_include_dirs,
        .binding_lib_dirs = binding_lib_dirs,
        .binding_link = binding_link,
        .binding_zig_deps = binding_zig_deps,
        .binding_vendor_c_files = binding_vendor_c_files,
        .err = null,
    };

    var walker = try guest_dir.walk(allocator);
    defer walker.deinit();

    var processed: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".ntx")) continue;

        const base = entry.basename[0 .. entry.basename.len - ".ntx".len];
        if (!std.mem.endsWith(u8, base, ".go")) {
            return .{ .processed = processed, .err = .{
                .message = try std.fmt.allocPrint(allocator, "natyv prepare: '{s}' isn't a supported guest-language extension yet (only .go.ntx is implemented)", .{entry.path}),
            } };
        }
        const stem = base[0 .. base.len - ".go".len];

        const src = try entry.dir.readFileAlloc(io, entry.basename, allocator, .unlimited);

        const package_name = extractPackageName(src) orelse return .{ .processed = processed, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv prepare: '{s}' has no 'package <name>' declaration", .{entry.path}),
        } };

        const found = try Expose.findComposers(allocator, src);
        if (found.err) |e| return .{ .processed = processed, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv prepare: {s}:{d}:{d}: {s}", .{ entry.path, e.line, e.col, e.message }),
        } };

        const result = try Codegen.generateGo(allocator, package_name, src, found.composers, style_tokens, found.uses, found.uses_start, found.uses_end);
        if (result.err) |e| return .{ .processed = processed, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv prepare: {s}:{d}:{d}: {s}", .{ entry.path, e.line, e.col, e.message }),
        } };

        const natyv_name = try std.fmt.allocPrint(allocator, "{s}.natyv.go", .{stem});
        const logic_name = base;
        try entry.dir.writeFile(io, .{ .sub_path = natyv_name, .data = result.output.?.generated });
        try entry.dir.writeFile(io, .{ .sub_path = logic_name, .data = result.output.?.logic });

        // Every package directory that gets any real `.ntx` output also
        // gets its own `styletokens_generated.go` -- cheap and idempotent
        // to write per-file rather than tracking which packages actually
        // reference which token names via `styles={...}`; matches the
        // real, already-shipping convention (see
        // examples/ntx-form/guest/styletokens_generated.go).
        if (style_tokens.len > 0) {
            const styletokens_src = try StylingCodegen.generateGo(allocator, package_name, style_tokens);
            try entry.dir.writeFile(io, .{ .sub_path = "styletokens_generated.go", .data = styletokens_src });
        }
        processed += 1;
    }

    if (processed > 0) {
        const validated = try Validate.validateForExtension(allocator, io, "go", guest_dir);
        if (!validated.ok) return .{ .processed = processed, .err = .{ .message = validated.err.?.message } };
    }

    return .{
        .processed = processed,
        .binding_include_dirs = binding_include_dirs,
        .binding_lib_dirs = binding_lib_dirs,
        .binding_link = binding_link,
        .binding_zig_deps = binding_zig_deps,
        .binding_vendor_c_files = binding_vendor_c_files,
        .err = null,
    };
}

test "extractPackageName finds the real leading package declaration" {
    try std.testing.expectEqualStrings("main", extractPackageName("package main\n\nimport \"x\"\n").?);
    try std.testing.expectEqualStrings("components", extractPackageName("// doc\npackage components\n").?);
}

test "extractPackageName returns null with no package declaration" {
    try std.testing.expect(extractPackageName("just some text") == null);
}

test "extractPackageName skips a false match inside a leading comment's prose" {
    // Real fixture (examples/ntx-components/guest/page.go.ntx): a doc
    // comment mentioning "package" mid-sentence used to be matched
    // instead of the real declaration on its own line below it.
    const src =
        \\// this component lives in the sibling `components` package (card.go.ntx)
        \\// for real reuse.
        \\package main
        \\
    ;
    try std.testing.expectEqualStrings("main", extractPackageName(src).?);
}

test "transpiles a single .go.ntx file in place and validates cleanly" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module preptest\n\ngo 1.23\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "page.go.ntx", .data =
        \\package main
        \\
        \\expose Page
        \\
        \\func Page(parent widgets.Container) error {
        \\  <Label>hi</Label>
        \\}
    });

    const outcome = try run(allocator, io, tmp.dir, &.{}, "", .full);
    try std.testing.expect(outcome.err == null);
    try std.testing.expectEqual(@as(usize, 1), outcome.processed);

    const generated = try tmp.dir.readFileAlloc(io, "page.natyv.go", allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, generated, "package main") != null);
    try std.testing.expect(std.mem.indexOf(u8, generated, "widgets.CreateLabel") != null);

    const logic = try tmp.dir.readFileAlloc(io, "page.go", allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, logic, "expose Page") == null);
    try std.testing.expect(std.mem.indexOf(u8, logic, "return natyvBuildPage(parent)") != null);
}

test "transpiles nested .go.ntx files across sub-packages, output lands in each one's own directory" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // The generated output references `natyv/sdk/widgets` (see
    // `Codegen.zig`) -- a real `replace` is needed for `go list` to
    // resolve it, exactly like every real example's own `go.mod` already
    // has (`../../../sdk/go`, relative to `guest/`). An absolute path
    // computed from the real process cwd (always the repo root under
    // `zig build test`) is more robust here than a relative one, since a
    // relative path would also need to account for `std.testing.tmpDir`'s
    // own nesting depth under `.zig-cache/tmp/`, an internal detail this
    // test shouldn't depend on.
    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const go_mod = try std.fmt.allocPrint(allocator, "module preptest\n\ngo 1.23\n\nrequire (\n\tnatyv/sdk v0.0.0\n\tgithub.com/extism/go-pdk v1.1.3\n)\n\nreplace natyv/sdk => {s}/sdk/go\n", .{cwd_path});
    try tmp.dir.writeFile(io, .{ .sub_path = "go.mod", .data = go_mod });
    // `sdk/go/widgets` itself imports `github.com/extism/go-pdk`, a real
    // external module -- matches every real example's own `go.sum`
    // exactly, so `go list` can resolve it from the local module cache
    // without needing network access.
    try tmp.dir.writeFile(io, .{ .sub_path = "go.sum", .data =
        \\github.com/extism/go-pdk v1.1.3 h1:hfViMPWrqjN6u67cIYRALZTZLk/enSPpNKa+rZ9X2SQ=
        \\github.com/extism/go-pdk v1.1.3/go.mod h1:Gz+LIU/YCKnKXhgge8yo5Yu1F/lbv7KtKFkiCSzW/P4=
        \\
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.go.ntx", .data =
        \\package main
        \\
        \\expose Page
        \\
        \\func Page(parent widgets.Container) error {
        \\  <Label>hi</Label>
        \\}
    });
    var sub = try tmp.dir.createDirPathOpen(io, "components", .{});
    defer sub.close(io);
    try sub.writeFile(io, .{ .sub_path = "card.go.ntx", .data =
        \\package components
        \\
        \\expose Card
        \\
        \\func Card(parent uint32) error {
        \\  <Label>hi</Label>
        \\}
    });

    const outcome = try run(allocator, io, tmp.dir, &.{}, "", .full);
    try std.testing.expect(outcome.err == null);
    try std.testing.expectEqual(@as(usize, 2), outcome.processed);

    const card_gen = try sub.readFileAlloc(io, "card.natyv.go", allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, card_gen, "package components") != null);
}

test "reports a clear, path-attributed error on a malformed .ntx file, without touching later files" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module preptest\n\ngo 1.23\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "bad.go.ntx", .data =
        \\package main
        \\
        \\expose Missing
    });

    const outcome = try run(allocator, io, tmp.dir, &.{}, "", .full);
    try std.testing.expect(outcome.err != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "bad.go.ntx") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "Missing") != null);
}

test "a non-.go.ntx extension is a clear, natyv-attributed 'not supported yet' error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "widget.rs.ntx", .data = "package main\n" });

    const outcome = try run(allocator, io, tmp.dir, &.{}, "", .full);
    try std.testing.expect(outcome.err != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "widget.rs.ntx") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "supported") != null);
}

test "a directory with no .ntx files at all processes zero files, no error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try tmp.dir.writeFile(io, .{ .sub_path = "main.go", .data = "package main\n\nfunc main() {}\n" });

    const outcome = try run(allocator, io, tmp.dir, &.{}, "", .full);
    try std.testing.expect(outcome.err == null);
    try std.testing.expectEqual(@as(usize, 0), outcome.processed);
}

test "a real .ntss stylesheet is discovered, resolved, and applied to both real consumers" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module preptest\n\ngo 1.23\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "styles.ntss", .data =
        \\spacer {
        \\  margin: 24
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "page.go.ntx", .data =
        \\package main
        \\
        \\expose Page
        \\
        \\func Page(parent widgets.Container) error {
        \\  <Label styles={spacer}>hi</Label>
        \\}
    });

    const outcome = try run(allocator, io, tmp.dir, &.{}, "", .full);
    try std.testing.expect(outcome.err == null);
    try std.testing.expectEqual(@as(usize, 1), outcome.processed);

    // Consumer 1: `ntx/Codegen.zig`'s margin-as-wrapper decision -- the
    // resolved `margin: 24` should have produced a real wrapper Container,
    // not silently dropped the way it was before real stylesheet
    // ingestion existed (the exact regression this closes).
    const generated = try tmp.dir.readFileAlloc(io, "page.natyv.go", allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, generated, "Padding = widgets.Padding{Left: 24, Right: 24, Top: 24, Bottom: 24}") != null);

    // Consumer 2: `styling/Codegen.zig`'s runtime `StyleTokens` map, now
    // written for real instead of never existing.
    const styletokens = try tmp.dir.readFileAlloc(io, "styletokens_generated.go", allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, styletokens, "\"spacer\": {") != null);
}

test "no .ntss file anywhere in the tree: unchanged behavior, no styletokens_generated.go" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module preptest\n\ngo 1.23\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "page.go.ntx", .data =
        \\package main
        \\
        \\expose Page
        \\
        \\func Page(parent widgets.Container) error {
        \\  <Label>hi</Label>
        \\}
    });

    const outcome = try run(allocator, io, tmp.dir, &.{}, "", .full);
    try std.testing.expect(outcome.err == null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(io, "styletokens_generated.go", allocator, .unlimited));
}

test "a second .ntss file anywhere in the tree is a clear, natyv-attributed error naming both paths" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "styles.ntss", .data = "spacer { margin: 24 }" });
    var sub = try tmp.dir.createDirPathOpen(io, "sub", .{});
    defer sub.close(io);
    try sub.writeFile(io, .{ .sub_path = "more.ntss", .data = "other { margin: 8 }" });

    const outcome = try run(allocator, io, tmp.dir, &.{}, "", .full);
    try std.testing.expect(outcome.err != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "styles.ntss") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "more.ntss") != null);
}

test "a malformed .ntss stylesheet is a clear, path-attributed parse error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "styles.ntss", .data = "broken {\n  margin 4\n}\n" });

    const outcome = try run(allocator, io, tmp.dir, &.{}, "", .full);
    try std.testing.expect(outcome.err != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "styles.ntss") != null);
}

test "a .ntss stylesheet with an unrecognized field is a clear, path-attributed resolve error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try tmp.dir.writeFile(io, .{ .sub_path = "styles.ntss", .data = "bad { boarder: 4 }" });

    const outcome = try run(allocator, io, tmp.dir, &.{}, "", .full);
    try std.testing.expect(outcome.err != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "styles.ntss") != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "boarder") != null);
}

test "Stage 2.7: natyv bind runs as run()'s own first step, real fixture entry produces real Go output" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const fixture_include_dir = try std.fs.path.join(allocator, &.{ cwd_path, "fixtures/bindgen" });
    const bindings = [_]Config.BindingEntry{.{
        .library = "fixture",
        .header = "fixture.h",
        .include_dirs = &.{fixture_include_dir},
        .functions = &.{"fixture_ping"},
    }};

    const outcome = try run(allocator, io, tmp.dir, &bindings, cwd_path, .full);
    defer {
        var bg = std.Io.Dir.cwd().openDir(io, "src/bindgen", .{}) catch unreachable;
        defer bg.close(io);
        bg.deleteFile(io, "fixture_bindings_generated.zig") catch {};
    }
    var src_dir_cleanup = try std.Io.Dir.cwd().openDir(io, "src", .{});
    defer {
        src_dir_cleanup.deleteFile(io, "BindingsGenerated.zig") catch {};
        src_dir_cleanup.close(io);
    }
    try std.testing.expect(outcome.err == null);
    try std.testing.expectEqual(@as(usize, 1), outcome.binding_include_dirs.len);

    const go_out = try tmp.dir.readFileAlloc(io, "fixture_bindings_generated.go", allocator, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, go_out, "func FixturePing(") != null);
}

test "Stage 2.7: .codegen_only mode runs bind but skips .ntx transpile entirely" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const fixture_include_dir = try std.fs.path.join(allocator, &.{ cwd_path, "fixtures/bindgen" });
    const bindings = [_]Config.BindingEntry{.{
        .library = "fixture",
        .header = "fixture.h",
        .include_dirs = &.{fixture_include_dir},
        .functions = &.{"fixture_ping"},
    }};

    try tmp.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module preptest\n\ngo 1.23\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "page.go.ntx", .data =
        \\package main
        \\
        \\expose Page
        \\
        \\func Page(parent widgets.Container) error {
        \\  <Label>hi</Label>
        \\}
    });

    const outcome = try run(allocator, io, tmp.dir, &bindings, cwd_path, .codegen_only);
    defer {
        var bg = std.Io.Dir.cwd().openDir(io, "src/bindgen", .{}) catch unreachable;
        defer bg.close(io);
        bg.deleteFile(io, "fixture_bindings_generated.zig") catch {};
    }
    var src_dir_cleanup = try std.Io.Dir.cwd().openDir(io, "src", .{});
    defer {
        src_dir_cleanup.deleteFile(io, "BindingsGenerated.zig") catch {};
        src_dir_cleanup.close(io);
    }
    try std.testing.expect(outcome.err == null);
    try std.testing.expectEqual(@as(usize, 0), outcome.processed);
    try std.testing.expectEqual(@as(usize, 1), outcome.binding_include_dirs.len);

    // Real bind output still lands (bind is never skipped by `.codegen_only`).
    _ = try tmp.dir.readFileAlloc(io, "fixture_bindings_generated.go", allocator, .unlimited);
    // But the .ntx file is genuinely untouched -- no .natyv.go/.go split at all.
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(io, "page.natyv.go", allocator, .unlimited));
}

test "Stage 2.7: a real bind failure surfaces as a clear PrepareError before any .ntx work happens" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    const fixture_include_dir = try std.fs.path.join(allocator, &.{ cwd_path, "fixtures/bindgen" });
    const bindings = [_]Config.BindingEntry{.{
        .library = "fixture",
        .header = "fixture.h",
        .include_dirs = &.{fixture_include_dir},
        .functions = &.{"this_function_does_not_exist"},
    }};

    try tmp.dir.writeFile(io, .{ .sub_path = "go.mod", .data = "module preptest\n\ngo 1.23\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "page.go.ntx", .data =
        \\package main
        \\
        \\expose Page
        \\
        \\func Page(parent widgets.Container) error {
        \\  <Label>hi</Label>
        \\}
    });

    const outcome = try run(allocator, io, tmp.dir, &bindings, cwd_path, .full);
    try std.testing.expect(outcome.err != null);
    try std.testing.expect(std.mem.indexOf(u8, outcome.err.?.message, "natyv bind:") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(io, "page.natyv.go", allocator, .unlimited));
}

test "Stage 2.7: an empty bindings list is a real no-op, run() behaves exactly as before" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    const allocator = std.testing.allocator;

    const outcome = try run(allocator, io, tmp.dir, &.{}, "", .codegen_only);
    try std.testing.expect(outcome.err == null);
    try std.testing.expectEqual(@as(usize, 0), outcome.processed);
    try std.testing.expectEqual(@as(usize, 0), outcome.binding_include_dirs.len);
}
