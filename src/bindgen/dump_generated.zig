//! Tiny helper invoked by `build.zig`'s own codegen step (`bindgen_generated_check`,
//! see that file's own comment) so Stage 1/2.1's "real compile check" can
//! actually exist as a `zig build test` target: generates the fixture's
//! full binding output (as the "fixture" library) and writes the two
//! halves to the two paths given as argv, then a separate test module
//! compiles the Zig half for real against this repo's actual
//! `c.zig`/`host_fn_util.zig`/`HandleTable.zig`.
//! Not `natyv bind` itself (`src/cli/Bind.zig`'s job) -- this only ever
//! runs against the one hand-written fixture, with no CLI, no arbitrary
//! header input, matching how `Reflect.zig`/`Codegen.zig` were
//! deliberately kept generic in Stage 2.1 while this file stayed a fixed,
//! fixture-specific verification tool.
const std = @import("std");
const Reflect = @import("Reflect.zig");
const Codegen = @import("Codegen.zig");
const fixture_c = @import("fixture.zig").c;

const allowlist = [_][]const u8{
    "fixture_create",
    "fixture_destroy",
    // Zero-parameter function -- real regression coverage for Stage 2.2's
    // "unused local constant" bug (see fixture.h's own doc comment on
    // `fixture_ping`): this whole file's output gets really compiled by
    // `build.zig`'s `bindgen_generated_check` test, so including it here
    // means that bug class can never silently reappear.
    "fixture_ping",
    "fixture_get_point",
    "fixture_set_callback",
    "fixture_trigger",
    // Stage 2.9's own byte-buffer + wide-unsigned-int marshaling --
    // including this here means the real `std.base64` decode logic
    // `Codegen.zig` now emits gets a genuine `zig build test` compile
    // check, not just the text-level assertions `Codegen.zig`'s own unit
    // test already covers.
    "fixture_checksum",
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const argv = init.minimal.args.vector;
    if (argv.len != 3) {
        std.debug.print("usage: dump_generated <zig-out-path> <go-out-path>\n", .{});
        return error.BadArgs;
    }
    const zig_out_path = std.mem.span(argv[1]);
    const go_out_path = std.mem.span(argv[2]);

    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var descs: [allowlist.len]Reflect.FnDescriptor = undefined;
    inline for (allowlist, 0..) |name, i| {
        descs[i] = try Reflect.describe(fixture_c, name);
    }
    const out = try Codegen.generate(allocator, "fixture", "fixture.h", &descs);

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = zig_out_path, .data = out.zig_source });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = go_out_path, .data = out.go_source });
}
