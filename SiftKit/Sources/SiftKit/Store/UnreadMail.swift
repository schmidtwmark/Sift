import Foundation
import GRDB

/// All Unread: every unread message you'd want to read, each on its own,
/// outside the Screener and the piles you don't (Screened Out, Spam, Trash).
public struct UnreadMail: Sendable, Hashable {
    /// Newest first, each message with its copies (see `groupingCopies`).
    public var messages: [[MessageRecord]]
    /// How many there are in all, past the limit too.
    public var total: Int
}

/// The messages a reading page is showing, as they are now (read or not).
public struct ReadingMessages: Sendable, Hashable {
    public var messages: [MessageRecord]
    /// Messages in each of their conversations (threadId → count), copies counted once.
    public var conversationSizes: [String: Int]
}

extension MailStore {
    /// `excluded` is the mailboxes to leave out (`SpecialMailboxes.quarantined`).
    /// Drafts and Bubble Up notes never count.
    public static func unread(excluding excluded: [String], limit: Int, in db: Database) throws -> UnreadMail {
        let placeholders = excluded.isEmpty ? "''" : excluded.map { _ in "?" }.joined(separator: ",")
        let filter = """
            FROM message m
            WHERE m.isUnread AND m.keywords NOT LIKE ? AND m.keywords NOT LIKE ?
              AND NOT EXISTS (SELECT 1 FROM messageMailbox mm WHERE mm.messageId = m.id AND mm.mailboxId IN (\(placeholders)))
            """
        let arguments = StatementArguments([bubblePattern, draftPattern] + excluded)
        let total = try Int.fetchOne(db, sql: "SELECT count(DISTINCT coalesce(m.messageIdHeader, m.id)) \(filter)",
                                     arguments: arguments) ?? 0
        // Copies are fetched alongside, so the limit counts each message once.
        let records = try MessageRecord.fetchAll(db, sql: """
            SELECT m.* \(filter) AND coalesce(m.messageIdHeader, m.id) IN (
                SELECT coalesce(m.messageIdHeader, m.id) \(filter)
                GROUP BY 1 ORDER BY max(m.receivedAt) DESC LIMIT ?
            )
            ORDER BY m.receivedAt DESC
            """, arguments: arguments + arguments + [limit])
        return UnreadMail(messages: records.groupingCopies(), total: total)
    }

    /// `ids` in the order given; any no longer stored are left out.
    public static func reading(_ ids: [String], in db: Database) throws -> ReadingMessages {
        let found = try MessageRecord.fetchAll(db, keys: ids)
        let byId = Dictionary(found.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let threads = Array(Set(found.map(\.threadId)))
        var sizes: [String: Int] = [:]
        if !threads.isEmpty {
            let rows = try Row.fetchAll(db, sql: """
                SELECT threadId, count(DISTINCT coalesce(messageIdHeader, id)) AS size FROM message
                WHERE threadId IN (\(threads.map { _ in "?" }.joined(separator: ","))) AND keywords NOT LIKE ?
                GROUP BY threadId
                """, arguments: StatementArguments(threads + [bubblePattern]))
            for row in rows { sizes[row["threadId"]] = row["size"] }
        }
        return ReadingMessages(messages: ids.compactMap { byId[$0] }, conversationSizes: sizes)
    }

    /// Matches a message's keywords (JSON text) when it's a draft.
    static let draftPattern = "%\"\(Keyword.draft)\"%"
}

public extension StoreQuery where Value == UnreadMail {
    static func unread(excluding excluded: [String], limit: Int) -> Self {
        Self { db in try MailStore.unread(excluding: excluded, limit: limit, in: db) }
    }
}

public extension StoreQuery where Value == ReadingMessages {
    static func reading(_ ids: [String]) -> Self {
        Self { db in try MailStore.reading(ids, in: db) }
    }
}
