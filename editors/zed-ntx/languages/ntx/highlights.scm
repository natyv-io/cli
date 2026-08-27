; Real, minimal base highlighting for `.ntx` markup -- exactly the same
; token taxonomy Stage 3 already established for VS Code's semantic tokens
; (tag names, attribute names, string-ish values), so this grammar layer
; and the LSP's own semantic-token overlay agree rather than fight. Real Go
; code (both the top-level prelude and any non-composer function body) gets
; its own real highlighting entirely through `injections.scm`, not through
; anything in this file -- there is deliberately no attempt here to
; reimplement Go's own keyword/operator highlighting.

(tag_name) @tag
(attribute_name) @attribute
(string_literal) @string
(func_decl name: (identifier) @function)
(go_type) @type

; Deliberately no capture for `child_text` -- per Quinn's own real
; click-through feedback during Stage 3 (VS Code), a widget's own child
; text (e.g. a Button's "Save") reads as plain author-facing content, not
; `.ntx` syntax, and should render in the editor's default color. The LSP
; server already agrees (it never emits a semantic token for child text,
; only for style-token names -- see Codegen.zig's own Stage 3 test), so
; this grammar must not reintroduce the coloring on its own.
