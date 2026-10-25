package com.markschmidt.sift.core

import com.markschmidt.sift.core.jmap.EmailAddress
import com.markschmidt.sift.core.jmap.Mailbox
import com.markschmidt.sift.core.search.SearchQuery
import com.markschmidt.sift.core.store.BodyRecord
import com.markschmidt.sift.core.store.MailStore
import com.markschmidt.sift.core.store.MailStore.Companion.threadMessages
import com.markschmidt.sift.core.store.SenderRecord
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.take
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class MailStoreTest {
    @Test fun threadsCollapseAndCount() = runTest {
        val store = MailStore.inMemory()
        store.upsertEmails(listOf(
            email("1", "a@x.com", name = "Ann", received = Instant.ofEpochSecond(100), thread = "T"),
            email("2", "b@x.com", name = "Bo", keywords = listOf("\$seen"), received = Instant.ofEpochSecond(200), thread = "T"),
            email("3", "c@x.com", mailboxes = listOf("feed"), received = Instant.ofEpochSecond(300)),
        ))
        val inbox = store.threads("inbox", 50)
        assertEquals(listOf("2"), inbox.map { it.latest.id })
        assertEquals(2, inbox.first().messageCount)
        assertEquals(1, inbox.first().unreadCount)
        assertEquals(listOf("Ann", "Bo"), inbox.first().participants.split(",").sorted())

        assertEquals(listOf("3", "2"), store.threads(null, 50).map { it.latest.id })
    }

    @Test fun screenerGroupsBySender() = runTest {
        val store = MailStore.inMemory()
        store.upsertEmails(listOf(
            email("1", "a@x.com", mailboxes = listOf("screener"), received = Instant.ofEpochSecond(100)),
            email("2", "b@x.com", mailboxes = listOf("screener"), received = Instant.ofEpochSecond(200)),
            email("3", "a@x.com", mailboxes = listOf("screener"), received = Instant.ofEpochSecond(300)),
        ))
        val entries = store.screenerEntries("screener")
        assertEquals(listOf("a@x.com", "b@x.com"), entries.map { it.email })
        assertEquals(listOf("3", "1"), entries.first().messages.map { it.id })
    }

    @Test fun localSearchCombinesTextAndFilters() = runTest {
        val store = MailStore.inMemory()
        store.replaceMailboxes(listOf(Mailbox(id = "feed", name = "Feed")))
        store.upsertEmails(listOf(
            email("1", "billing@stripe.com", subject = "Your invoice", mailboxes = listOf("feed")),
            email("2", "billing@stripe.com", subject = "Your receipt"),
            email("3", "pal@friends.org", subject = "Invoice joke", keywords = listOf("\$seen")),
        ))
        assertEquals(listOf("1", "3"), store.search(SearchQuery("invo")).map { it.id }.sorted())
        assertEquals(listOf("1"), store.search(SearchQuery("invoice from:stripe")).map { it.id })
        assertEquals(listOf("2"), store.search(SearchQuery("from:stripe -in:feed")).map { it.id })
        assertEquals(listOf("1"), store.search(SearchQuery("invoice is:unread")).map { it.id })
        assertEquals(listOf("2", "3"), store.search(SearchQuery("receipt OR joke")).map { it.id }.sorted())
        assertEquals(listOf("1"), store.search(SearchQuery("in:FEED")).map { it.id })
    }

    @Test fun bodiesAreIndexedForSearch() = runTest {
        val store = MailStore.inMemory()
        store.upsertEmails(listOf(email("1", "a@x.com")))
        store.save(BodyRecord("1", html = "<p>The <b>zeppelin</b> landed</p>"))
        assertEquals(listOf("1"), store.search(SearchQuery("zeppelin")).map { it.id })
        assertEquals(listOf("1"), store.search(SearchQuery("body:landed")).map { it.id })
        // A later metadata update keeps the body in the index.
        store.upsertEmails(listOf(email("1", "a@x.com", keywords = listOf("\$seen"))))
        assertEquals(listOf("1"), store.search(SearchQuery("zeppelin")).map { it.id })
    }

    @Test fun deletingRemovesFromIndex() = runTest {
        val store = MailStore.inMemory()
        store.upsertEmails(listOf(email("1", "a@x.com", subject = "unique-word")))
        store.delete(listOf("1"))
        assertTrue(store.search(SearchQuery("unique")).isEmpty())
        assertTrue(store.messagesIn("inbox").isEmpty())
    }

    @Test fun badgeCountsOnlyBadgedSendersOutsideQuarantine() = runTest {
        val store = MailStore.inMemory()
        store.save(SenderRecord(email = "vip@x.com", status = SenderRecord.Status.SCREENED_IN, badge = true))
        store.upsertEmails(listOf(
            email("1", "vip@x.com"),
            email("2", "vip@x.com", keywords = listOf("\$seen")),
            email("3", "vip@x.com", mailboxes = listOf("trash")),
            email("4", "other@x.com"),
        ))
        assertEquals(1, store.badgeCount(boxes.quarantined))
    }

    @Test fun suggestsAddressesYouWroteToFirst() = runTest {
        val store = MailStore.inMemory()
        store.upsertEmails(listOf(
            email("1", "sam@loud.com", name = "Sam Loud"),
            email("2", "sam@loud.com", name = "Sam Loud"),
            email("3", "sally@quiet.com", name = "Sally Quiet"),
        ))
        store.recordSentRecipients(listOf("Sally@Quiet.com", "sandra@nowhere.com"))
        val suggestions = store.addressSuggestions("sa")
        assertEquals(listOf("sally@quiet.com", "sam@loud.com", "sandra@nowhere.com"), suggestions.map { it.normalized })
        assertEquals(EmailAddress("Sally Quiet", "sally@quiet.com"), suggestions.first())
        assertEquals(listOf("sam@loud.com"), store.addressSuggestions("loud").map { it.normalized })
    }

    @Test fun observedQueriesFollowWrites() = runBlocking<Unit> {
        val store = MailStore.inMemory()
        store.upsertEmails(listOf(email("1", "a@x.com", subject = "Appointment", thread = "T1")))
        val firstSeen = CompletableDeferred<Unit>()
        val values = async {
            store.observe { threadMessages("T1") }.onEach { firstSeen.complete(Unit) }.take(2).toList()
        }
        firstSeen.await()
        store.upsertEmails(listOf(email("2", "b@x.com", thread = "T1", received = Instant.ofEpochSecond(2_000_000_100))))
        val seen = withTimeout(5_000) { values.await() }
        assertEquals(listOf(listOf("1"), listOf("1", "2")), seen.map { list -> list.map { it.id } })
    }
}
