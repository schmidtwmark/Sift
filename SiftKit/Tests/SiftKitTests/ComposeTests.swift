import Foundation
import Testing
@testable import SiftKit

@Suite struct ComposeTests {
    func makeEngine(_ server: DemoServer) async throws -> SyncEngine {
        let client = JMAPClient(token: "demo", sessionURL: DemoServer.sessionURL, urlSession: server.urlSession())
        let engine = SyncEngine(client: client, store: try MailStore.inMemory())
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))
        return engine
    }

    func message(_ engine: SyncEngine, subject: String = "Plans") async throws -> OutgoingMessage {
        let identity = try #require(await engine.identities.first)
        return OutgoingMessage(identityId: identity.id, to: [EmailAddress(name: "Alex", email: "alex@rivera.example")],
                               subject: subject, body: "See you at 7.")
    }

    @Test func draftsSaveReplaceAndReopen() async throws {
        let server = DemoServer()
        let engine = try await makeEngine(server)
        var draft = try await message(engine)
        let file = try await engine.upload(Data("hello".utf8), name: "notes.txt", type: "text/plain")
        draft.attachments = [file]

        let first = try await engine.saveDraft(draft)
        #expect(server.emailMailboxes(first) == ["drafts"])
        #expect(server.emailKeywords(first).contains(Keyword.draft))

        // Editing saves a new version and removes the old one.
        draft.draftId = first
        draft.body = "See you at 8."
        let second = try await engine.saveDraft(draft)
        #expect(!server.emailExists(first))

        let reopened = try await engine.outgoingMessage(fromDraft: second)
        #expect(reopened.draftId == second)
        #expect(reopened.subject == "Plans")
        #expect(reopened.body == "See you at 8.")
        #expect(reopened.to.map(\.email) == ["alex@rivera.example"])
        #expect(reopened.attachments.map(\.name) == ["notes.txt"])

        try await engine.discardDraft(second)
        #expect(!server.emailExists(second))
    }

    @Test func sendingADraftFilesItInSent() async throws {
        let server = DemoServer()
        let engine = try await makeEngine(server)
        var draft = try await message(engine)
        draft.draftId = try await engine.saveDraft(draft)
        let file = try await engine.upload(Data([0xFF, 0xD8]), name: "photo.jpg", type: "image/jpeg")
        draft.attachments = [file]

        let sending = try await engine.send(draft)
        #expect(sending.heldFor == 0)
        #expect(server.emailMailboxes(sending.emailId) == ["sent"])
        #expect(!server.emailKeywords(sending.emailId).contains(Keyword.draft))
        #expect(!server.emailExists(draft.draftId!))  // the draft is replaced, not left behind
        #expect(server.emailAttachments(sending.emailId).compactMap { $0["name"] as? String } == ["photo.jpg"])
        await #expect(throws: SendError.tooLateToUndo) { try await engine.cancel(sending) }
    }

    @Test func undoSendPutsAHeldMessageBackInDrafts() async throws {
        let server = DemoServer()
        server.maxDelayedSend = 60
        let engine = try await makeEngine(server)
        #expect(await engine.maxDelayedSend() == 60)

        let sending = try await engine.send(try await message(engine), holdFor: 10)
        #expect(sending.heldFor == 10)
        #expect(server.submission(sending.submissionId)?.undoStatus == "pending")
        #expect(server.submission(sending.submissionId)?.holdFor == 10)

        try await engine.cancel(sending)
        #expect(server.submission(sending.submissionId)?.undoStatus == "canceled")
        #expect(server.emailMailboxes(sending.emailId) == ["drafts"])
        #expect(server.emailKeywords(sending.emailId).contains(Keyword.draft))
        let restored = try await engine.outgoingMessage(fromDraft: sending.emailId)
        #expect(restored.subject == "Plans")
    }

    @Test func undoAfterTheHoldEndsIsTooLate() async throws {
        let server = DemoServer()
        server.maxDelayedSend = 60
        let engine = try await makeEngine(server)
        let sending = try await engine.send(try await message(engine), holdFor: 10)
        server.release(sending.submissionId)
        await #expect(throws: SendError.tooLateToUndo) { try await engine.cancel(sending) }
        #expect(server.emailMailboxes(sending.emailId) == ["sent"])
    }

    @Test func noRecipientsIsRefused() async throws {
        let engine = try await makeEngine(DemoServer())
        var draft = try await message(engine)
        draft.to = []
        await #expect(throws: SendError.noRecipients) { try await engine.send(draft) }
    }
}
