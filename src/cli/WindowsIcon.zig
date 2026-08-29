//! Builds a real Windows `.ico` (multi-resolution, PNG-in-ICO per entry --
//! valid on every Windows version since Vista, per Microsoft's own ICO
//! format documentation: a directory entry's image data is auto-detected as
//! PNG by its leading signature, no separate flag needed) from the dev's
//! single source PNG (`Config.icon` -- the same image the macOS `.icns`
//! path already uses), plus the small `.rc` resource script referencing it.
//! `Bundle.zig` links the result into the built `.exe` via Zig's own
//! built-in Win32 resource compiler (`Module.addWin32ResourceFile`,
//! confirmed real in Zig 0.16's stdlib -- cross-compiles cleanly from
//! macOS/Linux, no external Windows toolchain needed).
//!
//! No Windows-native resizing tool exists to shell out to the way macOS's
//! `sips` does, so resizing happens in-process via the stb decode/resize/
//! encode single-header trio (`StbC.zig`/`vendor/stb/stb_icon_tools_impl.c`)
//! -- linked only into the `natyv` CLI itself, never natyv-core.

const std = @import("std");
const Io = std.Io;
const stb = @import("StbC.zig").c;

pub const IconError = struct {
    message: []const u8,
};

pub const Result = struct {
    ok: bool,
    err: ?IconError,
    /// Absolute path to the generated `.rc` file, valid only when `ok`.
    rc_path: []const u8 = "",
};

/// Every real size a Windows `.ico` should cover -- 16/32/48 for
/// Explorer/taskbar at standard DPI, 256 for the large-icon/Vista+ view.
/// Matches the same "one source PNG, several derived sizes" shape as the
/// macOS `.iconset` path, just a different real size set (macOS's own
/// required-sizes list is unrelated and larger).
const icon_sizes = [_]u32{ 16, 32, 48, 256 };

const IcoEntry = struct {
    size: u32,
    png_bytes: []const u8,
};

/// `icon_path` is the dev's source PNG (already resolved relative to the
/// config file's own directory, matching `Bundle.zig`'s existing
/// `icon_path` convention). `scratch_dir`/`scratch_abs` is a directory the
/// caller owns and cleans up afterward (mirrors `buildMacosApp`'s own
/// scratch-then-delete `AppIcon.iconset` pattern) -- both the `.ico` and
/// `.rc` land there. The `.rc`'s own `ICON` directive references the `.ico`
/// by its bare basename, resolved by the resource compiler relative to the
/// `.rc` file's own directory (standard `rc.exe` behavior), so nothing
/// depends on `scratch_abs` staying valid beyond the `zig build` invocation
/// that consumes the returned `rc_path`.
pub fn build(allocator: std.mem.Allocator, io: Io, icon_path: []const u8, scratch_dir: Io.Dir, scratch_abs: []const u8) !Result {
    const png_bytes = std.Io.Dir.cwd().readFileAlloc(io, icon_path, allocator, .unlimited) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: configured icon '{s}' could not be read: {s}", .{ icon_path, @errorName(e) }),
        } };
    };
    defer allocator.free(png_bytes);

    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const decoded = stb.stbi_load_from_memory(png_bytes.ptr, @intCast(png_bytes.len), &width, &height, &channels, 4);
    if (decoded == null) {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: configured icon '{s}' could not be decoded (not a valid image?)", .{icon_path}),
        } };
    }
    defer stb.stbi_image_free(decoded);

    var entries: [icon_sizes.len]IcoEntry = undefined;
    var entry_count: usize = 0;
    errdefer for (entries[0..entry_count]) |e| allocator.free(e.png_bytes);

    for (icon_sizes) |size| {
        const resized = try allocator.alloc(u8, @as(usize, size) * @as(usize, size) * 4);
        defer allocator.free(resized);

        const resize_result = stb.stbir_resize_uint8_linear(
            decoded,
            width,
            height,
            0,
            resized.ptr,
            @intCast(size),
            @intCast(size),
            0,
            stb.STBIR_RGBA,
        );
        if (resize_result == null) {
            return .{ .ok = false, .err = .{
                .message = try std.fmt.allocPrint(allocator, "natyv build: could not resize icon '{s}' to {d}x{d}", .{ icon_path, size, size }),
            } };
        }

        entries[entry_count] = .{ .size = size, .png_bytes = try encodePng(allocator, resized, size) };
        entry_count += 1;
    }
    defer for (entries[0..entry_count]) |e| allocator.free(e.png_bytes);

    const ico_bytes = try assembleIco(allocator, entries[0..entry_count]);
    defer allocator.free(ico_bytes);

    scratch_dir.writeFile(io, .{ .sub_path = "AppIcon.ico", .data = ico_bytes }) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: could not write '{s}/AppIcon.ico': {s}", .{ scratch_abs, @errorName(e) }),
        } };
    };

    const rc_contents = "IDI_ICON1 ICON \"AppIcon.ico\"\n";
    scratch_dir.writeFile(io, .{ .sub_path = "AppIcon.rc", .data = rc_contents }) catch |e| {
        return .{ .ok = false, .err = .{
            .message = try std.fmt.allocPrint(allocator, "natyv build: could not write '{s}/AppIcon.rc': {s}", .{ scratch_abs, @errorName(e) }),
        } };
    };

    return .{ .ok = true, .err = null, .rc_path = try std.fmt.allocPrint(allocator, "{s}/AppIcon.rc", .{scratch_abs}) };
}

