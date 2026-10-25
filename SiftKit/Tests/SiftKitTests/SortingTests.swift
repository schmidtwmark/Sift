import Foundation
import Testing
@testable import SiftKit

@Suite struct SortingInferenceTests {
    let inputs = SortingInference.Inputs(
        mailboxes: boxes, userLabels: ["feed", "paper", "lts"], ignored: ["import"], ownAddresses: ["me@fastmail.com"]
    )

    @Test func suggestsTheFolderMostOfASendersMailIsIn() {
        let messages = [
            email("1", from: "news@a.com", mailboxes: ["feed"]),
            email("2", from: "news@a.com", mailboxes: ["feed"]),
            email("3", from: "news@a.com", mailboxes: ["archive"]),
            email("4", from: "bills@b.com", mailboxes: ["paper"]),
            email("5", from: "pal@c.com", mailboxes: ["inbox"]),
            email("6", from: "pal@c.com", mailboxes: ["archive"]),
            email("7", from: "spam@d.com", mailboxes: ["junk"]),
            email("8", from: "spam@d.com", mailboxes: ["junk"]),
            email("9", from: "mixed@e.com", mailboxes: ["feed"]),
            email("10", from: "mixed@e.com", mailboxes: ["paper"]),
            email("11", from: "mixed@e.com", mailboxes: ["trash"]),
        ].map(MessageRecord.init)
        let suggestions = Dictionary(uniqueKeysWithValues: SortingInference.suggestions(from: messages, inputs: inputs).map { ($0.email, $0) })
        #expect(suggestions["news@a.com"]?.labelIds == ["feed"])
        #expect(suggestions["news@a.com"]?.evidence == 3)
        #expect(suggestions["bills@b.com"]?.labelIds == ["paper"])
        #expect(suggestions["pal@c.com"]?.status == .screenedIn)
        #expect(suggestions["pal@c.com"]?.labelIds == [])
        #expect(suggestions["spam@d.com"]?.status == .screenedOut)
        // Split 50/50 between two folders counts for both (trash is ignored).
        #expect(suggestions["mixed@e.com"]?.labelIds == ["feed", "paper"])
    }

    @Test func ignoresImportsOwnMailAndExistingRules() {
        let messages = [
            email("1", from: "a@x.com", mailboxes: ["import"]),
            email("2", from: "me@fastmail.com", mailboxes: ["feed"]),
            email("3", from: "ruled@x.com", mailboxes: ["feed"]),
        ].map(MessageRecord.init)
        let existing = ["ruled@x.com": SenderRecord(email: "ruled@x.com", status: .screenedIn)]
        #expect(SortingInference.suggestions(from: messages, inputs: inputs, existing: existing).isEmpty)
    }

    @Test func screenedInWithoutAFolderOrNothingToGoOnMeansInbox() {
        let inboxRule = SenderRecord(email: "a@x.com", status: .screenedIn, labelIds: [])
        #expect(SortingInference.destination(for: "a@x.com", rule: inboxRule, suggestion: nil, isOwn: false,
                                             mailboxes: boxes, fallback: ["inbox"]) == ["inbox"])
        let unknown = SortingInference.decide(for: "new@x.com", rule: nil, suggestion: nil, isOwn: false,
                                              mailboxes: boxes, fallback: ["inbox"])
        #expect(unknown.destination == ["inbox"])
        #expect(unknown.reason == .noHistory)
        let both = SenderRecord(email: "a@x.com", status: .screenedIn, labelIds: ["inbox", "feed"])
        #expect(SortingInference.destination(for: "a@x.com", rule: both, suggestion: nil, isOwn: false,
                                             mailboxes: boxes, fallback: ["archive"]) == ["feed"])
        #expect(SortingInference.destination(for: "me@hey.com", rule: nil, suggestion: nil, isOwn: true,
                                             mailboxes: boxes, fallback: ["archive"]) == ["sent"])
        let out = RuleSuggestion(email: "s@x.com", status: .screenedOut, labelIds: [], evidence: 3)
        #expect(SortingInference.destination(for: "s@x.com", rule: nil, suggestion: out, isOwn: false,
                                             mailboxes: boxes, fallback: ["archive"]) == ["out"])
    }

    @Test func findsTheOldAddressInAnImport() {
        var emails = (0..<4).map { email("\($0)", from: "x\($0)@y.com") }
        for index in emails.indices { emails[index].to = [EmailAddress(email: "Me@Hey.com")] }
        emails[0].to = [EmailAddress(email: "other@z.com")]
        #expect(SortingInference.dominantRecipient(of: emails) == "me@hey.com")
        #expect(SortingInference.dominantRecipient(of: []) == nil)
    }
}

