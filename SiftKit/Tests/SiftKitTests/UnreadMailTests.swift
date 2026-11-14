import Foundation
import Testing
@testable import SiftKit

@Suite struct UnreadMailTests {
    let quarantined = ["screener", "screenedOut", "trash", "junk"]

    func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    @Test func showsUnreadMailYouWouldReadNewestFirst() async throws {
        let store = try MailStore.inMemory()
        try await store.upsert([
            email("inbox", from: "a@x.com", received: at(100)),
            email("label", from: "b@x.com", mailboxes: ["receipts"], received: at(300)),
            email("archived", from: "c@x.com", mailboxes: ["archive"], received: at(200)),
            email("read", from: "d@x.com", keywords: ["$seen"], received: at(400)),
            email("waiting", from: "e@x.com", mailboxes: ["screener"], received: at(500)),
            email("out", from: "f@x.com", mailboxes: ["screenedOut"], received: at(600)),
            email("spam", from: "g@x.com", mailboxes: ["junk"], received: at(700)),
            email("trashed", from: "h@x.com", mailboxes: ["inbox", "trash"], received: at(800)),
            email("draft", from: "me@fastmail.com", mailboxes: ["drafts"], keywords: ["$draft"], received: at(900)),
            email("note", from: "me@fastmail.com", keywords: [Keyword.bubble], received: at(1000)),
        ])
        let unread = try await store.read(.unread(excluding: quarantined, limit: 50))
        #expect(unread.messages.map { $0.map(\.id) } == [["label"], ["archived"], ["inbox"]])
        #expect(unread.total == 3)
    }

    @Test func theLimitCountsEachMessageOnce() async throws {
        let store = try MailStore.inMemory()
        var sent = email("s", from: "me@fastmail.com", mailboxes: ["sent"], received: at(300), thread: "T")
        var delivered = email("d", from: "me@fastmail.com", received: at(301), thread: "T")
        sent.messageId = ["<note@x>"]
        delivered.messageId = ["<note@x>"]
        try await store.upsert([sent, delivered, email("older", from: "a@x.com", received: at(100))])

        let first = try await store.read(.unread(excluding: quarantined, limit: 1))
        #expect(first.messages.map { $0.map(\.id) } == [["d", "s"]])
        #expect(first.total == 2)
    }

    @Test func readingKeepsTheOrderAndSizesConversations() async throws {
        let store = try MailStore.inMemory()
        try await store.upsert([
            email("1", from: "a@x.com", keywords: ["$seen"], received: at(100), thread: "T"),
            email("2", from: "b@x.com", received: at(200), thread: "T"),
            email("3", from: "c@x.com", received: at(300)),
        ])
        let page = try await store.read(.reading(["3", "gone", "2"]))
        #expect(page.messages.map(\.id) == ["3", "2"])
        #expect(page.conversationSizes == ["T": 2, "t-3": 1])
    }
}
