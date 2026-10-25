package com.markschmidt.sift.core

import com.markschmidt.sift.core.compose.MailtoLink
import com.markschmidt.sift.core.compose.OutgoingMessage
import com.markschmidt.sift.core.compose.SendException
import com.markschmidt.sift.core.demo.DemoServer
import com.markschmidt.sift.core.jmap.EmailAddress
import com.markschmidt.sift.core.store.Keyword
import com.markschmidt.sift.core.sync.SyncEngine
import kotlinx.coroutines.runBlocking
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class ComposeTest {
    private fun message(engine: SyncEngine, subject: String = "Plans") = OutgoingMessage(
        identityId = engine.identities.first().id,
        to = listOf(EmailAddress("Alex", "alex@rivera.example")),
        subject = subject, body = "See you at 7.",
    )

    @Test fun draftsSaveReplaceAndReopen() = runBlocking<Unit> {
        val server = DemoServer()
        val engine = startedEngine(server)
        val file = engine.upload("hello".toByteArray(), "notes.txt", "text/plain")
        var draft = message(engine).copy(attachments = listOf(file))

        val first = engine.saveDraft(draft)
        assertEquals(setOf("drafts"), server.emailMailboxes(first))
        assertTrue(Keyword.DRAFT in server.emailKeywords(first))

        // Editing saves a new version and removes the old one.
        draft = draft.copy(draftId = first, body = "See you at 8.")
        val second = engine.saveDraft(draft)
        assertFalse(server.emailExists(first))

        val reopened = engine.outgoingMessage(second)
        assertEquals(second, reopened.draftId)
        assertEquals("Plans", reopened.subject)
        assertEquals("See you at 8.", reopened.body)
        assertEquals(listOf("alex@rivera.example"), reopened.to.map { it.email })
        assertEquals(listOf("notes.txt"), reopened.attachments.map { it.name })

        engine.discardDraft(second)
        assertFalse(server.emailExists(second))
    }

    @Test fun sendingADraftFilesItInSent() = runBlocking<Unit> {
        val server = DemoServer()
        val engine = startedEngine(server)
        var draft = message(engine)
        draft = draft.copy(draftId = engine.saveDraft(draft))
        val file = engine.upload(byteArrayOf(0xFF.toByte(), 0xD8.toByte()), "photo.jpg", "image/jpeg")
        draft = draft.copy(attachments = listOf(file))

        val sending = engine.send(draft)
        assertEquals(0, sending.heldFor)
        assertEquals(setOf("sent"), server.emailMailboxes(sending.emailId))
        assertFalse(Keyword.DRAFT in server.emailKeywords(sending.emailId))
        assertFalse(server.emailExists(draft.draftId!!))  // the draft is replaced, not left behind
        assertEquals(listOf("photo.jpg"), server.emailAttachments(sending.emailId).map { it["name"] })
        assertFailsWith<SendException.TooLateToUndo> { engine.cancel(sending) }
    }

    @Test fun repliesAreMarkedAnswered() = runBlocking<Unit> {
        val server = DemoServer()
        val engine = startedEngine(server)
        val original = engine.store.messagesIn("inbox").first { it.fromEmail == "mom@family.example" }
        engine.send(message(engine).copy(answering = original.id, inReplyTo = listOfNotNull(original.messageIdHeader)))
        assertTrue(Keyword.ANSWERED in server.emailKeywords(original.id))
    }

    @Test fun undoSendPutsAHeldMessageBackInDrafts() = runBlocking<Unit> {
        val server = DemoServer().apply { maxDelayedSend = 60 }
        val engine = startedEngine(server)
        assertEquals(60, engine.maxDelayedSend())

        val sending = engine.send(message(engine), holdFor = 10)
        assertEquals(10, sending.heldFor)
        assertEquals("pending", server.submission(sending.submissionId)?.undoStatus)
        assertEquals(10, server.submission(sending.submissionId)?.holdFor)

        engine.cancel(sending)
        assertEquals("canceled", server.submission(sending.submissionId)?.undoStatus)
        assertEquals(setOf("drafts"), server.emailMailboxes(sending.emailId))
        assertTrue(Keyword.DRAFT in server.emailKeywords(sending.emailId))
        assertEquals("Plans", engine.outgoingMessage(sending.emailId).subject)
    }

    @Test fun undoAfterTheHoldEndsIsTooLate() = runBlocking<Unit> {
        val server = DemoServer().apply { maxDelayedSend = 60 }
        val engine = startedEngine(server)
        val sending = engine.send(message(engine), holdFor = 10)
        server.release(sending.submissionId)
        assertFailsWith<SendException.TooLateToUndo> { engine.cancel(sending) }
        assertEquals(setOf("sent"), server.emailMailboxes(sending.emailId))
    }

    @Test fun holdIsCappedByWhatFastmailAllows() = runBlocking<Unit> {
        val server = DemoServer()  // no delayed sending
        val engine = startedEngine(server)
        assertEquals(0, engine.send(message(engine), holdFor = 10).heldFor)
    }

    @Test fun noRecipientsIsRefused() = runBlocking<Unit> {
        val engine = startedEngine(DemoServer())
        assertFailsWith<SendException.NoRecipients> { engine.send(message(engine).copy(to = emptyList())) }
        assertFailsWith<SendException.NoIdentity> { engine.send(message(engine).copy(identityId = "nobody")) }
    }

    @Test fun blankMessagesAreNotWorthADraft() {
        assertTrue(OutgoingMessage(subject = "  ", body = "\n").isBlank)
        assertFalse(OutgoingMessage(body = "Hi").isBlank)
        assertNull(OutgoingMessage(draftId = "D1").content.draftId)
    }
}

class MailtoLinkTest {
    @Test fun parsesRecipientsAndFields() {
        val link = assertNotNull(MailtoLink.parse(
            "mailto:alex@example.com,sam@example.com?cc=pat@example.com&BCC=me@example.com&subject=Hi%20there&body=Line%20one%0D%0ALine%20two"))
        assertEquals(listOf("alex@example.com", "sam@example.com"), link.to)
        assertEquals(listOf("pat@example.com"), link.cc)
        assertEquals(listOf("me@example.com"), link.bcc)
        assertEquals("Hi there", link.subject)
        assertEquals("Line one\nLine two", link.body)
    }

    @Test fun toInTheQueryAddsRecipients() {
        assertEquals(listOf("a@example.com", "b@example.com"), MailtoLink.parse("mailto:?to=a@example.com&to=b%40example.com")?.to)
    }

    @Test fun keepsPlusSignsAndDecodesEncodedOnes() {
        val link = assertNotNull(MailtoLink.parse("mailto:me+news@example.com?subject=1+1%20%3D%202%26more"))
        assertEquals(listOf("me+news@example.com"), link.to)
        assertEquals("1+1 = 2&more", link.subject)
    }

    @Test fun toleratesSloppyLinks() {
        val raw = assertNotNull(MailtoLink.parse("MAILTO:support@example.com?subject=Help me please"))
        assertEquals(listOf("support@example.com"), raw.to)
        assertEquals("Help me please", raw.subject)
        assertEquals(listOf("hi@example.com"), MailtoLink.parse("mailto://hi@example.com")?.to)
        assertEquals(true, MailtoLink.parse("mailto:")?.isEmpty)
        assertNull(MailtoLink.parse("https://example.com"))
        assertEquals("Café", MailtoLink.parse("mailto:alex@example.com?subject=Caf%C3%A9")?.subject)
        assertEquals("100%", MailtoLink.parse("mailto:a@b.c?subject=100%")?.subject)
    }
}
