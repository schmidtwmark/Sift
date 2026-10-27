import Foundation
import GRDB
import Testing
@testable import SiftKit

// MARK: - Fixtures

func email(
    _ id: String,
    from: String,
    name: String? = nil,
    subject: String = "Hello",
    preview: String = "",
    mailboxes: [String] = ["inbox"],
    keywords: [String] = [],
    received: Date = Date(timeIntervalSince1970: 2_000_000_000),
    thread: String? = nil
) -> Email {
    Email(
        id: id, blobId: "b-\(id)", threadId: thread ?? "t-\(id)",
        mailboxIds: Dictionary(uniqueKeysWithValues: mailboxes.map { ($0, true) }),
        keywords: Dictionary(uniqueKeysWithValues: keywords.map { ($0, true) }),
        size: 100, receivedAt: received, sentAt: nil,
        from: [EmailAddress(name: name, email: from)], to: [EmailAddress(email: "me@fastmail.com")],
        cc: nil, bcc: nil, replyTo: nil, subject: subject, preview: preview, hasAttachment: false,
        messageId: ["<\(id)@x>"], inReplyTo: nil, references: nil,
        htmlBody: nil, textBody: nil, attachments: nil, bodyValues: nil
    )
}

let boxes = SpecialMailboxes(inbox: "inbox", screener: "screener", screenedOut: "out",
                             archive: "archive", trash: "trash", junk: "junk", sent: "sent", drafts: "drafts")

// MARK: - Search parsing

@Suite struct SearchQueryTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @Test func parsesOperatorsPhrasesAndNegation() {
        let query = SearchQuery(#"invoice from:stripe -subject:"payment failed" has:attachment is:unread in:Receipts"#,
                                now: now, calendar: calendar)
        #expect(query.clauses == [
            .init(term: .match(.text, "invoice"), negated: false),
            .init(term: .match(.from, "stripe"), negated: false),
            .init(term: .match(.subject, "payment failed"), negated: true),
            .init(term: .hasAttachment, negated: false),
            .init(term: .unread, negated: false),
            .init(term: .inMailbox("Receipts"), negated: false),
        ])
        #expect(query.highlightTerms == ["invoice", "stripe"])
    }

    @Test func parsesRelativeAndAbsoluteDates() throws {
        let relative = SearchQuery("after:7d", now: now, calendar: calendar)
        #expect(relative.clauses.first?.term == .after(now.addingTimeInterval(-7 * 86_400)))
        let absolute = SearchQuery("before:2026-03-01", now: now, calendar: calendar)
        let expected = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)))
        #expect(absolute.clauses.first?.term == .before(expected))
    }

    @Test func orJoinsNeighbours() {
        let query = SearchQuery("climbing from:alex OR from:sam OR from:kim -is:unread")
        #expect(query.clauses == [
            .init(term: .match(.text, "climbing"), negated: false),
            .init(term: .anyOf([
                .init(term: .match(.from, "alex"), negated: false),
                .init(term: .match(.from, "sam"), negated: false),
                .init(term: .match(.from, "kim"), negated: false),
            ]), negated: false),
            .init(term: .unread, negated: true),
        ])
        #expect(SearchQuery("tacos OR climbing").jmapFilter(mailboxIdsByName: [:]) == [
            "operator": "OR", "conditions": [["text": "tacos"], ["text": "climbing"]],
        ])
        // A lowercase "or" is just a word.
        #expect(SearchQuery("this or that").clauses.count == 3)
    }

    @Test func isReadIsNegatedUnread() {
        #expect(SearchQuery("is:read").clauses == [.init(term: .unread, negated: true)])
    }

    @Test func unknownKeysAreSearchedLiterally() {
        #expect(SearchQuery("re:lunch").clauses == [.init(term: .match(.text, "re:lunch"), negated: false)])
    }

    @Test func buildsJMAPFilter() {
        let filter = SearchQuery("from:stripe -is:unread in:receipts").jmapFilter(mailboxIdsByName: ["receipts": "M1"])
        #expect(filter == [
            "operator": "AND",
            "conditions": [
                ["from": "stripe"],
                ["hasKeyword": "$seen"],
                ["inMailbox": "M1"],
            ],
        ])
    }

    @Test func ftsExpressionsArePrefixPhrases() {
        #expect(SearchQuery.ftsExpression(field: .from, value: "john.smith@") == #"sender : ("john" + "smith" *)"#)
        #expect(SearchQuery.ftsExpression(field: .text, value: "!!!") == nil)
    }
}

