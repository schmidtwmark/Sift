import Observation
import SiftKit

/// Observes a store query for as long as the owning view exists. Unlike a
/// `.task`, SwiftUI can't cancel it during navigation transitions (which
/// happens when pushing a result from an active search on iPhone).
@Observable
final class LiveQuery<Value: Sendable> {
    private(set) var value: Value?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var key: String?

    func start(_ store: MailStore?, _ query: StoreQuery<Value>, key: String) {
        guard let store, self.key != key else { return }
        self.key = key
        task?.cancel()
        task = Task { [weak self] in
            do {
                for try await value in store.observe(query) { self?.value = value }
            } catch {}
        }
    }

    isolated deinit { task?.cancel() }
}
