import SiftKit
import SwiftUI

/// First-time senders wait here until you decide: screen them in (into one or
/// more labels) or screen them out.
struct ScreenerView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?
    @State private var entries: [ScreenerEntry] = []

    var body: some View {
        List(selection: $selection) {
            if !entries.isEmpty {
                Section {
                    ForEach(entries) { entry in
                        ScreenerCard(entry: entry)
                            .tag(entry.email)
                    }
                } footer: {
                    Text("Your choice applies to future mail from each sender, on every device and in Fastmail.")
                }
            }
        }
        .navigationTitle("Screener")
        .overlay {
            if entries.isEmpty {
                EmptyState(title: "All clear", systemImage: "checkmark.seal",
                           message: "New senders show up here before they reach your labels.")
            }
        }
        .refreshable { await model.refresh() }
        .task(id: model.special?.screener) {
            guard let store = model.store, let screener = model.special?.screener else { return }
            do {
                for try await value in store.observe(.screener(screener)) {
                    withAnimation(.snappy) { entries = value }
                }
            } catch {}
        }
    }
}

struct ScreenerCard: View {
    @Environment(AppModel.self) private var model
    let entry: ScreenerEntry
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Avatar(name: entry.name ?? entry.email, email: entry.email, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name ?? entry.email).font(.headline).lineLimit(1)
                    Text(entry.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if entry.messages.count > 1 {
                    Text("\(entry.messages.count) emails")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let latest = entry.messages.first {
                VStack(alignment: .leading, spacing: 2) {
                    Text(latest.subject.isEmpty ? "(no subject)" : latest.subject)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Text(latest.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            HStack {
                Button(role: .destructive) {
                    Task { await act { await model.screenOut(entry) } }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "hand.raised")
                        Text("Screen Out")
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                Spacer()
                ScreenInButton { labels in
                    await act { await model.screenIn(entry, labels: labels) }
                }
            }
            .disabled(isWorking)
        }
        .padding(.vertical, 6)
    }

    private func act(_ work: () async -> Void) async {
        isWorking = true
        await work()
        isWorking = false
    }
}

/// A split capsule: the main half screens the sender in to the Inbox; the
/// chevron opens the folder menu, applied by its last item.
struct ScreenInButton: View {
    @Environment(AppModel.self) private var model
    var title = "Screen In"
    var applyTitle: (Int) -> String = { count in count == 1 ? "Screen In to 1 Folder" : "Screen In to \(count) Folders" }
    /// The main half; screens in to the Inbox unless given.
    var onPrimary: (() async -> Void)?
    let onScreenIn: (Set<String>) async -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button {
                if let onPrimary {
                    Task { await onPrimary() }
                } else if let inbox = model.special?.inbox {
                    Task { await onScreenIn([inbox]) }
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark")
                    Text(title)
                }
                .lineLimit(1)
                .padding(.leading, 14)
                .padding(.trailing, 10)
                .frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Rectangle()
                .fill(.white.opacity(0.4))
                .frame(width: 1, height: 18)

            FolderMenu(
                applyTitle: applyTitle,
                applyIcon: "tray.and.arrow.down",
                onApply: { folders in Task { await onScreenIn(folders) } }
            ) {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.bold))
                    .padding(.leading, 10)
                    .padding(.trailing, 13)
                    .frame(height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Choose folders")
            .help("Choose folders…")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white)
        .background(.tint, in: Capsule())
        .fixedSize()
    }
}

/// A sender waiting in the Screener, read like any other email, with the
/// decision at the bottom. Deciding files their mail and keeps you here, so
/// you see where it went.
struct ScreenerSenderView: View {
    @Environment(AppModel.self) private var model
    let email: String

    /// The Screener, to find this sender when the view opens. Object-owned
    /// observations, because a `.task` can be cancelled mid-navigation on iPhone.
    @State private var waiting = LiveQuery<[ScreenerEntry]>()
    /// The sender's messages, followed by id so they stay after they're filed.
    @State private var messages = LiveQuery<[MessageRecord]>()
    @State private var opened: ScreenerEntry?
    @State private var decision: Decision?
    @State private var isWorking = false
    @State private var expanded: Set<String> = []

    enum Decision: Equatable {
        case screenedIn(Set<String>)
        case screenedOut
    }

    var body: some View {
        Group {
            if let opened {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        header(opened)
                        ForEach(shown) { message in
                            MessageCard(
                                message: message,
                                isExpanded: expanded.contains(message.id),
                                onToggle: { toggle(message.id) }
                            )
                        }
                    }
                    .padding(.vertical, 8)
                    .frame(maxWidth: 860)
                    .frame(maxWidth: .infinity)
                }
                .background(Color.readerBackground)
                .safeAreaInset(edge: .bottom) { decisionBar(opened) }
            } else if waiting.value == nil {
                ProgressView()
            } else {
                EmptyState(title: "Already Screened", systemImage: "checkmark.circle",
                           message: "This sender isn't waiting in the Screener any more.")
            }
        }
        .navigationTitle(opened?.name ?? email)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear {
            if let screener = model.special?.screener { waiting.start(model.store, .screener(screener), key: screener) }
        }
        .onChange(of: waiting.value) { _, entries in
            guard opened == nil, let entry = entries?.first(where: { $0.email == email }) else { return }
            opened = entry
            let ids = entry.messages.map(\.id)
            messages.start(model.store, .ids(ids), key: ids.joined(separator: ","))
            if let latest = entry.messages.first { expanded = [latest.id] }
        }
    }

