import SiftKit
import SwiftUI

/// Conversations in one label, or across the whole account (Everything).
struct ThreadListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    let mailboxId: String?
    let title: String
    @Binding var selection: Set<String>

    @State private var threads: [ThreadSummary] = []
    @State private var limit = 100
    @State private var isLoadingOlder = false
    @State private var reachedEnd = false
    @State private var showSort = false
    @State private var showIcons = false

    var body: some View {
        let items = threads.map(\.item)
        List(selection: $selection) {
            ForEach(threads) { thread in
                let item = thread.item
                ThreadRow(thread: thread, showLabels: mailboxId == nil)
                    .tag(item.id)
                    .swipeActions(edge: .leading) {
                        Button {
                            Task { await model.markThread(item.id, read: item.isUnread) }
                        } label: {
                            Label(item.isUnread ? "Read" : "Unread",
                                  systemImage: item.isUnread ? "envelope.open" : "envelope.badge")
                        }
                        .tint(.blue)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            Task { await model.trash(threads: [item.id], undo: undoManager) }
                        } label: {
                            Label("Trash", systemImage: "trash")
                        }
                        if mailboxId != nil {
                            Button {
                                Task { await model.archive(threads: [item.id], from: mailboxId, undo: undoManager) }
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.teal)
                        }
                    }
                    .conversationDrag(item, in: items, selection: selection, from: mailboxId)
            }
            if !threads.isEmpty, !reachedEnd {
                HStack {
                    Spacer()
                    if isLoadingOlder { ProgressView() } else { Text("Loading older mail…").foregroundStyle(.secondary) }
                    Spacer()
                }
                .onAppear { Task { await loadOlder() } }
            }
        }
        .conversationList(items, selection: $selection, mailboxId: mailboxId)
        .navigationTitle(title)
        .toolbar {
            if let mailboxId, model.mailbox(mailboxId)?.role == nil, mailboxId != model.special?.screenedOut {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Change Icon…", systemImage: "square.grid.2x2") { showIcons = true }
                        Button("Sort into Other Folders…", systemImage: "arrow.triangle.branch") { showSort = true }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(isPresented: $showSort) { FolderSortView(initialFolder: mailboxId) }
        .sheet(isPresented: $showIcons) {
            if let mailboxId {
                LabelIconPicker(mailboxId: mailboxId)
                    #if os(iOS)
                    .presentationDetents([.medium, .large])
                    #endif
            }
        }
        .overlay {
            if threads.isEmpty {
                EmptyState(title: "Nothing here", systemImage: "tray",
                           message: mailboxId == nil ? "No mail synced yet." : "No conversations in \(title).")
            }
        }
        .refreshable { await model.refresh() }
        .task(id: "\(mailboxId ?? "*")-\(limit)") {
            guard let store = model.store else { return }
            do {
                for try await value in store.observe(.threads(in: mailboxId, limit: limit)) {
                    threads = value
                }
            } catch {}
        }
    }

    private func loadOlder() async {
        guard !isLoadingOlder else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let before = threads.count
        if threads.count >= limit {
            limit += 100
            return
        }
        // Local cache exhausted: ask Fastmail for older mail.
        if let oldest = threads.last?.latest.receivedAt {
            await model.loadOlder(in: mailboxId, before: oldest)
            try? await Task.sleep(for: .milliseconds(300))
            if threads.count == before { reachedEnd = true }
        }
    }
}

struct ThreadRow: View {
    @Environment(AppModel.self) private var model
    let thread: ThreadSummary
    var showLabels = false

    var body: some View {
        let message = thread.latest
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: message.senderDisplayName, email: message.fromEmail, size: 34)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(participants)
                        .font(.body.weight(thread.unreadCount > 0 ? .semibold : .regular))
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    BubbleUpBadge(threadId: thread.id, bubbledAt: thread.bubbledAt)
                    if message.isFlagged {
                        Image(systemName: "pin.fill").font(.caption).foregroundStyle(.orange)
                    }
                    Text(message.receivedAt.listLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                    .font(.subheadline.weight(thread.unreadCount > 0 ? .medium : .regular))
                    .lineLimit(1)
                Text(message.preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if showLabels, !labelIds.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(labelIds, id: \.self) { id in
                            Label(model.name(of: id), systemImage: model.icon(for: id))
                                .labelStyle(.chip)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            if thread.unreadCount > 0 {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7).offset(x: -10)
            }
        }
    }

    private var participants: String {
        let names = thread.participants.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return names.count > 1 ? names.joined(separator: ", ") : thread.latest.senderDisplayName
    }

    private var labelIds: [String] {
        thread.latest.mailboxIds.filter { model.mailbox($0) != nil }
    }
}
