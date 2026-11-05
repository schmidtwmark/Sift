import Foundation

/// Marks text quoted from another message. What's typed among it isn't quoted,
/// so a reply written between the lines reads as new.
public enum QuotedAttribute: AttributedStringKey {
    public typealias Value = Bool
    public static let name = "SiftQuoted"
    public static let inheritedByAddedText = false
}

/// A message body as the compose screen edits it, with its links and quotes,
/// and the plain text and HTML it's sent as.
public enum RichBody {
    /// The text, with each link's address after its words, as Mail sends it:
    /// "Tickets <https://…>". A link that already reads as its address stays as
    /// is. Quoted lines start with ">".
    public static func plainText(_ body: AttributedString) -> String {
        lines(of: body).map { line in
            var text = ""
            for piece in line.pieces {
                text += piece.words
                if let url = piece.link, !reads(piece.words, as: url) { text += " <\(url.absoluteString)>" }
            }
            guard line.isQuoted else { return text }
            return text.isEmpty ? ">" : "> \(text)"
        }.joined(separator: "\n")
    }

    /// HTML with the links as links and the quotes as quotes. Nil when there
    /// are neither, so a message of just words goes as plain text only.
    public static func html(_ body: AttributedString) -> String? {
        let lines = lines(of: body)
        guard lines.contains(where: { $0.isQuoted || $0.pieces.contains { $0.link != nil } }) else { return nil }
        var html = ""
        var start = lines.startIndex
        while start < lines.endIndex {
            let isQuoted = lines[start].isQuoted
            let end = lines[start...].firstIndex { $0.isQuoted != isQuoted } ?? lines.endIndex
            var block = lines[start..<end].map(html(of:)).joined(separator: "<br>")
            // The last break in a block doesn't show, so a blank last line needs one more.
            if lines[end - 1].pieces.isEmpty { block += "<br>" }
            block = "<div dir=\"auto\">\(block)</div>"
            html += isQuoted ? "<blockquote type=\"cite\" style=\"\(quoteStyle)\">\(block)</blockquote>" : block
            start = end
        }
        return html
    }

    /// A saved draft's HTML back as text with its links and quotes.
    public static func attributedString(html: String) -> AttributedString {
        var result = AttributedString()
        var rest = html[...]
        while let match = rest.firstMatch(of: blockquote) {
            result += linkedText(of: rest[..<match.range.lowerBound])
            var quote = linkedText(of: match.output.1)
            quote[QuotedAttribute.self] = true
            result += quote
            rest = rest[match.range.upperBound...]
        }
        result += linkedText(of: rest)
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

    /// Mail apps that don't style quotes themselves still show this as one.
    private static let quoteStyle = "margin:0 0 0 .8ex;border-left:2px solid #ccc;padding-left:1ex"

    nonisolated(unsafe) private static let blockquote = /(?is)<blockquote\b[^>]*>(.*?)<\/blockquote\s*>/
    nonisolated(unsafe) private static let anchor = /(?is)<a\b[^>]*?\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>(.*?)<\/a\s*>/
    nonisolated(unsafe) private static let sourceBreaks = /\s*\r?\n\s*/
    nonisolated(unsafe) private static let lastBreak = /(?i)<br\b[^>]*>(?=\s*<\/div\s*>)/
    nonisolated(unsafe) private static let breaks = /(?i)<\s*(br|\/p|\/div|\/li|\/h[1-6])\b[^>]*>/
    nonisolated(unsafe) private static let tags = /<[^>]+>/

    /// One line of the body, however many runs it's in.
    private struct Line {
        struct Piece {
            var words: String
            var link: URL?
            var isQuoted: Bool
        }

        var pieces: [Piece] = []
        /// Whether the break ending it is quoted, which is all a blank line has to go on.
        var endsInQuote = false
        /// A line someone has written in is theirs, even with quoted words on it.
        var isQuoted: Bool { pieces.isEmpty ? endsInQuote : pieces.allSatisfy(\.isQuoted) }
    }

    private static func lines(of body: AttributedString) -> [Line] {
        var lines = [Line()]
        for run in body.runs {
            let isQuoted = run[QuotedAttribute.self] == true
            let parts = String(body[run.range].characters).split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            for (index, part) in parts.enumerated() {
                if index > 0 {
                    lines[lines.count - 1].endsInQuote = isQuoted
                    lines.append(Line())
                }
                if !part.isEmpty {
                    lines[lines.count - 1].pieces.append(.init(words: String(part), link: run.link, isQuoted: isQuoted))
                }
            }
        }
        return lines
    }

    private static func html(of line: Line) -> String {
        line.pieces.map { piece in
            // Runs of spaces would collapse to one.
            let words = HTMLText.escape(piece.words).replacingOccurrences(of: "  ", with: " &nbsp;")
            guard let url = piece.link else { return words }
            return "<a href=\"\(HTMLText.escape(url.absoluteString))\">\(words)</a>"
        }.joined()
    }

    private static func linkedText(of html: Substring) -> AttributedString {
        var result = AttributedString()
        var rest = html
        while let match = rest.firstMatch(of: anchor) {
            result += AttributedString(text(of: rest[..<match.range.lowerBound]))
            var words = AttributedString(text(of: match.output.3))
            let href = HTMLText.decodeEntities(String(match.output.1 ?? match.output.2 ?? ""))
            words.link = URL(string: href.trimmingCharacters(in: .whitespaces))
            result += words
            rest = rest[match.range.upperBound...]
        }
        result += AttributedString(text(of: rest))
        return result
    }

    /// Text as a browser shows it: line breaks in the source are spaces, breaks
    /// and block ends are new lines. Unlike `HTMLText.plainText`, nothing's
    /// trimmed, so the spaces around a link stay.
    private static func text(of html: Substring) -> String {
        var text = String(html).replacing(sourceBreaks, with: " ")
        text = text.replacing(lastBreak, with: "")
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
