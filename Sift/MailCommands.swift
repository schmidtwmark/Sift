import SiftKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar items, saved per window

extension SidebarItem {
    /// A stable string for `@SceneStorage`, so each window reopens where it was.
    var storageKey: String {
        switch self {
        case .screener: "screener"
        case .everything: "everything"
        case .senders: "senders"
        case .mailbox(let id): "mailbox:\(id)"
        }
    }

    init?(storageKey: String) {
        switch storageKey {
        case "screener": self = .screener
        case "everything": self = .everything
        case "senders": self = .senders
        case let key where key.hasPrefix("mailbox:"): self = .mailbox(String(key.dropFirst(8)))
        default: return nil
        }
    }
}

// MARK: - Compose: a sheet on iPhone, its own window on the Mac

/// What a compose window should start from. Codable so it can identify a window.
struct ComposeTarget: Codable, Hashable {
    enum Kind: String, Codable { case new, reply, replyAll, forward }
    var kind: Kind
    var messageId: String?
    var mailto: MailtoLink?
    var draft: OutgoingMessage?
    /// Distinguishes two blank compose windows.
    var token = UUID()

    init(_ request: ComposeRequest) {
        mailto = request.mailto
        draft = request.draft
        if let original = request.forward {
            kind = .forward
            messageId = original.id
        } else if let original = request.replyTo {
            kind = request.replyAll ? .replyAll : .reply
            messageId = original.id
        } else {
            kind = .new
            messageId = nil
        }
    }
}

struct ComposeAction {
    var open: (ComposeRequest) -> Void
    func callAsFunction(_ request: ComposeRequest = ComposeRequest()) { open(request) }
}

extension EnvironmentValues {
    @Entry var compose = ComposeAction { _ in }
}

// MARK: - What the menus act on

/// One row of a conversation list: a thread and its newest message.
struct ConversationItem: Identifiable {
    var id: String
    var latest: MessageRecord
    var isUnread: Bool
}

extension ThreadSummary {
    var item: ConversationItem { ConversationItem(id: id, latest: latest, isUnread: unreadCount > 0) }
}

/// The conversations selected in the focused window, for menu commands.
struct MailSelection {
    var threadIds: [String]
    /// The newest message, when exactly one conversation is selected.
    var latest: MessageRecord?
    var anyUnread: Bool
    var allPinned: Bool
    /// The folder being viewed (Archive removes it); nil for Everything and search.
    var mailboxId: String?
    var undoManager: UndoManager?

    init(_ items: [ConversationItem], mailboxId: String?, undoManager: UndoManager?) {
        threadIds = items.map(\.id)
        latest = items.count == 1 ? items.first?.latest : nil
        anyUnread = items.contains(where: \.isUnread)
        allPinned = !items.isEmpty && items.allSatisfy(\.latest.isFlagged)
        self.mailboxId = mailboxId
        self.undoManager = undoManager
    }
}

/// Window-level commands: navigation, search and compose.
struct WindowCommands {
    var show: (SidebarItem) -> Void
    var focusSearch: () -> Void
    var compose: (ComposeRequest) -> Void
    /// True while typing in the search field, so ⌘⌫ edits text instead of trashing mail.
    var isEditingText: Bool
}

extension FocusedValues {
    @Entry var mailSelection: MailSelection?
    @Entry var windowCommands: WindowCommands?
}

// MARK: - Dragging conversations

extension UTType {
    /// Declared in Info.plist (UTExportedTypeDeclarations).
    nonisolated static let siftConversation = UTType(exportedAs: "com.markschmidt.sift.conversation")
}

/// Conversations being dragged (onto a folder) or copied. Other apps get plain text.
nonisolated struct ConversationDrag: Codable, Transferable {
    var threadIds: [String]
    var sourceMailbox: String?
    var summary: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .siftConversation)
        ProxyRepresentation(exporting: \.summary)
    }

    init(_ items: [ConversationItem], from mailbox: String?) {
        threadIds = items.map(\.id)
        sourceMailbox = mailbox
        summary = items.map { item in
            let message = item.latest
            let subject = message.subject.isEmpty ? "(no subject)" : message.subject
            return "\(subject) — \(message.senderDisplayName) <\(message.fromEmail)>, \(message.receivedAt.formatted(date: .abbreviated, time: .shortened))"
        }
        .joined(separator: "\n")
    }
}
