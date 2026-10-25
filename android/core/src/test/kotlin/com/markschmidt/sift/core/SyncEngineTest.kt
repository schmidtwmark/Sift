package com.markschmidt.sift.core

import com.markschmidt.sift.core.demo.DemoServer
import com.markschmidt.sift.core.jmap.EmailAddress
import com.markschmidt.sift.core.compose.OutgoingMessage
import com.markschmidt.sift.core.privacy.TrackerDetector
import com.markschmidt.sift.core.screener.ContactsRuleStoreException
import com.markschmidt.sift.core.search.SearchQuery
import com.markschmidt.sift.core.store.Keyword
import com.markschmidt.sift.core.store.SenderRecord
import com.markschmidt.sift.core.sync.SyncEngine
import kotlinx.coroutines.runBlocking
import java.time.Instant
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

/** End to end against the demo server: the JMAP layer, rules in Contacts, routing and the store together. */
class SyncEngineTest {
    @Suppress("UNCHECKED_CAST")
    private fun DemoServer.groupNamed(name: String) =
        siftGroups().firstOrNull { (it["name"] as? Map<String, Any?>)?.get("full") == name }

    @Suppress("UNCHECKED_CAST")
    private fun Map<String, Any?>.members() = this["members"] as? Map<String, Any?>

    @Test fun screensNewSendersAndKeepsContactsInInbox() = runBlocking<Unit> {
        val server = DemoServer()
        val engine = startedEngine(server)

        val screener = assertNotNull(server.mailboxId(SyncEngine.SCREENER_NAME))
        assertNotNull(server.mailboxId(SyncEngine.SCREENED_OUT_NAME))

        val entries = engine.store.screenerEntries(screener)
        assertEquals(
            setOf("hello@paperline.example", "kai@lumenlabs.example", "bookings@fjordair.example",
                "reminders@coastaldental.example", "orders@northwind.example"),
            entries.map { it.email }.toSet(),
        )
        // Contacts were auto-approved and stayed put.
        val inbox = engine.store.messagesIn("inbox")
        assertEquals(setOf("alex@rivera.example", "mom@family.example"), inbox.map { it.fromEmail }.toSet())
        assertTrue(inbox.filter { it.receivedAt > demoActivation }.all { Keyword.ROUTED in server.emailKeywords(it.id) })
        assertEquals(SenderRecord.Status.SCREENED_IN, engine.store.sender("mom@family.example")?.status)
        // Grandfathered history was not touched.
        assertEquals(2, engine.store.messagesIn("receipts").size)
    }

    @Test fun screeningInFilesMailAndLaterArrivals() = runBlocking<Unit> {
        val server = DemoServer()
        val engine = startedEngine(server)

        engine.screenIn("bookings@fjordair.example", "Fjord Air", listOf("travel"))
        val booking = engine.store.messagesFrom("bookings@fjordair.example").first()
        assertEquals(setOf("travel"), server.emailMailboxes(booking.id))

        // The rule lives in Fastmail Contacts as group membership, with no card per sender.
        @Suppress("UNCHECKED_CAST")
        val memberOf = server.siftGroups().filter { it.members()?.get("mailto:bookings@fjordair.example") == true }
            .map { (it["name"] as Map<String, Any?>)["full"] }
        assertEquals(setOf("Sift: Screened In", "Sift label: Travel"), memberOf.toSet())
        @Suppress("UNCHECKED_CAST")
        assertTrue(server.siftGroups().all { (it["addressBookIds"] as? Map<String, Any?>)?.get("personal") == true })
        assertEquals(2, server.individualCardCount)  // just the user's own two contacts

        // A new message from the same sender is filed automatically.
        val next = server.deliver("Fjord Air" to "bookings@fjordair.example", "Check in now", "Open")
        engine.refresh()
        assertEquals(setOf("travel"), server.emailMailboxes(next))

        // A fresh device reads the same rules back.
        val other = engine(server)
        other.start()
        val rule = assertNotNull(other.store.sender("bookings@fjordair.example"))
        assertEquals(SenderRecord.Status.SCREENED_IN, rule.status)
        assertEquals(listOf("travel"), rule.labelIds)
    }

    @Test fun honoursContactsAddedToGroupsInFastmail() = runBlocking<Unit> {
        val server = DemoServer()
        val engine = startedEngine(server)
        // Screening in Alex created "Sift: Screened In"; now the user drags a contact into "Sift: Notify"...
        engine.updateRule(SenderRecord(email = "alex@rivera.example", status = SenderRecord.Status.SCREENED_IN, notify = true), refile = false)
        val pat = server.addContact("Pat Lee", "pat@lee.example")
        server.addMember(pat, "Sift: Notify")
        engine.syncRules()
        val rule = assertNotNull(engine.store.sender("pat@lee.example"))
        assertTrue(rule.notify)
        assertEquals("Pat Lee", rule.name)

        // ...and turning notify off in Sift removes that contact from the group.
        engine.updateRule(rule.copy(notify = false), refile = false)
        assertNull(assertNotNull(server.groupNamed("Sift: Notify")).members()?.get(pat))
    }

