import SiftKit
import SwiftUI

/// Everything Sift knows and decides about one sender.
struct SenderSettingsView: View {
    @Environment(AppModel.self) private var model
    let email: String

    @State private var rule: SenderRecord?
    @State private var draft = SenderRecord(email: "")
    @State private var labels: Set<String> = []
    @State private var refile = true
    @State private var messageCount = 0
    @State private var isSaving = false
    @State private var loaded = false
    @State private var fallbackName: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Avatar(name: displayName, email: email, size: 44)
                    VStack(alignment: .leading) {
                        Text(displayName).font(.headline)
                        Text(email).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("\(messageCount) message\(messageCount == 1 ? "" : "s") cached")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Screening") {
                Picker("Status", selection: $draft.status) {
                    Text("Screened in").tag(SenderRecord.Status.screenedIn)
                    Text("Screened out").tag(SenderRecord.Status.screenedOut)
                    Text("Not decided").tag(SenderRecord.Status.unknown)
                }
                .pickerStyle(.segmented)
                if draft.status == .screenedIn {
                    LabeledContent("New mail goes to") {
                        FolderMenu(
                            initial: labels,
                            applyTitle: { count in count == 1 ? "Use 1 Folder" : "Use \(count) Folders" },
                            onApply: { labels = $0 }
                        ) {
                            HStack(spacing: 4) {
                                Text(folderSummary).lineLimit(1)
                                Image(systemName: "chevron.up.chevron.down").font(.caption)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section {
                Toggle("Notify me about new mail", isOn: $draft.notify)
                Toggle("Count in the app icon badge", isOn: $draft.badge)
            } header: {
                Text("Notifications")
            } footer: {
                Text(notificationFooter)
            }
            .disabled(draft.status == .screenedOut)

            Section {
                Toggle("Move existing mail to match", isOn: $refile)
            } footer: {
                Text("Saved in Sift's contact groups in Fastmail, so every device follows the same rule.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle(displayName)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }
                    .disabled(!hasChanges || isSaving || (draft.status == .screenedIn && labels.isEmpty))
            }
        }
        .task(id: email) {
            guard let store = model.store else { return }
            messageCount = (try? await store.read(.messageCount(from: email))) ?? 0
            fallbackName = (try? await store.read(.senderName(email))) ?? nil
            do {
                for try await value in store.observe(.sender(email)) {
                    rule = value
                    if !loaded { reset(from: value) }
                }
            } catch {}
        }
    }

    private var displayName: String { draft.name ?? fallbackName ?? email }

    private var folderSummary: String {
        let names = model.labels.filter { labels.contains($0.id) }.map(\.name)
        return names.isEmpty ? "Choose" : names.formatted(.list(type: .and))
    }

    private var notificationFooter: String {
        #if os(iOS)
        "Off by default for everyone. On iPhone, alerts arrive when iOS lets Sift refresh in the background, which can be late."
        #else
        "Off by default for everyone. Alerts arrive while Sift is running."
        #endif
    }

    private var resolvedLabels: [String] {
        let inbox = model.special?.inbox
        let ordered = model.labels.map(\.id).filter(labels.contains)
        return ordered == [inbox].compactMap { $0 } ? [] : ordered
    }

    private var hasChanges: Bool {
        guard let rule else { return draft.status != .unknown || draft.notify || draft.badge }
        return rule.status != draft.status || rule.notify != draft.notify || rule.badge != draft.badge
            || (draft.status == .screenedIn && Set(rule.labelIds) != Set(resolvedLabels))
    }

    private func reset(from value: SenderRecord?) {
        loaded = true
        if let value {
            draft = value
        } else {
            let sample = SenderRecord(email: email)
            draft = sample
        }
        let inbox = model.special?.inbox
        labels = draft.labelIds.isEmpty ? Set([inbox].compactMap { $0 }) : Set(draft.labelIds)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        var updated = draft
        updated.name = updated.name ?? fallbackName
        updated.labelIds = draft.status == .screenedIn ? resolvedLabels : []
        if updated.status == .screenedOut {
            updated.notify = false
            updated.badge = false
        }
        updated.updatedAt = .now
        await model.save(updated, refile: refile)
        loaded = false
    }
}

/// All senders with a decision, for reviewing and undoing.
struct SendersView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: String?
    @State private var senders: [SenderRecord] = []
    @State private var filter = ""
    @State private var showSuggestions = false

    var body: some View {
        List(selection: $selection) {
            section("Screened in", status: .screenedIn)
            section("Screened out", status: .screenedOut)
        }
        .navigationTitle("Senders")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSuggestions = true
                } label: {
                    Label("Suggest Rules", systemImage: "wand.and.stars")
                }
            }
        }
        .sheet(isPresented: $showSuggestions) { RuleSuggestionsView() }
        .overlay {
            if senders.isEmpty {
                EmptyState(title: "No decisions yet", systemImage: "person.2",
                           message: "Senders you screen in or out appear here. Tap the wand to learn rules from mail you've already filed.")
            }
        }
        .task {
            guard let store = model.store else { return }
            do {
                for try await value in store.observe(.senders) { senders = value }
            } catch {}
        }
    }

    @ViewBuilder
    private func section(_ title: String, status: SenderRecord.Status) -> some View {
        let matching = senders.filter { $0.status == status }
        if !matching.isEmpty {
            Section(title) {
                ForEach(matching) { sender in
                    HStack(spacing: 10) {
                        Avatar(name: sender.name ?? sender.email, email: sender.email, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sender.name ?? sender.email).lineLimit(1)
                            Text(detail(for: sender)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if sender.notify { Image(systemName: "bell.fill").foregroundStyle(.secondary) }
                        if sender.badge { Image(systemName: "app.badge").foregroundStyle(.secondary) }
                    }
                    .tag(sender.email)
                }
            }
        }
    }

    private func detail(for sender: SenderRecord) -> String {
        guard sender.status == .screenedIn else { return sender.email }
        let names = sender.labelIds.map { model.name(of: $0) }
        return names.isEmpty ? "Inbox" : names.joined(separator: ", ")
    }
}