// MARK: - Routing

@Suite struct RouterTests {
    let activated = Date(timeIntervalSince1970: 1_900_000_000)

    func context(rules: [SenderRecord] = [], known: Set<String> = []) -> RoutingContext {
        RoutingContext(mailboxes: boxes, activatedAt: activated, ownAddresses: ["me@fastmail.com"],
                       knownAddresses: known, rules: Dictionary(uniqueKeysWithValues: rules.map { ($0.email, $0) }))
    }

    @Test func unknownSendersGoToTheScreener() {
        let plan = Router.plan(for: [MessageRecord(email("1", from: "New@Example.com"))], context: context())
        #expect(plan.patches["1"] == [
            "keywords/$siftrouted": true,
            "mailboxIds/inbox": .null,
            "mailboxIds/screener": true,
        ])
    }

    @Test func screenedInSendersAreFiledIntoTheirLabels() {
        let rule = SenderRecord(email: "news@acme.com", status: .screenedIn, labelIds: ["feed"])
        let plan = Router.plan(for: [MessageRecord(email("1", from: "news@acme.com"))], context: context(rules: [rule]))
        #expect(plan.patches["1"] == [
            "keywords/$siftrouted": true,
            "mailboxIds/inbox": .null,
            "mailboxIds/feed": true,
        ])
    }

    @Test func screenedInWithoutLabelsStaysInInbox() {
        let rule = SenderRecord(email: "pal@acme.com", status: .screenedIn)
        let plan = Router.plan(for: [MessageRecord(email("1", from: "pal@acme.com"))], context: context(rules: [rule]))
        #expect(plan.patches["1"]?["mailboxIds/inbox"] == true)
        #expect(plan.patches["1"]?["mailboxIds/screener"] == nil)
    }

    @Test func screenedOutSendersAreHiddenAndMarkedRead() {
        let rule = SenderRecord(email: "spam@acme.com", status: .screenedOut)
        let plan = Router.plan(for: [MessageRecord(email("1", from: "spam@acme.com"))], context: context(rules: [rule]))
        #expect(plan.patches["1"]?["mailboxIds/out"] == true)
        #expect(plan.patches["1"]?["mailboxIds/inbox"] == .null)
        #expect(plan.patches["1"]?["keywords/$seen"] == true)
    }

    @Test func contactsAreAutoApprovedOnce() {
        let messages = [email("1", from: "friend@x.com"), email("2", from: "friend@x.com")].map(MessageRecord.init)
        let plan = Router.plan(for: messages, context: context(known: ["friend@x.com"]))
        #expect(plan.autoApproved.map(\.normalized) == ["friend@x.com"])
        #expect(plan.patches["1"] == ["keywords/$siftrouted": true])
    }

    @Test func skipsGrandfatheredRoutedAndOwnMail() {
        let old = email("old", from: "a@x.com", received: activated.addingTimeInterval(-1))
        let routed = email("routed", from: "a@x.com", keywords: ["$siftrouted"])
        let elsewhere = email("junk", from: "a@x.com", mailboxes: ["junk"])
        let plan = Router.plan(for: [old, routed, elsewhere].map(MessageRecord.init), context: context())
        #expect(plan.patches.isEmpty)

        let mine = Router.plan(for: [MessageRecord(email("me", from: "me@fastmail.com"))], context: context())
        #expect(mine.patches["me"] == ["keywords/$siftrouted": true])
    }

    @Test func spamFromScreenedInSendersComesBackOut() {
        let rule = SenderRecord(email: "news@acme.com", status: .screenedIn, labelIds: ["feed"])
        let spam = MessageRecord(email("1", from: "news@acme.com", mailboxes: ["junk"], keywords: ["$junk"]))
        #expect(Router.plan(for: [spam], context: context(rules: [rule])).patches["1"] == [
            "mailboxIds/junk": .null, "mailboxIds/feed": true,
            "keywords/$notjunk": true, "keywords/$junk": .null, "keywords/$siftrouted": true,
        ])
        // Screened in to the Inbox.
        let pal = SenderRecord(email: "pal@acme.com", status: .screenedIn)
        let fromPal = MessageRecord(email("2", from: "pal@acme.com", mailboxes: ["junk"]))
        #expect(Router.plan(for: [fromPal], context: context(rules: [pal])).patches["2"]?["mailboxIds/inbox"] == true)
    }

    @Test func otherSpamStaysPut() {
        let out = SenderRecord(email: "out@acme.com", status: .screenedOut)
        let pal = SenderRecord(email: "pal@acme.com", status: .screenedIn)
        let messages = [
            email("unknown", from: "who@x.com", mailboxes: ["junk"]),
            email("contact", from: "friend@x.com", mailboxes: ["junk"]),
            email("out", from: "out@acme.com", mailboxes: ["junk"]),
            email("old", from: "pal@acme.com", mailboxes: ["junk"], received: activated.addingTimeInterval(-1)),
            email("moved", from: "pal@acme.com", mailboxes: ["junk"], keywords: ["$siftrouted"]),
        ].map(MessageRecord.init)
        let plan = Router.plan(for: messages, context: context(rules: [out, pal], known: ["friend@x.com"]))
        #expect(plan.patches.isEmpty)
        #expect(plan.autoApproved.isEmpty)
    }

    @Test func spoofedSpamStaysInSpam() {
        let pal = SenderRecord(email: "pal@acme.com", status: .screenedIn)
        let spam = MessageRecord(email("1", from: "pal@acme.com", mailboxes: ["junk"]))
        var context = context(rules: [pal])
        context.unauthenticated = ["1"]
        // Sorted once, so it isn't checked again, but left in Spam.
        #expect(Router.plan(for: [spam], context: context).patches["1"] == ["keywords/$siftrouted": true])
    }

    @Test func readsFastmailsDMARCVerdict() {
        let pass = "mx4.messagingengine.com; dkim=pass header.d=acme.com; dmarc=pass (p=reject) header.from=acme.com; spf=pass"
        let fail = "mx4.messagingengine.com; dkim=none; dmarc=fail (p=none,has-list-id=no) header.from=acme.com; spf=softfail"
        #expect(!Router.failedDMARC([]))
        #expect(!Router.failedDMARC([pass]))
        #expect(Router.failedDMARC([fail]))
        // Only the topmost (Fastmail's own) verdict counts, not one the sender wrote.
        #expect(!Router.failedDMARC([pass, fail]))
        #expect(!Router.failedDMARC(["mx4.messagingengine.com; dmarc=none header.from=acme.com"]))
    }

    @Test func screenInReleasesIntoInboxWhenNoLabels() {
        let waiting = MessageRecord(email("1", from: "a@x.com", mailboxes: ["screener"]))
        #expect(Router.screenIn([waiting], labels: [], mailboxes: boxes)["1"] == [
            "mailboxIds/screener": .null, "mailboxIds/inbox": true,
        ])
        let filed = Router.screenIn([waiting], labels: ["feed", "inbox"], mailboxes: boxes)["1"]
        #expect(filed == ["mailboxIds/screener": .null, "mailboxIds/feed": true, "mailboxIds/inbox": true])
    }

    @Test func patchesApplyLocally() {
        let message = MessageRecord(email("1", from: "a@x.com"))
        let moved = message.applying(["mailboxIds/inbox": .null, "mailboxIds/feed": true, "keywords/$seen": true])
        #expect(moved.mailboxIds == ["feed"])
        #expect(!moved.isUnread)
    }
}

