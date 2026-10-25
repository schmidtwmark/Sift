import Foundation
import Testing
@testable import SiftKit

@Suite struct BubbleUpTests {
    func makeEngine(_ server: DemoServer) async throws -> SyncEngine {
        let client = JMAPClient(token: "demo", sessionURL: DemoServer.sessionURL, urlSession: server.urlSession())
        let engine = SyncEngine(client: client, store: try MailStore.inMemory())
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))
        return engine
    }

    /// Alex's climbing thread: older than the newest Inbox mail, so it has to float up.
    func original(_ engine: SyncEngine) async throws -> MessageRecord {
        try #require(try await engine.store.read(.thread("T-climb")).last)
    }

    @Test func bubblesUpLikeNewMailWithTheOriginalShowing() async throws {
        let server = DemoServer()
        server.maxDelayedSend = 30 * 86_400
        let engine = try await makeEngine(server)
        let message = try await original(engine)
        try await engine.setKeyword(Keyword.seen, true, for: [message.id])

        let bubble = try await engine.bubbleUp(message, at: .now.addingTimeInterval(3600))
        // Fastmail holds it; no outgoing copy is left in Drafts or Sent.
        #expect(server.submission(bubble.submissionId)?.undoStatus == "pending")
        #expect(!server.emailExists(server.submission(bubble.submissionId)!.emailId))
        try await engine.refresh()
        #expect(try await engine.store.read(.bubbleUps).map(\.threadId) == ["T-climb"])

        // Its time comes: the note lands in the same conversation.
        let note = try #require(server.deliverHeld(bubble.submissionId))
        try await engine.refresh()

        let thread = try await engine.store.read(.thread("T-climb"))
        let arrived = try #require(thread.first { $0.id == note })
        #expect(arrived.isBubble)
        #expect(!arrived.isUnread)
        #expect(try #require(thread.first { $0.id == message.id }).isUnread)

        // Top of the Inbox, showing the original with its own date.
        let inbox = try await engine.store.read(.threads(in: "inbox", limit: 50))
        let top = try #require(inbox.first)
        #expect(top.id == "T-climb")
        #expect(top.latest.id == message.id)
        #expect(top.bubbledAt != nil)
        #expect(top.unreadCount >= 1)
        #expect(top.messageCount == thread.count - 1)  // the note isn't counted
        #expect(try await engine.store.read(.bubbleUps).isEmpty)
    }

    @Test func cancellingStopsIt() async throws {
        let server = DemoServer()
        server.maxDelayedSend = 30 * 86_400
        let engine = try await makeEngine(server)
        let bubble = try await engine.bubbleUp(try await original(engine), at: .now.addingTimeInterval(86_400))
        try await engine.cancel(bubble)
        #expect(server.submission(bubble.submissionId)?.undoStatus == "canceled")
        #expect(server.deliverHeld(bubble.submissionId) == nil)
        try await engine.syncBubbleUps()
        #expect(try await engine.store.read(.bubbleUps).isEmpty)
    }

    @Test func refusesWhatFastmailCantHold() async throws {
        // No delayed sending at all.
        let plain = try await makeEngine(DemoServer())
        let message = try await original(plain)
        await #expect(throws: BubbleUpError.unsupported) { try await plain.bubbleUp(message, at: .now.addingTimeInterval(3600)) }

        // Up to a day (the session is read once, so a new engine sees the new limit).
        let server = DemoServer()
        server.maxDelayedSend = 86_400
        let engine = try await makeEngine(server)
        await #expect(throws: BubbleUpError.tooFar(days: 1)) { try await engine.bubbleUp(message, at: .now.addingTimeInterval(3 * 86_400)) }
        await #expect(throws: BubbleUpError.tooSoon) { try await engine.bubbleUp(message, at: .now.addingTimeInterval(5)) }
    }

    @Test func suggestsSensibleTimes() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // Wednesday 10:00.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10)))
        let options = BubbleUp.suggestions(from: now, calendar: calendar)
        #expect(options.map(\.title) == ["Later Today", "Tomorrow Morning", "This Weekend", "Next Week"])
        #expect(calendar.component(.hour, from: options[0].date) == 13)
        #expect(calendar.component(.weekday, from: options[2].date) == 7)
        #expect(calendar.component(.weekday, from: options[3].date) == 2)
        #expect(options.dropFirst().allSatisfy { calendar.component(.hour, from: $0.date) == 8 })
    }
}
