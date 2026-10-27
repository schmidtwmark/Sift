import Foundation
import GRDB

/// Keeps `MailStore` in step with Fastmail, applies Screener routing, and
/// performs every mutation the UI asks for.
public actor SyncEngine {
    public static let screenerName = "Screener"
    public static let screenedOutName = "Screened Out"

    enum Key {
        static let emailState = "state.Email"
        static let mailboxState = "state.Mailbox"
        static let activatedAt = "screener.activatedAt"
        static let screenerId = "mailbox.screener"
        static let screenedOutId = "mailbox.screenedOut"
        static let bubbleUps = "bubbleUps"
    }

    public let store: MailStore
    public let client: JMAPClient
    private let rules: ContactsRuleStore

    /// How much history the first sync pulls down. Older mail is fetched on demand.
    public var initialSyncLimit = 3000

    public private(set) var mailboxes: SpecialMailboxes?
    public private(set) var identities: [Identity] = []
    private var activatedAt: Date = .now
    private var isRefreshing = false
    private var refreshAgain = false

    /// Called with messages that arrived during this session (not on initial
    /// sync), after routing. The app turns these into notifications.
    private var newMailHandler: (@Sendable ([MessageRecord]) async -> Void)?

    public init(client: JMAPClient, store: MailStore) {
        self.client = client
        self.store = store
        self.rules = ContactsRuleStore(client: client)
    }

    public func onNewMail(_ handler: @escaping @Sendable ([MessageRecord]) async -> Void) {
        newMailHandler = handler
    }

    // MARK: - Lifecycle

    /// First-run and launch work: mailboxes, identities, rules, then mail.
    /// `activatedAt` overrides when the Screener was switched on (demo mode).
    public func start(activatedAt override: Date? = nil) async throws {
        _ = try await client.session(refresh: true)
        if override == nil, let stored = try await store.value(for: Key.activatedAt), let date = JMAPCoding.parseDate(stored) {
            activatedAt = date
        } else {
            activatedAt = override ?? .now
            try await store.setValue(JMAPCoding.formatUTCDate(activatedAt), for: Key.activatedAt)
        }
        try await syncMailboxes()
        try await syncIdentities()
        try await syncRules()
        if try await store.value(for: Key.emailState) == nil {
            try await initialEmailSync()
        } else {
            try await refresh()
        }
    }

    /// Pulls every change since the last sync, then routes new mail.
    public func refresh() async throws {
        if isRefreshing {
            refreshAgain = true
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }
        repeat {
            refreshAgain = false
            try await syncMailboxes()
            let created = try await syncEmailChanges()
            try await route()
            try await receiveBubbleUps(among: created)
            try? await syncBubbleUps()
            if !created.isEmpty, let newMailHandler {
                let fresh = try await store.messages(ids: created)
                await newMailHandler(fresh)
            }
        } while refreshAgain
    }

    /// Holds Fastmail's EventSource open and refreshes on every state change.
    /// Runs until cancelled, reconnecting with backoff.
    public func listen() async {
        var delay: Duration = .seconds(2)
        while !Task.isCancelled {
            do {
                for try await change in try await client.stateChanges() {
                    delay = .seconds(2)
                    let accountId = try await client.accountId()
                    guard let types = change.changed[accountId] else { continue }
                    if types["ContactCard"] != nil, types["ContactCard"] != (await rules.state) {
                        try? await syncRules()
                    }
                    if types["Email"] != nil || types["Mailbox"] != nil {
                        try? await refresh()
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                // Fall through to reconnect.
            }
            try? await Task.sleep(for: delay)
            delay = min(delay * 2, .seconds(120))
            try? await refresh()
        }
    }

    // MARK: - Mailboxes, identities, rules

    func syncMailboxes() async throws {
        let accountId = try await client.accountId()
        let response = try await client.perform([
            MethodCall("Mailbox/get", ["accountId": .string(accountId)], id: "boxes"),
        ])
        let result = try response.result("boxes", as: GetResponse<Mailbox>.self)
        if let state = result.state, state == (try await store.value(for: Key.mailboxState)), mailboxes != nil {
            return
        }
        var list = result.list
        let screener = try await ensureMailbox(named: Self.screenerName, key: Key.screenerId, in: &list)
        let screenedOut = try await ensureMailbox(named: Self.screenedOutName, key: Key.screenedOutId, in: &list)
        try await store.replaceMailboxes(list)
        try await store.setValue(result.state, for: Key.mailboxState)

        func role(_ role: MailboxRole) -> String? { list.first { $0.role == role.rawValue }?.id }
        guard let inbox = role(.inbox) else { throw JMAPError.missingResponse("inbox mailbox") }
        mailboxes = SpecialMailboxes(inbox: inbox, screener: screener, screenedOut: screenedOut,
                                     archive: role(.archive), trash: role(.trash), junk: role(.junk),
                                     sent: role(.sent), drafts: role(.drafts))
    }

    private func ensureMailbox(named name: String, key: String, in list: inout [Mailbox]) async throws -> String {
        if let id = try await store.value(for: key), list.contains(where: { $0.id == id }) {
            return id
        }
        if let existing = list.first(where: { $0.name == name && $0.parentId == nil }) {
            try await store.setValue(existing.id, for: key)
            return existing.id
        }
        let id = try await createMailbox(named: name)
        list.append(Mailbox(id: id, name: name, parentId: nil, role: nil, sortOrder: 5))
        try await store.setValue(id, for: key)
        return id
    }

    /// Creates a label (a Fastmail mailbox). Returns its id.
    @discardableResult
    public func createMailbox(named name: String) async throws -> String {
        let accountId = try await client.accountId()
        let response = try await client.perform([
            MethodCall("Mailbox/set", [
                "accountId": .string(accountId),
                "create": ["new": ["name": .string(name), "parentId": .null]],
            ], id: "create"),
        ])
        let result = try response.result("create", as: SetResponse.self)
        try result.throwIfFailed("create the “\(name)” mailbox")
        guard let id = result.created?["new"]?["id"]?.stringValue else {
            throw JMAPError.missingResponse("Mailbox/set")
        }
        if mailboxes != nil { try await syncMailboxes() }
        return id
    }

    /// Puts `ids` (your folders) in this order, here and in Fastmail, by
    /// renumbering their sortOrder. They stay after the system mailboxes, so
    /// Fastmail's own folder list keeps Inbox, Archive and the rest on top.
    public func reorderMailboxes(_ ids: [String]) async throws {
        let current = try await store.mailboxes()
        let byId = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let afterSystem = (current.filter { $0.role != nil }.map(\.sortOrder).max() ?? 0) + 1
        let base = max(afterSystem, ids.compactMap { byId[$0]?.sortOrder }.min() ?? afterSystem)
        var changes: [String: Int] = [:]
        for (index, id) in ids.enumerated() where byId[id] != nil && byId[id]?.sortOrder != base + index {
            changes[id] = base + index
        }
        guard !changes.isEmpty else { return }

        // Shown at once; put back if Fastmail says no.
        let before = changes.keys.reduce(into: [String: Int]()) { $0[$1] = byId[$1]?.sortOrder }
        try await store.setSortOrders(changes)
        do {
            let accountId = try await client.accountId()
            let response = try await client.perform([
                MethodCall("Mailbox/set", [
                    "accountId": .string(accountId),
                    "update": .object(changes.mapValues { ["sortOrder": .int($0)] }),
                ], id: "order"),
            ])
            try response.result("order", as: SetResponse.self).throwIfFailed("reorder your folders")
        } catch {
            try? await store.setSortOrders(before)
            throw error
        }
    }

    func syncIdentities() async throws {
        let accountId = try await client.accountId()
        let response = try await client.perform([
            MethodCall("Identity/get", ["accountId": .string(accountId)], id: "ids"),
        ], using: [JMAPCapability.core, JMAPCapability.mail, JMAPCapability.submission])
        identities = (try? response.result("ids", as: GetResponse<Identity>.self).list) ?? []
    }

    /// Reloads sender rules from Fastmail Contacts into the local cache.
    public func syncRules() async throws {
        let mailboxIds = try await store.mailboxes().map(\.id)
        let loaded = try await rules.load(mailboxIds: mailboxIds)
        try await store.replaceSenders(loaded)
        try await store.setLabelIcons(await rules.labelIcons)
    }

    /// Sets a label's icon (nil goes back to the one guessed from its name).
    /// Shows at once, and syncs to other devices through the label's contact group.
    public func setLabelIcon(_ symbol: String?, for mailboxId: String) async throws {
        let before = try await store.read(.labelIcons)
        var icons = before
        icons[mailboxId] = symbol
        try await store.setLabelIcons(icons)
        do {
            let name = try await store.mailboxes().first { $0.id == mailboxId }?.name ?? "Label"
            try await rules.setIcon(symbol, forLabel: mailboxId, labelName: name)
        } catch {
            try? await store.setLabelIcons(before)
            throw error
        }
    }

    // MARK: - Email sync

    func initialEmailSync() async throws {
        let accountId = try await client.accountId()
        var firstState: String?

        // Recent history across the whole account (this is the Everything view).
        firstState = try await fetchQuery(filter: nil, limit: initialSyncLimit, accountId: accountId)
        // Make sure the piles people act on are complete, not just recent.
        if let boxes = mailboxes {
            for id in [boxes.screener, boxes.inbox] {
                _ = try await fetchQuery(filter: ["inMailbox": .string(id)], limit: 2000, accountId: accountId)
            }
            if let sent = boxes.sent {
                try await learnSentRecipients(sentMailbox: sent, accountId: accountId)
            }
        }
        try await store.setValue(firstState, for: Key.emailState)
        try await route()
    }

    /// Queries newest-first and stores up to `limit` messages. Returns the Email state.
    @discardableResult
    func fetchQuery(filter: JSONValue?, limit: Int, accountId: String, skipKnown: Bool = true) async throws -> String? {
        let pageSize = 500
        var position = 0
        var state: String?
        let known = skipKnown ? try await store.knownMessageIds() : []
        while position < limit {
            var query: [String: JSONValue] = [
                "accountId": .string(accountId),
                "sort": [["property": "receivedAt", "isAscending": false]],
                "position": .int(position),
                "limit": .int(min(pageSize, limit - position)),
            ]
            if let filter { query["filter"] = filter }
            let queryResponse = try await client.perform([MethodCall("Email/query", query, id: "q")])
            let ids = try queryResponse.result("q", as: QueryResponse.self).ids
            let missing = ids.filter { !known.contains($0) }
            if !missing.isEmpty || state == nil {
                let emails = try await getEmails(ids: missing, accountId: accountId)
                state = state ?? emails.state
                try await storeServerEmails(emails.list)
            }
            position += ids.count
            if ids.count < pageSize { break }
        }
        return state
    }

    private func getEmails(ids: [String], accountId: String) async throws -> GetResponse<Email> {
        let response = try await client.perform([
            MethodCall("Email/get", [
                "accountId": .string(accountId),
                "ids": .strings(ids),
                "properties": .strings(Email.listProperties),
            ], id: "get"),
        ])
        return try response.result("get", as: GetResponse<Email>.self)
    }

    /// Hey-style: anyone you've written to skips the Screener.
    private func learnSentRecipients(sentMailbox: String, accountId: String) async throws {
        let response = try await client.perform([
            MethodCall("Email/query", [
                "accountId": .string(accountId),
                "filter": ["inMailbox": .string(sentMailbox)],
                "sort": [["property": "receivedAt", "isAscending": false]],
                "limit": 1000,
            ], id: "q"),
            MethodCall("Email/get", [
                "accountId": .string(accountId),
                "#ids": MethodCall.reference(to: "q", name: "Email/query", path: "/ids"),
                "properties": .strings(["id", "to", "cc", "bcc"]),
            ], id: "get"),
        ])
        let emails = try response.result("get", as: GetResponse<Email>.self).list
        let addresses = emails.flatMap(\.recipients).map(\.normalized)
        try await store.recordSentRecipients(addresses.filter { !$0.isEmpty })
    }

    /// Applies `Email/changes` since the stored state. Returns ids of newly created messages.
    func syncEmailChanges() async throws -> [String] {
        guard var sinceState = try await store.value(for: Key.emailState) else {
            try await initialEmailSync()
            return []
        }
        let accountId = try await client.accountId()
        var created: [String] = []
        while true {
            let response = try await client.perform([
                MethodCall("Email/changes", [
                    "accountId": .string(accountId),
                    "sinceState": .string(sinceState),
                    "maxChanges": 500,
                ], id: "changes"),
                MethodCall("Email/get", [
                    "accountId": .string(accountId),
                    "#ids": MethodCall.reference(to: "changes", name: "Email/changes", path: "/created"),
                    "properties": .strings(Email.listProperties),
                ], id: "created"),
                MethodCall("Email/get", [
                    "accountId": .string(accountId),
                    "#ids": MethodCall.reference(to: "changes", name: "Email/changes", path: "/updated"),
                    "properties": .strings(Email.listProperties),
                ], id: "updated"),
            ])
            let changes: ChangesResponse
            do {
                changes = try response.result("changes", as: ChangesResponse.self)
            } catch JMAPError.method(type: "cannotCalculateChanges", _) {
                try await store.setValue(nil, for: Key.emailState)
                try await initialEmailSync()
                return []
            }
            let fresh = try response.result("created", as: GetResponse<Email>.self).list
            let updated = try response.result("updated", as: GetResponse<Email>.self).list
            try await storeServerEmails(fresh + updated)
            try await store.delete(messageIds: changes.destroyed)
            if let sent = mailboxes?.sent {
                let mine = fresh.filter { $0.mailboxIds?[sent] == true }
                let addresses = mine.flatMap(\.recipients).map(\.normalized)
                try await store.recordSentRecipients(addresses.filter { !$0.isEmpty })
            }
            created += fresh.map(\.id)
            sinceState = changes.newState
            try await store.setValue(sinceState, for: Key.emailState)
            if !changes.hasMoreChanges { break }
        }
        return created
    }

    /// Fetches older messages for a list that's been scrolled to the end.
    public func loadOlder(in mailboxId: String?, before date: Date, count: Int = 200) async throws {
        let accountId = try await client.accountId()
        var filter: [String: JSONValue] = ["before": .string(JMAPCoding.formatUTCDate(date))]
        if let mailboxId { filter["inMailbox"] = .string(mailboxId) }
        try await fetchQuery(filter: .object(filter), limit: count, accountId: accountId)
    }

    // MARK: - Routing

    /// Files unrouted Inbox mail according to sender rules. Idempotent across
    /// devices thanks to the `$siftrouted` keyword.
    func route() async throws {
        guard let boxes = mailboxes else { return }
        let ruleList = try await store.senders()
        let rulesByEmail = Dictionary(ruleList.map { ($0.email, $0) }, uniquingKeysWith: { first, _ in first })
        let inbox = try await store.messages(in: boxes.inbox).filter { !$0.isRouted && $0.receivedAt >= activatedAt }
        // Spam from screened-in senders, which Fastmail filtered before Sift could sort it.
        var spam: [MessageRecord] = []
        if let junk = boxes.junk {
            spam = try await store.messages(in: junk).filter {
                !$0.isRouted && $0.receivedAt >= activatedAt && rulesByEmail[$0.fromEmail]?.status == .screenedIn
            }
        }
        let candidates = inbox + spam
        guard !candidates.isEmpty else { return }

        var known = await rules.contactAddresses
        for candidate in inbox {
            if try await store.hasWrittenTo(candidate.fromEmail) { known.insert(candidate.fromEmail) }
        }
        let context = RoutingContext(
            mailboxes: boxes,
            activatedAt: activatedAt,
            ownAddresses: Set(identities.map { $0.email.lowercased() }),
            knownAddresses: known,
            rules: rulesByEmail,
            unauthenticated: try await failingDMARC(spam.map(\.id))
        )
        let plan = Router.plan(for: candidates, context: context)
        for address in plan.autoApproved {
            let rule = SenderRecord(email: address.normalized, name: address.name, status: .screenedIn)
            try? await saveRule(rule)
        }
        try await apply(plan.patches)
    }

    /// The messages whose From address failed DMARC when Fastmail received them.
    private func failingDMARC(_ ids: [String]) async throws -> Set<String> {
        guard !ids.isEmpty else { return [] }
        struct Headers: Decodable {
            var id: String
            var results: [String]?
            enum CodingKeys: String, CodingKey {
                case id
                case results = "header:Authentication-Results:asText:all"
            }
        }
        let accountId = try await client.accountId()
        let response = try await client.perform([
            MethodCall("Email/get", [
                "accountId": .string(accountId),
                "ids": .strings(ids),
                "properties": .strings(["id", "header:Authentication-Results:asText:all"]),
            ], id: "auth"),
        ])
        let list = try response.result("auth", as: GetResponse<Headers>.self).list
        return Set(list.filter { Router.failedDMARC($0.results ?? []) }.map(\.id))
    }

    // MARK: - Screener actions

    public func screenIn(_ sender: String, name: String?, labels: [String]) async throws {
        guard let boxes = mailboxes else { return }
        var rule = try await store.sender(sender) ?? SenderRecord(email: sender, name: name)
        rule.status = .screenedIn
        // Empty means "Inbox"; Inbox plus labels keeps the Inbox in the set.
        rule.labelIds = labels == [boxes.inbox] ? [] : labels
        rule.updatedAt = .now
        try await saveRule(rule)
        let waiting = try await store.messages(from: sender, in: boxes.screener)
        var patches = Router.screenIn(waiting, labels: labels, mailboxes: boxes)
        patches.merge(try await releaseSpam(from: sender, toLabels: labels), uniquingKeysWith: { $1 })
        try await apply(patches)
    }

    /// Everything of the sender's in Spam, out to `labels` (the Inbox when empty).
    private func releaseSpam(from sender: String, toLabels labels: [String]) async throws -> [String: EmailPatch] {
        guard let boxes = mailboxes, let junk = boxes.junk else { return [:] }
        let spam = try await store.messages(from: sender, in: junk)
        return Dictionary(uniqueKeysWithValues: spam.map { ($0.id, Router.release($0, toLabels: labels, mailboxes: boxes)) })
    }

    public func screenOut(_ sender: String, name: String?) async throws {
        guard let boxes = mailboxes else { return }
        var rule = try await store.sender(sender) ?? SenderRecord(email: sender, name: name)
        rule.status = .screenedOut
        rule.notify = false
        rule.badge = false
        rule.updatedAt = .now
        try await saveRule(rule)
        let waiting = try await store.messages(from: sender, in: boxes.screener)
        try await apply(Router.screenOut(waiting, mailboxes: boxes))
    }

    /// Saves a rule edited in sender settings. With `refile`, the sender's
    /// existing mail is moved to match.
    public func updateRule(_ rule: SenderRecord, refile: Bool) async throws {
        guard let boxes = mailboxes else { return }
        let previous = try await store.sender(rule.email)
        try await saveRule(rule)
        guard refile else { return }
        let existing = try await store.messages(from: rule.email)
        switch rule.status {
        case .screenedOut:
            // Leave trash and junk alone; everything else moves to Screened Out.
            let untouchable = Set([boxes.screenedOut, boxes.trash, boxes.junk].compactMap { $0 })
            let live = existing.filter { $0.mailboxIds.allSatisfy { !untouchable.contains($0) } }
            try await apply(Router.screenOut(live, mailboxes: boxes))
        case .screenedIn:
            let oldLabels = Set(previous?.labelIds ?? []).union([boxes.screener, boxes.screenedOut])
            let destinations = rule.labelIds.isEmpty ? [boxes.inbox] : rule.labelIds
            var patches: [String: EmailPatch] = [:]
            for message in existing where message.mailboxIds.contains(where: { oldLabels.contains($0) || $0 == boxes.inbox }) {
                patches[message.id] = Router.move(
                    from: message.mailboxIds.filter { oldLabels.contains($0) || $0 == boxes.inbox },
                    to: destinations
                )
            }
            patches.merge(try await releaseSpam(from: rule.email, toLabels: rule.labelIds), uniquingKeysWith: { $1 })
            try await apply(patches)
        case .unknown:
            break
        }
    }

    private func saveRule(_ rule: SenderRecord) async throws {
        try await saveRules([rule])
    }

    private func saveRules(_ batch: [SenderRecord]) async throws {
        let names = Dictionary(try await store.mailboxes().map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        // Fastmail first: if it refuses, the local copy must not claim otherwise.
        try await rules.save(batch, labelNames: names)
        for rule in batch { try await store.save(rule) }
    }

    // MARK: - Message actions

    public func setKeyword(_ keyword: String, _ on: Bool, for ids: [String]) async throws {
        try await apply(Dictionary(uniqueKeysWithValues: ids.map { ($0, ["keywords/\(keyword)": on ? true : .null]) }))
    }

    /// Adds and removes mailboxes (labels) on messages.
    public func relabel(_ ids: [String], add: [String], remove: [String]) async throws {
        try await apply(Dictionary(uniqueKeysWithValues: ids.map { ($0, Router.move(from: remove, to: add)) }))
    }

    /// Archive in Fastmail's labels model: drop the current label; if nothing is
    /// left, the message lives in Archive.
    /// Where each message was before a move, so it can be undone exactly.
    public typealias Placement = [String: [String]]

    @discardableResult
    public func archive(_ ids: [String], from mailboxId: String?) async throws -> Placement {
        guard let boxes = mailboxes else { return [:] }
        let messages = try await store.messages(ids: ids)
        var patches: [String: EmailPatch] = [:]
        for message in messages {
            let removing = mailboxId.map { [$0] } ?? [boxes.inbox]
            let remaining = Set(message.mailboxIds).subtracting(removing)
            var patch = Router.move(from: removing, to: [])
            if remaining.isEmpty, let archive = boxes.archive { patch["mailboxIds/\(archive)"] = true }
            patches[message.id] = patch
        }
        try await apply(patches)
        return Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0.mailboxIds) })
    }

    @discardableResult
    public func moveToTrash(_ ids: [String]) async throws -> Placement {
        guard let trash = mailboxes?.trash else { return [:] }
        return try await replaceMailboxes(ids, with: trash)
    }

    @discardableResult
    public func moveToJunk(_ ids: [String]) async throws -> Placement {
        guard let junk = mailboxes?.junk else { return [:] }
        // Marked as sorted too, so Sift never pulls it back out for a screened-in sender.
        return try await replaceMailboxes(ids, with: junk, keywords: [
            "keywords/\(Keyword.junk)": true, "keywords/\(Keyword.notJunk)": .null, "keywords/\(Keyword.routed)": true,
        ])
    }

    private func replaceMailboxes(_ ids: [String], with mailboxId: String, keywords: EmailPatch = [:]) async throws -> Placement {
        let messages = try await store.messages(ids: ids)
        var patches: [String: EmailPatch] = [:]
        for message in messages {
            patches[message.id] = Router.move(from: message.mailboxIds, to: [mailboxId]).merging(keywords, uniquingKeysWith: { $1 })
        }
        try await apply(patches)
        return Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0.mailboxIds) })
    }

    /// Undo: puts messages back exactly where they were.
    public func restore(_ placement: Placement) async throws {
        let messages = try await store.messages(ids: Array(placement.keys))
        var patches: [String: EmailPatch] = [:]
        for message in messages {
            guard let original = placement[message.id] else { continue }
            patches[message.id] = Router.move(from: message.mailboxIds, to: original)
            if let junk = mailboxes?.junk, message.mailboxIds.contains(junk), !original.contains(junk) {
                patches[message.id]?["keywords/\(Keyword.junk)"] = .null
            }
        }
        try await apply(patches)
    }

    /// Sends patches to Fastmail and mirrors them locally right away. If
    /// Fastmail refuses or the request fails, the local copy is put back.
    func apply(_ patches: [String: EmailPatch]) async throws {
        guard !patches.isEmpty else { return }
        let accountId = try await client.accountId()
        let token = UUID()
        for (id, patch) in patches { pending[id, default: []].append((token, patch)) }
        defer { clearPending(token, for: patches.keys) }

        let current = try await store.messages(ids: Array(patches.keys))
        try await store.upsert(current.compactMap { message in patches[message.id].map(message.applying) })

        do {
            for chunk in Array(patches).chunked(into: 200) {
                let update = JSONValue.object(Dictionary(uniqueKeysWithValues: chunk.map { ($0.key, JSONValue.object($0.value)) }))
                let response = try await client.perform([
                    MethodCall("Email/set", ["accountId": .string(accountId), "update": update], id: "set"),
                ])
                let result = try response.result("set", as: SetResponse.self)
                if let failed = result.notUpdated, !failed.isEmpty {
                    // Roll the optimistic copy back to the server's truth.
                    clearPending(token, for: failed.keys)
                    let emails = try await getEmails(ids: Array(failed.keys), accountId: accountId)
                    try await storeServerEmails(emails.list)
                    try result.throwIfFailed("update \(failed.count) message\(failed.count == 1 ? "" : "s")")
                }
            }
        } catch {
            // Never leave the screen claiming a change Fastmail didn't make.
            clearPending(token, for: patches.keys)
            try? await store.upsert(current)
            throw error
        }
    }

    /// Changes sent to Fastmail but not yet confirmed, per message. Copies
    /// fetched meanwhile get them re-applied, so a sync that races a change
    /// (an EventSource push mid-request) can't flip it back on screen.
    private var pending: [String: [(token: UUID, patch: EmailPatch)]] = [:]

    private func clearPending(_ token: UUID, for ids: some Sequence<String>) {
        for id in ids {
            pending[id]?.removeAll { $0.token == token }
            if pending[id]?.isEmpty == true { pending[id] = nil }
        }
    }

    /// Stores messages fetched from Fastmail, keeping in-flight changes.
    private func storeServerEmails(_ emails: [Email]) async throws {
        guard !emails.isEmpty else { return }
        try await store.upsert(emails.map { email in
            (pending[email.id] ?? []).reduce(MessageRecord(email)) { $0.applying($1.patch) }
        })
    }

    // MARK: - Bodies & attachments

    public func body(for messageId: String) async throws -> BodyRecord {
        if let cached = try await store.body(for: messageId) { return cached }
        let accountId = try await client.accountId()
        let response = try await client.perform([
            MethodCall("Email/get", [
                "accountId": .string(accountId),
                "ids": [.string(messageId)],
                "properties": .strings(Email.bodyProperties),
                "bodyProperties": .strings(["partId", "blobId", "size", "name", "type", "charset", "disposition", "cid"]),
                "fetchHTMLBodyValues": true,
                "fetchTextBodyValues": true,
            ], id: "body"),
        ])
        guard let email = try response.result("body", as: GetResponse<Email>.self).list.first else {
            throw JMAPError.missingResponse("Email/get body")
        }
        let body = BodyAssembler.assemble(email)
        try await store.save(body)
        return body
    }

    public func download(blobId: String, name: String, type: String) async throws -> Data {
        try await client.download(blobId: blobId, name: name, type: type)
    }

    // MARK: - Learning from existing mail

    /// The user's own folders: no system role, not Sift's piles.
    private func userLabelIds() async throws -> Set<String> {
        guard let boxes = mailboxes else { return [] }
        return Set(try await store.mailboxes()
            .filter { $0.role == nil && $0.id != boxes.screener && $0.id != boxes.screenedOut }
            .map(\.id))
    }

    /// Rules implied by where the user already files each sender's mail.
    /// `ignoring` holds folders with no filing signal (an unsorted import).
    public func suggestRules(ignoring ignored: Set<String> = []) async throws -> [RuleSuggestion] {
        guard let boxes = mailboxes else { return [] }
        let inputs = SortingInference.Inputs(
            mailboxes: boxes, userLabels: try await userLabelIds().subtracting(ignored),
            ignored: ignored, ownAddresses: Set(identities.map { $0.email.lowercased() })
        )
        let existing = Dictionary(try await store.senders().map { ($0.email, $0) }, uniquingKeysWith: { first, _ in first })
        let messages = try await store.writer.read { db in try MessageRecord.fetchAll(db) }
        return SortingInference.suggestions(from: messages, inputs: inputs, existing: existing)
    }

    /// Saves accepted suggestions as screening rules (future mail only).
    public func apply(_ suggestions: [RuleSuggestion]) async throws {
        try await saveRules(suggestions.map(\.rule))
    }

    // MARK: - Sorting a folder

    public struct FolderSortPlan: Sendable {
        /// One message, and why it's going where it is.
        public struct Item: Sendable, Identifiable, Hashable {
            public var id: String
            public var subject: String
            public var senderName: String?
            public var senderEmail: String
            public var receivedAt: Date?
            public var reason: SortReason
        }

        public struct Bucket: Sendable, Identifiable {
            public var id: String { destination.joined(separator: "+") }
            public var destination: [String]
            /// Newest first.
            public var items: [Item]
            public var messageIds: [String] { items.map(\.id) }
            public var senders: Set<String> { Set(items.map(\.senderEmail)) }
        }

        public var sourceId: String
        public var buckets: [Bucket]
        /// Addresses treated as the user's own (their mail goes to Sent).
        public var ownAddresses: [String]
        public var total: Int { buckets.reduce(0) { $0 + $1.messageIds.count } }
    }

    /// Works out where every message in `sourceId` belongs, without moving
    /// anything. Reads the whole folder from Fastmail, not just the cache.
    /// `ignoring` adds other unsorted folders to leave out of the inference.
    public func planFolderSort(_ sourceId: String, ignoring ignored: Set<String> = [],
                               progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> FolderSortPlan {
        guard let boxes = mailboxes else { throw JMAPError.missingResponse("mailboxes") }
        let accountId = try await client.accountId()
        let emails = try await fetchAll(inMailbox: sourceId, accountId: accountId,
                                        properties: ["id", "from", "to", "cc", "mailboxIds", "subject", "receivedAt"], progress: progress)

        var own = Set(identities.map { $0.email.lowercased() })
        if let old = SortingInference.dominantRecipient(of: emails) { own.insert(old) }

        let suggestions = Dictionary(try await suggestRules(ignoring: ignored.union([sourceId])).map { ($0.email, $0) },
                                     uniquingKeysWith: { first, _ in first })
        let rules = Dictionary(try await store.senders().map { ($0.email, $0) }, uniquingKeysWith: { first, _ in first })
        let fallback = [boxes.inbox]

        var buckets: [String: FolderSortPlan.Bucket] = [:]
        for email in emails {
            let sender = email.from?.first?.normalized ?? ""
            let elsewhere = (email.mailboxIds ?? [:]).filter { $0.value && $0.key != sourceId }.map(\.key).sorted()
            // Already filed somewhere else too: just drop it from the source folder.
            let (destination, reason) = elsewhere.isEmpty
                ? SortingInference.decide(for: sender, rule: rules[sender], suggestion: suggestions[sender],
                                          isOwn: own.contains(sender), mailboxes: boxes, fallback: fallback)
                : ([], .alreadyFiled(in: elsewhere))
            let item = FolderSortPlan.Item(id: email.id, subject: email.subject ?? "", senderName: email.from?.first?.name,
                                           senderEmail: sender, receivedAt: email.receivedAt, reason: reason)
            buckets[destination.joined(separator: "+"), default: .init(destination: destination, items: [])].items.append(item)
        }
        return FolderSortPlan(sourceId: sourceId,
                              buckets: buckets.values.sorted { $0.messageIds.count > $1.messageIds.count },
                              ownAddresses: own.sorted())
    }

    /// Moves every message out of the plan's source folder into its destination.
    public func execute(_ plan: FolderSortPlan,
                        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws {
        var done = 0
        for bucket in plan.buckets {
            for chunk in bucket.messageIds.chunked(into: 500) {
                var patch = Router.move(from: [plan.sourceId], to: bucket.destination)
                // Already sorted: keeps recent mail moved into the Inbox out of the Screener.
                patch["keywords/\(Keyword.routed)"] = true
                try await apply(Dictionary(uniqueKeysWithValues: chunk.map { ($0, patch) }))
                done += chunk.count
                progress(done, plan.total)
            }
        }
        try await syncMailboxes()
    }

    /// Deletes a folder, refusing if it still holds mail.
    public func deleteMailbox(_ id: String) async throws {
        let accountId = try await client.accountId()
        let response = try await client.perform([
            MethodCall("Mailbox/set", [
                "accountId": .string(accountId),
                "destroy": [.string(id)],
                "onDestroyRemoveEmails": false,
            ], id: "destroy"),
        ])
        try response.result("destroy", as: SetResponse.self).throwIfFailed("delete the folder")
        try await store.setValue(nil, for: Key.mailboxState)
        try await syncMailboxes()
    }

    private func fetchAll(inMailbox mailboxId: String, accountId: String, properties: [String],
                          progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [Email] {
        var ids: [String] = []
        var total = 0
        repeat {
            let response = try await client.perform([
                MethodCall("Email/query", [
                    "accountId": .string(accountId),
                    "filter": ["inMailbox": .string(mailboxId)],
                    "sort": [["property": "receivedAt", "isAscending": false]],
                    "position": .int(ids.count),
                    "limit": 1000,
                    "calculateTotal": true,
                ], id: "q"),
            ])
            let page = try response.result("q", as: QueryResponse.self)
            total = page.total ?? ids.count + page.ids.count
            ids += page.ids
            if page.ids.isEmpty { break }
        } while ids.count < total

        var emails: [Email] = []
        for chunk in ids.chunked(into: 500) {
            let response = try await client.perform([
                MethodCall("Email/get", [
                    "accountId": .string(accountId),
                    "ids": .strings(chunk),
                    "properties": .strings(properties),
                ], id: "get"),
            ])
            emails += try response.result("get", as: GetResponse<Email>.self).list
            progress(emails.count, ids.count)
        }
        return emails
    }

    // MARK: - Search

    public struct SearchResult: Sendable {
        public var messages: [MessageRecord]
        public var snippets: [String: SearchSnippet]
        public var total: Int?
    }

    /// Server-side search. Results are cached locally so they can be opened.
    public func search(_ query: SearchQuery, limit: Int = 100) async throws -> SearchResult {
        let mailboxList = try await store.mailboxes()
        let byName = Dictionary(mailboxList.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { first, _ in first })
        guard let filter = query.jmapFilter(mailboxIdsByName: byName) else {
            return SearchResult(messages: [], snippets: [:], total: 0)
        }
        let accountId = try await client.accountId()
        let response = try await client.perform([
            MethodCall("Email/query", [
                "accountId": .string(accountId),
                "filter": filter,
                "sort": [["property": "receivedAt", "isAscending": false]],
                "limit": .int(limit),
                "calculateTotal": true,
            ], id: "q"),
            MethodCall("Email/get", [
                "accountId": .string(accountId),
                "#ids": MethodCall.reference(to: "q", name: "Email/query", path: "/ids"),
                "properties": .strings(Email.listProperties),
            ], id: "get"),
            MethodCall("SearchSnippet/get", [
                "accountId": .string(accountId),
                "filter": filter,
                "#emailIds": MethodCall.reference(to: "q", name: "Email/query", path: "/ids"),
            ], id: "snip"),
        ])
        let query = try response.result("q", as: QueryResponse.self)
        let emails = try response.result("get", as: GetResponse<Email>.self).list
        try await storeServerEmails(emails)
        struct Snippets: Decodable { var list: [SearchSnippet] }
        let snippets = (try? response.result("snip", as: Snippets.self).list) ?? []
        let byId = Dictionary(emails.map { ($0.id, MessageRecord($0)) }, uniquingKeysWith: { first, _ in first })
        return SearchResult(
            messages: query.ids.compactMap { byId[$0] },
            snippets: Dictionary(snippets.map { ($0.emailId, $0) }, uniquingKeysWith: { first, _ in first }),
            total: query.total
        )
    }

    // MARK: - Bubble Up

    /// Brings `message`'s conversation back to the top at `date`: sends you a
    /// note in the same conversation, held by Fastmail until then.
    @discardableResult
    public func bubbleUp(_ message: MessageRecord, at date: Date) async throws -> BubbleUp {
        guard let boxes = mailboxes, let drafts = boxes.drafts, let identity = identities.first else {
            throw JMAPError.missingResponse("identity or drafts mailbox")
        }
        guard let messageId = message.messageIdHeader else { throw BubbleUpError.noMessageId }
        let hold = Int(date.timeIntervalSinceNow.rounded(.up))
        guard hold >= 60 else { throw BubbleUpError.tooSoon }
        let longest = await maxDelayedSend()
        guard longest > 0 else { throw BubbleUpError.unsupported }
        guard hold <= longest else { throw BubbleUpError.tooFar(days: longest / 86_400) }

        let accountId = try await client.accountId()
        let me: JSONValue = [["name": .string(identity.name), "email": .string(identity.email)]]
        let sender = message.fromName.flatMap { $0.isEmpty ? nil : $0 } ?? message.fromEmail
        let note: [String: JSONValue] = [
            "mailboxIds": [drafts: true],
            "keywords": [Keyword.seen: true, Keyword.bubble: true],
            "from": me,
            "to": me,
            // The same subject and headers keep it in the original conversation.
            "subject": .string(message.subject),
            "inReplyTo": [.string(messageId)],
            "references": .strings(message.references + [messageId]),
            "header:\(BubbleUp.header):asText": .string(messageId),
            "bodyValues": ["body": ["value": .string(
                "Bubbled up with Sift: “\(message.subject)” from \(sender), \(message.receivedAt.formatted(date: .abbreviated, time: .shortened))."
            )]],
            "textBody": [["partId": "body", "type": "text/plain"]],
        ]
        let response = try await client.perform([
            MethodCall("Email/set", ["accountId": .string(accountId), "create": ["note": .object(note)]], id: "note"),
            MethodCall("EmailSubmission/set", [
                "accountId": .string(accountId),
                "create": ["send": [
                    "identityId": .string(identity.id),
                    "emailId": "#note",
                    "envelope": [
                        "mailFrom": ["email": .string(identity.email), "parameters": ["HOLDFOR": .string(String(hold))]],
                        "rcptTo": [["email": .string(identity.email), "parameters": .null]],
                    ],
                ]],
                // Fastmail keeps its own copy to deliver; no outgoing copy in Sent or Drafts.
                "onSuccessDestroyEmail": ["#send"],
            ], id: "send"),
        ], using: [JMAPCapability.core, JMAPCapability.mail, JMAPCapability.submission])
        try response.result("note", name: "Email/set", as: SetResponse.self).throwIfFailed("schedule Bubble Up")
        let submitted = try response.result("send", name: "EmailSubmission/set", as: SetResponse.self)
        try submitted.throwIfFailed("schedule Bubble Up")
        guard let submissionId = submitted.created?["send"]?["id"]?.stringValue else {
            throw JMAPError.missingResponse("EmailSubmission/set")
        }
        let bubble = BubbleUp(submissionId: submissionId, threadId: message.threadId, at: date)
        var pending = try await store.read(.bubbleUps)
        pending.removeAll { $0.threadId == bubble.threadId }
        pending.append(bubble)
        try await store.setBubbleUps(pending)
        return bubble
    }

    /// Stops a Bubble Up before it happens.
    public func cancel(_ bubble: BubbleUp) async throws {
        let accountId = try await client.accountId()
        let response = try await client.perform([
            MethodCall("EmailSubmission/set", [
                "accountId": .string(accountId),
                "update": [bubble.submissionId: ["undoStatus": "canceled"]],
            ], id: "cancel"),
        ], using: [JMAPCapability.core, JMAPCapability.mail, JMAPCapability.submission])
        let result = try response.result("cancel", as: SetResponse.self)
        if result.notUpdated?[bubble.submissionId] == nil { try result.throwIfFailed("cancel Bubble Up") }
        var pending = try await store.read(.bubbleUps)
        pending.removeAll { $0.submissionId == bubble.submissionId }
        try await store.setBubbleUps(pending)
    }

    /// Mirrors the Bubble Ups still waiting in Fastmail, so every device shows
    /// them: held messages to yourself, more than a minute out (Undo Send
    /// holds are shorter).
    public func syncBubbleUps() async throws {
        struct Submission: Decodable {
            struct Envelope: Decodable { struct Address: Decodable { var email: String }; var rcptTo: [Address] }
            var id: String
            var threadId: String?
            var sendAt: Date?
            var envelope: Envelope?
        }
        let accountId = try await client.accountId()
        let response = try await client.perform([
            MethodCall("EmailSubmission/query", [
                "accountId": .string(accountId),
                "filter": ["undoStatus": "pending"],
            ], id: "q"),
            MethodCall("EmailSubmission/get", [
                "accountId": .string(accountId),
                "#ids": MethodCall.reference(to: "q", name: "EmailSubmission/query", path: "/ids"),
                "properties": .strings(["id", "threadId", "sendAt", "envelope"]),
            ], id: "get"),
        ], using: [JMAPCapability.core, JMAPCapability.mail, JMAPCapability.submission])
        let submissions = try response.result("get", as: GetResponse<Submission>.self).list
        let own = Set(identities.map { $0.email.lowercased() })
        let soon = Date.now.addingTimeInterval(60)
        let known = Dictionary(try await store.read(.bubbleUps).map { ($0.submissionId, $0) }, uniquingKeysWith: { first, _ in first })
        let pending = submissions.compactMap { submission -> BubbleUp? in
            guard let at = submission.sendAt, at > soon,
                  let rcpt = submission.envelope?.rcptTo, !rcpt.isEmpty,
                  rcpt.allSatisfy({ own.contains($0.email.lowercased()) }),
                  let threadId = known[submission.id]?.threadId ?? submission.threadId else { return nil }
            return BubbleUp(submissionId: submission.id, threadId: threadId, at: at)
        }
        try await store.setBubbleUps(pending)
    }

    /// A Bubble Up note has arrived: hide it, and make the original unread
    /// again so the conversation comes back like new mail.
    func receiveBubbleUps(among created: [String]) async throws {
        let own = Set(identities.map { $0.email.lowercased() })
        let candidates = try await store.messages(ids: created)
            .filter { own.contains($0.fromEmail) && !$0.isBubble && !$0.isDraft }
        guard !candidates.isEmpty else { return }
        struct Note: Decodable {
            var id: String
            var threadId: String?
            var original: String?
            enum CodingKeys: String, CodingKey {
                case id, threadId
                case original = "header:X-Sift-Bubble-Up:asText"
            }
        }
        let accountId = try await client.accountId()
        let response = try await client.perform([
            MethodCall("Email/get", [
                "accountId": .string(accountId),
                "ids": .strings(candidates.map(\.id)),
                "properties": .strings(["id", "threadId", "header:\(BubbleUp.header):asText"]),
            ], id: "notes"),
        ])
        let notes = try response.result("notes", as: GetResponse<Note>.self).list
            .filter { !($0.original ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
        guard !notes.isEmpty else { return }

        var patches: [String: EmailPatch] = [:]
        for note in notes {
            patches[note.id] = ["keywords/\(Keyword.seen)": true, "keywords/\(Keyword.bubble)": true]
            let marker = note.original?.trimmingCharacters(in: .whitespaces)
            let thread = try await store.read(.thread(note.threadId ?? ""))
            let original = thread.last { $0.messageIdHeader == marker } ?? thread.last { !$0.isBubble && $0.id != note.id }
            if let original { patches[original.id] = ["keywords/\(Keyword.seen)": .null] }
        }
        try await apply(patches)
        var pending = try await store.read(.bubbleUps)
        let arrived = Set(notes.compactMap(\.threadId))
        pending.removeAll { arrived.contains($0.threadId) && $0.at <= .now.addingTimeInterval(60) }
        try await store.setBubbleUps(pending)
    }

    // MARK: - Sending and drafts

    /// The longest Fastmail will hold a message before delivering it (its
    /// FUTURERELEASE support), which is what lets Undo Send call it back.
    public func maxDelayedSend() async -> Int {
        let session = try? await client.session()
        guard case .object(let submission)? = session?.capabilities[JMAPCapability.submission],
              case .int(let seconds)? = submission["maxDelayedSend"] else { return 0 }
        return seconds
    }

    /// Saves (or re-saves) a draft in Drafts and returns its new id. Fastmail
    /// messages can't be edited, so a new version replaces the old one.
    @discardableResult
    public func saveDraft(_ message: OutgoingMessage) async throws -> String {
        let (accountId, email) = try await draftObject(for: message)
        var arguments: [String: JSONValue] = ["accountId": .string(accountId), "create": ["draft": .object(email)]]
        if let old = message.draftId { arguments["destroy"] = [.string(old)] }
        let response = try await client.perform([MethodCall("Email/set", arguments, id: "save")])
        let result = try response.result("save", as: SetResponse.self)
        try result.throwIfFailed("save the draft")
        guard let id = result.created?["draft"]?["id"]?.stringValue else { throw JMAPError.missingResponse("Email/set draft") }
        // The old version is gone from Fastmail; drop it here too so no one reads it.
        if let old = message.draftId { try await store.delete(messageIds: [old]) }
        return id
    }

    public func discardDraft(_ id: String) async throws {
        let accountId = try await client.accountId()
        let response = try await client.perform([
            MethodCall("Email/set", ["accountId": .string(accountId), "destroy": [.string(id)]], id: "discard"),
        ])
        try response.result("discard", as: SetResponse.self).throwIfFailed("delete the draft")
        try await store.delete(messageIds: [id])
    }

    /// Sends a message. With `holdFor` (seconds, up to `maxDelayedSend()`),
    /// Fastmail keeps it that long first, so `cancel(_:)` can still stop it.
    @discardableResult
    public func send(_ message: OutgoingMessage, holdFor hold: Int = 0) async throws -> Sending {
        guard let boxes = mailboxes, let drafts = boxes.drafts, let sent = boxes.sent else {
            throw JMAPError.missingResponse("drafts or sent mailbox")
        }
        guard let identity = identities.first(where: { $0.id == message.identityId }) else { throw SendError.noIdentity }
        guard !message.recipients.isEmpty else { throw SendError.noRecipients }
        let (accountId, email) = try await draftObject(for: message)
        var create: [String: JSONValue] = ["accountId": .string(accountId), "create": ["draft": .object(email)]]
        if let old = message.draftId { create["destroy"] = [.string(old)] }

        var submission: [String: JSONValue] = ["identityId": .string(identity.id), "emailId": "#draft"]
        let held = hold > 0 ? min(hold, await maxDelayedSend()) : 0
        if held > 0 {
            submission["envelope"] = [
                "mailFrom": ["email": .string(identity.email), "parameters": ["HOLDFOR": .string(String(held))]],
                "rcptTo": .array(message.recipients.map { ["email": .string($0.email ?? ""), "parameters": .null] }),
            ]
        }
        var calls = [
            MethodCall("Email/set", create, id: "draft"),
            MethodCall("EmailSubmission/set", [
                "accountId": .string(accountId),
                "create": ["send": .object(submission)],
                "onSuccessUpdateEmail": ["#send": [
                    "mailboxIds/\(drafts)": .null,
                    "mailboxIds/\(sent)": true,
                    "keywords/\(Keyword.draft)": .null,
                ]],
            ], id: "submit"),
        ]
        if let answering = message.answering {
            calls.append(MethodCall("Email/set", [
                "accountId": .string(accountId),
                "update": [answering: ["keywords/\(Keyword.answered)": true]],
            ], id: "answered"))
        }
        let response = try await client.perform(calls, using: [JMAPCapability.core, JMAPCapability.mail, JMAPCapability.submission])
        let saved = try response.result("draft", name: "Email/set", as: SetResponse.self)
        try saved.throwIfFailed("save the outgoing message")
        let submitted = try response.result("submit", name: "EmailSubmission/set", as: SetResponse.self)
        try submitted.throwIfFailed("send the message")
        guard let emailId = saved.created?["draft"]?["id"]?.stringValue,
              let submissionId = submitted.created?["send"]?["id"]?.stringValue else {
            throw JMAPError.missingResponse("EmailSubmission/set")
        }
        try await store.recordSentRecipients(message.recipients.map(\.normalized))
        try? await refresh()
        return Sending(emailId: emailId, submissionId: submissionId, heldFor: held)
    }

    /// Undo Send: stops a held message and puts it back in Drafts.
    public func cancel(_ sending: Sending) async throws {
        guard sending.heldFor > 0, let boxes = mailboxes, let drafts = boxes.drafts else { throw SendError.tooLateToUndo }
        let accountId = try await client.accountId()
        let response = try await client.perform([
            MethodCall("EmailSubmission/set", [
                "accountId": .string(accountId),
                "update": [sending.submissionId: ["undoStatus": "canceled"]],
            ], id: "cancel"),
        ], using: [JMAPCapability.core, JMAPCapability.mail, JMAPCapability.submission])
        let result = try response.result("cancel", as: SetResponse.self)
        if result.notUpdated?[sending.submissionId] != nil { throw SendError.tooLateToUndo }
        try result.throwIfFailed("undo sending")
        var patch: EmailPatch = ["mailboxIds/\(drafts)": true, "keywords/\(Keyword.draft)": true]
        if let sent = boxes.sent { patch["mailboxIds/\(sent)"] = .null }
        try await apply([sending.emailId: patch])
    }

    /// A saved draft (or a message brought back by Undo Send), ready to edit.
    public func outgoingMessage(fromDraft id: String) async throws -> OutgoingMessage {
        let accountId = try await client.accountId()
        let response = try await client.perform([
            MethodCall("Email/get", [
                "accountId": .string(accountId),
                "ids": [.string(id)],
                "properties": .strings(["id", "from", "to", "cc", "bcc", "subject", "inReplyTo", "references",
                                        "textBody", "attachments", "bodyValues"]),
                "bodyProperties": .strings(["partId", "blobId", "size", "name", "type", "disposition"]),
                "fetchTextBodyValues": true,
            ], id: "draft"),
        ])
        guard let email = try response.result("draft", as: GetResponse<Email>.self).list.first else {
            throw JMAPError.missingResponse("Email/get draft")
        }
        let fromAddress = email.from?.first?.normalized
        let identity = identities.first { $0.email.lowercased() == fromAddress } ?? identities.first
        let text = (email.textBody ?? []).compactMap { $0.partId.flatMap { email.bodyValues?[$0]?.value } }.joined(separator: "\n")
        return OutgoingMessage(
            identityId: identity?.id ?? "",
            to: email.to ?? [], cc: email.cc ?? [], bcc: email.bcc ?? [],
            subject: email.subject ?? "", body: text,
            attachments: (email.attachments ?? []).compactMap { part in
                part.blobId.map { .init(blobId: $0, name: part.name ?? "Attachment", type: part.type ?? "application/octet-stream", size: part.size ?? 0) }
            },
            inReplyTo: email.inReplyTo ?? [], references: email.references ?? [],
            draftId: id
        )
    }

    /// Uploads a file to attach. Fastmail keeps unreferenced uploads for a day.
    public func upload(_ data: Data, name: String, type: String) async throws -> OutgoingMessage.Attachment {
        let blobId = try await client.upload(data, type: type)
        return .init(blobId: blobId, name: name, type: type, size: data.count)
    }

    /// The largest file Fastmail accepts in one upload, when it says.
    public func maxUploadSize() async -> Int? {
        let session = try? await client.session()
        guard case .object(let core)? = session?.capabilities[JMAPCapability.core],
              case .int(let size)? = core["maxSizeUpload"] else { return nil }
        return size
    }

    /// The Email/set create object for a message: in Drafts, marked $draft.
    private func draftObject(for message: OutgoingMessage) async throws -> (accountId: String, email: [String: JSONValue]) {
        guard let boxes = mailboxes, let drafts = boxes.drafts else { throw JMAPError.missingResponse("drafts mailbox") }
        let accountId = try await client.accountId()
        let identity = identities.first { $0.id == message.identityId } ?? identities.first
        func addresses(_ list: [EmailAddress]) -> JSONValue {
            .array(list.map { ["name": $0.name.map(JSONValue.string) ?? .null, "email": .string($0.email ?? "")] })
        }
        var email: [String: JSONValue] = [
            "mailboxIds": [drafts: true],
            "keywords": [Keyword.draft: true, Keyword.seen: true],
            "subject": .string(message.subject),
            "bodyValues": ["body": ["value": .string(message.body)]],
            "textBody": [["partId": "body", "type": "text/plain"]],
        ]
        if let identity { email["from"] = [["name": .string(identity.name), "email": .string(identity.email)]] }
        if !message.to.isEmpty { email["to"] = addresses(message.to) }
        if !message.cc.isEmpty { email["cc"] = addresses(message.cc) }
        if !message.bcc.isEmpty { email["bcc"] = addresses(message.bcc) }
        if !message.inReplyTo.isEmpty { email["inReplyTo"] = .strings(message.inReplyTo) }
        if !message.references.isEmpty { email["references"] = .strings(message.references) }
        if !message.attachments.isEmpty {
            email["attachments"] = .array(message.attachments.map {
                ["blobId": .string($0.blobId), "type": .string($0.type), "name": .string($0.name), "disposition": "attachment"]
            })
        }
        return (accountId, email)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