    @Test fun refusedGroupMembersLeaveMailAndRulesUntouched() = runBlocking<Unit> {
        val server = DemoServer()
        val engine = startedEngine(server)
        server.rejectsAddressMembers = true
        assertFailsWith<ContactsRuleStoreException.AddressMembersRejected> {
            engine.screenIn("bookings@fjordair.example", "Fjord Air", listOf("travel"))
        }
        val booking = engine.store.messagesFrom("bookings@fjordair.example").first()
        assertEquals(setOf(server.mailboxId(SyncEngine.SCREENER_NAME)), server.emailMailboxes(booking.id))
        assertNull(engine.store.sender("bookings@fjordair.example"))
    }

    @Test fun screeningOutHidesAndMarksRead() = runBlocking<Unit> {
        val server = DemoServer()
        val engine = startedEngine(server)
        engine.screenOut("kai@lumenlabs.example", "Kai")
        val screenedOut = assertNotNull(server.mailboxId(SyncEngine.SCREENED_OUT_NAME))
        val pitch = engine.store.messagesFrom("kai@lumenlabs.example").first()
        assertEquals(setOf(screenedOut), server.emailMailboxes(pitch.id))
        assertTrue(Keyword.SEEN in server.emailKeywords(pitch.id))

        val again = server.deliver("Kai" to "kai@lumenlabs.example", "Following up", "Bump")
        engine.refresh()
        assertEquals(setOf(screenedOut), server.emailMailboxes(again))
    }

    @Test fun archiveTrashAndUndoPutMailBack() = runBlocking<Unit> {
        val server = DemoServer()
        val engine = startedEngine(server)
        val mom = engine.store.messagesIn("inbox").first { it.fromEmail == "mom@family.example" }

        val archived = engine.archive(listOf(mom.id), "inbox")
        assertEquals(setOf("archive"), server.emailMailboxes(mom.id))
        engine.restore(archived)
        assertEquals(setOf("inbox"), server.emailMailboxes(mom.id))

        val trashed = engine.moveToTrash(listOf(mom.id))
        assertEquals(setOf("trash"), server.emailMailboxes(mom.id))
        assertEquals(listOf("trash"), engine.store.message(mom.id)?.mailboxIds)
        engine.restore(trashed)
        assertEquals(setOf("inbox"), server.emailMailboxes(mom.id))

        engine.moveToJunk(listOf(mom.id))
        assertEquals(setOf("junk"), server.emailMailboxes(mom.id))
    }

    @Test fun failedChangesAreRolledBackLocally() = runBlocking<Unit> {
        val server = DemoServer()
        val engine = startedEngine(server)
        val mom = engine.store.messagesIn("inbox").first { it.fromEmail == "mom@family.example" }
        server.failsEmailSet = true
        assertFailsWith<Exception> { engine.moveToTrash(listOf(mom.id)) }
        assertEquals(listOf("inbox"), engine.store.message(mom.id)?.mailboxIds)
    }

    @Test fun notifiesAboutNewMailSendsAndSearches() = runBlocking<Unit> {
        val server = DemoServer()
        val engine = startedEngine(server)

        val received = mutableListOf<String>()
        engine.onNewMail { messages -> received += messages.map { it.subject } }
        server.deliver("Alex Rivera" to "alex@rivera.example", "Dinner?", "Tacos at 7")
        engine.refresh()
        assertEquals(listOf("Dinner?"), received)

        val identity = engine.identities.first()
        engine.send(OutgoingMessage(identityId = identity.id, to = listOf(EmailAddress(email = "new@person.example")), subject = "Hello", body = "Hi!"))
        assertTrue(engine.store.messagesIn("sent").any { it.subject == "Hello" })
        assertTrue(engine.store.hasWrittenTo("new@person.example"))

        val results = engine.search(SearchQuery("bergen"))
        assertEquals(listOf("bookings@fjordair.example"), results.messages.map { it.fromEmail })
        assertEquals(1, results.total)
        assertEquals("Your trip to Bergen: booking FJ7Q2K", results.snippets.values.single().subject)
    }

    @Test fun fetchesAndSanitizesBodies() = runBlocking<Unit> {
        val server = DemoServer()
        val engine = startedEngine(server)
        val newsletter = engine.store.messagesFrom("hello@paperline.example").first()
        val body = engine.body(newsletter.id)
        assertEquals("Mailchimp", TrackerDetector.sanitize(assertNotNull(body.html)).trackerSummary)
        // Cached: the second read doesn't need Fastmail.
        server.failsEmailSet = true
        assertEquals(body.html, engine.body(newsletter.id).html)
    }

    @Test fun reordersFoldersAfterSystemMailboxes() = runBlocking<Unit> {
        val server = DemoServer()
        val engine = startedEngine(server)
        engine.reorderMailboxes(listOf("family", "travel", "receipts", "newsletters"))
        assertEquals(listOf(10, 11, 12, 13), listOf("family", "travel", "receipts", "newsletters").map { server.mailboxSortOrder(it) })
        val labels = engine.store.mailboxes().filter { it.role == null && it.id !in setOf(engine.mailboxes!!.screener, engine.mailboxes!!.screenedOut) }.map { it.name }
        assertEquals(listOf("Family", "Travel", "Receipts", "Newsletters", "Hey Import"), labels)
    }

    @Test fun loadsOlderMailOnDemand() = runBlocking<Unit> {
        val server = DemoServer()
        val engine = engine(server).apply { initialSyncLimit = 5 }
        engine.start(demoActivation)
        val before = engine.store.knownMessageIds().size
        engine.loadOlder(null, Instant.now().minusSeconds(10 * 86_400))
        assertTrue(engine.store.knownMessageIds().size > before)
    }
}
