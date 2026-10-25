package com.markschmidt.sift.core

import com.markschmidt.sift.core.demo.DemoSeed
import com.markschmidt.sift.core.demo.DemoServer
import com.markschmidt.sift.core.jmap.Email
import com.markschmidt.sift.core.jmap.EmailAddress
import com.markschmidt.sift.core.jmap.JmapClient
import com.markschmidt.sift.core.screener.SpecialMailboxes
import com.markschmidt.sift.core.store.MailStore
import com.markschmidt.sift.core.sync.SyncEngine
import java.time.Instant

fun email(
    id: String,
    from: String,
    name: String? = null,
    subject: String = "Hello",
    preview: String = "",
    mailboxes: List<String> = listOf("inbox"),
    keywords: List<String> = emptyList(),
    received: Instant = Instant.ofEpochSecond(2_000_000_000),
    thread: String? = null,
    to: List<EmailAddress> = listOf(EmailAddress(email = "me@fastmail.com")),
) = Email(
    id = id, blobId = "b-$id", threadId = thread ?: "t-$id",
    mailboxIds = mailboxes.associateWith { true },
    keywords = keywords.associateWith { true },
    size = 100, receivedAt = received,
    from = listOf(EmailAddress(name, from)), to = to,
    subject = subject, preview = preview, hasAttachment = false,
    messageId = listOf("<$id@x>"),
)

val boxes = SpecialMailboxes(
    inbox = "inbox", screener = "screener", screenedOut = "out",
    archive = "archive", trash = "trash", junk = "junk", sent = "sent", drafts = "drafts",
)

fun engine(server: DemoServer): SyncEngine {
    val client = JmapClient("demo", DemoServer.SESSION_URL, server.httpClient())
    return SyncEngine(client, MailStore.inMemory())
}

val demoActivation: Instant get() = Instant.now().minus(DemoSeed.activationAge)

/** An engine that has done its first sync against [server], with the Screener on since the demo's start. */
suspend fun startedEngine(server: DemoServer): SyncEngine = engine(server).also { it.start(demoActivation) }
