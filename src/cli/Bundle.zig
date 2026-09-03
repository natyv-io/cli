//! `natyv build`'s final sub-step (`.ntx` tooling Stage 7,
//! ~/.claude/plans/lexical-wishing-penguin.md): invokes a real
//! `zig build -Dembed-app-wasm=true` against natyv-core's own source tree
//! to produce one self-contained distributable binary with the dev's
//! compiled guest wasm embedded via `@embedFile` (see build.zig's
//! `embed-app-wasm` option and `src/assets/EmbeddedWasm{Present,Absent}.zig`).
//!
//! This needs natyv-core's own buildable source tree on disk somewhere --
//! `natyv_core_src` (the caller-supplied param below) resolves it the
//! same way `build.zig`'s own `extismPrefix()` already solves a
//! near-identical problem (an external dependency's location): a
//! compile-time-baked default (`build.zig`'s `-Dnatyv-core-src`, this
//! repo's own root for a local dev build), overridable at runtime via a
//! `NATYV_CORE_SRC` env var (see `main.zig`) -- not a fragile
//! self-locating guess, since Zig 0.16's stdlib has no
//! `selfExePath`-equivalent to guess with anyway (confirmed absent from
//! every relevant std file). Confirmed design, brought forward now
//! rather than deferred: the CLI and natyv-core are meant to always ship
//! *together* as one real package (Homebrew/Chocolatey/Scoop/a Linux
//! equivalent, not yet built) -- so a real future packaging "wrapper" is
//! nothing more than building natyv with `-Dnatyv-core-src=<wherever
//! that package installs natyv-core's source>`, then packaging the
//! result; no code here needs to change once that packaging exists.
//!
//! `@embedFile` can only ever reach a path inside its own module's root
//! (Zig 0.16 rejects paths escaping it -- confirmed while building
//! `src/assets/` originally), so the compiled wasm has to physically be
//! copied into natyv-core's own source tree, however briefly, before the
//! embed can work at all.
//!
//! On macOS, the final step wraps the built executable in a real `.app`
//! bundle (`<name>.app/Contents/{MacOS,Resources,Info.plist}`) instead of
//! dropping a flat binary straight into `dist_dir` -- a bare Unix
//! executable has no icon/Dock-identity concept at all on macOS (Finder
//! always shows the generic terminal-cog glyph for one), and every real
//! Mac app uses this exact structure regardless. A dev-supplied PNG (see
//! `Config.icon`) gets turned into a real `.icns` via `sips`+`iconutil`
//! (both ship standard on every Mac, matching this project's own
//! established "shell out to a real system tool rather than reimplement
//! it" precedent) -- no icon means the bundle just gets macOS's own
//! generic app icon rather than the previous bare-executable glyph.
//! Windows and Linux each have their own, structurally different real
//! mechanism, both built: Windows compiles a real `.ico` (see
//! `WindowsIcon.zig`) into the exe as a genuine PE resource via `build.zig`'s
//! `-Dwindows-icon-rc=` (needs to happen *before* the `zig build` call
//! below, unlike macOS/Linux's own post-build packaging); Linux ships the
//! icon inside its `AppImage`'s own `AppDir` when `linux_package:
//! "appimage"` is set (see `PackageAppImage.zig`) -- a flat Linux binary
//! with no `linux_package` set has no icon concept to attach one to at all,
//! same as before.

const std = @import("std");
const Io = std.Io;
const PackageAppImage = @import("PackageAppImage.zig");
const WindowsIcon = @import("WindowsIcon.zig");

/// Which OS the *target being built* is, not the natyv CLI's own compile
/// target (`builtin.target.os.tag`, which used to drive this file's own
/// macOS-`.app`-vs-flat-binary branching -- correct only by accident, back
/// when a single `natyv build` invocation could only ever produce a binary
/// for whatever OS it was itself running on). Now that `compile_targets`
/// lets one host cross-compile for more than one OS in a single `natyv
/// build` run (see `cli/main.zig`/`cli/CompileTargets.zig`), the caller
/// resolves this explicitly per target instead.
pub const TargetOs = enum { macos, windows, linux };

pub const BundleError = struct {
    message: []const u8,
};

pub const Result = struct {
    ok: bool,
    err: ?BundleError,
};

