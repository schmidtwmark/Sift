import SiftKit
import SwiftUI

struct Avatar: View {
    var name: String
    var email: String
    var size: CGFloat = 36

    var body: some View {
        Circle()
            .fill(color.gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }

    private var initials: String {
        let words = name.split(whereSeparator: { !$0.isLetter }).prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? String(email.prefix(1)).uppercased() : letters.uppercased()
    }

    private var color: Color {
        let palette: [Color] = [.teal, .indigo, .orange, .pink, .mint, .purple, .brown, .cyan, .green, .blue]
        let hash = email.unicodeScalars.reduce(5381) { ($0 &* 33) &+ Int($1.value) }
        return palette[abs(hash) % palette.count]
    }
}

extension MessageRecord {
    var senderDisplayName: String {
        if let fromName, !fromName.isEmpty { return fromName }
        return fromEmail
    }
}

extension Date {
    /// "9:41 AM" today, "Tue" this week, "Mar 4" this year, otherwise "3/4/24".
    var listLabel: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: self, to: .now).day, days < 6 {
            return formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.isDate(self, equalTo: .now, toGranularity: .year) {
            return formatted(.dateTime.month(.abbreviated).day())
        }
        return formatted(date: .numeric, time: .omitted)
    }
}

/// A toggleable label chip.
struct LabelChip: View {
    var title: String
    var systemImage: String?
    var isOn: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            // Same glyph slot and weight in both states, so toggling never reflows the row.
            HStack(spacing: 5) {
                Image(systemName: isOn ? "checkmark.circle.fill" : (systemImage ?? "circle"))
                    .font(.caption)
                    .imageScale(.medium)
                Text(title).lineLimit(1)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isOn ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1), in: Capsule())
            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
            .contentShape(Capsule())
        }
        // Borderless keeps each chip independently tappable inside List rows.
        .buttonStyle(.borderless)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// Tick one or more folders (the menu stays open while you do), optionally
/// create one, then apply with the last item. Used to screen senders in and
/// to change a conversation's folders.
struct FolderMenu<MenuLabel: View>: View {
    /// Folders ticked when the menu opens (a conversation's current folders).
    var initial: Set<String> = []
    let applyTitle: (Int) -> String
    var applyIcon = "folder"
    let onApply: (Set<String>) -> Void
    @ViewBuilder let label: () -> MenuLabel

    @State private var isPicking = false

