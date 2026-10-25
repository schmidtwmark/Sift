import Foundation

/// An in-process fake of Fastmail's JMAP API, good enough to run Sift end to
/// end without an account: tests use it, and the app's demo mode runs on it.
public final class DemoServer: @unchecked Sendable {
    public static let host = "demo.sift.invalid"
    public static let sessionURL = URL(string: "https://\(host)/jmap/session")!
    public static let shared = DemoServer()

    private let lock = NSLock()
    private var mailboxes: [String: [String: Any]] = [:]
    private var emails: [String: [String: Any]] = [:]
    private var bodies: [String: (html: String?, text: String)] = [:]
    private var blobs: [String: Data] = [:]
    /// A submitted message. Held ones keep a copy to deliver later.
    private struct Submission {
        var emailId: String
        var undoStatus: String
        var holdFor: Int
        var threadId: String?
        var sendAt: Date
        var rcptTo: [String]
        var copy: [String: Any]?
        var text: String
    }
    private var submissions: [String: Submission] = [:]
    private var books: [String: [String: Any]] = [:]
    private var cards: [String: [String: Any]] = [:]
    private var emailState = 1
    private var mailboxState = 1
    private var cardState = 1
    /// state → ids changed when moving to that state.
    private var changeLog: [(state: Int, created: Set<String>, updated: Set<String>, destroyed: Set<String>)] = []
    private var nextId = 1000

    /// Mimic a server that only allows real contacts as group members.
    public var rejectsAddressMembers = false
    /// Fail every Email/set with a server error.
    public var failsEmailSet = false
    /// Hold Email/set requests this long before applying them (race tests).
    public var emailSetDelay: TimeInterval = 0
    /// Advertised `maxDelayedSend`: how long submissions may be held (Undo Send).
    public var maxDelayedSend = 0

    public func submission(_ id: String) -> (emailId: String, undoStatus: String, holdFor: Int)? {
        locked { submissions[id].map { ($0.emailId, $0.undoStatus, $0.holdFor) } }
    }

    /// A held submission's time is up: it can no longer be canceled.
    public func release(_ id: String) {
        locked { submissions[id]?.undoStatus = "final" }
    }

    /// Held messages to you whose time has come arrive, as Fastmail would
    /// deliver them (so Bubble Up works in demo mode). Called with the lock held.
    private func deliverDue() {
        let due = submissions.filter { $0.value.undoStatus == "pending" && $0.value.sendAt <= .now
            && $0.value.rcptTo.contains("you@fastmail.com") }.keys
        for id in due { _ = deliver(held: id) }
    }

    /// Delivers a held message now, as if its time had come: a copy arrives
    /// in the Inbox of each of your own addresses it was sent to. Returns the new id.
    @discardableResult
    public func deliverHeld(_ id: String) -> String? {
        locked { deliver(held: id) }
    }

    private func deliver(held id: String) -> String? {
        guard var submission = submissions[id], submission.undoStatus == "pending", var copy = submission.copy else { return nil }
        submission.undoStatus = "final"
        submissions[id] = submission
        let newId = "M\(nextId)"
        nextId += 1
        copy["id"] = newId
        copy["blobId"] = "B\(newId)"
        copy["mailboxIds"] = ["inbox": true]
        copy["keywords"] = [String: Bool]()
        copy["receivedAt"] = JMAPCoding.formatUTCDate(.now)
        copy["threadId"] = submission.threadId ?? "T\(newId)"
        emails[newId] = copy
        bodies[newId] = (nil, submission.text)
        record(created: [newId])
        return newId
    }

    public func emailExists(_ id: String) -> Bool { locked { emails[id] != nil } }

    public func emailAttachments(_ id: String) -> [[String: Any]] {
        locked { emails[id]?["attachments"] as? [[String: Any]] ?? [] }
    }

