package com.markschmidt.sift.core.screener

import com.markschmidt.sift.core.jmap.EmailAddress
import com.markschmidt.sift.core.jmap.JsonValue
import com.markschmidt.sift.core.store.Keyword
import com.markschmidt.sift.core.store.MessageRecord
import com.markschmidt.sift.core.store.SenderRecord
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonPrimitive
import java.time.Instant

/** The mailboxes Sift's screens and routing depend on. */
data class SpecialMailboxes(
    val inbox: String,
    val screener: String,
    val screenedOut: String,
    val archive: String? = null,
    val trash: String? = null,
    val junk: String? = null,
    val sent: String? = null,
    val drafts: String? = null,
) {
    /** Piles that never notify, badge, or count as "real" mail. */
    val quarantined: List<String> get() = listOf(screener, screenedOut) + listOfNotNull(trash, junk)
}

/** A JMAP `Email/set` patch: `"mailboxIds/<id>": true|null`, `"keywords/<kw>": true|null`. */
typealias EmailPatch = Map<String, JsonValue>

val ON: JsonValue = JsonPrimitive(true)
val OFF: JsonValue = JsonNull

data class RoutingContext(
    val mailboxes: SpecialMailboxes,
    /** Mail received before this moment is grandfathered and never screened. */
    val activatedAt: Instant,
    /** The user's own addresses (identities). */
    val ownAddresses: Set<String>,
    /** People in the user's contacts or whom they've written to. */
    val knownAddresses: Set<String>,
    val rules: Map<String, SenderRecord>,
)

data class RoutingPlan(
    val patches: Map<String, EmailPatch> = emptyMap(),
    /**
     * Known-but-unruled senders (contacts, people you've written to) that
     * should be recorded as screened in so every device agrees.
     */
    val autoApproved: List<EmailAddress> = emptyList(),
)

/**
 * Decides where incoming mail goes. Pure, so it's shared by every device and
 * trivially testable; `SyncEngine` applies the plan.
 */
object Router {
    fun plan(messages: List<MessageRecord>, context: RoutingContext): RoutingPlan {
        val patches = LinkedHashMap<String, EmailPatch>()
        val autoApproved = mutableListOf<EmailAddress>()
        val approved = mutableSetOf<String>()
        val boxes = context.mailboxes

        for (message in messages) {
            if (boxes.inbox !in message.mailboxIds || message.isRouted || message.isDraft ||
                message.receivedAt < context.activatedAt
            ) continue

            val sender = message.fromEmail
            val patch = linkedMapOf<String, JsonValue>("keywords/${Keyword.ROUTED}" to ON)
            val rule = context.rules[sender]

            if (sender.isEmpty() || sender in context.ownAddresses) {
                // Your own mail (or something malformed) stays put.
            } else if (rule != null && rule.status != SenderRecord.Status.UNKNOWN) {
                if (rule.status == SenderRecord.Status.SCREENED_OUT) {
                    patch += move(listOf(boxes.inbox), listOf(boxes.screenedOut))
                    patch["keywords/${Keyword.SEEN}"] = ON
                } else {
                    patch += file(rule.labelIds, boxes.inbox, boxes.inbox)
                }
            } else if (sender in context.knownAddresses) {
                if (approved.add(sender)) autoApproved += message.sender
            } else {
                patch += move(listOf(boxes.inbox), listOf(boxes.screener))
            }
            patches[message.id] = patch
        }
        return RoutingPlan(patches, autoApproved)
    }

    /**
     * Patches that release a sender's waiting mail from the Screener into
     * [labels] (or the Inbox when no labels are chosen).
     */
    fun screenIn(messages: List<MessageRecord>, labels: List<String>, mailboxes: SpecialMailboxes): Map<String, EmailPatch> =
        messages.associate { it.id to file(labels, mailboxes.inbox, mailboxes.screener) }

    fun screenOut(messages: List<MessageRecord>, mailboxes: SpecialMailboxes): Map<String, EmailPatch> =
        messages.associate { message ->
            message.id to (move(message.mailboxIds, listOf(mailboxes.screenedOut)) + ("keywords/${Keyword.SEEN}" to ON))
        }

    fun file(labels: List<String>, inbox: String, source: String): EmailPatch {
        val destinations = labels.ifEmpty { listOf(inbox) }
        return move(listOf(source), destinations)
    }

    fun move(sources: List<String>, destinations: List<String>): EmailPatch {
        val patch = linkedMapOf<String, JsonValue>()
        for (id in sources) if (id !in destinations) patch["mailboxIds/$id"] = OFF
        for (id in destinations) patch["mailboxIds/$id"] = ON
        return patch
    }
}

/** Applies a JMAP patch locally, for optimistic UI updates. */
fun MessageRecord.applying(patch: EmailPatch): MessageRecord {
    var copy = this
    val mailboxes = mailboxIds.toMutableSet()
    for ((path, value) in patch) {
        val parts = path.split("/", limit = 2)
        if (parts.size != 2) continue
        val isOn = value != JsonNull && value != JsonPrimitive(false)
        when (parts[0]) {
            "mailboxIds" -> if (isOn) mailboxes += parts[1] else mailboxes -= parts[1]
            "keywords" -> copy = copy.withKeyword(parts[1], isOn)
        }
    }
    return copy.copy(mailboxIds = mailboxes.sorted())
}
