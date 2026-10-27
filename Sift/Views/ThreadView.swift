import QuickLook
import SiftKit
import SwiftUI

/// Pushed from search results on iPhone.
struct ThreadRoute: Hashable {
    let id: String
}

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @Environment(\.compose) private var compose
    @Environment(\.openWindow) private var openWindow
    let threadId: String
    /// The folder the thread was opened from; Archive removes it. Nil (search,
    /// Everything) archives out of the Inbox.
    var sourceMailbox: String?
    /// Leaves the reader after the thread is archived, trashed or marked spam.
    var onClose: () -> Void = {}
    /// In its own window: titled with the subject, and the menu bar acts on it.
    var isWindow = false
    @State private var live = LiveQuery<[MessageRecord]>()
    @State private var expanded: Set<String> = []
    @State private var showSender: IdentifiedString?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if let spam {
                    SpamBanner(message: spam)
                }
                if let latest = messages.last, latest.isDraft {
                    Button {
                        Task { await editDraft(latest) }
                    } label: {
                        Label("Edit Draft", systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.horizontal, 20)
                }
                if let latest = messages.last {
                    HStack(alignment: .firstTextBaseline) {
                        Text(messages.count == 1 ? "1 Message" : "\(messages.count) Messages")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        BubbleUpBadge(threadId: threadId, bubbledAt: bubbledAt)
                        Spacer()
                        LabelRow(message: latest)
                    }
                    .padding(.horizontal, 20)
                }
                ForEach(messages) { message in
                    MessageCard(
                        message: message,
                        isExpanded: expanded.contains(message.id),
                        showsSubject: message.id == messages.first?.id,
                        onToggle: { toggle(message.id) },
                        onSender: { openSender(message.fromEmail) }
                    )
                }
            }
            .padding(.vertical, 8)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .background(Color.readerBackground)
        // Mail-style: the subject lives in the message, not the bar.
        .navigationTitle(isWindow ? (messages.first?.subject ?? "") : "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        #else
        .toolbar(id: "reader") { macToolbar }
        #endif
        .modifier(PublishesSelection(selection: isWindow ? selection : nil))
        .sheet(item: $showSender) { sender in
            NavigationStack {
                SenderSettingsView(email: sender.value)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { showSender = nil }
                        }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 480)
            #endif
        }
        .onAppear { live.start(model.store, .thread(threadId), key: threadId) }
        .onChange(of: live.value) { old, new in
            // The conversation went away (a draft saved as a new version, or deleted elsewhere).
            if let old, !old.isEmpty, new?.isEmpty == true {
                onClose()
                return
            }
            guard let new, let last = new.last else { return }
            if let old {
                // Open messages that arrive while you're reading the thread.
                let known = Set(old.map(\.id))
                expanded.formUnion(new.map(\.id).filter { !known.contains($0) })
            } else {
                // Open the newest message plus anything unread.
                expanded = Set(new.filter(\.isUnread).map(\.id)).union([last.id])
            }
        }
    }

    /// The conversation, without Bubble Up notes (they only move it to the top).
    private var messages: [MessageRecord] { (live.value ?? []).filter { !$0.isBubble } }

    /// The newest message in Spam, if any.
    private var spam: MessageRecord? {
        guard let junk = model.special?.junk else { return nil }
        return messages.last { $0.mailboxIds.contains(junk) }
    }

    /// When the conversation last bubbled up, if that's its newest activity.
    private var bubbledAt: Date? {
        let notes = (live.value ?? []).filter(\.isBubble).map(\.receivedAt)
        guard let newest = notes.max(), newest > (messages.last?.receivedAt ?? .distantPast) else { return nil }
        return newest
    }

    /// What the menu bar acts on when this is its own window.
    private var selection: MailSelection {
        let item = messages.last.map { ConversationItem(id: threadId, latest: $0, isUnread: messages.contains(where: \.isUnread)) }
        return MailSelection(item.map { [$0] } ?? [], mailboxId: sourceMailbox, undoManager: undoManager)
    }

    #if os(iOS)
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if let latest = messages.last {
            // Mail-style: actions sit at the bottom, within thumb reach.
            ToolbarItemGroup(placement: .bottomBar) {
                archiveButton
                folderMenu
                bubbleUpMenu
                replyButton(latest)
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            ToolbarItem(placement: .bottomBar) { moreMenu(latest) }
        }
    }
    #else
    /// View ▸ Customize Toolbar… can add Reply All, Forward, Spam, Unread and Pin.
    /// Two groups: SwiftUI takes at most ten toolbar items in one block.
    @ToolbarContentBuilder private var macToolbar: some CustomizableToolbarContent {
        respondItems
        organizeItems
    }

    @ToolbarContentBuilder private var respondItems: some CustomizableToolbarContent {
        ToolbarItem(id: "reply", placement: .primaryAction) {
            Button("Reply", systemImage: "arrowshape.turn.up.left") { reply() }
                .help("Reply (⌘R)")
                .disabled(messages.isEmpty)
        }
        ToolbarItem(id: "replyAll", placement: .primaryAction, showsByDefault: false) {
            Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { reply(all: true) }
                .help("Reply All (⇧⌘R)")
                .disabled(messages.isEmpty)
        }
        ToolbarItem(id: "forward", placement: .primaryAction, showsByDefault: false) {
            Button("Forward", systemImage: "arrowshape.turn.up.right") { forward() }
                .help("Forward (⇧⌘F)")
                .disabled(messages.isEmpty)
        }
        ToolbarItem(id: "archive", placement: .primaryAction) {
            archiveButton.help("Archive (⌃⌘A)").disabled(messages.isEmpty)
        }
    }

    @ToolbarContentBuilder private var organizeItems: some CustomizableToolbarContent {
        ToolbarItem(id: "bubbleUp", placement: .primaryAction) {
            bubbleUpMenu.help("Bubble Up: bring this back to the top later").disabled(messages.isEmpty)
        }
        ToolbarItem(id: "folders", placement: .primaryAction) {
            folderMenu.help("File in folders").disabled(messages.isEmpty)
        }
        ToolbarItem(id: "junk", placement: .primaryAction, showsByDefault: false) {
            junkButton.help("Move to Spam (⇧⌘J)").disabled(messages.isEmpty)
        }
        ToolbarItem(id: "trash", placement: .primaryAction) {
            trashButton.help("Move to Trash (⌘⌫)").disabled(messages.isEmpty)
        }
        ToolbarItem(id: "unread", placement: .primaryAction, showsByDefault: false) {
            Button("Mark as Unread", systemImage: "envelope.badge") { markUnread() }
                .help("Mark as Unread (⇧⌘U)")
                .disabled(messages.isEmpty)
        }
        ToolbarItem(id: "pin", placement: .primaryAction, showsByDefault: false) {
            Button("Pin", systemImage: "pin") { togglePin() }
                .help("Pin (⇧⌘L)")
                .disabled(messages.isEmpty)
        }
        ToolbarItem(id: "sender", placement: .primaryAction, showsByDefault: false) {
            Button("Sender Settings", systemImage: "person.crop.circle") { openSender() }
                .help("Sender Settings (⌥⌘I)")
                .disabled(messages.isEmpty)
        }
    }
    #endif

    private var archiveButton: some View {
        Button("Archive", systemImage: "archivebox") {
            let source = sourceMailbox, undo = undoManager
            onClose()
            Task { await model.archive(threads: [threadId], from: source, undo: undo) }
        }
    }

    private var junkButton: some View {
        Button("Move to Spam", systemImage: "xmark.bin") {
            let undo = undoManager
            onClose()
            Task { await model.junk(threads: [threadId], undo: undo) }
        }
    }

    private var trashButton: some View {
        Button("Move to Trash", systemImage: "trash", role: .destructive) {
            let undo = undoManager
            onClose()
            Task { await model.trash(threads: [threadId], undo: undo) }
        }
    }

    private var bubbleUpMenu: some View {
        BubbleUpMenu(threadId: threadId) {
            Label("Bubble Up", systemImage: AppModel.bubbleUpSymbol)
        }
    }

    private var folderMenu: some View {
        FolderMenu(
            initial: currentFolders,
            applyTitle: { count in count == 1 ? "Move to 1 Folder" : "File in \(count) Folders" },
            onApply: { folders in
                let undo = undoManager
                Task { await model.refile(threads: [threadId], to: folders, undo: undo) }
            }
        ) {
            Label("Folders", systemImage: "folder")
        }
    }

    private func replyButton(_ latest: MessageRecord) -> some View {
        Button("Reply", systemImage: "arrowshape.turn.up.left") { reply() }
    }

    private func reply(all: Bool = false) {
        if let latest = messages.last { compose(ComposeRequest(replyTo: latest, replyAll: all)) }
    }

    private func forward() {
        if let latest = messages.last { compose(ComposeRequest(forward: latest)) }
    }

    private func markUnread() {
        let id = threadId
        Task { await model.markThread(id, read: false) }
    }

    private func togglePin() {
        if let latest = messages.last { Task { await model.toggleFlag(latest) } }
    }

    /// A sheet on iPhone; its own small window on the Mac.
    private func openSender(_ email: String? = nil) {
        guard let email = email ?? messages.last?.fromEmail else { return }
        #if os(macOS)
        openWindow(id: "sender", value: email)
        #else
        showSender = IdentifiedString(value: email)
        #endif
    }

    private func moreMenu(_ latest: MessageRecord) -> some View {
        Menu {
            Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { reply(all: true) }
            Button("Forward", systemImage: "arrowshape.turn.up.right") { forward() }
            Divider()
            Button("Mark as Unread", systemImage: "envelope.badge") { markUnread() }
            Button(latest.isFlagged ? "Unpin" : "Pin", systemImage: "pin") { togglePin() }
            Button("Sender Settings…", systemImage: "person.crop.circle") { openSender() }
            Divider()
            junkButton
            trashButton
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    /// The conversation's folders (Inbox and your own labels).
    private var currentFolders: Set<String> {
        let folders = Set(model.labels.map(\.id))
        return Set(messages.flatMap(\.mailboxIds)).intersection(folders)
    }

    /// Opens a saved draft in compose, where it's saved again (as a new version) or sent.
    private func editDraft(_ message: MessageRecord) async {
        if let draft = await model.openDraft(message.id) { compose(ComposeRequest(draft: draft)) }
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
}

/// Publishes the reader's conversation to the menu bar, only in its own window
/// (in the main window the list's selection is what the menus act on).
private struct PublishesSelection: ViewModifier {
    let selection: MailSelection?

    func body(content: Content) -> some View {
        if let selection {
            content.focusedSceneValue(\.mailSelection, selection)
        } else {
            content
        }
    }
}

struct IdentifiedString: Identifiable {
    var value: String
    var id: String { value }
}

/// Shown above a conversation in Spam. "Not Spam" screens the sender in and
/// takes their mail out, to where they're screened in to or to folders you pick.
private struct SpamBanner: View {
    @Environment(AppModel.self) private var model
    let message: MessageRecord
    @State private var isWorking = false

    var body: some View {
        // Side by side when there's room (the Mac), otherwise stacked.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                explanation
                Spacer(minLength: 8)
                button
            }
            VStack(alignment: .trailing, spacing: 10) {
                explanation.frame(maxWidth: .infinity, alignment: .leading)
                button
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 20)
    }

    private var explanation: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("Fastmail put this in Spam")
                    .font(.subheadline.weight(.semibold))
                Text("If it isn't, Sift screens the sender in and keeps their mail out of Spam.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "xmark.bin")
                .foregroundStyle(.secondary)
        }
    }

    private var button: some View {
        HStack(spacing: 8) {
            if isWorking { ProgressView().controlSize(.small) }
            ScreenInButton(
                title: "Not Spam",
                applyTitle: { count in count == 1 ? "Move to 1 Folder" : "Move to \(count) Folders" },
                onPrimary: { await decide(nil) },
                onScreenIn: { folders in await decide(folders) }
            )
            .disabled(isWorking)
        }
    }

    private func decide(_ folders: Set<String>?) async {
        isWorking = true
        defer { isWorking = false }
        await model.notSpam(message, folders: folders)
    }
}