    /// A change made elsewhere (the Fastmail web app) to one message's keywords.
    public func setKeyword(_ keyword: String, on id: String) {
        locked {
            guard var email = emails[id] else { return }
            var keywords = email["keywords"] as? [String: Bool] ?? [:]
            keywords[keyword] = true
            email["keywords"] = keywords
            emails[id] = email
            record(updated: [id])
        }
    }

    public init(seed: Bool = true) {
        // Like Fastmail: one default address book, and apps can't create more.
        books["personal"] = ["id": "personal", "name": "Personal", "isDefault": true]
        if seed { DemoSeed.populate(self) }
    }

    /// A URLSession whose requests to the demo host are answered by this server.
    public func urlSession() -> URLSession {
        let id = UUID().uuidString
        DemoURLProtocol.register(self, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DemoURLProtocol.self]
        configuration.httpAdditionalHeaders = [DemoURLProtocol.header: id]
        return URLSession(configuration: configuration)
    }

    // MARK: - Seeding & test hooks

    public func addMailbox(id: String, name: String, role: String? = nil, sortOrder: Int = 10) {
        locked { mailboxes[id] = ["id": id, "name": name, "parentId": NSNull(), "role": role ?? NSNull(), "sortOrder": sortOrder] }
    }

    /// Delivers a message. `html` defaults to a paragraph of `text`.
    @discardableResult
    public func deliver(from: (name: String, email: String), subject: String, text: String, html: String? = nil,
                        mailbox: String = "inbox", receivedAt: Date = .now, keywords: [String] = [],
                        threadId: String? = nil, to: String = "you@fastmail.com") -> String {
        locked {
            let id = "M\(nextId)"
            nextId += 1
            emails[id] = [
                "id": id, "blobId": "B\(id)", "threadId": threadId ?? "T\(id)",
                "mailboxIds": [mailbox: true],
                "keywords": Dictionary(uniqueKeysWithValues: keywords.map { ($0, true) }),
                "size": text.utf8.count + 400,
                "receivedAt": JMAPCoding.formatUTCDate(receivedAt),
                "sentAt": JMAPCoding.formatUTCDate(receivedAt),
                "from": [["name": from.name, "email": from.email]],
                "to": [["name": "You", "email": to]],
                "cc": [Any](), "replyTo": [Any](),
                "subject": subject,
                "preview": String(text.prefix(180)),
                "hasAttachment": false,
                "messageId": ["<\(id)@demo.sift>"], "inReplyTo": NSNull(), "references": NSNull(),
            ]
            bodies[id] = (html ?? "<p>\(HTMLText.escape(text))</p>", text)
            record(created: [id])
            return id
        }
    }

    public func emailMailboxes(_ id: String) -> Set<String> {
        locked { Set((emails[id]?["mailboxIds"] as? [String: Bool] ?? [:]).keys) }
    }

    public func emailKeywords(_ id: String) -> Set<String> {
        locked { Set((emails[id]?["keywords"] as? [String: Bool] ?? [:]).keys) }
    }

    public func mailboxId(named name: String) -> String? {
        locked { mailboxes.values.first { $0["name"] as? String == name }?["id"] as? String }
    }

    public func mailboxSortOrder(_ id: String) -> Int? {
        locked { mailboxes[id]?["sortOrder"] as? Int }
    }

    /// Sift's contact groups, as raw JSON.
    public func siftGroups() -> [[String: Any]] {
        locked {
            cards.values.filter {
                ($0["kind"] as? String) == "group"
                    && ((($0["name"] as? [String: Any])?["full"] as? String)?.hasPrefix("Sift") ?? false)
            }
        }
    }

    public var individualCardCount: Int {
        locked { cards.values.filter { ($0["kind"] as? String) != "group" }.count }
    }

