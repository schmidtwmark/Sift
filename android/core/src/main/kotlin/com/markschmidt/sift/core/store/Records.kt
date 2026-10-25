package com.markschmidt.sift.core.store

import com.markschmidt.sift.core.jmap.Email
import com.markschmidt.sift.core.jmap.EmailAddress
import com.markschmidt.sift.core.jmap.EmailBodyPart
import com.markschmidt.sift.core.jmap.Mailbox
import com.markschmidt.sift.core.jmap.MailboxRole
import kotlinx.serialization.Serializable
import java.time.Instant

data class MailboxRecord(
    val id: String,
    val name: String,
    val parentId: String? = null,
    val role: String? = null,
    val sortOrder: Int = 0,
    val totalEmails: Int = 0,
    val unreadEmails: Int = 0,
) {
    constructor(mailbox: Mailbox) : this(
        id = mailbox.id,
        name = mailbox.name,
        parentId = mailbox.parentId,
        role = mailbox.role,
        sortOrder = mailbox.sortOrder ?: 0,
        totalEmails = mailbox.totalEmails ?: 0,
        unreadEmails = mailbox.unreadEmails ?: 0,
    )

    val mailboxRole: MailboxRole? get() = MailboxRole.of(role)
}

object Keyword {
    const val SEEN = "\$seen"
    const val FLAGGED = "\$flagged"
    const val DRAFT = "\$draft"
    const val ANSWERED = "\$answered"

    /**
     * Marks mail Sift has already sorted, so every device (and a future
     * server) routes each message exactly once.
     */
    const val ROUTED = "\$siftrouted"
}

data class MessageRecord(
    val id: String,
    val threadId: String,
    val blobId: String? = null,
    val receivedAt: Instant,
    val sentAt: Instant? = null,
    val subject: String = "",
    val preview: String = "",
    val fromName: String? = null,
    val fromEmail: String = "",
    val to: List<EmailAddress> = emptyList(),
    val cc: List<EmailAddress> = emptyList(),
    val replyTo: List<EmailAddress> = emptyList(),
    val mailboxIds: List<String> = emptyList(),
    val keywords: List<String> = emptyList(),
    val hasAttachment: Boolean = false,
    val size: Int = 0,
    val messageIdHeader: String? = null,
    val inReplyTo: List<String> = emptyList(),
    val references: List<String> = emptyList(),
) {
    constructor(email: Email) : this(
        id = email.id,
        threadId = email.threadId ?: email.id,
        blobId = email.blobId,
        receivedAt = email.receivedAt ?: Instant.EPOCH,
        sentAt = email.sentAt,
        subject = email.subject ?: "",
        preview = email.preview ?: "",
        fromName = email.from?.firstOrNull()?.name,
        fromEmail = email.from?.firstOrNull()?.normalized ?: "",
        to = email.to ?: emptyList(),
        cc = email.cc ?: emptyList(),
        replyTo = email.replyTo ?: emptyList(),
        mailboxIds = (email.mailboxIds ?: emptyMap()).filterValues { it }.keys.sorted(),
        keywords = (email.keywords ?: emptyMap()).filterValues { it }.keys.map { it.lowercase() }.sorted(),
        hasAttachment = email.hasAttachment ?: false,
        size = email.size ?: 0,
        messageIdHeader = email.messageId?.firstOrNull(),
        inReplyTo = email.inReplyTo ?: emptyList(),
        references = email.references ?: emptyList(),
    )

    val isUnread: Boolean get() = Keyword.SEEN !in keywords
    val isFlagged: Boolean get() = Keyword.FLAGGED in keywords
    val isDraft: Boolean get() = Keyword.DRAFT in keywords
    val isRouted: Boolean get() = Keyword.ROUTED in keywords
    val sender: EmailAddress get() = EmailAddress(fromName, fromEmail)
    val senderDisplayName: String get() = fromName?.takeIf { it.isNotEmpty() } ?: fromEmail

    fun withKeyword(keyword: String, on: Boolean): MessageRecord {
        val updated = keywords.filter { it != keyword }.toMutableList()
        if (on) updated += keyword
        return copy(keywords = updated.sorted())
    }
}

@Serializable
data class BodyRecord(
    val messageId: String,
    val html: String? = null,
    val text: String? = null,
    val attachments: List<EmailBodyPart> = emptyList(),
    /** Inline parts referenced as `cid:` URLs, keyed by content-id. */
    val inlineParts: Map<String, EmailBodyPart> = emptyMap(),
    val fetchedAt: Long = System.currentTimeMillis(),
)

/**
 * How Sift treats a sender. The source of truth is synced through Fastmail
 * Contacts (`ContactsRuleStore`); this table is the local cache.
 */
data class SenderRecord(
    val email: String,
    val name: String? = null,
    val status: Status = Status.UNKNOWN,
    /** Mailbox ids new mail from this sender is filed into. Empty means "leave it in the Inbox". */
    val labelIds: List<String> = emptyList(),
    val notify: Boolean = false,
    val badge: Boolean = false,
    val updatedAt: Instant = Instant.now(),
) {
    enum class Status(val raw: String) {
        UNKNOWN("unknown"), SCREENED_IN("screenedIn"), SCREENED_OUT("screenedOut");

        companion object {
            fun of(raw: String) = entries.firstOrNull { it.raw == raw } ?: UNKNOWN
        }
    }

    /** The same decision, ignoring when it was made (for comparisons). */
    fun sameRule(other: SenderRecord) =
        email == other.email && status == other.status && labelIds == other.labelIds &&
            notify == other.notify && badge == other.badge
}

/** A conversation as shown in a list: the newest message plus thread stats. */
data class ThreadSummary(
    val latest: MessageRecord,
    val messageCount: Int,
    val unreadCount: Int,
    val participants: String,
) {
    val id: String get() = latest.threadId
}

/** A sender waiting in the Screener with their pending messages. */
data class ScreenerEntry(val email: String, val name: String?, val messages: List<MessageRecord>)
