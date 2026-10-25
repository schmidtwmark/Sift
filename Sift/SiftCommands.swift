import SiftKit
import SwiftUI

/// The menu bar. Everything here acts on the focused window: its selected
/// conversations (`mailSelection`) and its sidebar and search (`windowCommands`).
struct SiftCommands: Commands {
    let model: AppModel
    @FocusedValue(\.mailSelection) private var selection
    @FocusedValue(\.windowCommands) private var window
    @Environment(\.openWindow) private var openWindow

    private var ready: Bool { model.phase == .ready }

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()

        CommandGroup(replacing: .newItem) {
            Button("New Message", systemImage: "square.and.pencil") { compose(ComposeRequest()) }
                .keyboardShortcut("n")
                .disabled(!ready)
            #if os(macOS)
            Button("New Viewer Window", systemImage: "macwindow.badge.plus") { openWindow(id: "main") }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Divider()
            Button("Open Conversation", systemImage: "macwindow") {
                for id in selection?.threadIds ?? [] { openWindow(id: "thread", value: id) }
            }
            .keyboardShortcut("o")
            .disabled(selection == nil)
            #endif
        }

        CommandGroup(after: .textEditing) {
            Button("Search Mail", systemImage: "magnifyingglass") { window?.focusSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(window == nil)
        }

        CommandMenu("Mailbox") {
            Button("Get New Mail", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(!ready || model.isSyncing)
            Divider()
            Button("Screener", systemImage: "person.crop.circle.badge.questionmark") { window?.show(.screener) }
                .keyboardShortcut("1")
                .disabled(window == nil)
            Button("Inbox", systemImage: "tray") {
                if let inbox = model.special?.inbox { window?.show(.mailbox(inbox)) }
            }
            .keyboardShortcut("2")
            .disabled(window == nil)
            Button("Everything", systemImage: "square.stack.3d.up") { window?.show(.everything) }
                .keyboardShortcut("3")
                .disabled(window == nil)
            Button("Senders", systemImage: "person.2") { window?.show(.senders) }
                .keyboardShortcut("4")
                .disabled(window == nil)
            #if os(macOS)
            Divider()
            Button("Suggest Screening Rules…", systemImage: "wand.and.stars") { openWindow(id: "suggestions") }
                .disabled(!ready)
            Button("Sort a Folder…", systemImage: "arrow.triangle.branch") { openWindow(id: "sort") }
                .disabled(!ready)
            #endif
        }

        CommandMenu("Message") {
            MessageMenu(model: model, selection: selection, isEditingText: window?.isEditingText ?? false, compose: compose)
                .environment(model)
        }

        #if os(macOS)
        CommandGroup(replacing: .help) {
            Button("Sift Help") { openWindow(id: "help") }
                .keyboardShortcut("?")
        }
        #endif
    }

    private func compose(_ request: ComposeRequest) {
        #if os(macOS)
        openWindow(id: "compose", value: ComposeTarget(request))
        #else
        window?.compose(request)
        #endif
    }
}

/// Message ▸ …, with Mail's shortcuts.
private struct MessageMenu: View {
    let model: AppModel
    let selection: MailSelection?
    /// The search field has focus: leave ⌘⌫ to it.
    let isEditingText: Bool
    let compose: (ComposeRequest) -> Void
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        let latest = selection?.latest
        Button("Reply", systemImage: "arrowshape.turn.up.left") { latest.map { compose(ComposeRequest(replyTo: $0)) } }
            .keyboardShortcut("r")
            .disabled(latest == nil)
        Button("Reply All", systemImage: "arrowshape.turn.up.left.2") { latest.map { compose(ComposeRequest(replyTo: $0, replyAll: true)) } }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(latest == nil)
        Button("Forward", systemImage: "arrowshape.turn.up.right") { latest.map { compose(ComposeRequest(forward: $0)) } }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(latest == nil)
        Divider()

        if let selection {
            let ids = selection.threadIds, source = selection.mailboxId, undo = selection.undoManager
            Button("Archive", systemImage: "archivebox") { Task { await model.archive(threads: ids, from: source, undo: undo) } }
                .keyboardShortcut("a", modifiers: [.command, .control])
            Button("Move to Trash", systemImage: "trash") { Task { await model.trash(threads: ids, undo: undo) } }
                .keyboardShortcut(isEditingText ? nil : KeyboardShortcut(.delete))
            Button("Move to Spam", systemImage: "xmark.bin") { Task { await model.junk(threads: ids, undo: undo) } }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Divider()
            Button(selection.anyUnread ? "Mark as Read" : "Mark as Unread",
                   systemImage: selection.anyUnread ? "envelope.open" : "envelope.badge") {
                let read = selection.anyUnread
                Task { await model.markThreads(ids, read: read) }
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            Button(selection.allPinned ? "Unpin" : "Pin", systemImage: "pin") {
                let pin = !selection.allPinned
                Task { await model.setPinned(ids, pin) }
            }
            .keyboardShortcut("l", modifiers: [.command, .shift])
            Menu("Move To", systemImage: "folder") { MoveToItems(selection: selection) }
        } else {
            // Same items, disabled, so the menu doesn't change shape.
            Group {
                Button("Archive", systemImage: "archivebox") {}.keyboardShortcut("a", modifiers: [.command, .control])
                Button("Move to Trash", systemImage: "trash") {}
                Button("Move to Spam", systemImage: "xmark.bin") {}.keyboardShortcut("j", modifiers: [.command, .shift])
                Divider()
                Button("Mark as Unread", systemImage: "envelope.badge") {}.keyboardShortcut("u", modifiers: [.command, .shift])
                Button("Pin", systemImage: "pin") {}.keyboardShortcut("l", modifiers: [.command, .shift])
                Menu("Move To", systemImage: "folder") {}
            }
            .disabled(true)
        }

        #if os(macOS)
        Divider()
        Button("Sender Settings…", systemImage: "person.crop.circle") {
            if let email = latest?.fromEmail { openWindow(id: "sender", value: email) }
        }
        .keyboardShortcut("i", modifiers: [.command, .option])
        .disabled(latest == nil)
        #endif
    }
}