/// `natyv_core_src` is a real natyv-core checkout's root -- callers
/// resolve this however they like (`main.zig` reads it from the
/// `NATYV_CORE_SRC` env var; kept as a plain parameter here, rather than
/// this function reading the env var itself, so tests can exercise real
/// error paths -- a missing/bad `NATYV_CORE_SRC`, a missing wasm file --
/// without needing real process-wide env var mutation). `wasm_path` is
/// the dev's already-compiled guest wasm, resolved relative to the
/// process's own cwd. `dist_dir` is where the final binary lands
/// (already created by the caller); `output_name` is what it gets
/// renamed to there (dropping Zig's own default `bin/<exe-name>`
/// nesting -- a real end-user distributable should be one flat,
/// sensibly-named file, not a path a dev has to go hunting for).
/// `has_bindings` passes `-Dhas-bindings=true` (Stage 2.2 of the binding
/// generator arc) so this build picks up the real `src/BindingsGenerated.zig`
/// `natyv bind` already wrote, instead of the empty `BindingsAbsent.zig`
/// stub -- same "app-specific option, only when actually needed" shape as
/// `-Dembed-app-wasm` itself. `binding_include_dirs`/`binding_lib_dirs`/
/// `binding_link` are already comma-joined (built by `cli/main.zig` from
/// `Bind.Outcome`'s own aggregated per-entry values) -- passed through
/// verbatim as `-Dbinding-include-dirs=`/`-Dbinding-lib-dirs=`/
/// `-Dbinding-link=` so `build.zig` can apply the exact same include/
/// library paths and linker flags the reflector's own scratch compile
/// already used against `src/BindingsGenerated.zig`'s per-entry
/// `@cInclude`s and real library symbol calls. Empty strings mean "add
/// nothing" and are simply omitted from argv.
///
/// `binding_zig_deps` (Stage 2.5) is a separate, differently-shaped
/// `name:artifact,...` list -- a `-zig`-mode entry links via the fetched
/// package's own build.zig (`b.dependency(name, ...).artifact(artifact)` +
/// `linkLibrary`, see `build.zig`), which flags alone can't express.
///
/// `sqlite_enabled` mirrors the app's own `conf.natyv.json` `sqlite.enabled`
/// exactly -- passed through to `build.zig`'s own `-Dsqlite` option so an
/// app that never sets it doesn't pay for vendored sqlite3's real compiled
/// size (a real, measured ~9.4MB Debug-build difference) in its own shipped
/// binary at all, not just a nominally-unused dependency.
///
/// `bundle_id` (`Config.effectiveBundleId`'s already-resolved result --
/// either the dev's real one or the synthesized `dev.natyv.<name>`
/// default) only matters on macOS. `icon_path` (`Config.icon`, resolved
/// relative to the config file's own directory, or `null`) matters on
/// macOS and Windows (and Linux, when `linux_package` is set) -- see this
/// file's own doc comment for each OS's real mechanism.
///
/// `config_path` is the app's own real `conf.natyv.json`, copied to
/// `embedded_config.json` the same way `wasm_path` is copied to
/// `embedded_app.wasm` just below -- a real bundled binary can't rely on
/// any particular cwd at launch (Finder/Launch Services never sets one
/// to the bundle's own directory), so `src/main.zig` reads this embedded
/// copy instead of a cwd-relative disk file whenever `-Dembed-app-wasm`
/// is set. See `EmbeddedWasmPresent.zig`'s own doc comment for the real
/// launch failure this fixes.
/// `target`/`target_os`: `null`/the host's own OS (today's existing
/// behavior, unchanged) unless the caller resolved a real
/// `compile_targets` entry via `CompileTargets.resolve` -- `target` (a raw
/// Zig triple, e.g. `"aarch64-linux-gnu"`) becomes a real `-Dtarget=` flag
/// below; `target_os` drives this function's own macOS/Linux branching
/// instead of `builtin.target.os.tag` (see `TargetOs`'s own doc comment
/// for why). `linux_package` (only meaningful when `target_os == .linux`)
/// is `Config.linux_package` verbatim -- `"appimage"` wraps the built
/// binary via `PackageAppImage.zig`, `null` ships the plain flat binary.
///
/// `cache_dir` (`~/.cache/natyv` today, hardcoded by the caller -- a real
/// `natyv cache --dir=` override is confirmed future, post-v1 work) is
/// where `zig build`'s own `.zig-cache`/`zig-pkg` directories get
/// redirected to via `--cache-dir`/`--global-cache-dir` below. Without
/// this, `zig build` writes those directly into `natyv_core_src` itself
/// (wherever it's invoked from) -- harmless for a normal project checkout
/// a dev already gitignores, but a real, confirmed problem the moment
/// `natyv_core_src` is a packaging-managed install location (a real
/// Homebrew-installed natyv-core directory grew to 2GB after one app
/// build) that's supposed to stay read-only after install.
pub fn run(allocator: std.mem.Allocator, io: Io, natyv_core_src: []const u8, wasm_path: []const u8, config_path: []const u8, dist_dir: Io.Dir, output_name: []const u8, has_bindings: bool, binding_include_dirs: []const u8, binding_lib_dirs: []const u8, binding_link: []const u8, binding_zig_deps: []const u8, binding_vendor_c_files: []const u8, has_textures: bool, sqlite_enabled: bool, bundle_id: []const u8, icon_path: ?[]const u8, target: ?[]const u8, target_os: TargetOs, linux_package: ?[]const u8, ca_certs_json: []const u8, cache_dir: []const u8, optimize_flag: []const u8) !Result {
    var core_dir = std.Io.Dir.cwd().openDir(io, natyv_core_src, .{}) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: could not open NATYV_CORE_SRC ('{s}'): {s}", .{ natyv_core_src, @errorName(e) }),
        } };
    };
    defer core_dir.close(io);

    core_dir.access(io, "build.zig", .{}) catch {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: NATYV_CORE_SRC ('{s}') doesn't look like a real natyv-core checkout (no build.zig found there)", .{natyv_core_src}),
        } };
    };

    const wasm_bytes = std.Io.Dir.cwd().readFileAlloc(io, wasm_path, allocator, .unlimited) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: could not read compiled wasm '{s}': {s}", .{ wasm_path, @errorName(e) }),
        } };
    };

    const config_bytes = std.Io.Dir.cwd().readFileAlloc(io, config_path, allocator, .unlimited) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: could not read '{s}': {s}", .{ config_path, @errorName(e) }),
        } };
    };

    var assets_dir = core_dir.openDir(io, "src/assets", .{}) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: could not open '{s}/src/assets': {s}", .{ natyv_core_src, @errorName(e) }),
        } };
    };
    defer assets_dir.close(io);
    try assets_dir.writeFile(io, .{ .sub_path = "embedded_app.wasm", .data = wasm_bytes });
    try assets_dir.writeFile(io, .{ .sub_path = "embedded_config.json", .data = config_bytes });
    try assets_dir.writeFile(io, .{ .sub_path = "embedded_ca_certs.json", .data = ca_certs_json });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dist_abs_len = try dist_dir.realPath(io, &path_buf);
    const dist_abs = path_buf[0..dist_abs_len];

    // Windows icon embedding: must happen *before* the `zig build` call
    // below, not in the post-build `target_os` switch like macOS/Linux's
    // own icon handling -- a `.rc`/`.ico` resource is compiled *into* the
    // exe by `build.zig` itself (`-Dwindows-icon-rc=`, see
    // `WindowsIcon.zig`'s own doc comment), not attached to an
    // already-built binary afterward the way `.app`/AppImage packaging
    // wraps one. The generated `.ico`/`.rc` live in a scratch directory
    // inside `dist_dir`, cleaned up unconditionally on the way out --
    // `build.zig` only ever needs them to exist for the duration of the one
    // `zig build` invocation below.
    var windows_icon_scratch_created = false;
    defer if (windows_icon_scratch_created) dist_dir.deleteTree(io, ".natyv-windows-icon-scratch") catch {};

    // Redirecting `zig build`'s own caches to `cache_dir` needs three real
    // pieces, not just the two documented flags -- confirmed the hard way
    // against natyv-core's own real dependency graph (SDL3's own nested
    // `libusb`/`fribidi` sub-dependencies): (1) `--cache-dir` correctly
    // redirects `.zig-cache`; (2) `--global-cache-dir` correctly redirects
    // the standard `<dir>/p/<hash>` package cache; but (3) natyv-core's
    // build graph *also* writes a real, separate `zig-pkg/<hash>`
    // directory relative to wherever `zig build` is invoked from,
    // unconditionally, regardless of either flag or their
    // `ZIG_*_CACHE_DIR` env var equivalents -- worked around with a real
    // symlink at `natyv_core_src/zig-pkg` pointing at the desired
    // location instead, so even an unconditional relative write lands
    // where intended. Also confirmed the hard way: a *custom* (non-
    // default) global cache dir hits a real Zig bug fetching a `.zip`-
    // packaged dependency specifically (fribidi's `.tar.gz` fetches fine;
    // libusb's `.zip` fails with "failed to create temporary zip file:
    // FileNotFound") unless its own `tmp/`/`p/` subdirectories already
    // exist -- pre-created below rather than left for `zig` to create
    // lazily.
    const zig_cache_dir = try std.fs.path.join(allocator, &.{ cache_dir, "zig-cache" });
    const zig_global_cache_dir = try std.fs.path.join(allocator, &.{ cache_dir, "zig-global-cache" });
    const zig_pkg_dir = try std.fs.path.join(allocator, &.{ cache_dir, "zig-pkg" });
    {
        var d_dir = try std.Io.Dir.cwd().createDirPathOpen(io, zig_cache_dir, .{});
        d_dir.close(io);
    }
    // `tmp/`/`p/` need pre-creating under *both* real package-cache
    // locations (`zig_global_cache_dir`, the documented `--global-cache-
    // dir` target, and `zig_pkg_dir`, the symlinked one) -- confirmed the
    // hard way that omitting either one still reproduces the same real
    // "failed to create temporary zip file" error the moment a `.zip`-
    // packaged dependency's fetch happens to land in the one missing its
    // own `tmp/`.
    for ([_][]const u8{ zig_global_cache_dir, zig_pkg_dir }) |base| {
        for ([_][]const u8{ "tmp", "p" }) |sub| {
            var sub_dir = try std.Io.Dir.cwd().createDirPathOpen(io, try std.fs.path.join(allocator, &.{ base, sub }), .{});
            sub_dir.close(io);
        }
    }
    core_dir.symLink(io, zig_pkg_dir, "zig-pkg", .{ .is_directory = true }) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };

    var argv: std.ArrayList([]const u8) = .empty;
    // `install-core`, not the bare default step -- the default "install"
    // step installs every artifact in natyv-core's build graph, including
    // the `natyv` CLI itself, which would leave a stray, useless second
    // binary inside the app's own bundled output (confirmed by actually
    // running a bundle and inspecting what came out).
    try argv.appendSlice(allocator, &.{ "zig", "build", "install-core", "-Dembed-app-wasm=true", optimize_flag, "--prefix", dist_abs, "--cache-dir", zig_cache_dir, "--global-cache-dir", zig_global_cache_dir });
    if (target) |t| try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Dtarget={s}", .{t}));
    if (has_bindings) try argv.append(allocator, "-Dhas-bindings=true");
    if (binding_include_dirs.len > 0) try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Dbinding-include-dirs={s}", .{binding_include_dirs}));
    if (binding_lib_dirs.len > 0) try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Dbinding-lib-dirs={s}", .{binding_lib_dirs}));
    if (binding_link.len > 0) try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Dbinding-link={s}", .{binding_link}));
    if (binding_zig_deps.len > 0) try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Dbinding-zig-deps={s}", .{binding_zig_deps}));
    if (binding_vendor_c_files.len > 0) try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Dbinding-vendor-c-files={s}", .{binding_vendor_c_files}));
    if (has_textures) try argv.append(allocator, "-Dhas-textures=true");
    // Always passed explicitly, not just when true (unlike `has_bindings`/
    // `has_textures` above) -- `build.zig`'s own `-Dsqlite` option defaults
    // to `true` for local dev/testing convenience, so a disabled app needs
    // an explicit `-Dsqlite=false` to actually override that default and
    // get the real binary-size win of not compiling vendored sqlite3 in at
    // all. Mirrors the app's own `conf.natyv.json` `sqlite.enabled` exactly.
    try argv.append(allocator, if (sqlite_enabled) "-Dsqlite=true" else "-Dsqlite=false");

    if (target_os == .windows) {
        if (icon_path) |icon| {
            var scratch_dir = dist_dir.createDirPathOpen(io, ".natyv-windows-icon-scratch", .{}) catch |e| {
                return .{ .ok = false, .err = .{
                    .message = try std.fmt.allocPrint(allocator, "natyv build: could not create '{s}/.natyv-windows-icon-scratch': {s}", .{ dist_abs, @errorName(e) }),
                } };
            };
            defer scratch_dir.close(io);
            windows_icon_scratch_created = true;

            var scratch_path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const scratch_abs_len = try scratch_dir.realPath(io, &scratch_path_buf);
            const scratch_abs = scratch_path_buf[0..scratch_abs_len];

            const icon_result = try WindowsIcon.build(allocator, io, icon, scratch_dir, scratch_abs);
            if (icon_result.err) |e| return .{ .ok = false, .err = .{ .message = e.message } };
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Dwindows-icon-rc={s}", .{icon_result.rc_path}));
        }
    }

    const result = std.process.run(allocator, io, .{
        .argv = argv.items,
        .cwd = .{ .dir = core_dir },
    }) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: could not run 'zig build' in NATYV_CORE_SRC ('{s}'): {s}", .{ natyv_core_src, @errorName(e) }),
        } };
    };
    defer allocator.free(result.stdout);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                defer allocator.free(result.stderr);
                return .{ .ok = false, .err = .{
                    .message = try std.fmt.allocPrint(allocator, "natyv build: bundling failed (zig build exit code {d}):\n{s}{s}", .{ code, result.stdout, result.stderr }),
                } };
            }
            allocator.free(result.stderr);
        },
        else => |term| {
            defer allocator.free(result.stderr);
            return .{ .ok = false, .err = .{
                .message = try std.fmt.allocPrint(allocator, "natyv build: bundling exited abnormally ({any}):\n{s}{s}", .{ term, result.stdout, result.stderr }),
            } };
        },
    }

    // Zig's own install step always produces `<prefix>/bin/natyv-core`
    // regardless of OS -- what happens to it from here differs.
    var bin_dir = dist_dir.openDir(io, "bin", .{}) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: bundling reported success but '{s}/bin' wasn't created: {s}", .{ dist_abs, @errorName(e) }),
        } };
    };
    defer bin_dir.close(io);

    switch (target_os) {
        .macos => {
            const app_result = try buildMacosApp(allocator, io, dist_dir, dist_abs, bin_dir, output_name, bundle_id, icon_path);
            if (app_result.err) |e| return .{ .ok = false, .err = e };
        },
        .windows => {
            // Icon embedding itself already happened above, before `zig
            // build` ran (see this file's own comment there for why it has
            // to happen pre-build, unlike macOS/Linux's post-build
            // packaging) -- nothing left to do here but move the already
            // icon-bearing exe out of Zig's own `bin/` directory.
            bin_dir.rename("natyv-core.exe", dist_dir, try std.fmt.allocPrint(allocator, "{s}.exe", .{output_name}), io) catch |e| {
                return .{ .ok = false, .err = .{
                    .message = try std.fmt.allocPrint(allocator, "natyv build: bundling reported success but the built binary couldn't be moved out of '{s}/bin': {s}", .{ dist_abs, @errorName(e) }),
                } };
            };
            // A real, un-stripped windows-gnu build also produces a real
            // ~30MB `.pdb` (debug symbols) -- moved out alongside the
            // `.exe` (real, potentially useful for a dev debugging a crash
            // report, not just discarded) rather than left behind, since a
            // leftover file is exactly what makes the final `bin`
            // directory non-empty and silently defeats this function's
            // own cleanup `deleteDir` call below (confirmed the hard way:
            // a real `dist/windows-x64/bin/natyv-core.pdb` left sitting
            // there, found by actually running a multi-target build and
            // inspecting the output, not predicted upfront). A soft
            // `catch` rather than a hard error -- unlike the `.exe` itself,
            // a `.pdb`'s existence depends on optimize mode/future stripping
            // support this function has no control over, so its absence
            // shouldn't fail an otherwise-successful build.
            bin_dir.rename("natyv-core.pdb", dist_dir, try std.fmt.allocPrint(allocator, "{s}.pdb", .{output_name}), io) catch {};
        },
        .linux => {
            bin_dir.rename("natyv-core", dist_dir, output_name, io) catch |e| {
                return .{ .ok = false, .err = .{
                    .message = try std.fmt.allocPrint(allocator, "natyv build: bundling reported success but the built binary couldn't be moved out of '{s}/bin': {s}", .{ dist_abs, @errorName(e) }),
                } };
            };
            if (linux_package) |pkg| {
                if (std.mem.eql(u8, pkg, "appimage")) {
                    const pkg_result = try PackageAppImage.run(allocator, io, dist_dir, dist_abs, output_name, bundle_id, icon_path, target);
                    if (pkg_result.err) |e| return .{ .ok = false, .err = .{ .message = e.message } };
                } else {
                    return .{ .ok = false, .err = .{
                        .message = try std.fmt.allocPrint(allocator, "natyv build: unrecognized linux_package '{s}' (only \"appimage\" is supported)", .{pkg}),
                    } };
                }
            }
        },
    }
    dist_dir.deleteDir(io, "bin") catch {};

    return .{ .ok = true, .err = null };
}

