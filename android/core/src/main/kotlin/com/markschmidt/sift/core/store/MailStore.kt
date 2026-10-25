package com.markschmidt.sift.core.store

import androidx.sqlite.driver.bundled.BundledSQLiteDriver
import androidx.sqlite.execSQL
import com.markschmidt.sift.core.jmap.Email
import com.markschmidt.sift.core.jmap.EmailAddress
import com.markschmidt.sift.core.jmap.EmailBodyPart
import com.markschmidt.sift.core.jmap.Mailbox
import com.markschmidt.sift.core.jmap.MailboxRole
import com.markschmidt.sift.core.jmap.SiftJson
import com.markschmidt.sift.core.privacy.HtmlText
import com.markschmidt.sift.core.search.SearchQuery
import kotlinx.coroutines.flow.Flow
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import java.io.File
import java.time.Instant

/**
 * Local cache of the Fastmail account: mailboxes, message metadata, bodies,
 * sender rules and a full-text index. Screens observe it; `SyncEngine` writes it.
 */
class MailStore private constructor(val db: Database) {

    companion object {
        /** Opens (or creates) the on-disk store at [file]. */
        fun open(file: File): MailStore {
            file.parentFile?.mkdirs()
            return create(file.absolutePath)
        }

        fun inMemory(): MailStore = create(":memory:")

        private fun create(path: String): MailStore {
            val connection = BundledSQLiteDriver().open(path)
            connection.execSQL("PRAGMA foreign_keys = ON")
            if (path != ":memory:") connection.execSQL("PRAGMA journal_mode = WAL")
            migrate(connection)
            return MailStore(Database(connection))
        }

        private const val SCHEMA_VERSION = 1L

        private fun migrate(connection: androidx.sqlite.SQLiteConnection) {
            val current = connection.prepare("PRAGMA user_version").use { it.step(); it.getLong(0) }
            if (current >= SCHEMA_VERSION) return
            for (statement in schema) connection.execSQL(statement)
            connection.execSQL("PRAGMA user_version = $SCHEMA_VERSION")
        }

        private val schema = listOf(
            """CREATE TABLE mailbox (
                id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, parentId TEXT, role TEXT,
                sortOrder INTEGER NOT NULL, totalEmails INTEGER NOT NULL, unreadEmails INTEGER NOT NULL)""",
            """CREATE TABLE message (
                id TEXT PRIMARY KEY NOT NULL, threadId TEXT NOT NULL, blobId TEXT,
                receivedAt INTEGER NOT NULL, sentAt INTEGER, subject TEXT NOT NULL, preview TEXT NOT NULL,
                fromName TEXT, fromEmail TEXT NOT NULL, "to" TEXT NOT NULL, cc TEXT NOT NULL, replyTo TEXT NOT NULL,
                mailboxIds TEXT NOT NULL, keywords TEXT NOT NULL, hasAttachment INTEGER NOT NULL, size INTEGER NOT NULL,
                messageIdHeader TEXT, inReplyTo TEXT NOT NULL, "references" TEXT NOT NULL,
                isUnread INTEGER NOT NULL, isFlagged INTEGER NOT NULL)""",
            "CREATE INDEX message_threadId ON message(threadId)",
            "CREATE INDEX message_receivedAt ON message(receivedAt)",
            "CREATE INDEX message_fromEmail ON message(fromEmail)",
            """CREATE TABLE messageMailbox (
                messageId TEXT NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                mailboxId TEXT NOT NULL, PRIMARY KEY (messageId, mailboxId))""",
            "CREATE INDEX messageMailbox_mailbox ON messageMailbox(mailboxId, messageId)",
            """CREATE TABLE body (
                messageId TEXT PRIMARY KEY NOT NULL REFERENCES message(id) ON DELETE CASCADE,
                html TEXT, text TEXT, attachments TEXT NOT NULL, inlineParts TEXT NOT NULL, fetchedAt INTEGER NOT NULL)""",
            """CREATE TABLE sender (
                email TEXT PRIMARY KEY NOT NULL, name TEXT, status TEXT NOT NULL, labelIds TEXT NOT NULL,
                notify INTEGER NOT NULL, badge INTEGER NOT NULL, updatedAt INTEGER NOT NULL)""",
            // Everyone the user has written to; Hey-style, they skip the Screener.
            "CREATE TABLE sentRecipient (email TEXT PRIMARY KEY NOT NULL)",
            "CREATE TABLE kv (key TEXT PRIMARY KEY NOT NULL, value TEXT)",
            // rowid mirrors message.rowid so rows can be replaced without scanning.
            """CREATE VIRTUAL TABLE messageFTS USING fts5(
                subject, sender, recipients, preview, body,
                tokenize = 'unicode61 remove_diacritics 2')""",
        )

        const val LABEL_ICONS_KEY = "labelIcons"

        private val addresses = ListSerializer(EmailAddress.serializer())
        private val stringList = ListSerializer(String.serializer())
        private val parts = ListSerializer(EmailBodyPart.serializer())
        private val partMap = MapSerializer(String.serializer(), EmailBodyPart.serializer())
        private val stringMap = MapSerializer(String.serializer(), String.serializer())

        private fun encode(list: List<String>) = SiftJson.encodeToString(stringList, list)
        private fun decodeStrings(text: String): List<String> = SiftJson.decodeFromString(stringList, text)

        fun messageFrom(row: Database.Row) = MessageRecord(
            id = row.string("id"),
            threadId = row.string("threadId"),
            blobId = row.stringOrNull("blobId"),
            receivedAt = Instant.ofEpochMilli(row.long("receivedAt")),
            sentAt = row.longOrNull("sentAt")?.let(Instant::ofEpochMilli),
            subject = row.string("subject"),
            preview = row.string("preview"),
            fromName = row.stringOrNull("fromName"),
            fromEmail = row.string("fromEmail"),
            to = SiftJson.decodeFromString(addresses, row.string("to")),
            cc = SiftJson.decodeFromString(addresses, row.string("cc")),
            replyTo = SiftJson.decodeFromString(addresses, row.string("replyTo")),
            mailboxIds = decodeStrings(row.string("mailboxIds")),
            keywords = decodeStrings(row.string("keywords")),
            hasAttachment = row.bool("hasAttachment"),
            size = row.int("size"),
            messageIdHeader = row.stringOrNull("messageIdHeader"),
            inReplyTo = decodeStrings(row.string("inReplyTo")),
            references = decodeStrings(row.string("references")),
        )

        private fun mailboxFrom(row: Database.Row) = MailboxRecord(
            id = row.string("id"), name = row.string("name"), parentId = row.stringOrNull("parentId"),
            role = row.stringOrNull("role"), sortOrder = row.int("sortOrder"),
            totalEmails = row.int("totalEmails"), unreadEmails = row.int("unreadEmails"),
        )

        private fun senderFrom(row: Database.Row) = SenderRecord(
            email = row.string("email"), name = row.stringOrNull("name"),
            status = SenderRecord.Status.of(row.string("status")),
            labelIds = decodeStrings(row.string("labelIds")),
            notify = row.bool("notify"), badge = row.bool("badge"),
            updatedAt = Instant.ofEpochMilli(row.long("updatedAt")),
        )

        private fun bodyFrom(row: Database.Row) = BodyRecord(
            messageId = row.string("messageId"), html = row.stringOrNull("html"), text = row.stringOrNull("text"),
            attachments = SiftJson.decodeFromString(parts, row.string("attachments")),
            inlineParts = SiftJson.decodeFromString(partMap, row.string("inlineParts")),
            fetchedAt = row.long("fetchedAt"),
        )

        // MARK: - Queries usable inside a read (for observation)

        fun Database.Scope.mailboxList(): List<MailboxRecord> =
            query("SELECT * FROM mailbox ORDER BY sortOrder, name", map = ::mailboxFrom)

        fun Database.Scope.threadMessages(threadId: String): List<MessageRecord> =
            query("SELECT * FROM message WHERE threadId = ? ORDER BY receivedAt", threadId, map = ::messageFrom)

        fun Database.Scope.messagesById(ids: List<String>): List<MessageRecord> {
            if (ids.isEmpty()) return emptyList()
            return ids.chunked(500).flatMap { chunk ->
                query("SELECT * FROM message WHERE id IN (${chunk.joinToString(",") { "?" }})", chunk, ::messageFrom)
            }
        }

        fun Database.Scope.messagesInMailbox(mailboxId: String): List<MessageRecord> = query(
            """SELECT message.* FROM message
               JOIN messageMailbox mm ON mm.messageId = message.id AND mm.mailboxId = ?
               ORDER BY receivedAt DESC""", mailboxId, map = ::messageFrom,
        )

        /**
         * Threads for a list: one row per thread, newest first. [mailboxId]
         * null means every message in the account (the Everything view).
         */
        fun Database.Scope.threadSummaries(mailboxId: String?, limit: Int): List<ThreadSummary> {
            val scope = if (mailboxId == null) "SELECT id, threadId, receivedAt FROM message"
            else "SELECT m2.id, m2.threadId, m2.receivedAt FROM message m2 JOIN messageMailbox mm ON mm.messageId = m2.id AND mm.mailboxId = ?"
            val sql = """
                SELECT m.*,
                    (SELECT count(*) FROM message t WHERE t.threadId = m.threadId) AS messageCount,
                    (SELECT count(*) FROM message t WHERE t.threadId = m.threadId AND t.isUnread) AS unreadCount,
                    (SELECT group_concat(DISTINCT coalesce(nullif(t.fromName, ''), t.fromEmail))
                        FROM message t WHERE t.threadId = m.threadId) AS participants
                FROM message m
                WHERE m.id IN (
                    SELECT id FROM (
                        SELECT id, row_number() OVER (PARTITION BY threadId ORDER BY receivedAt DESC) AS rn
                        FROM ($scope)
                    ) WHERE rn = 1
                )
                ORDER BY m.receivedAt DESC
                LIMIT ?
            """
            val arguments = listOfNotNull(mailboxId) + limit
            return query(sql, arguments) { row ->
                ThreadSummary(
                    latest = messageFrom(row),
                    messageCount = row.int("messageCount"),
                    unreadCount = row.int("unreadCount"),
                    participants = row.stringOrNull("participants") ?: "",
                )
            }
        }

        /** Senders waiting in the Screener mailbox, most recent first. */
        fun Database.Scope.screener(screenerId: String): List<ScreenerEntry> {
            val grouped = LinkedHashMap<String, MutableList<MessageRecord>>()
            val names = HashMap<String, String?>()
            for (message in messagesInMailbox(screenerId)) {
                grouped.getOrPut(message.fromEmail) { mutableListOf() } += message
                if (message.fromEmail !in names) names[message.fromEmail] = message.fromName
            }
            return grouped.map { (email, messages) -> ScreenerEntry(email, names[email], messages) }
        }

        fun Database.Scope.senderList(): List<SenderRecord> =
            query("SELECT * FROM sender ORDER BY status, email", map = ::senderFrom)

        fun Database.Scope.senderRule(email: String): SenderRecord? =
            queryOne("SELECT * FROM sender WHERE email = ?", email.lowercase(), map = ::senderFrom)

        /** The display name a sender most recently used. */
        fun Database.Scope.senderName(email: String): String? = string(
            """SELECT fromName FROM message WHERE fromEmail = ? AND coalesce(fromName, '') != ''
               ORDER BY receivedAt DESC LIMIT 1""", email.lowercase(),
        )

        fun Database.Scope.messageCount(sender: String): Int =
            long("SELECT count(*) FROM message WHERE fromEmail = ?", sender)?.toInt() ?: 0

        /**
         * Unread mail from senders whose badge is on, outside the Screener and
         * the junk/trash/screened-out piles.
         */
        fun Database.Scope.unreadBadgeCount(excluding: List<String>): Int {
            val placeholders = if (excluding.isEmpty()) "''" else excluding.joinToString(",") { "?" }
            return long(
                """SELECT count(*) FROM message m
                   JOIN sender s ON s.email = m.fromEmail AND s.badge
                   WHERE m.isUnread
                     AND NOT EXISTS (SELECT 1 FROM messageMailbox mm WHERE mm.messageId = m.id AND mm.mailboxId IN ($placeholders))""",
                *excluding.toTypedArray(),
            )?.toInt() ?: 0
        }

        /** Custom label icons: mailbox id → SF Symbol name. */
        fun Database.Scope.labelIconMap(): Map<String, String> =
            string("SELECT value FROM kv WHERE key = ?", LABEL_ICONS_KEY)
                ?.let { runCatching { SiftJson.decodeFromString(stringMap, it) }.getOrNull() } ?: emptyMap()

        fun Database.Scope.kvValue(key: String): String? = string("SELECT value FROM kv WHERE key = ?", key)

        /** Full-text search over cached mail, with the query's structured filters. */
        fun Database.Scope.localSearch(searchQuery: SearchQuery, limit: Int = 200): List<MessageRecord> {
            val byName = mailboxList().associateBy({ it.name.lowercase() }, { it.id })
            val (sql, arguments) = searchQuery.localSql(limit, byName) ?: return emptyList()
            return query(sql, arguments, ::messageFrom)
        }

        private fun Database.Scope.upsert(record: MessageRecord) {
            execute(
                """INSERT INTO message (id, threadId, blobId, receivedAt, sentAt, subject, preview, fromName, fromEmail,
                       "to", cc, replyTo, mailboxIds, keywords, hasAttachment, size, messageIdHeader, inReplyTo, "references",
                       isUnread, isFlagged)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                   ON CONFLICT(id) DO UPDATE SET threadId = excluded.threadId, blobId = excluded.blobId,
                       receivedAt = excluded.receivedAt, sentAt = excluded.sentAt, subject = excluded.subject,
                       preview = excluded.preview, fromName = excluded.fromName, fromEmail = excluded.fromEmail,
                       "to" = excluded."to", cc = excluded.cc, replyTo = excluded.replyTo, mailboxIds = excluded.mailboxIds,
                       keywords = excluded.keywords, hasAttachment = excluded.hasAttachment, size = excluded.size,
                       messageIdHeader = excluded.messageIdHeader, inReplyTo = excluded.inReplyTo,
                       "references" = excluded."references", isUnread = excluded.isUnread, isFlagged = excluded.isFlagged""",
                record.id, record.threadId, record.blobId, record.receivedAt.toEpochMilli(), record.sentAt?.toEpochMilli(),
                record.subject, record.preview, record.fromName, record.fromEmail,
                SiftJson.encodeToString(addresses, record.to), SiftJson.encodeToString(addresses, record.cc),
                SiftJson.encodeToString(addresses, record.replyTo), encode(record.mailboxIds), encode(record.keywords),
                record.hasAttachment, record.size, record.messageIdHeader, encode(record.inReplyTo), encode(record.references),
                record.isUnread, record.isFlagged,
            )
            execute("DELETE FROM messageMailbox WHERE messageId = ?", record.id)
            for (mailboxId in record.mailboxIds) {
                execute("INSERT INTO messageMailbox(messageId, mailboxId) VALUES (?, ?)", record.id, mailboxId)
            }
            val bodyText = string("SELECT coalesce(text, html) FROM body WHERE messageId = ?", record.id)
            index(record, bodyText)
        }

        private fun Database.Scope.index(record: MessageRecord, bodyText: String?) {
            val rowid = long("SELECT rowid FROM message WHERE id = ?", record.id) ?: return
            val recipients = (record.to + record.cc).joinToString(" ") { "${it.name ?: ""} ${it.email ?: ""}" }
            execute("DELETE FROM messageFTS WHERE rowid = ?", rowid)
            execute(
                "INSERT INTO messageFTS(rowid, subject, sender, recipients, preview, body) VALUES (?, ?, ?, ?, ?, ?)",
                rowid, record.subject, "${record.fromName ?: ""} ${record.fromEmail}", recipients,
                record.preview, bodyText?.let(HtmlText::plainText) ?: "",
            )
        }
    }