/// Which labels the conversation is in.
private struct LabelRow: View {
    @Environment(AppModel.self) private var model
    let message: MessageRecord

    var body: some View {
        let ids = message.mailboxIds.filter { model.mailbox($0) != nil }
        if !ids.isEmpty {
            HStack(spacing: 6) {
                ForEach(ids, id: \.self) { id in
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
    }
}

/// One message, Mail-style: a full-width panel with the sender, a To: line
/// (tap for addresses), the subject on the first message, then the body.
struct MessageCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage("loadRemoteImages") private var loadRemoteImages = true
    let message: MessageRecord
    var isExpanded: Bool
    var showsSubject = true
    var onToggle: () -> Void = {}
    var onSender: () -> Void = {}

    @State private var body_: BodyRecord?
    @State private var prepared: MessageHTML.Prepared?
    @State private var loadError: String?
    @State private var allowRemoteOnce = false
    @State private var showTrackers = false
    @State private var showAddresses = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(16)
            if showsSubject {
                Divider().padding(.leading, 16)
                Text(message.subject.isEmpty ? "(no subject)" : message.subject)
                    .font(.title2.weight(.bold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, isExpanded ? 6 : 16)
            }
            if isExpanded {
                content
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 18)
            }
        }
        .background(Color.readerPanel, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .task(id: isExpanded) {
            guard isExpanded, prepared == nil else { return }
            do {
                let body = try await model.body(for: message)
                body_ = body
                prepared = await Task.detached { MessageHTML.prepare(body) }.value
                // Read as soon as it's on screen. A separate task, so leaving the
                // view or a navigation transition can't cancel the request.
                if message.isUnread {
                    let shown = message
                    Task { await model.markRead([shown]) }
                }
            } catch {
                loadError = "Couldn't load this message. \(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let prepared {
            let sanitized = prepared.sanitized
            VStack(alignment: .leading, spacing: 12) {
                if !allowsRemote, sanitized.remoteImageCount > 0 {
                    Button("Load \(sanitized.remoteImageCount) remote image\(sanitized.remoteImageCount == 1 ? "" : "s")") {
                        allowRemoteOnce = true
                    }
                    .font(.caption)
                }
                MessageWebView(html: sanitized.html, allowRemote: allowsRemote)
                if let attachments = body_?.attachments, !attachments.isEmpty {
                    AttachmentList(parts: attachments)
                }
            }
        } else if let loadError {
            Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.secondary)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
        }
    }

    private var allowsRemote: Bool { loadRemoteImages || allowRemoteOnce }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button(action: onSender) {
                Avatar(name: message.senderDisplayName, email: message.fromEmail, size: 44)
            }
            .buttonStyle(.plain)
            .help("Sender settings")
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(message.senderDisplayName).font(.headline).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(message.receivedAt.listLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                    if isExpanded, let trackers = prepared?.sanitized.trackers, !trackers.isEmpty {
                        Button {
                            showTrackers = true
                        } label: {
                            Image(systemName: "eye.slash")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.orange)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Spy pixels blocked")
                        .popover(isPresented: $showTrackers) {
                            TrackerDetails(trackers: trackers)
                                .presentationCompactAdaptation(.popover)
                        }
                    }
                }
                if isExpanded {
                    Button {
                        withAnimation(.snappy) { showAddresses.toggle() }
                    } label: {
                        HStack(spacing: 3) {
                            Text("To: \(recipientNames)").lineLimit(1)
                            Image(systemName: showAddresses ? "chevron.down" : "chevron.right")
                                .font(.caption2.weight(.semibold))
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    if showAddresses { addresses }
                } else {
                    Text(message.preview).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
    }

    private var recipientNames: String {
        let names = (message.to + message.cc).map(\.displayName)
        return names.isEmpty ? "(no recipients)" : names.formatted(.list(type: .and))
    }

    /// The full addresses, revealed from the To: line.
    private var addresses: some View {
        VStack(alignment: .leading, spacing: 4) {
            addressLine("From", [message.sender])
            addressLine("To", message.to)
            if !message.cc.isEmpty { addressLine("Cc", message.cc) }
            if !message.replyTo.isEmpty, message.replyTo.map(\.normalized) != [message.fromEmail] {
                addressLine("Reply-To", message.replyTo)
            }
            Text(message.receivedAt.formatted(date: .complete, time: .shortened))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .padding(.top, 4)
    }

    private func addressLine(_ label: String, _ list: [EmailAddress]) -> some View {
        Text("\(Text(label + ":").fontWeight(.semibold)) \(list.map { ComposeDraft.format($0) }.joined(separator: ", "))")
    }
}

/// What the eye-slash icon reveals: which trackers were removed and why.
struct TrackerDetails: View {
    let trackers: [DetectedTracker]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Spy pixel\(trackers.count == 1 ? "" : "s") blocked", systemImage: "eye.slash.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("Sift removed \(trackers.count == 1 ? "a tracking image" : "\(trackers.count) tracking images") that would have told the sender when, where and how often you opened this.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(trackers, id: \.url) { tracker in
                VStack(alignment: .leading, spacing: 2) {
                    Text(tracker.name).font(.subheadline.weight(.semibold))
                    Text(tracker.reason.explanation.capitalizedFirst).font(.caption).foregroundStyle(.secondary)
                    Text(tracker.url)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
        }
        .padding()
        .frame(width: 320, alignment: .leading)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

extension DetectedTracker.Reason {
    var explanation: String {
        switch self {
        case .knownService: "known tracking service"
        case .tinyImage: "invisible 1×1 image"
        case .hiddenImage: "hidden image"
        case .beaconPath: "tracking beacon URL"
        }
    }
}

struct AttachmentList: View {
    @Environment(AppModel.self) private var model
    let parts: [EmailBodyPart]
    @State private var downloading: String?
    @State private var preview: URL?

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(parts, id: \.self) { part in
                Button {
                    Task { await open(part) }
                } label: {
                    HStack(spacing: 6) {
                        if downloading == part.blobId {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "paperclip")
                        }
                        Text(part.name ?? "Attachment").lineLimit(1)
                        if let size = part.size {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .quickLookPreview($preview)
    }

    private func open(_ part: EmailBodyPart) async {
        guard let blobId = part.blobId, let engine = model.engine else { return }
        downloading = blobId
        defer { downloading = nil }
        do {
            let name = part.name ?? "attachment"
            let data = try await engine.download(blobId: blobId, name: name, type: part.type ?? "application/octet-stream")
            let folder = FileManager.default.temporaryDirectory.appending(path: blobId, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appending(path: name)
            try data.write(to: url)
            preview = url
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