/// Builds `<dist_dir>/<output_name>.app/Contents/{MacOS,Resources,Info.plist}`
/// and moves the freshly built executable into `Contents/MacOS`. Kept
/// separate from `run` so the macOS-only control flow (several fallible
/// steps in sequence, each needing its own clear error) doesn't nest
/// inside `run`'s own already-long body.
fn buildMacosApp(allocator: std.mem.Allocator, io: Io, dist_dir: Io.Dir, dist_abs: []const u8, bin_dir: Io.Dir, output_name: []const u8, bundle_id: []const u8, icon_path: ?[]const u8) !Result {
    const app_dir_name = try std.fmt.allocPrint(allocator, "{s}.app", .{output_name});
    const contents_rel = try std.fs.path.join(allocator, &.{ app_dir_name, "Contents" });

    var contents_dir = dist_dir.createDirPathOpen(io, contents_rel, .{}) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: could not create '{s}/{s}': {s}", .{ dist_abs, contents_rel, @errorName(e) }),
        } };
    };
    defer contents_dir.close(io);

    var macos_dir = contents_dir.createDirPathOpen(io, "MacOS", .{}) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: could not create '{s}/{s}/MacOS': {s}", .{ dist_abs, contents_rel, @errorName(e) }),
        } };
    };
    defer macos_dir.close(io);

    var resources_dir = contents_dir.createDirPathOpen(io, "Resources", .{}) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: could not create '{s}/{s}/Resources': {s}", .{ dist_abs, contents_rel, @errorName(e) }),
        } };
    };
    defer resources_dir.close(io);

    bin_dir.rename("natyv-core", macos_dir, output_name, io) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: bundling reported success but the built binary couldn't be moved into '{s}/{s}/MacOS': {s}", .{ dist_abs, contents_rel, @errorName(e) }),
        } };
    };

    var has_icon = false;
    if (icon_path) |icon| {
        std.Io.Dir.cwd().access(io, icon, .{}) catch |e| {
            return .{ .ok = false, .err = .{
                .message = try std.fmt.allocPrint(allocator, "natyv build: configured icon '{s}' could not be read: {s}", .{ icon, @errorName(e) }),
            } };
        };

        var res_path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const resources_abs_len = try resources_dir.realPath(io, &res_path_buf);
        const resources_abs = res_path_buf[0..resources_abs_len];

        _ = resources_dir.createDirPathOpen(io, "AppIcon.iconset", .{}) catch |e| {
            return .{ .ok = false, .err = .{
                .message = try std.fmt.allocPrint(allocator, "natyv build: could not create '{s}/AppIcon.iconset': {s}", .{ resources_abs, @errorName(e) }),
            } };
        };

        // The macOS-documented `.iconset` naming convention -- 10 exact
        // filenames `iconutil` expects, covering every size Finder/Dock/
        // Launchpad/the app switcher actually draw at.
        const icon_sizes = [_]struct { px: u32, name: []const u8 }{
            .{ .px = 16, .name = "icon_16x16.png" },
            .{ .px = 32, .name = "icon_16x16@2x.png" },
            .{ .px = 32, .name = "icon_32x32.png" },
            .{ .px = 64, .name = "icon_32x32@2x.png" },
            .{ .px = 128, .name = "icon_128x128.png" },
            .{ .px = 256, .name = "icon_128x128@2x.png" },
            .{ .px = 256, .name = "icon_256x256.png" },
            .{ .px = 512, .name = "icon_256x256@2x.png" },
            .{ .px = 512, .name = "icon_512x512.png" },
            .{ .px = 1024, .name = "icon_512x512@2x.png" },
        };
        for (icon_sizes) |entry| {
            const out_path = try std.fmt.allocPrint(allocator, "{s}/AppIcon.iconset/{s}", .{ resources_abs, entry.name });
            const px_str = try std.fmt.allocPrint(allocator, "{d}", .{entry.px});
            if (try runTool(allocator, io, &.{ "sips", "-z", px_str, px_str, icon, "--out", out_path }, "generating icon size")) |e| {
                resources_dir.deleteTree(io, "AppIcon.iconset") catch {};
                return .{ .ok = false, .err = e };
            }
        }

        const icns_path = try std.fmt.allocPrint(allocator, "{s}/AppIcon.icns", .{resources_abs});
        const iconset_path = try std.fmt.allocPrint(allocator, "{s}/AppIcon.iconset", .{resources_abs});
        if (try runTool(allocator, io, &.{ "iconutil", "-c", "icns", iconset_path, "-o", icns_path }, "packing .icns")) |e| {
            resources_dir.deleteTree(io, "AppIcon.iconset") catch {};
            return .{ .ok = false, .err = e };
        }
        resources_dir.deleteTree(io, "AppIcon.iconset") catch {};
        has_icon = true;
    }

    const plist = try buildInfoPlist(allocator, output_name, bundle_id, has_icon);
    contents_dir.writeFile(io, .{ .sub_path = "Info.plist", .data = plist }) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: could not write '{s}/{s}/Info.plist': {s}", .{ dist_abs, contents_rel, @errorName(e) }),
        } };
    };

    return .{ .ok = true, .err = null };
}

