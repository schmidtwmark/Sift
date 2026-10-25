import Foundation

public enum JMAPCapability {
    public static let core = "urn:ietf:params:jmap:core"
    public static let mail = "urn:ietf:params:jmap:mail"
    public static let submission = "urn:ietf:params:jmap:submission"
    public static let contacts = "urn:ietf:params:jmap:contacts"
}

public struct JMAPSession: Codable, Sendable {
    public var apiUrl: URL
    public var downloadUrl: String
    public var uploadUrl: String
    public var eventSourceUrl: String
    public var username: String
    public var state: String
    public var primaryAccounts: [String: String]
    public var capabilities: [String: JSONValue]
    public var accounts: [String: Account]?

    public struct Account: Codable, Sendable {
        public var name: String?
        public var isReadOnly: Bool?
        public var accountCapabilities: [String: JSONValue]?
    }

    public var mailAccountId: String? { primaryAccounts[JMAPCapability.mail] }

    /// Scopes Sift needs that this token lacks, named as Fastmail's token
    /// settings name them. Empty when the token is good to go.
    public var missingScopes: [String] {
        func grants(_ capability: String) -> Bool {
            guard let id = primaryAccounts[capability] else { return false }
            guard let granted = accounts?[id]?.accountCapabilities else { return true }
            return granted[capability] != nil
        }
        var missing: [String] = []
        if !grants(JMAPCapability.mail) {
            missing.append("Email")
        } else if let id = mailAccountId, accounts?[id]?.isReadOnly == true {
            missing.append("Email write access (the token is read-only)")
        }
        if !grants(JMAPCapability.submission) { missing.append("Email submission") }
        if !grants(JMAPCapability.contacts) { missing.append("Contacts") }
        return missing
    }

    func downloadURL(accountId: String, blobId: String, name: String, type: String) -> URL? {
        let filled = downloadUrl
            .replacingOccurrences(of: "{accountId}", with: accountId.urlPathEscaped)
            .replacingOccurrences(of: "{blobId}", with: blobId.urlPathEscaped)
            .replacingOccurrences(of: "{name}", with: name.urlPathEscaped)
            .replacingOccurrences(of: "{type}", with: type.urlQueryEscaped)
        return URL(string: filled)
    }

    func uploadURL(accountId: String) -> URL? {
        URL(string: uploadUrl.replacingOccurrences(of: "{accountId}", with: accountId.urlPathEscaped))
    }

    func eventSourceURL(types: String = "*", ping: Int = 60) -> URL? {
        let filled = eventSourceUrl
            .replacingOccurrences(of: "{types}", with: types)
            .replacingOccurrences(of: "{closeafter}", with: "no")
            .replacingOccurrences(of: "{ping}", with: String(ping))
        return URL(string: filled)
    }
}

private extension String {
    var urlPathEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? self
    }

    var urlQueryEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+/"))) ?? self
    }
}

// MARK: - Mail objects

public enum MailboxRole: String, Codable, Sendable {
    case inbox, archive, drafts, sent, trash, junk, important, all, flagged, subscribed
}

public struct Mailbox: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var parentId: String?
    public var role: String?
    public var sortOrder: Int?
    public var totalEmails: Int?
    public var unreadEmails: Int?
    public var totalThreads: Int?
    public var unreadThreads: Int?
}

public struct EmailAddress: Codable, Sendable, Hashable {
    public var name: String?
    public var email: String?

    public init(name: String? = nil, email: String) {
        self.name = name
        self.email = email
    }

    /// Lowercased address, used as the key for sender rules.
    public var normalized: String { (email ?? "").trimmingCharacters(in: .whitespaces).lowercased() }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return email ?? ""
    }
}

public struct EmailBodyPart: Codable, Sendable, Hashable {
    public var partId: String?
    public var blobId: String?
    public var size: Int?
    public var name: String?
    public var type: String?
    public var charset: String?
    public var disposition: String?
    public var cid: String?
}

public struct EmailBodyValue: Codable, Sendable, Hashable {
    public var value: String
    public var isEncodingProblem: Bool?
    public var isTruncated: Bool?
}

