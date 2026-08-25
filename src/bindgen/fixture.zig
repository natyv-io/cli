//! Real, hand-written module wrapping the fixture C library's own
//! `@cImport` -- generated trampoline code (`Codegen.zig`'s output)
//! imports this by name (`@import("fixture")`) rather than re-declaring
//! its own `@cImport`, so the generated file and `Reflect.zig` (which
//! also needs the real fixture types for its own tests) always agree on
//! exactly one underlying translate-c instance. Wired into `build.zig` as
//! a real named module with `fixtures/bindgen` on its include path,
//! linked against the fixture's own compiled `fixture.c`.
pub const c = @cImport({
    @cInclude("fixture.h");
});