// MARK: - Spy pixels

@Suite struct TrackerDetectorTests {
    @Test func removesKnownServicesAndNamesThem() {
        let html = #"<p>Hi</p><img src="https://acme.us1.list-manage.com/track/open.php?u=1" width="1" height="1"><img src="https://cdn.acme.com/logo.png" width="200" height="50">"#
        let result = TrackerDetector.sanitize(html)
        #expect(result.trackers.map(\.name) == ["Mailchimp"])
        #expect(result.trackers.first?.reason == .knownService)
        #expect(!result.html.contains("list-manage"))
        #expect(result.html.contains("logo.png"))
        #expect(result.remoteImageCount == 1)
        #expect(result.trackerSummary == "Mailchimp")
    }

    @Test func catchesTinyHiddenAndBeaconImages() {
        let tiny = #"<img src="https://news.example.co.uk/x/abc" style="width: 1px; height: 1px">"#
        let hidden = #"<img src='https://t.example.com/p' style="display:none">"#
        let beacon = #"<img src=https://mail.example.org/open?id=42>"#
        let result = TrackerDetector.sanitize(tiny + hidden + beacon)
        #expect(result.trackers.map(\.reason) == [.tinyImage, .hiddenImage, .beaconPath])
        #expect(result.trackers.first?.name == "example.co.uk")
        #expect(!result.html.contains("<img"))
    }

