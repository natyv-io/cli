; Real Go logic code -- the top-level prelude (package/import/var/const
; declarations) and any non-composer function's own body -- gets real Go
; syntax highlighting by injecting Zed's own already-bundled, real "go"
; grammar into these opaque spans, the same embedded-language mechanism
; markdown code fences and Vue/Svelte's <script> blocks use. This grammar
; deliberately never reimplements Go's own keyword/operator/string
; highlighting itself -- `go_chunk`/`go_body` exist specifically to find
; these spans' real boundaries (balanced-brace-aware, so a nested if/for
; block's own braces are never mistaken for the function's own closing
; one), not to parse Go syntax.
;
; Real, honest limitation: `go_chunk` also contains natyv-specific keywords
; with no real Go equivalent (`expose Name`, `uses (...)`) -- Go's own
; grammar will hit a genuine parse error there and fall back to unstyled
; plain text for those lines specifically, while the surrounding real Go
; declarations (package/import/var/comments) still get correct real
; highlighting via tree-sitter's normal error-tolerant recovery.

((go_chunk) @injection.content
 (#set! injection.language "go"))

((go_body) @injection.content
 (#set! injection.language "go"))