    // MARK: - Observation

    fun <T> observe(query: Database.Scope.() -> T): Flow<T> = db.observe(query)

    suspend fun <T> read(query: Database.Scope.() -> T): T = db.read(query)

    // MARK: - Key/value state

    suspend fun value(key: String): String? = db.read { kvValue(key) }

    suspend fun setValue(value: String?, key: String) =
        db.write { execute("INSERT OR REPLACE INTO kv(key, value) VALUES (?, ?)", key, value) }

    /** Mailbox id → SF Symbol name, mirrored from Fastmail. */
    suspend fun setLabelIcons(icons: Map<String, String>) =
        setValue(SiftJson.encodeToString(stringMap, icons), LABEL_ICONS_KEY)

    suspend fun labelIcons(): Map<String, String> = db.read { labelIconMap() }

    // MARK: - Mailboxes

    suspend fun replaceMailboxes(mailboxes: List<Mailbox>) = db.write {
        execute("DELETE FROM mailbox")
        for (mailbox in mailboxes.map(::MailboxRecord)) {
            execute(
                "INSERT INTO mailbox(id, name, parentId, role, sortOrder, totalEmails, unreadEmails) VALUES (?, ?, ?, ?, ?, ?, ?)",
                mailbox.id, mailbox.name, mailbox.parentId, mailbox.role, mailbox.sortOrder, mailbox.totalEmails, mailbox.unreadEmails,
            )
        }
    }

