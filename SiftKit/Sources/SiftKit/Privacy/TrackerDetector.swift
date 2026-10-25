import Foundation

public struct DetectedTracker: Sendable, Hashable {
    public enum Reason: String, Sendable {
        case knownService, tinyImage, hiddenImage, beaconPath
    }

    public var name: String
    public var url: String
    public var reason: Reason
}

public struct SanitizedMessage: Sendable {
    public var html: String
    public var trackers: [DetectedTracker]
    /// Remote images left in the message (not trackers).
    public var remoteImageCount: Int

    public init(html: String, trackers: [DetectedTracker], remoteImageCount: Int) {
        self.html = html
        self.trackers = trackers
        self.remoteImageCount = remoteImageCount
    }

    /// "Mailchimp", "HubSpot and Litmus", …
    public var trackerSummary: String? {
        let names = trackers.reduce(into: [String]()) { names, tracker in
            if !names.contains(tracker.name) { names.append(tracker.name) }
        }
        guard !names.isEmpty else { return nil }
        return names.formatted(.list(type: .and))
    }
}

/// Finds and removes spy pixels, HEY-style: known services first, then generic
/// heuristics (tiny, hidden, or beacon-shaped images). Also strips active and
/// remote-loading content that has no business in an email.
public enum TrackerDetector {
    nonisolated(unsafe) private static let imgTag = /(?is)<img\b[^>]*>/
    nonisolated(unsafe) private static let attribute = /(?is)([a-z_:][-a-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))/
    nonisolated(unsafe) private static let pairedDangerous = /(?is)<(script|iframe|object|embed|frameset|applet)\b.*?<\/\1\s*>/
    nonisolated(unsafe) private static let loneDangerous = /(?is)<(script|iframe|object|embed|link|base|meta\s+http-equiv)\b[^>]*>/

    public static func sanitize(_ html: String) -> SanitizedMessage {
        var trackers: [DetectedTracker] = []
        var remoteImages = 0

        var output = html.replacing(pairedDangerous, with: "")
        output = output.replacing(loneDangerous, with: "")
        output = output.replacing(imgTag) { match in
            let tag = String(match.output)
            guard let verdict = inspect(tag) else {
                if isRemote(attributes(of: tag)["src"]) { remoteImages += 1 }
                return tag
            }
            trackers.append(verdict)
            return ""
        }
        return SanitizedMessage(html: output, trackers: trackers, remoteImageCount: remoteImages)
    }

    /// Returns a tracker verdict for one `<img>` tag, or nil if it looks legitimate.
    static func inspect(_ tag: String) -> DetectedTracker? {
        let attrs = attributes(of: tag)
        guard let src = attrs["src"], isRemote(src), let url = URL(string: src.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        if let rule = TrackerList.match(url) {
            return DetectedTracker(name: rule.name, url: src, reason: .knownService)
        }

        let style = (attrs["style"] ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        let width = dimension(attrs["width"]) ?? styleDimension("width", in: style)
        let height = dimension(attrs["height"]) ?? styleDimension("height", in: style)
        let name = companyName(for: url)

        let isTiny = switch (width, height) {
        case let (w?, h?): w <= 2 && h <= 2
        case let (w?, nil): w <= 1
        case let (nil, h?): h <= 1
        default: false
        }
        if isTiny { return DetectedTracker(name: name, url: src, reason: .tinyImage) }

        let hidden = ["display:none", "visibility:hidden", "opacity:0;", "max-height:0", "max-width:0"]
            .contains { style.contains($0) } || style.hasSuffix("opacity:0")
        if hidden { return DetectedTracker(name: name, url: src, reason: .hiddenImage) }

        let path = url.path(percentEncoded: true).lowercased() + (url.query().map { "?" + $0.lowercased() } ?? "")
        if width == nil, height == nil, TrackerList.suspiciousPaths.contains(where: { path.contains($0) }) {
            return DetectedTracker(name: name, url: src, reason: .beaconPath)
        }
        return nil
    }

    static func attributes(of tag: String) -> [String: String] {
        var result: [String: String] = [:]
        for match in tag.matches(of: attribute) {
            let name = String(match.output.1).lowercased()
            let value = match.output.2 ?? match.output.3 ?? match.output.4 ?? ""
            if result[name] == nil { result[name] = HTMLText.decodeEntities(String(value)) }
        }
        return result
    }

    static func isRemote(_ src: String?) -> Bool {
        guard let src = src?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return src.hasPrefix("http://") || src.hasPrefix("https://") || src.hasPrefix("//")
    }

    static func dimension(_ value: String?) -> Double? {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased(), !value.hasSuffix("%") else { return nil }
        return Double(value.replacingOccurrences(of: "px", with: ""))
    }

    static func styleDimension(_ property: String, in style: String) -> Double? {
        // `style` is lowercased with spaces removed; look for "width:1px" but not "max-width".
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0] == property else { continue }
            return dimension(String(parts[1]))
        }
        return nil
    }

    /// "email.news.acme.co.uk" → "acme.co.uk"; a readable stand-in when the
    /// tracking service isn't one we know by name.
    static func companyName(for url: URL) -> String {
        guard let host = url.host()?.lowercased() else { return "Unknown tracker" }
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        let secondLevel = ["co", "com", "org", "net", "ac", "gov"]
        let keep = secondLevel.contains(String(labels[labels.count - 2])) && labels.count > 2 ? 3 : 2
        return labels.suffix(keep).joined(separator: ".")
    }
}

/// Builds WebKit content-blocker rules (`WKContentRuleListStore` JSON).
public enum ContentBlockerRules {
    /// Blocks known tracking services at the network layer, catching CSS
    /// backgrounds and anything the HTML pass missed.
    public static func trackersJSON() -> String {
        json(TrackerList.rules.map { rule in
            ["trigger": ["url-filter": urlFilter(for: rule), "url-filter-is-case-sensitive": false],
             "action": ["type": "block"]]
        })
    }

    /// Blocks every remote load: used when remote images are off.
    public static func blockRemoteJSON() -> String {
        json([["trigger": ["url-filter": "^https?://"], "action": ["type": "block"]]])
    }

    static func urlFilter(for rule: TrackerRule) -> String {
        switch (rule.host, rule.path) {
        case let (host?, path?): "^https?://[^/]*\(escape(host)).*\(escape(path))"
        case let (host?, nil): "^https?://[^/]*\(escape(host))"
        case let (nil, path?): "^https?://.*\(escape(path))"
        case (nil, nil): "^$"
        }
    }

    static func escape(_ text: String) -> String {
        let specials = Set(".?*+[]()^$\\")
        return text.map { specials.contains($0) ? "\\\($0)" : String($0) }.joined()
    }

    private static func json(_ rules: [[String: Any]]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