    /// Newest first; while the live copies load, the ones from the Screener.
    private var shown: [MessageRecord] {
        let current = messages.value ?? opened?.messages ?? []
        return current.sorted { $0.receivedAt > $1.receivedAt }
    }

    private func header(_ entry: ScreenerEntry) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(entry.messages.count == 1 ? "1 Email" : "\(entry.messages.count) Emails")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 6) {
                ForEach(folders, id: \.self) { id in
                    Label(model.name(of: id), systemImage: model.icon(for: id))
                        .labelStyle(.chip)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.14), in: Capsule())
                }
            }
        }
        .padding(.horizontal, 20)
    }

    /// Where the newest message is now: the Screener, then wherever it was filed.
    private var folders: [String] {
        shown.first?.mailboxIds.filter { model.mailbox($0) != nil } ?? []
    }

    // MARK: - Decision

    @ViewBuilder private func decisionBar(_ entry: ScreenerEntry) -> some View {
        Group {
            if let decision {
                Label(outcome(decision), systemImage: decision == .screenedOut ? "hand.raised.fill" : "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(decision == .screenedOut ? AnyShapeStyle(.red) : AnyShapeStyle(.tint))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .transition(.opacity)
            } else {
                HStack {
                    Button(role: .destructive) {
                        Task { await decide(.screenedOut, entry) }
                    } label: {
                        Label("Screen Out", systemImage: "hand.raised")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    Spacer()
                    if isWorking { ProgressView().controlSize(.small) }
                    ScreenInButton { labels in await decide(.screenedIn(labels), entry) }
                }
                .disabled(isWorking)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func decide(_ choice: Decision, _ entry: ScreenerEntry) async {
        isWorking = true
        defer { isWorking = false }
        switch choice {
        case .screenedIn(let labels): await model.screenIn(entry, labels: labels)
        case .screenedOut: await model.screenOut(entry)
        }
        // Stay on the email; the folder chips above update as it moves.
        if model.errorMessage == nil { withAnimation(.snappy) { decision = choice } }
    }

    private func outcome(_ decision: Decision) -> String {
        switch decision {
        case .screenedOut:
            return "Screened out"
        case .screenedIn(let labels):
            let names = model.labels.filter { labels.contains($0.id) }.map(\.name)
            return "Screened in to \(names.isEmpty ? "Inbox" : names.formatted(.list(type: .and)))"
        }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}