/// Runs one real subprocess (`sips`/`iconutil`) and returns `null` on
/// success or a natyv-attributed `BundleError` (real stderr surfaced
/// verbatim) otherwise -- shared by every real-tool invocation in
/// `buildMacosApp` above so the same three-way exit-code check isn't
/// duplicated per call site.
fn runTool(allocator: std.mem.Allocator, io: Io, argv: []const []const u8, what: []const u8) !?BundleError {
    const result = std.process.run(allocator, io, .{ .argv = argv }) catch |e| {
        return .{ .message = try std.fmt.allocPrint(allocator, "natyv build: could not run '{s}' ({s}): {s}", .{ argv[0], what, @errorName(e) }) };
    };
    defer allocator.free(result.stdout);
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                defer allocator.free(result.stderr);
                return .{ .message = try std.fmt.allocPrint(allocator, "natyv build: {s} failed (exit code {d}):\n{s}{s}", .{ what, code, result.stdout, result.stderr }) };
            }
            allocator.free(result.stderr);
        },
        else => |term| {
            defer allocator.free(result.stderr);
            return .{ .message = try std.fmt.allocPrint(allocator, "natyv build: {s} exited abnormally ({any}):\n{s}{s}", .{ what, term, result.stdout, result.stderr }) };
        },
    }
    return null;
}

