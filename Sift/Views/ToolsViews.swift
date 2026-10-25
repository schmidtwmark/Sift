import SiftKit
import SwiftUI

/// Screening rules inferred from where you already file each sender's mail.
struct RuleSuggestionsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var suggestions: [RuleSuggestion]?
    @State private var selected: Set<String> = []
    @State private var loadError: String?
    @State private var isSaving = false

    private struct Group: Identifiable {
        var id: String
        var title: String
        var items: [RuleSuggestion]
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Suggested Rules")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(selected.isEmpty ? "Save" : "Save \(selected.count)") { Task { await save() } }
                            .disabled(selected.isEmpty || isSaving)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if let loadError {
            ContentUnavailableView("Couldn't look at your mail", systemImage: "exclamationmark.triangle", description: Text(loadError))
        } else if let suggestions {
            if suggestions.isEmpty {
                ContentUnavailableView("Nothing to suggest", systemImage: "wand.and.stars",
                                       description: Text("Every sender you've filed already has a screening rule."))
            } else {
                List {
                    Section {
                        Text("Based on where you've already filed each sender's mail. Saved rules sort new mail and keep these senders out of the Screener; existing mail isn't moved.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } footer: {
                        let ignored = model.labels.filter { model.unsortedFolderIds.contains($0.id) }.map(\.name)
                        if !ignored.isEmpty {
                            Text("Ignoring \(ignored.formatted(.list(type: .and))), which isn't sorted yet.")
                        }
                    }
                    ForEach(groups(suggestions)) { group in
                        Section {
                            ForEach(group.items) { suggestion in
                                Toggle(isOn: binding(for: suggestion.email)) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(suggestion.name ?? suggestion.email).lineLimit(1)
                                        Text("\(suggestion.email) · \(suggestion.evidence) message\(suggestion.evidence == 1 ? "" : "s")")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                Text("\(group.title) · \(group.items.count)")
                                Spacer()
                                let ids = Set(group.items.map(\.email))
                                Button(ids.isSubset(of: selected) ? "None" : "All") {
                                    if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
                                }
                                .font(.caption.weight(.semibold))
                                .textCase(nil)
                            }
                        }
                    }
                }
            }
        } else {
            ProgressView("Looking at how you file mail…")
        }
    }

    private func groups(_ suggestions: [RuleSuggestion]) -> [Group] {
        var byKey: [String: Group] = [:]
        for suggestion in suggestions {
            let key: String
            let title: String
            if suggestion.status == .screenedOut {
                (key, title) = ("out", "Screen Out")
            } else if suggestion.labelIds.isEmpty {
                (key, title) = ("inbox", "Inbox")
            } else {
                key = suggestion.labelIds.joined(separator: "+")
                title = suggestion.labelIds.map { model.name(of: $0) }.formatted(.list(type: .and))
            }
            byKey[key, default: Group(id: key, title: title, items: [])].items.append(suggestion)
        }
        return byKey.values.sorted { $0.items.count > $1.items.count }
    }

    private func binding(for email: String) -> Binding<Bool> {
        Binding(
            get: { selected.contains(email) },
            set: { isOn in if isOn { selected.insert(email) } else { selected.remove(email) } }
        )
    }

    private func load() async {
        do {
            let found = try await model.suggestRules()
            suggestions = found
            selected = Set(found.map(\.email))
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func save() async {
        guard let suggestions else { return }
        isSaving = true
        defer { isSaving = false }
        if await model.apply(suggestions.filter { selected.contains($0.email) }) { dismiss() }
    }
}

/// Files everything in one folder (e.g. an import from HEY) into your other
/// folders, using screening rules and where each sender's mail already lives.
struct FolderSortView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var initialFolder: String?

    private enum Stage {
        case choosing, scanning, preview(SyncEngine.FolderSortPlan), moving, finished(moved: Int)
    }

    @State private var folderId: String?
    @State private var stage: Stage = .choosing
    @State private var progress = ProgressTracker()
    @State private var errorText: String?
    @State private var confirmMove = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Form { content }
                .formStyle(.grouped)
                .navigationTitle("Sort a Folder")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(isBusy ? "Close" : "Done") { dismiss() }
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 480)
        #endif
        .interactiveDismissDisabled(isBusy)
        .onAppear {
            if folderId == nil {
                folderId = initialFolder ?? model.unsortedFolderIds.first ?? sortableFolders.first?.id
            }
        }
    }

    private var isBusy: Bool {
        switch stage {
        case .scanning, .moving: true
        default: false
        }
    }

    private var sortableFolders: [MailboxRecord] {
        model.labels.filter { $0.id != model.special?.inbox }
    }

    private var folderName: String { folderId.map { model.name(of: $0) } ?? "folder" }

    @ViewBuilder private var content: some View {
        switch stage {
        case .choosing:
            Section {
                Picker("Folder", selection: $folderId) {
                    ForEach(sortableFolders) { folder in
                        Text("\(folder.name) (\(folder.totalEmails))").tag(Optional(folder.id))
                    }
                }
            } footer: {
                Text("Sift reads every message in the folder and works out where each belongs: the sender's screening rule first, then wherever you've filed that sender's other mail. Your own messages go to Sent. Anything else goes to the Inbox. Nothing moves until you confirm.")
            }
            if let errorText { Section { Label(errorText, systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
            Section {
                Button("Scan “\(folderName)”") { Task { await scan() } }
                    .disabled(folderId == nil)
            }

        case .scanning:
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(progress.total == 0 ? "Finding messages…" : "Reading \(progress.done.formatted()) of \(progress.total.formatted())…")
                    ProgressView(value: progress.fraction)
                }
            }

        case .preview(let plan):
            Section {
                ForEach(plan.buckets) { bucket in
                    DisclosureGroup {
                        ForEach(SortSenderGroup.groups(in: bucket)) { group in
                            SortSenderRow(group: group, destination: bucket.destination)
                        }
                    } label: {
                        LabeledContent {
                            Text(bucket.items.count.formatted())
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(title(for: bucket.destination))
                                    Text("from \(bucket.senders.count.formatted()) sender\(bucket.senders.count == 1 ? "" : "s")")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: bucket.destination.first.map(model.icon(for:)) ?? "arrow.uturn.backward")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } header: {
                Text("Where \(plan.total.formatted()) messages will go")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Open a destination to see who's going there and why, then a sender to see their messages.")
                    if !plan.ownAddresses.isEmpty {
                        Text("Mail from \(plan.ownAddresses.formatted(.list(type: .or))) counts as yours and goes to Sent.")
                    }
                }
            }
            Section {
                Button("Move \(plan.total.formatted()) Messages") { confirmMove = true }
                    .disabled(plan.total == 0)
                    .confirmationDialog("Move \(plan.total.formatted()) messages out of “\(folderName)”?",
                                        isPresented: $confirmMove, titleVisibility: .visible) {
                        Button("Move Messages") { Task { await move(plan) } }
                    } message: {
                        Text("They'll be filed as shown. This changes your mail in Fastmail too.")
                    }
                Button("Start Over") { stage = .choosing }
            }

        case .moving:
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Moved \(progress.done.formatted()) of \(progress.total.formatted())…")
                    ProgressView(value: progress.fraction)
                }
            } footer: {
                Text("Keep Sift open until this finishes.")
            }

        case .finished(let moved):
            Section {
                Label("Moved \(moved.formatted()) messages out of “\(folderName)”.", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
            if let folder = folderId.flatMap(model.mailbox), folder.totalEmails == 0 {
                Section {
                    Button("Delete “\(folder.name)”", role: .destructive) { confirmDelete = true }
                        .confirmationDialog("Delete the empty folder “\(folder.name)” from Fastmail?",
                                            isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("Delete Folder", role: .destructive) {
                                Task { if await model.deleteFolder(folder.id) { dismiss() } }
                            }
                        }
                } footer: {
                    Text("It's empty now. Fastmail won't delete a folder that still has mail in it.")
                }
            } else {
                Section {
                    Text("Some mail is still in the folder (new arrivals, or messages Fastmail couldn't move). Scan again to sort it.")
                        .foregroundStyle(.secondary)
                    Button("Scan Again") { Task { await scan() } }
                }
            }
        }
    }

    private func title(for destination: [String]) -> String {
        destination.isEmpty
            ? "Already filed elsewhere (just leaves this folder)"
            : destination.map { model.name(of: $0) }.formatted(.list(type: .and))
    }

    private func scan() async {
        guard let folderId else { return }
        errorText = nil
        progress = ProgressTracker()
        stage = .scanning
        do {
            stage = .preview(try await model.planSort(of: folderId, progress: progress))
        } catch {
            errorText = error.localizedDescription
            stage = .choosing
        }
    }

    private func move(_ plan: SyncEngine.FolderSortPlan) async {
        progress = ProgressTracker()
        progress.update(0, plan.total)
        stage = .moving
        if await model.execute(plan, progress: progress) {
            stage = .finished(moved: plan.total)
        } else {
            stage = .preview(plan)
        }
    }
}

/// One sender's messages within a folder-sort destination.
private struct SortSenderGroup: Identifiable {
    typealias Item = SyncEngine.FolderSortPlan.Item

    var id: String { email }
    var email: String
    var name: String
    var items: [Item]
    /// Shared by all of the sender's messages; nil when they differ (some are
    /// already filed elsewhere), and then each message shows its own.
    var reason: SortReason?

    /// Biggest senders first.
    static func groups(in bucket: SyncEngine.FolderSortPlan.Bucket) -> [SortSenderGroup] {
        Dictionary(grouping: bucket.items, by: \.senderEmail).map { email, items in
            let reasons = Set(items.map(\.reason))
            let name = items.lazy.compactMap(\.senderName).first { !$0.isEmpty }
            return SortSenderGroup(email: email, name: name ?? (email.isEmpty ? "Unknown sender" : email),
                                   items: items, reason: reasons.count == 1 ? reasons.first : nil)
        }
        .sorted { $0.items.count != $1.items.count ? $0.items.count > $1.items.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// A sender, why their mail goes where it does, and (expanded) their messages.
private struct SortSenderRow: View {
    @Environment(AppModel.self) private var model
    let group: SortSenderGroup
    let destination: [String]

    var body: some View {
        DisclosureGroup {
            ForEach(group.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.subject.isEmpty ? "(no subject)" : item.subject)
                        .lineLimit(2)
                    Text(details(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 1)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(group.name).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(group.items.count.formatted()).foregroundStyle(.secondary)
                }
                if group.name != group.email {
                    Text(group.email)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let reason = group.reason {
                    Label(explanation(reason), systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .labelStyle(.chip)
                }
            }
        }
    }

    private func details(for item: SyncEngine.FolderSortPlan.Item) -> String {
        let date = item.receivedAt?.formatted(date: .abbreviated, time: .omitted)
        // Only spelled out per message when the sender's messages differ.
        let why = group.reason == nil ? explanation(item.reason) : nil
        return [date, why].compactMap { $0 }.joined(separator: " · ")
    }

    private func explanation(_ reason: SortReason) -> String {
        let names = destination.map { model.name(of: $0) }.formatted(.list(type: .and))
        let toInbox = model.special.map { destination == [$0.inbox] } ?? false
        func most(_ count: Int) -> String {
            count == 1 ? "Their 1 other message is" : "Most of their \(count.formatted()) other messages are"
        }
        switch reason {
        case .alreadyFiled(let folders):
            return "Already in \(folders.map { model.name(of: $0) }.formatted(.list(type: .and))), so it just leaves this folder"
        case .ownMail(let address):
            return "Sent from your address \(address)"
        case .rule(.screenedOut):
            return "You screened this sender out"
        case .rule:
            return toInbox ? "Screened in with no folder, so it goes to the Inbox" : "Their screening rule files them in \(names)"
        case .history(.screenedOut, let evidence):
            return "\(most(evidence)) in Spam, so they're screened out"
        case .history(_, let evidence):
            return toInbox ? "\(most(evidence)) in Inbox or Archive" : "\(most(evidence)) in \(names)"
        case .noHistory:
            return "No screening rule, and no other filed mail from this sender"
        }
    }
}
