import AppKit
import SwiftUI

struct ClipboardHistoryView: View {
    @EnvironmentObject private var store: ClipboardHistoryStore
    @EnvironmentObject private var settings: AppSettings

    /// Raw text from the search field (updates every keystroke).
    @State private var query = ""
    /// Debounced query used for filtering — avoids rebuilding the list on the
    /// same turn as the first keystroke (that path was crashing).
    @State private var filterQuery = ""
    @State private var selectedID: UUID?
    @State private var searchFocusToken = 0
    @State private var searchSyncToken = 0
    /// Bumped only for keyboard ↑↓ so click-select doesn't jump the scroll view.
    @State private var keyboardScrollToken = 0
    @State private var filterWorkItem: DispatchWorkItem?
    @State private var isPinned = false
    @State private var copyToast: String?
    @State private var copyToastGeneration = 0

    private var filtered: [ClipboardHistoryItem] {
        store.items.filter { store.matches($0, query: filterQuery) }
    }

    private var selected: ClipboardHistoryItem? {
        if let selectedID, let item = filtered.first(where: { $0.id == selectedID }) {
            return item
        }
        return filtered.first
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            ClipboardHistoryResultsPane(
                items: filtered,
                selectedID: $selectedID,
                keyboardScrollToken: keyboardScrollToken,
                store: store,
                onActivate: activateSelected
            )
            Divider()
            footer
        }
        .padding(2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipboardPanelChrome()
        .onAppear {
            selectedID = store.items.first?.id
            isPinned = ClipboardHistoryPanelController.shared.isPinned
            requestSearchFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardHistoryPanelDidShow)) { _ in
            filterWorkItem?.cancel()
            query = ""
            filterQuery = ""
            selectedID = store.items.first?.id
            searchSyncToken &+= 1
            isPinned = ClipboardHistoryPanelController.shared.isPinned
            requestSearchFocus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardHistoryPinDidChange)) { _ in
            isPinned = ClipboardHistoryPanelController.shared.isPinned
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardHistoryActivateRequested)) { _ in
            activateSelected()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardHistoryMoveSelection)) { note in
            let delta = (note.userInfo?["delta"] as? Int) ?? 0
            moveSelection(by: delta)
        }
        .onChange(of: query) { _, newValue in
            scheduleFilterUpdate(newValue)
        }
        .onChange(of: store.items.count) { _, _ in
            reconcileSelection()
        }
        .onExitCommand {
            ClipboardHistoryPanelController.shared.dismiss()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clipboardHistoryDidCopy)) { _ in
            showCopyToast("已复制")
        }
        .overlay(alignment: .bottom) {
            if let copyToast {
                Text(copyToast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.78))
                    )
                    .padding(.bottom, 44)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
    }

    private func showCopyToast(_ message: String) {
        copyToastGeneration += 1
        let generation = copyToastGeneration
        withAnimation(.easeOut(duration: 0.15)) {
            copyToast = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            guard copyToastGeneration == generation else { return }
            withAnimation(.easeIn(duration: 0.18)) {
                copyToast = nil
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
            ClipboardHistorySearchField(
                text: $query,
                placeholder: "搜索剪贴历史…",
                onSubmit: activateSelected,
                focusToken: searchFocusToken,
                syncToken: searchSyncToken
            )
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
            ClipboardPinButton(isPinned: isPinned) {
                ClipboardHistoryPanelController.shared.togglePinned()
                isPinned = ClipboardHistoryPanelController.shared.isPinned
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer(minLength: 0)
            Text("↵ \(settings.clipboardSelectionAction.title) · ↑↓ 选择 · Esc 关闭 · 双击执行")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                SettingsOpener.open(.clipboard)
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("剪贴板历史设置")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func requestSearchFocus() {
        DispatchQueue.main.async {
            searchFocusToken &+= 1
        }
    }

    private func scheduleFilterUpdate(_ newValue: String) {
        filterWorkItem?.cancel()
        // First character used to crash when list/detail rebuilt in the same
        // turn as the field-editor callback. Debounce so typing settles first.
        let work = DispatchWorkItem {
            filterQuery = newValue
            reconcileSelection()
        }
        filterWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func reconcileSelection() {
        let items = filtered
        if let selectedID, items.contains(where: { $0.id == selectedID }) {
            return
        }
        selectedID = items.first?.id
    }

    private func moveSelection(by delta: Int) {
        // Apply pending filter immediately so ↑↓ matches what the user typed.
        filterWorkItem?.cancel()
        if filterQuery != query {
            filterQuery = query
        }
        let items = store.items.filter { store.matches($0, query: filterQuery) }
        guard !items.isEmpty else { return }
        let currentIndex: Int = {
            if let selectedID, let idx = items.firstIndex(where: { $0.id == selectedID }) {
                return idx
            }
            return 0
        }()
        let next = min(max(currentIndex + delta, 0), items.count - 1)
        selectedID = items[next].id
        keyboardScrollToken &+= 1
    }

    private func activateSelected() {
        filterWorkItem?.cancel()
        if filterQuery != query {
            filterQuery = query
            reconcileSelection()
        }
        guard let item = selected else { return }
        ClipboardHistoryPanelController.shared.selectItem(item)
    }
}

// MARK: - Results (isolated from search-field updates)

private struct ClipboardHistoryResultsPane: View {
    let items: [ClipboardHistoryItem]
    @Binding var selectedID: UUID?
    let keyboardScrollToken: Int
    let store: ClipboardHistoryStore
    let onActivate: () -> Void

    private var selected: ClipboardHistoryItem? {
        if let selectedID, let item = items.first(where: { $0.id == selectedID }) {
            return item
        }
        return items.first
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: 240)
            Divider()
            detailColumn
        }
        .frame(maxHeight: .infinity)
    }

    private var listColumn: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if items.isEmpty {
                        Text(store.items.isEmpty ? "还没有记录" : "无匹配结果")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    } else {
                        ForEach(items) { item in
                            ClipboardHistoryListRow(
                                item: item,
                                isSelected: item.id == selected?.id,
                                leadingIcon: { listLeadingIcon(for: item) },
                                onSelect: { selectedID = item.id },
                                onActivate: {
                                    selectedID = item.id
                                    onActivate()
                                },
                                onDelete: { deleteItem(item) }
                            )
                            .id(item.id)
                        }
                    }
                }
                .padding(6)
            }
            .onChange(of: keyboardScrollToken) { _, _ in
                guard let id = selectedID else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private var detailColumn: some View {
        Group {
            if let item = selected {
                VStack(alignment: .leading, spacing: 12) {
                    preview(for: item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    metadata(for: item)
                }
                .padding(14)
                // Stable identity so switching selection doesn't tear down the
                // whole detail tree in the middle of search-field editing.
                .id(item.id)
            } else {
                Text("选择左侧一条记录")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func deleteItem(_ item: ClipboardHistoryItem) {
        let removingSelected = selectedID == item.id
        store.deleteItem(id: item.id)
        if removingSelected {
            selectedID = store.items.first?.id
        }
    }

    @ViewBuilder
    private func listLeadingIcon(for item: ClipboardHistoryItem) -> some View {
        if ClipboardHistoryStore.isImageFileItem(item),
           let thumb = store.listThumbnail(for: item) {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        } else if item.kind == .file {
            ClipboardQuickLookThumbnailView(
                url: store.resolvedFileURL(for: item),
                pointSize: 22,
                contentMode: .fill,
                cornerRadius: 4,
                placeholderSystemImage: item.kind.systemImage
            )
        } else {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
        }
    }

    @ViewBuilder
    private func preview(for item: ClipboardHistoryItem) -> some View {
        switch item.kind {
        case .text:
            ScrollView {
                Text(item.text ?? "")
                    .font(.system(size: 15))
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        case .image:
            imageDetail(item: item, showPathIfAvailable: true)
        case .file:
            if ClipboardHistoryStore.isImageFileItem(item) {
                imageDetail(item: item, showPathIfAvailable: true)
            } else {
                fileDetail(item: item)
            }
        }
    }

    private func fileDetail(item: ClipboardHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let path = item.filePath, !path.isEmpty {
                Text(path)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            // Non-image files: system Quick Look thumbnail (not custom decode).
            ClipboardQuickLookThumbnailView(
                url: store.resolvedFileURL(for: item),
                pointSize: 220,
                contentMode: .fit,
                cornerRadius: 10,
                placeholderSystemImage: "doc"
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func imageDetail(item: ClipboardHistoryItem, showPathIfAvailable: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if showPathIfAvailable, let path = item.filePath, !path.isEmpty {
                Text(path)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
            Group {
                if let image = store.nsImage(for: item) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text("无法预览图片")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Stay clear so panel glass shows through — no white/mosaic fill.
            .background(Color.clear)
        }
    }

    private func metadata(for item: ClipboardHistoryItem) -> some View {
        let time = Self.friendlyTime(item.createdAt)
        let source = item.sourceAppName ?? "未知"
        let sizeText = ClipboardHistoryStore.formatByteSize(item.byteSize)
        let showImageMeta = item.kind == .image || ClipboardHistoryStore.isImageFileItem(item)
        // Image files (incl. Finder copies) show as 图片, not 文件.
        let typeLabel = ClipboardHistoryStore.isImageFileItem(item)
            ? ClipboardItemKind.image.title
            : item.kind.title

        return VStack(spacing: 6) {
            HStack(spacing: 16) {
                metaRow(label: "时间", value: time)
                metaRow(label: "来源", value: source)
            }
            HStack(spacing: 16) {
                metaRow(label: "类型", value: typeLabel)
                if item.kind == .text {
                    metaRow(label: "长度", value: "\(item.characterCount ?? item.text?.count ?? 0) 字")
                } else if item.kind == .file && !showImageMeta {
                    metaRow(label: "大小", value: sizeText ?? "—")
                } else if showImageMeta {
                    if let w = item.imagePixelWidth, let h = item.imagePixelHeight {
                        metaRow(label: "尺寸", value: "\(w)×\(h)")
                    } else {
                        metaRow(label: "大小", value: sizeText ?? "—")
                    }
                }
            }
        }
        .padding(.top, 8)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private func metaRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Relative / short local time for metadata (e.g. 刚刚、3 分钟前、今天 21:43).
    private static func friendlyTime(_ date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60)) 分钟前" }
        if interval < 6 * 3600 { return "\(Int(interval / 3600)) 小时前" }

        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "'今天' HH:mm"
        } else if calendar.isDateInYesterday(date) {
            formatter.dateFormat = "'昨天' HH:mm"
        } else if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            formatter.dateFormat = "M月d日 HH:mm"
        } else {
            formatter.dateFormat = "yyyy年M月d日 HH:mm"
        }
        return formatter.string(from: date)
    }
}

private struct ClipboardHistoryListRow<LeadingIcon: View>: View {
    let item: ClipboardHistoryItem
    let isSelected: Bool
    @ViewBuilder let leadingIcon: () -> LeadingIcon
    let onSelect: () -> Void
    let onActivate: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

    var body: some View {
        // Whole row is the hit target (incl. padding / empty space). Delete sits on top.
        // Don't use TapGesture(count: 2) — it delays every single click while waiting
        // to see if a second tap arrives. Use AppKit clickCount instead.
        Button {
            if NSApp.currentEvent?.clickCount ?? 1 > 1 {
                onActivate()
            } else {
                onSelect()
            }
        } label: {
            HStack(spacing: 5) {
                leadingIcon()
                Text(item.summary)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 6)
            // × stays at trailing 10; text↔× gap (lower = closer).
            .padding(.trailing, 16)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowBackground)
            )
        }
        .buttonStyle(.plain)
        .overlay(alignment: .trailing) {
            DeleteRowButton(action: onDelete)
                .padding(.trailing, 4)
        }
        .onHover { isHovered = $0 }
    }

    private var rowBackground: Color {
        if isSelected { return Color.primary.opacity(0.12) }
        if isHovered { return Color.primary.opacity(0.06) }
        return .clear
    }
}

private struct ClipboardPinButton: View {
    let isPinned: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isPinned ? Color.accentColor : Color.secondary.opacity(isHovered ? 0.95 : 0.7))
                .rotationEffect(.degrees(45))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.10 : 0))
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isPinned ? "取消固定" : "固定面板")
        .background(ArrowCursorNSView())
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.arrow.set()
            }
        }
    }
}

/// Keeps the arrow cursor over controls sitting next to an NSTextField (I-beam).
private struct ArrowCursorNSView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        ArrowCursorView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private final class ArrowCursorView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.invalidateCursorRects(for: self)
    }
}

private struct DeleteRowButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary.opacity(isHovered ? 0.85 : 0.45))
                .frame(width: 16, height: 16)
                .background(
                    Circle()
                        .fill(Color.primary.opacity(isHovered ? 0.10 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("删除这条记录")
        .onHover { isHovered = $0 }
    }
}

enum ClipboardPanelChrome {
    static let cornerRadius: CGFloat = 14

    /// Same family as the launcher panel fill, but opaque (no material / glass).
    static var fillNSColor: NSColor { .windowBackgroundColor }
}

private extension View {
    /// Match launcher panel colors/shape, solid — no ultraThinMaterial / glass.
    func clipboardPanelChrome() -> some View {
        let shape = RoundedRectangle(cornerRadius: ClipboardPanelChrome.cornerRadius, style: .continuous)
        return self
            .background(Color(nsColor: ClipboardPanelChrome.fillNSColor), in: shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .clipShape(shape)
    }
}
