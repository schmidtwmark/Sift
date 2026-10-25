import Foundation
import GRDB

public struct MailboxRecord: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "mailbox"

    public var id: String
    public var name: String
    public var parentId: String?
    public var role: String?
    public var sortOrder: Int
    public var totalEmails: Int
    public var unreadEmails: Int

    public init(_ mailbox: Mailbox) {
        id = mailbox.id
        name = mailbox.name
        parentId = mailbox.parentId
        role = mailbox.role
        sortOrder = mailbox.sortOrder ?? 0
        totalEmails = mailbox.totalEmails ?? 0
        unreadEmails = mailbox.unreadEmails ?? 0
    }

    public var mailboxRole: MailboxRole? { role.flatMap(MailboxRole.init(rawValue:)) }
}

public struct MessageRecord: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "message"

    public var id: String
    public var threadId: String
    public var blobId: String?
    public var receivedAt: Date
    public var sentAt: Date?
    public var subject: String
    public var preview: String
    public var fromName: String?
    public var fromEmail: String
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var mailboxIds: [String]
    public var keywords: [String]
    public var hasAttachment: Bool
    public var size: Int
    public var messageIdHeader: String?
    public var inReplyTo: [String]
    public var references: [String]
    // Denormalized from `keywords` so list queries can filter cheaply.
    public private(set) var isUnread: Bool
    public private(set) var isFlagged: Bool

    public init(_ email: Email) {
        id = email.id
        threadId = email.threadId ?? email.id
        blobId = email.blobId
        receivedAt = email.receivedAt ?? .distantPast
        sentAt = email.sentAt
        subject = email.subject ?? ""
        preview = email.preview ?? ""
        let sender = email.from?.first
        fromName = sender?.name
        fromEmail = sender?.normalized ?? ""
        to = email.to ?? []
        cc = email.cc ?? []
        replyTo = email.replyTo ?? []
        mailboxIds = (email.mailboxIds ?? [:]).filter(\.value).keys.sorted()
        keywords = (email.keywords ?? [:]).filter(\.value).keys.map { $0.lowercased() }.sorted()
        hasAttachment = email.hasAttachment ?? false
        size = email.size ?? 0
        messageIdHeader = email.messageId?.first
        inReplyTo = email.inReplyTo ?? []
        references = email.references ?? []
        isUnread = true
        isFlagged = false
        refreshFlags()
    }

    public mutating func setKeyword(_ keyword: String, _ on: Bool) {
        keywords.removeAll { $0 == keyword }
        if on { keywords.append(keyword); keywords.sort() }
        refreshFlags()
    }

    private mutating func refreshFlags() {
        isUnread = !keywords.contains(Keyword.seen)
        isFlagged = keywords.contains(Keyword.flagged)
    }

    public var isDraft: Bool { keywords.contains(Keyword.draft) }
    public var isRouted: Bool { keywords.contains(Keyword.routed) }
    public var isBubble: Bool { keywords.contains(Keyword.bubble) }
    public var sender: EmailAddress { EmailAddress(name: fromName, email: fromEmail) }
}

public enum Keyword {
    public static let seen = "$seen"
    public static let flagged = "$flagged"
    public static let draft = "$draft"
    public static let answered = "$answered"
    /// Marks mail Sift has already sorted, so every device (and a future
    /// server) routes each message exactly once.
    public static let routed = "$siftrouted"
    /// A Bubble Up note that has arrived: kept so the conversation stays on
    /// top (in Fastmail too), but hidden in Sift.
    public static let bubble = "$siftbubble"
}

public struct BodyRecord: Codable, Sendable, Hashable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "body"

    public var messageId: String
    public var html: String?
    public var text: String?
    public var attachments: [EmailBodyPart]
    /// Inline parts referenced as `cid:` URLs, keyed by content-id.
    public var inlineParts: [String: EmailBodyPart]
    public var fetchedAt: Date
}

/// How Sift treats a sender. The source of truth is synced through
/// `SenderRuleStore`; this table is the local cache.
public struct SenderRecord: Codable, Sendable, Hashable, Identifiable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sender"

    public enum Status: String, Codable, Sendable, DatabaseValueConvertible {
        case unknown, screenedIn, screenedOut
    }

    public var id: String { email }
    public var email: String
    public var name: String?
    public var status: Status
    /// Mailbox ids new mail from this sender is filed into. Empty means "leave it in the Inbox".
    public var labelIds: [String]
    public var notify: Bool
    public var badge: Bool
    public var updatedAt: Date

    public init(email: String, name: String? = nil, status: Status = .unknown, labelIds: [String] = [],
                notify: Bool = false, badge: Bool = false, updatedAt: Date = .now) {
        self.email = email
        self.name = name
        self.status = status
        self.labelIds = labelIds
        self.notify = notify
        self.badge = badge
        self.updatedAt = updatedAt
    }
}

/// A conversation as shown in a list: the newest message plus thread stats.
public struct ThreadSummary: Sendable, Hashable, Identifiable, FetchableRecord {
    public var id: String { latest.threadId }
    /// The newest real message (Bubble Up notes never show).
    public var latest: MessageRecord
    public var messageCount: Int
    public var unreadCount: Int
    public var participants: String
    /// When the conversation last bubbled up, if that's its latest activity.
    public var bubbledAt: Date?

    public init(row: Row) throws {
        latest = try MessageRecord(row: row)
        messageCount = row["messageCount"]
        unreadCount = row["unreadCount"]
        participants = row["participants"] ?? ""
        let bubbled: Date? = row["bubbledAt"]
        bubbledAt = bubbled.flatMap { $0 > latest.receivedAt ? $0 : nil }
    }
}

/// A sender waiting in the Screener with their pending messages.
public struct ScreenerEntry: Sendable, Hashable, Identifiable {
    public var id: String { email }
    public var email: String
    public var name: String?
    public var messages: [MessageRecord]
}
