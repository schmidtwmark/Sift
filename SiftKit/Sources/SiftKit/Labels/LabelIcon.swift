import Foundation

/// SF Symbols for labels: a catalog to choose from, a guess from the label's
/// name until you choose, and the contact-group note that syncs your choice.
public enum LabelIcon {
    public struct Category: Sendable, Identifiable {
        public var id: String { title }
        public let title: String
        public let symbols: [String]

        public init(title: String, symbols: [String]) {
            self.title = title
            self.symbols = symbols
        }
    }

    public static let fallback = "tag"

    public static let catalog: [Category] = [
        Category(title: "General", symbols: [
            "tag", "folder", "tray.full", "archivebox", "star", "heart", "bookmark", "flag",
            "pin", "bell", "lightbulb", "sparkles", "bolt", "flame", "leaf", "drop",
        ]),
        Category(title: "Money & Shopping", symbols: [
            "receipt", "cart", "bag", "creditcard", "banknote", "dollarsign.circle", "building.columns",
            "chart.line.uptrend.xyaxis", "percent", "giftcard", "gift", "storefront", "shippingbox",
        ]),
        Category(title: "Work & School", symbols: [
            "briefcase", "building.2", "doc.text", "newspaper", "book", "graduationcap", "pencil",
            "hammer", "wrench.and.screwdriver", "laptopcomputer", "chart.bar", "calendar", "clock",
            "server.rack", "megaphone", "chevron.left.forwardslash.chevron.right",
        ]),
        Category(title: "Travel & Places", symbols: [
            "airplane", "car", "tram", "bus", "ferry", "bicycle", "suitcase", "map",
            "mappin.and.ellipse", "globe.americas", "house", "bed.double", "tent",
        ]),
        Category(title: "People & Fun", symbols: [
            "person", "person.2", "figure.2.and.child.holdinghands", "figure.and.child.holdinghands",
            "bubble.left.and.bubble.right", "pawprint", "gamecontroller", "music.note", "film", "tv",
            "camera", "photo", "ticket", "theatermasks", "trophy", "sportscourt", "figure.run", "dumbbell",
        ]),
        Category(title: "Health & Home", symbols: [
            "cross.case", "pills", "stethoscope", "heart.text.square", "fork.knife", "cup.and.saucer",
            "wineglass", "birthday.cake", "wifi", "phone", "envelope", "paperplane", "lock", "key",
            "shield", "checkmark.seal", "exclamationmark.triangle", "gearshape", "cloud",
        ]),
    ]

    /// A starting icon from the label's name, so labels don't all look alike
    /// before you pick anything.
    public static func suggested(for name: String) -> String {
        // Match the starts of words, so "Education" isn't about cats.
        let words = name.lowercased().split { !$0.isLetter }
        for (keywords, symbol) in suggestions {
            if words.contains(where: { word in keywords.contains { word.hasPrefix($0) } }) { return symbol }
        }
        return fallback
    }

    private static let suggestions: [([String], String)] = [
        (["receipt", "order", "purchase", "invoice", "paper"], "receipt"),
        (["bill", "utilit"], "bolt"),
        (["bank", "financ", "money", "tax", "invest", "credit"], "building.columns"),
        (["shipping", "package", "deliver"], "shippingbox"),
        (["shop", "store", "deal"], "bag"),
        (["promo", "marketing", "offer", "sale"], "megaphone"),
        (["newsletter", "news", "digest", "reading", "blog", "feed"], "newspaper"),
        (["github", "gitlab", "code", "dev", "engineering"], "chevron.left.forwardslash.chevron.right"),
        (["travel", "trip", "flight", "vacation", "holiday"], "airplane"),
        (["family", "kid", "parent"], "figure.2.and.child.holdinghands"),
        (["friend", "personal"], "person.2"),
        (["work", "job", "career", "business"], "briefcase"),
        (["school", "class", "college", "universit", "course", "educat"], "graduationcap"),
        (["health", "medical", "doctor", "dental", "insurance"], "cross.case"),
        (["home", "house", "rent", "mortgage"], "house"),
        (["car", "auto", "vehicle"], "car"),
        (["social", "community", "forum"], "bubble.left.and.bubble.right"),
        (["notification", "alert", "update"], "bell"),
        (["ticket", "event", "concert"], "ticket"),
        (["pet", "dog", "cat", "vet"], "pawprint"),
        (["music"], "music.note"),
        (["game"], "gamecontroller"),
        (["fitness", "gym", "run", "sport"], "figure.run"),
        (["food", "recipe", "restaurant", "cooking"], "fork.knife"),
        (["security", "account", "login", "password"], "lock"),
        (["subscription", "membership"], "checkmark.seal"),
        (["import", "archive", "old", "storage", "keep"], "archivebox"),
    ]

    // MARK: - Contact-group note

    static let notePrefix = "Sift icon: "

    static func note(for symbol: String) -> String { notePrefix + symbol }

    static func parse(note: String) -> String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(notePrefix) else { return nil }
        let symbol = trimmed.dropFirst(notePrefix.count).trimmingCharacters(in: .whitespaces)
        return symbol.isEmpty ? nil : symbol
    }
}
