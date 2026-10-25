import Foundation

/// A message being written: what the compose screen edits, and what saving a
/// draft, sending and Undo Send pass around.
public struct OutgoingMessage: Codable, Sendable, Hashable {
    public struct Attachment: Codable, Sendable, Hashable, Identifiable {
        public var id: String { blobId }
        public var blobId: String
        public var name: String
        public var type: String
        public var size: Int

        public init(blobId: String, name: String, type: String, size: Int) {
            self.blobId = blobId
            self.name = name
            self.type = type
            self.size = size
        }
    }

    public var identityId: String
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var body: String
    public var attachments: [Attachment]
    /// Threading headers, so replies stay in their conversation.
    public var inReplyTo: [String]
    public var references: [String]
    /// The message being answered, flagged $answered once this is sent.
    public var answering: String?
    /// The saved draft this one replaces, if any.
    public var draftId: String?

    public init(identityId: String = "", to: [EmailAddress] = [], cc: [EmailAddress] = [], bcc: [EmailAddress] = [],
                subject: String = "", body: String = "", attachments: [Attachment] = [],
                inReplyTo: [String] = [], references: [String] = [], answering: String? = nil, draftId: String? = nil) {
        self.identityId = identityId
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
        self.answering = answering
        self.draftId = draftId
    }

    public var recipients: [EmailAddress] { to + cc + bcc }

    /// Nothing worth keeping as a draft.
    public var isBlank: Bool {
        recipients.isEmpty && attachments.isEmpty
            && subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The same content, ignoring which saved draft it lives in.
    public var content: OutgoingMessage {
        var copy = self
        copy.draftId = nil
        return copy
    }
}

/// A message handed to Fastmail. With a hold, it can still be called back.
public struct Sending: Sendable, Hashable {
    public var emailId: String
    public var submissionId: String
    /// Seconds Fastmail holds it before delivery; 0 means it's already gone.
    public var heldFor: Int
}

public enum SendError: Error, LocalizedError, Equatable {
    case noIdentity
    case noRecipients
    case tooLateToUndo

    public var errorDescription: String? {
        switch self {
        case .noIdentity: "Choose an address to send from."
        case .noRecipients: "Add someone to send this to."
        case .tooLateToUndo: "Too late to undo: the message has already been sent."
        }
    }
}