/// Escapes the five real XML metacharacters -- `name`/`bundle_id` are
/// dev-supplied and end up as literal text inside a generated XML plist.
fn xmlEscapeAlloc(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            '\'' => try out.appendSlice(allocator, "&apos;"),
            else => try out.append(allocator, c),
        }
    }
    // `toOwnedSlice`, not `.items` directly -- `ArrayList`'s backing
    // buffer routinely over-allocates past `.items.len` for growth, and
    // `allocator.free` on a slice shorter than the real original
    // allocation is invalid (confirmed the hard way: a real
    // DebugAllocator "Invalid free" panic in `buildInfoPlist`'s own
    // `defer allocator.free(...)` calls before this fix). `toOwnedSlice`
    // shrinks to exactly the used length first, so a plain `free` on the
    // result is always valid.
    return out.toOwnedSlice(allocator);
}

/// A minimal, hand-built `Info.plist` -- no plist library needed, the
/// real key set a bundled app needs is small and fixed. `CFBundleIconFile`
/// is only included when `has_icon` -- macOS falls back to its own
/// generic app icon when the key is simply absent, no placeholder needed.
fn buildInfoPlist(allocator: std.mem.Allocator, name: []const u8, bundle_id: []const u8, has_icon: bool) ![]const u8 {
    const escaped_name = try xmlEscapeAlloc(allocator, name);
    defer allocator.free(escaped_name);
    const escaped_id = try xmlEscapeAlloc(allocator, bundle_id);
    defer allocator.free(escaped_id);
    const icon_block = if (has_icon) "    <key>CFBundleIconFile</key>\n    <string>AppIcon</string>\n" else "";
    return std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\    <key>CFBundleExecutable</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleIdentifier</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleName</key>
        \\    <string>{s}</string>
        \\    <key>CFBundleDisplayName</key>
        \\    <string>{s}</string>
        \\    <key>CFBundlePackageType</key>
        \\    <string>APPL</string>
        \\    <key>CFBundleShortVersionString</key>
        \\    <string>1.0</string>
        \\    <key>CFBundleVersion</key>
        \\    <string>1</string>
        \\    <key>CFBundleInfoDictionaryVersion</key>
        \\    <string>6.0</string>
        \\    <key>NSHighResolutionCapable</key>
        \\    <true/>
        \\{s}</dict>
        \\</plist>
        \\
    , .{ escaped_name, escaped_id, escaped_name, escaped_name, icon_block });
}

