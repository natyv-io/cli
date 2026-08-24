package dev.natyv.ntss

import com.intellij.psi.tree.IElementType

class NtssTokenType(debugName: String) : IElementType(debugName, NtssLanguage)

object NtssTokenTypes {
    val COMMENT = NtssTokenType("COMMENT")
    val STRING = NtssTokenType("STRING")
    val NUMBER = NtssTokenType("NUMBER")

    // Three distinct identifier token types, disambiguated by one token of
    // lookahead in NtssLexer -- mirrors src/styling/Stylesheet.zig's real
    // grammar (an identifier's role is purely positional: followed by '{'
    // is a top-level token name, followed by ':' is a field key, anything
    // else is a bare-word value like an anchor keyword).
    val TOKEN_NAME = NtssTokenType("TOKEN_NAME")
    val FIELD_KEY = NtssTokenType("FIELD_KEY")
    val IDENTIFIER = NtssTokenType("IDENTIFIER")

    val LBRACE = NtssTokenType("LBRACE")
    val RBRACE = NtssTokenType("RBRACE")
    val COLON = NtssTokenType("COLON")
    val COMMA = NtssTokenType("COMMA")
    val BAD_CHARACTER = NtssTokenType("BAD_CHARACTER")
}
