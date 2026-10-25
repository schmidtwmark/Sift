package com.markschmidt.sift

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.markschmidt.sift.core.compose.OutgoingMessage
import com.markschmidt.sift.core.jmap.EmailAddress
import com.markschmidt.sift.core.privacy.HtmlText
import com.markschmidt.sift.core.store.MessageRecord
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import java.util.UUID

/**
 * One message being written: its fields, its attachments as they upload,
 * and saving it to Drafts. The compose screen draws it.
 */
class ComposeDraft {
    enum class Field { TO, CC, BCC, SUBJECT, BODY }

    data class PendingAttachment(
        val id: String = UUID.randomUUID().toString(),
        val name: String,
        val type: String,
        val size: Int,
        val ready: OutgoingMessage.Attachment? = null,
        val failure: String? = null,
    ) {
        val isUploading: Boolean get() = ready == null && failure == null
    }

    var identityId by mutableStateOf("")
    val to = mutableStateListOf<EmailAddress>()
    val cc = mutableStateListOf<EmailAddress>()
    val bcc = mutableStateListOf<EmailAddress>()
    /** What's being typed in each address field, not yet a token. */
    var toText by mutableStateOf("")
    var ccText by mutableStateOf("")
    var bccText by mutableStateOf("")
    var subject by mutableStateOf("")
    var body by mutableStateOf("")
    val attachments = mutableStateListOf<PendingAttachment>()
    /** "Cc/Bcc, From" folds into one line until it's tapped. */
    var showsAllHeaders by mutableStateOf(false)
    var isSending by mutableStateOf(false)

    var draftId by mutableStateOf<String?>(null)
        private set
    var kind = "New Message"
        private set
    private var inReplyTo: List<String> = emptyList()
    private var references: List<String> = emptyList()
    private var answering: String? = null
    /** The content as last saved (or as it started), to tell whether there are edits. */
    private var savedContent: OutgoingMessage? = null
    private var isSaving = false
    /** Sent or deleted: nothing left to save. */
    var isFinished = false
        private set

    val message: OutgoingMessage
        get() = OutgoingMessage(
            identityId = identityId,
            to = to + parse(toText), cc = cc + parse(ccText), bcc = bcc + parse(bccText),
            subject = subject, body = body,
            attachments = attachments.mapNotNull { it.ready },
            inReplyTo = inReplyTo, references = references, answering = answering, draftId = draftId,
        )

    val title: String get() = subject.trim().ifEmpty { kind }

    /** Changed since it was opened or last saved. */
    val hasEdits: Boolean get() = savedContent != null && message.content != savedContent

    val isUploading: Boolean get() = attachments.any { it.isUploading }

    val canSend: Boolean get() = message.recipients.isNotEmpty() && identityId.isNotEmpty() && !isUploading && !isSending

    // MARK: - Starting

    /** Fills the fields for a new message, reply, forward, link or saved draft. Returns the field to start in. */
    suspend fun prepare(request: ComposeRequest, model: AppModel): Field {
        identityId = model.identities.firstOrNull()?.id ?: ""
        val own = model.identities.map { it.email.lowercase() }.toSet()
        var focus = Field.TO
        val draft = request.draft
        val link = request.mailto
        val original = request.replyTo
        val forwarded = request.forward

        when {
            draft != null -> {
                identityId = draft.identityId.ifEmpty { identityId }
                to += draft.to; cc += draft.cc; bcc += draft.bcc
                subject = draft.subject
                body = draft.body
                attachments += draft.attachments.map { PendingAttachment(name = it.name, type = it.type, size = it.size, ready = it) }
                inReplyTo = draft.inReplyTo; references = draft.references; answering = draft.answering; draftId = draft.draftId
                showsAllHeaders = cc.isNotEmpty() || bcc.isNotEmpty()
                focus = if (to.isEmpty()) Field.TO else Field.BODY
            }
            link != null -> {
                to += link.to.flatMap(::parse); cc += link.cc.flatMap(::parse); bcc += link.bcc.flatMap(::parse)
                subject = link.subject ?: ""
                body = link.body ?: ""
                showsAllHeaders = cc.isNotEmpty() || bcc.isNotEmpty()
                focus = if (to.isEmpty()) Field.TO else Field.BODY
            }
            original != null -> {
                kind = if (request.replyAll) "Reply All" else "Reply"
                to += original.replyTo.ifEmpty { listOf(original.sender) }
                if (request.replyAll) {
                    val already = to.map { it.normalized }.toSet()
                    cc += (original.to + original.cc).filter { it.normalized !in own && it.normalized !in already }
                }
                subject = if (original.subject.lowercase().startsWith("re:")) original.subject else "Re: ${original.subject}"
                // Reply from whichever of your addresses it was sent to.
                model.identities.firstOrNull { identity ->
                    (original.to + original.cc).any { it.normalized == identity.email.lowercase() }
                }?.let { identityId = it.id }
                original.messageIdHeader?.let { id ->
                    inReplyTo = listOf(id)
                    references = original.references + id
                }
                answering = original.id
                val quoted = quotedText(original, model).split("\n").joinToString("\n") { "> $it" }
                body = signatureBlock(model) + "\n\nOn ${dateTime(original, FormatStyle.MEDIUM)}, ${original.senderDisplayName} wrote:\n\n$quoted"
                showsAllHeaders = cc.isNotEmpty()
                focus = Field.BODY
            }
            forwarded != null -> {
                kind = "Forward"
                subject = if (forwarded.subject.lowercase().startsWith("fwd:")) forwarded.subject else "Fwd: ${forwarded.subject}"
                val text = quotedText(forwarded, model)
                body = signatureBlock(model) + "\n\n\nBegin forwarded message:\n\n" +
                    "From: ${format(forwarded.sender)}\n" +
                    "Subject: ${forwarded.subject}\n" +
                    "Date: ${dateTime(forwarded, FormatStyle.LONG)}\n" +
                    "To: ${forwarded.to.joinToString(", ") { format(it) }}\n\n$text"
                // The original's files come along without uploading them again.
                runCatching { model.body(forwarded).attachments }.getOrNull()?.forEach { part ->
                    val blobId = part.blobId ?: return@forEach
                    val file = OutgoingMessage.Attachment(blobId, part.name ?: "Attachment", part.type ?: "application/octet-stream", part.size ?: 0)
                    attachments += PendingAttachment(name = file.name, type = file.type, size = file.size, ready = file)
                }
            }
            else -> body = signatureBlock(model)
        }
        savedContent = message.content
        return focus
    }

