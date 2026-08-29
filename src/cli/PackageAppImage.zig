//! Wraps a just-built Linux binary into a real, distributable `.AppImage`
//! (`conf.natyv.json`'s `linux_package: "appimage"`, see `Config.zig`).
//! Full design + real proof (a genuine `.AppImage` built entirely on a Mac,
//! transferred to and run successfully on a real Ubuntu ARM64 VM) lives in
//! the `natyv-linux-appimage-packaging` memory -- this is that proven
//! design wired into `natyv build` for real.
//!
//! **The split, worth being explicit about**: an AppImage is a real
//! executable stub (a genuine native ELF binary, vendored per-architecture
//! under `src/cli/assets/appimage_runtime_*` -- official
//! `AppImage/type2-runtime` release builds, small enough to commit
//! directly rather than fetch via `build.zig.zon`, which expects a
//! tarball, not a bare binary) with a
//! SquashFS filesystem image appended. This file builds that SquashFS
//! image by calling a real, embedded Extism plugin (`appimage_packer.wasm`,
//! `src/cli/assets/` -- a separate directory from natyv-core's own
//! `src/assets/`, since `@embedFile` can't cross a module's own root and
//! `cli_module`'s root is `src/cli/`, not `src/` -- compiled from the Rust
//! source under `tools/appimage-packer/`, a small wrapper around a
//! WASI-patched fork of the `backhand` crate) via the real Extism C API
//! (`AppImageC.zig`), then
//! concatenates the vendored runtime stub onto the front. The WASM plugin
//! is a *build-time-only* tool run on the dev's own machine -- it plays no
//! role in the shipped artifact itself, unlike the runtime stub, which is
//! literally part of the file that ships.
//!
//! **Only the permission metadata crosses the plugin-call boundary, not
//! file content.** The plugin's real input is a small JSON payload
//! (`{src_root, out_path, entries: [{path, mode, is_dir}]}`) -- real file
//! bytes are read by the plugin itself via a real Extism `allowed_paths`
//! grant over the AppDir this function builds, the same mechanism that
//! made the spike's `wasmtime --dir`/`extism call --allow-path` flags work.

const std = @import("std");
const Io = std.Io;
const c = @import("AppImageC.zig").c;

const appimage_packer_wasm = @embedFile("assets/appimage_packer.wasm");

const runtime_aarch64 = @embedFile("assets/appimage_runtime_aarch64");
const runtime_x86_64 = @embedFile("assets/appimage_runtime_x86_64");

pub const PackageError = struct {
    message: []const u8,
};

pub const Result = struct {
    ok: bool,
    err: ?PackageError,
};