/// A small growable sink for `stbi_write_png_to_func`'s callback -- stb's
/// own callback only ever carries back a raw `context` pointer, so the
/// allocator has to travel alongside the list inside it.
const PngSink = struct {
    allocator: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,
};

fn pngWriteCallback(context: ?*anyopaque, data: ?*anyopaque, size: c_int) callconv(.c) void {
    const sink: *PngSink = @ptrCast(@alignCast(context.?));
    const bytes: [*]const u8 = @ptrCast(data.?);
    sink.list.appendSlice(sink.allocator, bytes[0..@intCast(size)]) catch @panic("OOM");
}

fn encodePng(allocator: std.mem.Allocator, rgba: []const u8, size: u32) ![]u8 {
    var sink: PngSink = .{ .allocator = allocator };
    errdefer sink.list.deinit(allocator);
    const ok = stb.stbi_write_png_to_func(pngWriteCallback, &sink, @intCast(size), @intCast(size), 4, rgba.ptr, 0);
    if (ok == 0) return error.PngEncodeFailed;
    return sink.list.toOwnedSlice(allocator);
}

fn appendU16LE(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: u16) !void {
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, v, .little);
    try out.appendSlice(allocator, &buf);
}

fn appendU32LE(allocator: std.mem.Allocator, out: *std.ArrayList(u8), v: u32) !void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, v, .little);
    try out.appendSlice(allocator, &buf);
}

/// A real ICONDIR + one ICONDIRENTRY per image + the raw image bytes back
/// to back, per Microsoft's own documented ICO layout. `bWidth`/`bHeight`
/// wrap to 0 for a real 256px image -- an ICO byte field can't represent
/// 256 directly, and 0 is the documented special case meaning "256."
fn assembleIco(allocator: std.mem.Allocator, entries: []const IcoEntry) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.append(allocator, 0); // idReserved (low byte)
    try out.append(allocator, 0); // idReserved (high byte)
    try appendU16LE(allocator, &out, 1); // idType: 1 == icon
    try appendU16LE(allocator, &out, @intCast(entries.len));

    var offset: u32 = 6 + @as(u32, @intCast(entries.len)) * 16;
    for (entries) |e| {
        const dim_byte: u8 = if (e.size == 256) 0 else @intCast(e.size);
        try out.append(allocator, dim_byte); // bWidth
        try out.append(allocator, dim_byte); // bHeight
        try out.append(allocator, 0); // bColorCount (0: >=8bpp)
        try out.append(allocator, 0); // bReserved
        try appendU16LE(allocator, &out, 1); // wPlanes
        try appendU16LE(allocator, &out, 32); // wBitCount
        try appendU32LE(allocator, &out, @intCast(e.png_bytes.len)); // dwBytesInRes
        try appendU32LE(allocator, &out, offset); // dwImageOffset
        offset += @intCast(e.png_bytes.len);
    }
    for (entries) |e| try out.appendSlice(allocator, e.png_bytes);

    return out.toOwnedSlice(allocator);
}

test "assembleIco: header fields and offsets are correct for two entries" {
    const allocator = std.testing.allocator;
    const entries = [_]IcoEntry{
        .{ .size = 16, .png_bytes = "AB" },
        .{ .size = 256, .png_bytes = "CDEF" },
    };
    const ico = try assembleIco(allocator, &entries);
    defer allocator.free(ico);

    // ICONDIR: reserved=0, type=1, count=2
    try std.testing.expectEqual(@as(u8, 0), ico[0]);
    try std.testing.expectEqual(@as(u8, 0), ico[1]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, ico[2..4], .little));
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, ico[4..6], .little));

    // Entry 0: 16x16, 2 bytes, offset 6 + 2*16 = 38
    try std.testing.expectEqual(@as(u8, 16), ico[6]);
    try std.testing.expectEqual(@as(u8, 16), ico[7]);
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, ico[14..18], .little));
    try std.testing.expectEqual(@as(u32, 38), std.mem.readInt(u32, ico[18..22], .little));

    // Entry 1: 256x256 wraps to byte 0, 4 bytes, offset 38 + 2 = 40
    try std.testing.expectEqual(@as(u8, 0), ico[22]);
    try std.testing.expectEqual(@as(u8, 0), ico[23]);
    try std.testing.expectEqual(@as(u32, 4), std.mem.readInt(u32, ico[30..34], .little));
    try std.testing.expectEqual(@as(u32, 40), std.mem.readInt(u32, ico[34..38], .little));

    // Real image bytes follow, in order.
    try std.testing.expectEqualStrings("AB", ico[38..40]);
    try std.testing.expectEqualStrings("CDEF", ico[40..44]);
}

