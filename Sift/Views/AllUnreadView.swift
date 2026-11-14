import SiftKit
import SwiftUI

/// Every unread message outside the Screener, Screened Out, Spam and Trash, one
/// after another, each in its own section, newest first. Each is marked read as
/// it comes on screen but stays until you leave, so nothing moves while you read.
/// Older unread mail joins the bottom as you go; mail that arrives meanwhile
/// waits behind a button at the top.
struct AllUnreadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.compose) private var compose
    @Environment(\.openWindow) private var openWindow
    @State private var unread = LiveQuery<UnreadMail>()
    @State private var reading = LiveQuery<ReadingMessages>()
    /// What's on the page. Unset until the first look at what's unread.
    @State private var sections: [UnreadSection]?
    @State private var collapsed: Set<String> = []
    @State private var showSender: IdentifiedString?

    /// How many to look at once. Reading them makes room for older ones.
    private static let window = 50
    private static let top = "top"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                let records = records
                LazyVStack(alignment: .leading, spacing: 28) {
                    Color.clear.frame(height: 0).id(Self.top)
                    ForEach(sections ?? []) { section in
                        let copies = section.ids.compactMap { records[$0] }
                        if !copies.isEmpty {
                            sectionView(MessageRecord.merging(copies), copies: copies)
                        }
                    }
                    if let sections, !sections.isEmpty, isComplete {
                        Label("That's everything unread.", systemImage: "checkmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
            .overlay(alignment: .top) {
                if !waiting.isEmpty {
                    Button {
                        showWaiting()
                        withAnimation(.snappy) { proxy.scrollTo(Self.top, anchor: .top) }
                    } label: {
                        Label(waiting.count == 1 ? "1 New Message" : "\(waiting.count) New Messages",
                              systemImage: "arrow.up")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
        .background(Color.readerBackground)
        .overlay {
            if sections?.isEmpty == true, waiting.isEmpty {
                EmptyState(title: "All Caught Up", systemImage: "checkmark.circle",
                           message: "Nothing unread, apart from the Screener, Spam and Trash.")
            }
        }
        .navigationTitle("All Unread")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        // Here, not further up: links can't see destinations set on the view this was pushed from.
        .navigationDestination(for: ThreadRoute.self) { PushedThreadView(threadId: $0.id) }
        #endif
        .sheet(item: $showSender) { sender in
            NavigationStack {
                SenderSettingsView(email: sender.value)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showSender = nil }
                        }
                    }
            }
        }
        .onAppear {
            guard let excluded = model.special?.quarantined else { return }
            unread.start(model.store, .unread(excluding: excluded, limit: Self.window), key: "unread")
        }
        .onChange(of: unread.value) { _, value in
            if let value { arrived(value) }
        }
        .onChange(of: sections) { _, sections in
            let ids = (sections ?? []).flatMap(\.ids)
            reading.start(model.store, .reading(ids), key: ids.joined(separator: ","))
        }
    }

    // MARK: - A message's section

    private func sectionView(_ message: MessageRecord, copies: [MessageRecord]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                LabelRow(message: message)
                Spacer(minLength: 8)
                conversationLink(message)
                    .layoutPriority(1)
            }
            .padding(.horizontal, 20)
            MessageCard(
                message: message,
                copies: copies,
                isExpanded: !collapsed.contains(message.id),
                onToggle: { toggle(message.id) },
                onSender: { openSender(message.fromEmail) }
            )
            HStack(spacing: 10) {
                Button("Reply", systemImage: "arrowshape.turn.up.left") {
                    compose(ComposeRequest(replyTo: message))
                }
                if let inbox = model.special?.inbox, message.mailboxIds.contains(inbox) {
                    Button("Archive", systemImage: "archivebox") { archive(message) }
                }
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .padding(.horizontal, 20)
        }
    }

    /// The whole conversation, when there's more to it than this message: in
    /// its own window on the Mac, pushed elsewhere.
    @ViewBuilder private func conversationLink(_ message: MessageRecord) -> some View {
        let size = reading.value?.conversationSizes[message.threadId] ?? 1
        if size > 1 {
            let label = HStack(spacing: 3) {
                Text("\(size) in Conversation")
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
            }
            .font(.caption.weight(.medium))
            .lineLimit(1)
            .fixedSize()
            #if os(macOS)
            Button { openWindow(id: "thread", value: message.threadId) } label: { label }
                .buttonStyle(.link)
            #else
            NavigationLink(value: ThreadRoute(id: message.threadId)) { label }
            #endif
        }
    }

    // MARK: - What's on the page

    private var records: [String: MessageRecord] {
        Dictionary((reading.value?.messages ?? []).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Unread messages that aren't on the page yet: ones that came in while
    /// you were reading (or were marked unread elsewhere).
    private var waiting: [UnreadSection] {
        guard let sections, let value = unread.value else { return [] }
        let shown = Set(sections.flatMap(\.ids))
        // Older ones join the bottom by themselves (see `arrived`).
        let oldest = sections.last?.receivedAt ?? .distantFuture
        return value.messages.map(UnreadSection.init)
            .filter { !$0.ids.contains(where: shown.contains) && $0.receivedAt >= oldest }
    }

    /// No unread mail left beyond what's on the page.
    private var isComplete: Bool {
        guard let value = unread.value else { return false }
        return value.total <= value.messages.count
    }

    /// The first look fills the page. After that, older mail that's come into
    /// view (because you read what was ahead of it) joins the bottom; newer
    /// mail waits for the button, so the page doesn't move under you.
    private func arrived(_ value: UnreadMail) {
        let found = value.messages.map(UnreadSection.init)
        guard var current = sections else {
            sections = found
            return
        }
        let shown = Set(current.flatMap(\.ids))
        let oldest = current.last?.receivedAt ?? .distantFuture
        let older = found.filter { !$0.ids.contains(where: shown.contains) && $0.receivedAt < oldest }
        guard !older.isEmpty else { return }
        current += older
        sections = current
    }

    private func showWaiting() {
        guard let current = sections else { return }
        withAnimation(.snappy) {
            sections = (current + waiting).sorted { $0.receivedAt > $1.receivedAt }
        }
    }

    private func archive(_ message: MessageRecord) {
        let undo = undoManager
        withAnimation(.snappy) { sections?.removeAll { section in section.ids.contains { records[$0]?.threadId == message.threadId } } }
        Task { await model.archive(threads: [message.threadId], from: nil, undo: undo) }
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) } else { collapsed.insert(id) }
    }

    /// A sheet on iPhone and iPad; its own small window on the Mac.
    private func openSender(_ email: String) {
        #if os(macOS)
        openWindow(id: "sender", value: email)
        #else
        showSender = IdentifiedString(value: email)
        #endif
    }
}

