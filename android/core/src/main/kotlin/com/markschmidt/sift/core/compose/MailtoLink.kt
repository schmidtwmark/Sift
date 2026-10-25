package com.markschmidt.sift.core.compose

import java.io.ByteArrayOutputStream

/**
 * A `mailto:` link (RFC 6068), as opened from a web page or another app when
 * Sift is the default email app.
 *
 *     mailto:alex@example.com,sam@example.com?cc=pat@example.com&subject=Hi%20there&body=See%20you
 */
data class MailtoLink(
    val to: List<String> = emptyList(),
    val cc: List<String> = emptyList(),
    val bcc: List<String> = emptyList(),
    val subject: String? = null,
    val body: String? = null,
) {
    val isEmpty: Boolean get() = to.isEmpty() && cc.isEmpty() && bcc.isEmpty() && subject == null && body == null

    companion object {
        /**
         * Parsed by hand: strict URL parsers reject common real-world links
         * (raw spaces, unencoded commas) and RFC 6068 doesn't treat "+" as a space.
         */
        fun parse(string: String): MailtoLink? {
            if (!string.lowercase().startsWith("mailto:")) return null
            var rest = string.drop("mailto:".length)
            if (rest.startsWith("//")) rest = rest.drop(2)  // "mailto://", seen in the wild
            val parts = rest.split("?", limit = 2)
            val to = addresses(parts[0]).toMutableList()
            val cc = mutableListOf<String>()
            val bcc = mutableListOf<String>()
            var subject: String? = null
            var body: String? = null
            if (parts.size > 1) {
                for (field in parts[1].split("&").filter { it.isNotEmpty() }) {
                    val pair = field.split("=", limit = 2)
                    val value = if (pair.size > 1) decode(pair[1]) else ""
                    when (pair[0].lowercase()) {
                        "to" -> to += addresses(value, decoded = true)
                        "cc" -> cc += addresses(value, decoded = true)
                        "bcc" -> bcc += addresses(value, decoded = true)
                        "subject" -> subject = value
                        "body" -> body = value.replace("\r\n", "\n")
                        // In-Reply-To, Keywords and so on: not needed to start a message.
                    }
                }
            }
            return MailtoLink(to, cc, bcc, subject, body)
        }

        /** Percent-decoding without "+"-as-space; malformed input comes back as it was. */
        fun decode(value: String): String {
            if (!value.contains('%')) return value
            val bytes = ByteArrayOutputStream()
            var index = 0
            while (index < value.length) {
                val char = value[index]
                if (char == '%') {
                    val byte = value.substring(index + 1, minOf(index + 3, value.length)).takeIf { it.length == 2 }?.toIntOrNull(16)
                        ?: return value
                    bytes.write(byte)
                    index += 3
                } else {
                    bytes.write(char.toString().toByteArray(Charsets.UTF_8))
                    index++
                }
            }
            val decoder = Charsets.UTF_8.newDecoder()
            return runCatching { decoder.decode(java.nio.ByteBuffer.wrap(bytes.toByteArray())).toString() }.getOrDefault(value)
        }

        private fun addresses(list: String, decoded: Boolean = false): List<String> {
            val text = if (decoded) list else decode(list)
            return text.split(",").map { it.trim() }.filter { it.isNotEmpty() }
        }
    }
}