@Suite struct FolderSortTests {
    @Test func sortsAnImportAndDeletesTheEmptyFolder() async throws {
        let server = DemoServer()
        server.addMailbox(id: "heyimport", name: "Old Import")
        let old = Date.now.addingTimeInterval(-400 * 86_400)
        // Known filing: the newsletter lives in Newsletters, the bank in Receipts.
        let fromHey: [(name: String, email: String, subject: String)] = [
            ("Field Notes Digest", "digest@fieldnotes.example", "Issue 12"),
            ("Brightside Bank", "alerts@brightside.example", "Old statement"),
            ("Someone New", "stranger@unknown.example", "Hello from the past"),
            ("You", "you@hey.example", "Re: plans"),
        ]
        var ids: [String: String] = [:]
        for entry in fromHey {
            ids[entry.email] = server.deliver(from: (entry.name, entry.email), subject: entry.subject, text: "…",
                                              mailbox: "heyimport", receivedAt: old, keywords: ["$seen"],
                                              to: entry.email == "you@hey.example" ? "friend@x.example" : "you@hey.example")
        }
        let client = JMAPClient(token: "demo", sessionURL: DemoServer.sessionURL, urlSession: server.urlSession())
        let engine = SyncEngine(client: client, store: try MailStore.inMemory())
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))

        let plan = try await engine.planFolderSort("heyimport", ignoring: ["hey-import"])
        #expect(plan.total == 4)
        #expect(plan.ownAddresses.contains("you@hey.example"))

        try await engine.execute(plan)
        #expect(server.emailMailboxes(ids["digest@fieldnotes.example"]!) == ["newsletters"])
        #expect(server.emailMailboxes(ids["alerts@brightside.example"]!) == ["receipts"])
        #expect(server.emailMailboxes(ids["stranger@unknown.example"]!) == ["inbox"])
        #expect(server.emailKeywords(ids["stranger@unknown.example"]!).contains(Keyword.routed))
        #expect(server.emailMailboxes(ids["you@hey.example"]!) == ["sent"])

        try await engine.deleteMailbox("heyimport")
        #expect(server.mailboxId(named: "Old Import") == nil)
    }

    @Test func recentMailSortedIntoTheInboxIsNotScreened() async throws {
        let server = DemoServer()
        server.addMailbox(id: "misc", name: "Misc")
        // Arrived after the Screener was switched on, from someone it doesn't know.
        let recent = server.deliver(from: ("Someone New", "stranger@unknown.example"), subject: "Hi", text: "…",
                                    mailbox: "misc", receivedAt: .now.addingTimeInterval(-86_400), keywords: ["$seen"])
        let client = JMAPClient(token: "demo", sessionURL: DemoServer.sessionURL, urlSession: server.urlSession())
        let engine = SyncEngine(client: client, store: try MailStore.inMemory())
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))

        try await engine.execute(try await engine.planFolderSort("misc"))
        try await engine.refresh()
        #expect(server.emailMailboxes(recent) == ["inbox"])
    }

    @Test func reordersFoldersInFastmail() async throws {
        let server = DemoServer()
        let client = JMAPClient(token: "demo", sessionURL: DemoServer.sessionURL, urlSession: server.urlSession())
        let engine = SyncEngine(client: client, store: try MailStore.inMemory())
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))

        let order = ["travel", "receipts", "hey-import", "family", "newsletters"]
        try await engine.reorderMailboxes(order)
        // Locally at once, and in Fastmail, after every system mailbox.
        let local = try await engine.store.mailboxes().filter { order.contains($0.id) }.map(\.id)
        #expect(local == order)
        let saved = order.compactMap(server.mailboxSortOrder)
        #expect(saved == saved.sorted() && Set(saved).count == order.count)
        #expect(saved.first! > server.mailboxSortOrder("trash")!)

        // Another device sees the same order.
        let other = SyncEngine(client: JMAPClient(token: "demo", sessionURL: DemoServer.sessionURL, urlSession: server.urlSession()),
                               store: try MailStore.inMemory())
        try await other.start()
        #expect(try await other.store.mailboxes().filter { order.contains($0.id) }.map(\.id) == order)
    }

    @Test func sortsTheDemoHeyImport() async throws {
        let server = DemoServer()
        let client = JMAPClient(token: "demo", sessionURL: DemoServer.sessionURL, urlSession: server.urlSession())
        let engine = SyncEngine(client: client, store: try MailStore.inMemory())
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))
        let plan = try await engine.planFolderSort("hey-import")
        let counts = Dictionary(uniqueKeysWithValues: plan.buckets.map { ($0.id, $0.messageIds.count) })
        #expect(counts == ["newsletters": 3, "receipts": 2, "sent": 2, "inbox": 3])
        #expect(plan.ownAddresses.contains("you@hey.example"))

        // Every message says why it's going where it is.
        let items = plan.buckets.flatMap(\.items)
        func reasons(_ sender: String) -> Set<SortReason> { Set(items.filter { $0.senderEmail == sender }.map(\.reason)) }
        #expect(reasons("digest@fieldnotes.example") == [.history(.screenedIn, evidence: 1)])
        #expect(reasons("you@hey.example") == [.ownMail("you@hey.example")])
        #expect(reasons("alex@rivera.example") == [.rule(.screenedIn)])  // a contact, so screened in; no folder means Inbox
        #expect(reasons("rentals@oaktree.example") == [.noHistory])
        let lease = try #require(items.first { $0.senderEmail == "rentals@oaktree.example" })
        #expect(lease.subject == "Lease renewal")
        #expect(lease.receivedAt != nil)
        // Newest first within each destination.
        for bucket in plan.buckets {
            let dates = bucket.items.compactMap(\.receivedAt)
            #expect(dates == dates.sorted(by: >))
        }
    }

    @Test func refusesToDeleteAFolderWithMail() async throws {
        let server = DemoServer()
        let client = JMAPClient(token: "demo", sessionURL: DemoServer.sessionURL, urlSession: server.urlSession())
        let engine = SyncEngine(client: client, store: try MailStore.inMemory())
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))
        await #expect(throws: SetError.self) { try await engine.deleteMailbox("receipts") }
    }

    @Test func suggestionsApplyAsRulesInOneRequest() async throws {
        let server = DemoServer()
        let client = JMAPClient(token: "demo", sessionURL: DemoServer.sessionURL, urlSession: server.urlSession())
        let engine = SyncEngine(client: client, store: try MailStore.inMemory())
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))
        let suggestions = try await engine.suggestRules(ignoring: ["hey-import"])
        let digest = try #require(suggestions.first { $0.email == "digest@fieldnotes.example" })
        #expect(digest.labelIds == ["newsletters"])
        try await engine.apply(suggestions)
        let rule = try #require(try await engine.store.sender("digest@fieldnotes.example"))
        #expect(rule.status == .screenedIn)
        #expect(rule.labelIds == ["newsletters"])
        let groupNames = Set(server.siftGroups().compactMap { ($0["name"] as? [String: Any])?["full"] as? String })
        #expect(groupNames.isSuperset(of: ["Sift: Screened In", "Sift label: Newsletters", "Sift label: Receipts"]))
    }

    @Test func undoPutsMessagesBack() async throws {
        let server = DemoServer()
        let client = JMAPClient(token: "demo", sessionURL: DemoServer.sessionURL, urlSession: server.urlSession())
        let engine = SyncEngine(client: client, store: try MailStore.inMemory())
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))
        let receipt = try #require(try await engine.store.messages(in: "receipts").first)
        let placement = try await engine.archive([receipt.id], from: "receipts")
        #expect(server.emailMailboxes(receipt.id) == ["archive"])
        try await engine.restore(placement)
        #expect(server.emailMailboxes(receipt.id) == ["receipts"])
    }
}