    @Test func leavesLocalAndOrdinaryImagesAlone() {
        let html = #"<img src="cid:logo"><img src="data:image/png;base64,AA" width="1" height="1"><img src="https://x.com/hero.jpg" width="1" height="400">"#
        let result = TrackerDetector.sanitize(html)
        #expect(result.trackers.isEmpty)
        #expect(result.remoteImageCount == 1)
    }

    @Test func detectsMailgunOpenPixels() {
        let html = #"<img src="https://email.mg.substack.com/o/eJwlj">"#
        #expect(TrackerDetector.sanitize(html).trackers.first?.name == "Substack" ||
                TrackerDetector.sanitize(html).trackers.first?.name == "Mailgun")
    }

    @Test func stripsScriptsFramesAndRemoteStylesheets() {
        let html = #"<script>alert(1)</script><iframe src="https://x.com"></iframe><link rel="stylesheet" href="https://x.com/a.css"><b>ok</b>"#
        #expect(TrackerDetector.sanitize(html).html == "<b>ok</b>")
    }

    @Test func contentBlockerJSONIsValid() throws {
        let data = Data(ContentBlockerRules.trackersJSON().utf8)
        let rules = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(rules.count == TrackerList.rules.count)
        #expect(ContentBlockerRules.urlFilter(for: TrackerRule("X", host: "mjt.lu", path: "/oo/")) == #"^https?://[^/]*mjt\.lu.*/oo/"#)
    }
}

// MARK: - Store

@Suite struct MailStoreTests {
    @Test func threadsCollapseAndCount() async throws {
        let store = try MailStore.inMemory()
        try await store.upsert([
            email("1", from: "a@x.com", name: "Ann", received: Date(timeIntervalSince1970: 100), thread: "T"),
            email("2", from: "b@x.com", name: "Bo", keywords: ["$seen"], received: Date(timeIntervalSince1970: 200), thread: "T"),
            email("3", from: "c@x.com", mailboxes: ["feed"], received: Date(timeIntervalSince1970: 300)),
        ])
        let inbox = try await store.writer.read { db in try MailStore.threads(in: "inbox", limit: 50, in: db) }
        #expect(inbox.map(\.latest.id) == ["2"])
        #expect(inbox.first?.messageCount == 2)
        #expect(inbox.first?.unreadCount == 1)
        #expect(inbox.first?.participants.split(separator: ",").sorted() == ["Ann", "Bo"])

        let everything = try await store.writer.read { db in try MailStore.threads(in: nil, limit: 50, in: db) }
        #expect(everything.map(\.latest.id) == ["3", "2"])
    }

    @Test func screenerGroupsBySender() async throws {
        let store = try MailStore.inMemory()
        try await store.upsert([
            email("1", from: "a@x.com", mailboxes: ["screener"], received: Date(timeIntervalSince1970: 100)),
            email("2", from: "b@x.com", mailboxes: ["screener"], received: Date(timeIntervalSince1970: 200)),
            email("3", from: "a@x.com", mailboxes: ["screener"], received: Date(timeIntervalSince1970: 300)),
        ])
        let entries = try await store.writer.read { db in try MailStore.screenerEntries(screenerId: "screener", in: db) }
        #expect(entries.map(\.email) == ["a@x.com", "b@x.com"])
        #expect(entries.first?.messages.map(\.id) == ["3", "1"])
    }

