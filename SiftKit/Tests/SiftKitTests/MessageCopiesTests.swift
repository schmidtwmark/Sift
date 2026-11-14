import Foundation
import Testing
@testable import SiftKit

/// Mail to yourself: one copy in Sent, one delivered to the Inbox.
@Suite struct MessageCopiesTests {
    func copies() -> [Email] {
        var sent = email("s", from: "me@fastmail.com", mailboxes: ["sent"], keywords: ["$seen"],
                         received: Date(timeIntervalSince1970: 300), thread: "T")
        var delivered = email("d", from: "me@fastmail.com", mailboxes: ["inbox"],
                              received: Date(timeIntervalSince1970: 301), thread: "T")
        sent.messageId = ["<note@x>"]
        delivered.messageId = ["<note@x>"]
        return [sent, delivered]
    }

    @Test func aMessageToYourselfShowsOnce() {
        let first = MessageRecord(email("1", from: "a@x.com", received: Date(timeIntervalSince1970: 100), thread: "T"))
        let thread = [first] + copies().map(MessageRecord.init)
        #expect(thread.groupingCopies().map { $0.map(\.id) } == [["1"], ["s", "d"]])

        let shown = thread.collapsingCopies()
        #expect(shown.map(\.id) == ["1", "s"])
        let note = try! #require(shown.last)
        #expect(note.isUnread)  // the delivered copy hasn't been read
        #expect(note.mailboxIds == ["inbox", "sent"])
    }

    @Test func messagesWithoutAMessageIDStayApart() {
        var one = MessageRecord(email("1", from: "a@x.com", thread: "T"))
        var two = MessageRecord(email("2", from: "a@x.com", thread: "T"))
        one.messageIdHeader = nil
        two.messageIdHeader = nil
        #expect([one, two].collapsingCopies().map(\.id) == ["1", "2"])
    }

    @Test func theListCountsEachMessageOnce() async throws {
        let store = try MailStore.inMemory()
        try await store.upsert([
            email("1", from: "a@x.com", keywords: ["$seen"], received: Date(timeIntervalSince1970: 100), thread: "T"),
        ] + copies())
        let inbox = try await store.writer.read { db in try MailStore.threads(in: "inbox", limit: 50, in: db) }
        #expect(inbox.first?.messageCount == 2)
        #expect(inbox.first?.unreadCount == 1)
    }
}

@Suite struct ReplyRecipientsTests {
    let own: Set<String> = ["me@fastmail.com"]

    func message(from: String, to: [String], cc: [String] = [], replyTo: [String] = []) -> MessageRecord {
        var email = email("m", from: from)
        email.to = to.map { EmailAddress(email: $0) }
        email.cc = cc.map { EmailAddress(email: $0) }
        email.replyTo = replyTo.isEmpty ? nil : replyTo.map { EmailAddress(email: $0) }
        return MessageRecord(email)
    }

    @Test func aReplyGoesToTheSender() {
        let original = message(from: "support@seatgeek.com", to: ["me@fastmail.com", "jamie@x.com"],
                               replyTo: ["help@seatgeek.com"])
        let reply = ReplyRecipients.of(original, all: false, own: own)
        #expect(reply.to.map(\.normalized) == ["help@seatgeek.com"])
        #expect(reply.cc.isEmpty)
        let all = ReplyRecipients.of(original, all: true, own: own)
        #expect(all.cc.map(\.normalized) == ["jamie@x.com"])
        #expect(ReplyRecipients.identityEmail(for: original, own: own) == "me@fastmail.com")
    }

    @Test func replyingToYourOwnMessageGoesToWhoYouSentItTo() {
        let original = message(from: "Me@Fastmail.com", to: ["support@seatgeek.com", "me@fastmail.com"],
                               cc: ["jamie@x.com", "me@fastmail.com"])
        let reply = ReplyRecipients.of(original, all: false, own: own)
        #expect(reply.to.map(\.normalized) == ["support@seatgeek.com"])
        #expect(reply.cc.isEmpty)
        let all = ReplyRecipients.of(original, all: true, own: own)
        #expect(all.cc.map(\.normalized) == ["jamie@x.com"])
        #expect(ReplyRecipients.identityEmail(for: original, own: own) == "me@fastmail.com")
    }

    @Test func aNoteToYourselfStillComesBackToYou() {
        let original = message(from: "me@fastmail.com", to: ["me@fastmail.com"])
        #expect(ReplyRecipients.of(original, all: false, own: own).to.map(\.normalized) == ["me@fastmail.com"])
    }
}
