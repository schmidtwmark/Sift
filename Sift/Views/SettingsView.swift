import SwiftUI
#if os(macOS)
import ServiceManagement
#endif

/// iPhone and iPad: one scrolling form in a sheet.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            AccountSettings()
            SendingSettings()
            ToolsSettings()
            PrivacySettings()
            NotificationSettings()
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        #if os(iOS)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        #endif
    }
}

#if os(macOS)
/// Sift ▸ Settings… (⌘,): a tab per topic, like every other Mac app.
struct MacSettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    AccountSettings()
                    SendingSettings()
                    DefaultMailSettings()
                    LoginSettings()
                }
                .formStyle(.grouped)
            }
            Tab("Privacy", systemImage: "eye.slash") {
                Form { PrivacySettings() }.formStyle(.grouped)
            }
            Tab("Notifications", systemImage: "bell.badge") {
                Form { NotificationSettings() }.formStyle(.grouped)
            }
            Tab("Tools", systemImage: "wand.and.stars") {
                Form { ToolsSettings() }.formStyle(.grouped)
            }
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Whether email links open Sift. macOS confirms the change itself.
private struct DefaultMailSettings: View {
    @Environment(AppModel.self) private var model
    @State private var handler: URL?
    @State private var isAsking = false

    private static let probe = URL(string: "mailto:")!

    var body: some View {
        Section {
            LabeledContent("Default email app") {
                if let handler {
                    Label {
                        Text(FileManager.default.displayName(atPath: handler.path).replacingOccurrences(of: ".app", with: ""))
                    } icon: {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: handler.path))
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                } else {
                    Text("None")
                }
            }
            if !isDefault {
                Button("Make Sift the Default Email App") { Task { await makeDefault() } }
                    .disabled(isAsking)
            }
        } footer: {
            if !Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
                Text("This copy of Sift isn't in Applications, so links would open this build.")
            } else {
                Text("Email links on web pages and in other apps open a new message in Sift.")
            }
        }
        .onAppear(perform: refresh)
        // Picks up a change made in Mail's settings while Sift was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private var isDefault: Bool {
        handler.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
    }

    private func refresh() {
        handler = NSWorkspace.shared.urlForApplication(toOpen: Self.probe)
    }

    private func makeDefault() async {
        isAsking = true
        defer { isAsking = false }
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto")
        } catch let error as CocoaError where error.code == .userCancelled {
        } catch {
            model.errorMessage = "Couldn't make Sift the default email app. \(error.localizedDescription)"
        }
        refresh()
    }
}

private struct LoginSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Section {
            Toggle("Open Sift at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        model.errorMessage = error.localizedDescription
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
        } footer: {
            Text("Keeps screening and sender alerts running while Sift's window is closed.")
        }
    }
}
#endif

private struct AccountSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Section("Account") {
            LabeledContent("Signed in as", value: model.username.isEmpty ? "—" : model.username)
            if let started = model.screenerStartedAt {
                LabeledContent("Screening since", value: started.formatted(date: .abbreviated, time: .shortened))
            }
            Button(model.isDemo ? "Leave Demo" : "Sign Out", role: .destructive) {
                model.signOut()
                dismiss()
            }
            .disabled(model.phase != .ready)
        }
    }
}

private struct ToolsSettings: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showSuggestions = false
    @State private var showSort = false

    var body: some View {
        Section {
            Button("Suggest Screening Rules…") { suggest() }
            Button("Sort a Folder…") { sort() }
        } header: {
            Text("Tools")
        } footer: {
            Text("Learn rules from how you've already filed mail, or empty a folder (like an import from HEY) into your other folders.")
        }
        .disabled(model.phase != .ready)
        .sheet(isPresented: $showSuggestions) { RuleSuggestionsView() }
        .sheet(isPresented: $showSort) { FolderSortView() }
    }

    private func suggest() {
        #if os(macOS)
        openWindow(id: "suggestions")
        #else
        showSuggestions = true
        #endif
    }

    private func sort() {
        #if os(macOS)
        openWindow(id: "sort")
        #else
        showSort = true
        #endif
    }
}

private struct SendingSettings: View {
    @AppStorage(AppModel.undoSendDelayKey) private var undoDelay = 10

    var body: some View {
        Section {
            Picker("Undo Send Delay", selection: $undoDelay) {
                Text("Off").tag(0)
                Text("10 seconds").tag(10)
                Text("20 seconds").tag(20)
                Text("30 seconds").tag(30)
            }
        } header: {
            Text("Sending")
        } footer: {
            Text(undoDelay == 0
                 ? "Messages go as soon as you tap Send."
                 : "After you tap Send, you have \(undoDelay) seconds to take it back.")
        }
    }
}

private struct PrivacySettings: View {
    @AppStorage("loadRemoteImages") private var loadRemoteImages = true

    var body: some View {
        Section {
            Toggle("Load remote images", isOn: $loadRemoteImages)
        } header: {
            Text("Privacy")
        } footer: {
            Text("Spy pixels are always removed, and known tracking services are blocked from loading anything. Turn this off to block every remote image too; you can still load them one message at a time.")
        }
    }
}

private struct NotificationSettings: View {
    var body: some View {
        Section {
            LabeledContent("Default", value: "No alerts, no badge")
        } header: {
            Text("Notifications")
        } footer: {
            Text("Turn on alerts or the badge for individual senders from a message's sender settings (⌥⌘I).")
        }
    }
}
