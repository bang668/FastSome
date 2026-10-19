import AppKit
import SwiftUI

struct PanelView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: PanelCoordinateSpaces.root)
        .panelChrome()
    }

    @ViewBuilder
    private var content: some View {
        switch settings.layout {
        case .sidebar:
            HStack(alignment: .top, spacing: 10) {
                sidebar
                VStack(alignment: .leading, spacing: 10) {
                    Text(store.selectedGroup?.name ?? "")
                        .font(.headline)
                    itemArea
                }
            }
        case .tabsGrid, .list:
            VStack(spacing: 10) {
                topBar
                itemArea
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            GroupTabsStrip(axis: .horizontal)
            Spacer(minLength: 4)
            trailingControls
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            GroupTabsStrip(axis: .vertical)
            Spacer()
            trailingControls
        }
        .frame(width: appState.isEditing ? 108 : 88)
    }

    private var trailingControls: some View {
        HStack(spacing: 4) {
            Button {
                appState.isEditing.toggle()
            } label: {
                Text(appState.isEditing ? "完成" : "编辑")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)

            Button {
                SettingsOpener.open(.panel)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .help("快捷面板设置")
        }
        .foregroundStyle(.secondary)
    }

    private var itemArea: some View {
        ItemAreaView()
    }
}

/// Owns group-tab drag @State so continuous drag updates do not redraw the shortcut icon grid.
private struct GroupTabsStrip: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var store: LibraryStore

    let axis: Axis

    @State private var dropTargetGroupID: UUID?
    @State private var lastGroupClick: (id: UUID, time: Date)?
    @State private var draggingGroupID: UUID?
    @State private var groupHoverInsertIndex: Int?
    @State private var draggingGroupSize: CGSize = CGSize(width: 72, height: 28)
    @State private var groupTabFrames: [UUID: CGRect] = [:]
    @State private var groupDragHitFrames: [UUID: CGRect] = [:]
    @State private var groupDragTranslation: CGSize = .zero
    @State private var groupDragStartFrame: CGRect = .zero
    @State private var groupDragSettling = false

    private let groupTabSpacing: CGFloat = 4
    private let groupStripSpace = "groupStrip"

    var body: some View {
        let groups = store.library.groups
        Group {
            if axis == .vertical {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: groupTabSpacing) {
                        tabsRow(groups: groups)
                        if appState.isEditing {
                            Button("+ 分组") { store.addGroup(named: "新分组") }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                        }
                    }
                    dragPreview
                }
                .coordinateSpace(name: groupStripSpace)
                .onPreferenceChange(GroupTabFrameKey.self) { groupTabFrames = $0 }
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        HStack(spacing: groupTabSpacing) {
                            tabsRow(groups: groups)
                            if appState.isEditing {
                                Button("+ 分组") { store.addGroup(named: "新分组") }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        dragPreview
                    }
                    .coordinateSpace(name: groupStripSpace)
                    .onPreferenceChange(GroupTabFrameKey.self) { groupTabFrames = $0 }
                }
            }
        }
        .onChange(of: appState.isEditing) { _, editing in
            if !editing { clearGroupDrag() }
        }
    }

    @ViewBuilder
    private func tabsRow(groups: [ShortcutGroup]) -> some View {
        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
            groupTab(group, storeIndex: index)
        }
    }

    private var squeezeAnimation: Animation {
        .interactiveSpring(response: 0.22, dampingFraction: 0.86, blendDuration: 0.05)
    }

    private func squeezeOffset(for index: Int) -> CGSize {
        guard let dragID = draggingGroupID,
              let from = store.library.groups.firstIndex(where: { $0.id == dragID }),
              let hover = groupHoverInsertIndex,
              index != from
        else { return .zero }

        let extent = (axis == .horizontal ? draggingGroupSize.width : draggingGroupSize.height) + groupTabSpacing
        var delta: CGFloat = 0
        if from < hover {
            if index > from && index < hover { delta = -extent }
        } else if hover < from {
            if index >= hover && index < from { delta = extent }
        }
        return axis == .horizontal ? CGSize(width: delta, height: 0) : CGSize(width: 0, height: delta)
    }

    @ViewBuilder
    private var dragPreview: some View {
        if let dragID = draggingGroupID,
           let group = store.library.groups.first(where: { $0.id == dragID }),
           let storeIndex = store.library.groups.firstIndex(where: { $0.id == dragID }) {
            tabLabel(group, storeIndex: storeIndex, showDelete: false)
                .frame(width: draggingGroupSize.width, height: draggingGroupSize.height, alignment: .leading)
                .opacity(0.92)
                .shadow(color: .black.opacity(groupDragSettling ? 0.06 : 0.18), radius: groupDragSettling ? 2 : 6, y: 1)
                .offset(
                    x: groupDragStartFrame.minX + groupDragTranslation.width,
                    y: groupDragStartFrame.minY + groupDragTranslation.height
                )
                .allowsHitTesting(false)
                .zIndex(100)
        }
    }

    @ViewBuilder
    private func groupTab(_ group: ShortcutGroup, storeIndex: Int) -> some View {
        let selected = store.library.selectedGroupID == group.id
        let isDragging = draggingGroupID == group.id
        let squeeze = squeezeOffset(for: storeIndex)

        let itemDropHighlight = appState.itemDragHoverGroupID == group.id

        tabLabel(group, storeIndex: storeIndex, showDelete: appState.isEditing && selected && store.library.groups.count > 1)
            .background(
                GeometryReader { geo in
                    let stripFrame = geo.frame(in: .named(groupStripSpace))
                    let panelFrame = geo.frame(in: .named(PanelCoordinateSpaces.root))
                    Color.clear
                        .preference(key: GroupTabFrameKey.self, value: [group.id: stripFrame])
                        .onAppear { GroupTabGeometry.framesInPanel[group.id] = panelFrame }
                        .onChange(of: panelFrame) { _, frame in
                            GroupTabGeometry.framesInPanel[group.id] = frame
                        }
                }
            )
            .opacity(isDragging ? 0.001 : 1)
            .offset(squeeze)
            .animation(squeezeAnimation, value: groupHoverInsertIndex)
            .animation(squeezeAnimation, value: draggingGroupID)
            .onTapGesture { handleGroupClick(group) }
            .gesture(appState.isEditing ? reorderGesture(group: group, storeIndex: storeIndex) : nil)
            .onDrop(of: [.text], isTargeted: Binding(
                get: { dropTargetGroupID == group.id && draggingGroupID == nil },
                set: { dropTargetGroupID = ($0 && draggingGroupID == nil) ? group.id : (dropTargetGroupID == group.id ? nil : dropTargetGroupID) }
            )) { providers in
                acceptItemDropOntoGroup(providers, groupID: group.id)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        ((dropTargetGroupID == group.id && draggingGroupID == nil) || itemDropHighlight)
                            ? Color.accentColor
                            : Color.clear,
                        lineWidth: 2
                    )
            )
    }

    @ViewBuilder
    private func tabLabel(_ group: ShortcutGroup, storeIndex: Int, showDelete: Bool) -> some View {
        let selected = store.library.selectedGroupID == group.id
        HStack(spacing: 2) {
            Text(group.name)
                .lineLimit(1)
                .padding(.leading, 8)
                .padding(.trailing, (appState.isEditing && showDelete) ? 2 : 8)
                .padding(.vertical, 5)
                .frame(maxWidth: axis == .vertical ? .infinity : nil, alignment: .leading)
                .contentShape(Rectangle())

            if showDelete {
                Button {
                    confirmDeleteGroup(group)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.primary.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .help("删除分组")
                .padding(.trailing, 4)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(selected ? Color.primary.opacity(0.12) : Color.clear)
        )
        // Keep the badge inside the tab bounds so ScrollView / panel chrome do not clip it.
        .overlay(alignment: .bottomTrailing) {
            if appState.optionKeyHeld, let hint = groupKeyHint(storeIndex) {
                Text(hint)
                    .font(.system(size: 9, weight: .semibold).monospaced())
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.32), in: RoundedRectangle(cornerRadius: 3))
                    .foregroundStyle(.white)
                    .padding(.trailing, 0)
                    .padding(.bottom, 2)
                    .offset(x: 3, y: 0)
            }
        }
    }

    private func groupKeyHint(_ index: Int) -> String? {
        guard (0..<10).contains(index) else { return nil }
        let n = index == 9 ? 0 : index + 1
        return "⌥\(n)"
    }

    private func reorderGesture(group: ShortcutGroup, storeIndex: Int) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(groupStripSpace))
            .onChanged { value in
                guard !groupDragSettling else { return }
                if draggingGroupID == nil {
                    let frame = groupTabFrames[group.id]
                        ?? CGRect(origin: value.startLocation, size: CGSize(width: 72, height: 28))
                    draggingGroupID = group.id
                    draggingGroupSize = frame.size
                    groupDragStartFrame = frame
                    groupDragHitFrames = groupTabFrames
                    groupHoverInsertIndex = storeIndex
                }
                groupDragTranslation = axisConstrained(value.translation)
                let insert = insertIndex(
                    pointer: axisConstrainedPointer(value.location),
                    draggingID: group.id
                )
                if groupHoverInsertIndex != insert {
                    withAnimation(squeezeAnimation) {
                        groupHoverInsertIndex = insert
                    }
                }
            }
            .onEnded { _ in
                finishGroupDrag()
            }
    }

    private func axisConstrained(_ translation: CGSize) -> CGSize {
        axis == .horizontal
            ? CGSize(width: translation.width, height: 0)
            : CGSize(width: 0, height: translation.height)
    }

    private func axisConstrainedPointer(_ location: CGPoint) -> CGPoint {
        axis == .horizontal
            ? CGPoint(x: location.x, y: groupDragStartFrame.midY)
            : CGPoint(x: groupDragStartFrame.midX, y: location.y)
    }

    private func finishGroupDrag() {
        guard let dragID = draggingGroupID,
              let from = store.library.groups.firstIndex(where: { $0.id == dragID }),
              let insert = groupHoverInsertIndex
        else {
            clearGroupDrag()
            return
        }

        groupDragSettling = true
        let land = landingOrigin(from: from, insert: insert)
        let settle = axisConstrained(
            CGSize(
                width: land.x - groupDragStartFrame.minX,
                height: land.y - groupDragStartFrame.minY
            )
        )

        withAnimation(.easeOut(duration: 0.16)) {
            groupDragTranslation = settle
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 170_000_000)
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                store.reorderGroup(groupID: dragID, toInsertIndex: insert)
                clearGroupDrag()
            }
        }
    }

    private func landingOrigin(from: Int, insert: Int) -> CGPoint {
        let groups = store.library.groups
        let frames = groupDragHitFrames.isEmpty ? groupTabFrames : groupDragHitFrames
        let fallback = groupDragStartFrame.origin

        if insert == from || insert == from + 1 {
            return fallback
        }
        if from < insert {
            let idx = insert - 1
            guard groups.indices.contains(idx), let frame = frames[groups[idx].id] else { return fallback }
            return frame.origin
        }
        guard groups.indices.contains(insert), let frame = frames[groups[insert].id] else { return fallback }
        return frame.origin
    }

    private func insertIndex(pointer: CGPoint, draggingID: UUID) -> Int {
        let groups = store.library.groups
        let frames = groupDragHitFrames.isEmpty ? groupTabFrames : groupDragHitFrames
        let pos = axis == .horizontal ? pointer.x : pointer.y

        for (index, group) in groups.enumerated() {
            guard group.id != draggingID else { continue }
            guard let frame = frames[group.id] else { continue }
            let threshold = axis == .horizontal
                ? frame.minX + frame.width * 0.30
                : frame.minY + frame.height * 0.30
            if pos < threshold {
                return index
            }
        }
        return groups.count
    }

    private func acceptItemDropOntoGroup(_ providers: [NSItemProvider], groupID: UUID) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String,
                  !string.hasPrefix("group:"),
                  let id = UUID(uuidString: string)
            else { return }
            Task { @MainActor in
                store.moveItem(id, toGroup: groupID)
                dropTargetGroupID = nil
            }
        }
        return true
    }

    private func clearGroupDrag() {
        draggingGroupID = nil
        groupHoverInsertIndex = nil
        groupDragHitFrames = [:]
        groupDragTranslation = .zero
        groupDragStartFrame = .zero
        groupDragSettling = false
        dropTargetGroupID = nil
    }

    private func handleGroupClick(_ group: ShortcutGroup) {
        let now = Date()
        if appState.isEditing,
           let last = lastGroupClick,
           last.id == group.id,
           now.timeIntervalSince(last.time) < 0.4 {
            lastGroupClick = nil
            presentRenameDialog(for: group)
            return
        }
        store.selectGroup(group.id)
        lastGroupClick = appState.isEditing ? (group.id, now) : nil
    }

    private func presentRenameDialog(for group: ShortcutGroup) {
        store.selectGroup(group.id)
        PanelController.shared.performModal {
            let confirmed = RenameGroupPrompt.run(currentName: group.name)
            if let name = confirmed {
                store.renameGroup(group.id, to: name)
            }
        }
    }

    private func confirmDeleteGroup(_ group: ShortcutGroup) {
        PanelController.shared.performModal {
            let ok = ConfirmPrompt.run(
                title: "删除分组",
                message: "确定删除「\(group.name)」吗？组内的快捷方式也会一起删除。",
                confirmTitle: "删除"
            )
            if ok {
                store.deleteGroup(group.id)
            }
        }
    }
}

private struct GroupTabFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

extension View {
    /// macOS 26+: Liquid Glass. Older systems: existing ultra-thin material.
    @ViewBuilder
    func panelChrome() -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
        }
    }
}