public struct Email: Codable, Sendable, Identifiable {
    public var id: String
    public var blobId: String?
    public var threadId: String?
    public var mailboxIds: [String: Bool]?
    public var keywords: [String: Bool]?
    public var size: Int?
    public var receivedAt: Date?
    public var sentAt: Date?
    public var from: [EmailAddress]?
    public var to: [EmailAddress]?
    public var cc: [EmailAddress]?
    public var bcc: [EmailAddress]?
    public var replyTo: [EmailAddress]?
    public var subject: String?
    public var preview: String?
    public var hasAttachment: Bool?
    public var messageId: [String]?
    public var inReplyTo: [String]?
    public var references: [String]?
    public var htmlBody: [EmailBodyPart]?
    public var textBody: [EmailBodyPart]?
    public var attachments: [EmailBodyPart]?
    public var bodyValues: [String: EmailBodyValue]?

    /// Everyone the message was addressed to.
    public var recipients: [EmailAddress] {
        var all: [EmailAddress] = to ?? []
        all.append(contentsOf: cc ?? [])
        all.append(contentsOf: bcc ?? [])
        return all
    }

    public static let listProperties = [
        "id", "blobId", "threadId", "mailboxIds", "keywords", "size", "receivedAt", "sentAt",
        "from", "to", "cc", "replyTo", "subject", "preview", "hasAttachment",
        "messageId", "inReplyTo", "references",
    ]

    public static let bodyProperties = ["id", "htmlBody", "textBody", "attachments", "bodyValues"]
}

public struct Identity: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var email: String
    public var mayDelete: Bool?
    /// The plain-text signature set up in Fastmail, if any.
    public var textSignature: String?
}

public struct SearchSnippet: Codable, Sendable, Hashable {
    public var emailId: String
    public var subject: String?
    public var preview: String?
}

/// Push payload delivered over EventSource: account → type → new state.
public struct StateChange: Codable, Sendable {
    public var changed: [String: [String: String]]
}

// MARK: - Standard method responses

public struct GetResponse<T: Decodable & Sendable>: Decodable, Sendable {
    public var accountId: String
    public var state: String?
    public var list: [T]
    public var notFound: [String]?
}

public struct QueryResponse: Decodable, Sendable {
    public var accountId: String
    public var queryState: String?
    public var ids: [String]
    public var position: Int?
    public var total: Int?
}

public struct ChangesResponse: Decodable, Sendable {
    public var accountId: String
    public var oldState: String
    public var newState: String
    public var hasMoreChanges: Bool
    public var created: [String]
    public var updated: [String]
    public var destroyed: [String]
}

public struct SetError: Decodable, Sendable, Error, LocalizedError, CustomStringConvertible {
    public var type: String
    public var detail: String?
    /// For `invalidProperties`: which properties the server rejected.
    public var properties: [String]?
    /// What Sift was trying to do, e.g. "create the Sift address book".
    public var operation: String?

    enum CodingKeys: String, CodingKey {
        case type, properties
        case detail = "description"
    }

    public var description: String {
        var text = type
        if let properties, !properties.isEmpty { text += " [\(properties.joined(separator: ", "))]" }
        if let detail, !detail.isEmpty { text += ": \(detail)" }
        return text
    }

    public var errorDescription: String? {
        "Fastmail wouldn't \(operation ?? "save a change") (\(description))."
    }
}

public struct SetResponse: Decodable, Sendable {
    public var accountId: String
    public var newState: String?
    public var created: [String: JSONValue]?
    public var updated: [String: JSONValue]?
    public var destroyed: [String]?
    public var notCreated: [String: SetError]?
    public var notUpdated: [String: SetError]?
    public var notDestroyed: [String: SetError]?

    /// Throws the first per-object failure, if any, labelled with what was being attempted.
    public func throwIfFailed(_ operation: String) throws {
        if var error = notCreated?.values.first ?? notUpdated?.values.first ?? notDestroyed?.values.first {
            error.operation = operation
            JMAPClient.log.error("\(operation, privacy: .public) failed: \(error.description, privacy: .public)")
            throw error
        }
    }
}
