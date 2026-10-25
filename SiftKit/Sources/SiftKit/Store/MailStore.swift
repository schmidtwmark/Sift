import Foundation
import GRDB

/// Local cache of the Fastmail account: mailboxes, message metadata, bodies,
/// sender rules and a full-text index. Views observe it; `SyncEngine` writes it.
public final class MailStore: Sendable {
    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// Opens (or creates) the on-disk store in Application Support.
    public static func onDisk(named name: String = "Sift") throws -> MailStore {
        let folder = try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        let pool = try DatabasePool(path: folder.appending(path: "mail.sqlite").path, configuration: config)
        return try MailStore(writer: pool)
    }

    public static func inMemory() throws -> MailStore {
        try MailStore(writer: DatabaseQueue())
    }

    // MARK: - Schema

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "mailbox") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("parentId", .text)
                t.column("role", .text)
                t.column("sortOrder", .integer).notNull()
                t.column("totalEmails", .integer).notNull()
                t.column("unreadEmails", .integer).notNull()
            }
            try db.create(table: "message") { t in
                t.primaryKey("id", .text)
                t.column("threadId", .text).notNull().indexed()
                t.column("blobId", .text)
                t.column("receivedAt", .datetime).notNull().indexed()
                t.column("sentAt", .datetime)
                t.column("subject", .text).notNull()
                t.column("preview", .text).notNull()
                t.column("fromName", .text)
                t.column("fromEmail", .text).notNull().indexed()
                t.column("to", .jsonText).notNull()
                t.column("cc", .jsonText).notNull()
                t.column("replyTo", .jsonText).notNull()
                t.column("mailboxIds", .jsonText).notNull()
                t.column("keywords", .jsonText).notNull()
                t.column("hasAttachment", .boolean).notNull()
                t.column("size", .integer).notNull()
                t.column("messageIdHeader", .text)
                t.column("inReplyTo", .jsonText).notNull()
                t.column("references", .jsonText).notNull()
                t.column("isUnread", .boolean).notNull()
                t.column("isFlagged", .boolean).notNull()
            }
            try db.create(table: "messageMailbox") { t in
                t.column("messageId", .text).notNull().references("message", onDelete: .cascade)
                t.column("mailboxId", .text).notNull()
                t.primaryKey(["messageId", "mailboxId"])
            }
            try db.create(index: "messageMailbox_mailbox", on: "messageMailbox", columns: ["mailboxId", "messageId"])
            try db.create(table: "body") { t in
                t.primaryKey("messageId", .text).references("message", onDelete: .cascade)
                t.column("html", .text)
                t.column("text", .text)
                t.column("attachments", .jsonText).notNull()
                t.column("inlineParts", .jsonText).notNull()
                t.column("fetchedAt", .datetime).notNull()
            }
            try db.create(table: "sender") { t in
                t.primaryKey("email", .text)
                t.column("name", .text)
                t.column("status", .text).notNull()
                t.column("labelIds", .jsonText).notNull()
                t.column("notify", .boolean).notNull()
                t.column("badge", .boolean).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
            // Everyone the user has written to; Hey-style, they skip the Screener.
            try db.create(table: "sentRecipient") { t in
                t.primaryKey("email", .text)
            }
            try db.create(table: "kv") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }
            // rowid mirrors message.rowid so rows can be replaced without scanning.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE messageFTS USING fts5(
                    subject, sender, recipients, preview, body,
                    tokenize = 'unicode61 remove_diacritics 2'
                )
                """)
        }
        return migrator
    }

    // MARK: - Key/value state

    public func value(for key: String) async throws -> String? {
        try await writer.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [key])
        }
    }

    public func setValue(_ value: String?, for key: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO kv(key, value) VALUES (?, ?)", arguments: [key, value])
        }
    }

    static let bubbleUpsKey = "bubbleUps"

    /// Bubble Ups waiting to happen, mirrored from Fastmail.
    public func setBubbleUps(_ bubbles: [BubbleUp]) async throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try await setValue(String(decoding: try encoder.encode(bubbles), as: UTF8.self), for: Self.bubbleUpsKey)
    }

    static let labelIconsKey = "labelIcons"

    /// Mailbox id → SF Symbol, mirrored from Fastmail.
    public func setLabelIcons(_ icons: [String: String]) async throws {
        let json = String(decoding: try JSONEncoder().encode(icons), as: UTF8.self)
        try await setValue(json, for: Self.labelIconsKey)
    }

    // MARK: - Mailboxes

    public func replaceMailboxes(_ mailboxes: [Mailbox]) async throws {
        try await writer.write { db in
            try MailboxRecord.deleteAll(db)
            for mailbox in mailboxes { try MailboxRecord(mailbox).insert(db) }
        }
    }

    /// Mailbox id → new sortOrder.
    public func setSortOrders(_ orders: [String: Int]) async throws {
        try await writer.write { db in
            for (id, order) in orders {
                try db.execute(sql: "UPDATE mailbox SET sortOrder = ? WHERE id = ?", arguments: [order, id])
            }
        }
    }

    public func mailboxes() async throws -> [MailboxRecord] {
        try await writer.read { db in try MailboxRecord.order(Column("sortOrder"), Column("name")).fetchAll(db) }
    }

    public func mailbox(role: MailboxRole) async throws -> MailboxRecord? {
        try await writer.read { db in try MailboxRecord.filter(Column("role") == role.rawValue).fetchOne(db) }
    }

    public func mailbox(named name: String) async throws -> MailboxRecord? {
        try await writer.read { db in
            try MailboxRecord.filter(Column("name").collating(.nocase) == name).fetchOne(db)
        }
    }

    // MARK: - Messages

    public func upsert(_ emails: [Email]) async throws {
        guard !emails.isEmpty else { return }
        try await writer.write { db in
            for email in emails {
                try Self.upsert(MessageRecord(email), in: db)
            }
        }
    }

    public func upsert(_ records: [MessageRecord]) async throws {
        try await writer.write { db in
            for record in records { try Self.upsert(record, in: db) }
        }
    }

    static func upsert(_ record: MessageRecord, in db: Database) throws {
        try record.upsert(db)
        try db.execute(sql: "DELETE FROM messageMailbox WHERE messageId = ?", arguments: [record.id])
        for mailboxId in record.mailboxIds {
            try db.execute(sql: "INSERT INTO messageMailbox(messageId, mailboxId) VALUES (?, ?)",
                           arguments: [record.id, mailboxId])
        }
        let bodyText = try String.fetchOne(db, sql: "SELECT coalesce(text, html) FROM body WHERE messageId = ?",
                                           arguments: [record.id])
        try index(record, bodyText: bodyText, in: db)
    }

    static func index(_ record: MessageRecord, bodyText: String?, in db: Database) throws {
        guard let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM message WHERE id = ?", arguments: [record.id]) else {
            return
        }
        let recipients = (record.to + record.cc).map { "\($0.name ?? "") \($0.email ?? "")" }.joined(separator: " ")
        try db.execute(sql: "DELETE FROM messageFTS WHERE rowid = ?", arguments: [rowid])
        try db.execute(
            sql: "INSERT INTO messageFTS(rowid, subject, sender, recipients, preview, body) VALUES (?, ?, ?, ?, ?, ?)",
            arguments: [rowid, record.subject, "\(record.fromName ?? "") \(record.fromEmail)", recipients,
                        record.preview, bodyText.map(HTMLText.plainText(from:)) ?? ""]
        )
    }

    /// People to suggest while typing an address: anyone you've written to
    /// first, then whoever writes to you most, matching the start of a name
    /// or address.
    public func addressSuggestions(matching text: String, limit: Int = 6) async throws -> [EmailAddress] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
            .replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "_", with: "")
        guard !query.isEmpty else { return [] }
        return try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT fromEmail AS email, MAX(fromName) AS name, COUNT(*) AS n,
                       EXISTS(SELECT 1 FROM sentRecipient s WHERE s.email = message.fromEmail) AS written
                FROM message
                WHERE fromEmail LIKE ?1 OR fromName LIKE ?1 OR fromName LIKE ?2
                GROUP BY fromEmail
                ORDER BY written DESC, n DESC
                LIMIT ?3
                """, arguments: ["\(query)%", "% \(query)%", limit])
            var results = rows.map { row -> EmailAddress in
                let name: String? = row["name"]
                return EmailAddress(name: name?.isEmpty == false ? name : nil, email: row["email"])
            }
            if results.count < limit {
                let known = Set(results.map(\.normalized))
                let written = try String.fetchAll(db, sql: "SELECT email FROM sentRecipient WHERE email LIKE ? ORDER BY email LIMIT ?",
                                                  arguments: ["\(query)%", limit])
                results += written.filter { !known.contains($0) }.map { EmailAddress(email: $0) }
            }
            return Array(results.prefix(limit))
        }
    }

    public func delete(messageIds: [String]) async throws {
        guard !messageIds.isEmpty else { return }
        try await writer.write { db in
            for id in messageIds {
                if let rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM message WHERE id = ?", arguments: [id]) {
                    try db.execute(sql: "DELETE FROM messageFTS WHERE rowid = ?", arguments: [rowid])
                }
                _ = try MessageRecord.deleteOne(db, key: id)
            }
        }
    }

    public func message(id: String) async throws -> MessageRecord? {
        try await writer.read { db in try MessageRecord.fetchOne(db, key: id) }
    }

    public func messages(ids: [String]) async throws -> [MessageRecord] {
        try await writer.read { db in try MessageRecord.fetchAll(db, keys: ids) }
    }

    public func knownMessageIds() async throws -> Set<String> {
        try await writer.read { db in Set(try String.fetchAll(db, sql: "SELECT id FROM message")) }
    }

    public func oldestReceivedAt() async throws -> Date? {
        try await writer.read { db in try Date.fetchOne(db, sql: "SELECT min(receivedAt) FROM message") }
    }

    /// All messages in a thread, oldest first.
    public static func thread(_ threadId: String, in db: Database) throws -> [MessageRecord] {
        try MessageRecord.filter(Column("threadId") == threadId).order(Column("receivedAt")).fetchAll(db)
    }

    public static func messages(in mailboxId: String, in db: Database) throws -> [MessageRecord] {
        try MessageRecord.fetchAll(db, sql: """
            SELECT message.* FROM message
            JOIN messageMailbox mm ON mm.messageId = message.id AND mm.mailboxId = ?
            ORDER BY receivedAt DESC
            """, arguments: [mailboxId])
    }

    public func messages(in mailboxId: String) async throws -> [MessageRecord] {
        try await writer.read { db in try Self.messages(in: mailboxId, in: db) }
    }

    public func messages(from sender: String, in mailboxId: String? = nil) async throws -> [MessageRecord] {
        try await writer.read { db in
            if let mailboxId {
                return try MessageRecord.fetchAll(db, sql: """
                    SELECT message.* FROM message
                    JOIN messageMailbox mm ON mm.messageId = message.id AND mm.mailboxId = ?
                    WHERE fromEmail = ? ORDER BY receivedAt DESC
                    """, arguments: [mailboxId, sender])
            }
            return try MessageRecord.filter(Column("fromEmail") == sender).order(Column("receivedAt").desc).fetchAll(db)
        }
    }

    /// Threads for a list view: one row per thread, newest first. `mailboxId`
    /// nil means every message in the account (the Everything view).
    /// Conversations in a mailbox (or everywhere), most recent activity first.
    /// A Bubble Up note counts as activity, so its conversation floats up, but
    /// the row shows the newest real message, in this mailbox when there is one.
    public static func threads(in mailboxId: String?, limit: Int, in db: Database) throws -> [ThreadSummary] {
        let scope = mailboxId == nil
            ? "SELECT id, threadId, receivedAt FROM message"
            : "SELECT m2.id, m2.threadId, m2.receivedAt FROM message m2 JOIN messageMailbox mm ON mm.messageId = m2.id AND mm.mailboxId = :mailbox"
        var arguments: StatementArguments = ["limit": limit, "bubble": bubblePattern]
        if let mailboxId { arguments += ["mailbox": mailboxId] }
        return try ThreadSummary.fetchAll(db, sql: """
            WITH scope AS (\(scope)),
            picked AS (
                SELECT threadId, max(receivedAt) AS activity FROM scope
                GROUP BY threadId ORDER BY activity DESC LIMIT :limit
            ),
            shown AS (
                SELECT p.threadId, p.activity, coalesce(
                    (SELECT s.id FROM scope s JOIN message x ON x.id = s.id
                        WHERE s.threadId = p.threadId AND x.keywords NOT LIKE :bubble
                        ORDER BY s.receivedAt DESC LIMIT 1),
                    (SELECT x.id FROM message x
                        WHERE x.threadId = p.threadId AND x.keywords NOT LIKE :bubble
                        ORDER BY x.receivedAt DESC LIMIT 1)
                ) AS id
                FROM picked p
            )
            SELECT m.*,
                (SELECT count(*) FROM message t WHERE t.threadId = m.threadId AND t.keywords NOT LIKE :bubble) AS messageCount,
                (SELECT count(*) FROM message t WHERE t.threadId = m.threadId AND t.isUnread AND t.keywords NOT LIKE :bubble) AS unreadCount,
                (SELECT group_concat(DISTINCT coalesce(nullif(t.fromName, ''), t.fromEmail))
                    FROM message t WHERE t.threadId = m.threadId AND t.keywords NOT LIKE :bubble) AS participants,
                (SELECT max(t.receivedAt) FROM message t WHERE t.threadId = m.threadId AND t.keywords LIKE :bubble) AS bubbledAt
            FROM shown sh JOIN message m ON m.id = sh.id
            ORDER BY sh.activity DESC
            """, arguments: arguments)
    }

    /// Matches a message's keywords (JSON text) when it's a Bubble Up note.
    static let bubblePattern = "%\"\(Keyword.bubble)\"%"

    /// Senders waiting in the Screener mailbox, most recent first.
    public static func screenerEntries(screenerId: String, in db: Database) throws -> [ScreenerEntry] {
        let messages = try messages(in: screenerId, in: db)
        var order: [String] = []
        var grouped: [String: ScreenerEntry] = [:]
        for message in messages {
            if grouped[message.fromEmail] == nil {
                order.append(message.fromEmail)
                grouped[message.fromEmail] = ScreenerEntry(email: message.fromEmail, name: message.fromName, messages: [])
            }
            grouped[message.fromEmail]?.messages.append(message)
        }
        return order.compactMap { grouped[$0] }
    }

    // MARK: - Bodies

    public func body(for messageId: String) async throws -> BodyRecord? {
        try await writer.read { db in try BodyRecord.fetchOne(db, key: messageId) }
    }

    public func save(_ body: BodyRecord) async throws {
        try await writer.write { db in
            try body.upsert(db)
            if let record = try MessageRecord.fetchOne(db, key: body.messageId) {
                try Self.index(record, bodyText: body.text ?? body.html, in: db)
            }
        }
    }

    // MARK: - Senders

    public func sender(_ email: String) async throws -> SenderRecord? {
        try await writer.read { db in try SenderRecord.fetchOne(db, key: email.lowercased()) }
    }

    public func senders() async throws -> [SenderRecord] {
        try await writer.read { db in try SenderRecord.fetchAll(db) }
    }

    public func save(_ sender: SenderRecord) async throws {
        try await writer.write { db in try sender.upsert(db) }
    }

    public func replaceSenders(_ senders: [SenderRecord]) async throws {
        try await writer.write { db in
            try SenderRecord.deleteAll(db)
            for sender in senders { try sender.insert(db) }
        }
    }

    public func recordSentRecipients(_ addresses: [String]) async throws {
        guard !addresses.isEmpty else { return }
        try await writer.write { db in
            for address in addresses {
                try db.execute(sql: "INSERT OR IGNORE INTO sentRecipient(email) VALUES (?)", arguments: [address.lowercased()])
            }
        }
    }

    public func hasWrittenTo(_ address: String) async throws -> Bool {
        try await writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM sentRecipient WHERE email = ?)",
                              arguments: [address.lowercased()]) ?? false
        }
    }

    /// Unread mail from senders whose badge is on, outside the Screener and
    /// the junk/trash/screened-out piles.
    public static func badgeCount(excludingMailboxIds excluded: [String], in db: Database) throws -> Int {
        let placeholders = excluded.isEmpty ? "''" : excluded.map { _ in "?" }.joined(separator: ",")
        return try Int.fetchOne(db, sql: """
            SELECT count(*) FROM message m
            JOIN sender s ON s.email = m.fromEmail AND s.badge
            WHERE m.isUnread
              AND NOT EXISTS (SELECT 1 FROM messageMailbox mm WHERE mm.messageId = m.id AND mm.mailboxId IN (\(placeholders)))
            """, arguments: StatementArguments(excluded)) ?? 0
    }

    // MARK: - Local search

    /// Full-text search over cached mail. Returns message ids ranked by relevance
    /// and recency; structured filters are applied by `SearchQuery.localSQL`.
    public func search(_ query: SearchQuery, limit: Int = 200) async throws -> [MessageRecord] {
        try await writer.read { db in try Self.search(query, limit: limit, in: db) }
    }

    public static func search(_ query: SearchQuery, limit: Int, in db: Database) throws -> [MessageRecord] {
        let mailboxIdsByName = Dictionary(
            try MailboxRecord.fetchAll(db).map { ($0.name.lowercased(), $0.id) },
            uniquingKeysWith: { first, _ in first }
        )
        guard let (sql, arguments) = query.localSQL(limit: limit, mailboxIdsByName: mailboxIdsByName) else { return [] }
        return try MessageRecord.fetchAll(db, sql: sql, arguments: arguments)
    }
}