    /** Mailbox id → new sortOrder. */
    suspend fun setSortOrders(orders: Map<String, Int>) = db.write {
        for ((id, order) in orders) execute("UPDATE mailbox SET sortOrder = ? WHERE id = ?", order, id)
    }

    suspend fun mailboxes(): List<MailboxRecord> = db.read { mailboxList() }

    suspend fun mailbox(role: MailboxRole): MailboxRecord? = mailboxes().firstOrNull { it.role == role.raw }

    // MARK: - Messages

    suspend fun upsertEmails(emails: List<Email>) = upsert(emails.map(::MessageRecord))

    suspend fun upsert(records: List<MessageRecord>) {
        if (records.isEmpty()) return
        db.write { for (record in records) upsert(record) }
    }

    /**
     * People to suggest while typing an address: anyone you've written to
     * first, then whoever writes to you most, matching the start of a name or
     * address.
     */
    suspend fun addressSuggestions(matching: String, limit: Int = 6): List<EmailAddress> {
        val text = matching.trim().lowercase().replace("%", "").replace("_", "")
        if (text.isEmpty()) return emptyList()
        return db.read {
            val results = query(
                """SELECT fromEmail AS email, MAX(fromName) AS name, COUNT(*) AS n,
                       EXISTS(SELECT 1 FROM sentRecipient s WHERE s.email = message.fromEmail) AS written
                   FROM message
                   WHERE fromEmail LIKE ?1 OR fromName LIKE ?1 OR fromName LIKE ?2
                   GROUP BY fromEmail
                   ORDER BY written DESC, n DESC
                   LIMIT ?3""",
                "$text%", "% $text%", limit,
            ) { row -> EmailAddress(row.stringOrNull("name")?.takeIf { it.isNotEmpty() }, row.string("email")) }.toMutableList()
            if (results.size < limit) {
                val known = results.map { it.normalized }.toSet()
                val written = strings("SELECT email FROM sentRecipient WHERE email LIKE ? ORDER BY email LIMIT ?", "$text%", limit)
                results += written.filter { it !in known }.map { EmailAddress(email = it) }
            }
            results.take(limit)
        }
    }

