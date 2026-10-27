import SiftKit
import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    #if os(iOS)
    @State private var composing: ComposeRequest?
    #endif

    var body: some View {
        @Bindable var model = model
        Group {
            switch model.phase {
            case .launching:
                ProgressView()
            case .signedOut, .failed, .connecting:
                OnboardingView()
            case .syncing:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Syncing with Fastmail…").foregroundStyle(.secondary)
                }
            case .ready:
                MainView()
            }
        }
        .tint(Color("AccentColor"))
        .environment(\.compose, composeAction)
        // Undo Send brings the message back to finish it.
        .onChange(of: model.composeToReopen?.id) {
            guard let request = model.composeToReopen else { return }
            model.composeToReopen = nil
            composeAction(request)
        }
        #if os(iOS)
        .sheet(item: $composing) { request in
            ComposeView(request: request)
        }
        // Email links, once Sift is the default mail app.
        .onOpenURL { url in
            if let link = MailtoLink(url) { composing = ComposeRequest(mailto: link) }
        }
        #endif
        .alert("Something went wrong", isPresented: $model.showsError) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    /// A sheet on iPhone and iPad; its own window on the Mac.
    private var composeAction: ComposeAction {
        #if os(macOS)
        ComposeAction { openWindow(id: "compose", value: ComposeTarget($0)) }
        #else
        ComposeAction { composing = $0 }
        #endif
    }
}

/// Sidebar → list → reader. Collapses to a stack on iPhone. Each window keeps
/// its own place, so two viewer windows can show different folders.
struct MainView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.compose) private var compose
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @SceneStorage("sidebar") private var savedSidebar = ""
    @State private var sidebar: SidebarItem?
    @State private var pendingThread: String?
    @State private var selectedThreads: Set<String> = []
    @State private var selectedSender: String?
    @State private var searchText = ""
    @FocusState private var searchFocused: Bool
    @State private var showSettings = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $sidebar, showSettings: $showSettings)
        } content: {
            content
                .searchable(text: $searchText, placement: .toolbar, prompt: "Search all mail")
                .searchFocused($searchFocused)
                .searchSuggestions { SearchSuggestions(text: $searchText) }
                .plainSearchInput()
        } detail: {
            detail
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    #if os(iOS)
                    .padding(.bottom, 76)  // above the bottom search field
                    #else
                    .padding(.bottom, 20)
                    #endif
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .onAppear {
            if sidebar == nil { sidebar = SidebarItem(storageKey: savedSidebar) ?? initialSidebar }
        }
        .onChange(of: sidebar) { _, item in
            savedSidebar = item?.storageKey ?? ""
            selectedThreads = pendingThread.map { [$0] } ?? []
            pendingThread = nil
            selectedSender = nil
        }
        .onChange(of: searchText) { selectedThreads = [] }
        .onChange(of: model.threadToOpen, initial: true) {
            guard let id = model.threadToOpen else { return }
            model.threadToOpen = nil
            open(id)
        }
        .focusedSceneValue(\.windowCommands, WindowCommands(
            show: { item in
                searchText = ""
                sidebar = item
            },
            focusSearch: { searchFocused = true },
            compose: { compose($0) },
            isEditingText: searchFocused
        ))
        #if os(iOS)
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        #endif
    }

    /// iPhone starts on the home screen (mailboxes and global search); iPad and
    /// Mac start in the Screener, or the Inbox when nobody's waiting.
    private var initialSidebar: SidebarItem? {
        #if os(iOS)
        if sizeClass == .compact { return nil }
        #endif
        return model.defaultSidebar
    }

    /// Shows a conversation from a notification, in Everything so it's there
    /// whichever folder it was filed in.
    private func open(_ threadId: String) {
        searchText = ""
        if sidebar == .everything {
            selectedThreads = [threadId]
        } else {
            pendingThread = threadId
            sidebar = .everything
        }
    }

    private var listMailbox: String? {
        if case .mailbox(let id)? = sidebar { return id }
        return nil
    }

    @ViewBuilder private var content: some View {
        if !searchText.isEmpty {
            SearchResultsView(text: searchText, selection: $selectedThreads)
        } else {
            switch sidebar {
            case .screener?:
                ScreenerView(selection: $selectedSender)
            case .mailbox(let id)?:
                ThreadListView(mailboxId: id, title: model.name(of: id), selection: $selectedThreads)
            case .everything?:
                ThreadListView(mailboxId: nil, title: "Everything", selection: $selectedThreads)
            case .senders?:
                SendersView(selection: $selectedSender)
            case nil:
                EmptyState(title: "Sift", systemImage: "line.3.horizontal.decrease", message: "Pick a view from the sidebar.")
            }
        }
    }

    private var sourceMailbox: String? { searchText.isEmpty ? listMailbox : nil }

    @ViewBuilder private var detail: some View {
        if selectedThreads.count == 1, let id = selectedThreads.first {
            ThreadView(threadId: id, sourceMailbox: sourceMailbox, onClose: closeThread)
                .id(id)
        } else if selectedThreads.count > 1 {
            MultiSelectionView(threadIds: selectedThreads, mailboxId: sourceMailbox)
        } else if let selectedSender, sidebar == .screener, searchText.isEmpty {
            ScreenerSenderView(email: selectedSender, onClose: { self.selectedSender = nil })
                .id(selectedSender)
        } else if let selectedSender, sidebar == .senders {
            SenderSettingsView(email: selectedSender)
                .id(selectedSender)
        } else {
            EmptyState(title: "No Conversation Selected", systemImage: "envelope", message: "Choose a conversation to read it.")
        }
    }

    /// After Archive, Spam or Trash in the reader. iPhone goes back to the
    /// list; the Mac's list moves on to the next conversation by itself.
    private func closeThread() {
        #if os(iOS)
        selectedThreads = []
        #endif
    }
}
