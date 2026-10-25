package com.markschmidt.sift.core.screener

import com.markschmidt.sift.core.jmap.Email
import com.markschmidt.sift.core.store.MessageRecord
import com.markschmidt.sift.core.store.SenderRecord

/** A screening rule inferred from where the user already files a sender's mail. */
data class RuleSuggestion(
    val email: String,
    val name: String? = null,
    val status: SenderRecord.Status,
    /** Folders new mail should go to; empty means the Inbox. */
    val labelIds: List<String>,
    /** How many messages the suggestion is based on. */
    val evidence: Int,
) {
    val rule: SenderRecord get() = SenderRecord(email = email, name = name, status = status, labelIds = labelIds)
}

/** Why a message in a folder being sorted goes where it does. */
sealed interface SortReason {
    /** It's in other folders too (these), so it only leaves the one being sorted. */
    data class AlreadyFiled(val mailboxIds: List<String>) : SortReason
    /** Sent from one of your addresses (this one), so it goes to Sent. */
    data class OwnMail(val address: String) : SortReason
    /** The sender's screening rule. */
    data class Rule(val status: SenderRecord.Status) : SortReason
    /** Where most of the sender's other mail is filed. */
    data class History(val status: SenderRecord.Status, val evidence: Int) : SortReason
    /** No rule and no other filed mail from the sender: the Inbox. */
    data object NoHistory : SortReason
}

/**
 * Infers per-sender filing from existing mail. Pure, so it's shared by rule
 * suggestions and folder sorting, and unit-tested.
 */
object SortingInference {
    data class Inputs(
        val mailboxes: SpecialMailboxes,
        /** The user's own folders (no system role, not Screener/Screened Out). */
        val userLabels: Set<String>,
        /** Mailboxes whose contents say nothing about intent (an unsorted import, Drafts…). */
        val ignored: Set<String>,
        val ownAddresses: Set<String>,
    )

    /** A sender's mail counts toward a folder when at least this share of it is filed there. */
    private const val MAJORITY = 0.5
    private const val JUNK_SHARE = 0.8

    fun suggestions(
        messages: List<MessageRecord>,
        inputs: Inputs,
        existing: Map<String, SenderRecord> = emptyMap(),
    ): List<RuleSuggestion> {
        val boxes = inputs.mailboxes
        val skip = inputs.ignored + listOfNotNull(boxes.screener, boxes.screenedOut, boxes.trash, boxes.sent, boxes.drafts)

        class Tally {
            var name: String? = null
            var total = 0
            val labels = mutableMapOf<String, Int>()
            var inboxOrArchive = 0
            var junk = 0
        }
        val tallies = LinkedHashMap<String, Tally>()
        for (message in messages) {
            val sender = message.fromEmail
            if (sender.isEmpty() || sender in inputs.ownAddresses) continue
            if (existing[sender]?.let { it.status == SenderRecord.Status.UNKNOWN } == false) continue
            if (message.mailboxIds.any { it in skip }) continue
            val tally = tallies.getOrPut(sender) { Tally() }
            if (tally.name == null && !message.fromName.isNullOrEmpty()) tally.name = message.fromName
            tally.total += 1
            val labels = message.mailboxIds.filter { it in inputs.userLabels }
            for (label in labels) tally.labels[label] = (tally.labels[label] ?: 0) + 1
            if (labels.isEmpty()) {
                if (boxes.inbox in message.mailboxIds || boxes.archive?.let { it in message.mailboxIds } == true) {
                    tally.inboxOrArchive += 1
                }
                if (boxes.junk?.let { it in message.mailboxIds } == true) tally.junk += 1
            }
        }

        return tallies.mapNotNull { (email, tally) ->
            val total = tally.total.toDouble()
            if (tally.total >= 2 && tally.junk / total >= JUNK_SHARE) {
                return@mapNotNull RuleSuggestion(email, tally.name, SenderRecord.Status.SCREENED_OUT, emptyList(), tally.total)
            }
            val labels = tally.labels.filter { it.value / total >= MAJORITY }.keys.sorted()
            if (labels.isNotEmpty()) {
                return@mapNotNull RuleSuggestion(email, tally.name, SenderRecord.Status.SCREENED_IN, labels, tally.total)
            }
            if (tally.inboxOrArchive / total >= MAJORITY) {
                return@mapNotNull RuleSuggestion(email, tally.name, SenderRecord.Status.SCREENED_IN, emptyList(), tally.total)
            }
            null
        }.sortedWith(compareByDescending<RuleSuggestion> { it.evidence }.thenBy { it.email })
    }

    /**
     * Where an old message from [sender] belongs: the sender's folders, or the
     * Inbox when they're screened in without one or there's nothing to go on.
     */
    fun destination(
        sender: String, rule: SenderRecord?, suggestion: RuleSuggestion?, isOwn: Boolean,
        mailboxes: SpecialMailboxes, fallback: List<String>,
    ): List<String> = decide(sender, rule, suggestion, isOwn, mailboxes, fallback).first

    /** [destination], plus why, for the folder-sort preview. */
    fun decide(
        sender: String, rule: SenderRecord?, suggestion: RuleSuggestion?, isOwn: Boolean,
        mailboxes: SpecialMailboxes, fallback: List<String>,
    ): Pair<List<String>, SortReason> {
        if (isOwn && mailboxes.sent != null) return listOf(mailboxes.sent) to SortReason.OwnMail(sender)
        // An explicit rule beats an inferred one.
        val (status, labels, reason) = when {
            rule != null && rule.status != SenderRecord.Status.UNKNOWN -> Triple(rule.status, rule.labelIds, SortReason.Rule(rule.status))
            suggestion != null -> Triple(suggestion.status, suggestion.labelIds, SortReason.History(suggestion.status, suggestion.evidence))
            else -> return fallback to SortReason.NoHistory
        }
        return when (status) {
            SenderRecord.Status.SCREENED_OUT -> listOf(mailboxes.screenedOut) to reason
            SenderRecord.Status.SCREENED_IN -> {
                val filed = labels.filter { it != mailboxes.inbox }
                filed.ifEmpty { listOf(mailboxes.inbox) } to reason
            }
            SenderRecord.Status.UNKNOWN -> fallback to SortReason.NoHistory
        }
    }

    /**
     * The address that receives most of a folder's mail, when it clearly
     * dominates: in an import from another provider, that's the user's old address.
     */
    fun dominantRecipient(emails: List<Email>, minimumShare: Double = 0.25): String? {
        val counts = mutableMapOf<String, Int>()
        for (email in emails) {
            for (address in email.recipients.map { it.normalized }.toSet()) {
                if (address.isNotEmpty()) counts[address] = (counts[address] ?: 0) + 1
            }
        }
        val (address, count) = counts.maxByOrNull { it.value } ?: return null
        return if (count.toDouble() / maxOf(emails.size, 1) >= minimumShare) address else null
    }
}
