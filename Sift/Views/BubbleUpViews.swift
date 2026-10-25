import SiftKit
import SwiftUI

/// Bubble Up choices for a conversation: later today, tomorrow, the weekend,
/// next week or a chosen time, and a way to call off one that's set.
struct BubbleUpMenu<MenuLabel: View>: View {
    @Environment(AppModel.self) private var model
    let threadId: String
    @ViewBuilder let label: () -> MenuLabel
    @State private var choosingDate = false

    var body: some View {
        Menu {
            if let pending = model.bubbleUp(for: threadId) {
                Section("Bubbles up \(pending.at.bubbleUpLabel)") {
                    Button("Don't Bubble Up", systemImage: "xmark.circle") {
                        Task { await model.cancelBubbleUp(pending) }
                    }
                }
            }
            Section(model.bubbleUp(for: threadId) == nil ? "Bubble Up" : "Change To") {
                ForEach(BubbleUp.suggestions(), id: \.title) { option in
                    Button {
                        Task { await model.bubbleUp(threadId, at: option.date) }
                    } label: {
                        Text(option.title)
                        Text(option.date.bubbleUpLabel.capitalizedFirstLetter)
                    }
                }
                Button("Choose a Time…", systemImage: "calendar") { choosingDate = true }
            }
        } label: {
            label()
        }
        // Soonest first, even when the menu opens upward from a bottom toolbar.
        .menuOrder(.fixed)
        .sheet(isPresented: $choosingDate) {
            BubbleUpPicker(threadId: threadId)
        }
    }
}

/// Pick any time for a conversation to bubble up.
struct BubbleUpPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let threadId: String
    @State private var date = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Bubble up", selection: $date, in: Date.now.addingTimeInterval(5 * 60)...,
                           displayedComponents: [.date, .hourAndMinute])
                    .datePickerStyle(.graphical)
                Text("It comes back to the top of your mail, unread, at \(date.bubbleUpLabel). Fastmail's own apps show it too.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .navigationTitle("Bubble Up")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Bubble Up") {
                        let threadId = threadId, date = date
                        dismiss()
                        Task { await model.bubbleUp(threadId, at: date) }
                    }
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.large])
        #else
        .frame(minWidth: 380, minHeight: 460)
        #endif
    }
}

/// "Bubbles up Tuesday" before, "Bubbled up" after: shown in lists and the reader.
struct BubbleUpBadge: View {
    @Environment(AppModel.self) private var model
    let threadId: String
    var bubbledAt: Date?

    var body: some View {
        if let pending = model.bubbleUp(for: threadId) {
            Label(pending.at.bubbleUpLabel.capitalizedFirstLetter, systemImage: AppModel.bubbleUpSymbol)
                .labelStyle(.chip)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Bubbles up \(pending.at.bubbleUpLabel)")
        } else if bubbledAt != nil {
            Label("Bubbled up", systemImage: AppModel.bubbleUpSymbol)
                .labelStyle(.chip)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tint)
        }
    }
}

extension String {
    var capitalizedFirstLetter: String { prefix(1).uppercased() + dropFirst() }
}
