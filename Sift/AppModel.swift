import Foundation
import Observation
import OSLog
import SiftKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

enum SidebarItem: Hashable {
    case screener
    case mailbox(String)
    case everything
    case senders
}

struct ComposeRequest: Identifiable {
    let id = UUID()
    var replyTo: MessageRecord?
    var replyAll = false
    var forward: MessageRecord?
    /// A mailto: link opened from another app or a web page.
    var mailto: MailtoLink?
    /// A saved draft, or a message brought back by Undo Send.
    var draft: OutgoingMessage?
}

/// App-wide state: the account connection, mailboxes, and every user action,
/// which it forwards to `SyncEngine` and turns into user-facing errors.
@Observable
final class AppModel {
    enum Phase: Equatable {
        /// `connecting` checks the token (onboarding stays up); `syncing` is the first sync.
        case launching, signedOut, connecting, syncing, ready
        case failed(String)
    }

    var phase: Phase = .launching
    private(set) var isDemo = false
    private(set) var engine: SyncEngine?
    private(set) var store: MailStore?

    var mailboxes: [MailboxRecord] = []
    /// Icons you picked for labels (mailbox id → SF Symbol), synced via Fastmail.
    private(set) var labelIcons: [String: String] = [:]
    /// Conversations set to bubble up, soonest first.
    private(set) var bubbleUps: [BubbleUp] = []
    private(set) var special: SpecialMailboxes?
    private(set) var identities: [Identity] = []
    private(set) var username = ""
    private(set) var screenerStartedAt: Date?

