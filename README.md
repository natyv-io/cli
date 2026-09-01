# natyv-io/cli

The `natyv` CLI (`prepare`/`build`/`get`/`bind`/`init`/...) -- everything a natyv app developer's own
toolchain needs to go from a `.ntx`/`.ntss`-authored app to a real, bundled binary. Includes the `.ntx`
transpiler's `cli`-only pieces (`Validate`, `Prepare`), the stylesheet codegen, the binding generator's
codegen half, and the vendored AppImage-packing plugin source (`tools/appimage-packer/`).

The `ntx-lsp` language server and every editor extension (`vscode-ntx`, `zed-ntx`, etc.) each live in
their own repo now -- see the [natyv-io](https://github.com/natyv-io) org.

See [natyv-io/natyv](https://github.com/natyv-io/natyv) for the project's own README and
architectural reference until this repo grows its own.

Depends on [natyv-io/shared](https://github.com/natyv-io/shared) for the `conf.natyv.json`
schema/parser (shared with [natyv-io/core](https://github.com/natyv-io/core)) and the `.ntx`
transpiler core (`Parser`/`Expose`/`Codegen`/`Resolver`/`Stylesheet`, shared with
[natyv-io/ntx-lsp](https://github.com/natyv-io/ntx-lsp)) -- and, at `natyv build` runtime, on a real
natyv-io/core checkout (`NATYV_CORE_SRC`/`-Dnatyv-core-src`) to compile a dev's app against.