    @Test func localSearchCombinesTextAndFilters() async throws {
        let store = try MailStore.inMemory()
        try await store.replaceMailboxes([Mailbox(id: "feed", name: "Feed")])
        try await store.upsert([
            email("1", from: "billing@stripe.com", subject: "Your invoice", mailboxes: ["feed"]),
            email("2", from: "billing@stripe.com", subject: "Your receipt"),
            email("3", from: "pal@friends.org", subject: "Invoice joke", keywords: ["$seen"]),
        ])
        #expect(try await store.search(SearchQuery("invo")).map(\.id).sorted() == ["1", "3"])
        #expect(try await store.search(SearchQuery("invoice from:stripe")).map(\.id) == ["1"])
        #expect(try await store.search(SearchQuery("from:stripe -in:feed")).map(\.id) == ["2"])
        #expect(try await store.search(SearchQuery("invoice is:unread")).map(\.id) == ["1"])
        #expect(try await store.search(SearchQuery("receipt OR joke")).map(\.id).sorted() == ["2", "3"])
    }

    @Test func bodiesAreIndexedForSearch() async throws {
        let store = try MailStore.inMemory()
        try await store.upsert([email("1", from: "a@x.com")])
        try await store.save(BodyRecord(messageId: "1", html: "<p>The <b>zeppelin</b> landed</p>", text: nil,
                                        attachments: [], inlineParts: [:], fetchedAt: .now))
        #expect(try await store.search(SearchQuery("zeppelin")).map(\.id) == ["1"])
        #expect(try await store.search(SearchQuery("body:landed")).map(\.id) == ["1"])
    }

    @Test func deletingRemovesFromIndex() async throws {
        let store = try MailStore.inMemory()
        try await store.upsert([email("1", from: "a@x.com", subject: "unique-word")])
        try await store.delete(messageIds: ["1"])
        #expect(try await store.search(SearchQuery("unique")).isEmpty)
    }

    @Test func badgeCountsOnlyBadgedSendersOutsideQuarantine() async throws {
        let store = try MailStore.inMemory()
        try await store.save(SenderRecord(email: "vip@x.com", status: .screenedIn, badge: true))
        try await store.upsert([
            email("1", from: "vip@x.com"),
            email("2", from: "vip@x.com", keywords: ["$seen"]),
            email("3", from: "vip@x.com", mailboxes: ["trash"]),
            email("4", from: "other@x.com"),
        ])
        let count = try await store.writer.read { db in try MailStore.badgeCount(excludingMailboxIds: boxes.quarantined, in: db) }
        #expect(count == 1)
    }
}

// MARK: - Misc

@Suite struct MiscTests {
    @Test func parsesJMAPDates() {
        #expect(JMAPCoding.parseDate("2026-10-16T12:00:00Z") == Date(timeIntervalSince1970: 1_792_152_000))
        #expect(JMAPCoding.parseDate("2026-10-16T14:00:00+02:00") == Date(timeIntervalSince1970: 1_792_152_000))
        #expect(JMAPCoding.parseDate("2026-10-16T12:00:00.250Z") != nil)
    }

    @Test func deterministicUids() {
        let uid = ContactsRuleStore.uid(for: "sender:a@x.com")
        #expect(uid == ContactsRuleStore.uid(for: "sender:a@x.com"))
        #expect(uid != ContactsRuleStore.uid(for: "sender:b@x.com"))
        #expect(uid.hasPrefix("urn:uuid:"))
        #expect(UUID(uuidString: String(uid.dropFirst(9))) != nil)
    }

