package com.markschmidt.sift.core.jmap

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import java.time.Instant

object JmapCapability {
    const val CORE = "urn:ietf:params:jmap:core"
    const val MAIL = "urn:ietf:params:jmap:mail"
    const val SUBMISSION = "urn:ietf:params:jmap:submission"
    const val CONTACTS = "urn:ietf:params:jmap:contacts"
}

@Serializable
data class JmapSession(
    val apiUrl: String,
    val downloadUrl: String,
    val uploadUrl: String,
    val eventSourceUrl: String,
    val username: String,
    val state: String,
    val primaryAccounts: Map<String, String> = emptyMap(),
    val capabilities: Map<String, JsonElement> = emptyMap(),
    val accounts: Map<String, Account>? = null,
) {
    @Serializable
    data class Account(
        val name: String? = null,
        val isReadOnly: Boolean? = null,
        val accountCapabilities: Map<String, JsonElement>? = null,
    )

    val mailAccountId: String? get() = primaryAccounts[JmapCapability.MAIL]

    /**
     * Scopes Sift needs that this token lacks, named as Fastmail's token
     * settings name them. Empty when the token is good to go.
     */
    val missingScopes: List<String>
        get() {
            fun grants(capability: String): Boolean {
                val id = primaryAccounts[capability] ?: return false
                val granted = accounts?.get(id)?.accountCapabilities ?: return true
                return granted[capability] != null
            }
            val missing = mutableListOf<String>()
            if (!grants(JmapCapability.MAIL)) {
                missing += "Email"
            } else if (mailAccountId?.let { accounts?.get(it)?.isReadOnly } == true) {
                missing += "Email write access (the token is read-only)"
            }
            if (!grants(JmapCapability.SUBMISSION)) missing += "Email submission"
            if (!grants(JmapCapability.CONTACTS)) missing += "Contacts"
            return missing
        }

    fun downloadUrl(accountId: String, blobId: String, name: String, type: String): String =
        downloadUrl
            .replace("{accountId}", accountId.pathEscaped())
            .replace("{blobId}", blobId.pathEscaped())
            .replace("{name}", name.pathEscaped())
            .replace("{type}", type.queryEscaped())

    fun uploadUrl(accountId: String): String = uploadUrl.replace("{accountId}", accountId.pathEscaped())

    fun eventSourceUrl(types: String = "*", ping: Int = 60): String =
        eventSourceUrl
            .replace("{types}", types)
            .replace("{closeafter}", "no")
            .replace("{ping}", ping.toString())
}

private const val UNRESERVED = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"

private fun String.percentEscaped(allowed: String): String = buildString {
    for (byte in this@percentEscaped.toByteArray(Charsets.UTF_8)) {
        val char = (byte.toInt() and 0xFF).toChar()
        if (byte >= 0 && (char in UNRESERVED || char in allowed)) append(char) else append("%%%02X".format(byte.toInt() and 0xFF))
    }
}

/** A single path segment: `/` is escaped. */
internal fun String.pathEscaped() = percentEscaped("!$&'()*+,;=:@")

/** A query value: `&`, `=`, `+` and `/` are escaped. */
internal fun String.queryEscaped() = percentEscaped("!$'()*,;:@?")

// MARK: - Mail objects

enum class MailboxRole(val raw: String) {
    INBOX("inbox"), ARCHIVE("archive"), DRAFTS("drafts"), SENT("sent"), TRASH("trash"), JUNK("junk"),
    IMPORTANT("important"), ALL("all"), FLAGGED("flagged"), SUBSCRIBED("subscribed");

    companion object {
        fun of(raw: String?) = entries.firstOrNull { it.raw == raw }
    }
}

@Serializable
data class Mailbox(
    val id: String,
    val name: String,
    val parentId: String? = null,
    val role: String? = null,
    val sortOrder: Int? = null,
    val totalEmails: Int? = null,
    val unreadEmails: Int? = null,
    val totalThreads: Int? = null,
    val unreadThreads: Int? = null,
)

@Serializable
data class EmailAddress(val name: String? = null, val email: String? = null) {
    /** Lowercased address, used as the key for sender rules. */
    val normalized: String get() = (email ?: "").trim().lowercase()

    val displayName: String get() = name?.takeIf { it.isNotEmpty() } ?: email ?: ""
}

@Serializable
data class EmailBodyPart(
    val partId: String? = null,
    val blobId: String? = null,
    val size: Int? = null,
    val name: String? = null,
    val type: String? = null,
    val charset: String? = null,
    val disposition: String? = null,
    val cid: String? = null,
)

