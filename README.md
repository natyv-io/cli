# natyv-io/cli

The `natyv` CLI (`prepare`/`build`/`get`/`bind`/`init`/...) and the `ntx-lsp` language server --
everything a natyv app developer's own toolchain needs. Includes the `.ntx` transpiler, the
stylesheet resolver, the binding generator's codegen half, editor extensions (`editors/`), and the
vendored AppImage-packing plugin source (`tools/appimage-packer/`).

See [natyv-io/natyv](https://github.com/natyv-io/natyv) for the project's own README and
architectural reference until this repo grows its own.

Depends on [natyv-io/shared](https://github.com/natyv-io/shared) for the `conf.natyv.json`
schema/parser, shared with [natyv-io/core](https://github.com/natyv-io/core) -- and, at
`natyv build` runtime, on a real natyv-io/core checkout (`NATYV_CORE_SRC`/`-Dnatyv-core-src`) to
compile a dev's app against.