    var body: some View {
        // A popover rather than a menu: Mac menus close on every click, and
        // iPhone menus re-lay themselves out when the first item is ticked.
        Button {
            isPicking = true
        } label: {
            label()
        }
        .popover(isPresented: $isPicking, arrowEdge: arrowEdge) {
            FolderPicker(initial: initial, applyTitle: applyTitle, applyIcon: applyIcon) { folders in
                isPicking = false
                onApply(folders)
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    /// Below the button on the Mac; on iPhone, wherever there's more room.
    private var arrowEdge: Edge? {
        #if os(macOS)
        .bottom
        #else
        nil
        #endif
    }
}

/// FolderMenu's popover: tick any number of folders, add one inline, then
/// apply. Mac: checkboxes, Space to tick, Return to apply.
private struct FolderPicker: View {
    @Environment(AppModel.self) private var model
    let initial: Set<String>
    let applyTitle: (Int) -> String
    let applyIcon: String
    let onApply: (Set<String>) -> Void

    @State private var chosen: Set<String>?
    @State private var filter = ""
    @State private var isNamingFolder = false
    @State private var newFolderName = ""
    @State private var isCreating = false
    @FocusState private var nameFocused: Bool

    private var selection: Set<String> { chosen ?? initial }

    private var folders: [MailboxRecord] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return query.isEmpty ? model.labels : model.labels.filter { $0.name.localizedStandardContains(query) }
    }

    private var canApply: Bool { !selection.isEmpty && !(selection == initial && !initial.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.labels.count > 8 {
                TextField("Filter Folders", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .padding([.horizontal, .top], 12)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: rowSpacing) {
                    ForEach(folders) { folder in
                        row(for: folder)
                    }
                    if folders.isEmpty {
                        Text("No folders match “\(filter)”").foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, rowSpacing + 4)
            }
            // Its full height when there's room; shrinks and scrolls when the
            // popover is squeezed (near the top or bottom of an iPhone screen).
            .frame(minHeight: min(listHeight, rowHeight * 3), idealHeight: listHeight, maxHeight: listHeight)

            Divider()
            newFolderRow
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            Divider()
            footer
                .padding(12)
        }
        .frame(width: 300)
        #if os(iOS)
        .sensoryFeedback(.selection, trigger: selection)
        #endif
    }

    // MARK: Rows

    private var listHeight: CGFloat {
        min(CGFloat(max(folders.count, 1)) * rowHeight + (rowSpacing + 4) * 2, 360)
    }

    #if os(macOS)
    private let rowSpacing: CGFloat = 6
    private let rowHeight: CGFloat = 22

    private func row(for folder: MailboxRecord) -> some View {
        Toggle(isOn: binding(for: folder.id)) {
            Label(folder.name, systemImage: model.icon(for: folder.id))
        }
        .toggleStyle(.checkbox)
    }
    #else
    private let rowSpacing: CGFloat = 0
    private let rowHeight: CGFloat = 44

    /// Icon, name, and a checkmark slot that's always there, so ticking a
    /// folder never moves anything.
    private func row(for folder: MailboxRecord) -> some View {
        let isOn = selection.contains(folder.id)
        return Button {
            toggle(folder.id)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: model.icon(for: folder.id))
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                Text(folder.name)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.tint)
                    .opacity(isOn ? 1 : 0)
            }
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
    #endif

    @ViewBuilder private var newFolderRow: some View {
        if isNamingFolder {
            HStack {
                TextField("New folder name", text: $newFolderName)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                    .submitLabel(.done)
                    .onSubmit { Task { await createFolder() } }
                    #if os(macOS)
                    .onExitCommand { cancelNaming() }
                    #endif
                if isCreating {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Add") { Task { await createFolder() } }
                        .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { nameFocused = true }
        } else {
            Button("New Folder…", systemImage: "folder.badge.plus") { isNamingFolder = true }
                .buttonStyle(.borderless)
        }
    }

    @ViewBuilder private var footer: some View {
        #if os(macOS)
        HStack {
            Text(selection.isEmpty ? "Tick one or more folders" : "\(selection.count) selected")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(applyTitle(max(selection.count, 1)), systemImage: applyIcon) { onApply(selection) }
                .buttonStyle(.borderedProminent)
                // Return creates the folder while you're naming one.
                .keyboardShortcut(isNamingFolder ? nil : .defaultAction)
                .disabled(!canApply)
        }
        #else
        Button {
            onApply(selection)
        } label: {
            Label(selection.isEmpty ? "Pick Folders Above" : applyTitle(selection.count), systemImage: applyIcon)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!canApply)
        #endif
    }

    // MARK: Changes

    private func binding(for id: String) -> Binding<Bool> {
        Binding(get: { selection.contains(id) }, set: { _ in toggle(id) })
    }

    private func toggle(_ id: String) {
        var updated = selection
        if updated.contains(id) { updated.remove(id) } else { updated.insert(id) }
        chosen = updated
    }

    private func cancelNaming() {
        newFolderName = ""
        isNamingFolder = false
    }

    private func createFolder() async {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !isCreating else { return }
        isCreating = true
        defer { isCreating = false }
        guard let id = await model.createLabel(named: name) else { return }
        chosen = selection.union([id])
        filter = ""
        cancelNaming()
    }
}

/// Wraps children onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// Shows a placeholder when a list is empty.
struct EmptyState: View {
    var title: String
    var systemImage: String
    var message: String

    var body: some View {
        ContentUnavailableView(title, systemImage: systemImage, description: Text(message))
    }
}

extension View {
    /// Search operators (`from:stripe`) shouldn't be capitalized or autocorrected.
    func plainSearchInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        autocorrectionDisabled()
        #endif
    }
}

/// "Archived · Undo", floating above the content for a few seconds.
struct ToastView: View {
    @Environment(AppModel.self) private var model
    let toast: AppModel.Toast

    var body: some View {
        HStack(spacing: 16) {
            Text(toast.message)
                .font(.subheadline.weight(.medium))
            if let undo = toast.undo {
                Button("Undo") {
                    withAnimation(.snappy) { model.toast = nil }
                    Task { await undo() }
                }
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect()
        .accessibilityElement(children: .combine)
    }
}

extension Color {
    /// Behind the reader's message panels (Mail's grouped background).
    static var readerBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// A message panel: white in light mode, raised dark gray in dark mode.
    static var readerPanel: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .textBackgroundColor)
        #endif
    }
}

/// Icon and name, tight, for label chips.
struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        // Baseline-aligned, so the icon sits on the first line when the title wraps.
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension LabelStyle where Self == ChipLabelStyle {
    static var chip: ChipLabelStyle { ChipLabelStyle() }
}
