import SiftKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @Environment(\.compose) private var compose
    @Environment(\.undoManager) private var undoManager
    @Binding var selection: SidebarItem?
    @Binding var showSettings: Bool
    @State private var screenerCount = 0
    @State private var searchText = ""
    /// Wiggle mode, as on the Home Screen: drag labels to rearrange them, tap
    /// one to change its icon, or add a new one.
    @State private var isArranging = false
    /// The label being pressed, which grows a little as you hold it. Resets by
    /// itself when the press ends, however it ends.
    @GestureState(resetTransaction: Transaction(animation: .spring(duration: 0.3, bounce: 0.4)))
    private var pressing: String?
    /// The labels' order while arranging; saved to Fastmail when you're done.
    @State private var order: [String] = []
    /// The label being dragged, where your finger is, and where on the tile you
    /// picked it up (all in the grid's space).
    @State private var dragging: String?
    @State private var dragLocation: CGPoint = .zero
    @State private var grabOffset: CGSize?
    @State private var tileFrames: [String: CGRect] = [:]
    @State private var pickingIcon: IdentifiedString?
    @State private var isNamingLabel = false
    @State private var newLabelName = ""

    /// On iPhone the sidebar is the home screen, so search lives here: results
    /// replace the list and push threads. iPad and Mac search from the toolbar.
    private var searchesHere: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    /// The sync status goes over whichever column you're looking at: this one on
    /// iPhone and the Mac, the list on iPad, which is always showing.
    private var showsSyncStatus: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        true
        #endif
    }

    var body: some View {
        Group {
            if searchesHere, !searchText.isEmpty {
                SearchResultsView(text: searchText, selection: .constant([]), pushesThreads: true)
            } else {
                mailboxList
            }
        }
        .modifier(HomeSearch(enabled: searchesHere, text: $searchText))
        .navigationDestination(for: ThreadRoute.self) { route in
            PushedThreadView(threadId: route.id)
        }
    }

    private var mailboxList: some View {
        List(selection: $selection) {
            Section {
                #if os(iOS)
                // An inset list clips its first and last rows to the section's rounded
                // corners; empty rows take those corners so every tile keeps its shape.
                cornerSpacer
                #endif
                tiles
                    .listRowInsets(tileInsets)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                #if os(iOS)
                cornerSpacer
                #endif
            }
            #if os(iOS)
            // Edge to edge, with the margin inside the row, so a tile that grows
            // or tilts isn't cut off at the row's edge.
            .listSectionMargins(.horizontal, 0)
            #endif

            // System piles: no unread counts, by design. No header: the gap
            // under the tiles sets them apart.
            Section {
                Label("Everything", systemImage: "square.stack.3d.up").tag(SidebarItem.everything)
                ForEach(systemMailboxes, id: \.id) { item in
                    Label(item.name, systemImage: item.icon)
                        .tag(SidebarItem.mailbox(item.id))
                        .modifier(FolderDrop(target: item.id, undo: undoManager, enabled: item.acceptsDrops))
                }
                Label("Senders", systemImage: "person.2").tag(SidebarItem.senders)
            }
        }
        // The list holds still while a label is being dragged.
        .scrollDisabled(dragging != nil)
        #if os(iOS)
        .environment(\.defaultMinListRowHeight, 0)
        // No title or first header, so no room kept for them: the Inbox sits
        // right under the bar.
        .contentMargins(.top, 8, for: .scrollContent)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            SyncStatus(isChecking: model.isCatchingUp && showsSyncStatus,
                       updatedAt: showsSyncStatus ? model.syncedAt : nil)
            if isArranging {
                #if os(iOS)
                ToolbarItem(placement: .topBarTrailing) { doneButton }
                #else
                ToolbarItem(placement: .primaryAction) { doneButton }
                #endif
            }
            // Only there when someone is waiting (or you're looking at it), up
            // here so the mailboxes below never shift.
            if screenerCount > 0 || selection == .screener {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) { screenerButton }
                #else
                ToolbarItem(placement: .primaryAction) { screenerButton }
                #endif
            }
            ToolbarItem(placement: .primaryAction) {
                Button("New Message", systemImage: "square.and.pencil") { compose() }
                    .help("New Message (⌘N)")
            }
            #if os(iOS)
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    showSettings = true
                } label: {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            #endif
        }
        .sensoryFeedback(trigger: isArranging) { _, arranging in arranging ? .impact : nil }
        .sheet(item: $pickingIcon) { label in
            LabelIconPicker(mailboxId: label.value)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #else
                .frame(minWidth: 340, minHeight: 420)
                #endif
        }
        .alert("New Label", isPresented: $isNamingLabel) {
            TextField("Name", text: $newLabelName)
            Button("Cancel", role: .cancel) { newLabelName = "" }
            Button("Create") { createLabel() }
        }
        .refreshable { await model.refresh() }
        .task(id: model.special?.screener) {
            guard let store = model.store, let screener = model.special?.screener else { return }
            do {
                for try await entries in store.observe(.screener(screener)) {
                    withAnimation(.snappy) { screenerCount = entries.count }
                }
            } catch {}
        }
    }

    private var screenerButton: some View {
        Button {
            selection = .screener
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                if screenerCount > 0 {
                    Text(screenerCount, format: .number).monospacedDigit()
                }
            }
        }
        .accessibilityLabel(screenerCount == 1 ? "Screener, 1 sender waiting" : "Screener, \(screenerCount) senders waiting")
        .help("Screener (⌘1)")
    }

    #if os(iOS)
    private var cornerSpacer: some View {
        Color.clear
            .frame(height: 0)
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .selectionDisabled()
            .accessibilityHidden(true)
    }
    #endif

    private var doneButton: some View {
        Button("Done") { finishArranging() }
            .fontWeight(.semibold)
    }

    /// The Inbox across the top, then your labels two by two.
    private var tiles: some View {
        VStack(spacing: 10) {
            if let inbox = model.special.flatMap({ model.mailbox($0.inbox) }) {
                MailboxTile(name: "Inbox", icon: "tray", unread: inbox.unreadEmails,
                            isSelected: selection == .mailbox(inbox.id), isWide: true)
                    .onTapGesture { selection = .mailbox(inbox.id) }
                    .modifier(FolderDrop(target: inbox.id, undo: undoManager))
            }
            // Names beside the icons if every one fits there, otherwise all under
            // them, so the tiles stay alike.
            ViewThatFits(in: .horizontal) {
                labelGrid(namesBeside: true)
                labelGrid(namesBeside: false)
            }
        }
        // Pinned to the top of the row: when the New Label tile adds a line, the
        // row grows downward and the Inbox stays where it is.
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func labelGrid(namesBeside: Bool) -> some View {
        TileGrid(spacing: 10) {
            ForEach(Array(arranged.enumerated()), id: \.element.id) { index, label in
                labelTile(label, index: index, nameBeside: namesBeside)
            }
            if isArranging {
                NewLabelTile(nameBeside: namesBeside) { isNamingLabel = true }
                    // Squeezes to fit rather than moving every name under its icon.
                    .frame(idealWidth: 0, maxWidth: .infinity)
            }
        }
        .overlay(alignment: .topLeading) { liftedTile(nameBeside: namesBeside) }
        .coordinateSpace(.named(Self.grid))
    }

    /// One view in both modes, so starting or finishing arranging changes how
    /// the tile behaves without swapping it for a new one (which would flash).
    private func labelTile(_ label: MailboxRecord, index: Int, nameBeside: Bool) -> some View {
        let isDragged = dragging == label.id
        return MailboxTile(name: label.name, icon: model.icon(for: label.id), unread: label.unreadEmails,
                           isSelected: !isArranging && selection == .mailbox(label.id), nameBeside: nameBeside,
                           isArranging: isArranging)
            .modifier(Wiggle(index: index, isOn: isArranging && !isDragged))
            .scaleEffect(pressing == label.id ? 1.06 : 1)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.grid)) } action: { tileFrames[label.id] = $0 }
            // While dragged, its place stays empty; the lifted copy follows your finger.
            .opacity(isDragged ? 0 : 1)
            // Opens the label, or while arranging, changes its icon.
            .onTapGesture {
                if isArranging {
                    pickingIcon = IdentifiedString(value: label.id)
                } else {
                    selection = .mailbox(label.id)
                }
            }
            .gesture(reorderGesture(label.id), including: isArranging ? .all : .subviews)
            #if os(iOS)
            // Touch and hold to rearrange, as on the Home Screen: the tile swells
            // while you hold, then settles as the labels start to wiggle.
            .gesture(arrangeGesture(label.id), including: isArranging ? .subviews : .all)
            .accessibilityAction(named: "Rearrange Labels") { startArranging() }
            #else
            .modifier(LabelIconEditing(mailboxId: label.id) { startArranging() })
            #endif
            .accessibilityHint(isArranging ? "Changes the icon" : "")
            .modifier(FolderDrop(target: label.id, undo: undoManager))
    }

    #if os(iOS)
    private func arrangeGesture(_ id: String) -> some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .updating($pressing) { isPressing, pressing, transaction in
                guard isPressing else { return }
                transaction.animation = .easeOut(duration: 0.4)
                pressing = id
            }
            // A moment later: the press's spring back would otherwise animate the list
            // making room for the New Label tile (see startArranging).
            .onEnded { _ in Task { @MainActor in startArranging() } }
    }
    #endif

    private nonisolated static let grid = "labelGrid"

    #if os(iOS)
    /// Hold briefly, then drag; a quick swipe still scrolls.
    private func reorderGesture(_ id: String) -> some Gesture {
        LongPressGesture(minimumDuration: 0.15)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.grid)))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                // Lift as soon as the hold is recognised, so the list stops scrolling before you move.
                if dragging != id { lift(id) }
                if let drag { dragged(id, drag) }
            }
            .onEnded { _ in dropped() }
    }
    #else
    private func reorderGesture(_ id: String) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.grid))
            .onChanged { drag in
                if dragging != id { lift(id) }
                dragged(id, drag)
            }
            .onEnded { _ in dropped() }
    }
    #endif

    private func lift(_ id: String) {
        grabOffset = nil
        withAnimation(.snappy) { dragging = id }
    }

    /// Keeps the tile under your finger and slides it into the place of
    /// whichever tile it's over, as on the Home Screen.
    private func dragged(_ id: String, _ drag: DragGesture.Value) {
        if grabOffset == nil {
            let origin = tileFrames[id]?.origin ?? .zero
            grabOffset = CGSize(width: drag.startLocation.x - origin.x, height: drag.startLocation.y - origin.y)
        }
        dragLocation = drag.location
        guard let target = tileFrames.first(where: { $0.key != id && $0.value.contains(drag.location) })?.key,
              let from = order.firstIndex(of: id), let to = order.firstIndex(of: target) else { return }
        withAnimation(.snappy) { order.move(fromOffsets: [from], toOffset: to > from ? to + 1 : to) }
    }

    /// Settles the lifted tile into its new place, then puts the real one back.
    private func dropped() {
        guard let id = dragging, let frame = tileFrames[id], let grabOffset else {
            dragging = nil
            return
        }
        withAnimation(.snappy) {
            dragLocation = CGPoint(x: frame.minX + grabOffset.width, y: frame.minY + grabOffset.height)
        } completion: {
            dragging = nil
        }
    }

    /// The tile you're dragging, drawn above the others so it never slides under one.
    @ViewBuilder private func liftedTile(nameBeside: Bool) -> some View {
        if let id = dragging, let frame = tileFrames[id], let label = folders.first(where: { $0.id == id }) {
            let origin = grabOffset.map { CGPoint(x: dragLocation.x - $0.width, y: dragLocation.y - $0.height) } ?? frame.origin
            MailboxTile(name: label.name, icon: model.icon(for: id), unread: label.unreadEmails,
                        isSelected: false, nameBeside: nameBeside, isArranging: true)
                .frame(width: frame.width, height: frame.height)
                .scaleEffect(1.08)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                .offset(x: origin.x, y: origin.y)
                .allowsHitTesting(false)
        }
    }

    /// Your labels in the order shown: as you're arranging them, or as saved.
    private var arranged: [MailboxRecord] {
        guard isArranging else { return folders }
        let byId = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return order.compactMap { byId[$0] } + folders.filter { !order.contains($0.id) }
    }

    private func startArranging() {
        order = folders.map(\.id)
        // Not animated: when the New Label tile needs a line of its own, the list
        // would animate its row growing and drag the Inbox down and back up. The
        // New Label tile animates its own arrival instead.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { isArranging = true }
    }

    private func finishArranging() {
        let ids = arranged.map(\.id)
        dragging = nil
        withAnimation(.snappy) { isArranging = false }
        if ids != folders.map(\.id) { Task { await model.reorderFolders(ids) } }
    }

    private func createLabel() {
        let name = newLabelName.trimmingCharacters(in: .whitespaces)
        newLabelName = ""
        guard !name.isEmpty else { return }
        Task {
            if let id = await model.createLabel(named: name) { order.append(id) }
        }
    }

    private var tileInsets: EdgeInsets {
        #if os(iOS)
        EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16)
        #else
        EdgeInsets(top: 4, leading: 8, bottom: 8, trailing: 8)
        #endif
    }

    /// Your own folders, in your order (Inbox has its own row above).
    private var folders: [MailboxRecord] {
        model.labels.filter { $0.id != model.special?.inbox }
    }

    private var systemMailboxes: [(id: String, name: String, icon: String, acceptsDrops: Bool)] {
        guard let special = model.special else { return [] }
        let items: [(String?, String, String, Bool)] = [
            (special.screenedOut, "Screened Out", "hand.raised", false),
            (special.sent, "Sent", "paperplane", false),
            (special.drafts, "Drafts", "doc", false),
            (special.archive, "Archive", "archivebox", true),
            (special.junk, "Spam", "xmark.bin", true),
            (special.trash, "Trash", "trash", true),
        ]
        return items.compactMap { id, name, icon, drops in id.map { ($0, name, icon, drops) } }
    }
}

