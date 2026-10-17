import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Shared panel coordinate space so item drag can hit-test group tabs for cross-group moves.
enum PanelCoordinateSpaces {
    static let root = "panelRoot"
}

/// Screen/panel frames of group tabs — updated by `GroupTabsStrip`, read during item drag.
enum GroupTabGeometry {
    static var framesInPanel: [UUID: CGRect] = [:]
}

/// Shortcut icon grid / list with DragGesture squeeze reorder (mirrors group-tab behavior).
struct ItemAreaView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    @State private var isFinderDropTargeted = false
    @State private var hoveredItemID: UUID?

    @State private var draggingItemID: UUID?
    @State private var hoverInsertIndex: Int?
    @State private var dragTranslation: CGSize = .zero
    @State private var dragStartFrame: CGRect = .zero
    @State private var dragHitFrames: [UUID: CGRect] = [:]
    @State private var itemFrames: [UUID: CGRect] = [:]
    @State private var dragSettling = false
    @State private var hoverGroupID: UUID?
    @State private var dragPreviewSize: CGSize = CGSize(width: 72, height: 88)

    private let gridCellWidth: CGFloat = 78
    private let gridBaseSpacing: CGFloat = 8
    private let gridRowSpacing: CGFloat = 10
    private let itemStripSpace = "itemStrip"
    /// Origin of this strip in `panelRoot`, used to hit-test group tabs while dragging.
    @State private var stripOriginInPanel: CGPoint = .zero

    private var items: [ShortcutItem] {
        store.selectedGroup?.items ?? []
    }

    private var isList: Bool {
        settings.layout == .list
    }

    private var squeezeAnimation: Animation {
        .interactiveSpring(response: 0.22, dampingFraction: 0.86, blendDuration: 0.05)
    }

    /// Live display order while dragging (1D squeeze preview for both grid and list).
    private var displayedItems: [ShortcutItem] {
        guard let dragID = draggingItemID,
              let from = items.firstIndex(where: { $0.id == dragID }),
              let raw = hoverInsertIndex
        else { return items }

        var preview = items
        let moved = preview.remove(at: from)
        var dest = raw
        if from < raw { dest -= 1 }
        dest = min(max(0, dest), preview.count)
        preview.insert(moved, at: dest)
        return preview
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if isList {
                    listBody
                } else {
                    gridBody
                }
            }
            // Animate squeeze only while actively dragging — never on settle/clear (that flash).
            .animation(dragSettling ? nil : squeezeAnimation, value: displayedItems.map(\.id))

            dragPreview
        }
        .coordinateSpace(name: itemStripSpace)
        .onPreferenceChange(ItemFrameKey.self) { itemFrames = $0 }
        .background(
            GeometryReader { geo in
                let origin = geo.frame(in: .named(PanelCoordinateSpaces.root)).origin
                Color.clear
                    .onAppear { stripOriginInPanel = origin }
                    .onChange(of: origin) { _, value in stripOriginInPanel = value }
            }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isFinderDropTargeted ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isFinderDropTargeted ? Color.accentColor : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: finderDropBinding) { providers in
            acceptFinderDrop(providers)
        }
    }

    private var finderDropBinding: Binding<Bool> {
        Binding(
            get: { isFinderDropTargeted },
            set: { isFinderDropTargeted = $0 && appState.isEditing }
        )
    }

    // MARK: - Grid

    private var gridBody: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, gridCellWidth)
            let columns = gridColumnCount(for: width)
            let spacing = gridSpacing(for: width, columns: columns)
            ScrollView {
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(gridCellWidth), spacing: spacing),
                        count: columns
                    ),
                    spacing: gridRowSpacing
                ) {
                    ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                        let storeIndex = items.firstIndex(where: { $0.id == item.id }) ?? index
                        gridCell(item, storeIndex: storeIndex)
                    }
                    if appState.isEditing {
                        addItemCell
                    }
                }
                .frame(width: width, alignment: .leading)
                .padding(.top, 2)
            }
        }
    }

    private func gridColumnCount(for width: CGFloat) -> Int {
        var columns = 1
        while columns < 12 {
            let next = columns + 1
            let needed = CGFloat(next) * gridCellWidth + CGFloat(next - 1) * gridBaseSpacing
            if needed <= width { columns = next } else { break }
        }
        return columns
    }

    private func gridSpacing(for width: CGFloat, columns: Int) -> CGFloat {
        guard columns > 1 else { return gridBaseSpacing }
        let leftover = width - CGFloat(columns) * gridCellWidth
        return max(gridBaseSpacing, leftover / CGFloat(columns - 1))
    }

    @ViewBuilder
    private func gridCell(_ item: ShortcutItem, storeIndex: Int) -> some View {
        let hovered = hoveredItemID == item.id && draggingItemID == nil
        let isDragging = draggingItemID == item.id

        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: store.icon(for: item))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 60, height: 60)
                    .shadow(color: .black.opacity(hovered ? 0.28 : 0.15), radius: hovered ? 6 : 2, y: hovered ? 3 : 1)
                    .scaleEffect(hovered ? 1.06 : 1.0)

                if appState.isEditing {
                    Button {
                        store.removeItem(item.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .font(.system(size: 14))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 6, y: -6)
                }

                if appState.commandKeyHeld, let hint = keyHint(storeIndex) {
                    Text(hint)
                        .font(.system(size: 9, weight: .semibold).monospaced())
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .offset(x: -2, y: 2)
                }
            }
            .frame(width: 64, height: 64)

            Text(item.displayName)
                .font(.system(size: 11))
                .lineLimit(1)
                .foregroundStyle(hovered ? .primary : .secondary)
                .frame(maxWidth: 80)
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hovered ? Color.primary.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        // While settling, reveal the real cell under the fading preview (avoids a pop on clear).
        .opacity(isDragging ? (dragSettling ? 1 : 0.001) : (appState.missingItemIDs.contains(item.id) ? 0.4 : 1))
        .background(itemFrameReader(for: item.id))
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { hovering in
            guard draggingItemID == nil else { return }
            hoveredItemID = hovering ? item.id : (hoveredItemID == item.id ? nil : hoveredItemID)
        }
        .onTapGesture { activate(item) }
        .gesture(reorderGesture(item: item, storeIndex: storeIndex, axisLocked: false))
    }

    private var addItemCell: some View {
        Button {
            pickFiles()
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                        .frame(width: 60, height: 60)
                    Image(systemName: "plus")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 64, height: 64)

                Text("添加")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 80)
            }
            .padding(6)
        }
        .buttonStyle(.plain)
        .help("添加快捷方式")
    }

    // MARK: - List

    private var listBody: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(displayedItems.enumerated()), id: \.element.id) { index, item in
                    let storeIndex = items.firstIndex(where: { $0.id == item.id }) ?? index
                    listRow(item, storeIndex: storeIndex)
                }
                if appState.isEditing {
                    addListRow
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func listRow(_ item: ShortcutItem, storeIndex: Int) -> some View {
        let hovered = hoveredItemID == item.id && draggingItemID == nil
        let isDragging = draggingItemID == item.id

        HStack(spacing: 10) {
            Image(nsImage: store.icon(for: item))
                .resizable()
                .frame(width: 32, height: 32)
            Text(item.displayName)
                .lineLimit(1)
            Spacer()
            if appState.commandKeyHeld, let hint = keyHint(storeIndex) {
                Text(hint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if appState.isEditing {
                Button {
                    store.removeItem(item.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(hovered ? Color.primary.opacity(0.08) : Color.clear)
        )
        .contentShape(Rectangle())
        .opacity(isDragging ? (dragSettling ? 1 : 0.001) : (appState.missingItemIDs.contains(item.id) ? 0.4 : 1))
        .background(itemFrameReader(for: item.id))
        .onHover { hovering in
            guard draggingItemID == nil else { return }
            hoveredItemID = hovering ? item.id : (hoveredItemID == item.id ? nil : hoveredItemID)
        }
        .onTapGesture { activate(item) }
        .gesture(reorderGesture(item: item, storeIndex: storeIndex, axisLocked: true))
    }

    private var addListRow: some View {
        Button {
            pickFiles()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.08)))
                Text("添加快捷方式")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Drag

    @ViewBuilder
    private var dragPreview: some View {
        if let dragID = draggingItemID,
           let item = items.first(where: { $0.id == dragID }) {
            Group {
                if isList {
                    HStack(spacing: 10) {
                        Image(nsImage: store.icon(for: item))
                            .resizable()
                            .frame(width: 32, height: 32)
                        Text(item.displayName)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08)))
                } else {
                    VStack(spacing: 6) {
                        Image(nsImage: store.icon(for: item))
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 60, height: 60)
                            .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        Text(item.displayName)
                            .font(.system(size: 11))
                            .lineLimit(1)
                            .frame(maxWidth: 80)
                    }
                    .padding(6)
                }
            }
            .frame(width: dragPreviewSize.width, height: dragPreviewSize.height, alignment: .leading)
            .opacity(dragSettling ? 0 : 0.92)
            .shadow(color: .black.opacity(dragSettling ? 0 : 0.18), radius: dragSettling ? 0 : 6, y: 1)
            .offset(
                x: dragStartFrame.minX + dragTranslation.width,
                y: dragStartFrame.minY + dragTranslation.height
            )
            .allowsHitTesting(false)
            .zIndex(100)
            .animation(.easeOut(duration: 0.14), value: dragSettling)
        }
    }

    private func itemFrameReader(for id: UUID) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: ItemFrameKey.self,
                value: [id: geo.frame(in: .named(itemStripSpace))]
            )
        }
    }

    private func reorderGesture(item: ShortcutItem, storeIndex: Int, axisLocked: Bool) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(itemStripSpace))
            .onChanged { value in
                guard !dragSettling else { return }
                if draggingItemID == nil {
                    let frame = itemFrames[item.id]
                        ?? CGRect(origin: value.startLocation, size: CGSize(width: 72, height: 72))
                    draggingItemID = item.id
                    dragStartFrame = frame
                    dragPreviewSize = frame.size
                    dragHitFrames = itemFrames
                    hoverInsertIndex = storeIndex
                    hoveredItemID = nil
                }
                dragTranslation = axisLocked
                    ? CGSize(width: 0, height: value.translation.height)
                    : value.translation

                let pointer = axisLocked
                    ? CGPoint(x: dragStartFrame.midX, y: value.location.y)
                    : value.location

                // Over a group tab → prepare cross-group move; otherwise squeeze-reorder.
                let panelPoint = CGPoint(
                    x: pointer.x + stripOriginInPanel.x,
                    y: pointer.y + stripOriginInPanel.y
                )
                if let groupID = groupID(atPanelPoint: panelPoint), groupID != store.library.selectedGroupID {
                    if hoverGroupID != groupID {
                        hoverGroupID = groupID
                        appState.itemDragHoverGroupID = groupID
                    }
                } else {
                    if hoverGroupID != nil {
                        hoverGroupID = nil
                        appState.itemDragHoverGroupID = nil
                    }
                    let insert = insertIndex(at: pointer, draggingID: item.id, listMode: axisLocked)
                    if hoverInsertIndex != insert {
                        withAnimation(squeezeAnimation) {
                            hoverInsertIndex = insert
                        }
                    }
                }
            }
            .onEnded { _ in
                finishDrag(itemID: item.id)
            }
    }

    private func groupID(atPanelPoint point: CGPoint) -> UUID? {
        for (id, frame) in GroupTabGeometry.framesInPanel {
            if frame.insetBy(dx: -4, dy: -4).contains(point) {
                return id
            }
        }
        return nil
    }

    private func insertIndex(at point: CGPoint, draggingID: UUID, listMode: Bool) -> Int {
        let frames = dragHitFrames.isEmpty ? itemFrames : dragHitFrames
        for (index, item) in items.enumerated() {
            guard item.id != draggingID else { continue }
            guard let frame = frames[item.id] else { continue }
            if listMode {
                let threshold = frame.minY + frame.height * 0.30
                if point.y < threshold { return index }
            } else if isBeforeInGrid(point: point, frame: frame) {
                return index
            }
        }
        return items.count
    }

    /// Row-major “before this cell” using an eager leading zone (~30%).
    private func isBeforeInGrid(point: CGPoint, frame: CGRect) -> Bool {
        let rowBand = frame.height * 0.45
        if point.y < frame.midY - rowBand { return true }
        if point.y > frame.midY + rowBand { return false }
        return point.x < frame.minX + frame.width * 0.30
    }

    private func finishDrag(itemID: UUID) {
        let targetGroup = hoverGroupID ?? appState.itemDragHoverGroupID
        let insert = hoverInsertIndex
        let currentGroup = store.library.selectedGroupID

        if let targetGroup, targetGroup != currentGroup {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                clearDragState()
                store.moveItem(itemID, toGroup: targetGroup)
            }
            return
        }

        guard let from = items.firstIndex(where: { $0.id == itemID }),
              let insert
        else {
            clearDragState()
            return
        }

        // Already in the right slot — commit without a settle animation.
        if insert == from || insert == from + 1 {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                clearDragState()
            }
            return
        }

        dragSettling = true

        // Land on the invisible placeholder's *current* frame (post-squeeze), not frozen hit frames.
        let land = itemFrames[itemID] ?? dragStartFrame
        let settle: CGSize = isList
            ? CGSize(width: 0, height: land.minY - dragStartFrame.minY)
            : CGSize(width: land.minX - dragStartFrame.minX, height: land.minY - dragStartFrame.minY)

        withAnimation(.easeOut(duration: 0.14)) {
            dragTranslation = settle
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                // Commit first while ghost still occupies the slot, then drop preview in the same frame.
                store.reorderItem(itemID: itemID, toInsertIndex: insert)
                clearDragState()
            }
        }
    }

    private func clearDragState() {
        draggingItemID = nil
        hoverInsertIndex = nil
        dragTranslation = .zero
        dragStartFrame = .zero
        dragHitFrames = [:]
        dragSettling = false
        hoverGroupID = nil
        appState.itemDragHoverGroupID = nil
    }

    // MARK: - Actions

    private func activate(_ item: ShortcutItem) {
        guard !appState.isEditing else { return }
        if Launcher.open(item, store: store), settings.closePanelAfterLaunch {
            PanelController.shared.hide()
        }
    }

    private func keyHint(_ index: Int) -> String? {
        guard index >= 0, index <= 9 else { return nil }
        let n = index == 9 ? 0 : index + 1
        return "⌘\(n)"
    }

    private func pickFiles() {
        PanelController.shared.performModal {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = true
            panel.treatsFilePackagesAsDirectories = false
            panel.prompt = "添加"
            if panel.runModal() == .OK {
                store.addItems(from: panel.urls)
                appState.refreshMissingFlags()
            }
        }
    }

    private func acceptFinderDrop(_ providers: [NSItemProvider]) -> Bool {
        guard appState.isEditing else { return false }
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
        }
        guard !fileProviders.isEmpty else { return false }

        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let url: URL?
                if let value = item as? URL {
                    url = value
                } else if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let string = item as? String {
                    url = URL(fileURLWithPath: string)
                } else {
                    url = nil
                }
                guard let url else { return }
                lock.lock()
                urls.append(url)
                lock.unlock()
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            store.addItems(from: urls)
            appState.refreshMissingFlags()
            isFinderDropTargeted = false
        }
        return true
    }
}

private struct ItemFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}