test "a NATYV_CORE_SRC that doesn't exist is a clear error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;

    const result = try run(std.testing.allocator, io, "/definitely/not/a/real/path", "app.wasm", "conf.natyv.json", tmp.dir, "myapp", false, "", "", "", "", "", false, true, "dev.natyv.myapp", null, null, .macos, null, "", "/tmp/natyv-test-cache", "-Doptimize=Debug");
    defer if (result.err) |e| std.testing.allocator.free(e.message);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "NATYV_CORE_SRC") != null);
}

test "a NATYV_CORE_SRC with no build.zig is a clear error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    var not_core = try tmp.dir.createDirPathOpen(io, "not-natyv-core", .{});
    defer not_core.close(io);

    const cwd_path = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd_path);
    // `std.testing.tmpDir` resolves to `<cwd>/.zig-cache/tmp/<sub_path>`
    // -- an absolute path built from the real cwd avoids depending on
    // that nesting depth, same reasoning Prepare.zig's own tmpDir-based
    // go.mod tests already established.
    const abs_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}/not-natyv-core", .{ cwd_path, tmp.sub_path });
    defer std.testing.allocator.free(abs_path);

    const result = try run(std.testing.allocator, io, abs_path, "app.wasm", "conf.natyv.json", tmp.dir, "myapp", false, "", "", "", "", "", false, true, "dev.natyv.myapp", null, null, .macos, null, "", "/tmp/natyv-test-cache", "-Doptimize=Debug");
    defer if (result.err) |e| std.testing.allocator.free(e.message);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "build.zig") != null);
}