@Serializable
data class EmailBodyValue(val value: String, val isEncodingProblem: Boolean? = null, val isTruncated: Boolean? = null)

@Serializable
data class Email(
    val id: String,
    val blobId: String? = null,
    val threadId: String? = null,
    val mailboxIds: Map<String, Boolean>? = null,
    val keywords: Map<String, Boolean>? = null,
    val size: Int? = null,
    @Serializable(with = InstantSerializer::class) val receivedAt: Instant? = null,
    @Serializable(with = InstantSerializer::class) val sentAt: Instant? = null,
    val from: List<EmailAddress>? = null,
    val to: List<EmailAddress>? = null,
    val cc: List<EmailAddress>? = null,
    val bcc: List<EmailAddress>? = null,
    val replyTo: List<EmailAddress>? = null,
    val subject: String? = null,
    val preview: String? = null,
    val hasAttachment: Boolean? = null,
    val messageId: List<String>? = null,
    val inReplyTo: List<String>? = null,
    val references: List<String>? = null,
    val htmlBody: List<EmailBodyPart>? = null,
    val textBody: List<EmailBodyPart>? = null,
    val attachments: List<EmailBodyPart>? = null,
    val bodyValues: Map<String, EmailBodyValue>? = null,
) {
    /** Everyone the message was addressed to. */
    val recipients: List<EmailAddress> get() = (to ?: emptyList()) + (cc ?: emptyList()) + (bcc ?: emptyList())

    companion object {
        val listProperties = listOf(
            "id", "blobId", "threadId", "mailboxIds", "keywords", "size", "receivedAt", "sentAt",
            "from", "to", "cc", "replyTo", "subject", "preview", "hasAttachment",
            "messageId", "inReplyTo", "references",
        )
        val bodyProperties = listOf("id", "htmlBody", "textBody", "attachments", "bodyValues")
    }
}

@Serializable
data class Identity(
    val id: String,
    val name: String = "",
    val email: String,
    val mayDelete: Boolean? = null,
    /** The plain-text signature set up in Fastmail, if any. */
    val textSignature: String? = null,
)

@Serializable
data class SearchSnippet(val emailId: String, val subject: String? = null, val preview: String? = null)

/** Push payload delivered over EventSource: account → type → new state. */
@Serializable
data class StateChange(val changed: Map<String, Map<String, String>> = emptyMap())

// MARK: - Standard method responses

@Serializable
data class GetResponse<T>(
    val accountId: String? = null,
    val state: String? = null,
    val list: List<T> = emptyList(),
    val notFound: List<String>? = null,
)

@Serializable
data class QueryResponse(
    val accountId: String? = null,
    val queryState: String? = null,
    val ids: List<String> = emptyList(),
    val position: Int? = null,
    val total: Int? = null,
)

@Serializable
data class ChangesResponse(
    val accountId: String? = null,
    val oldState: String,
    val newState: String,
    val hasMoreChanges: Boolean,
    val created: List<String> = emptyList(),
    val updated: List<String> = emptyList(),
    val destroyed: List<String> = emptyList(),
)

@Serializable
data class SetError(
    val type: String,
    @SerialName("description") val detail: String? = null,
    /** For `invalidProperties`: which properties the server rejected. */
    val properties: List<String>? = null,
) {
    override fun toString(): String {
        var text = type
        if (!properties.isNullOrEmpty()) text += " [${properties.joinToString(", ")}]"
        if (!detail.isNullOrEmpty()) text += ": $detail"
        return text
    }
}

/** A per-object failure from a `/set` call, labelled with what Sift was trying to do. */
class SetFailure(val error: SetError, val operation: String) :
    Exception("Fastmail wouldn't $operation ($error).")

@Serializable
data class SetResponse(
    val accountId: String? = null,
    val newState: String? = null,
    val created: Map<String, JsonObject>? = null,
    val updated: Map<String, JsonElement?>? = null,
    val destroyed: List<String>? = null,
    val notCreated: Map<String, SetError>? = null,
    val notUpdated: Map<String, SetError>? = null,
    val notDestroyed: Map<String, SetError>? = null,
) {
    /** Throws the first per-object failure, if any, labelled with what was being attempted. */
    fun throwIfFailed(operation: String) {
        val error = notCreated?.values?.firstOrNull() ?: notUpdated?.values?.firstOrNull()
            ?: notDestroyed?.values?.firstOrNull() ?: return
        throw SetFailure(error, operation)
    }

    fun createdId(key: String): String? = created?.get(key)?.get("id").stringValue
}
