import Foundation
import Testing
@testable import SiftKit

@Suite struct MailtoLinkTests {
    @Test func parsesRecipientsAndFields() throws {
        let link = try #require(MailtoLink(string: "mailto:alex@example.com,sam@example.com?cc=pat@example.com&BCC=me@example.com&subject=Hi%20there&body=Line%20one%0D%0ALine%20two"))
        #expect(link.to == ["alex@example.com", "sam@example.com"])
        #expect(link.cc == ["pat@example.com"])
        #expect(link.bcc == ["me@example.com"])
        #expect(link.subject == "Hi there")
        #expect(link.body == "Line one\nLine two")
    }

    @Test func toInTheQueryAddsRecipients() throws {
        let link = try #require(MailtoLink(string: "mailto:?to=a@example.com&to=b%40example.com"))
        #expect(link.to == ["a@example.com", "b@example.com"])
    }

    @Test func keepsPlusSignsAndDecodesEncodedOnes() throws {
        let link = try #require(MailtoLink(string: "mailto:me+news@example.com?subject=1+1%20%3D%202%26more"))
        #expect(link.to == ["me+news@example.com"])
        #expect(link.subject == "1+1 = 2&more")
    }

    @Test func toleratesSloppyLinks() throws {
        let raw = try #require(MailtoLink(string: "MAILTO:support@example.com?subject=Help me please"))
        #expect(raw.to == ["support@example.com"])
        #expect(raw.subject == "Help me please")
        #expect(MailtoLink(string: "mailto://hi@example.com")?.to == ["hi@example.com"])
        #expect(MailtoLink(string: "mailto:")?.isEmpty == true)
        #expect(MailtoLink(string: "https://example.com") == nil)
    }

    @Test func readsFoundationURLs() throws {
        let url = try #require(URL(string: "mailto:alex@example.com?subject=Caf%C3%A9"))
        #expect(MailtoLink(url)?.subject == "Café")
    }
}

@Suite struct NetworkFailureTests {
    @Test func timeoutsAndDroppedConnectionsAreTransient() {
        #expect(URLError(.timedOut).isTransientNetworkFailure)
        #expect(URLError(.networkConnectionLost).isTransientNetworkFailure)
        #expect(URLError(.notConnectedToInternet).isTransientNetworkFailure)
        #expect(JMAPError.http(status: 503, body: "").isTransientNetworkFailure)
    }

    @Test func realProblemsAreNot() {
        #expect(!JMAPError.unauthorized(detail: nil).isTransientNetworkFailure)
        #expect(!JMAPError.http(status: 400, body: "").isTransientNetworkFailure)
        #expect(!URLError(.badURL).isTransientNetworkFailure)
        #expect(!CancellationError().isTransientNetworkFailure)
    }
}