test "a missing compiled wasm file is a clear error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.createDirPath(io, "src/assets");

    const cwd_path = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd_path);
    const abs_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_path, tmp.sub_path });
    defer std.testing.allocator.free(abs_path);

    const result = try run(std.testing.allocator, io, abs_path, "/definitely/not/a/real/wasm/path.wasm", "conf.natyv.json", tmp.dir, "myapp", false, "", "", "", "", "", false, true, "dev.natyv.myapp", null, null, .macos, null, "", "/tmp/natyv-test-cache", "-Doptimize=Debug");
    defer if (result.err) |e| std.testing.allocator.free(e.message);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "compiled wasm") != null);
}

test "a missing config file is a clear error" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.createDirPath(io, "src/assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "app.wasm", .data = "" });

    const cwd_path = try std.process.currentPathAlloc(io, std.testing.allocator);
    defer std.testing.allocator.free(cwd_path);
    const abs_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_path, tmp.sub_path });
    defer std.testing.allocator.free(abs_path);
    const wasm_abs = try std.fmt.allocPrint(std.testing.allocator, "{s}/app.wasm", .{abs_path});
    defer std.testing.allocator.free(wasm_abs);

    const result = try run(std.testing.allocator, io, abs_path, wasm_abs, "/definitely/not/a/real/conf.natyv.json", tmp.dir, "myapp", false, "", "", "", "", "", false, true, "dev.natyv.myapp", null, null, .macos, null, "", "/tmp/natyv-test-cache", "-Doptimize=Debug");
    defer if (result.err) |e| std.testing.allocator.free(e.message);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "conf.natyv.json") != null);
}

