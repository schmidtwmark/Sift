package com.markschmidt.sift.core

import com.markschmidt.sift.core.screener.OFF
import com.markschmidt.sift.core.screener.ON
import com.markschmidt.sift.core.screener.Router
import com.markschmidt.sift.core.screener.RoutingContext
import com.markschmidt.sift.core.screener.applying
import com.markschmidt.sift.core.store.MessageRecord
import com.markschmidt.sift.core.store.SenderRecord
import com.markschmidt.sift.core.store.SenderRecord.Status
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

class RouterTest {
    private val activated = Instant.ofEpochSecond(1_900_000_000)

    private fun context(rules: List<SenderRecord> = emptyList(), known: Set<String> = emptySet()) = RoutingContext(
        mailboxes = boxes, activatedAt = activated, ownAddresses = setOf("me@fastmail.com"),
        knownAddresses = known, rules = rules.associateBy { it.email },
    )

    @Test fun unknownSendersGoToTheScreener() {
        val plan = Router.plan(listOf(MessageRecord(email("1", from = "New@Example.com"))), context())
        assertEquals(
            mapOf("keywords/\$siftrouted" to ON, "mailboxIds/inbox" to OFF, "mailboxIds/screener" to ON),
            plan.patches["1"],
        )
    }

    @Test fun screenedInSendersAreFiledIntoTheirLabels() {
        val rule = SenderRecord(email = "news@acme.com", status = Status.SCREENED_IN, labelIds = listOf("feed"))
        val plan = Router.plan(listOf(MessageRecord(email("1", from = "news@acme.com"))), context(listOf(rule)))
        assertEquals(
            mapOf("keywords/\$siftrouted" to ON, "mailboxIds/inbox" to OFF, "mailboxIds/feed" to ON),
            plan.patches["1"],
        )
    }

    @Test fun screenedInWithoutLabelsStaysInInbox() {
        val rule = SenderRecord(email = "pal@acme.com", status = Status.SCREENED_IN)
        val plan = Router.plan(listOf(MessageRecord(email("1", from = "pal@acme.com"))), context(listOf(rule)))
        assertEquals(ON, plan.patches["1"]?.get("mailboxIds/inbox"))
        assertNull(plan.patches["1"]?.get("mailboxIds/screener"))
    }

    @Test fun screenedOutSendersAreHiddenAndMarkedRead() {
        val rule = SenderRecord(email = "spam@acme.com", status = Status.SCREENED_OUT)
        val plan = Router.plan(listOf(MessageRecord(email("1", from = "spam@acme.com"))), context(listOf(rule)))
        val patch = plan.patches.getValue("1")
        assertEquals(ON, patch["mailboxIds/out"])
        assertEquals(OFF, patch["mailboxIds/inbox"])
        assertEquals(ON, patch["keywords/\$seen"])
    }

    @Test fun contactsAreAutoApprovedOnce() {
        val messages = listOf(email("1", from = "friend@x.com"), email("2", from = "friend@x.com")).map(::MessageRecord)
        val plan = Router.plan(messages, context(known = setOf("friend@x.com")))
        assertEquals(listOf("friend@x.com"), plan.autoApproved.map { it.normalized })
        assertEquals(mapOf("keywords/\$siftrouted" to ON), plan.patches["1"])
    }

    @Test fun skipsGrandfatheredRoutedDraftsAndOwnMail() {
        val old = email("old", from = "a@x.com", received = activated.minusSeconds(1))
        val routed = email("routed", from = "a@x.com", keywords = listOf("\$siftrouted"))
        val elsewhere = email("junk", from = "a@x.com", mailboxes = listOf("junk"))
        val draft = email("draft", from = "a@x.com", keywords = listOf("\$draft"))
        val plan = Router.plan(listOf(old, routed, elsewhere, draft).map(::MessageRecord), context())
        assertTrue(plan.patches.isEmpty())

        val mine = Router.plan(listOf(MessageRecord(email("me", from = "me@fastmail.com"))), context())
        assertEquals(mapOf("keywords/\$siftrouted" to ON), mine.patches["me"])
    }

    @Test fun ruleBeatsContactsAndUnknownRuleScreens() {
        val out = SenderRecord(email = "friend@x.com", status = Status.SCREENED_OUT)
        val plan = Router.plan(listOf(MessageRecord(email("1", from = "friend@x.com"))), context(listOf(out), known = setOf("friend@x.com")))
        assertEquals(ON, plan.patches["1"]?.get("mailboxIds/out"))
        assertTrue(plan.autoApproved.isEmpty())

        val undecided = SenderRecord(email = "maybe@x.com", status = Status.UNKNOWN, notify = true)
        val screened = Router.plan(listOf(MessageRecord(email("2", from = "maybe@x.com"))), context(listOf(undecided)))
        assertEquals(ON, screened.patches["2"]?.get("mailboxIds/screener"))
    }

    @Test fun screenInReleasesIntoInboxWhenNoLabels() {
        val waiting = MessageRecord(email("1", from = "a@x.com", mailboxes = listOf("screener")))
        assertEquals(
            mapOf("mailboxIds/screener" to OFF, "mailboxIds/inbox" to ON),
            Router.screenIn(listOf(waiting), emptyList(), boxes)["1"],
        )
        assertEquals(
            mapOf("mailboxIds/screener" to OFF, "mailboxIds/feed" to ON, "mailboxIds/inbox" to ON),
            Router.screenIn(listOf(waiting), listOf("feed", "inbox"), boxes)["1"],
        )
    }

    @Test fun screenOutMovesEverythingAndMarksRead() {
        val waiting = MessageRecord(email("1", from = "a@x.com", mailboxes = listOf("screener", "feed")))
        assertEquals(
            mapOf("mailboxIds/feed" to OFF, "mailboxIds/screener" to OFF, "mailboxIds/out" to ON, "keywords/\$seen" to ON),
            Router.screenOut(listOf(waiting), boxes)["1"],
        )
    }

    @Test fun patchesApplyLocally() {
        val message = MessageRecord(email("1", from = "a@x.com"))
        val moved = message.applying(mapOf("mailboxIds/inbox" to OFF, "mailboxIds/feed" to ON, "keywords/\$seen" to ON))
        assertEquals(listOf("feed"), moved.mailboxIds)
        assertFalse(moved.isUnread)
        assertTrue(moved.applying(mapOf("keywords/\$seen" to OFF)).isUnread)
    }
}