/// `dist_dir`/`dist_abs`: same directory `Bundle.run` just placed the flat
/// Linux binary into. `output_name`: that binary's real filename.
/// `bundle_id`/`icon_path`: same values `Bundle.run` already resolved for
/// macOS -- reused here for the `.desktop` file's `Icon=`/naming, since
/// the same source PNG feeds every platform's icon (see `Config.icon`'s
/// own doc comment). `target`: the raw Zig triple `Bundle.run` was given
/// (or `null` for a native build) -- used only to pick which vendored
/// runtime architecture matches; irrelevant to everything else here.
pub fn run(allocator: std.mem.Allocator, io: Io, dist_dir: Io.Dir, dist_abs: []const u8, output_name: []const u8, bundle_id: []const u8, icon_path: ?[]const u8, target: ?[]const u8) !Result {
    _ = bundle_id; // not yet used in the .desktop file below -- reserved for a future StartupWMClass-style field.

    const runtime = pickRuntime(target);

    const scratch_rel = ".appimage-scratch";
    dist_dir.deleteTree(io, scratch_rel) catch {};
    var scratch_dir = dist_dir.createDirPathOpen(io, scratch_rel, .{}) catch |e| {
        return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv build: could not create AppImage scratch dir under '{s}': {s}", .{ dist_abs, @errorName(e) }) } };
    };
    defer scratch_dir.close(io);
    defer dist_dir.deleteTree(io, scratch_rel) catch {};

    var appdir = scratch_dir.createDirPathOpen(io, "AppDir", .{}) catch |e| {
        return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv build: could not create AppDir: {s}", .{@errorName(e)}) } };
    };
    defer appdir.close(io);

    var out_dir = scratch_dir.createDirPathOpen(io, "out", .{}) catch |e| {
        return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv build: could not create AppImage output scratch dir: {s}", .{@errorName(e)}) } };
    };
    defer out_dir.close(io);

    var entries: std.ArrayList(Entry) = .empty;

    // AppRun -- the real entry point every AppImage runtime execs after
    // mounting/extracting the payload. `readlink -f` resolves symlinks so
    // this works whether the runtime mounts via FUSE or falls back to a
    // plain extract-to-tmp.
    const apprun_contents = try std.fmt.allocPrint(allocator,
        \\#!/bin/sh
        \\HERE="$(dirname "$(readlink -f "${{0}}")")"
        \\exec "${{HERE}}/usr/bin/{s}" "$@"
        \\
    , .{output_name});
    appdir.writeFile(io, .{ .sub_path = "AppRun", .data = apprun_contents, .flags = .{ .permissions = mode(0o755) } }) catch |e| {
        return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv build: could not write AppRun: {s}", .{@errorName(e)}) } };
    };
    try entries.append(allocator, .{ .path = "AppRun", .file_mode = 0o755, .is_dir = false });

    // The real, already-built binary Bundle.run's Linux branch just placed
    // at `<dist_abs>/<output_name>` -- copied in (not moved) since Bundle
    // still needs it to remain the real top-level dist artifact regardless
    // of whether AppImage packaging succeeds or fails.
    try entries.append(allocator, .{ .path = "usr", .file_mode = 0o755, .is_dir = true });
    try entries.append(allocator, .{ .path = "usr/bin", .file_mode = 0o755, .is_dir = true });
    var usr_bin = appdir.createDirPathOpen(io, "usr/bin", .{}) catch |e| {
        return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv build: could not create AppDir/usr/bin: {s}", .{@errorName(e)}) } };
    };
    defer usr_bin.close(io);
    const bin_bytes = dist_dir.readFileAlloc(io, output_name, allocator, .unlimited) catch |e| {
        return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv build: could not read already-built binary '{s}' for AppImage packaging: {s}", .{ output_name, @errorName(e) }) } };
    };
    usr_bin.writeFile(io, .{ .sub_path = output_name, .data = bin_bytes, .flags = .{ .permissions = mode(0o755) } }) catch |e| {
        return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv build: could not copy binary into AppDir: {s}", .{@errorName(e)}) } };
    };
    try entries.append(allocator, .{ .path = try std.fmt.allocPrint(allocator, "usr/bin/{s}", .{output_name}), .file_mode = 0o755, .is_dir = false });

    var has_icon = false;
    if (icon_path) |icon| {
        std.Io.Dir.cwd().access(io, icon, .{}) catch |e| {
            return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv build: configured icon '{s}' could not be read: {s}", .{ icon, @errorName(e) }) } };
        };
        const icon_bytes = std.Io.Dir.cwd().readFileAlloc(io, icon, allocator, .unlimited) catch |e| {
            return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv build: could not read icon '{s}': {s}", .{ icon, @errorName(e) }) } };
        };
        const icon_name = try std.fmt.allocPrint(allocator, "{s}.png", .{output_name});
        appdir.writeFile(io, .{ .sub_path = icon_name, .data = icon_bytes, .flags = .{ .permissions = mode(0o644) } }) catch |e| {
            return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv build: could not write icon into AppDir: {s}", .{@errorName(e)}) } };
        };
        try entries.append(allocator, .{ .path = icon_name, .file_mode = 0o644, .is_dir = false });
        has_icon = true;
    }

    const desktop_contents = try buildDesktopFile(allocator, output_name, has_icon);
    appdir.writeFile(io, .{ .sub_path = try std.fmt.allocPrint(allocator, "{s}.desktop", .{output_name}), .data = desktop_contents, .flags = .{ .permissions = mode(0o644) } }) catch |e| {
        return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv build: could not write .desktop file: {s}", .{@errorName(e)}) } };
    };
    try entries.append(allocator, .{ .path = try std.fmt.allocPrint(allocator, "{s}.desktop", .{output_name}), .file_mode = 0o644, .is_dir = false });

    var appdir_abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const appdir_abs_len = try appdir.realPath(io, &appdir_abs_buf);
    const appdir_abs = appdir_abs_buf[0..appdir_abs_len];

    var out_abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    const out_abs_len = try out_dir.realPath(io, &out_abs_buf);
    const out_abs = out_abs_buf[0..out_abs_len];

    const call_payload = try buildCallPayload(allocator, entries.items);
    const manifest_json = try buildManifest(allocator, appdir_abs, out_abs);

    var errmsg: [*c]u8 = null;
    const plugin = c.extism_plugin_new(manifest_json.ptr, manifest_json.len, null, 0, true, &errmsg);
    if (plugin == null) {
        defer if (errmsg != null) c.extism_plugin_new_error_free(errmsg);
        return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv build: could not load the AppImage-packing plugin: {s}", .{errmsg}) } };
    }
    defer c.extism_plugin_free(plugin);

    const rc = c.extism_plugin_call(plugin, "pack", call_payload.ptr, call_payload.len);
    if (rc != 0) {
        const err = c.extism_plugin_error(plugin);
        return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv build: AppImage packaging failed: {s}", .{err}) } };
    }

    const squashfs_bytes = out_dir.readFileAlloc(io, "app.squashfs", allocator, .unlimited) catch |e| {
        return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv build: AppImage packaging reported success but the squashfs image wasn't found: {s}", .{@errorName(e)}) } };
    };

    var final: std.ArrayList(u8) = .empty;
    try final.appendSlice(allocator, runtime);
    try final.appendSlice(allocator, squashfs_bytes);

    const appimage_name = try std.fmt.allocPrint(allocator, "{s}.AppImage", .{output_name});
    dist_dir.writeFile(io, .{ .sub_path = appimage_name, .data = final.items, .flags = .{ .permissions = mode(0o755) } }) catch |e| {
        return .{ .ok = false, .err = .{ .message = try std.fmt.allocPrint(allocator, "natyv build: could not write '{s}': {s}", .{ appimage_name, @errorName(e) }) } };
    };

    return .{ .ok = true, .err = null };
}

