package dev.natyv.ntss

import com.intellij.openapi.editor.colors.TextAttributesKey
import com.intellij.openapi.fileTypes.SyntaxHighlighter
import com.intellij.openapi.options.colors.AttributesDescriptor
import com.intellij.openapi.options.colors.ColorDescriptor
import com.intellij.openapi.options.colors.ColorSettingsPage
import javax.swing.Icon

class NtssColorSettingsPage : ColorSettingsPage {
    private val descriptors = arrayOf(
        AttributesDescriptor("Token name", NtssSyntaxHighlighter.TOKEN_NAME),
        AttributesDescriptor("Field key", NtssSyntaxHighlighter.FIELD_KEY),
        AttributesDescriptor("Bare identifier", NtssSyntaxHighlighter.IDENTIFIER),
        AttributesDescriptor("String", NtssSyntaxHighlighter.STRING),
        AttributesDescriptor("Number", NtssSyntaxHighlighter.NUMBER),
        AttributesDescriptor("Comment", NtssSyntaxHighlighter.COMMENT),
        AttributesDescriptor("Braces", NtssSyntaxHighlighter.BRACES),
        AttributesDescriptor("Comma", NtssSyntaxHighlighter.COMMA),
        AttributesDescriptor("Colon", NtssSyntaxHighlighter.COLON),
    )

    override fun getIcon(): Icon? = null

    override fun getHighlighter(): SyntaxHighlighter = NtssSyntaxHighlighter()

    override fun getDemoText(): String =
        """
        // A real natyv stylesheet token.
        card {
          cornerRadius: {4, 4, 4, 4}
          border: { width: 2, color: "#8B5CF6" }
          gradient: { start: { pos: top, color: "#111111" }, end: { pos: bottomRight, color: "#222222" } }
          padding: 8
          margin: 24
        }
        """.trimIndent()

    override fun getAdditionalHighlightingTagToDescriptorMap(): MutableMap<String, TextAttributesKey>? = null

    override fun getAttributeDescriptors(): Array<AttributesDescriptor> = descriptors

    override fun getColorDescriptors(): Array<ColorDescriptor> = ColorDescriptor.EMPTY_ARRAY

    override fun getDisplayName(): String = "natyv Stylesheet"
}
