package dev.natyv.ntss

import com.intellij.openapi.fileTypes.LanguageFileType
import javax.swing.Icon

// A Kotlin `object` compiles to a singleton with an auto-generated static
// `INSTANCE` field -- exactly what plugin.xml's <fileType fieldName="INSTANCE">
// binds to, no hand-written field needed.
object NtssFileType : LanguageFileType(NtssLanguage) {
    override fun getName(): String = "ntss"
    override fun getDescription(): String = "natyv Stylesheet"
    override fun getDefaultExtension(): String = "ntss"
    override fun getIcon(): Icon? = null
}
