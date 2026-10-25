import SiftKit
import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

/// One message being written: its fields, its attachments as they upload,
/// and saving it to Drafts. `ComposeView` draws it.
@Observable
final class ComposeDraft {
    enum Field: Hashable { case to, cc, bcc, subject, body }

    struct PendingAttachment: Identifiable {
        enum State {
            case uploading
            case ready(OutgoingMessage.Attachment)
            case failed(String)
        }

        let id = UUID()
        var name: String
        var type: String
        var size: Int
        var state: State

        var isImage: Bool { UTType(mimeType: type)?.conforms(to: .image) ?? false }
    }

    var identityId = ""
    var to: [EmailAddress] = []
    var cc: [EmailAddress] = []
    var bcc: [EmailAddress] = []
    /// What's being typed in each address field, not yet a token.
    var toText = ""
    var ccText = ""
    var bccText = ""
    var subject = ""
    var body = ""
    var attachments: [PendingAttachment] = []
    /// iPhone shows "Cc/Bcc, From:" on one line until it's tapped.
    var showsAllHeaders = false
    var isSending = false

    private(set) var draftId: String?
    private(set) var kind = "New Message"
    private var inReplyTo: [String] = []
    private var references: [String] = []
    private var answering: String?
    /// The content as last saved (or as it started), to tell whether there are edits.
    private var savedContent: OutgoingMessage?
    private var isSaving = false
    /// Sent or deleted: nothing left to save.
    private(set) var isFinished = false

    // MARK: - The message

    var message: OutgoingMessage {
        OutgoingMessage(
            identityId: identityId,
            to: to + Self.parse(toText), cc: cc + Self.parse(ccText), bcc: bcc + Self.parse(bccText),
            subject: subject, body: body,
            attachments: attachments.compactMap { if case .ready(let file) = $0.state { file } else { nil } },
            inReplyTo: inReplyTo, references: references, answering: answering, draftId: draftId
        )
    }

    var title: String { subject.trimmingCharacters(in: .whitespaces).isEmpty ? kind : subject }

    /// Changed since it was opened or last saved.
    var hasEdits: Bool { savedContent != nil && message.content != savedContent }

    var isUploading: Bool {
        attachments.contains { if case .uploading = $0.state { true } else { false } }
    }

    var canSend: Bool { !message.recipients.isEmpty && !identityId.isEmpty && !isUploading && !isSending }

    // MARK: - Starting

    /// Fills the fields for a new message, reply, forward, link or saved draft.
    /// Returns the field to start typing in.
    func prepare(_ request: ComposeRequest, model: AppModel) async -> Field {
        identityId = model.identities.first?.id ?? ""
        let own = Set(model.identities.map { $0.email.lowercased() })
        var focus = Field.to

        if let draft = request.draft {
            identityId = draft.identityId.isEmpty ? identityId : draft.identityId
            (to, cc, bcc) = (draft.to, draft.cc, draft.bcc)
            subject = draft.subject
            body = draft.body
            attachments = draft.attachments.map { .init(name: $0.name, type: $0.type, size: $0.size, state: .ready($0)) }
            (inReplyTo, references, answering, draftId) = (draft.inReplyTo, draft.references, draft.answering, draft.draftId)
            showsAllHeaders = !cc.isEmpty || !bcc.isEmpty
            focus = to.isEmpty ? .to : .body
        } else if let link = request.mailto {
            to = link.to.flatMap(Self.parse)
            cc = link.cc.flatMap(Self.parse)
            bcc = link.bcc.flatMap(Self.parse)
            subject = link.subject ?? ""
            body = link.body ?? ""
            showsAllHeaders = !cc.isEmpty || !bcc.isEmpty
            focus = to.isEmpty ? .to : .body
        } else if let original = request.replyTo {
            kind = request.replyAll ? "Reply All" : "Reply"
            to = original.replyTo.isEmpty ? [original.sender] : original.replyTo
            if request.replyAll {
                let already = Set(to.map(\.normalized))
                cc = (original.to + original.cc).filter { !own.contains($0.normalized) && !already.contains($0.normalized) }
            }
            subject = original.subject.lowercased().hasPrefix("re:") ? original.subject : "Re: \(original.subject)"
            // Reply from whichever of your addresses it was sent to.
            if let identity = model.identities.first(where: { identity in
                (original.to + original.cc).contains { $0.normalized == identity.email.lowercased() }
            }) {
                identityId = identity.id
            }
            if let id = original.messageIdHeader {
                inReplyTo = [id]
                references = original.references + [id]
            }
            answering = original.id
            let quoted = await Self.quotedText(of: original, model: model)
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { "> \($0)" }.joined(separator: "\n")
            body = signatureBlock(model) + "\n\nOn \(original.receivedAt.formatted(date: .abbreviated, time: .shortened)), \(original.senderDisplayName) wrote:\n\n\(quoted)"
            showsAllHeaders = !cc.isEmpty
            focus = .body
        } else if let original = request.forward {
            kind = "Forward"
            subject = original.subject.lowercased().hasPrefix("fwd:") ? original.subject : "Fwd: \(original.subject)"
            let text = await Self.quotedText(of: original, model: model)
            body = signatureBlock(model) + """


                Begin forwarded message:

                From: \(Self.format(original.sender))
                Subject: \(original.subject)
                Date: \(original.receivedAt.formatted(date: .long, time: .shortened))
                To: \(original.to.map(Self.format).joined(separator: ", "))

                \(text)
                """
            // The originals' files come along without uploading them again.
            if let files = try? await model.body(for: original).attachments {
                attachments = files.compactMap { part in
                    part.blobId.map {
                        let file = OutgoingMessage.Attachment(blobId: $0, name: part.name ?? "Attachment",
                                                              type: part.type ?? "application/octet-stream", size: part.size ?? 0)
                        return .init(name: file.name, type: file.type, size: file.size, state: .ready(file))
                    }
                }
            }
        } else {
            body = signatureBlock(model)
        }
        savedContent = message.content
        return focus
    }

