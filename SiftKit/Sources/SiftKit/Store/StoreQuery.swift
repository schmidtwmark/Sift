import Foundation
import GRDB

/// A live query views can observe without touching GRDB directly.
public struct StoreQuery<Value: Sendable>: Sendable {
    let fetch: @Sendable (Database) throws -> Value
}

public extension MailStore {
    /// Emits the query's current value, then again whenever the tables it read change.
    func observe<Value: Sendable>(_ query: StoreQuery<Value>) -> AsyncThrowingStream<Value, Error> {
        let observation = ValueObservation.tracking(query.fetch)
        let writer = self.writer
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in observation.values(in: writer) {
                        continuation.yield(value)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func read<Value: Sendable>(_ query: StoreQuery<Value>) async throws -> Value {
        try await writer.read(query.fetch)
    }
}

public extension StoreQuery where Value == [ThreadSummary] {
    /// `mailboxId` nil means the Everything view.
    static func threads(in mailboxId: String?, limit: Int) -> Self {
        Self { db in try MailStore.threads(in: mailboxId, limit: limit, in: db) }
    }
}

public extension StoreQuery where Value == [ScreenerEntry] {
    static func screener(_ screenerId: String) -> Self {
        Self { db in try MailStore.screenerEntries(screenerId: screenerId, in: db) }
    }
}

public extension StoreQuery where Value == [MailboxRecord] {
    static var mailboxes: Self {
        Self { db in try MailboxRecord.order(Column("sortOrder"), Column("name")).fetchAll(db) }
    }
}

public extension StoreQuery where Value == [MessageRecord] {
    static func thread(_ threadId: String) -> Self {
        Self { db in try MailStore.thread(threadId, in: db) }
    }

    static func search(_ query: SearchQuery, limit: Int = 200) -> Self {
        Self { db in try MailStore.search(query, limit: limit, in: db) }
    }

    static func ids(_ ids: [String]) -> Self {
        Self { db in try MessageRecord.fetchAll(db, keys: ids) }
    }
}

public extension StoreQuery where Value == [SenderRecord] {
    static var senders: Self {
        Self { db in try SenderRecord.order(Column("status"), Column("email")).fetchAll(db) }
    }
}

public extension StoreQuery where Value == SenderRecord? {
    static func sender(_ email: String) -> Self {
        Self { db in try SenderRecord.fetchOne(db, key: email.lowercased()) }
    }
}

public extension StoreQuery where Value == String? {
    /// The display name a sender most recently used.
    static func senderName(_ email: String) -> Self {
        Self { db in
            try String.fetchOne(db, sql: """
                SELECT fromName FROM message
                WHERE fromEmail = ? AND coalesce(fromName, '') != ''
                ORDER BY receivedAt DESC LIMIT 1
                """, arguments: [email.lowercased()])
        }
    }
}

public extension StoreQuery where Value == Int {
    static func badgeCount(excluding mailboxIds: [String]) -> Self {
        Self { db in try MailStore.badgeCount(excludingMailboxIds: mailboxIds, in: db) }
    }

    static func messageCount(from sender: String) -> Self {
        Self { db in try MessageRecord.filter(Column("fromEmail") == sender).fetchCount(db) }
    }
}

public extension StoreQuery where Value == [String: String] {
    /// Custom label icons: mailbox id → SF Symbol.
    static var labelIcons: Self {
        Self { db in
            let json = try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [MailStore.labelIconsKey])
            return json.flatMap { try? JSONDecoder().decode([String: String].self, from: Data($0.utf8)) } ?? [:]
        }
    }
}

public extension StoreQuery where Value == [BubbleUp] {
    /// Conversations set to bubble up, soonest first.
    static var bubbleUps: Self {
        Self { db in
            let json = try String.fetchOne(db, sql: "SELECT value FROM kv WHERE key = ?", arguments: [MailStore.bubbleUpsKey])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let list = json.flatMap { try? decoder.decode([BubbleUp].self, from: Data($0.utf8)) } ?? []
            return list.sorted { $0.at < $1.at }
        }
    }
}
