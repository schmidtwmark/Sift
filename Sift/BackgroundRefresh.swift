#if os(iOS)
import BackgroundTasks
import Foundation

/// Best-effort iOS background sync. iOS decides when this runs (often tens of
/// minutes apart), so per-sender alerts can lag until a push relay exists.
enum BackgroundRefresh {
    static let identifier = "com.markschmidt.Sift.refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = .now.addingTimeInterval(15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    static func run(model: AppModel) async {
        schedule()
        await model.launch()
        await model.refresh(.automatic)
    }
}
#endif
