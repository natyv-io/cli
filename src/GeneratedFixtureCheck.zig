//! Stage 1's real compile check for the binding generator
//! (~/.claude/plans/lexical-wishing-penguin.md) -- `build.zig`'s
//! `bindgen_generated_check` test target points its root module directly
//! at this file, which in turn `@import`s `bindgen/generated_check.zig`, a
//! real file `Codegen.generate`'s output gets written to fresh on every
//! `zig build test` (gitignored -- see `.gitignore`, `build.zig`'s own
//! comment on why a real path rather than an opaque build-cache one). Zig
//! transitively compiles and runs tests from every file it actually
//! analyzes (an established, already-documented behavior in this
//! project's own CLAUDE.md Toolchain section), so this file existing at
//! all is what proves the generated Zig trampoline source is genuinely
//! valid Zig -- linked here against the real `c.zig`/`host_fn_util.zig`
//! and the fixture's own compiled `fixture.c` -- not just textually
//! plausible.
//!
//! The one test below goes a step further than "it compiles": it drives
//! the real native callback-registration/invocation round trip
//! `fixtureSetCallbackHostFn`/`fixtureTriggerHostFn` set up (a real
//! `callconv(.c)` function registered with, and later called back by, the
//! real fixture C library) directly -- bypassing the Extism host-function
//! wire format entirely (no fake `ExtismCurrentPlugin`/guest linear memory
//! needed for this), since standing up a full fake plugin is exactly the
//! "live wiring" this stage explicitly defers to Stage 2. This still
//! proves the part that's genuinely new and risky in this stage: the
//! static callback natyv registers really is being called back by the
//! real C library, with the right value, for the right handle.
const std = @import("std");
const generated = @import("bindgen/generated_check.zig");
// Reaches the generated file's *own* `@cImport` instance (`pub const
// fixture_c` -- see `Codegen.zig`'s own doc comment) rather than a
// separate `@import("bindgen/fixture.zig")` -- two independent `@cImport`
// blocks over the same header produce two distinct, incompatible Zig
// types (the same class of bug `Reflect.zig`'s own doc comment already
// warns about), which would make `generated.fixture_handle_table.insert`
// below a real type-mismatch compile error against a separately-imported
// `fixture.FixtureHandle`.
const fixture = generated.fixture_c;

test "the real fixture library actually invokes the generated static callback, recording the right value for the right handle" {
    const handle_ptr = fixture.fixture_create(0).?;
    defer fixture.fixture_destroy(handle_ptr);

    const id = generated.fixture_handle_table.insert(handle_ptr).?;
    defer generated.fixture_handle_table.remove(id);

    fixture.fixture_set_callback(handle_ptr, generated.fixtureNativeCallback, @ptrFromInt(id));
    try std.testing.expectEqual(@as(?i32, null), generated.fixture_last_invocation[id]);

    fixture.fixture_trigger(handle_ptr, 77);
    try std.testing.expectEqual(@as(?i32, 77), generated.fixture_last_invocation[id]);
}
