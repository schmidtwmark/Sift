import Foundation

/// Lightweight HTML helpers that don't need a web view (indexing, quoting replies).
public enum HTMLText {
    nonisolated(unsafe) private static let invisibleBlocks = /(?is)<(head|style|script|title)\b.*?<\/\1\s*>/
    nonisolated(unsafe) private static let breaks = /(?i)<\s*(br|\/p|\/div|\/tr|\/li|\/h[1-6])\b[^>]*>/
    nonisolated(unsafe) private static let tags = /<[^>]+>/
    nonisolated(unsafe) private static let entity = /&(#x?[0-9a-fA-F]+|[a-zA-Z]+);/
    nonisolated(unsafe) private static let blankLines = /\n[ \t]*(\n[ \t]*)+/

    public static func plainText(from html: String) -> String {
        guard html.contains("<") else { return html }
        var text = html.replacing(invisibleBlocks, with: " ")
        text = text.replacing(breaks, with: "\n")
        text = text.replacing(tags, with: "")
        text = decodeEntities(text)
        text = text.replacing(blankLines, with: "\n\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func decodeEntities(_ text: String) -> String {
        text.replacing(entity) { match in
            let name = String(match.output.1)
            if name.hasPrefix("#") {
                let digits = name.dropFirst()
                let code = digits.first == "x" || digits.first == "X"
                    ? UInt32(digits.dropFirst(), radix: 16)
                    : UInt32(digits)
                if let code, let scalar = Unicode.Scalar(code) { return String(Character(scalar)) }
                return String(match.output.0)
            }
            return named[name.lowercased()] ?? String(match.output.0)
        }
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "rsquo": "’", "lsquo": "‘",
        "rdquo": "”", "ldquo": "“", "copy": "©", "reg": "®", "trade": "™", "zwnj": "", "zwj": "",
    ]
}