    @Test func assemblesHTMLWithInlineImages() {
        var message = email("1", from: "a@x.com")
        message.htmlBody = [EmailBodyPart(partId: "1", blobId: nil, size: 10, name: nil, type: "text/html", charset: nil, disposition: nil, cid: nil)]
        message.attachments = [
            EmailBodyPart(partId: "2", blobId: "Gabc", size: 10, name: "logo.png", type: "image/png", charset: nil, disposition: "inline", cid: "<logo@x>"),
            EmailBodyPart(partId: "3", blobId: "Gdef", size: 10, name: "report.pdf", type: "application/pdf", charset: nil, disposition: "attachment", cid: nil),
        ]
        message.bodyValues = ["1": EmailBodyValue(value: #"<img src="cid:logo@x"> Hi"#)]
        let body = BodyAssembler.assemble(message)
        #expect(body.html == #"<img src="sift-blob://blob/Gabc?type=image/png&name=logo.png"> Hi"#)
        #expect(body.attachments.map(\.name) == ["report.pdf"])
        #expect(body.text == "Hi")
    }

    @Test func reportsMissingScopes() throws {
        func session(_ capabilities: [String], readOnly: Bool = false) throws -> JMAPSession {
            let caps = capabilities.map { "\"\($0)\": {}" }.joined(separator: ",")
            let primary = capabilities.map { "\"\($0)\": \"A1\"" }.joined(separator: ",")
            let json = """
                {"apiUrl": "https://x/api", "downloadUrl": "d", "uploadUrl": "u", "eventSourceUrl": "e",
                 "username": "me", "state": "1", "capabilities": {\(caps)}, "primaryAccounts": {\(primary)},
                 "accounts": {"A1": {"name": "me", "isReadOnly": \(readOnly), "accountCapabilities": {\(caps)}}}}
                """
            return try JMAPCoding.decoder.decode(JMAPSession.self, from: Data(json.utf8))
        }
        let all = [JMAPCapability.core, JMAPCapability.mail, JMAPCapability.submission, JMAPCapability.contacts]
        #expect(try session(all).missingScopes.isEmpty)
        #expect(try session([JMAPCapability.core, JMAPCapability.mail]).missingScopes == ["Email submission", "Contacts"])
        #expect(try session(all, readOnly: true).missingScopes.first?.hasPrefix("Email write access") == true)
    }

    @Test func surfacesFastmailErrorDetail() {
        #expect(JMAPError.serverDetail(from: Data(#"{"type":"about:blank","title":"Unauthorized","detail":"Token expired"}"#.utf8)) == "Token expired")
        #expect(JMAPError.serverDetail(from: Data("Authorization header not a valid format".utf8)) == "Authorization header not a valid format")
        #expect(JMAPError.serverDetail(from: Data("<html>nope</html>".utf8)) == nil)
    }

    @Test func plainTextFromHTML() {
        #expect(HTMLText.plainText(from: "<style>p{}</style><p>One &amp; two</p><p>Three&nbsp;&#8212;</p>") == "One & two\nThree —")
    }
}

// MARK: - End to end against the demo server

@Suite struct SyncEngineTests {
    func makeEngine(_ server: DemoServer) throws -> SyncEngine {
        let client = JMAPClient(token: "demo", sessionURL: DemoServer.sessionURL, urlSession: server.urlSession())
        return SyncEngine(client: client, store: try MailStore.inMemory())
    }

    @Test func screensNewSendersAndKeepsContactsInInbox() async throws {
        let server = DemoServer()
        let engine = try makeEngine(server)
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))

        let screener = try #require(server.mailboxId(named: SyncEngine.screenerName))
        #expect(server.mailboxId(named: SyncEngine.screenedOutName) != nil)

        let entries = try await engine.store.writer.read { db in try MailStore.screenerEntries(screenerId: screener, in: db) }
        #expect(Set(entries.map(\.email)) == [
            "hello@paperline.example", "kai@lumenlabs.example", "bookings@fjordair.example",
            "reminders@coastaldental.example", "orders@northwind.example",
        ])
        // Contacts were auto-approved and stayed put.
        let inbox = try await engine.store.messages(in: "inbox")
        #expect(Set(inbox.map(\.fromEmail)) == ["alex@rivera.example", "mom@family.example"])
        let activation = Date.now.addingTimeInterval(-DemoSeed.activationAge)
        #expect(inbox.filter { $0.receivedAt > activation }.allSatisfy { server.emailKeywords($0.id).contains(Keyword.routed) })
        // Grandfathered history was not touched.
        #expect(try await engine.store.messages(in: "receipts").count == 2)
    }

    @Test func screeningInFilesMailAndLaterArrivals() async throws {
        let server = DemoServer()
        let engine = try makeEngine(server)
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))

        try await engine.screenIn("bookings@fjordair.example", name: "Fjord Air", labels: ["travel"])
        let booking = try #require(try await engine.store.messages(from: "bookings@fjordair.example").first)
        #expect(server.emailMailboxes(booking.id) == ["travel"])

        // The rule lives in Fastmail Contacts as group membership, with no card per sender.
        let groups = server.siftGroups()
        let memberOf = groups.filter { ($0["members"] as? [String: Bool])?["mailto:bookings@fjordair.example"] == true }
            .compactMap { ($0["name"] as? [String: Any])?["full"] as? String }
        #expect(Set(memberOf) == ["Sift: Screened In", "Sift label: Travel"])
        #expect(groups.allSatisfy { ($0["addressBookIds"] as? [String: Bool])?["personal"] == true })
        #expect(server.individualCardCount == 2)  // just the user's own two contacts

        // A new message from the same sender is filed automatically.
        let next = server.deliver(from: ("Fjord Air", "bookings@fjordair.example"), subject: "Check in now", text: "Open")
        try await engine.refresh()
        #expect(server.emailMailboxes(next) == ["travel"])

        // A fresh device reads the same rules back.
        let other = try makeEngine(server)
        try await other.start()
        let rule = try #require(try await other.store.sender("bookings@fjordair.example"))
        #expect(rule.status == .screenedIn)
        #expect(rule.labelIds == ["travel"])
    }

    @Test func rescuesScreenedInMailFromSpam() async throws {
        let server = DemoServer()
        let engine = try makeEngine(server)
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))
        try await engine.screenIn("bookings@fjordair.example", name: "Fjord Air", labels: ["travel"])

        // Fastmail's filter puts their next email in Spam; Sift takes it back out.
        let caught = server.deliver(from: ("Fjord Air", "bookings@fjordair.example"), subject: "Gate change", text: "Gate 4",
                                    mailbox: "junk", keywords: ["$junk"])
        // One that only claims to be from them stays.
        let forged = server.deliver(from: ("Fjord Air", "bookings@fjordair.example"), subject: "Verify your card", text: "Click",
                                    mailbox: "junk", authenticationResults: ["mx1.messagingengine.com; dmarc=fail header.from=fjordair.example"])
        let stranger = server.deliver(from: ("Prize Desk", "win@prize.example"), subject: "You won", text: "!", mailbox: "junk")
        try await engine.refresh()

        #expect(server.emailMailboxes(caught) == ["travel"])
        #expect(server.emailKeywords(caught).isSuperset(of: [Keyword.notJunk, Keyword.routed]))
        #expect(!server.emailKeywords(caught).contains(Keyword.junk))
        #expect(server.emailMailboxes(forged) == ["junk"])
        #expect(server.emailMailboxes(stranger) == ["junk"])

        // Moving it back to Spam yourself sticks.
        try await engine.moveToJunk([caught])
        try await engine.refresh()
        #expect(server.emailMailboxes(caught) == ["junk"])
        #expect(server.emailKeywords(caught).contains(Keyword.junk))
    }

    @Test func screeningInReleasesTheirSpam() async throws {
        let server = DemoServer()
        let engine = try makeEngine(server)
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))
        let caught = server.deliver(from: ("Riddle", "hello@riddle.example"), subject: "Episode 398", text: "New", mailbox: "junk")
        try await engine.refresh()
        #expect(server.emailMailboxes(caught) == ["junk"])

        try await engine.screenIn("hello@riddle.example", name: "Riddle", labels: [])
        #expect(server.emailMailboxes(caught) == ["inbox"])
        #expect(server.emailKeywords(caught).contains(Keyword.notJunk))

        // Changing their folders in sender settings refiles from Spam too.
        let again = server.deliver(from: ("Riddle", "hello@riddle.example"), subject: "Episode 399", text: "New", mailbox: "junk")
        try await engine.refresh()
        #expect(server.emailMailboxes(again) == ["inbox"])
        try await engine.moveToJunk([again])
        try await engine.updateRule(SenderRecord(email: "hello@riddle.example", status: .screenedIn, labelIds: ["newsletters"]), refile: true)
        #expect(server.emailMailboxes(again) == ["newsletters"])
        #expect(server.emailMailboxes(caught) == ["newsletters"])
    }

    @Test func honoursContactsAddedToGroupsInFastmail() async throws {
        let server = DemoServer()
        let engine = try makeEngine(server)
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))
        // Screening in Alex created "Sift: Screened In"; now the user drags a contact into "Sift: Notify"...
        try await engine.updateRule(SenderRecord(email: "alex@rivera.example", status: .screenedIn, notify: true), refile: false)
        let pat = server.addContact(name: "Pat Lee", email: "pat@lee.example")
        server.addMember(pat, toGroupNamed: "Sift: Notify")
        try await engine.syncRules()
        let rule = try #require(try await engine.store.sender("pat@lee.example"))
        #expect(rule.notify)
        #expect(rule.name == "Pat Lee")

        // ...and turning notify off in Sift removes that contact from the group.
        var off = rule
        off.notify = false
        try await engine.updateRule(off, refile: false)
        let notify = try #require(server.siftGroups().first { (($0["name"] as? [String: Any])?["full"] as? String) == "Sift: Notify" })
        #expect((notify["members"] as? [String: Bool])?[pat] == nil)
    }

    @Test func refusedGroupMembersLeaveMailAndRulesUntouched() async throws {
        let server = DemoServer()
        let engine = try makeEngine(server)
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))
        server.rejectsAddressMembers = true
        await #expect(throws: ContactsRuleStoreError.self) {
            try await engine.screenIn("bookings@fjordair.example", name: "Fjord Air", labels: ["travel"])
        }
        let booking = try #require(try await engine.store.messages(from: "bookings@fjordair.example").first)
        #expect(server.emailMailboxes(booking.id) == [try #require(server.mailboxId(named: SyncEngine.screenerName))])
        #expect(try await engine.store.sender("bookings@fjordair.example") == nil)
    }

    @Test func screeningOutHidesAndMarksRead() async throws {
        let server = DemoServer()
        let engine = try makeEngine(server)
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))
        try await engine.screenOut("kai@lumenlabs.example", name: "Kai")
        let screenedOut = try #require(server.mailboxId(named: SyncEngine.screenedOutName))
        let pitch = try #require(try await engine.store.messages(from: "kai@lumenlabs.example").first)
        #expect(server.emailMailboxes(pitch.id) == [screenedOut])
        #expect(server.emailKeywords(pitch.id).contains(Keyword.seen))

        let again = server.deliver(from: ("Kai", "kai@lumenlabs.example"), subject: "Following up", text: "Bump")
        try await engine.refresh()
        #expect(server.emailMailboxes(again) == [screenedOut])
    }

    @Test func notifiesAboutNewMailAndSends() async throws {
        let server = DemoServer()
        let engine = try makeEngine(server)
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))

        let received = Received()
        await engine.onNewMail { messages in await received.add(messages.map(\.subject)) }
        server.deliver(from: ("Alex Rivera", "alex@rivera.example"), subject: "Dinner?", text: "Tacos at 7")
        try await engine.refresh()
        #expect(await received.subjects == ["Dinner?"])

        let identity = try #require(await engine.identities.first)
        try await engine.send(.init(identityId: identity.id, to: [EmailAddress(email: "new@person.example")],
                                    subject: "Hello", body: "Hi!"))
        let sent = try await engine.store.messages(in: "sent")
        #expect(sent.contains { $0.subject == "Hello" })
        #expect(try await engine.store.hasWrittenTo("new@person.example"))

        let results = try await engine.search(SearchQuery("bergen"))
        #expect(results.messages.map(\.fromEmail) == ["bookings@fjordair.example"])
    }

    @Test func fetchesAndSanitizesBodies() async throws {
        let server = DemoServer()
        let engine = try makeEngine(server)
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))
        let newsletter = try #require(try await engine.store.messages(from: "hello@paperline.example").first)
        let body = try await engine.body(for: newsletter.id)
        let sanitized = TrackerDetector.sanitize(try #require(body.html))
        #expect(sanitized.trackerSummary == "Mailchimp")
    }
}

actor Received {
    var subjects: [String] = []
    func add(_ new: [String]) { subjects += new }
}
