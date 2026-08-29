# appimage-packer

A small Extism plugin, compiled to `wasm32-wasip1`, that packs a directory
into a real SquashFS image -- the payload half of a `.AppImage` file (see
the `natyv-linux-appimage-packaging` memory for the full design/proof, and
`src/cli/PackageAppImage.zig` for how natyv's own CLI calls this).

**This is a maintainer-only build tool, not something natyv devs ever need
to touch.** Rust/cargo is never required to build or use `natyv` itself --
only to regenerate the compiled `.wasm` blob (`src/cli/assets/appimage_packer.wasm`)
if this plugin's own source ever changes.

## Why `backhand` is patched locally (`backhand-patched/`)

`backhand`'s real, upstream source already has an intentional cross-platform
compatibility shim (`v3`/`v4`'s own `unix_string.rs`) for `OsStr`/`OsString`
byte conversion, with real `#[cfg(unix)]` and `#[cfg(windows)]` branches --
it's just missing a `#[cfg(target_os = "wasi")]` one, which is a hard
compile error under `wasm32-wasip1`. `backhand-patched/` is the real
upstream crate (pinned to `0.25.1`) with that one gap filled in, mirroring
the existing `unix` branch exactly (two files, ~15 lines each). Not
upstreamed as a PR -- Quinn's own call, 2026-08-29: this patch only ever
needs applying once, here, to produce the vendored blob; natyv devs never
touch Rust or this patch at all, so there's no ongoing cost to justify
waiting on an external review.

## Rebuilding the blob

```bash
cd plugin
rustup target add wasm32-wasip1  # once, if not already installed
cargo build --release --target wasm32-wasip1
cp target/wasm32-wasip1/release/appimage_packer.wasm ../../src/cli/assets/appimage_packer.wasm
```
