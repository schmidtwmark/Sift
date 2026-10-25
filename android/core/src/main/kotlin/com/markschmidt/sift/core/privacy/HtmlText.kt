package com.markschmidt.sift.core.privacy

/** Lightweight HTML helpers that don't need a web view (indexing, quoting replies). */
object HtmlText {
    private val invisibleBlocks = Regex("(?is)<(head|style|script|title)\\b.*?</\\1\\s*>")
    private val breaks = Regex("(?i)<\\s*(br|/p|/div|/tr|/li|/h[1-6])\\b[^>]*>")
    private val tags = Regex("<[^>]+>")
    private val entity = Regex("&(#[xX]?[0-9a-fA-F]+|[a-zA-Z]+);")
    private val blankLines = Regex("\n[ \t]*(\n[ \t]*)+")

    fun plainText(html: String): String {
        if (!html.contains('<')) return html
        var text = html.replace(invisibleBlocks, " ")
        text = text.replace(breaks, "\n")
        text = text.replace(tags, "")
        text = decodeEntities(text)
        text = text.replace(blankLines, "\n\n")
        return text.trim()
    }

    fun decodeEntities(text: String): String = entity.replace(text) { match ->
        val name = match.groupValues[1]
        if (name.startsWith("#")) {
            val digits = name.drop(1)
            val code = if (digits.startsWith("x") || digits.startsWith("X")) digits.drop(1).toIntOrNull(16) else digits.toIntOrNull()
            if (code != null && Character.isValidCodePoint(code)) String(Character.toChars(code)) else match.value
        } else {
            named[name.lowercase()] ?: match.value
        }
    }

    fun escape(text: String): String =
        text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\"", "&quot;")

    private val named = mapOf(
        "amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'", "nbsp" to " ",
        "ndash" to "–", "mdash" to "—", "hellip" to "…", "rsquo" to "’", "lsquo" to "‘",
        "rdquo" to "”", "ldquo" to "“", "copy" to "©", "reg" to "®", "trade" to "™", "zwnj" to "", "zwj" to "",
    )
}