    private fun signatureBlock(model: AppModel): String {
        val signature = model.identities.firstOrNull { it.id == identityId }?.textSignature?.trim()
        return if (signature.isNullOrEmpty()) "" else "\n\n-- \n$signature"
    }

    private fun dateTime(message: MessageRecord, style: FormatStyle) =
        DateTimeFormatter.ofLocalizedDateTime(style, FormatStyle.SHORT).format(message.receivedAt.atZone(ZoneId.systemDefault()))

    private suspend fun quotedText(message: MessageRecord, model: AppModel): String {
        val body = runCatching { model.body(message) }.getOrNull() ?: return message.preview
        return body.text ?: body.html?.let(HtmlText::plainText) ?: message.preview
    }

    // MARK: - Addresses

    fun text(field: Field): String = when (field) {
        Field.TO -> toText
        Field.CC -> ccText
        Field.BCC -> bccText
        else -> ""
    }

    fun setText(field: Field, value: String) {
        when (field) {
            Field.TO -> toText = value
            Field.CC -> ccText = value
            Field.BCC -> bccText = value
            else -> {}
        }
    }

    fun list(field: Field): MutableList<EmailAddress> = when (field) {
        Field.TO -> to
        Field.CC -> cc
        else -> bcc
    }

    /** Turns what's been typed into address tokens. Anything that isn't an address stays as text to fix. */
    fun commit(field: Field) {
        if (field == Field.SUBJECT || field == Field.BODY) return
        val list = list(field)
        val leftover = mutableListOf<String>()
        for (piece in text(field).split(',', ';')) {
            val parsed = parse(piece)
            if (parsed.isEmpty()) {
                piece.trim().takeIf { it.isNotEmpty() }?.let { leftover += it }
            } else {
                list += parsed.filter { new -> list.none { it.normalized == new.normalized } }
            }
        }
        setText(field, leftover.joinToString(", "))
    }

    fun add(address: EmailAddress, field: Field) {
        list(field) += address
        setText(field, "")
    }

    // MARK: - Attachments

    /** Starts uploading a file; it shows straight away with a spinner. */
    suspend fun attach(data: ByteArray, name: String, type: String, model: AppModel) {
        val pending = PendingAttachment(name = name, type = type, size = data.size)
        attachments += pending
        val updated = try {
            pending.copy(ready = model.upload(data, name, type))
        } catch (error: Throwable) {
            if (error is kotlinx.coroutines.CancellationException) throw error
            pending.copy(failure = error.message ?: "Couldn't upload")
        }
        val index = attachments.indexOfFirst { it.id == pending.id }
        if (index >= 0) attachments[index] = updated
    }

    fun remove(id: String) {
        attachments.removeAll { it.id == id }
    }

    // MARK: - Drafts

    /** Saves to Drafts if anything changed. A message emptied out deletes its draft. Returns true when a draft was written. */
    suspend fun save(model: AppModel): Boolean {
        if (savedContent == null || isFinished || isSaving) return false
        val snapshot = message
        if (snapshot.isBlank) {
            draftId?.let { id ->
                draftId = null
                model.discardDraft(id)
            }
            savedContent = snapshot.content
            return false
        }
        if (!hasEdits) return false
        isSaving = true
        try {
            val id = model.saveDraft(snapshot) ?: return false
            draftId = id
            savedContent = snapshot.content
            return true
        } finally {
            isSaving = false
        }
    }

    /** Throws the message away, including any saved draft. */
    suspend fun discard(model: AppModel) {
        isFinished = true
        draftId?.let { model.discardDraft(it) }
    }

    /** Hands the message to the model (which holds it for Undo Send). */
    suspend fun send(model: AppModel): Boolean {
        Field.entries.forEach(::commit)
        isSending = true
        try {
            val ok = model.send(message)
            if (ok) isFinished = true
            return ok
        } finally {
            isSending = false
        }
    }

    companion object {
        fun format(address: EmailAddress): String =
            if (!address.name.isNullOrEmpty()) "${address.name} <${address.email ?: ""}>" else address.email ?: ""

        /** Parses "Ann <ann@x.com>, bo@y.org" into addresses. */
        fun parse(field: String): List<EmailAddress> = field.split(',', ';').mapNotNull { raw ->
            val item = raw.trim()
            val open = item.lastIndexOf('<')
            val close = item.lastIndexOf('>')
            if (open >= 0 && close > open) {
                val email = item.substring(open + 1, close).trim()
                val name = item.substring(0, open).trim().trim('"').trim()
                return@mapNotNull if (email.contains('@')) EmailAddress(name.ifEmpty { null }, email) else null
            }
            if (item.contains('@') && !item.contains(' ')) EmailAddress(email = item) else null
        }
    }
}