    suspend fun delete(messageIds: List<String>) {
        if (messageIds.isEmpty()) return
        db.write {
            for (id in messageIds) {
                long("SELECT rowid FROM message WHERE id = ?", id)?.let { execute("DELETE FROM messageFTS WHERE rowid = ?", it) }
                execute("DELETE FROM message WHERE id = ?", id)
            }
        }
    }

    suspend fun message(id: String): MessageRecord? = messages(listOf(id)).firstOrNull()

    suspend fun messages(ids: List<String>): List<MessageRecord> = db.read { messagesById(ids) }

    suspend fun knownMessageIds(): Set<String> = db.read { strings("SELECT id FROM message").toSet() }

    suspend fun allMessages(): List<MessageRecord> = db.read { query("SELECT * FROM message", map = ::messageFrom) }

    suspend fun messagesIn(mailboxId: String): List<MessageRecord> = db.read { messagesInMailbox(mailboxId) }

    suspend fun thread(threadId: String): List<MessageRecord> = db.read { threadMessages(threadId) }

    suspend fun messagesFrom(sender: String, mailboxId: String? = null): List<MessageRecord> = db.read {
        if (mailboxId != null) {
            query(
                """SELECT message.* FROM message
                   JOIN messageMailbox mm ON mm.messageId = message.id AND mm.mailboxId = ?
                   WHERE fromEmail = ? ORDER BY receivedAt DESC""", mailboxId, sender, map = ::messageFrom,
            )
        } else {
            query("SELECT * FROM message WHERE fromEmail = ? ORDER BY receivedAt DESC", sender, map = ::messageFrom)
        }
    }