    /// Where a new window opens: the Screener when someone is waiting, else Inbox.
    private(set) var defaultSidebar: SidebarItem = .screener
    /// A conversation to bring up (from a notification); the main window shows it.
    var threadToOpen: String?
    var errorMessage: String?
    /// For `.alert(isPresented:)`.
    var showsError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }
    private(set) var isSyncing = false

    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    init() {
        notifier.onOpen = { [weak self] threadId in self?.threadToOpen = threadId }
    }

    // MARK: - Connection

    func launch() async {
        guard phase == .launching else { return }
        if ProcessInfo.processInfo.arguments.contains("-demo") {
            await startDemo()
        } else if let token = Keychain.token() {
            await connect(token: token, saving: false)
        } else {
            phase = .signedOut
        }
    }

    func connect(token: String, saving: Bool = true) async {
        phase = .connecting
        do {
            let client = JMAPClient(token: token)
            let session = try await client.session(refresh: true)
            // Check scopes before touching the account, so a partial token
            // fails cleanly instead of halfway through setup.
            let missing = session.missingScopes
            guard missing.isEmpty else { throw JMAPError.missingScopes(missing) }
            let store = try MailStore.onDisk(named: "Sift-\(session.username)")
            if saving { Keychain.save(token: token) }
            username = session.username
            phase = .syncing
            try await start(SyncEngine(client: client, store: store), store: store, activatedAt: nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func startDemo() async {
        phase = .syncing
        isDemo = true
        do {
            let server = DemoServer()
            // Like Fastmail: holds mail to send later (Undo Send, Bubble Up).
            server.maxDelayedSend = 90 * 86_400
            let client = JMAPClient(token: "demo", sessionURL: DemoServer.sessionURL, urlSession: server.urlSession())
            let store = try MailStore.inMemory()
            username = "you@fastmail.com (demo)"
            try await start(SyncEngine(client: client, store: store), store: store,
                            activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func start(_ engine: SyncEngine, store: MailStore, activatedAt: Date?) async throws {
        self.engine = engine
        self.store = store
        await engine.onNewMail { [weak self] messages in
            await self?.handleNewMail(messages)
        }
        isSyncing = true
        defer { isSyncing = false }
        try await engine.start(activatedAt: activatedAt)
        special = await engine.mailboxes
        identities = await engine.identities
        if let raw = try await store.value(for: "screener.activatedAt") {
            screenerStartedAt = JMAPCoding.parseDate(raw)
        }
        // Open on the Screener only when someone is waiting there.
        if let special, try await store.messages(in: special.screener).isEmpty {
            defaultSidebar = .mailbox(special.inbox)
        }
        phase = .ready
        observe()
        tasks.append(Task { [engine] in await engine.listen() })
    }

    func signOut() {
        tasks.forEach { $0.cancel() }
        tasks = []
        if !isDemo { Keychain.deleteToken() }
        engine = nil
        store = nil
        mailboxes = []
        labelIcons = [:]
        special = nil
        isDemo = false
        defaultSidebar = .screener
        phase = .signedOut
    }

    private func observe() {
        guard let store else { return }
        tasks.append(Task { [weak self] in
            do {
                for try await icons in store.observe(.labelIcons) {
                    self?.labelIcons = icons
                }
            } catch {}
        })
        tasks.append(Task { [weak self] in
            do {
                for try await bubbles in store.observe(.bubbleUps) {
                    self?.bubbleUps = bubbles
                }
            } catch {}
        })
        tasks.append(Task { [weak self] in
            do {
                for try await boxes in store.observe(.mailboxes) {
                    self?.mailboxes = boxes
                }
            } catch {}
        })
        if let quarantined = special?.quarantined {
            tasks.append(Task { [weak self] in
                do {
                    for try await count in store.observe(.badgeCount(excluding: quarantined)) {
                        self?.notifier.setBadge(count)
                    }
                } catch {}
            })
        }
    }

    enum RefreshTrigger {
        /// Pull to refresh, Get New Mail: say so if it fails.
        case user
        /// Coming to the front, or iOS's background refresh. Nobody's waiting
        /// on it, so a flaky network shouldn't interrupt with an alert.
        case automatic
    }

    @ObservationIgnored private let syncLog = Logger(subsystem: "com.markschmidt.Sift", category: "sync")

    func refresh(_ trigger: RefreshTrigger = .user) async {
        guard let engine, phase == .ready, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        // Syncing is safe to repeat, so a network hiccup gets one quiet retry.
        for attempt in 1...2 {
            do {
                try await engine.refresh()
                return
            } catch is CancellationError {
                return
            } catch where error.isTransientNetworkFailure {
                syncLog.notice("Sync attempt \(attempt) couldn't reach Fastmail: \(error.localizedDescription, privacy: .public)")
                guard attempt == 1, (try? await Task.sleep(for: .seconds(3))) != nil else { break }
            } catch {
                syncLog.error("Sync failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
                return
            }
        }
        // Still unreachable: the next sync (or a push from Fastmail) catches up.
        if trigger == .user { show(Toast(message: "Couldn't reach Fastmail. Try again in a moment.")) }
    }

    // MARK: - Mailboxes

    /// User-facing labels (Fastmail mailboxes without a system role), plus Inbox first.
    var labels: [MailboxRecord] {
        guard let special else { return [] }
        let inbox = mailboxes.filter { $0.id == special.inbox }
        let custom = mailboxes.filter { $0.role == nil && $0.id != special.screener && $0.id != special.screenedOut }
        return inbox + custom
    }

    func mailbox(_ id: String) -> MailboxRecord? { mailboxes.first { $0.id == id } }

    func name(of mailboxId: String) -> String { mailbox(mailboxId)?.name ?? "Label" }

    /// The symbol for any mailbox: fixed ones for system folders; for labels,
    /// your pick, or a guess from the name.
    func icon(for mailboxId: String) -> String {
        if let special {
            let system: [(String?, String)] = [
                (special.inbox, "tray"), (special.screener, "person.crop.circle.badge.questionmark"),
                (special.screenedOut, "hand.raised"), (special.archive, "archivebox"), (special.sent, "paperplane"),
                (special.drafts, "doc"), (special.junk, "xmark.bin"), (special.trash, "trash"),
            ]
            if let icon = system.first(where: { $0.0 == mailboxId })?.1 { return icon }
        }
        return labelIcons[mailboxId] ?? LabelIcon.suggested(for: name(of: mailboxId))
    }

    func setIcon(_ symbol: String?, for mailboxId: String) async {
        guard let engine else { return }
        await perform { try await engine.setLabelIcon(symbol, for: mailboxId) }
    }

    /// Puts your folders in this order everywhere: the sidebar, folder menus,
    /// your other devices and Fastmail itself.
    func reorderFolders(_ ids: [String]) async {
        guard let engine else { return }
        // Move them in place now, so the list doesn't snap back while Fastmail answers.
        let byId = Dictionary(mailboxes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let slots = mailboxes.indices.filter { ids.contains(mailboxes[$0].id) }
        var reordered = mailboxes
        for (slot, id) in zip(slots, ids) { if let box = byId[id] { reordered[slot] = box } }
        mailboxes = reordered
        await perform { try await engine.reorderMailboxes(ids) }
    }

    func createLabel(named name: String) async -> String? {
        guard let engine else { return nil }
        var id: String?
        await perform { id = try await engine.createMailbox(named: name) }
        return id
    }

    // MARK: - Screener

    func screenIn(_ entry: ScreenerEntry, labels: Set<String>) async {
        guard let engine else { return }
        let ordered = self.labels.map(\.id).filter(labels.contains)
        await perform { try await engine.screenIn(entry.email, name: entry.name, labels: ordered) }
    }

    /// Screens the sender in and takes all their mail out of Spam: into
    /// `folders`, or else wherever they're already screened in to (the Inbox
    /// if nowhere). Their later mail comes out of Spam on its own.
    func notSpam(_ message: MessageRecord, folders: Set<String>? = nil) async {
        guard let engine else { return }
        let sender = message.fromEmail
        let labels: [String]
        if let folders {
            labels = self.labels.map(\.id).filter(folders.contains)
        } else if let rule = try? await store?.read(.sender(sender)), rule.status == .screenedIn {
            labels = rule.labelIds
        } else {
            labels = []
        }
        await perform { try await engine.screenIn(sender, name: message.fromName, labels: labels) }
        guard errorMessage == nil else { return }
        let names = self.labels.filter { labels.contains($0.id) }.map(\.name)
        show(Toast(message: "Moved to \(names.isEmpty ? "Inbox" : names.formatted(.list(type: .and))). "
                   + "Sift will take \(message.fromName ?? sender)'s mail out of Spam from now on."))
    }

    func screenOut(_ entry: ScreenerEntry) async {
        guard let engine else { return }
        await perform { try await engine.screenOut(entry.email, name: entry.name) }
    }

    func save(_ rule: SenderRecord, refile: Bool) async {
        guard let engine else { return }
        if rule.notify || rule.badge { await notifier.requestAuthorization() }
        await perform { try await engine.updateRule(rule, refile: refile) }
    }

    // MARK: - Message actions

    func markRead(_ messages: [MessageRecord], read: Bool = true) async {
        let ids = messages.filter { $0.isUnread == read }.map(\.id)
        guard let engine, !ids.isEmpty else { return }
        await perform { try await engine.setKeyword(Keyword.seen, read, for: ids) }
    }

    /// Read marks every message in the conversation; unread marks just the newest.
    func markThreads(_ threadIds: [String], read: Bool) async {
        var targets: [MessageRecord] = []
        for id in threadIds {
            let thread = await messages(inThreads: [id])
            targets += read ? thread : Array(thread.suffix(1))
        }
        await markRead(targets, read: read)
    }

    func markThread(_ threadId: String, read: Bool) async {
        await markThreads([threadId], read: read)
    }

    func toggleFlag(_ message: MessageRecord) async {
        guard let engine else { return }
        await perform { try await engine.setKeyword(Keyword.flagged, !message.isFlagged, for: [message.id]) }
    }

    func setPinned(_ threadIds: [String], _ pinned: Bool) async {
        guard let engine else { return }
        var latest: [String] = []
        for id in threadIds { if let last = await messages(inThreads: [id]).last { latest.append(last.id) } }
        await perform { try await engine.setKeyword(Keyword.flagged, pinned, for: latest) }
    }

    /// Every message in the given conversations, oldest first.
    func messages(inThreads threadIds: [String]) async -> [MessageRecord] {
        guard let store else { return [] }
        var all: [MessageRecord] = []
        for id in threadIds { all += (try? await store.read(.thread(id))) ?? [] }
        return all
    }

    // Conversation-level moves: every message in the thread goes, not just the newest.

    func archive(threads: [String], from mailboxId: String?, undo: UndoManager? = nil) async {
        await archive(await messages(inThreads: threads).map(\.id), from: mailboxId, undo: undo)
    }

    func trash(threads: [String], undo: UndoManager? = nil) async {
        await trash(await messages(inThreads: threads).map(\.id), undo: undo)
    }

    func junk(threads: [String], undo: UndoManager? = nil) async {
        await junk(await messages(inThreads: threads).map(\.id), undo: undo)
    }

    /// Removes `mailboxId` (the folder the user is looking at; Inbox when nil).
    func archive(_ ids: [String], from mailboxId: String?, undo: UndoManager? = nil) async {
        guard let engine else { return }
        await move(Move(name: "Archive", done: "Archived", undo: undo) { try await engine.archive(ids, from: mailboxId) })
    }

    func trash(_ ids: [String], undo: UndoManager? = nil) async {
        guard let engine else { return }
        await move(Move(name: "Move to Trash", done: "Moved to Trash", undo: undo) { try await engine.moveToTrash(ids) })
    }

    func junk(_ ids: [String], undo: UndoManager? = nil) async {
        guard let engine else { return }
        await move(Move(name: "Move to Spam", done: "Moved to Spam", undo: undo) { try await engine.moveToJunk(ids) })
    }

    /// Files whole conversations into exactly `folders` (Inbox and your labels;
    /// your own sent copies stay in Sent).
    func refile(threads: [String], to folders: Set<String>, undo: UndoManager? = nil) async {
        guard let engine else { return }
        let all = Set(labels.map(\.id))
        let sent = special?.sent
        let messages = await messages(inThreads: threads).filter { !(sent.map($0.mailboxIds.contains) ?? false) }
        let names = labels.filter { folders.contains($0.id) }.map(\.name).formatted(.list(type: .and))
        await move(Move(name: "Move", done: "Moved to \(names)", undo: undo) {
            var placement: SyncEngine.Placement = [:]
            for message in messages {
                let current = Set(message.mailboxIds).intersection(all)
                let add = folders.subtracting(current), remove = current.subtracting(folders)
                guard !add.isEmpty || !remove.isEmpty else { continue }
                try await engine.relabel([message.id], add: Array(add), remove: Array(remove))
                placement[message.id] = message.mailboxIds
            }
            return placement
        })
    }

    /// A drop onto a sidebar folder: Mail-style move out of the folder being viewed.
    func move(threads: [String], from source: String?, to target: String, undo: UndoManager? = nil) async {
        guard let engine, let special, target != source else { return }
        if target == special.trash { return await trash(threads: threads, undo: undo) }
        if target == special.junk { return await junk(threads: threads, undo: undo) }
        let sent = special.sent
        let ids = await messages(inThreads: threads).filter { !(sent.map($0.mailboxIds.contains) ?? false) }.map(\.id)
        // From a folder: out of that folder. From Everything or search: out of
        // wherever it is now (bar Sent and Drafts), so it ends up only in `target`.
        let remove: [String] = source.map { [$0, special.screener] }
            ?? mailboxes.map(\.id).filter { $0 != special.sent && $0 != special.drafts }
        await move(Move(name: "Move", done: "Moved to \(name(of: target))", undo: undo) {
            let before = Dictionary(uniqueKeysWithValues: (try await self.store?.messages(ids: ids) ?? []).map { ($0.id, $0.mailboxIds) })
            try await engine.relabel(ids, add: [target], remove: remove.filter { $0 != target })
            return before
        })
    }

    /// A reversible move: what to call it in the Edit menu and the toast, and the work itself.
    struct Move {
        var name: String
        var done: String
        var undo: UndoManager?
        var work: () async throws -> SyncEngine.Placement
    }

    /// Runs a move, registers it with the window's Undo (as “Undo Archive” and
    /// so on) and confirms it with a toast that can undo it too.
    private func move(_ move: Move) async {
        var placement: SyncEngine.Placement = [:]
        await perform { placement = try await move.work() }
        guard !placement.isEmpty else { return }
        if let undoManager = move.undo {
            undoManager.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated {
                    // Registered while undoing, so it becomes Redo.
                    undoManager.registerUndo(withTarget: model) { model in
                        MainActor.assumeIsolated { _ = Task { await model.move(move) } }
                    }
                    undoManager.setActionName(move.name)
                    Task { await model.restore(placement) }
                }
            }
            undoManager.setActionName(move.name)
        }
        show(Toast(message: move.done) { [weak self] in
            if let undoManager = move.undo, undoManager.canUndo, undoManager.undoActionName == move.name {
                undoManager.undo()
            } else {
                await self?.restore(placement)
            }
        })
    }

    private func restore(_ placement: SyncEngine.Placement) async {
        guard let engine else { return }
        await perform { try await engine.restore(placement) }
    }

    // MARK: - Learning from existing mail

    /// Folders whose contents say nothing about where mail belongs yet
    /// (an unsorted import from another provider).
    var unsortedFolderIds: Set<String> {
        Set(labels.filter { $0.name.localizedCaseInsensitiveContains("import") }.map(\.id))
    }

    func suggestRules() async throws -> [RuleSuggestion] {
        guard let engine else { return [] }
        return try await engine.suggestRules(ignoring: unsortedFolderIds)
    }

    func apply(_ suggestions: [RuleSuggestion]) async -> Bool {
        guard let engine else { return false }
        var ok = false
        await perform {
            try await engine.apply(suggestions)
            ok = true
        }
        if ok { show(Toast(message: "Saved \(suggestions.count) rule\(suggestions.count == 1 ? "" : "s")")) }
        return ok
    }

    func planSort(of folderId: String, progress: ProgressTracker) async throws -> SyncEngine.FolderSortPlan {
        guard let engine else { throw CancellationError() }
        return try await engine.planFolderSort(folderId, ignoring: unsortedFolderIds) { done, total in
            Task { @MainActor in progress.update(done, total) }
        }
    }

    func execute(_ plan: SyncEngine.FolderSortPlan, progress: ProgressTracker) async -> Bool {
        guard let engine else { return false }
        var ok = false
        await perform {
            try await engine.execute(plan) { done, total in
                Task { @MainActor in progress.update(done, total) }
            }
            ok = true
        }
        return ok
    }

    func deleteFolder(_ id: String) async -> Bool {
        guard let engine else { return false }
        let name = name(of: id)
        var ok = false
        await perform {
            try await engine.deleteMailbox(id)
            ok = true
        }
        if ok { show(Toast(message: "Deleted “\(name)”")) }
        return ok
    }

    // MARK: - Toasts

    struct Toast: Identifiable {
        let id = UUID()
        var message: String
        /// How long it stays up, in seconds.
        var duration = 6
        var undo: (() async -> Void)?
    }

    var toast: Toast?

    func show(_ toast: Toast) {
        withAnimation(.snappy) { self.toast = toast }
        let id = toast.id
        Task {
            try? await Task.sleep(for: .seconds(toast.duration))
            if self.toast?.id == id { withAnimation(.snappy) { self.toast = nil } }
        }
    }

    func relabel(_ ids: [String], add: [String], remove: [String]) async {
        guard let engine else { return }
        await perform { try await engine.relabel(ids, add: add, remove: remove) }
    }

    // MARK: - Bubble Up

    static let bubbleUpSymbol = "arrow.up.message"

    func bubbleUp(for threadId: String) -> BubbleUp? { bubbleUps.first { $0.threadId == threadId } }

    /// Sets a conversation to come back to the top at `date` (replacing any
    /// time already set), with Undo in the confirmation.
    func bubbleUp(_ threadId: String, at date: Date) async {
        guard let engine, let store else { return }
        let thread = ((try? await store.read(.thread(threadId))) ?? []).filter { !$0.isBubble }
        guard let latest = thread.last else { return }
        if let existing = bubbleUp(for: threadId) { try? await engine.cancel(existing) }
        var scheduled: BubbleUp?
        await perform { scheduled = try await engine.bubbleUp(latest, at: date) }
        guard let scheduled else { return }
        show(Toast(message: "Bubbles up \(date.bubbleUpLabel)") { [weak self] in
            await self?.cancelBubbleUp(scheduled, confirm: false)
        })
    }

    func cancelBubbleUp(_ bubble: BubbleUp, confirm: Bool = true) async {
        guard let engine else { return }
        var ok = false
        await perform {
            try await engine.cancel(bubble)
            ok = true
        }
        if ok, confirm { show(Toast(message: "Won't bubble up")) }
    }

    // MARK: - Sending and drafts

    /// Seconds a sent message waits so it can be undone; 0 turns Undo Send off.
    static let undoSendDelayKey = "undoSendDelay"
    var undoSendDelay: Int { UserDefaults.standard.object(forKey: Self.undoSendDelayKey) as? Int ?? 10 }

    /// A compose screen to bring back after Undo Send; the main window opens it.
    var composeToReopen: ComposeRequest?
    @ObservationIgnored private var heldSends: [UUID: Task<Void, Never>] = [:]

    /// Sends `message`, held for the Undo Send delay. Returns false (with an
    /// alert) only if it couldn't be handed off at all.
    func send(_ message: OutgoingMessage) async -> Bool {
        guard let engine else { return false }
        let delay = undoSendDelay
        do {
            if delay == 0 {
                try await engine.send(message)
                show(Toast(message: "Sent"))
            } else if await engine.maxDelayedSend() >= delay {
                // Fastmail holds it, so it still goes out if Sift quits meanwhile.
                let sending = try await engine.send(message, holdFor: delay)
                show(Toast(message: "Sending…", duration: delay) { [weak self] in
                    await self?.undoSend(sending, message)
                })
            } else {
                // Fastmail can't hold it: keep it in Drafts for the delay, then send.
                var held = message
                held.draftId = try await engine.saveDraft(message)
                let id = UUID()
                heldSends[id] = Task { [weak self] in
                    #if os(iOS)
                    let background = UIApplication.shared.beginBackgroundTask(withName: "Send")
                    defer { UIApplication.shared.endBackgroundTask(background) }
                    #endif
                    guard (try? await Task.sleep(for: .seconds(delay))) != nil else { return }
                    await self?.finishHeldSend(id, held)
                }
                show(Toast(message: "Sending…", duration: delay) { [weak self] in
                    self?.cancelHeldSend(id, held)
                })
            }
            return true
        } catch {
            errorMessage = error.isTransientNetworkFailure
                ? "Couldn't reach Fastmail, so the message wasn't sent. Check your connection and try again."
                : error.localizedDescription
            return false
        }
    }

    private func undoSend(_ sending: Sending, _ message: OutgoingMessage) async {
        guard let engine else { return }
        do {
            try await engine.cancel(sending)
            var restored = message
            restored.draftId = sending.emailId
            composeToReopen = ComposeRequest(draft: restored)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func finishHeldSend(_ id: UUID, _ message: OutgoingMessage) async {
        heldSends[id] = nil
        guard let engine else { return }
        do {
            try await engine.send(message)
            show(Toast(message: "Sent"))
        } catch {
            errorMessage = "Couldn't send “\(message.subject.isEmpty ? "(no subject)" : message.subject)”. It's saved in Drafts. \(error.localizedDescription)"
        }
    }

    private func cancelHeldSend(_ id: UUID, _ message: OutgoingMessage) {
        heldSends[id]?.cancel()
        heldSends[id] = nil
        composeToReopen = ComposeRequest(draft: message)
    }

    /// Saves a draft to Fastmail and returns its id (nil, with an alert, on failure).
    func saveDraft(_ message: OutgoingMessage) async -> String? {
        guard let engine else { return nil }
        var id: String?
        await perform { id = try await engine.saveDraft(message) }
        // Bring the new version into Drafts now rather than at the next sync.
        if id != nil { Task { await refresh(.automatic) } }
        return id
    }

    func discardDraft(_ id: String) async {
        guard let engine else { return }
        await perform { try await engine.discardDraft(id) }
    }

    func openDraft(_ id: String) async -> OutgoingMessage? {
        guard let engine else { return nil }
        var message: OutgoingMessage?
        await perform { message = try await engine.outgoingMessage(fromDraft: id) }
        return message
    }

    func upload(_ data: Data, name: String, type: String) async throws -> OutgoingMessage.Attachment {
        guard let engine else { throw CancellationError() }
        if let limit = await engine.maxUploadSize(), data.count > limit {
            throw AttachmentError.tooLarge(limit: limit)
        }
        return try await engine.upload(data, name: name, type: type)
    }

    enum AttachmentError: LocalizedError {
        case tooLarge(limit: Int)
        var errorDescription: String? {
            switch self {
            case .tooLarge(let limit):
                "Too large: Fastmail takes files up to \(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file))."
            }
        }
    }

    /// Addresses to offer while typing a recipient (never your own).
    func addressSuggestions(matching text: String) async -> [EmailAddress] {
        guard let store else { return [] }
        let own = Set(identities.map { $0.email.lowercased() })
        return ((try? await store.addressSuggestions(matching: text, limit: 8)) ?? []).filter { !own.contains($0.normalized) }
    }

    func body(for message: MessageRecord) async throws -> BodyRecord {
        guard let engine else { throw CancellationError() }
        return try await engine.body(for: message.id)
    }

    func loadOlder(in mailboxId: String?, before date: Date) async {
        guard let engine else { return }
        await perform { try await engine.loadOlder(in: mailboxId, before: date) }
    }

    func search(_ query: SearchQuery) async throws -> SyncEngine.SearchResult {
        guard let engine else { throw CancellationError() }
        return try await engine.search(query)
    }

    private func perform(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch is CancellationError {
        } catch where error.isTransientNetworkFailure {
            errorMessage = "Couldn't reach Fastmail (\(error.localizedDescription.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))). Check your connection and try again."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Notifications

    private func handleNewMail(_ messages: [MessageRecord]) async {
        guard let store, let special else { return }
        let senders = (try? await store.senders()) ?? []
        let notifying = Set(senders.filter(\.notify).map(\.email))
        let quarantined = Set(special.quarantined)
        let recent = messages.filter { message in
            notifying.contains(message.fromEmail) && message.isUnread
                && message.mailboxIds.allSatisfy { !quarantined.contains($0) }
                && message.receivedAt > .now.addingTimeInterval(-3600)
        }
        await notifier.post(recent)
    }
}

/// Progress of a long Fastmail operation, for a determinate progress bar.
@Observable
final class ProgressTracker {
    var done = 0
    var total = 0

    func update(_ done: Int, _ total: Int) {
        self.done = done
        self.total = total
    }

    var fraction: Double { total == 0 ? 0 : Double(done) / Double(total) }
}

extension Date {
    /// "today at 1:00 PM", "tomorrow at 8:00 AM", "Saturday at 8:00 AM", or a date.
    var bubbleUpLabel: String {
        let calendar = Calendar.current
        let time = formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(self) { return "today at \(time)" }
        if calendar.isDateInTomorrow(self) { return "tomorrow at \(time)" }
        if let days = calendar.dateComponents([.day], from: .now, to: self).day, days < 6 {
            return "\(formatted(.dateTime.weekday(.wide))) at \(time)"
        }
        return formatted(date: .abbreviated, time: .shortened)
    }
}
