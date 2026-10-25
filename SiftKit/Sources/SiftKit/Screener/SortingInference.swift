import Foundation

/// A screening rule inferred from where the user already files a sender's mail.
public struct RuleSuggestion: Sendable, Hashable, Identifiable {
    public var id: String { email }
    public var email: String
    public var name: String?
    public var status: SenderRecord.Status
    /// Folders new mail should go to; empty means the Inbox.
    public var labelIds: [String]
    /// How many messages the suggestion is based on.
    public var evidence: Int

    public var rule: SenderRecord {
        SenderRecord(email: email, name: name, status: status, labelIds: labelIds)
    }
}

/// Why a message in a folder being sorted goes where it does.
public enum SortReason: Sendable, Hashable {
    /// It's in other folders too (these), so it only leaves the one being sorted.
    case alreadyFiled(in: [String])
    /// Sent from one of your addresses (this one), so it goes to Sent.
    case ownMail(String)
    /// The sender's screening rule.
    case rule(SenderRecord.Status)
    /// Where most of the sender's other mail is filed; `evidence` messages.
    case history(SenderRecord.Status, evidence: Int)
    /// No rule and no other filed mail from the sender: the Inbox.
    case noHistory
}

/// Infers per-sender filing from existing mail. Pure, so it's shared by rule
/// suggestions and folder sorting, and unit-tested.
public enum SortingInference {
    public struct Inputs: Sendable {
        public var mailboxes: SpecialMailboxes
        /// The user's own folders (no system role, not Screener/Screened Out).
        public var userLabels: Set<String>
        /// Mailboxes whose contents say nothing about intent (an unsorted import, Drafts…).
        public var ignored: Set<String>
        public var ownAddresses: Set<String>

        public init(mailboxes: SpecialMailboxes, userLabels: Set<String>, ignored: Set<String>, ownAddresses: Set<String>) {
            self.mailboxes = mailboxes
            self.userLabels = userLabels
            self.ignored = ignored
            self.ownAddresses = ownAddresses
        }
    }

    /// A sender's mail counts toward a folder when at least this share of it is filed there.
    static let majority = 0.5
    static let junkShare = 0.8

    public static func suggestions(from messages: [MessageRecord], inputs: Inputs,
                                   existing: [String: SenderRecord] = [:]) -> [RuleSuggestion] {
        let boxes = inputs.mailboxes
        let skip = inputs.ignored.union([boxes.screener, boxes.screenedOut, boxes.trash, boxes.sent, boxes.drafts].compactMap { $0 })

        struct Tally {
            var name: String?
            var total = 0
            var labels: [String: Int] = [:]
            var inboxOrArchive = 0
            var junk = 0
        }
        var tallies: [String: Tally] = [:]
        for message in messages {
            let sender = message.fromEmail
            guard !sender.isEmpty, !inputs.ownAddresses.contains(sender),
                  existing[sender].map({ $0.status == .unknown }) ?? true,
                  !message.mailboxIds.contains(where: skip.contains) else { continue }
            var tally = tallies[sender] ?? Tally()
            if tally.name == nil, let name = message.fromName, !name.isEmpty { tally.name = name }
            tally.total += 1
            let labels = message.mailboxIds.filter(inputs.userLabels.contains)
            for label in labels { tally.labels[label, default: 0] += 1 }
            if labels.isEmpty {
                if message.mailboxIds.contains(boxes.inbox) || boxes.archive.map(message.mailboxIds.contains) == true {
                    tally.inboxOrArchive += 1
                }
                if let junk = boxes.junk, message.mailboxIds.contains(junk) { tally.junk += 1 }
            }
            tallies[sender] = tally
        }

        return tallies.compactMap { email, tally -> RuleSuggestion? in
            let total = Double(tally.total)
            if tally.total >= 2, Double(tally.junk) / total >= junkShare {
                return RuleSuggestion(email: email, name: tally.name, status: .screenedOut, labelIds: [], evidence: tally.total)
            }
            let labels = tally.labels.filter { Double($0.value) / total >= majority }.map(\.key).sorted()
            if !labels.isEmpty {
                return RuleSuggestion(email: email, name: tally.name, status: .screenedIn, labelIds: labels, evidence: tally.total)
            }
            if Double(tally.inboxOrArchive) / total >= majority {
                return RuleSuggestion(email: email, name: tally.name, status: .screenedIn, labelIds: [], evidence: tally.total)
            }
            return nil
        }
        .sorted { $0.evidence != $1.evidence ? $0.evidence > $1.evidence : $0.email < $1.email }
    }

    /// Where an old message from `sender` belongs: the sender's folders, or the
    /// Inbox when they're screened in without one or there's nothing to go on.
    public static func destination(for sender: String, rule: SenderRecord?, suggestion: RuleSuggestion?,
                                   isOwn: Bool, mailboxes: SpecialMailboxes, fallback: [String]) -> [String] {
        decide(for: sender, rule: rule, suggestion: suggestion, isOwn: isOwn, mailboxes: mailboxes, fallback: fallback).destination
    }

    /// `destination(for:…)`, plus why, for the folder-sort preview.
    public static func decide(for sender: String, rule: SenderRecord?, suggestion: RuleSuggestion?,
                              isOwn: Bool, mailboxes: SpecialMailboxes,
                              fallback: [String]) -> (destination: [String], reason: SortReason) {
        if isOwn, let sent = mailboxes.sent { return ([sent], .ownMail(sender)) }
        // An explicit rule beats an inferred one.
        let decision: (status: SenderRecord.Status, labels: [String], reason: SortReason)
        if let rule, rule.status != .unknown {
            decision = (rule.status, rule.labelIds, .rule(rule.status))
        } else if let suggestion {
            decision = (suggestion.status, suggestion.labelIds, .history(suggestion.status, evidence: suggestion.evidence))
        } else {
            return (fallback, .noHistory)
        }
        switch decision.status {
        case .screenedOut:
            return ([mailboxes.screenedOut], decision.reason)
        case .screenedIn:
            let filed = decision.labels.filter { $0 != mailboxes.inbox }
            return (filed.isEmpty ? [mailboxes.inbox] : filed, decision.reason)
        case .unknown:
            return (fallback, .noHistory)
        }
    }

    /// The address that receives most of a folder's mail, when it clearly
    /// dominates: in an import from another provider, that's the user's old address.
    public static func dominantRecipient(of emails: [Email], minimumShare: Double = 0.25) -> String? {
        var counts: [String: Int] = [:]
        for email in emails {
            for address in Set(email.recipients.map(\.normalized)) where !address.isEmpty {
                counts[address, default: 0] += 1
            }
        }
        guard let (address, count) = counts.max(by: { $0.value < $1.value }),
              Double(count) / Double(max(emails.count, 1)) >= minimumShare else { return nil }
        return address
    }
}
