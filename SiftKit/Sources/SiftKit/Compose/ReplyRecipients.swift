import Foundation

/// Who a reply goes to.
public enum ReplyRecipients {
    /// A reply goes to the sender (or their Reply-To); Reply All also copies
    /// everyone else who got it. Replying to something you sent goes on to the
    /// people you sent it to, as Mail does, instead of back to you.
    /// `own` is your addresses, lowercased.
    public static func of(_ original: MessageRecord, all: Bool, own: Set<String>)
        -> (to: [EmailAddress], cc: [EmailAddress]) {
        let to: [EmailAddress]
        var others: [EmailAddress]
        let sentTo = original.to.filter { !own.contains($0.normalized) }
        if own.contains(original.sender.normalized), !sentTo.isEmpty {
            to = sentTo
            others = original.cc
        } else {
            to = original.replyTo.isEmpty ? [original.sender] : original.replyTo
            others = original.to + original.cc
        }
        guard all else { return (to, []) }
        var seen = Set(to.map(\.normalized)).union(own)
        others = others.filter { seen.insert($0.normalized).inserted }
        return (to, others)
    }

    /// The address to answer from: the one you sent it from, or else the one
    /// it was sent to.
    public static func identityEmail(for original: MessageRecord, own: Set<String>) -> String? {
        if own.contains(original.sender.normalized) { return original.sender.normalized }
        return (original.to + original.cc).map(\.normalized).first(where: own.contains)
    }
}