@Suite struct OptimisticChangeTests {
    func engine(_ server: DemoServer) async throws -> SyncEngine {
        let client = JMAPClient(token: "demo", sessionURL: DemoServer.sessionURL, urlSession: server.urlSession())
        let engine = SyncEngine(client: client, store: try MailStore.inMemory())
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))
        return engine
    }

    @Test func failedChangesRollBack() async throws {
        let server = DemoServer()
        let engine = try await engine(server)
        let unread = try #require(try await engine.store.messages(in: "inbox").first { $0.isUnread })
        server.failsEmailSet = true
        await #expect(throws: JMAPError.self) {
            try await engine.setKeyword(Keyword.seen, true, for: [unread.id])
        }
        #expect(try await engine.store.message(id: unread.id)?.isUnread == true)
    }

    @Test func syncDuringAChangeDoesNotUndoIt() async throws {
        let server = DemoServer()
        let engine = try await engine(server)
        let unread = try #require(try await engine.store.messages(in: "inbox").first { $0.isUnread })
        server.emailSetDelay = 0.4
        let marking = Task { try await engine.setKeyword(Keyword.seen, true, for: [unread.id]) }
        try await Task.sleep(for: .milliseconds(100))
        // Meanwhile the message changes elsewhere and a push triggers a sync,
        // which fetches Fastmail's copy (still unread: our change is in flight).
        server.setKeyword(Keyword.flagged, on: unread.id)
        try await engine.refresh()
        let duringSync = try #require(try await engine.store.message(id: unread.id))
        #expect(!duringSync.isUnread)
        #expect(duringSync.isFlagged)
        try await marking.value
        try await engine.refresh()
        #expect(try await engine.store.message(id: unread.id)?.isUnread == false)
        #expect(server.emailKeywords(unread.id).contains(Keyword.seen))
    }
}
