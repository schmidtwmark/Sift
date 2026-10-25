import CryptoKit
import Foundation

/// Persists sender rules in Fastmail Contacts (JMAP Contacts, RFC 9610) so every
/// device — and Fastmail itself — sees the same screening decisions.
///
/// Fastmail doesn't let apps create address books, so Sift keeps a handful of
/// group cards in the user's default address book: "Sift: Screened In",
/// "Sift: Screened Out", "Sift: Notify", "Sift: Badge", and one
/// "Sift label: <name>" group per label. Senders are stored as `mailto:` members
/// (vCard MEMBER URIs), so no contact card is created per sender. Members the
/// user adds as real contacts in Fastmail's UI are honoured too. A label's
/// custom icon is a note on its group ("Sift icon: airplane").
public actor ContactsRuleStore {
    enum Group: Hashable {
        case screenedIn, screenedOut, notify, badge
        case label(mailboxId: String)

        var uid: String {
            switch self {
            case .screenedIn: ContactsRuleStore.uid(for: "group:screened-in")
            case .screenedOut: ContactsRuleStore.uid(for: "group:screened-out")
            case .notify: ContactsRuleStore.uid(for: "group:notify")
            case .badge: ContactsRuleStore.uid(for: "group:badge")
            case .label(let id): ContactsRuleStore.uid(for: "group:label:\(id)")
            }
        }

        func displayName(labelName: String?) -> String {
            switch self {
            case .screenedIn: "Sift: Screened In"
            case .screenedOut: "Sift: Screened Out"
            case .notify: "Sift: Notify"
            case .badge: "Sift: Badge"
            case .label: "Sift label: \(labelName ?? "Label")"
            }
        }

        static let fixed: [Group] = [.screenedIn, .screenedOut, .notify, .badge]
    }

    struct Card: Codable, Sendable {
        struct Name: Codable, Sendable { var full: String? }
        struct Email: Codable, Sendable { var address: String }
        struct Note: Codable, Sendable { var note: String }

        var id: String
        var uid: String
        var kind: String?
        var name: Name?
        var emails: [String: Email]?
        var members: [String: Bool]?
        var addressBookIds: [String: Bool]?
        var notes: [String: Note]?
    }

    struct AddressBook: Codable, Sendable {
        var id: String
        var name: String
        var isDefault: Bool?
    }

    private let client: JMAPClient
    private var addressBookId: String?
    /// Sift's groups as last fetched: uid → group, card id, and raw member keys.
    private var groups: [String: Group] = [:]
    private var groupCardIds: [String: String] = [:]
    private var groupMembers: [String: Set<String>] = [:]
    /// Group uid → the keys of its notes, and which one holds Sift's icon.
    private var groupNoteKeys: [String: Set<String>] = [:]
    private var groupIconNoteKey: [String: String] = [:]
    /// Contact card uid → its addresses and name, to resolve contacts the user
    /// put in a Sift group by hand.
    private var cardAddresses: [String: [String]] = [:]
    private var cardNames: [String: String] = [:]
    /// Everyone in the user's address books; they skip the Screener.
    public private(set) var contactAddresses: Set<String> = []
    /// Mailbox id → SF Symbol chosen for that label.
    public private(set) var labelIcons: [String: String] = [:]
    public private(set) var state: String?

    private static let capabilities = [JMAPCapability.core, JMAPCapability.contacts]

    public init(client: JMAPClient) {
        self.client = client
    }

    /// The group member key for an address: a vCard MEMBER URI.
    static func memberKey(for email: String) -> String { "mailto:\(email.lowercased())" }

    // MARK: - Loading

    /// Fetches every card and returns the decoded sender rules. `mailboxIds`
    /// are the account's mailboxes, used to recognise label groups by uid.
    public func load(mailboxIds: [String]) async throws -> [SenderRecord] {
        let accountId = try await contactsAccountId()
        _ = try await defaultAddressBook(accountId: accountId)

        var allCards: [Card] = []
        let pageSize = 500
        while true {
            let response = try await client.perform([
                MethodCall("ContactCard/query", [
                    "accountId": .string(accountId),
                    "position": .int(allCards.count),
                    "limit": .int(pageSize),
                ], id: "query"),
                MethodCall("ContactCard/get", [
                    "accountId": .string(accountId),
                    "#ids": MethodCall.reference(to: "query", name: "ContactCard/query", path: "/ids"),
                    "properties": .strings(["id", "uid", "kind", "name", "emails", "members", "addressBookIds", "notes"]),
                ], id: "cards"),
            ], using: Self.capabilities)
            let page = try response.result("cards", as: GetResponse<Card>.self)
            if allCards.isEmpty { state = page.state }
            allCards += page.list
            if page.list.count < pageSize { break }
        }

        let known = Group.fixed + mailboxIds.map { Group.label(mailboxId: $0) }
        let byUid = Dictionary(known.map { ($0.uid, $0) }, uniquingKeysWith: { first, _ in first })
        groups = [:]
        groupCardIds = [:]
        groupMembers = [:]
        groupNoteKeys = [:]
        groupIconNoteKey = [:]
        labelIcons = [:]
        cardAddresses = [:]
        cardNames = [:]
        contactAddresses = []

        for card in allCards {
            if card.kind == "group" {
                guard let group = byUid[card.uid] else { continue }
                groups[card.uid] = group
                groupCardIds[card.uid] = card.id
                groupMembers[card.uid] = Set((card.members ?? [:]).filter(\.value).keys)
                groupNoteKeys[card.uid] = Set((card.notes ?? [:]).keys)
                for (key, note) in card.notes ?? [:] {
                    guard let symbol = LabelIcon.parse(note: note.note) else { continue }
                    groupIconNoteKey[card.uid] = key
                    if case .label(let mailboxId) = group { labelIcons[mailboxId] = symbol }
                }
            } else {
                let addresses = (card.emails ?? [:]).values.map { $0.address.lowercased() }
                cardAddresses[card.uid] = addresses
                if let name = card.name?.full { cardNames[card.uid] = name }
                contactAddresses.formUnion(addresses)
            }
        }

        var rules: [String: SenderRecord] = [:]
        for (uid, members) in groupMembers {
            guard let group = groups[uid] else { continue }
            for key in members {
                for address in addresses(forMember: key) {
                    var rule = rules[address] ?? SenderRecord(email: address, name: cardNames[key])
                    switch group {
                    case .screenedIn: if rule.status != .screenedOut { rule.status = .screenedIn }
                    case .screenedOut: rule.status = .screenedOut
                    case .notify: rule.notify = true
                    case .badge: rule.badge = true
                    case .label(let id): rule.labelIds.append(id)
                    }
                    rules[address] = rule
                }
            }
        }
        return rules.values.map { rule in
            var rule = rule
            rule.labelIds.sort()
            return rule
        }
    }

    private func addresses(forMember key: String) -> [String] {
        if key.lowercased().hasPrefix("mailto:") { return [String(key.dropFirst(7)).lowercased()] }
        return cardAddresses[key] ?? []
    }

    // MARK: - Saving

    /// Writes one sender's rule. `labelNames` maps mailbox id → display name,
    /// used when a label group has to be created.
    public func save(_ rule: SenderRecord, labelNames: [String: String]) async throws {
        try await save([rule], labelNames: labelNames)
    }

    /// Writes many rules in one `ContactCard/set`.
    public func save(_ rules: [SenderRecord], labelNames: [String: String]) async throws {
        guard !rules.isEmpty else { return }
        let accountId = try await contactsAccountId()
        let bookId = try await defaultAddressBook(accountId: accountId)

        var updates: [String: [String: JSONValue]] = [:]   // group card id → patch
        var newGroups: [Group: [String: JSONValue]] = [:]  // group → members
        var membership: [(group: Group, add: [String], remove: [String])] = []

        for rule in rules {
            let key = Self.memberKey(for: rule.email)
            // Contacts the user added to a Sift group by hand, for this address.
            let cardKeys = cardAddresses.filter { $0.value.contains(rule.email) }.map(\.key)

            var desired: [Group: Bool] = [
                .screenedIn: rule.status == .screenedIn,
                .screenedOut: rule.status == .screenedOut,
                .notify: rule.notify,
                .badge: rule.badge,
            ]
            // Every label group the sender is in or should be in.
            for group in groups.values {
                if case .label = group { desired[group] = false }
            }
            for group in newGroups.keys {
                if case .label = group { desired[group] = desired[group] ?? false }
            }
            for mailboxId in rule.labelIds {
                desired[.label(mailboxId: mailboxId)] = true
            }

            for (group, shouldBeMember) in desired {
                let members = groupMembers[group.uid] ?? []
                let isMember = members.contains(key) || cardKeys.contains(where: members.contains)
                if let cardId = groupCardIds[group.uid] {
                    guard isMember != shouldBeMember else { continue }
                    if shouldBeMember {
                        updates[cardId, default: [:]]["members/\(Self.pointerEscape(key))"] = true
                        membership.append((group, [key], []))
                    } else {
                        let stale = ([key] + cardKeys).filter(members.contains)
                        for member in stale {
                            updates[cardId, default: [:]]["members/\(Self.pointerEscape(member))"] = .null
                        }
                        membership.append((group, [], stale))
                    }
                } else if shouldBeMember {
                    newGroups[group, default: [:]][key] = true
                    membership.append((group, [key], []))
                }
            }
        }
        guard !newGroups.isEmpty || !updates.isEmpty else { return }

        var create: [String: JSONValue] = [:]
        for (index, (group, members)) in newGroups.enumerated() {
            let labelName: String? = if case .label(let id) = group { labelNames[id] } else { nil }
            create["group-\(index)"] = [
                "@type": "Card", "version": "1.0", "kind": "group",
                "uid": .string(group.uid),
                "addressBookIds": [bookId: true],
                "name": ["full": .string(group.displayName(labelName: labelName))],
                "members": .object(members),
            ]
        }
        var arguments: [String: JSONValue] = ["accountId": .string(accountId)]
        if !create.isEmpty { arguments["create"] = .object(create) }
        if !updates.isEmpty { arguments["update"] = .object(updates.mapValues { .object($0) }) }
        let response = try await client.perform([MethodCall("ContactCard/set", arguments, id: "set")],
                                                using: Self.capabilities)
        let result = try response.result("set", as: SetResponse.self)
        let what = rules.count == 1 ? "the screening rule for \(rules[0].email)" : "\(rules.count) screening rules"
        do {
            try result.throwIfFailed("save \(what)")
        } catch let error as SetError where error.type == "invalidProperties" && (error.properties ?? []).contains("members") {
            throw ContactsRuleStoreError.addressMembersRejected(error.description)
        }
        state = result.newState

        // Mirror the write locally so the next save diffs correctly.
        for (createKey, value) in result.created ?? [:] {
            guard let id = value["id"]?.stringValue,
                  case .object(let card)? = create[createKey], let uid = card["uid"]?.stringValue else { continue }
            groupCardIds[uid] = id
        }
        for change in membership {
            groups[change.group.uid] = change.group
            groupMembers[change.group.uid, default: []].formUnion(change.add)
            groupMembers[change.group.uid]?.subtract(change.remove)
        }
    }

    // MARK: - Label icons

    /// Sets (or, with nil, clears) a label's icon. Creates the label's group if
    /// the label has no screening rules yet.
    public func setIcon(_ symbol: String?, forLabel mailboxId: String, labelName: String) async throws {
        let accountId = try await contactsAccountId()
        let bookId = try await defaultAddressBook(accountId: accountId)
        let group = Group.label(mailboxId: mailboxId)
        let note: JSONValue = symbol.map { ["@type": "Note", "note": .string(LabelIcon.note(for: $0))] } ?? .null

        var arguments: [String: JSONValue] = ["accountId": .string(accountId)]
        if let cardId = groupCardIds[group.uid] {
            let patch: [String: JSONValue]
            if let key = groupIconNoteKey[group.uid] {
                patch = ["notes/\(Self.pointerEscape(key))": note]
            } else if symbol == nil {
                return
            } else if groupNoteKeys[group.uid, default: []].isEmpty {
                patch = ["notes": ["sift-icon": note]]
            } else {
                patch = ["notes/sift-icon": note]
            }
            arguments["update"] = [cardId: .object(patch)]
        } else {
            guard symbol != nil else { return }
            arguments["create"] = ["icon-group": [
                "@type": "Card", "version": "1.0", "kind": "group",
                "uid": .string(group.uid),
                "addressBookIds": [bookId: true],
                "name": ["full": .string(group.displayName(labelName: labelName))],
                "notes": ["sift-icon": note],
            ]]
        }
        let response = try await client.perform([MethodCall("ContactCard/set", arguments, id: "set")],
                                                using: Self.capabilities)
        let result = try response.result("set", as: SetResponse.self)
        try result.throwIfFailed("save the icon for “\(labelName)”")
        state = result.newState

        // Mirror the write locally.
        if let id = result.created?["icon-group"]?["id"]?.stringValue {
            groupCardIds[group.uid] = id
            groups[group.uid] = group
            groupMembers[group.uid] = []
        }
        labelIcons[mailboxId] = symbol
        // Read the notes back: the server may store them under keys of its own,
        // and the next change has to patch the right one.
        guard let cardId = groupCardIds[group.uid] else { return }
        let readBack = try await client.perform([
            MethodCall("ContactCard/get", [
                "accountId": .string(accountId),
                "ids": .strings([cardId]),
                "properties": .strings(["id", "uid", "notes"]),
            ], id: "get"),
        ], using: Self.capabilities)
        if let card = try? readBack.result("get", as: GetResponse<Card>.self).list.first {
            let notes = card.notes ?? [:]
            groupNoteKeys[group.uid] = Set(notes.keys)
            groupIconNoteKey[group.uid] = notes.first { LabelIcon.parse(note: $0.value.note) != nil }?.key
        }
    }

    // MARK: - Helpers

    private func contactsAccountId() async throws -> String {
        let session = try await client.session()
        guard let id = session.primaryAccounts[JMAPCapability.contacts] else {
            throw ContactsRuleStoreError.contactsUnavailable
        }
        return id
    }

    private func defaultAddressBook(accountId: String) async throws -> String {
        if let addressBookId { return addressBookId }
        let response = try await client.perform([
            MethodCall("AddressBook/get", ["accountId": .string(accountId)], id: "books"),
        ], using: Self.capabilities)
        let books = try response.result("books", as: GetResponse<AddressBook>.self).list
        guard let book = books.first(where: { $0.isDefault == true }) ?? books.first else {
            throw ContactsRuleStoreError.noAddressBook
        }
        addressBookId = book.id
        return book.id
    }

    /// JSON Pointer escaping for a key inside a JMAP patch path.
    static func pointerEscape(_ key: String) -> String {
        key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    /// Stable `urn:uuid:` identifiers so devices agree on card uids without coordinating.
    static func uid(for key: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("sift:\(key)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80  // version 8 (custom)
        bytes[8] = (bytes[8] & 0x3F) | 0x80  // RFC 4122 variant
        let uuid = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return "urn:uuid:\(uuid.uuidString.lowercased())"
    }
}

public enum ContactsRuleStoreError: Error, LocalizedError, Equatable {
    case contactsUnavailable
    case noAddressBook
    case addressMembersRejected(String)

    public var errorDescription: String? {
        switch self {
        case .contactsUnavailable:
            "Your Fastmail API token doesn't include the Contacts scope, which Sift uses to sync screening decisions. Create a token with Email, Email submission and Contacts access."
        case .noAddressBook:
            "Your Fastmail account has no address book Sift can keep its screening groups in."
        case .addressMembersRejected(let detail):
            "Fastmail wouldn't store an email address in a Sift contact group (\(detail)). Nothing was moved; this screening decision wasn't saved."
        }
    }
}
