import SiftKit
import SwiftUI

/// What you can do to the selected conversations. Used for right-click menus,
/// and its pieces by the menu bar, so both always offer the same things.
struct ConversationMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.compose) private var compose
    @Environment(\.openWindow) private var openWindow
    let selection: MailSelection

    var body: some View {
        if let latest = selection.latest {
            #if os(macOS)
            Button("Open in New Window", systemImage: "macwindow") { openWindow(id: "thread", value: latest.threadId) }
            Divider()
            #endif
            Button("Reply", systemImage: "arrowshape.turn.up.left") { compose(ComposeRequest(replyTo: latest)) }
            Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { compose(ComposeRequest(replyTo: latest, replyAll: true)) }
            Button("Forward", systemImage: "arrowshape.turn.up.right") { compose(ComposeRequest(forward: latest)) }
            Divider()
            BubbleUpMenu(threadId: latest.threadId) {
                Label("Bubble Up", systemImage: AppModel.bubbleUpSymbol)
            }
        }
        ReadPinButtons(selection: selection)
        Divider()
        Menu("Move To", systemImage: "folder") { MoveToItems(selection: selection) }
        MoveButtons(selection: selection)
    }
}

struct ReadPinButtons: View {
    @Environment(AppModel.self) private var model
    let selection: MailSelection

    var body: some View {
        let ids = selection.threadIds
        Button(selection.anyUnread ? "Mark as Read" : "Mark as Unread",
               systemImage: selection.anyUnread ? "envelope.open" : "envelope.badge") {
            let read = selection.anyUnread
            Task { await model.markThreads(ids, read: read) }
        }
        Button(selection.allPinned ? "Unpin" : "Pin", systemImage: selection.allPinned ? "pin.slash" : "pin") {
            let pin = !selection.allPinned
            Task { await model.setPinned(ids, pin) }
        }
    }
}

/// Archive, Spam and Trash, each undoable from Edit ▸ Undo.
struct MoveButtons: View {
    @Environment(AppModel.self) private var model
    let selection: MailSelection

    var body: some View {
        let ids = selection.threadIds, source = selection.mailboxId, undo = selection.undoManager
        Button("Archive", systemImage: "archivebox") {
            Task { await model.archive(threads: ids, from: source, undo: undo) }
        }
        Button("Move to Spam", systemImage: "xmark.bin") {
            Task { await model.junk(threads: ids, undo: undo) }
        }
        Button("Move to Trash", systemImage: "trash", role: .destructive) {
            Task { await model.trash(threads: ids, undo: undo) }
        }
    }
}

/// One folder per item: Inbox, your labels, then Archive.
struct MoveToItems: View {
    @Environment(AppModel.self) private var model
    let selection: MailSelection

    var body: some View {
        ForEach(model.labels) { label in
            Button(label.name, systemImage: model.icon(for: label.id)) { move(to: label.id) }
                .disabled(label.id == selection.mailboxId)
        }
        if let archive = model.special?.archive {
            Divider()
            Button("Archive", systemImage: "archivebox") { move(to: archive) }
                .disabled(archive == selection.mailboxId)
        }
    }

    private func move(to target: String) {
        let ids = selection.threadIds, source = selection.mailboxId, undo = selection.undoManager
        Task { await model.move(threads: ids, from: source, to: target, undo: undo) }
    }
}

