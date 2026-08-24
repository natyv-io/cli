package dev.natyv.ntss

import com.intellij.lexer.Lexer
import com.intellij.openapi.editor.DefaultLanguageHighlighterColors
import com.intellij.openapi.editor.colors.TextAttributesKey
import com.intellij.openapi.editor.colors.TextAttributesKey.createTextAttributesKey
import com.intellij.openapi.fileTypes.SyntaxHighlighterBase
import com.intellij.psi.TokenType
import com.intellij.psi.tree.IElementType

class NtssSyntaxHighlighter : SyntaxHighlighterBase() {
    companion object {
        val COMMENT: TextAttributesKey = createTextAttributesKey("NTSS_COMMENT", DefaultLanguageHighlighterColors.LINE_COMMENT)
        val STRING: TextAttributesKey = createTextAttributesKey("NTSS_STRING", DefaultLanguageHighlighterColors.STRING)
        val NUMBER: TextAttributesKey = createTextAttributesKey("NTSS_NUMBER", DefaultLanguageHighlighterColors.NUMBER)
        val TOKEN_NAME: TextAttributesKey = createTextAttributesKey("NTSS_TOKEN_NAME", DefaultLanguageHighlighterColors.CLASS_NAME)
        val FIELD_KEY: TextAttributesKey = createTextAttributesKey("NTSS_FIELD_KEY", DefaultLanguageHighlighterColors.INSTANCE_FIELD)
        val IDENTIFIER: TextAttributesKey = createTextAttributesKey("NTSS_IDENTIFIER", DefaultLanguageHighlighterColors.KEYWORD)
        val BRACES: TextAttributesKey = createTextAttributesKey("NTSS_BRACES", DefaultLanguageHighlighterColors.BRACES)
        val COMMA: TextAttributesKey = createTextAttributesKey("NTSS_COMMA", DefaultLanguageHighlighterColors.COMMA)
        val COLON: TextAttributesKey = createTextAttributesKey("NTSS_COLON", DefaultLanguageHighlighterColors.OPERATION_SIGN)
        val BAD_CHARACTER: TextAttributesKey = createTextAttributesKey("NTSS_BAD_CHARACTER", com.intellij.openapi.editor.colors.CodeInsightColors.ERRORS_ATTRIBUTES)

        private val EMPTY = emptyArray<TextAttributesKey>()
    }

    override fun getHighlightingLexer(): Lexer = NtssLexer()

    override fun getTokenHighlights(tokenType: IElementType): Array<TextAttributesKey> {
        val key = when (tokenType) {
            NtssTokenTypes.COMMENT -> COMMENT
            NtssTokenTypes.STRING -> STRING
            NtssTokenTypes.NUMBER -> NUMBER
            NtssTokenTypes.TOKEN_NAME -> TOKEN_NAME
            NtssTokenTypes.FIELD_KEY -> FIELD_KEY
            NtssTokenTypes.IDENTIFIER -> IDENTIFIER
            NtssTokenTypes.LBRACE, NtssTokenTypes.RBRACE -> BRACES
            NtssTokenTypes.COMMA -> COMMA
            NtssTokenTypes.COLON -> COLON
            NtssTokenTypes.BAD_CHARACTER, TokenType.BAD_CHARACTER -> BAD_CHARACTER
            else -> return EMPTY
        }
        return arrayOf(key)
    }
}
