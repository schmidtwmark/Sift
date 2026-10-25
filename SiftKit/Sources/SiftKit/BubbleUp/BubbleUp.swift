import Foundation

/// A conversation set to come back to the top of your mail later, Hey-style.
///
/// Sift sends you a note, held by Fastmail until `at`, with the conversation's
/// subject and threading headers, so it lands in the same conversation. That
/// makes the conversation float up in Fastmail's own apps too. In Sift, the
/// note (marked `$siftbubble`) stays hidden: the original shows, unread again,
/// with its own date.
public struct BubbleUp: Codable, Sendable, Hashable {
    public var submissionId: String
    public var threadId: String
    public var at: Date

    public init(submissionId: String, threadId: String, at: Date) {
        self.submissionId = submissionId
        self.threadId = threadId
        self.at = at
    }

    /// Names the original in the note, and lets Sift recognize the note when it arrives.
    public static let header = "X-Sift-Bubble-Up"

    /// The usual choices, worked out from `now`: later today, tomorrow
    /// morning, the weekend, next week.
    public static func suggestions(from now: Date = .now, calendar: Calendar = .current) -> [(title: String, date: Date)] {
        func morning(_ day: Date) -> Date {
            calendar.date(bySettingHour: 8, minute: 0, second: 0, of: day) ?? day
        }
        var options: [(String, Date)] = []
        let hour = calendar.component(.hour, from: now)
        if hour < 18, let later = calendar.date(byAdding: .hour, value: 3, to: now) {
            options.append(("Later Today", later))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) {
            options.append(("Tomorrow Morning", morning(tomorrow)))
        }
        let weekday = calendar.component(.weekday, from: now)  // 1 = Sunday, 7 = Saturday
        if weekday != 7, weekday != 1,
           let saturday = calendar.nextDate(after: now, matching: DateComponents(weekday: 7), matchingPolicy: .nextTime) {
            options.append(("This Weekend", morning(saturday)))
        }
        if let monday = calendar.nextDate(after: now, matching: DateComponents(weekday: 2), matchingPolicy: .nextTime) {
            options.append(("Next Week", morning(monday)))
        }
        return options
    }
}

public enum BubbleUpError: Error, LocalizedError, Equatable {
    case unsupported
    case tooSoon
    case tooFar(days: Int)
    case noMessageId

    public var errorDescription: String? {
        switch self {
        case .unsupported: "Your Fastmail account can't hold mail to send later, which Bubble Up needs."
        case .tooSoon: "Pick a time at least a few minutes from now."
        case .tooFar(let days): "Fastmail can hold mail for up to \(days) days. Pick an earlier time."
        case .noMessageId: "This message can't be bubbled up because it has no Message-ID."
        }
    }
}
