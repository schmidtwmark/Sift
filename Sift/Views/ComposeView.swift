import PhotosUI
import SiftKit
import SwiftUI
import UniformTypeIdentifiers

/// Mail-style compose. iPhone: a sheet with Cancel and Send. Mac: a window
/// with Send, Attach and Delete Draft in the toolbar. Drafts save to Fastmail
/// as you go, and Send waits out the Undo Send delay.
struct ComposeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let request: ComposeRequest

    @State private var draft = ComposeDraft()
    @State private var prepared = false
    @FocusState private var focus: ComposeDraft.Field?
    @State private var suggestions: [EmailAddress] = []
    @State private var confirmCancel = false
    @State private var confirmNoSubject = false
    @State private var choosingFiles = false
    @State private var choosingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            fields
                .navigationTitle(draft.title)
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar { toolbar }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 480)
        #endif
        .interactiveDismissDisabled(draft.hasEdits)
        .task {
            guard !prepared else { return }
            prepared = true
            focus = await draft.prepare(request, model: model)
        }
        // Saves a draft after a pause in editing, like Mail.
        .task(id: draft.message.content) {
            guard (try? await Task.sleep(for: .seconds(15))) != nil else { return }
            await draft.save(model: model)
        }
        .task(id: suggestionQuery) { await loadSuggestions() }
        .onChange(of: focus) { old, _ in
            if let old { draft.commit(old) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await draft.save(model: model) } }
        }
        #if os(macOS)
        // Closing the window keeps what you wrote in Drafts.
        .onDisappear {
            guard !draft.isFinished else { return }
            let draft = draft, model = model
            Task {
                for field in [ComposeDraft.Field.to, .cc, .bcc] { draft.commit(field) }
                if await draft.save(model: model) { model.show(AppModel.Toast(message: "Saved to Drafts")) }
            }
        }
        #endif
        .confirmationDialog("Keep this message?", isPresented: $confirmCancel, titleVisibility: .hidden) {
            Button("Delete Draft", role: .destructive) {
                Task {
                    await draft.discard(model: model)
                    dismiss()
                }
            }
            Button("Save Draft") { Task { await saveAndClose() } }
        }
        .alert("This message has no subject.", isPresented: $confirmNoSubject) {
            Button("Send Anyway") { Task { await send() } }
            Button("Cancel", role: .cancel) { focus = .subject }
        }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            for url in urls { Task { await draft.attach(fileAt: url, model: model) } }
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photoItems, maxSelectionCount: 20,
                      matching: .any(of: [.images, .videos]))
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            for (index, item) in items.enumerated() { Task { await attach(item, number: draft.attachments.count + index + 1) } }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            for url in files { Task { await draft.attach(fileAt: url, model: model) } }
            return !files.isEmpty
        }
    }

    // MARK: - Header fields and body

    private var fields: some View {
        VStack(spacing: 0) {
            recipientRow(.to, label: "To:")
            if showsCcBcc {
                recipientRow(.cc, label: "Cc:")
                #if os(macOS)
                if draft.showsAllHeaders || !draft.bcc.isEmpty { recipientRow(.bcc, label: "Bcc:") }
                #else
                recipientRow(.bcc, label: "Bcc:")
                #endif
                if model.identities.count > 1 { fromRow }
            } else {
                collapsedHeaders
            }
            headerRow(label: "Subject:") {
                TextField("", text: $draft.subject)
                    .focused($focus, equals: .subject)
                    .onSubmit { focus = .body }
                    .accessibilityLabel("Subject")
            }
            if !draft.attachments.isEmpty { attachmentStrip }
            TextEditor(text: $draft.body)
                .focused($focus, equals: .body)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, bodyInset)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Message")
        }
        .textFieldStyle(.plain)
        .background(Color.composeBackground)
    }

    /// iPhone folds Cc, Bcc and From into one line until you need them; the Mac shows Cc.
    private var showsCcBcc: Bool {
        #if os(macOS)
        true
        #else
        draft.showsAllHeaders
        #endif
    }

    private var bodyInset: CGFloat {
        #if os(macOS)
        7
        #else
        11
        #endif
    }

    private var collapsedHeaders: some View {
        Button {
            draft.showsAllHeaders = true
            focus = .cc
        } label: {
            headerRow(label: "Cc/Bcc, From:") {
                Text(currentIdentity?.email ?? "")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var fromRow: some View {
        headerRow(label: "From:") {
            Picker("From", selection: $draft.identityId) {
                ForEach(model.identities) { identity in
                    Text("\(identity.name) <\(identity.email)>").tag(identity.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            Spacer(minLength: 0)
        }
    }

    private var currentIdentity: Identity? { model.identities.first { $0.id == draft.identityId } }

    private func headerRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(label)
                    .foregroundStyle(.secondary)
                    #if os(macOS)
                    .frame(minWidth: 58, alignment: .trailing)
                    #endif
                content()
            }
            .padding(.horizontal, rowInset)
            .padding(.vertical, rowPadding)
            Divider().padding(.leading, rowInset)
        }
    }

    private var rowInset: CGFloat {
        #if os(macOS)
        12
        #else
        16
        #endif
    }

    private var rowPadding: CGFloat {
        #if os(macOS)
        7
        #else
        11
        #endif
    }

    // MARK: - Recipients

    private func recipientRow(_ field: ComposeDraft.Field, label: String) -> some View {
        VStack(spacing: 0) {
            headerRow(label: label) {
                FlowLayout(spacing: 6) {
                    ForEach(Array(addresses(field).wrappedValue.enumerated()), id: \.offset) { _, address in
                        RecipientToken(address: address) {
                            addresses(field).wrappedValue.removeAll { $0 == address }
                        }
                    }
                    TextField("", text: text(field))
                        .focused($focus, equals: field)
                        .autocorrectionDisabled()
                        .textContentType(.emailAddress)
                        #if os(iOS)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        #endif
                        .frame(minWidth: 140)
                        .onSubmit {
                            if let first = suggestions.first, focus == field, !text(field).wrappedValue.isEmpty {
                                draft.add(first, to: field)
                            } else {
                                draft.commit(field)
                            }
                        }
                        .onChange(of: text(field).wrappedValue) { _, typed in
                            if typed.contains(",") || typed.contains(";") { draft.commit(field) }
                        }
                        .accessibilityLabel(label)
                }
                #if os(macOS)
                if field == .cc, !draft.showsAllHeaders, draft.bcc.isEmpty {
                    Button("Bcc") { draft.showsAllHeaders = true; focus = .bcc }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .help("Add a Bcc field")
                }
                #endif
            }
            if focus == field, !suggestions.isEmpty, !text(field).wrappedValue.isEmpty {
                suggestionList(for: field)
            }
        }
    }

    private func addresses(_ field: ComposeDraft.Field) -> Binding<[EmailAddress]> {
        switch field {
        case .cc: $draft.cc
        case .bcc: $draft.bcc
        default: $draft.to
        }
    }

    private func text(_ field: ComposeDraft.Field) -> Binding<String> {
        switch field {
        case .cc: $draft.ccText
        case .bcc: $draft.bccText
        default: $draft.toText
        }
    }

    private func suggestionList(for field: ComposeDraft.Field) -> some View {
        VStack(spacing: 0) {
            ForEach(suggestions, id: \.self) { address in
                Button {
                    draft.add(address, to: field)
                    suggestions = []
                } label: {
                    HStack(spacing: 10) {
                        Avatar(name: address.displayName, email: address.normalized, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(address.name ?? address.email ?? "").lineLimit(1)
                            if address.name != nil {
                                Text(address.email ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, rowInset)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Divider()
        }
        .background(Color.secondary.opacity(0.06))
    }

    /// What's being typed in the focused address field.
    private var suggestionQuery: String {
        guard let focus, [ComposeDraft.Field.to, .cc, .bcc].contains(focus) else { return "" }
        return "\(focus)|\(text(focus).wrappedValue)"
    }

    private func loadSuggestions() async {
        guard let focus, !text(focus).wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty else {
            suggestions = []
            return
        }
        try? await Task.sleep(for: .milliseconds(120))
        guard !Task.isCancelled else { return }
        let added = Set((draft.to + draft.cc + draft.bcc).map(\.normalized))
        suggestions = await model.addressSuggestions(matching: text(focus).wrappedValue).filter { !added.contains($0.normalized) }
    }

    // MARK: - Attachments

    private var attachmentStrip: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(draft.attachments) { file in
                        AttachmentChip(file: file) { draft.remove(file.id) }
                    }
                }
                .padding(.horizontal, rowInset)
                .padding(.vertical, 8)
            }
            Divider().padding(.leading, rowInset)
        }
    }

    private func attach(_ item: PhotosPickerItem, number: Int) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let type = item.supportedContentTypes.first
        let ext = type?.preferredFilenameExtension ?? "jpg"
        let name = type?.conforms(to: .movie) == true ? "Video \(number).\(ext)" : "Photo \(number).\(ext)"
        await draft.attach(data, name: name, type: type?.preferredMIMEType ?? "image/jpeg", model: model)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", systemImage: "xmark") { cancel() }
        }
        ToolbarItem(placement: .primaryAction) { attachMenu }
        ToolbarItem(placement: .confirmationAction) { sendButton }
        #else
        ToolbarItem(placement: .navigation) { sendButton }
        ToolbarItem(placement: .primaryAction) { attachMenu }
        ToolbarItem(placement: .primaryAction) {
            Button("Delete Draft", systemImage: "trash") {
                Task {
                    await draft.discard(model: model)
                    dismiss()
                }
            }
            .help("Delete this message")
        }
        #endif
    }

    private var sendButton: some View {
        Button {
            requestSend()
        } label: {
            if draft.isSending {
                ProgressView().controlSize(.small)
            } else {
                Label("Send", systemImage: sendSymbol)
            }
        }
        #if os(macOS)
        .keyboardShortcut("d", modifiers: [.command, .shift])
        .help(draft.isUploading ? "Waiting for attachments to upload" : "Send (⇧⌘D)")
        #else
        .keyboardShortcut(.return, modifiers: .command)
        #endif
        .disabled(!draft.canSend)
    }

    private var sendSymbol: String {
        #if os(macOS)
        "paperplane"
        #else
        "arrow.up"
        #endif
    }

    private var attachMenu: some View {
        Menu {
            Button("Photo Library", systemImage: "photo.on.rectangle") { choosingPhotos = true }
            Button("Choose File…", systemImage: "folder") { choosingFiles = true }
                #if os(macOS)
                .keyboardShortcut("a", modifiers: [.command, .shift])
                #endif
        } label: {
            Label("Attach", systemImage: "paperclip")
        }
        .help("Attach photos or files")
    }

    // MARK: - Actions

    private func requestSend() {
        for field in [ComposeDraft.Field.to, .cc, .bcc] { draft.commit(field) }
        guard draft.canSend else { return }
        if draft.subject.trimmingCharacters(in: .whitespaces).isEmpty {
            confirmNoSubject = true
        } else {
            Task { await send() }
        }
    }

    private func send() async {
        if await draft.send(model: model) { dismiss() }
    }

    /// iPhone's Cancel: asks to save or delete when there's something to lose.
    private func cancel() {
        for field in [ComposeDraft.Field.to, .cc, .bcc] { draft.commit(field) }
        if draft.hasEdits, !draft.message.isBlank {
            confirmCancel = true
        } else {
            Task {
                // An autosaved draft that's since been emptied goes too.
                if draft.message.isBlank { await draft.discard(model: model) }
                dismiss()
            }
        }
    }

    private func saveAndClose() async {
        await draft.save(model: model)
        // Still unsaved means saving failed; the alert says why, and the message stays open.
        if !draft.hasEdits { dismiss() }
    }
}

/// An address in the To, Cc or Bcc field: tap it to see the address or remove it.
private struct RecipientToken: View {
    let address: EmailAddress
    let onRemove: () -> Void

    var body: some View {
        Menu {
            Section(address.email ?? "") {
                Button("Remove", systemImage: "minus.circle", role: .destructive, action: onRemove)
            }
        } label: {
            Text(address.name?.isEmpty == false ? address.name! : address.email ?? "")
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .foregroundStyle(.tint)
                .background(Color.accentColor.opacity(0.14), in: Capsule())
        }
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(address.name.map { "\($0), \(address.email ?? "")" } ?? address.email ?? "")
    }
}

/// A file attached to the message being written, with its upload state.
private struct AttachmentChip: View {
    let file: ComposeDraft.PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Group {
                switch file.state {
                case .uploading: ProgressView().controlSize(.small)
                case .ready: Image(systemName: file.isImage ? "photo" : "doc")
                case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(file.name)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(isFailed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            Button("Remove \(file.name)", systemImage: "xmark.circle.fill", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: 240, alignment: .leading)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var isFailed: Bool { if case .failed = file.state { true } else { false } }

    private var detail: String {
        switch file.state {
        case .uploading: "Uploading…"
        case .ready: ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file)
        case .failed(let reason): reason
        }
    }
}

extension Color {
    /// Behind the compose fields: the plain text background, like Mail.
    static var composeBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .textBackgroundColor)
        #endif
    }
}
