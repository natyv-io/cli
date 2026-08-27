; Real, minimal base highlighting for `.ntx` markup -- exactly the same
; token taxonomy Stage 3 already established for VS Code's semantic tokens
; (tag names, attribute names, string-ish values), so this grammar layer
; and the LSP's own semantic-token overlay agree rather than fight. Real Go
; code (both the top-level prelude and any non-composer function body) gets
; its own real highlighting entirely through `injections.scm`, not through
; anything in this file -- there is deliberately no attempt here to
; reimplement Go's own keyword/operator highlighting.

(tag_name) @tag
(attribute_name) @property
(string_literal) @string
(child_text) @string
(func_decl name: (identifier) @function)
(go_type) @type
