//! `PackageAppImage`'s own private `@cImport` of Extism's C API --
//! deliberately NOT a relative import of the shared `src/c.zig`, same
//! reasoning as `src/bindgen/BindingsC.zig`'s own doc comment: `c.zig`
//! also `@cImport`s SDL3/Clay/FreeType, none of which the CLI links (see
//! `linkExtism` in `build.zig`, factored out specifically so the CLI only
//! gets real Extism, not natyv-core's other dependencies) -- and even if
//! it did, `c.zig` is already part of the real natyv-core `root` module,
//! so a second module (the CLI's own) reaching that same physical file
//! would hit Zig's real "file exists in two modules" error. Extism's own
//! C ABI types are stable/external and never need to cross between this
//! module's instance and `root`'s own, so a second, independent
//! `@cImport` here is safe -- same precedent as `BindingsC.zig`.
pub const c = @cImport({
    @cInclude("extism.h");
});