fn mode(m: std.posix.mode_t) Io.File.Permissions {
    return @enumFromInt(m);
}

const Entry = struct {
    path: []const u8,
    file_mode: u16,
    is_dir: bool,
};

/// Picks the real vendored runtime matching `target`'s architecture, or
/// the CLI's own native arch when `target` is `null` (a native build with
/// no explicit `compile_targets` entry) -- `natyv`'s own `compile_targets`
/// allowlist (`CompileTargets.zig`) only accepts `linux-arm64` today, but
/// a native x86_64 Linux host running `natyv build` with no
/// `compile_targets` set at all can still reach this code path, so both
/// real architectures need a real vendored runtime regardless.
fn pickRuntime(target: ?[]const u8) []const u8 {
    if (target) |t| {
        if (std.mem.indexOf(u8, t, "aarch64") != null) return runtime_aarch64;
        return runtime_x86_64;
    }
    return switch (@import("builtin").cpu.arch) {
        .aarch64 => runtime_aarch64,
        else => runtime_x86_64,
    };
}

fn buildDesktopFile(allocator: std.mem.Allocator, name: []const u8, has_icon: bool) ![]const u8 {
    const icon_line = if (has_icon) try std.fmt.allocPrint(allocator, "Icon={s}\n", .{name}) else "";
    defer if (has_icon) allocator.free(icon_line);
    return std.fmt.allocPrint(allocator,
        \\[Desktop Entry]
        \\Name={s}
        \\Exec={s}
        \\{s}Type=Application
        \\Categories=Utility;
        \\
    , .{ name, name, icon_line });
}

/// The plugin call's real input -- see this file's own doc comment on why
/// only metadata crosses this boundary, never file content.
fn buildCallPayload(allocator: std.mem.Allocator, entries: []const Entry) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "{\"src_root\":\"/appdir\",\"out_path\":\"/out/app.squashfs\",\"entries\":[");
    for (entries, 0..) |entry, i| {
        if (i != 0) try out.append(allocator, ',');
        try out.print(allocator, "{{\"path\":\"{s}\",\"mode\":{d},\"is_dir\":{s}}}", .{ entry.path, entry.file_mode, if (entry.is_dir) "true" else "false" });
    }
    try out.appendSlice(allocator, "]}");
    return out.toOwnedSlice(allocator);
}

/// The real Extism plugin manifest -- `allowed_paths` is Extism's real,
/// official mechanism for granting a plugin sandboxed host-filesystem
/// access (`allowed_paths: Option<BTreeMap<String, PathBuf>>` in Extism's
/// own Rust manifest source, confirmed directly rather than assumed).
fn buildManifest(allocator: std.mem.Allocator, appdir_abs: []const u8, out_abs: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const b64_buf = try allocator.alloc(u8, encoder.calcSize(appimage_packer_wasm.len));
    _ = encoder.encode(b64_buf, appimage_packer_wasm);

    return std.fmt.allocPrint(allocator,
        \\{{"wasm":[{{"data":"{s}"}}],"allowed_paths":{{"{s}":"/appdir","{s}":"/out"}},"timeout_ms":30000}}
    , .{ b64_buf, appdir_abs, out_abs });
}

test "buildDesktopFile: no icon omits the Icon key" {
    const allocator = std.testing.allocator;
    const contents = try buildDesktopFile(allocator, "myapp", false);
    defer allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Icon=") == null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Name=myapp") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Exec=myapp") != null);
}

test "buildDesktopFile: an icon includes Icon= pointing at the app name" {
    const allocator = std.testing.allocator;
    const contents = try buildDesktopFile(allocator, "myapp", true);
    defer allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "Icon=myapp\n") != null);
}

test "buildCallPayload: real entries serialize correctly" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{
        .{ .path = "AppRun", .file_mode = 0o755, .is_dir = false },
        .{ .path = "usr", .file_mode = 0o755, .is_dir = true },
    };
    const payload = try buildCallPayload(allocator, &entries);
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"path\":\"AppRun\",\"mode\":493,\"is_dir\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"path\":\"usr\",\"mode\":493,\"is_dir\":true") != null);
}

test "pickRuntime: an explicit aarch64 target picks the aarch64 runtime" {
    try std.testing.expectEqualSlices(u8, runtime_aarch64, pickRuntime("aarch64-linux-gnu"));
}

test "pickRuntime: a null target falls back to the native CLI arch" {
    const expected: []const u8 = switch (@import("builtin").cpu.arch) {
        .aarch64 => runtime_aarch64,
        else => runtime_x86_64,
    };
    try std.testing.expectEqualSlices(u8, expected, pickRuntime(null));
}
