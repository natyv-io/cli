; Real `.ntss` highlighting, mirroring `editors/vscode-ntss/`'s own
; TextMate token taxonomy (token name, field key, string, number, bare
; anchor-keyword identifier) but expressed as real tree-sitter captures --
; `.ntss` has no LSP behind it (syntax highlighting only, confirmed scope
; in CLAUDE.md), so this file, not semantic tokens, is the whole story for
; `.ntss` in Zed.
;
; Capture names confirmed against Zed's own real documented convention
; (not guessed): `@property` for a key in a key:value pair (matching
; Zed's own JSON example, `(pair key: (string) @property.json_key)`) --
; deliberately different from `.ntx`'s own `@attribute` for tag
; attributes, since a stylesheet field key is a genuinely different real
; construct (CSS/JSON-like), not an HTML-style tag attribute.

(style_token name: (identifier) @type)
(field key: (identifier) @property)
(string) @string
(number) @number
(comment) @comment

; Deliberately last: a bare identifier used as a *value* (an anchor
; keyword like `topLeft`, or any other bare-word value) -- everywhere
; `identifier` appears as a `name:`/`key:` field is already claimed by a
; more specific pattern above.
(identifier) @constant
