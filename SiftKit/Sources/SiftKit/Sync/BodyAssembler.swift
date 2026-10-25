import Foundation

/// Turns a JMAP Email's body structure into one renderable document.
public enum BodyAssembler {
    /// Inline parts are served to the web view through this scheme:
    /// `sift-blob://blob/<blobId>?type=image/png&name=logo.png`.
    public static let blobScheme = "sift-blob"

    nonisolated(unsafe) private static let cidReference = /(?i)cid:([^"'\s)>]+)/

    public static func assemble(_ email: Email) -> BodyRecord {
        let values = email.bodyValues ?? [:]
        let inline = Dictionary(
            ((email.htmlBody ?? []) + (email.attachments ?? [])).compactMap { part -> (String, EmailBodyPart)? in
                guard let cid = part.cid else { return nil }
                return (cid.trimmingCharacters(in: CharacterSet(charactersIn: "<>")), part)
            },
            uniquingKeysWith: { first, _ in first }
        )

        var html = ""
        var sawHTML = false
        for part in email.htmlBody ?? [] {
            let type = part.type?.lowercased() ?? ""
            if type == "text/html", let partId = part.partId, let value = values[partId]?.value {
                html += value
                sawHTML = true
            } else if type == "text/plain", let partId = part.partId, let value = values[partId]?.value {
                html += "<div style=\"white-space: pre-wrap\">\(HTMLText.escape(value))</div>"
            } else if type.hasPrefix("image/"), let blobId = part.blobId {
                html += "<img src=\"\(blobURL(blobId: blobId, part: part))\" style=\"max-width: 100%\">"
            }
        }
        if sawHTML {
            html = html.replacing(cidReference) { match in
                let cid = String(match.output.1)
                guard let part = inline[cid] ?? inline[cid.removingPercentEncoding ?? cid], let blobId = part.blobId else {
                    return String(match.output.0)
                }
                return blobURL(blobId: blobId, part: part)
            }
        }

        let text = (email.textBody ?? [])
            .filter { ($0.type ?? "").lowercased() == "text/plain" }
            .compactMap { $0.partId.flatMap { values[$0]?.value } }
            .joined(separator: "\n\n")

        let attachments = (email.attachments ?? []).filter { part in
            part.disposition?.lowercased() == "attachment" || part.cid == nil
        }

        return BodyRecord(
            messageId: email.id,
            html: sawHTML ? html : nil,
            text: text.isEmpty ? (sawHTML ? HTMLText.plainText(from: html) : nil) : text,
            attachments: attachments,
            inlineParts: inline,
            fetchedAt: .now
        )
    }

    public static func blobURL(blobId: String, part: EmailBodyPart) -> String {
        var components = URLComponents()
        components.scheme = blobScheme
        // Blob ids are case-sensitive, so they ride in the path, not the host.
        components.host = "blob"
        components.path = "/\(blobId)"
        components.queryItems = [
            URLQueryItem(name: "type", value: part.type ?? "application/octet-stream"),
            URLQueryItem(name: "name", value: part.name ?? "inline"),
        ]
        return components.string ?? "\(blobScheme)://blob/\(blobId)"
    }
}
