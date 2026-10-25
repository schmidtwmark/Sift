package com.markschmidt.sift.core

import com.markschmidt.sift.core.demo.DemoServer
import com.markschmidt.sift.core.jmap.EmailAddress
import com.markschmidt.sift.core.labels.LabelIcon
import com.markschmidt.sift.core.screener.RuleSuggestion
import com.markschmidt.sift.core.screener.SortReason
import com.markschmidt.sift.core.screener.SortingInference
import com.markschmidt.sift.core.store.MessageRecord
import com.markschmidt.sift.core.store.SenderRecord
import com.markschmidt.sift.core.store.SenderRecord.Status
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

class LabelIconTest {
    @Test fun guessesFromTheLabelName() {
        assertEquals("receipt", LabelIcon.suggested("Receipts"))
        assertEquals("airplane", LabelIcon.suggested("Travel"))
        assertEquals("figure.2.and.child.holdinghands", LabelIcon.suggested("Family"))
        assertEquals("newspaper", LabelIcon.suggested("Newsletters"))
        assertEquals("archivebox", LabelIcon.suggested("Hey Import"))
        // Word starts only: "Education" isn't about cats, "Scary" isn't a car.
        assertEquals("graduationcap", LabelIcon.suggested("Education"))
        assertEquals(LabelIcon.FALLBACK, LabelIcon.suggested("Scary Stories"))
        assertEquals(LabelIcon.FALLBACK, LabelIcon.suggested("Zzz"))
        assertEquals("receipt", LabelIcon.suggested("Paper Trail"))
        assertEquals("megaphone", LabelIcon.suggested("Promotions"))
        assertEquals("newspaper", LabelIcon.suggested("The Feed"))
        assertEquals("chevron.left.forwardslash.chevron.right", LabelIcon.suggested("GitHub"))
        assertEquals("archivebox", LabelIcon.suggested("Long Term Storage"))
    }

    @Test fun notesRoundTrip() {
        assertEquals("airplane", LabelIcon.parse(LabelIcon.note("airplane")))
        assertEquals("cart", LabelIcon.parse("  Sift icon: cart \n"))
        assertNull(LabelIcon.parse("Remember to call"))
        assertNull(LabelIcon.parse("Sift icon: "))
    }

    @Test fun catalogHasNoDuplicatesAndIncludesEverySuggestion() {
        val all = LabelIcon.catalog.flatMap { it.symbols }
        assertEquals(all.size, all.toSet().size)
        val suggested = listOf("Receipts", "Bills", "Bank", "Shipping", "Shop", "News", "Travel", "Family", "Friends", "Work",
            "School", "Health", "Home", "Car", "Social", "Alerts", "Tickets", "Pets", "Music", "Games",
            "Gym", "Food", "Security", "Subscriptions", "Import", "Promotions", "GitHub", "Paper Trail").map(LabelIcon::suggested)
        assertTrue(all.containsAll(suggested))
    }

    @Suppress("UNCHECKED_CAST")
    @Test fun iconsSyncThroughTheLabelsContactGroup() = runBlocking<Unit> {
        val server = DemoServer()
        val engine = startedEngine(server)
        fun travelGroups() = server.siftGroups().filter { (it["name"] as Map<String, Any?>)["full"] == "Sift label: Travel" }

        // Travel has no screening rules yet, so this creates its group.
        engine.setLabelIcon("suitcase", "travel")
        assertEquals(mapOf("travel" to "suitcase"), engine.store.labelIcons())
        val group = travelGroups().single()
        assertNull(group["members"])
        assertEquals("Sift icon: suitcase", ((group["notes"] as Map<String, Any?>)["sift-icon"] as Map<String, Any?>)["note"])

        // Screening a sender into Travel reuses that group.
        engine.screenIn("bookings@fjordair.example", "Fjord Air", listOf("travel"))
        assertEquals(1, travelGroups().size)

        // Another device reads it back, and sees it change.
        val other = engine(server)
        other.start()
        assertEquals(mapOf("travel" to "suitcase"), other.store.labelIcons())
        engine.setLabelIcon("airplane", "travel")
        other.syncRules()
        assertEquals(mapOf("travel" to "airplane"), other.store.labelIcons())

        // Clearing goes back to the guess everywhere, and the rule survives.
        other.setLabelIcon(null, "travel")
        engine.syncRules()
        assertTrue(engine.store.labelIcons().isEmpty())
        assertEquals(listOf("travel"), engine.store.sender("bookings@fjordair.example")?.labelIds)
    }
}

class SortingInferenceTest {
    private val inputs = SortingInference.Inputs(
        mailboxes = boxes, userLabels = setOf("feed", "paper", "lts"), ignored = setOf("import"), ownAddresses = setOf("me@fastmail.com"),
    )

