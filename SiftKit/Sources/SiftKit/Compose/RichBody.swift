import Foundation

/// A message body with links, as the compose screen edits it, and the plain
/// text and HTML it's sent as. Links are the only formatting it keeps.
public enum RichBody {
    /// The text, with each link's address after its words, as Mail sends it:
    /// "Tickets <https://…>". A link that already reads as its address stays as is.
    public static func plainText(_ body: AttributedString) -> String {
        var text = ""
        for run in body.runs {
            let words = String(body[run.range].characters)
            text += words
            if let url = run.link, !reads(words, as: url) { text += " <\(url.absoluteString)>" }
        }
        return text
    }

    /// HTML with the links as links. Nil when there are none, so a message
    /// without links goes as plain text only.
    public static func html(_ body: AttributedString) -> String? {
        guard body.runs.contains(where: { $0.link != nil }) else { return nil }
        var html = ""
        for run in body.runs {
            let words = HTMLText.escape(String(body[run.range].characters))
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: "<br>")
                // Runs of spaces would collapse to one.
                .replacingOccurrences(of: "  ", with: " &nbsp;")
            if let url = run.link {
                html += "<a href=\"\(HTMLText.escape(url.absoluteString))\">\(words)</a>"
            } else {
                html += words
            }
        }
        return "<div dir=\"auto\">\(html)</div>"
    }

    /// A saved draft's HTML back as text with its links.
    public static func attributedString(html: String) -> AttributedString {
        var result = AttributedString()
        var rest = html[...]
        while let match = rest.firstMatch(of: anchor) {
            result += AttributedString(text(of: rest[..<match.range.lowerBound]))
            var words = AttributedString(text(of: match.output.3))
            let href = HTMLText.decodeEntities(String(match.output.1 ?? match.output.2 ?? ""))
            words.link = URL(string: href.trimmingCharacters(in: .whitespaces))
            result += words
            rest = rest[match.range.upperBound...]
        }
        result += AttributedString(text(of: rest))
        // Block ends leave a trailing break that the editor would show as a blank line.
        while result.characters.last == "\n" { result.characters.removeLast() }
        return result
    }

    /// What someone types into Add Link, as an address: "example.com" is a web
    /// page and "pat@example.com" an email address.
    public static func url(from typed: String) -> URL? {
        let typed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, !typed.contains(" ") else { return nil }
        if typed.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil {
            return URL(string: typed)
        }
        if typed.contains("@"), !typed.contains("/") { return URL(string: "mailto:\(typed)") }
        return URL(string: "https://\(typed)")
    }

    nonisolated(unsafe) private static let anchor = /(?is)<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>(.*?)<\/a\s*>/
    nonisolated(unsafe) private static let sourceBreaks = /\s*\r?\n\s*/
    nonisolated(unsafe) private static let breaks = /(?i)<\s*(br|\/p|\/div|\/li|\/h[1-6])\b[^>]*>/
    nonisolated(unsafe) private static let tags = /<[^>]+>/

    /// Text as a browser shows it: line breaks in the source are spaces, breaks
    /// and block ends are new lines. Unlike `HTMLText.plainText`, nothing's
    /// trimmed, so the spaces around a link stay.
    private static func text(of html: Substring) -> String {
        var text = String(html).replacing(sourceBreaks, with: " ")
        text = text.replacing(breaks, with: "\n")
        text = text.replacing(tags, with: "")
        return HTMLText.decodeEntities(text)
    }

    private static func reads(_ words: String, as url: URL) -> Bool {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let address = url.absoluteString.lowercased()
        return [address, address.replacingOccurrences(of: "mailto:", with: ""),
                address.replacingOccurrences(of: "https://", with: ""),
                address.replacingOccurrences(of: "http://", with: "")]
            .contains { $0 == words || $0 == words + "/" }
    }
}
