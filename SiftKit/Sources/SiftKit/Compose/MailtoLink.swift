import Foundation

/// A `mailto:` link (RFC 6068), as opened from a web page or another app when
/// Sift is the default email app.
///
///     mailto:alex@example.com,sam@example.com?cc=pat@example.com&subject=Hi%20there&body=See%20you
public struct MailtoLink: Codable, Sendable, Hashable {
    public var to: [String] = []
    public var cc: [String] = []
    public var bcc: [String] = []
    public var subject: String?
    public var body: String?

    public init(to: [String] = [], cc: [String] = [], bcc: [String] = [], subject: String? = nil, body: String? = nil) {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
    }

    public init?(_ url: URL) {
        self.init(string: url.absoluteString)
    }

    public init?(string: String) {
        guard string.lowercased().hasPrefix("mailto:") else { return nil }
        // Parsed by hand: URLComponents rejects common real-world links (raw
        // spaces, unencoded commas) and RFC 6068 doesn't treat "+" as a space.
        var rest = Substring(string.dropFirst("mailto:".count))
        if rest.hasPrefix("//") { rest = rest.dropFirst(2) }  // "mailto://", seen in the wild
        let parts = rest.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        to = Self.addresses(parts.first.map(String.init) ?? "")

        if parts.count > 1 {
            for field in parts[1].split(separator: "&") {
                let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = (pair.first.map(String.init) ?? "").lowercased()
                let value = pair.count > 1 ? Self.decode(String(pair[1])) : ""
                switch name {
                case "to": to += Self.addresses(value, decoded: true)
                case "cc": cc += Self.addresses(value, decoded: true)
                case "bcc": bcc += Self.addresses(value, decoded: true)
                case "subject": subject = value
                case "body": body = value.replacingOccurrences(of: "\r\n", with: "\n")
                default: break  // In-Reply-To, Keywords and so on: not needed to start a message.
                }
            }
        }
    }

    public var isEmpty: Bool { to.isEmpty && cc.isEmpty && bcc.isEmpty && subject == nil && body == nil }

    private static func decode(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private static func addresses(_ list: String, decoded: Bool = false) -> [String] {
        let text = decoded ? list : decode(list)
        return text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