    @Test fun suggestsTheFolderMostOfASendersMailIsIn() {
        val messages = listOf(
            email("1", "news@a.com", mailboxes = listOf("feed")),
            email("2", "news@a.com", mailboxes = listOf("feed")),
            email("3", "news@a.com", mailboxes = listOf("archive")),
            email("4", "bills@b.com", mailboxes = listOf("paper")),
            email("5", "pal@c.com", mailboxes = listOf("inbox")),
            email("6", "pal@c.com", mailboxes = listOf("archive")),
            email("7", "spam@d.com", mailboxes = listOf("junk")),
            email("8", "spam@d.com", mailboxes = listOf("junk")),
            email("9", "mixed@e.com", mailboxes = listOf("feed")),
            email("10", "mixed@e.com", mailboxes = listOf("paper")),
            email("11", "mixed@e.com", mailboxes = listOf("trash")),
        ).map(::MessageRecord)
        val suggestions = SortingInference.suggestions(messages, inputs).associateBy { it.email }
        assertEquals(listOf("feed"), suggestions["news@a.com"]?.labelIds)
        assertEquals(3, suggestions["news@a.com"]?.evidence)
        assertEquals(listOf("paper"), suggestions["bills@b.com"]?.labelIds)
        assertEquals(Status.SCREENED_IN, suggestions["pal@c.com"]?.status)
        assertEquals(emptyList(), suggestions["pal@c.com"]?.labelIds)
        assertEquals(Status.SCREENED_OUT, suggestions["spam@d.com"]?.status)
        // Split 50/50 between two folders counts for both (trash is ignored).
        assertEquals(listOf("feed", "paper"), suggestions["mixed@e.com"]?.labelIds)
    }

    @Test fun ignoresImportsOwnMailAndExistingRules() {
        val messages = listOf(
            email("1", "a@x.com", mailboxes = listOf("import")),
            email("2", "me@fastmail.com", mailboxes = listOf("feed")),
            email("3", "ruled@x.com", mailboxes = listOf("feed")),
        ).map(::MessageRecord)
        val existing = mapOf("ruled@x.com" to SenderRecord(email = "ruled@x.com", status = Status.SCREENED_IN))
        assertTrue(SortingInference.suggestions(messages, inputs, existing).isEmpty())
    }

    @Test fun screenedInWithoutAFolderOrNothingToGoOnMeansInbox() {
        val inboxRule = SenderRecord(email = "a@x.com", status = Status.SCREENED_IN)
        assertEquals(listOf("inbox"), SortingInference.destination("a@x.com", inboxRule, null, false, boxes, listOf("inbox")))
        val (destination, reason) = SortingInference.decide("new@x.com", null, null, false, boxes, listOf("inbox"))
        assertEquals(listOf("inbox"), destination)
        assertEquals(SortReason.NoHistory, reason)
        val both = SenderRecord(email = "a@x.com", status = Status.SCREENED_IN, labelIds = listOf("inbox", "feed"))
        assertEquals(listOf("feed"), SortingInference.destination("a@x.com", both, null, false, boxes, listOf("archive")))
        assertEquals(listOf("sent"), SortingInference.destination("me@hey.com", null, null, true, boxes, listOf("archive")))
        val out = RuleSuggestion("s@x.com", status = Status.SCREENED_OUT, labelIds = emptyList(), evidence = 3)
        assertEquals(listOf("out"), SortingInference.destination("s@x.com", null, out, false, boxes, listOf("archive")))
    }

    @Test fun findsTheOldAddressInAnImport() {
        val emails = (0 until 4).map { email("$it", "x$it@y.com", to = listOf(EmailAddress(email = "Me@Hey.com"))) }.toMutableList()
        emails[0] = emails[0].copy(to = listOf(EmailAddress(email = "other@z.com")))
        assertEquals("me@hey.com", SortingInference.dominantRecipient(emails))
        assertNull(SortingInference.dominantRecipient(emptyList()))
    }

    @Test fun sortsAnImportIntoFoldersByRuleAndHistory() = runBlocking<Unit> {
        val server = DemoServer()
        val engine = startedEngine(server)
        val plan = engine.planFolderSort("hey-import", ignored = setOf("hey-import"))
        assertEquals(10, plan.total)
        val byDestination = plan.buckets.associate { it.id to it.items.map { item -> item.senderEmail }.toSet() }
        // Your own old address's mail goes to Sent; the newsletter follows its history to Newsletters.
        assertTrue("you@hey.example" in plan.ownAddresses)
        assertEquals(setOf("you@hey.example"), byDestination["sent"])
        assertTrue("digest@fieldnotes.example" in byDestination.getValue("newsletters"))
        engine.execute(plan)
        assertTrue(engine.store.messagesIn("hey-import").isEmpty())
        engine.deleteMailbox("hey-import")
        assertNull(server.mailboxId("Hey Import"))
    }
}
