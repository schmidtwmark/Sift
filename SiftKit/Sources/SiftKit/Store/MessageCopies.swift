import Foundation

/// Mail you send to yourself exists twice, the copy in Sent and the one
/// delivered to your Inbox, and both sit in the conversation. Mail shows each
/// message once; so does Sift. Copies share a Message-ID.
extension Array where Element == MessageRecord {
    /// The messages grouped with their copies, in the order each first appears.
    public func groupingCopies() -> [[MessageRecord]] {
        var groups: [[MessageRecord]] = []
        var index: [String: Int] = [:]
        for message in self {
            if let key = message.messageIdHeader, let at = index[key] {
                groups[at].append(message)
            } else {
                if let key = message.messageIdHeader { index[key] = groups.count }
                groups.append([message])
            }
        }
        return groups
    }

    /// Each message once (see `MessageRecord.merging`).
    public func collapsingCopies() -> [MessageRecord] {
        groupingCopies().map(MessageRecord.merging)
    }
}

extension MessageRecord {
    /// One record standing for all copies of a message: the first copy, unread
    /// while any copy is, flagged if any is, and in every copy's mailboxes.
    public static func merging(_ copies: [MessageRecord]) -> MessageRecord {
        guard var merged = copies.first else { preconditionFailure("No copies to merge") }
        guard copies.count > 1 else { return merged }
        merged.mailboxIds = Array(Set(copies.flatMap(\.mailboxIds))).sorted()
        merged.setKeyword(Keyword.seen, copies.allSatisfy { !$0.isUnread })
        merged.setKeyword(Keyword.flagged, copies.contains(where: \.isFlagged))
        return merged
    }
}
