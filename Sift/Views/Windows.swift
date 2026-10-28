#if os(macOS)
import SiftKit
import SwiftUI

/// Waits for the account before showing a window's content, since restored
/// windows can open before the main window has signed in.
private struct WhenReady<Content: View>: View {
    @Environment(AppModel.self) private var model
    @ViewBuilder var content: () -> Content

    var body: some View {
        switch model.phase {
        case .ready:
            content()
        case .signedOut, .failed:
            EmptyState(title: "Not Signed In", systemImage: "person.crop.circle.badge.exclamationmark",
                       message: "Sign in from the main window.")
        default:
            ProgressView()
        }
    }
}

/// A conversation in its own window (double-click, Return or ⌘O).
struct ThreadWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let threadId: String?

    var body: some View {
        WhenReady {
            if let threadId {
                ThreadView(threadId: threadId, onClose: { dismiss() }, isWindow: true)
            }
        }
        .frame(minWidth: 520, minHeight: 400)
        .task { await model.launch() }
    }
}

/// A message being written. Replies look their original up by id, so the
/// window's value stays small and Codable. mailto: links from other apps open
/// one of these too (see `handlesExternalEvents` in SiftApp).
struct ComposeWindow: View {
    @Environment(AppModel.self) private var model
    let target: ComposeTarget?
    @State private var request: ComposeRequest?

    var body: some View {
        WhenReady {
            if let request {
                ComposeView(request: request)
                    .id(request.id)
            } else {
                ProgressView().frame(minWidth: 560, minHeight: 520)
            }
        }
        // A link can open Sift before any viewer window has signed in.
        .task { await model.launch() }
        .task(id: model.phase) {
            guard request == nil, model.phase == .ready else { return }
            request = await resolve()
        }
        .onOpenURL { url in
            if let link = MailtoLink(url) { request = ComposeRequest(mailto: link) }
        }
    }

    private func resolve() async -> ComposeRequest {
        if let draft = target?.draft { return ComposeRequest(draft: draft) }
        if let link = target?.mailto { return ComposeRequest(mailto: link) }
        guard let target, let id = target.messageId,
              let original = try? await model.store?.messages(ids: [id]).first else { return ComposeRequest() }
        switch target.kind {
        case .new: return ComposeRequest()
        case .reply: return ComposeRequest(replyTo: original)
        case .replyAll: return ComposeRequest(replyTo: original, replyAll: true)
        case .forward: return ComposeRequest(forward: original)
        }
    }
}

/// Alerts, badge and filing for one sender (⌥⌘I).
struct SenderWindow: View {
    let email: String?

    var body: some View {
        WhenReady {
            if let email {
                SenderSettingsView(email: email)
            }
        }
        .frame(minWidth: 400, minHeight: 460)
    }
}

/// Help ▸ Sift Help: search syntax and keyboard shortcuts.
struct HelpView: View {
    private let operators: [(String, String)] = [
        ("from:alex", "From a sender (name or address)"),
        ("to:me@example.com", "Sent to an address"),
        ("subject:invoice", "Words in the subject"),
        ("has:attachment", "Has attachments"),
        ("is:unread  ·  is:read", "Read state"),
        ("is:pinned", "Pinned conversations"),
        ("in:receipts", "In a label or folder"),
        ("after:30d  ·  before:2026-01-01", "Dates, absolute or relative"),
        ("\"exact phrase\"", "Words in this order"),
        ("-word  ·  -from:news", "Leave matches out"),
        ("lunch OR dinner", "Either side matches (uppercase OR)"),
    ]

    private let shortcuts: [(String, String)] = [
        ("⌘N", "New Message"),
        ("⌥⌘N", "New Viewer Window"),
        ("⌘O  ·  Return  ·  double-click", "Open conversation in its own window"),
        ("⌥⌘F", "Search all mail"),
        ("⌘1 ⌘2 ⌘3 ⌘4", "Screener, Inbox, Everything, Senders"),
        ("⌘R", "Get New Mail"),
        ("⌥⌘R  ·  ⇧⌘R  ·  ⇧⌘F", "Reply, Reply All, Forward"),
        ("⌃⌘A", "Archive"),
        ("⌫  ·  ⌘⌫", "Move to Trash"),
        ("⇧⌘J", "Move to Spam"),
        ("⇧⌘U", "Mark as Read or Unread"),
        ("⇧⌘L", "Pin or Unpin"),
        ("⌥⌘I", "Sender Settings"),
        ("⌘Z  ·  ⇧⌘Z", "Undo and Redo any move"),
        ("⇧⌘D", "Send (in a message window)"),
    ]

    var body: some View {
        Form {
            Section {
                Text("New senders wait in the Screener. Screen them in to the Inbox or straight into folders, or screen them out; Sift remembers, using groups in your Fastmail contacts, so it works on every device.")
                Text("Drag conversations onto a folder in the sidebar to move them. Select several with ⌘-click or ⇧-click to act on them all at once.")
            } header: {
                Text("Getting Around")
            }
            Section("Search") {
                ForEach(operators, id: \.0) { syntax, meaning in
                    LabeledContent {
                        Text(meaning)
                    } label: {
                        Text(syntax).font(.body.monospaced()).textSelection(.enabled)
                    }
                }
            }
            Section("Keyboard Shortcuts") {
                ForEach(shortcuts, id: \.0) { keys, action in
                    LabeledContent(action) {
                        Text(keys).font(.body.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 720)
    }
}
#endif