test "encodePng then decoding it back gives the same pixels" {
    const allocator = std.testing.allocator;
    // A tiny real 2x2 RGBA buffer, deliberately not all-one-color so a
    // channel/row swap would be caught.
    const pixels = [_]u8{
        255, 0, 0,   255, 0,   255, 0, 255,
        0,   0, 255, 255, 255, 255, 0, 255,
    };
    const png = try encodePng(allocator, &pixels, 2);
    defer allocator.free(png);

    // Real PNG signature, not garbage.
    try std.testing.expectEqualSlices(u8, &.{ 0x89, 'P', 'N', 'G' }, png[0..4]);

    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const decoded = stb.stbi_load_from_memory(png.ptr, @intCast(png.len), &w, &h, &ch, 4);
    try std.testing.expect(decoded != null);
    defer stb.stbi_image_free(decoded);
    try std.testing.expectEqual(@as(c_int, 2), w);
    try std.testing.expectEqual(@as(c_int, 2), h);
    try std.testing.expectEqualSlices(u8, &pixels, decoded[0..16]);
}

test "build: a real source PNG produces a real .ico whose entries decode to the right sizes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    // A real, tiny 4x4 solid-color source PNG, built via the same encoder
    // this file uses -- exercises the full decode-then-resize path for
    // real, not just a synthetic fixture.
    var source_pixels: [4 * 4 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < source_pixels.len) : (i += 4) {
        source_pixels[i] = 10;
        source_pixels[i + 1] = 20;
        source_pixels[i + 2] = 30;
        source_pixels[i + 3] = 255;
    }
    const source_png = try encodePng(allocator, &source_pixels, 4);
    defer allocator.free(source_png);
    try tmp.dir.writeFile(io, .{ .sub_path = "source.png", .data = source_png });

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    const icon_abs = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}/source.png", .{ cwd_path, tmp.sub_path });
    defer allocator.free(icon_abs);
    const scratch_abs = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_path, tmp.sub_path });
    defer allocator.free(scratch_abs);

    const result = try build(allocator, io, icon_abs, tmp.dir, scratch_abs);
    defer if (result.err) |e| allocator.free(e.message);
    try std.testing.expect(result.ok);
    defer allocator.free(result.rc_path);

    const rc_text = try tmp.dir.readFileAlloc(io, "AppIcon.rc", allocator, .unlimited);
    defer allocator.free(rc_text);
    try std.testing.expect(std.mem.indexOf(u8, rc_text, "AppIcon.ico") != null);

    const ico_bytes = try tmp.dir.readFileAlloc(io, "AppIcon.ico", allocator, .unlimited);
    defer allocator.free(ico_bytes);
    try std.testing.expectEqual(@as(u16, @intCast(icon_sizes.len)), std.mem.readInt(u16, ico_bytes[4..6], .little));

    // Decode the first entry (16x16) straight out of the real assembled
    // .ico bytes and confirm it's genuinely 16x16, not just present.
    const first_offset = std.mem.readInt(u32, ico_bytes[18..22], .little);
    const first_len = std.mem.readInt(u32, ico_bytes[14..18], .little);
    var w: c_int = 0;
    var h: c_int = 0;
    var ch: c_int = 0;
    const decoded = stb.stbi_load_from_memory(ico_bytes.ptr + first_offset, @intCast(first_len), &w, &h, &ch, 4);
    try std.testing.expect(decoded != null);
    defer stb.stbi_image_free(decoded);
    try std.testing.expectEqual(@as(c_int, 16), w);
    try std.testing.expectEqual(@as(c_int, 16), h);
}

test "build: an unreadable icon path is a clear error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const result = try build(allocator, io, "/definitely/not/a/real/icon.png", tmp.dir, "/tmp/scratch");
    defer if (result.err) |e| allocator.free(e.message);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "could not be read") != null);
}

test "build: a non-image file is a clear decode error" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "not-an-image.png", .data = "this is definitely not a real image file" });

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);
    const icon_abs = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}/not-an-image.png", .{ cwd_path, tmp.sub_path });
    defer allocator.free(icon_abs);

    const result = try build(allocator, io, icon_abs, tmp.dir, "/tmp/scratch");
    defer if (result.err) |e| allocator.free(e.message);
    try std.testing.expect(!result.ok);
    try std.testing.expect(std.mem.indexOf(u8, result.err.?.message, "could not be decoded") != null);
}
