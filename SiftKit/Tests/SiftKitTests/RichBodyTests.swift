import Foundation
import Testing
@testable import SiftKit

struct RichBodyTests {
    func body(_ parts: (String, String?)...) -> AttributedString {
        parts.reduce(into: AttributedString()) { result, part in
            var words = AttributedString(part.0)
            words.link = part.1.flatMap(URL.init(string:))
            result += words
        }
    }

    @Test func plainTextPutsAddressesAfterTheirWords() {
        let text = body(("Tickets are ", nil), ("here", "https://example.com/t"), (". Or see ", nil),
                        ("example.com", "https://example.com"), (".", nil))
        #expect(RichBody.plainText(text) == "Tickets are here <https://example.com/t>. Or see example.com.")
    }

    @Test func htmlOnlyWhenThereAreLinks() throws {
        #expect(RichBody.html(AttributedString("Just <text>\nand more")) == nil)
        let html = try #require(RichBody.html(body(("A & B\nsee ", nil), ("this", "https://example.com/?a=1&b=2"))))
        #expect(html == "<div dir=\"auto\">A &amp; B<br>see <a href=\"https://example.com/?a=1&amp;b=2\">this</a></div>")
    }

    @Test func draftsComeBackWithTheirLinks() throws {
        let original = body(("Hi,\n\nsee ", nil), ("the plan", "https://example.com/plan"), (" & reply.", nil))
        let html = try #require(RichBody.html(original))
        let restored = RichBody.attributedString(html: html)
        #expect(String(restored.characters) == String(original.characters))
        #expect(restored.runs.compactMap(\.link) == [URL(string: "https://example.com/plan")!])
        // Fastmail's own editor writes blocks, not breaks.
        let web = RichBody.attributedString(html: "<div>Hello</div><div><a href='https://x.example'>x</a> there</div>")
        #expect(String(web.characters) == "Hello\nx there")
    }

    @Test func typedAddressesBecomeLinks() {
        #expect(RichBody.url(from: "example.com/a") == URL(string: "https://example.com/a"))
        #expect(RichBody.url(from: " http://x.example ") == URL(string: "http://x.example"))
        #expect(RichBody.url(from: "pat@example.com") == URL(string: "mailto:pat@example.com"))
        #expect(RichBody.url(from: "not a link") == nil)
    }
}