    suspend fun threads(mailboxId: String?, limit: Int): List<ThreadSummary> = db.read { threadSummaries(mailboxId, limit) }

    suspend fun screenerEntries(screenerId: String): List<ScreenerEntry> = db.read { screener(screenerId) }

    // MARK: - Bodies

    suspend fun body(messageId: String): BodyRecord? =
        db.read { queryOne("SELECT * FROM body WHERE messageId = ?", messageId, map = ::bodyFrom) }

    suspend fun save(body: BodyRecord) = db.write {
        execute(
            "INSERT OR REPLACE INTO body(messageId, html, text, attachments, inlineParts, fetchedAt) VALUES (?, ?, ?, ?, ?, ?)",
            body.messageId, body.html, body.text, SiftJson.encodeToString(parts, body.attachments),
            SiftJson.encodeToString(partMap, body.inlineParts), body.fetchedAt,
        )
        queryOne("SELECT * FROM message WHERE id = ?", body.messageId, map = ::messageFrom)?.let { index(it, body.text ?: body.html) }
    }

    // MARK: - Senders

    suspend fun sender(email: String): SenderRecord? = db.read { senderRule(email) }

    suspend fun senders(): List<SenderRecord> = db.read { senderList() }

    suspend fun save(sender: SenderRecord) = db.write { insert(sender) }

