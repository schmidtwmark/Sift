import Foundation

/// The mailboxes Sift's views and routing depend on.
public struct SpecialMailboxes: Sendable, Hashable {
    public var inbox: String
    public var screener: String
    public var screenedOut: String
    public var archive: String?
    public var trash: String?
    public var junk: String?
    public var sent: String?
    public var drafts: String?

    public init(inbox: String, screener: String, screenedOut: String, archive: String? = nil, trash: String? = nil,
                junk: String? = nil, sent: String? = nil, drafts: String? = nil) {
        self.inbox = inbox
        self.screener = screener
        self.screenedOut = screenedOut
        self.archive = archive
        self.trash = trash
        self.junk = junk
        self.sent = sent
        self.drafts = drafts
    }

    /// Piles that never notify, badge, or count as "real" mail.
    public var quarantined: [String] { [screener, screenedOut] + [trash, junk].compactMap { $0 } }
}

/// A JMAP `Email/set` patch: `"mailboxIds/<id>": true|null`, `"keywords/<kw>": true|null`.
public typealias EmailPatch = [String: JSONValue]

public struct RoutingContext: Sendable {
    public var mailboxes: SpecialMailboxes
    /// Mail received before this moment is grandfathered and never screened.
    public var activatedAt: Date
    /// The user's own addresses (identities).
    public var ownAddresses: Set<String>
    /// People in the user's contacts or whom they've written to.
    public var knownAddresses: Set<String>
    public var rules: [String: SenderRecord]
    /// Spam whose sender address failed Fastmail's DMARC check: it may not be
    /// from them, so it stays in Spam even if they're screened in.
    public var unauthenticated: Set<String>

    public init(mailboxes: SpecialMailboxes, activatedAt: Date, ownAddresses: Set<String>,
                knownAddresses: Set<String>, rules: [String: SenderRecord], unauthenticated: Set<String> = []) {
        self.mailboxes = mailboxes
        self.activatedAt = activatedAt
        self.ownAddresses = ownAddresses
        self.knownAddresses = knownAddresses
        self.rules = rules
        self.unauthenticated = unauthenticated
    }
}

public struct RoutingPlan: Sendable {
    public var patches: [String: EmailPatch] = [:]
    /// Known-but-unruled senders (contacts, people you've written to) that should
    /// be recorded as screened in so every device agrees.
    public var autoApproved: [EmailAddress] = []
}

/// Decides where incoming mail goes. Pure, so it's shared by every device and
/// trivially testable; `SyncEngine` applies the plan.
public enum Router {
    public static func plan(for messages: [MessageRecord], context: RoutingContext) -> RoutingPlan {
        var plan = RoutingPlan()
        var approved: Set<String> = []
        let boxes = context.mailboxes

        for message in messages {
            guard !message.isRouted,
                  !message.isDraft,
                  message.receivedAt >= context.activatedAt else { continue }

            // Fastmail's spam filter runs before Sift sees anything. Mail from a
            // sender you screened in comes back out; the rest of Spam is left alone.
            if let junk = boxes.junk, message.mailboxIds.contains(junk) {
                guard let rule = context.rules[message.fromEmail], rule.status == .screenedIn else { continue }
                if context.unauthenticated.contains(message.id) {
                    plan.patches[message.id] = ["keywords/\(Keyword.routed)": true]
                } else {
                    plan.patches[message.id] = release(message, toLabels: rule.labelIds, mailboxes: boxes)
                }
                continue
            }
            guard message.mailboxIds.contains(boxes.inbox) else { continue }

            let sender = message.fromEmail
            var patch: EmailPatch = ["keywords/\(Keyword.routed)": true]

            if sender.isEmpty || context.ownAddresses.contains(sender) {
                // Your own mail (or something malformed) stays put.
            } else if let rule = context.rules[sender], rule.status != .unknown {
                if rule.status == .screenedOut {
                    patch.merge(move(from: [boxes.inbox], to: [boxes.screenedOut]), uniquingKeysWith: { $1 })
                    patch["keywords/\(Keyword.seen)"] = true
                } else {
                    patch.merge(file(intoLabels: rule.labelIds, inbox: boxes.inbox, from: boxes.inbox),
                                uniquingKeysWith: { $1 })
                }
            } else if context.knownAddresses.contains(sender) {
                if approved.insert(sender).inserted {
                    plan.autoApproved.append(message.sender)
                }
            } else {
                patch.merge(move(from: [boxes.inbox], to: [boxes.screener]), uniquingKeysWith: { $1 })
            }
            plan.patches[message.id] = patch
        }
        return plan
    }

    /// Patches that release a sender's waiting mail from the Screener into `labels`
    /// (or the Inbox when no labels are chosen).
    public static func screenIn(_ messages: [MessageRecord], labels: [String], mailboxes: SpecialMailboxes) -> [String: EmailPatch] {
        var patches: [String: EmailPatch] = [:]
        for message in messages {
            patches[message.id] = file(intoLabels: labels, inbox: mailboxes.inbox, from: mailboxes.screener)
        }
        return patches
    }

    /// Takes a message out of Spam into `labels` (the Inbox when empty), and
    /// tells Fastmail's filter it wasn't spam.
    public static func release(_ message: MessageRecord, toLabels labels: [String], mailboxes: SpecialMailboxes) -> EmailPatch {
        let destinations = labels.isEmpty ? [mailboxes.inbox] : labels
        var patch = move(from: [mailboxes.junk].compactMap { $0 }, to: destinations)
        patch["keywords/\(Keyword.notJunk)"] = true
        patch["keywords/\(Keyword.junk)"] = .null
        patch["keywords/\(Keyword.routed)"] = true
        return patch
    }

    /// Whether the receiving server's verdict (the topmost Authentication-Results,
    /// which Fastmail adds on arrival) says the From address failed DMARC.
    public static func failedDMARC(_ authenticationResults: [String]) -> Bool {
        guard let fastmail = authenticationResults.first else { return false }
        return fastmail.lowercased().range(of: #"\bdmarc=fail\b"#, options: .regularExpression) != nil
    }

    public static func screenOut(_ messages: [MessageRecord], mailboxes: SpecialMailboxes) -> [String: EmailPatch] {
        var patches: [String: EmailPatch] = [:]
        for message in messages {
            var patch = move(from: message.mailboxIds, to: [mailboxes.screenedOut])
            patch["keywords/\(Keyword.seen)"] = true
            patches[message.id] = patch
        }
        return patches
    }

    static func file(intoLabels labels: [String], inbox: String, from source: String) -> EmailPatch {
        let destinations = labels.isEmpty ? [inbox] : labels
        return move(from: [source], to: destinations)
    }

    static func move(from sources: [String], to destinations: [String]) -> EmailPatch {
        var patch: EmailPatch = [:]
        for id in sources where !destinations.contains(id) {
            patch["mailboxIds/\(id)"] = .null
        }
        for id in destinations {
            patch["mailboxIds/\(id)"] = true
        }
        return patch
    }
}

public extension MessageRecord {
    /// Applies a JMAP patch locally, for optimistic UI updates.
    func applying(_ patch: EmailPatch) -> MessageRecord {
        var copy = self
        var mailboxes = Set(mailboxIds)
        for (path, value) in patch {
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let isOn = value != .null && value != .bool(false)
            switch parts[0] {
            case "mailboxIds":
                if isOn { mailboxes.insert(parts[1]) } else { mailboxes.remove(parts[1]) }
            case "keywords":
                copy.setKeyword(parts[1], isOn)
            default:
                break
            }
        }
        copy.mailboxIds = mailboxes.sorted()
        return copy
    }
}
