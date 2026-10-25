import Foundation
import Testing
@testable import SiftKit

@Suite struct ObservationTests {
    @Test func threadObservationEmitsWhileSearchIsObserved() async throws {
        let store = try MailStore.inMemory()
        try await store.upsert([email("1", from: "a@x.com", subject: "Appointment", thread: "T1")])
        let search = Task {
            for try await _ in store.observe(.search(SearchQuery("appointment"))) {}
        }
        defer { search.cancel() }
        try await Task.sleep(for: .milliseconds(100))
        let thread = try await withThrowingTaskGroup(of: [MessageRecord].self) { group in
            group.addTask {
                for try await value in store.observe(.thread("T1")) { return value }
                return []
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw CancellationError()
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }
        #expect(thread.map(\.id) == ["1"])
    }
}
