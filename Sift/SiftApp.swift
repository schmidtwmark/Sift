import SiftKit
import SwiftUI

@main
struct SiftApp: App {
    @State private var model = AppModel()
    #if os(iOS)
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some Scene {
        WindowGroup(id: "main") {
            RootView()
                .environment(model)
                .task { await model.launch() }
        }
        .commands { SiftCommands(model: model) }
        #if os(iOS)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackgroundRefresh.schedule() }
            if phase == .active { Task { await model.refresh(.automatic) } }
        }
        .backgroundTask(.appRefresh(BackgroundRefresh.identifier)) {
            await BackgroundRefresh.run(model: model)
        }
        #endif

        #if os(macOS)
        WindowGroup("Conversation", id: "thread", for: String.self) { $threadId in
            ThreadWindow(threadId: threadId)
                .environment(model)
                .tint(Color("AccentColor"))
        }
        .defaultSize(width: 760, height: 860)

        WindowGroup("New Message", id: "compose", for: ComposeTarget.self) { $target in
            ComposeWindow(target: target)
                .environment(model)
                .tint(Color("AccentColor"))
        }
        .defaultSize(width: 640, height: 640)
        // Drafts aren't saved yet, so don't bring back empty shells on relaunch.
        .restorationBehavior(.disabled)
        // Email links from other apps (Sift as the default email app) each get a new message.
        .handlesExternalEvents(matching: ["mailto:"])

        WindowGroup("Sender", id: "sender", for: String.self) { $email in
            SenderWindow(email: email)
                .environment(model)
                .tint(Color("AccentColor"))
        }
        .defaultSize(width: 440, height: 560)
        .windowResizability(.contentMinSize)

        Window("Suggested Rules", id: "suggestions") {
            RuleSuggestionsView()
                .environment(model)
                .tint(Color("AccentColor"))
        }
        .restorationBehavior(.disabled)

        Window("Sort a Folder", id: "sort") {
            FolderSortView()
                .environment(model)
                .tint(Color("AccentColor"))
        }
        .restorationBehavior(.disabled)

        Window("Sift Help", id: "help") {
            HelpView()
        }
        .defaultSize(width: 560, height: 720)

        Settings {
            MacSettingsView()
                .environment(model)
        }
        #endif
    }
}
