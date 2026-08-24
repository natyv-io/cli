; Top-level token name, e.g. `spacer` in `spacer { ... }`.
(token name: (identifier) @type)

; Field keys, e.g. `margin` in `margin: 24`.
(field key: (identifier) @property)

; Any other bare identifier is a value (anchor keywords like `top`,
; `bottomRight`, etc.) -- matched last so the two rules above (which
; anchor on the surrounding `token`/`field` node shape) take priority.
(identifier) @constant

(comment) @comment

(number) @number

(string) @string

[
  "{"
  "}"
] @punctuation.bracket

[
  ":"
  ","
] @punctuation.delimiter
