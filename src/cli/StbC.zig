//! A second, independent `@cImport` of the stb icon-tooling headers,
//! mirroring `AppImageC.zig`/`bindgen/BindingsC.zig`'s own established
//! precedent for this exact situation: `cli_module` can't reach `src/c.zig`
//! (it's part of natyv-core's own root module, a separate binary), and a
//! second `@cImport` of the same headers is safe since their declared ABI
//! is identical either way. Real implementation is compiled as C via
//! `vendor/stb/stb_icon_tools_impl.c` (see `build.zig`), same split as
//! every other vendored single-header C library in this codebase.
pub const c = @cImport({
    @cInclude("stb_image.h");
    @cInclude("stb_image_resize2.h");
    @cInclude("stb_image_write.h");
});