    /// Adds a contact to the default address book. Returns its uid.
    @discardableResult
    public func addContact(name: String, email: String) -> String {
        locked {
            let id = "C\(nextId)"
            nextId += 1
            let uid = "urn:uuid:\(UUID().uuidString.lowercased())"
            cards[id] = ["id": id, "uid": uid, "kind": "individual",
                         "name": ["full": name], "emails": ["e1": ["address": email]], "addressBookIds": ["personal": true]]
            cardState += 1
            return uid
        }
    }

    /// What a user does in Fastmail's UI: drag a contact into a group.
    public func addMember(_ memberKey: String, toGroupNamed name: String) {
        locked {
            guard let (id, card) = cards.first(where: { (($0.value["name"] as? [String: Any])?["full"] as? String) == name }) else { return }
            var members = card["members"] as? [String: Bool] ?? [:]
            members[memberKey] = true
            cards[id]?["members"] = members
            cardState += 1
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func record(created: Set<String> = [], updated: Set<String> = [], destroyed: Set<String> = []) {
        emailState += 1
        changeLog.append((emailState, created, updated, destroyed))
    }

    // MARK: - HTTP

    /// How long to hold this request before handling it (only Email/set, when
    /// `emailSetDelay` is set). Other requests keep flowing meanwhile.
    func delay(for body: Data?) -> TimeInterval {
        guard emailSetDelay > 0, let body,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let calls = root["methodCalls"] as? [[Any]],
              calls.contains(where: { $0.first as? String == "Email/set" }) else { return 0 }
        return emailSetDelay
    }

    func respond(to request: URLRequest, body: Data?) -> (Int, Data, String) {
        guard let url = request.url else { return (400, Data(), "text/plain") }
        switch url.path {
        case "/jmap/session":
            return (200, json(sessionObject()), "application/json")
        case "/jmap/api", "/jmap/api/":
            guard let body, let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let calls = root["methodCalls"] as? [[Any]] else { return (400, Data(), "text/plain") }

            let responses = locked { handle(calls) }
            return (200, json(["methodResponses": responses, "sessionState": "demo"]), "application/json")
        case let path where path.hasPrefix("/jmap/download/"):
            let parts = path.split(separator: "/")
            let blobId = parts.count > 3 ? String(parts[3]) : ""
            if let data = locked({ blobs[blobId] }) { return (200, data, "application/octet-stream") }
            let id = String(blobId.dropFirst())
            let text = locked { bodies[id]?.text } ?? ""
            return (200, Data(text.utf8), "text/plain")
        case let path where path.hasPrefix("/jmap/upload/"):
            let data = body ?? Data()
            let type = request.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            let blobId = locked {
                let id = "U\(nextId)"
                nextId += 1
                blobs[id] = data
                return id
            }
            return (201, json(["accountId": "A1", "blobId": blobId, "type": type, "size": data.count]), "application/json")
        default:
            // No EventSource in the demo; SyncEngine falls back to periodic refresh.
            return (404, Data(), "text/plain")
        }
    }

    private func sessionObject() -> [String: Any] {
        [
            "apiUrl": "https://\(Self.host)/jmap/api/",
            "downloadUrl": "https://\(Self.host)/jmap/download/{accountId}/{blobId}/{name}?type={type}",
            "uploadUrl": "https://\(Self.host)/jmap/upload/{accountId}/",
            "eventSourceUrl": "https://\(Self.host)/jmap/event/?types={types}&closeafter={closeafter}&ping={ping}",
            "username": "you@fastmail.com",
            "state": "demo",
            "accounts": ["A1": [
                "name": "you@fastmail.com", "isReadOnly": false,
                "accountCapabilities": [
                    JMAPCapability.mail: [String: Any](), JMAPCapability.submission: [String: Any](),
                    JMAPCapability.contacts: [String: Any](),
                ],
            ]],
            "primaryAccounts": [
                JMAPCapability.mail: "A1", JMAPCapability.submission: "A1", JMAPCapability.contacts: "A1",
            ],
            "capabilities": [
                JMAPCapability.core: ["maxSizeUpload": 50_000_000], JMAPCapability.mail: [String: Any](),
                JMAPCapability.submission: ["maxDelayedSend": maxDelayedSend], JMAPCapability.contacts: [String: Any](),
            ],
        ]
    }

    private func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    // MARK: - Method dispatch

    private func handle(_ calls: [[Any]]) -> [[Any]] {
        deliverDue()
        var responses: [[Any]] = []
        for call in calls {
            guard call.count == 3, let name = call[0] as? String, var args = call[1] as? [String: Any],
                  let callId = call[2] as? String else { continue }
            // Resolve "#prop" result references against earlier responses.
            for (key, value) in args where key.hasPrefix("#") {
                if let ref = value as? [String: Any], let resultOf = ref["resultOf"] as? String,
                   let path = ref["path"] as? String,
                   let prior = responses.last(where: { $0[2] as? String == resultOf })?[1] as? [String: Any] {
                    args[String(key.dropFirst())] = prior[String(path.dropFirst())] ?? []
                }
                args[key] = nil
            }
            let result: [[Any]]
            switch name {
            case "Mailbox/get": result = [[name, mailboxGet(), callId]]
            case "Mailbox/set": result = [[name, mailboxSet(args), callId]]
            case "Identity/get":
                result = [[name, ["accountId": "A1", "state": "1",
                                  "list": [["id": "I1", "name": "You", "email": "you@fastmail.com"]]], callId]]
            case "Email/query": result = [[name, emailQuery(args), callId]]
            case "Email/get": result = [[name, emailGet(args), callId]]
            case "Email/set":
                result = failsEmailSet ? [["error", ["type": "serverFail", "description": "demo failure"], callId]]
                                       : [[name, emailSet(args), callId]]
            case "Email/changes":
                let changes = emailChanges(args)
                result = [[changes == nil ? "error" : name, changes ?? ["type": "cannotCalculateChanges"], callId]]
            case "EmailSubmission/set": result = emailSubmissionSet(args, callId: callId, responses: responses)
            case "EmailSubmission/query":
                let status = (args["filter"] as? [String: Any])?["undoStatus"] as? String
                let ids = submissions.filter { status == nil || $0.value.undoStatus == status }.keys.sorted()
                result = [[name, ["accountId": "A1", "ids": ids, "position": 0, "total": ids.count], callId]]
            case "EmailSubmission/get":
                let ids = args["ids"] as? [String] ?? Array(submissions.keys)
                let list = ids.compactMap { id -> [String: Any]? in
                    guard let s = submissions[id] else { return nil }
                    return ["id": id, "threadId": s.threadId ?? NSNull(), "undoStatus": s.undoStatus,
                            "sendAt": JMAPCoding.formatUTCDate(s.sendAt),
                            "envelope": ["mailFrom": ["email": "you@fastmail.com"], "rcptTo": s.rcptTo.map { ["email": $0] }]]
                }
                result = [[name, ["accountId": "A1", "state": "1", "list": list], callId]]
            case "SearchSnippet/get": result = [[name, searchSnippets(args), callId]]
            case "AddressBook/get":
                result = [[name, ["accountId": "A1", "state": "\(cardState)", "list": Array(books.values)], callId]]
            case "AddressBook/set": result = [[name, addressBookSet(args), callId]]
            case "ContactCard/query":
                let ids = cards.keys.sorted()
                let position = args["position"] as? Int ?? 0
                let limit = args["limit"] as? Int ?? ids.count
                result = [[name, ["accountId": "A1", "ids": Array(ids.dropFirst(position).prefix(limit)), "position": position], callId]]
            case "ContactCard/get":
                let ids = args["ids"] as? [String] ?? Array(cards.keys)
                result = [[name, ["accountId": "A1", "state": "\(cardState)", "list": ids.compactMap { cards[$0] }], callId]]
            case "ContactCard/set": result = [[name, cardSet(args), callId]]
            default:
                result = [["error", ["type": "unknownMethod"], callId]]
            }
            responses += result
        }
        return responses
    }

    private func mailboxGet() -> [String: Any] {
        let list = mailboxes.values.map { box -> [String: Any] in
            var box = box
            let id = box["id"] as! String
            let inside = emails.values.filter { ($0["mailboxIds"] as? [String: Bool])?[id] == true }
            box["totalEmails"] = inside.count
            box["unreadEmails"] = inside.filter { ($0["keywords"] as? [String: Bool])?["$seen"] != true }.count
            return box
        }
        return ["accountId": "A1", "state": "\(mailboxState)-\(emailState)", "list": list]
    }

    private func mailboxSet(_ args: [String: Any]) -> [String: Any] {
        var created: [String: Any] = [:]
        for (key, value) in args["create"] as? [String: [String: Any]] ?? [:] {
            let id = "MB\(nextId)"
            nextId += 1
            mailboxes[id] = ["id": id, "name": value["name"] ?? "Untitled", "parentId": NSNull(), "role": NSNull(), "sortOrder": 20]
            created[key] = ["id": id]
        }
        var updated: [String: Any] = [:]
        for (id, patch) in args["update"] as? [String: [String: Any]] ?? [:] where mailboxes[id] != nil {
            for (key, value) in patch { mailboxes[id]?[key] = value }
            updated[id] = NSNull()
        }
        var destroyed: [String] = []
        var notDestroyed: [String: Any] = [:]
        for id in args["destroy"] as? [String] ?? [] {
            let inUse = emails.values.contains { ($0["mailboxIds"] as? [String: Bool])?[id] == true }
            if inUse {
                notDestroyed[id] = ["type": "mailboxHasEmail"]
            } else {
                mailboxes[id] = nil
                destroyed.append(id)
            }
        }
        mailboxState += 1
        var result: [String: Any] = ["accountId": "A1", "newState": "\(mailboxState)", "created": created,
                                     "updated": updated, "destroyed": destroyed]
        if !notDestroyed.isEmpty { result["notDestroyed"] = notDestroyed }
        return result
    }

    private func emailQuery(_ args: [String: Any]) -> [String: Any] {
        let filter = args["filter"] as? [String: Any]
        var list = emails.values.filter { matches($0, filter) }
        list.sort { ($0["receivedAt"] as! String) > ($1["receivedAt"] as! String) }
        let ids = list.map { $0["id"] as! String }
        let position = args["position"] as? Int ?? 0
        let limit = args["limit"] as? Int ?? ids.count
        return ["accountId": "A1", "queryState": "\(emailState)", "position": position, "total": ids.count,
                "ids": Array(ids.dropFirst(position).prefix(limit))]
    }

    private func matches(_ email: [String: Any], _ filter: [String: Any]?) -> Bool {
        guard let filter else { return true }
        if let op = filter["operator"] as? String, let conditions = filter["conditions"] as? [[String: Any]] {
            switch op {
            case "AND": return conditions.allSatisfy { matches(email, $0) }
            case "OR": return conditions.contains { matches(email, $0) }
            default: return !conditions.contains { matches(email, $0) }
            }
        }
        let boxes = email["mailboxIds"] as? [String: Bool] ?? [:]
        let keywords = email["keywords"] as? [String: Bool] ?? [:]
        let received = email["receivedAt"] as? String ?? ""
        let from = ((email["from"] as? [[String: Any]])?.first).map { "\($0["name"] ?? "") \($0["email"] ?? "")" } ?? ""
        let subject = email["subject"] as? String ?? ""
        let body = bodies[email["id"] as? String ?? ""]?.text ?? ""
        func contains(_ haystack: String, _ key: String) -> Bool {
            guard let needle = filter[key] as? String else { return true }
            return haystack.localizedCaseInsensitiveContains(needle)
        }
        if let id = filter["inMailbox"] as? String, boxes[id] != true { return false }
        if let date = filter["before"] as? String, received >= date { return false }
        if let date = filter["after"] as? String, received < date { return false }
        if let keyword = filter["hasKeyword"] as? String, keywords[keyword] != true { return false }
        if let keyword = filter["notKeyword"] as? String, keywords[keyword] == true { return false }
        return contains(from, "from") && contains(subject, "subject") && contains(body, "body")
            && contains("\(from) \(subject) \(body)", "text")
    }

    private func emailGet(_ args: [String: Any]) -> [String: Any] {
        let ids = args["ids"] as? [String] ?? Array(emails.keys)
        let properties = Set(args["properties"] as? [String] ?? [])
        let list = ids.compactMap { id -> [String: Any]? in
            guard var email = emails[id] else { return nil }
            if properties.contains("htmlBody") || properties.contains("textBody"), let body = bodies[id] {
                email["htmlBody"] = [["partId": "1", "blobId": "B\(id)", "type": body.html == nil ? "text/plain" : "text/html", "size": 100]]
                email["textBody"] = [["partId": "2", "blobId": "B\(id)", "type": "text/plain", "size": 100]]
                email["attachments"] = email["attachments"] ?? [Any]()
                var values: [String: Any] = ["2": ["value": body.text]]
                values["1"] = ["value": body.html ?? body.text]
                email["bodyValues"] = values
            }
            return email
        }
        return ["accountId": "A1", "state": "\(emailState)", "list": list, "notFound": ids.filter { emails[$0] == nil }]
    }

    private func emailSet(_ args: [String: Any]) -> [String: Any] {
        var updated: [String: Any] = [:]
        var notUpdated: [String: Any] = [:]
        var created: [String: Any] = [:]
        for (id, patch) in args["update"] as? [String: [String: Any]] ?? [:] {
            guard emails[id] != nil else {
                notUpdated[id] = ["type": "notFound"]
                continue
            }
            apply(patch, to: id)
            updated[id] = NSNull()
        }
        for (key, value) in args["create"] as? [String: [String: Any]] ?? [:] {
            let id = "M\(nextId)"
            nextId += 1
            var email = value
            email["id"] = id
            // Thread like Fastmail: a reply joins the conversation it references.
            let referenced = (value["inReplyTo"] as? [String] ?? []) + (value["references"] as? [String] ?? [])
            let thread = emails.values.first { existing in
                (existing["messageId"] as? [String] ?? []).contains(where: referenced.contains)
            }?["threadId"] as? String
            email["threadId"] = thread ?? "T\(id)"
            if email["messageId"] == nil { email["messageId"] = ["<\(id)@demo.sift>"] }
            email["blobId"] = "B\(id)"
            email["receivedAt"] = JMAPCoding.formatUTCDate(.now)
            let text = ((value["bodyValues"] as? [String: [String: Any]])?.values.first?["value"] as? String) ?? ""
            email["preview"] = String(text.prefix(180))
            email["hasAttachment"] = !((value["attachments"] as? [Any]) ?? []).isEmpty
            email["size"] = text.utf8.count
            emails[id] = email
            bodies[id] = (nil, text)
            created[key] = ["id": id, "threadId": email["threadId"] ?? "T\(id)", "blobId": "B\(id)"]
        }
        var destroyed: [String] = []
        for id in args["destroy"] as? [String] ?? [] where emails[id] != nil {
            emails[id] = nil
            bodies[id] = nil
            destroyed.append(id)
        }
        if !updated.isEmpty || !created.isEmpty || !destroyed.isEmpty {
            record(created: Set(created.values.compactMap { ($0 as? [String: Any])?["id"] as? String }),
                   updated: Set(updated.keys), destroyed: Set(destroyed))
        }
        var result: [String: Any] = ["accountId": "A1", "newState": "\(emailState)", "updated": updated,
                                     "created": created, "destroyed": destroyed]
        if !notUpdated.isEmpty { result["notUpdated"] = notUpdated }
        return result
    }

    private func apply(_ patch: [String: Any], to id: String) {
        guard var email = emails[id] else { return }
        for (path, value) in patch {
            let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, var map = email[parts[0]] as? [String: Bool] {
                if value is NSNull { map[parts[1]] = nil } else { map[parts[1]] = true }
                email[parts[0]] = map
            } else {
                email[path] = value
            }
        }
        emails[id] = email
    }

    private func emailChanges(_ args: [String: Any]) -> [String: Any]? {
        guard let since = (args["sinceState"] as? String).flatMap(Int.init), since <= emailState,
              since >= (changeLog.first?.state ?? 1) - 1 else { return nil }
        var created = Set<String>(), updated = Set<String>(), destroyed = Set<String>()
        for entry in changeLog where entry.state > since {
            created.formUnion(entry.created)
            updated.formUnion(entry.updated.subtracting(created))
            destroyed.formUnion(entry.destroyed)
        }
        return ["accountId": "A1", "oldState": "\(since)", "newState": "\(emailState)", "hasMoreChanges": false,
                "created": Array(created), "updated": Array(updated), "destroyed": Array(destroyed)]
    }

    private func emailSubmissionSet(_ args: [String: Any], callId: String, responses: [[Any]]) -> [[Any]] {
        var created: [String: Any] = [:]
        var updates: [String: [String: Any]] = [:]
        let onSuccess = args["onSuccessUpdateEmail"] as? [String: [String: Any]] ?? [:]
        for (key, value) in args["create"] as? [String: [String: Any]] ?? [:] {
            var emailId = value["emailId"] as? String ?? ""
            if emailId.hasPrefix("#") {
                let ref = String(emailId.dropFirst())
                for response in responses {
                    if let createdMap = (response[1] as? [String: Any])?["created"] as? [String: [String: Any]],
                       let id = createdMap[ref]?["id"] as? String {
                        emailId = id
                    }
                }
            }
            let submissionId = "S\(nextId)"
            nextId += 1
            let envelope = value["envelope"] as? [String: Any]
            let hold = (((envelope?["mailFrom"] as? [String: Any])?["parameters"] as? [String: Any])?["HOLDFOR"] as? String).flatMap(Int.init) ?? 0
            let rcpt = (envelope?["rcptTo"] as? [[String: Any]] ?? []).compactMap { $0["email"] as? String }
            submissions[submissionId] = Submission(
                emailId: emailId, undoStatus: hold > 0 ? "pending" : "final", holdFor: hold,
                threadId: emails[emailId]?["threadId"] as? String, sendAt: .now.addingTimeInterval(TimeInterval(hold)),
                rcptTo: rcpt, copy: hold > 0 ? emails[emailId] : nil, text: bodies[emailId]?.text ?? "")
            created[key] = ["id": submissionId, "undoStatus": hold > 0 ? "pending" : "final"]
            if let patch = onSuccess["#\(key)"] { updates[emailId] = patch }
            if (args["onSuccessDestroyEmail"] as? [String] ?? []).contains("#\(key)") {
                emails[emailId] = nil
                bodies[emailId] = nil
                record(destroyed: [emailId])
            }
        }
        var updated: [String: Any] = [:]
        var notUpdated: [String: Any] = [:]
        for (id, patch) in args["update"] as? [String: [String: Any]] ?? [:] {
            if patch["undoStatus"] as? String == "canceled", submissions[id]?.undoStatus == "pending" {
                submissions[id]?.undoStatus = "canceled"
                updated[id] = NSNull()
            } else {
                notUpdated[id] = ["type": "cannotUnsend", "description": "Already sent"]
            }
        }
        var response: [String: Any] = ["accountId": "A1", "created": created, "updated": updated]
        if !notUpdated.isEmpty { response["notUpdated"] = notUpdated }
        var result: [[Any]] = [["EmailSubmission/set", response, callId]]
        if !updates.isEmpty {
            result.append(["Email/set", emailSet(["update": updates]), callId])
        }
        return result
    }

    private func searchSnippets(_ args: [String: Any]) -> [String: Any] {
        let ids = args["emailIds"] as? [String] ?? []
        return ["accountId": "A1", "list": ids.map { id in
            ["emailId": id, "subject": emails[id]?["subject"] ?? NSNull(), "preview": emails[id]?["preview"] ?? NSNull()]
        }]
    }

    private func addressBookSet(_ args: [String: Any]) -> [String: Any] {
        // Fastmail's answer, verbatim.
        var notCreated: [String: Any] = [:]
        for key in (args["create"] as? [String: Any] ?? [:]).keys {
            notCreated[key] = ["type": "forbidden", "description": "AddressBooks may not be created"]
        }
        return ["accountId": "A1", "newState": "\(cardState)", "notCreated": notCreated]
    }

    private func cardSet(_ args: [String: Any]) -> [String: Any] {
        var created: [String: Any] = [:]
        var updated: [String: Any] = [:]
        var notCreated: [String: Any] = [:]
        var notUpdated: [String: Any] = [:]
        let rejection: [String: Any] = ["type": "invalidProperties", "properties": ["members"],
                                        "description": "members must be contact uids"]
        func hasAddressMember(_ keys: some Sequence<String>) -> Bool {
            rejectsAddressMembers && keys.contains { $0.hasPrefix("mailto:") || $0.hasPrefix("members/mailto:") }
        }
        for (key, value) in args["create"] as? [String: [String: Any]] ?? [:] {
            if hasAddressMember((value["members"] as? [String: Any] ?? [:]).keys) {
                notCreated[key] = rejection
                continue
            }
            let id = "C\(nextId)"
            nextId += 1
            var card = value
            card["id"] = id
            cards[id] = card
            created[key] = ["id": id]
        }
        for (id, patch) in args["update"] as? [String: [String: Any]] ?? [:] {
            guard var card = cards[id] else { continue }
            if hasAddressMember(patch.keys) {
                notUpdated[id] = rejection
                continue
            }
            for (path, value) in patch {
                let parts = path.split(separator: "/", maxSplits: 1).map(String.init)
                if parts.count == 2 {
                    let key = parts[1].replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                    var map = card[parts[0]] as? [String: Any] ?? [:]
                    map[key] = value is NSNull ? nil : value
                    card[parts[0]] = map
                } else {
                    card[path] = value is NSNull ? nil : value
                }
            }
            cards[id] = card
            updated[id] = NSNull()
        }
        cardState += 1
        var result: [String: Any] = ["accountId": "A1", "newState": "\(cardState)", "created": created, "updated": updated]
        if !notCreated.isEmpty { result["notCreated"] = notCreated }
        if !notUpdated.isEmpty { result["notUpdated"] = notUpdated }
        return result
    }
}

final class DemoURLProtocol: URLProtocol, @unchecked Sendable {
    static let header = "X-Sift-Demo"
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var servers: [String: DemoServer] = [:]

    static func register(_ server: DemoServer, id: String) {
        registryLock.withLock { servers[id] = server }
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host() == DemoServer.host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: Self.header) ?? ""
        guard let server = Self.registryLock.withLock({ Self.servers[id] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        let request = self.request
        let delay = server.delay(for: body)
        guard delay > 0 else {
            finish(server.respond(to: request, body: body), url: url)
            return
        }
        // Handle it later without blocking the loading thread, then report back
        // on that thread's run loop, as URLProtocol expects.
        let runLoop = CFRunLoopGetCurrent()
        let payload = body
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
            let result = server.respond(to: request, body: payload)
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { self.finish(result, url: url) }
            CFRunLoopWakeUp(runLoop)
        }
    }

    private func finish(_ result: (Int, Data, String), url: URL) {
        let (status, data, type) = result
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