/// A big block for a folder: its icon, unread count and name. Callers add
/// what tapping and holding it do.
private struct MailboxTile: View {
    let name: String
    let icon: String
    let unread: Int
    let isSelected: Bool
    var isWide = false
    /// The name to the right of the icon rather than under it.
    var nameBeside = false
    /// Wiggling: a pencil on the icon, since tapping changes it.
    var isArranging = false
    @ScaledMetric(relativeTo: .body) private var badge: CGFloat = 30

    var body: some View {
        Group {
            if isWide {
                HStack(spacing: 12) {
                    symbol(size: badge * 1.25)
                    title.font(.title3.weight(.bold))
                }
                .padding(.vertical, 6)
            } else if nameBeside {
                HStack(spacing: 8) {
                    labelSymbol
                    title.font(.headline)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    labelSymbol
                    title.font(.headline)
                }
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // On the corner, as on an app icon, so the name has the tile to itself.
        .overlay(alignment: .topTrailing) { countBadge }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unread > 0 ? "\(name), \(unread) unread" : name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var title: some View {
        Text(name).lineLimit(1).minimumScaleFactor(0.6)
    }

    /// In the app's color; white on a selected tile, which is already that color.
    @ViewBuilder private var countBadge: some View {
        if unread > 0 {
            Text(unread, format: .number)
                .monospacedDigit()
                .lineLimit(1)
                .font(.caption.weight(.bold))
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
                .padding(.horizontal, 6)
                .frame(minWidth: 20, minHeight: 20)
                .background(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint), in: Capsule())
                .offset(x: 6, y: -6)
        }
    }

    private var labelSymbol: some View {
        symbol(size: badge)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "pencil")
                    .font(.system(size: badge * 0.3, weight: .bold))
                    .foregroundStyle(.tint)
                    .frame(width: badge * 0.5, height: badge * 0.5)
                    .background(.white, in: Circle())
                    .offset(x: 4, y: 4)
                    .opacity(isArranging ? 1 : 0)
            }
    }