    suspend fun replaceSenders(senders: List<SenderRecord>) = db.write {
        execute("DELETE FROM sender")
        for (sender in senders) insert(sender)
    }

    private fun Database.Scope.insert(sender: SenderRecord) = execute(
        "INSERT OR REPLACE INTO sender(email, name, status, labelIds, notify, badge, updatedAt) VALUES (?, ?, ?, ?, ?, ?, ?)",
        sender.email, sender.name, sender.status.raw, encode(sender.labelIds), sender.notify, sender.badge,
        sender.updatedAt.toEpochMilli(),
    )

    suspend fun recordSentRecipients(addresses: List<String>) {
        if (addresses.isEmpty()) return
        db.write { for (address in addresses) execute("INSERT OR IGNORE INTO sentRecipient(email) VALUES (?)", address.lowercase()) }
    }

    suspend fun hasWrittenTo(address: String): Boolean =
        db.read { long("SELECT EXISTS(SELECT 1 FROM sentRecipient WHERE email = ?)", address.lowercase()) == 1L }

    suspend fun badgeCount(excluding: List<String>): Int = db.read { unreadBadgeCount(excluding) }

    // MARK: - Local search

    suspend fun search(query: SearchQuery, limit: Int = 200): List<MessageRecord> = db.read { localSearch(query, limit) }

    fun close() = db.close()
}
