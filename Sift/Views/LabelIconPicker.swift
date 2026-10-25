import SiftKit
import SwiftUI

/// A grid of symbols for one label. Picking applies at once (and syncs to your
/// other devices); "Use Suggested" goes back to the icon guessed from the name.
struct LabelIconPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let mailboxId: String
    /// A Mac popover closes by clicking away, so it has no Done button.
    var showsDone = true

    @State private var search = ""

    private let columns = [GridItem(.adaptive(minimum: 38, maximum: 46), spacing: 6)]

    var body: some View {
        let current = model.icon(for: mailboxId)
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: current)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 40, height: 40)
                    .background(.tint.opacity(0.15), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(model.name(of: mailboxId))
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                if showsDone {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding([.horizontal, .top])
            .padding(.bottom, 10)

            TextField("Search Icons", text: $search)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .padding(.horizontal)
                .padding(.bottom, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(categories) { category in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(category.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                                ForEach(category.symbols, id: \.self) { symbol in
                                    symbolButton(symbol, isCurrent: symbol == current)
                                }
                            }
                        }
                    }
                    if categories.isEmpty {
                        Text("No icons match “\(search)”")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }

            Divider()
            HStack {
                Button("Use Suggested") { choose(nil) }
                    .disabled(model.labelIcons[mailboxId] == nil)
                Spacer()
                Text("Syncs to your other devices")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        #if os(macOS)
        .frame(width: 360, height: 440)
        #endif
    }

    private func symbolButton(_ symbol: String, isCurrent: Bool) -> some View {
        Button {
            choose(symbol)
        } label: {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 38, height: 38)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                .background {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.tint.opacity(0.18))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(symbol)
        .accessibilityLabel(symbol.replacingOccurrences(of: ".", with: " "))
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    /// The catalog, narrowed by the search field (symbol names and category titles).
    private var categories: [LabelIcon.Category] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return LabelIcon.catalog }
        return LabelIcon.catalog.compactMap { category in
            if category.title.lowercased().contains(query) { return category }
            let matches = category.symbols.filter { $0.replacingOccurrences(of: ".", with: " ").contains(query) }
            return matches.isEmpty ? nil : LabelIcon.Category(title: category.title, symbols: matches)
        }
    }

    private func choose(_ symbol: String?) {
        let id = mailboxId
        Task { await model.setIcon(symbol, for: id) }
    }
}

/// Right-click (or long-press) a label for "Change Icon…".
struct LabelIconEditing: ViewModifier {
    let mailboxId: String
    @State private var isPicking = false

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Change Icon…", systemImage: "square.grid.2x2") { isPicking = true }
            }
            .popover(isPresented: $isPicking) {
                #if os(macOS)
                LabelIconPicker(mailboxId: mailboxId, showsDone: false)
                #else
                LabelIconPicker(mailboxId: mailboxId)
                    .presentationDetents([.medium, .large])
                    .presentationCompactAdaptation(.sheet)
                #endif
            }
    }
}