    private func symbol(size: CGFloat) -> some View {
        Image(systemName: icon)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.white))
            .frame(width: size, height: size)
            .background(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.tint), in: Circle())
    }

    private var fill: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.tint) }
        #if os(iOS)
        return AnyShapeStyle(Color.readerPanel)
        #else
        return AnyShapeStyle(.quaternary)
        #endif
    }
}

/// The empty spot at the end while arranging, for adding a label.
private struct NewLabelTile: View {
    /// Laid out like the labels around it.
    var nameBeside = false
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var badge: CGFloat = 30
    @State private var isShown = false

    var body: some View {
        Button(action: action) {
            Group {
                if nameBeside {
                    HStack(spacing: 10) { plus; title }
                } else {
                    VStack(alignment: .leading, spacing: 8) { plus; title }
                }
            }
            .foregroundStyle(.tint)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.secondary, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isShown ? 1 : 0.6)
        .opacity(isShown ? 1 : 0)
        .onAppear { withAnimation(.snappy) { isShown = true } }
    }

    private var plus: some View {
        Image(systemName: "plus")
            .font(.system(size: badge * 0.5, weight: .semibold))
            .frame(width: badge, height: badge)
            .background(Circle().strokeBorder(.tint, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
    }

    private var title: some View {
        Text("New Label").font(.headline).lineLimit(1).minimumScaleFactor(0.6)
    }
}

/// Two columns of tiles, each row as tall as its taller tile. Asked how wide it
/// would like to be, it says twice its widest tile, so ViewThatFits can tell
/// whether every name fits beside its icon.
private struct TileGrid: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
            ?? 2 * (subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0) + spacing
        let heights = rowHeights(subviews, column: column(in: width))
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = column(in: bounds.width)
        var y = bounds.minY
        for (row, height) in rowHeights(subviews, column: column).enumerated() {
            for index in row * 2 ..< min(row * 2 + 2, subviews.count) {
                let x = bounds.minX + CGFloat(index % 2) * (column + spacing)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(width: column, height: height))
            }
            y += height + spacing
        }
    }

    private func column(in width: CGFloat) -> CGFloat { max((width - spacing) / 2, 0) }

    private func rowHeights(_ subviews: Subviews, column: CGFloat) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: 2).map { start in
            subviews[start ..< min(start + 2, subviews.count)]
                .map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }
                .max() ?? 0
        }
    }
}

