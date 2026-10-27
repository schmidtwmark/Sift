import SiftKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(\.compose) private var compose
    @Environment(\.undoManager) private var undoManager
    @Binding var selection: SidebarItem?
    @Binding var showSettings: Bool
    @State private var screenerCount = 0
    @State private var searchText = ""

    /// On iPhone the sidebar is the home screen, so search lives here: results
    /// replace the list and push threads. iPad and Mac search from the toolbar.
    private var searchesHere: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if searchesHere, !searchText.isEmpty {
                SearchResultsView(text: searchText, selection: .constant([]), pushesThreads: true)
            } else {
                mailboxList
            }
        }
        .modifier(HomeSearch(enabled: searchesHere, text: $searchText))
        .navigationDestination(for: ThreadRoute.self) { route in
            PushedThreadView(threadId: route.id)
        }
    }

    private var mailboxList: some View {
        List(selection: $selection) {
            Section {
                // Only there when someone is waiting (or you're looking at it).
                if screenerCount > 0 || selection == .screener {
                    Label {
                        Text("Screener")
                    } icon: {
                        Image(systemName: "person.crop.circle.badge.questionmark")
                    }
                    .badge(screenerCount)
                    .tag(SidebarItem.screener)
                }
                if let inbox = model.special.flatMap({ model.mailbox($0.inbox) }) {
                    Label("Inbox", systemImage: "tray")
                        .badge(inbox.unreadEmails)
                        .tag(SidebarItem.mailbox(inbox.id))
                        .modifier(FolderDrop(target: inbox.id, undo: undoManager))
                }
            }

            // Drag to reorder (on iPhone, after tapping Edit); the order is saved in Fastmail.
            Section("Labels") {
                ForEach(folders) { label in
                    Label(label.name, systemImage: model.icon(for: label.id))
                        .badge(label.unreadEmails)
                        .tag(SidebarItem.mailbox(label.id))
                        .modifier(FolderDrop(target: label.id, undo: undoManager))
                        .modifier(LabelIconEditing(mailboxId: label.id))
                }
                .onMove { from, to in
                    var ids = folders.map(\.id)
                    ids.move(fromOffsets: from, toOffset: to)
                    Task { await model.reorderFolders(ids) }
                }
            }

            // System piles: no unread counts, by design.
            Section("More") {
                Label("Everything", systemImage: "square.stack.3d.up").tag(SidebarItem.everything)
                ForEach(systemMailboxes, id: \.id) { item in
                    Label(item.name, systemImage: item.icon)
                        .tag(SidebarItem.mailbox(item.id))
                        .modifier(FolderDrop(target: item.id, undo: undoManager, enabled: item.acceptsDrops))
                }
                Label("Senders", systemImage: "person.2").tag(SidebarItem.senders)
            }
        }
        #if os(macOS)
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Message", systemImage: "square.and.pencil") { compose() }
                    .help("New Message (⌘N)")
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
            #endif
        }
        .refreshable { await model.refresh() }
        .task(id: model.special?.screener) {
            guard let store = model.store, let screener = model.special?.screener else { return }
            do {
                for try await entries in store.observe(.screener(screener)) {
                    screenerCount = entries.count
                }
            } catch {}
        }
    }

    /// Your own folders, in your order (Inbox has its own row above).
    private var folders: [MailboxRecord] {
        model.labels.filter { $0.id != model.special?.inbox }
    }

    private var systemMailboxes: [(id: String, name: String, icon: String, acceptsDrops: Bool)] {
        guard let special = model.special else { return [] }
        let items: [(String?, String, String, Bool)] = [
            (special.screenedOut, "Screened Out", "hand.raised", false),
            (special.sent, "Sent", "paperplane", false),
            (special.drafts, "Drafts", "doc", false),
            (special.archive, "Archive", "archivebox", true),
            (special.junk, "Spam", "xmark.bin", true),
            (special.trash, "Trash", "trash", true),
        ]
        return items.compactMap { id, name, icon, drops in id.map { ($0, name, icon, drops) } }
    }
}

/// Lets conversations be dragged onto a folder to move them there.
private struct FolderDrop: ViewModifier {
    @Environment(AppModel.self) private var model
    let target: String
    let undo: UndoManager?
    var enabled = true

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: ConversationDrag.self) { drags, _ in
                guard !drags.isEmpty else { return false }
                Task {
                    for drag in drags {
                        await model.move(threads: drag.threadIds, from: drag.sourceMailbox, to: target, undo: undo)
                    }
                }
                return true
            }
        } else {
            content
        }
    }
}

/// A thread opened from home-screen search; Archive pops back to the results.
private struct PushedThreadView: View {
    @Environment(\.dismiss) private var dismiss
    let threadId: String

    var body: some View {
        ThreadView(threadId: threadId, onClose: { dismiss() })
    }
}

/// Adds the home-screen search field only where the sidebar is the home screen.
private struct HomeSearch: ViewModifier {
    let enabled: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(text: $text, prompt: "Search all mail")
                .searchSuggestions { SearchSuggestions(text: $text) }
                .plainSearchInput()
        } else {
            content
        }
    }
}
