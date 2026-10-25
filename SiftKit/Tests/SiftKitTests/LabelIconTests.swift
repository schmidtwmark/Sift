import Foundation
import Testing
@testable import SiftKit
#if canImport(AppKit)
import AppKit
#endif

@Suite struct LabelIconTests {
    func makeEngine(_ server: DemoServer) throws -> SyncEngine {
        let client = JMAPClient(token: "demo", sessionURL: DemoServer.sessionURL, urlSession: server.urlSession())
        return SyncEngine(client: client, store: try MailStore.inMemory())
    }

    @Test func guessesFromTheLabelName() {
        #expect(LabelIcon.suggested(for: "Receipts") == "receipt")
        #expect(LabelIcon.suggested(for: "Travel") == "airplane")
        #expect(LabelIcon.suggested(for: "Family") == "figure.2.and.child.holdinghands")
        #expect(LabelIcon.suggested(for: "Newsletters") == "newspaper")
        #expect(LabelIcon.suggested(for: "Hey Import") == "archivebox")
        // Word starts only: "Education" isn't about cats, "Scary" isn't a car.
        #expect(LabelIcon.suggested(for: "Education") == "graduationcap")
        #expect(LabelIcon.suggested(for: "Scary Stories") == LabelIcon.fallback)
        #expect(LabelIcon.suggested(for: "Zzz") == LabelIcon.fallback)
        // Labels from a real account.
        #expect(LabelIcon.suggested(for: "Paper Trail") == "receipt")
        #expect(LabelIcon.suggested(for: "Promotions") == "megaphone")
        #expect(LabelIcon.suggested(for: "The Feed") == "newspaper")
        #expect(LabelIcon.suggested(for: "GitHub") == "chevron.left.forwardslash.chevron.right")
        #expect(LabelIcon.suggested(for: "Long Term Storage") == "archivebox")
    }

    @Test func notesRoundTrip() {
        #expect(LabelIcon.parse(note: LabelIcon.note(for: "airplane")) == "airplane")
        #expect(LabelIcon.parse(note: "  Sift icon: cart \n") == "cart")
        #expect(LabelIcon.parse(note: "Remember to call") == nil)
        #expect(LabelIcon.parse(note: "Sift icon: ") == nil)
    }

    #if canImport(AppKit)
    /// A typo would show as a blank square, so check every name with the system.
    @Test func everyCatalogSymbolExists() {
        let all = LabelIcon.catalog.flatMap(\.symbols)
        #expect(Set(all).count == all.count, "duplicate symbols")
        let suggested = ["Receipts", "Bills", "Bank", "Shipping", "Shop", "News", "Travel", "Family", "Friends", "Work",
                         "School", "Health", "Home", "Car", "Social", "Alerts", "Tickets", "Pets", "Music", "Games",
                         "Gym", "Food", "Security", "Subscriptions", "Import", "Promotions", "GitHub", "Paper Trail"].map(LabelIcon.suggested(for:))
        for symbol in all + suggested {
            #expect(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "\(symbol) isn't an SF Symbol")
        }
        #expect(Set(suggested).isSubset(of: Set(all)), "suggestions should be pickable too")
    }
    #endif

    @Test func iconsSyncThroughTheLabelsContactGroup() async throws {
        let server = DemoServer()
        let engine = try makeEngine(server)
        try await engine.start(activatedAt: .now.addingTimeInterval(-DemoSeed.activationAge))

        // Travel has no screening rules yet, so this creates its group.
        try await engine.setLabelIcon("suitcase", for: "travel")
        #expect(try await engine.store.read(.labelIcons) == ["travel": "suitcase"])
        let group = try #require(server.siftGroups().first { ($0["name"] as? [String: Any])?["full"] as? String == "Sift label: Travel" })
        #expect(group["members"] == nil)

        // Screening a sender into Travel reuses that group.
        try await engine.screenIn("bookings@fjordair.example", name: "Fjord Air", labels: ["travel"])
        #expect(server.siftGroups().filter { ($0["name"] as? [String: Any])?["full"] as? String == "Sift label: Travel" }.count == 1)

        // Another device reads it back, and sees it change.
        let other = try makeEngine(server)
        try await other.start()
        #expect(try await other.store.read(.labelIcons) == ["travel": "suitcase"])
        try await engine.setLabelIcon("airplane", for: "travel")
        try await other.syncRules()
        #expect(try await other.store.read(.labelIcons) == ["travel": "airplane"])

        // Clearing goes back to the guess everywhere, and the rule survives.
        try await other.setLabelIcon(nil, for: "travel")
        try await engine.syncRules()
        #expect(try await engine.store.read(.labelIcons).isEmpty)
        #expect(try await engine.store.sender("bookings@fjordair.example")?.labelIds == ["travel"])
    }
}