test "buildInfoPlist: no icon omits CFBundleIconFile" {
    const allocator = std.testing.allocator;
    const plist = try buildInfoPlist(allocator, "MyApp", "dev.natyv.myapp", false);
    defer allocator.free(plist);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<string>MyApp</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<string>dev.natyv.myapp</string>") != null);
    try std.testing.expect(std.mem.indexOf(u8, plist, "CFBundleIconFile") == null);
}

test "buildInfoPlist: an icon includes CFBundleIconFile pointing at AppIcon" {
    const allocator = std.testing.allocator;
    const plist = try buildInfoPlist(allocator, "MyApp", "dev.natyv.myapp", true);
    defer allocator.free(plist);
    try std.testing.expect(std.mem.indexOf(u8, plist, "<key>CFBundleIconFile</key>\n    <string>AppIcon</string>") != null);
}

test "buildInfoPlist: name/bundle_id containing XML metacharacters are escaped" {
    const allocator = std.testing.allocator;
    const plist = try buildInfoPlist(allocator, "Foo & Bar's <App>", "dev.natyv.foo", false);
    defer allocator.free(plist);
    try std.testing.expect(std.mem.indexOf(u8, plist, "Foo &amp; Bar&apos;s &lt;App&gt;") != null);
    // The raw, unescaped text should never appear anywhere in the output.
    try std.testing.expect(std.mem.indexOf(u8, plist, "Foo & Bar's <App>") == null);
}