/// One message on the All Unread page: the ids of its copies (mail to yourself
/// has two) and when it arrived.
struct UnreadSection: Identifiable, Hashable {
    var ids: [String]
    var receivedAt: Date
    var id: String { ids[0] }

    init(_ copies: [MessageRecord]) {
        ids = copies.map(\.id)
        receivedAt = copies.map(\.receivedAt).max() ?? .distantPast
    }
}

/// Pushes All Unread on iPhone, where the home screen is a navigation stack:
/// by value, so its conversation links find their destination, as search's do.
struct AllUnreadRoute: Hashable {}

/// Opens All Unread, showing how many messages are waiting to be read. `action`
/// nil pushes it (iPhone).
struct AllUnreadButton: View {
    @Environment(AppModel.self) private var model
    var action: (() -> Void)?
    @State private var count = 0

    var body: some View {
        Group {
            if let action {
                Button(action: action) { label }
            } else {
                NavigationLink(value: AllUnreadRoute()) { label }
            }
        }
        .accessibilityLabel(count == 1 ? "All Unread, 1 message" : "All Unread, \(count) messages")
        .help("All Unread (⌘5)")
        .task(id: model.special) {
            guard let store = model.store, let excluded = model.special?.quarantined else { return }
            do {
                for try await value in store.observe(.unread(excluding: excluded, limit: 0)) {
                    withAnimation(.snappy) { count = value.total }
                }
            } catch {}
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            Image(systemName: "envelope.stack")
            if count > 0 {
                Text(count, format: .number).monospacedDigit()
            }
        }
    }
}