/// The Mac list behaviours every conversation list shares: right-click and
/// double-click, the Delete key, ⌘C, the menu bar's selection, and moving to
/// the next conversation when the selected one leaves the list.
struct ConversationListBehavior: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.openWindow) private var openWindow
    let items: [ConversationItem]
    @Binding var selection: Set<String>
    /// The folder being shown; nil for Everything and search.
    let mailboxId: String?

    func body(content: Content) -> some View {
        content
            #if os(macOS)
            .contextMenu(forSelectionType: String.self) { ids in
                if !ids.isEmpty { ConversationMenu(selection: mailSelection(ids)) }
            } primaryAction: { ids in
                for id in ids { openWindow(id: "thread", value: id) }
            }
            .onDeleteCommand {
                let ids = Array(selection)
                Task { await model.trash(threads: ids, undo: undoManager) }
            }
            .copyable(selectedItems.isEmpty ? [] : [ConversationDrag(selectedItems, from: mailboxId)])
            .onChange(of: items.map(\.id)) { old, new in selectNext(old: old, new: new) }
            #else
            .contextMenu(forSelectionType: String.self) { ids in
                if !ids.isEmpty { ConversationMenu(selection: mailSelection(ids)) }
            }
            #endif
            .focusedSceneValue(\.mailSelection, selection.isEmpty ? nil : mailSelection(selection))
    }

    private var selectedItems: [ConversationItem] { items.filter { selection.contains($0.id) } }

    private func mailSelection(_ ids: Set<String>) -> MailSelection {
        MailSelection(items.filter { ids.contains($0.id) }, mailboxId: mailboxId, undoManager: undoManager)
    }

    /// Mail-style: after archiving or deleting, the next conversation is selected.
    private func selectNext(old: [String], new: [String]) {
        guard !selection.isEmpty else { return }
        let remaining = Set(new)
        if !selection.isDisjoint(with: remaining) {
            if !selection.isSubset(of: remaining) { selection.formIntersection(remaining) }
            return
        }
        guard let first = old.firstIndex(where: selection.contains) else { return }
        let next = old[first...].first(where: remaining.contains) ?? old[..<first].last(where: remaining.contains)
        selection = next.map { [$0] } ?? []
    }
}

extension View {
    func conversationList(_ items: [ConversationItem], selection: Binding<Set<String>>, mailboxId: String?) -> some View {
        modifier(ConversationListBehavior(items: items, selection: selection, mailboxId: mailboxId))
    }

    /// Drags the whole selection when the row is part of it, else just the row.
    func conversationDrag(_ item: ConversationItem, in items: [ConversationItem], selection: Set<String>, from mailboxId: String?) -> some View {
        draggable(ConversationDrag(selection.contains(item.id) ? items.filter { selection.contains($0.id) } : [item], from: mailboxId))
    }
}

/// The reader when several conversations are selected.
struct MultiSelectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let threadIds: Set<String>
    let mailboxId: String?

    @State private var items: [ConversationItem] = []

    var body: some View {
        let selection = MailSelection(items, mailboxId: mailboxId, undoManager: undoManager)
        VStack(spacing: 18) {
            Image(systemName: "square.stack")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text("\(threadIds.count) Conversations Selected")
                .font(.title2.weight(.semibold))
            HStack {
                ForEach(Array(items.prefix(3))) { item in
                    Avatar(name: item.latest.senderDisplayName, email: item.latest.fromEmail, size: 28)
                }
                if items.count > 3 { Text("+\(items.count - 3)").font(.caption).foregroundStyle(.secondary) }
            }
            ControlGroup {
                MoveButtons(selection: selection)
            }
            .labelStyle(.titleAndIcon)
            .fixedSize()
            HStack {
                Menu("Move To", systemImage: "folder") { MoveToItems(selection: selection) }
                    .fixedSize()
                Menu("More", systemImage: "ellipsis.circle") { ReadPinButtons(selection: selection) }
                    .fixedSize()
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.readerBackground)
        .task(id: threadIds) {
            let messages = await model.messages(inThreads: Array(threadIds))
            let byThread = Dictionary(grouping: messages, by: \.threadId)
            items = byThread.compactMap { id, messages in
                guard let latest = messages.max(by: { $0.receivedAt < $1.receivedAt }) else { return nil }
                return ConversationItem(id: id, latest: latest, isUnread: messages.contains(where: \.isUnread))
            }
            .sorted { $0.latest.receivedAt > $1.latest.receivedAt }
        }
    }
}
