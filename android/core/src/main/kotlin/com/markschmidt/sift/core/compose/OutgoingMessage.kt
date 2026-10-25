package com.markschmidt.sift.core.compose

import com.markschmidt.sift.core.jmap.EmailAddress

/**
 * A message being written: what the compose screen edits, and what saving a
 * draft, sending and Undo Send pass around.
 */
data class OutgoingMessage(
    val identityId: String = "",
    val to: List<EmailAddress> = emptyList(),
    val cc: List<EmailAddress> = emptyList(),
    val bcc: List<EmailAddress> = emptyList(),
    val subject: String = "",
    val body: String = "",
    val attachments: List<Attachment> = emptyList(),
    /** Threading headers, so replies stay in their conversation. */
    val inReplyTo: List<String> = emptyList(),
    val references: List<String> = emptyList(),
    /** The message being answered, flagged $answered once this is sent. */
    val answering: String? = null,
    /** The saved draft this one replaces, if any. */
    val draftId: String? = null,
) {
    data class Attachment(val blobId: String, val name: String, val type: String, val size: Int)

    val recipients: List<EmailAddress> get() = to + cc + bcc

    /** Nothing worth keeping as a draft. */
    val isBlank: Boolean
        get() = recipients.isEmpty() && attachments.isEmpty() && subject.isBlank() && body.isBlank()

    /** The same content, ignoring which saved draft it lives in. */
    val content: OutgoingMessage get() = copy(draftId = null)
}

/** A message handed to Fastmail. With a hold, it can still be called back. */
data class Sending(
    val emailId: String,
    val submissionId: String,
    /** Seconds Fastmail holds it before delivery; 0 means it's already gone. */
    val heldFor: Int,
)

sealed class SendException(message: String) : Exception(message) {
    object NoIdentity : SendException("Choose an address to send from.")
    object NoRecipients : SendException("Add someone to send this to.")
    object TooLateToUndo : SendException("Too late to undo: the message has already been sent.")
}