/// The Home Screen's wiggle, out of step from tile to tile. Still with
/// Reduce Motion on.
private struct Wiggle: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    var isOn = true

    func body(content: Content) -> some View {
        // Always the same view, so switching the wiggle on and off never rebuilds the tile.
        let angle = index.isMultiple(of: 2) ? 0.9 : -0.9
        let quarter = index.isMultiple(of: 3) ? 0.12 : 0.14
        content.keyframeAnimator(initialValue: 0.0, repeating: isOn && !reduceMotion) { view, degrees in
            view.rotationEffect(.degrees(degrees))
        } keyframes: { _ in
            KeyframeTrack {
                CubicKeyframe(angle, duration: quarter)
                CubicKeyframe(-angle, duration: quarter * 2)
                CubicKeyframe(0, duration: quarter)
            }
        }
    }
}

/// Lets conversations be dragged onto a folder to move them there.
private struct FolderDrop: ViewModifier {
    @Environment(AppModel.self) private var model
    let target: String
    let undo: UndoManager?
    var enabled = true

    func body(content: Content) -> some View {
        if enabled {
            content.dropDestination(for: ConversationDrag.self) { drags, _ in
                guard !drags.isEmpty else { return false }
                Task {
                    for drag in drags {
                        await model.move(threads: drag.threadIds, from: drag.sourceMailbox, to: target, undo: undo)
                    }
                }
                return true
            }
        } else {
            content
        }
    }
}

/// A thread opened from home-screen search; Archive pops back to the results.
private struct PushedThreadView: View {
    @Environment(\.dismiss) private var dismiss
    let threadId: String

    var body: some View {
        ThreadView(threadId: threadId, onClose: { dismiss() })
    }
}

/// Adds the home-screen search field only where the sidebar is the home screen.
private struct HomeSearch: ViewModifier {
    let enabled: Bool
    @Binding var text: String

    func body(content: Content) -> some View {
        if enabled {
            content
                .searchable(text: $text, prompt: "Search all mail")
                .searchSuggestions { SearchSuggestions(text: $text) }
                .plainSearchInput()
        } else {
            content
        }
    }
}
