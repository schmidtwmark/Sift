import SiftKit
import SwiftUI

/// Instant results from the local index, then complete results from
/// Fastmail's server-side search (which also covers bodies and attachments).
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model
    let text: String
    @Binding var selection: Set<String>
    /// iPhone home-screen search: rows push the thread instead of selecting it.
    var pushesThreads = false

    @State private var local: [MessageRecord] = []
    @State private var serverIds: [String] = []
    @State private var server: [MessageRecord] = []
    @State private var snippets: [String: SearchSnippet] = [:]
    @State private var total: Int?
    @State private var isSearching = false
    @State private var serverError: String?

    private var query: SearchQuery { SearchQuery(text) }

    var body: some View {
        list
            .navigationTitle("Search")
            .overlay {
                if results.isEmpty, !isSearching {
                    ContentUnavailableView.search(text: text)
                }
            }
            .task(id: text) {
                guard let store = model.store, !query.isEmpty else { return }
                do {
                    for try await value in store.observe(.search(query)) { local = value }
                } catch {}
            }
            .task(id: text) {
                // Debounce typing, then ask the server.
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, !query.isEmpty else { return }
                isSearching = true
                defer { isSearching = false }
                do {
                    let result = try await model.search(query)
                    guard !Task.isCancelled else { return }
                    serverIds = result.messages.map(\.id)
                    server = result.messages
                    snippets = result.snippets
                    total = result.total
                    serverError = nil
                } catch is CancellationError {
                } catch {
                    serverError = error.localizedDescription
                }
            }
    }

    @ViewBuilder private var list: some View {
        if pushesThreads {
            List { resultsSection }
        } else {
            List(selection: $selection) { resultsSection }
                .conversationList(items, selection: $selection, mailboxId: nil)
        }
    }

    /// One row per conversation: its newest matching message.
    private var items: [ConversationItem] {
        var seen = Set<String>()
        return results.filter { seen.insert($0.threadId).inserted }
            .map { ConversationItem(id: $0.threadId, latest: $0, isUnread: $0.isUnread) }
    }

    private var resultsSection: some View {
        Section {
            ForEach(pushesThreads ? results : items.map(\.latest)) { message in
                row(message)
            }
        } header: {
            HStack {
                if isSearching {
                    ProgressView().controlSize(.small)
                    Text("Searching Fastmail…")
                } else if let total {
                    Text("\(total) result\(total == 1 ? "" : "s")")
                } else if let serverError {
                    Text("Showing cached mail only · \(serverError)").lineLimit(1)
                }
            }
            .font(.caption)
        }
    }

    @ViewBuilder private func row(_ message: MessageRecord) -> some View {
        let row = SearchRow(message: message, snippet: snippets[message.id], terms: query.highlightTerms)
        if pushesThreads {
            NavigationLink(value: ThreadRoute(id: message.threadId)) { row }
        } else {
            row.tag(message.threadId)
                .draggable(ConversationDrag([ConversationItem(id: message.threadId, latest: message, isUnread: message.isUnread)], from: nil))
        }
    }

    /// Server order wins once it arrives; local hits fill in while waiting.
    private var results: [MessageRecord] {
        var seen = Set<String>()
        // Bubble Up notes repeat the subject; the conversation itself is the result.
        let merged = (server + local).filter { !$0.isBubble && seen.insert($0.id).inserted }
        return merged.sorted { $0.receivedAt > $1.receivedAt }
    }
}

struct SearchRow: View {
    let message: MessageRecord
    let snippet: SearchSnippet?
    let terms: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(message.senderDisplayName).font(.body.weight(message.isUnread ? .semibold : .regular)).lineLimit(1)
                Spacer()
                Text(message.receivedAt.listLabel).font(.caption).foregroundStyle(.secondary)
            }
            Text(highlighted(snippet?.subject, fallback: message.subject.isEmpty ? "(no subject)" : message.subject))
                .font(.subheadline)
                .lineLimit(1)
            Text(highlighted(snippet?.preview, fallback: message.preview))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 3)
    }

    /// Uses Fastmail's `<mark>` snippets when present, else highlights the terms locally.
    private func highlighted(_ marked: String?, fallback: String) -> AttributedString {
        if let marked, marked.contains("<mark>") {
            var result = AttributedString()
            for (index, piece) in marked.components(separatedBy: "<mark>").enumerated() {
                let parts = piece.components(separatedBy: "</mark>")
                if index > 0, let hit = parts.first {
                    var run = AttributedString(HTMLText.decodeEntities(hit))
                    run.font = .subheadline.weight(.bold)
                    run.backgroundColor = .yellow.opacity(0.35)
                    result += run
                    result += AttributedString(HTMLText.decodeEntities(parts.dropFirst().joined()))
                } else {
                    result += AttributedString(HTMLText.decodeEntities(piece))
                }
            }
            return result
        }
        var result = AttributedString(marked.map(HTMLText.decodeEntities) ?? fallback)
        for term in terms where !term.isEmpty {
            var searchRange = result.startIndex..<result.endIndex
            while let range = result[searchRange].range(of: term, options: .caseInsensitive) {
                result[range].font = .subheadline.weight(.bold)
                result[range].backgroundColor = .yellow.opacity(0.35)
                searchRange = range.upperBound..<result.endIndex
            }
        }
        return result
    }
}

/// Operator hints shown under an empty search field.
struct SearchSuggestions: View {
    @Binding var text: String

    private let suggestions: [(String, String)] = [
        ("from:", "From a sender"),
        ("to:", "Sent to"),
        ("subject:", "In the subject"),
        ("has:attachment", "Has attachments"),
        ("is:unread", "Unread"),
        ("is:pinned", "Pinned"),
        ("in:", "In a label"),
        ("after:30d", "In the last 30 days"),
        ("before:2026-01-01", "Before a date"),
        ("OR ", "Either side matches"),
    ]

    var body: some View {
        if text.isEmpty || text.hasSuffix(" ") {
            ForEach(suggestions, id: \.0) { token, description in
                Label {
                    Text("\(Text(token).font(.body.monospaced()))  \(Text(description).foregroundStyle(.secondary))")
                } icon: {
                    Image(systemName: "magnifyingglass")
                }
                .searchCompletion(text + token)
            }
        }
    }
}
