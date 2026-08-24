package dev.natyv.ntss

import com.intellij.lexer.LexerBase
import com.intellij.psi.TokenType
import com.intellij.psi.tree.IElementType

/**
 * Hand-written lexer mirroring src/styling/Stylesheet.zig's real grammar
 * (that file is the source of truth -- see its own grammar doc comment).
 * No JFlex/Grammar-Kit needed for syntax-highlighting-only support -- a
 * plain LexerBase subclass is the documented minimal path for this.
 */
class NtssLexer : LexerBase() {
    private var buffer: CharSequence = ""
    private var bufferEnd: Int = 0
    private var pos: Int = 0
    private var tokenStart: Int = 0
    private var tokenEnd: Int = 0
    private var tokenType: IElementType? = null

    override fun start(buffer: CharSequence, startOffset: Int, endOffset: Int, initialState: Int) {
        this.buffer = buffer
        this.bufferEnd = endOffset
        this.pos = startOffset
        scanNextToken()
    }

    override fun getState(): Int = 0

    override fun getTokenType(): IElementType? = tokenType

    override fun getTokenStart(): Int = tokenStart

    override fun getTokenEnd(): Int = tokenEnd

    override fun advance() {
        scanNextToken()
    }

    override fun getBufferSequence(): CharSequence = buffer

    override fun getBufferEnd(): Int = bufferEnd

    private fun isIdentStart(c: Char): Boolean = c.isLetter() || c == '_'
    private fun isIdentCont(c: Char): Boolean = c.isLetterOrDigit() || c == '_' || c == '-'

    private fun scanNextToken() {
        tokenStart = pos
        if (pos >= bufferEnd) {
            tokenType = null
            tokenEnd = pos
            return
        }
        val c = buffer[pos]

        // Whitespace is emitted as its own real token, never silently
        // skipped -- every character in [tokenStart, bufferEnd) must be
        // covered by some token per the Lexer contract.
        if (c.isWhitespace()) {
            while (pos < bufferEnd && buffer[pos].isWhitespace()) pos++
            tokenType = TokenType.WHITE_SPACE
            tokenEnd = pos
            return
        }

        if (c == '/' && pos + 1 < bufferEnd && buffer[pos + 1] == '/') {
            while (pos < bufferEnd && buffer[pos] != '\n') pos++
            tokenType = NtssTokenTypes.COMMENT
            tokenEnd = pos
            return
        }

        when (c) {
            '{' -> {
                pos++
                tokenType = NtssTokenTypes.LBRACE
                tokenEnd = pos
                return
            }
            '}' -> {
                pos++
                tokenType = NtssTokenTypes.RBRACE
                tokenEnd = pos
                return
            }
            ':' -> {
                pos++
                tokenType = NtssTokenTypes.COLON
                tokenEnd = pos
                return
            }
            ',' -> {
                pos++
                tokenType = NtssTokenTypes.COMMA
                tokenEnd = pos
                return
            }
            '"' -> {
                pos++
                // v1 simplification, matching Stylesheet.zig exactly: no
                // string escapes at all.
                while (pos < bufferEnd && buffer[pos] != '"') pos++
                if (pos < bufferEnd) pos++
                tokenType = NtssTokenTypes.STRING
                tokenEnd = pos
                return
            }
        }

        if (isIdentStart(c)) {
            while (pos < bufferEnd && isIdentCont(buffer[pos])) pos++
            tokenEnd = pos
            // One token of lookahead (skip whitespace without consuming
            // it -- it becomes its own WHITE_SPACE token on the next
            // call) to classify this identifier by what follows it,
            // matching Stylesheet.zig's own real grammar: a name
            // immediately followed by '{' is a top-level token
            // declaration, one followed by ':' is a field key, anything
            // else is a bare-word value (an anchor keyword, etc.).
            var lookahead = pos
            while (lookahead < bufferEnd && buffer[lookahead].isWhitespace()) lookahead++
            tokenType = when {
                lookahead < bufferEnd && buffer[lookahead] == '{' -> NtssTokenTypes.TOKEN_NAME
                lookahead < bufferEnd && buffer[lookahead] == ':' -> NtssTokenTypes.FIELD_KEY
                else -> NtssTokenTypes.IDENTIFIER
            }
            return
        }

        val isNegativeNumberStart = c == '-' && pos + 1 < bufferEnd && buffer[pos + 1].isDigit()
        if (c.isDigit() || isNegativeNumberStart) {
            pos++
            while (pos < bufferEnd && (buffer[pos].isDigit() || buffer[pos] == '.')) pos++
            tokenType = NtssTokenTypes.NUMBER
            tokenEnd = pos
            return
        }

        // One bad character, never silently swallowed -- matches
        // Stylesheet.zig's own lexer fallback for anything unrecognized.
        pos++
        tokenType = NtssTokenTypes.BAD_CHARACTER
        tokenEnd = pos
    }
}