    private func signatureBlock(_ model: AppModel) -> String {
        guard let signature = model.identities.first(where: { $0.id == identityId })?.textSignature?
            .trimmingCharacters(in: .whitespacesAndNewlines), !signature.isEmpty else { return "" }
        return "\n\n-- \n\(signature)"
    }

    private static func quotedText(of message: MessageRecord, model: AppModel) async -> String {
        guard let body = try? await model.body(for: message) else { return message.preview }
        return body.text ?? body.html.map(HTMLText.plainText(from:)) ?? message.preview
    }

    // MARK: - Addresses

    /// Turns what's been typed into address tokens. Anything that isn't an
    /// address stays as text to fix.
    func commit(_ field: Field) {
        switch field {
        case .to: Self.commit(&toText, into: &to)
        case .cc: Self.commit(&ccText, into: &cc)
        case .bcc: Self.commit(&bccText, into: &bcc)
        default: break
        }
    }

    func add(_ address: EmailAddress, to field: Field) {
        switch field {
        case .to: to.append(address); toText = ""
        case .cc: cc.append(address); ccText = ""
        case .bcc: bcc.append(address); bccText = ""
        default: break
        }
    }

    private static func commit(_ text: inout String, into list: inout [EmailAddress]) {
        var leftover: [String] = []
        for piece in text.split(whereSeparator: { $0 == "," || $0 == ";" }) {
            let parsed = parse(String(piece))
            if parsed.isEmpty {
                let trimmed = piece.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { leftover.append(trimmed) }
            } else {
                list += parsed.filter { new in !list.contains { $0.normalized == new.normalized } }
            }
        }
        text = leftover.joined(separator: ", ")
    }

    static func format(_ address: EmailAddress) -> String {
        if let name = address.name, !name.isEmpty { return "\(name) <\(address.email ?? "")>" }
        return address.email ?? ""
    }

    /// Parses "Ann <ann@x.com>, bo@y.org" into addresses.
    static func parse(_ field: String) -> [EmailAddress] {
        field.split(whereSeparator: { $0 == "," || $0 == ";" }).compactMap { raw in
            let item = raw.trimmingCharacters(in: .whitespaces)
            if let open = item.lastIndex(of: "<"), let close = item.lastIndex(of: ">"), open < close {
                let email = item[item.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
                let name = item[..<open].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"")))
                return email.contains("@") ? EmailAddress(name: name.isEmpty ? nil : name, email: email) : nil
            }
            return item.contains("@") && !item.contains(" ") ? EmailAddress(email: item) : nil
        }
    }

    // MARK: - Attachments

    /// Starts uploading a file; it shows straight away with a spinner.
    func attach(_ data: Data, name: String, type: String, model: AppModel) async {
        var data = data, name = name, type = type
        #if canImport(UIKit)
        // iPhone photos are HEIC, which many mail apps can't show: send JPEG like Mail does.
        if type == "image/heic" || type == "image/heif", let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.9) {
            data = jpeg
            type = "image/jpeg"
            name = (name as NSString).deletingPathExtension + ".jpg"
        }
        #endif
        let pending = PendingAttachment(name: name, type: type, size: data.count, state: .uploading)
        attachments.append(pending)
        let state: PendingAttachment.State
        do {
            state = .ready(try await model.upload(data, name: name, type: type))
        } catch {
            state = .failed(error.localizedDescription)
        }
        if let index = attachments.firstIndex(where: { $0.id == pending.id }) { attachments[index].state = state }
    }

    /// A file from the Files app, a file panel or a drop.
    func attach(fileAt url: URL, model: AppModel) async {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        let type = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        do {
            let data = try await Task.detached { try Data(contentsOf: url) }.value
            await attach(data, name: name, type: type, model: model)
        } catch {
            attachments.append(.init(name: name, type: type, size: 0, state: .failed(error.localizedDescription)))
        }
    }

    func remove(_ id: PendingAttachment.ID) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: - Drafts

    /// Saves to Drafts if anything changed. A message emptied out deletes its draft.
    /// Returns true when a draft was written.
    @discardableResult
    func save(model: AppModel) async -> Bool {
        guard savedContent != nil, !isFinished, !isSaving else { return false }
        let snapshot = message
        if snapshot.isBlank {
            if let id = draftId {
                draftId = nil
                await model.discardDraft(id)
            }
            savedContent = snapshot.content
            return false
        }
        guard hasEdits else { return false }
        isSaving = true
        defer { isSaving = false }
        guard let id = await model.saveDraft(snapshot) else { return false }
        draftId = id
        savedContent = snapshot.content
        return true
    }

    /// Throws the message away, including any saved draft.
    func discard(model: AppModel) async {
        isFinished = true
        if let id = draftId { await model.discardDraft(id) }
    }

    /// Hands the message to AppModel (which holds it for Undo Send).
    func send(model: AppModel) async -> Bool {
        for field in [Field.to, .cc, .bcc] { commit(field) }
        isSending = true
        defer { isSending = false }
        let ok = await model.send(message)
        if ok { isFinished = true }
        return ok
    }
}
