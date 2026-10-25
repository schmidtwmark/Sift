package com.markschmidt.sift.core.sync

import com.markschmidt.sift.core.compose.MailtoLink
import com.markschmidt.sift.core.jmap.Email
import com.markschmidt.sift.core.jmap.EmailBodyPart
import com.markschmidt.sift.core.jmap.queryEscaped
import com.markschmidt.sift.core.privacy.HtmlText
import com.markschmidt.sift.core.store.BodyRecord

/** Turns a JMAP Email's body structure into one renderable document. */
object BodyAssembler {
    /**
     * Inline parts are served to the web view through this scheme:
     * `sift-blob://blob/<blobId>?type=image/png&name=logo.png`.
     */
    const val BLOB_SCHEME = "sift-blob"

    private val cidReference = Regex("(?i)cid:([^\"'\\s)>]+)")

    fun assemble(email: Email): BodyRecord {
        val values = email.bodyValues ?: emptyMap()
        val inline = LinkedHashMap<String, EmailBodyPart>()
        for (part in (email.htmlBody ?: emptyList()) + (email.attachments ?: emptyList())) {
            val cid = part.cid ?: continue
            inline.putIfAbsent(cid.trim('<', '>'), part)
        }

        val html = StringBuilder()
        var sawHtml = false
        for (part in email.htmlBody ?: emptyList()) {
            val type = part.type?.lowercase() ?: ""
            val value = part.partId?.let { values[it]?.value }
            if (type == "text/html" && value != null) {
                html.append(value)
                sawHtml = true
            } else if (type == "text/plain" && value != null) {
                html.append("<div style=\"white-space: pre-wrap\">${HtmlText.escape(value)}</div>")
            } else if (type.startsWith("image/") && part.blobId != null) {
                html.append("<img src=\"${blobUrl(part.blobId, part)}\" style=\"max-width: 100%\">")
            }
        }
        var document = html.toString()
        if (sawHtml) {
            document = cidReference.replace(document) { match ->
                val cid = match.groupValues[1]
                val part = inline[cid] ?: inline[MailtoLink.decode(cid)]
                val blobId = part?.blobId ?: return@replace match.value
                blobUrl(blobId, part)
            }
        }

        val text = (email.textBody ?: emptyList())
            .filter { (it.type ?: "").lowercase() == "text/plain" }
            .mapNotNull { part -> part.partId?.let { values[it]?.value } }
            .joinToString("\n\n")

        val attachments = (email.attachments ?: emptyList()).filter { part ->
            part.disposition?.lowercase() == "attachment" || part.cid == null
        }

        return BodyRecord(
            messageId = email.id,
            html = if (sawHtml) document else null,
            text = text.ifEmpty { if (sawHtml) HtmlText.plainText(document) else null },
            attachments = attachments,
            inlineParts = inline,
        )
    }

    fun blobUrl(blobId: String, part: EmailBodyPart): String =
        // Blob ids are case-sensitive, so they ride in the path, not the host.
        "$BLOB_SCHEME://blob/$blobId?type=${(part.type ?: "application/octet-stream").queryEscapedKeepingSlash()}" +
            "&name=${(part.name ?: "inline").queryEscapedKeepingSlash()}"

    private fun String.queryEscapedKeepingSlash() = queryEscaped().replace("%2F", "/")
}
