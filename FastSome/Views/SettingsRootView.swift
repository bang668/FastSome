import AppKit
import Carbon
import SwiftUI
import UniformTypeIdentifiers

private enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case panel
    case gestures
    case scroll
    case modifiers
    case clipboard
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "通用"
        case .panel: return "快捷面板"
        case .gestures: return "鼠标手势"
        case .scroll: return "滚动翻转"
        case .modifiers: return "修饰键"
        case .clipboard: return "剪贴板历史"
        case .about: return "关于"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .panel: return "square.grid.2x2"
        case .gestures: return "hand.draw"
        case .scroll: return "arrow.up.arrow.down"
        case .modifiers: return "command"
        case .clipboard: return "doc.on.clipboard"
        case .about: return "info.circle"
        }
    }
}

private enum HotKeyRecordingTarget {
    case panel
    case clipboard
}

struct SettingsRootView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var selectedPane: SettingsPane = .general
    @State private var recordingTarget: HotKeyRecordingTarget?
    @State private var monitor: Any?
    @State private var flagsMonitor: Any?
    @State private var recordingCandidate: HotKeyCombo?
    @State private var recordingDiscard = false
    @State private var tipDetector = DoubleModifierTapDetector()
    @State private var tipLastFlagsRaw: UInt = 0
    @State private var showPanelHotKeyTips = false
    @State private var showClipboardHotKeyTips = false
    @State private var gestureEditor: GestureEditorSession?
    @State private var isCheckingUpdate = false
    @State private var showedUpToDateHint = false
    @State private var settingsToast: String?
    @State private var settingsToastGeneration = 0
    @State private var modifierRuleEditor: AppModifierRemapRule?
    @State private var modifierAddError: String?
    @State private var aboutIconClickCount = 0
    @State private var aboutIconLastClickAt: Date?
    @ObservedObject private var mouseGestures = MouseGestureController.shared
    @ObservedObject private var updateChecker = UpdateChecker.shared
    @ObservedObject private var clipboardStore = ClipboardHistoryStore.shared
    @State private var showClearClipboardHistoryConfirm = false
    @State private var showClearClipboardImagesConfirm = false

    var body: some View {
        ZStack(alignment: .bottom) {
        VStack(spacing: 0) {
            if needsAccessibilityBanner {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("没有设备控制和数据访问权限")
                        Text(accessibilityBannerDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button("获取权限") {
                        mouseGestures.requestAccessibility()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.16))
                .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
                    mouseGestures.refreshAccessibility()
                    DoubleModifierHotKeyMonitor.shared.refreshIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    mouseGestures.refreshAccessibility()
                    DoubleModifierHotKeyMonitor.shared.refreshIfNeeded()
                }
            }
            HStack(spacing: 0) {
                List(SettingsPane.allCases, selection: $selectedPane) { pane in
                    Label {
                        Text(pane.title)
                    } icon: {
                        Image(systemName: pane.systemImage)
                            .font(.system(size: 11, weight: .regular))
                            .frame(width: 14, alignment: .center)
                    }
                    .tag(pane)
                }
                .listStyle(.sidebar)
                .frame(width: 140)
                Group {
                    switch selectedPane {
                    case .general:
                        generalPane
                    case .panel:
                        panelPane
                    case .gestures:
                        gesturesPane
                    case .scroll:
                        scrollPane
                    case .modifiers:
                        modifiersPane
                    case .clipboard:
                        clipboardPane
                    case .about:
                        aboutPane
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: 640, height: 560)
        .onAppear {
            applySettingsPane(SettingsOpener.consumePendingPane())
            mouseGestures.refreshAccessibility()
        }
        .onReceive(NotificationCenter.default.publisher(for: .fastSomeSelectSettingsPane)) { note in
            if let raw = note.userInfo?["pane"] as? String,
               let pane = SettingsOpener.Pane(rawValue: raw) {
                applySettingsPane(pane)
            }
        }
        .onDisappear { stopRecording() }
        .onChange(of: selectedPane) { _, _ in
            stopRecording()
        }
        .sheet(item: $gestureEditor) { session in
            MouseGestureEditor(existing: session.gesture)
                .id(session.id)
        }
        .sheet(item: $modifierRuleEditor) { rule in
            ModifierRemapEditorSheet(rule: rule) { updated in
                settings.updateModifierRemapRule(updated)
            }
        }

            if let settingsToast {
                Text(settingsToast)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.78))
                    )
                    .padding(.bottom, 24)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .allowsHitTesting(false)
            }
        }
    }

    private func showSettingsToast(_ message: String) {
        settingsToastGeneration += 1
        let generation = settingsToastGeneration
        withAnimation(.easeOut(duration: 0.18)) {
            settingsToast = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            guard settingsToastGeneration == generation else { return }
            withAnimation(.easeIn(duration: 0.2)) {
                settingsToast = nil
            }
        }
    }

    private var needsAccessibilityBanner: Bool {
        !mouseGestures.accessibilityTrusted
            && (settings.panelEnabled
                || settings.mouseGesturesEnabled
                || settings.mouseScrollNeedsEventTap
                || settings.modifierRemapEnabled
                || settings.clipboardHistoryEnabled)
    }

    private var accessibilityBannerDetail: String {
        let permissionHowTo = "点「获取权限」会先弹出系统对话框，再在对话框里点「打开系统设置」并打开 FastSome 的开关；若仍提示，把开关关掉再打开一次，或完全退出 FastSome 后再开。调试版每次重新编译后也可能要重新允许。"
        var parts: [String] = []
        if settings.panelEnabled { parts.append("快捷面板") }
        if settings.mouseGesturesEnabled { parts.append("鼠标手势") }
        if settings.mouseScrollNeedsEventTap { parts.append("鼠标滚动") }
        if settings.modifierRemapEnabled { parts.append("修饰键") }
        if settings.clipboardHistoryEnabled { parts.append("剪贴板历史") }
        if parts.isEmpty {
            return permissionHowTo
        }
        if parts.count == 1 {
            return "\(parts[0])需要这项权限。\(permissionHowTo)"
        }
        let joined = parts.dropLast().joined(separator: "、") + "和" + parts.last!
        return "\(joined)都可能用到这项权限。\(permissionHowTo)"
    }

    private func applySettingsPane(_ pane: SettingsOpener.Pane) {
        if let mapped = SettingsPane(rawValue: pane.rawValue) {
            selectedPane = mapped
        }
    }

    private var isRecordingPanelHotKey: Bool { recordingTarget == .panel }
    private var isRecordingClipboardHotKey: Bool { recordingTarget == .clipboard }

    private var panelHotKeyTipsBinding: Binding<Bool> {
        Binding(
            get: { showPanelHotKeyTips },
            set: { newValue in
                guard showPanelHotKeyTips != newValue else { return }
                showPanelHotKeyTips = newValue
                if !newValue {
                    finishRecordingAfterTipsDismiss()
                }
            }
        )
    }

    private var clipboardHotKeyTipsBinding: Binding<Bool> {
        Binding(
            get: { showClipboardHotKeyTips },
            set: { newValue in
                guard showClipboardHotKeyTips != newValue else { return }
                showClipboardHotKeyTips = newValue
                if !newValue {
                    finishRecordingAfterTipsDismiss()
                }
            }
        )
    }

    private var generalPane: some View {
        Form {
            Section("启动") {
                Toggle("登录时打开 FastSome", isOn: $settings.launchAtLogin)
                Toggle("在程序坞中显示图标", isOn: $settings.showInDock)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var panelPane: some View {
        Form {
            Section {
                Toggle("启用快捷面板", isOn: $settings.panelEnabled)
                Text("关闭后菜单栏图标仍在，可打开设置；不会再唤起快捷面板，也不注册全局快捷键。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.panelEnabled {
                Section("全局唤起快捷键") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("唤起面板")
                            Text("点击右侧录制；支持组合键或双击 ⌃ / ⌥ / ⌘")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(settings.hotKey?.displayString ?? "未设置") {
                            startRecording(for: .panel)
                        }
                        .popover(isPresented: panelHotKeyTipsBinding, arrowEdge: .top) {
                            hotKeyRecordingTipsContent
                        }
                    }

                    HStack {
                        Button("恢复默认（⌥Space）") {
                            settings.resetHotKeyToDefault()
                            HotKeyBinding.applyFromSettings()
                            toastIfHotKeyBindFailed(target: .panel)
                            stopRecording()
                        }
                        Button("清除") {
                            settings.clearHotKey()
                            stopRecording()
                        }
                    }
                }

                Section("面板布局") {
                    ForEach(PanelLayout.allCases) { layout in
                        Button {
                            settings.layout = layout
                        } label: {
                            HStack(spacing: 14) {
                                layoutPreview(layout)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(layout.title)
                                        .foregroundStyle(.primary)
                                    Text(layout.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if settings.layout == layout {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(settings.layout == layout ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: settings.layout == layout ? 2 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("面板") {
                    Toggle("打开快捷方式后关闭面板", isOn: $settings.closePanelAfterLaunch)
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .onChange(of: settings.panelEnabled) { _, enabled in
            if !enabled { stopRecording() }
        }
    }

    private var gesturesPane: some View {
        Form {
            Section {
                Toggle("启用鼠标手势", isOn: $settings.mouseGesturesEnabled)
                Text("关闭后不再监听鼠标，已保存的手势会保留。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.mouseGesturesEnabled {
                Section("显示") {
                    Toggle("显示轨迹", isOn: $settings.mouseGestureTrailVisible)
                    if settings.mouseGestureTrailVisible {
                        HStack(spacing: 10) {
                            Text("颜色")
                            Spacer(minLength: 8)
                            ForEach(MouseGestureTrailColor.allCases) { color in
                                let selected = settings.mouseGestureTrailColor == color
                                Button {
                                    settings.mouseGestureTrailColor = color
                                } label: {
                                    Circle()
                                        .fill(trailSwiftUIColor(color))
                                        .frame(width: 18, height: 18)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(Color.primary.opacity(selected ? 0.9 : 0.15), lineWidth: selected ? 2 : 1)
                                        )
                                        .shadow(color: trailSwiftUIColor(color).opacity(0.55), radius: selected ? 4 : 0)
                                }
                                .buttonStyle(.plain)
                                .help(color.title)
                            }
                            Text(settings.mouseGestureTrailColor.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 16, alignment: .leading)
                        }
                    }
                    Toggle("显示提示", isOn: $settings.mouseGestureTipVisible)
                    Text("关闭后不影响手势识别与执行。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("添加") {
                        gestureEditor = .add
                    }
                    if settings.mouseGestures.isEmpty {
                        Text("添加后，按住选定的鼠标键画出方向，松开就会触发快捷键或粘贴预设文本。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(settings.mouseGestures) { gesture in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(gesture.summary)
                                Text(gesture.action.listSummary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("编辑") {
                                gestureEditor = .edit(gesture)
                            }
                            Button {
                                settings.removeMouseGesture(gesture.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("删除")
                        }
                    }
                    if mouseGestures.accessibilityTrusted, let statusMessage = mouseGestures.statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private var scrollPane: some View {
        Form {
            Section {
                Toggle("翻转鼠标垂直滚动", isOn: $settings.mouseScrollReverseEnabled)
                Text("只影响鼠标（含 Magic Mouse）的上下滚动。触摸板请用系统设置里的「滚动方向」。需要辅助功能权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("滚轮步长") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Spacer(minLength: 0)
                        Text(mouseScrollStepDisplayLabel)
                            .font(.body.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    // Form 里 Slider 有默认理想宽度；用行宽强制铺满。
                    GeometryReader { geo in
                        let labelWidth: CGFloat = 28
                        let gap: CGFloat = 12
                        let trackWidth = max(0, geo.size.width - labelWidth * 2 - gap * 2)
                        let lo = Double(AppSettings.mouseScrollStepPercentMin)
                        let hi = Double(AppSettings.mouseScrollStepPercentMax)
                        let def = Double(AppSettings.mouseScrollStepPercentDefault)
                        let fraction = (def - lo) / (hi - lo)
                        let inset: CGFloat = 12
                        let usable = max(0, trackWidth - inset * 2)
                        let tickX = labelWidth + gap + inset + CGFloat(fraction) * usable

                        HStack(spacing: gap) {
                            Text("慢")
                                .font(.body.weight(.medium))
                                .frame(width: labelWidth, alignment: .leading)

                            Slider(
                                value: Binding(
                                    get: { Double(settings.mouseScrollStepPercent) },
                                    set: { settings.mouseScrollStepPercent = Int($0.rounded()) }
                                ),
                                in: lo...hi,
                                step: Double(AppSettings.mouseScrollStepPercentStep)
                            )
                            .labelsHidden()
                            .frame(width: trackWidth)

                            Text("快")
                                .font(.body.weight(.medium))
                                .frame(width: labelWidth, alignment: .trailing)
                        }
                        .frame(width: geo.size.width, alignment: .leading)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.secondary.opacity(0.55))
                                .frame(width: 2, height: 12)
                                .offset(x: tickX - 1, y: 0)
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(height: 22)
                    .frame(maxWidth: .infinity)

                    Text("相对默认滚动量：默认＝×1，向左更细、向右更猛。只影响鼠标，与系统「滚动速度」会叠加。需要辅助功能权限。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    /// 步长对用户显示为「默认 / ×0.75」，避免「100%」像满格或完成度；倍数固定两位小数，拖动时宽度不跳。
    private var mouseScrollStepDisplayLabel: String {
        let percent = settings.mouseScrollStepPercent
        if percent == AppSettings.mouseScrollStepPercentDefault {
            return "默认"
        }
        let ratio = Double(percent) / 100.0
        return String(format: "×%.2f", ratio)
    }

    private var clipboardPane: some View {
        Form {
            Section {
                Toggle("启用剪贴板历史", isOn: $settings.clipboardHistoryEnabled)
                Text("关闭后不再记录，也不注册唤起快捷键；已有历史会保留。直接粘贴需要辅助功能，并可能要求允许控制「系统事件」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.clipboardHistoryEnabled {
                Section("唤起") {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("全局快捷键")
                            Text("点击右侧录制；支持组合键或双击 ⌃ / ⌥ / ⌘")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(settings.clipboardHotKey?.displayString ?? "未设置") {
                            startRecording(for: .clipboard)
                        }
                        .popover(isPresented: clipboardHotKeyTipsBinding, arrowEdge: .top) {
                            hotKeyRecordingTipsContent
                        }
                    }

                    HStack {
                        Button("恢复默认（⌥⌘V）") {
                            settings.resetClipboardHotKeyToDefault()
                            HotKeyBinding.applyFromSettings()
                            toastIfHotKeyBindFailed(target: .clipboard)
                            stopRecording()
                        }
                        Button("清除") {
                            settings.clearClipboardHotKey()
                            stopRecording()
                        }
                    }
                }

                Section("选中一条历史后") {
                    Picker("动作", selection: $settings.clipboardSelectionAction) {
                        ForEach(ClipboardSelectionAction.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(settings.clipboardSelectionAction.settingsHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("保留策略") {
                    Picker("保存时长", selection: $settings.clipboardRetentionDays) {
                        Text("1 天").tag(1)
                        Text("3 天").tag(3)
                        Text("5 天").tag(5)
                        Text("10 天").tag(10)
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        Text("最大条数")
                        Spacer()
                        ClipboardMaxItemsStepper(value: $settings.clipboardMaxItems)
                    }
                    Text("按有复制进历史的日期计算天数；超过天数或条数的记录会自动删除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("已占用空间")
                            Spacer()
                            Text(clipboardStore.occupiedSizeLabel)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        occupiedRow(title: "文本", value: clipboardStore.occupiedTextSizeLabel)
                        occupiedRow(title: "图片", value: clipboardStore.occupiedImageSizeLabel)
                    }

                    HStack(spacing: 12) {
                        Button("清除全部", role: .destructive) {
                            showClearClipboardHistoryConfirm = true
                        }
                        .disabled(clipboardStore.items.isEmpty && clipboardStore.occupiedByteCount == 0)

                        Button("清除图片", role: .destructive) {
                            showClearClipboardImagesConfirm = true
                        }
                        .disabled(!clipboardStore.hasStoredImages)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .onChange(of: settings.clipboardHistoryEnabled) { _, enabled in
            if !enabled { stopRecording() }
        }
        .alert("清除全部剪贴板历史？", isPresented: $showClearClipboardHistoryConfirm) {
            Button("清除全部", role: .destructive) {
                clipboardStore.clearAll()
                showSettingsToast("已清除全部历史")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除文本、图片和文件记录，且不可恢复。")
        }
        .alert("清除图片历史？", isPresented: $showClearClipboardImagesConfirm) {
            Button("清除图片", role: .destructive) {
                clipboardStore.clearImages()
                showSettingsToast("已清除图片历史")
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除图片记录及本地副本，文本和文件记录会保留。")
        }
    }

    private func occupiedRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.caption)
    }

    private var modifiersPane: some View {
        Form {
            Section {
                Toggle("启用按应用修饰键映射", isOn: $settings.modifierRemapEnabled)
                Text("只在列表中的应用前台时生效，其它应用保持系统原样。每个应用可单独设置，类似系统「修饰键」。需要辅助功能权限。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.modifierRemapEnabled {
                Section("应用") {
                    Menu("从运行中的应用添加") {
                        let apps = runningAppsForModifierRemap()
                        if apps.isEmpty {
                            Text("没有可添加的应用")
                        } else {
                            ForEach(apps, id: \.bundleIdentifier) { app in
                                Button(app.displayName) {
                                    modifierAddError = settings.addModifierRemapRule(
                                        bundleIdentifier: app.bundleIdentifier,
                                        displayName: app.displayName
                                    )
                                }
                            }
                        }
                    }
                    Button("选取应用程序…") {
                        modifierAddError = pickApplicationForModifierRemap()
                    }
                    if let modifierAddError {
                        Text(modifierAddError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if settings.modifierRemapRules.isEmpty {
                        Text("把远程桌面等应用加进来，再点「编辑」设置该应用内的修饰键映射。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(settings.modifierRemapRules) { rule in
                        HStack(spacing: 10) {
                            appIcon(for: rule.bundleIdentifier)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 28, height: 28)
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.displayName)
                                Text(rule.summary)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Button("编辑") {
                                modifierRuleEditor = rule
                            }
                            Button {
                                settings.removeModifierRemapRule(rule.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("删除")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }

    private func pickApplicationForModifierRemap() -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "选择要单独设置修饰键的应用"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let bundle = Bundle(url: url), let bundleId = bundle.bundleIdentifier else {
            return "无法识别该应用。"
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return settings.addModifierRemapRule(bundleIdentifier: bundleId, displayName: name)
    }

    private func runningAppsForModifierRemap() -> [(bundleIdentifier: String, displayName: String)] {
        let existing = Set(settings.modifierRemapRules.map(\.bundleIdentifier))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (String, String)? in
                guard let id = app.bundleIdentifier, !existing.contains(id) else { return nil }
                return (id, app.localizedName ?? id)
            }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    private func appIcon(for bundleIdentifier: String) -> Image {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
        }
        return Image(nsImage: NSImage(size: NSSize(width: 28, height: 28)))
    }

    private func trailSwiftUIColor(_ color: MouseGestureTrailColor) -> Color {
        let rgb = color.rgb
        return Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    private var aboutPane: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .onTapGesture { handleAboutIconTap() }

                Text("FastSome")
                    .font(.title2.bold())

                Text("版本 \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.3")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Text("少一点寻找，多一点顺手。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.top, 2)

                VStack(spacing: 8) {
                    if updateChecker.isDownloading {
                        Button("正在下载 \(updateChecker.downloadPercentLabel)") {}
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .disabled(true)
                        ProgressView(value: updateChecker.downloadProgress)
                            .progressViewStyle(.linear)
                            .frame(width: 220)
                    } else if let available = updateChecker.availableUpdate {
                        Button("立即更新") {
                            Task { await updateChecker.downloadAndInstall() }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        Text("发现新版本 \(available.latest)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Button(isCheckingUpdate ? "检查中…" : "检查更新") {
                            guard !isCheckingUpdate else { return }
                            isCheckingUpdate = true
                            showedUpToDateHint = false
                            Task {
                                let outcome = await updateChecker.check()
                                await MainActor.run {
                                    isCheckingUpdate = false
                                    switch outcome {
                                    case .upToDate:
                                        showedUpToDateHint = true
                                    case .updateAvailable:
                                        showedUpToDateHint = false
                                    case .failed(let message):
                                        showedUpToDateHint = false
                                        UpdateChecker.presentFailure(message)
                                    }
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(isCheckingUpdate)
                        if showedUpToDateHint {
                            Text("已是最新版")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.top, 10)
            }

            Spacer(minLength: 20)

            Link(destination: UpdateChecker.homepageURL) {
                HStack(spacing: 4) {
                    Text("项目主页")
                        .underline()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.tint)
            }
            .help("在浏览器打开 GitHub 仓库")
            .padding(.bottom, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func handleAboutIconTap() {
        guard !FireworksPresenter.isPlaying else { return }
        let now = Date()
        if let last = aboutIconLastClickAt, now.timeIntervalSince(last) <= 0.8 {
            aboutIconClickCount += 1
        } else {
            aboutIconClickCount = 1
        }
        aboutIconLastClickAt = now
        guard aboutIconClickCount >= 5 else { return }
        aboutIconClickCount = 0
        aboutIconLastClickAt = nil
        FireworksPresenter.play()
    }

    @ViewBuilder
    private func layoutPreview(_ layout: PanelLayout) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.001))
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.85))
            Group {
                switch layout {
                case .tabsGrid:
                    VStack(spacing: 4) {
                        HStack(spacing: 2) {
                            Capsule().fill(Color.white.opacity(0.55)).frame(height: 4)
                            Capsule().fill(Color.white.opacity(0.25)).frame(height: 4)
                            Capsule().fill(Color.white.opacity(0.25)).frame(height: 4)
                        }
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 4), spacing: 3) {
                            ForEach(0..<8, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.28))
                                    .frame(height: 10)
                            }
                        }
                    }
                    .padding(7)
                case .sidebar:
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.2)).frame(width: 16)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
                            ForEach(0..<6, id: \.self) { _ in
                                RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.28))
                                    .frame(height: 10)
                            }
                        }
                    }
                    .padding(7)
                case .list:
                    VStack(spacing: 3) {
                        ForEach(0..<4, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.28))
                                .frame(height: 8)
                        }
                    }
                    .padding(7)
                }
            }
        }
        .frame(width: 96, height: 70)
    }

    @ViewBuilder
    private var hotKeyRecordingTipsContent: some View {
        HStack(spacing: 10) {
            Text(recordingCandidate?.displayString ?? "请按下快捷键")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(recordingCandidate == nil ? .secondary : .primary)
                .fixedSize(horizontal: true, vertical: false)
            Button {
                recordingDiscard = true
                showPanelHotKeyTips = false
                showClipboardHotKeyTips = false
                finishRecordingAfterTipsDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("放弃本次设置")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func startRecording(for target: HotKeyRecordingTarget) {
        // Drop any in-progress tips session without saving.
        if recordingTarget != nil || showPanelHotKeyTips || showClipboardHotKeyTips {
            recordingDiscard = true
            showPanelHotKeyTips = false
            showClipboardHotKeyTips = false
            stopRecordingMonitorsOnly()
            recordingTarget = nil
            recordingCandidate = nil
            recordingDiscard = false
        }

        recordingTarget = target
        recordingCandidate = nil
        recordingDiscard = false
        tipDetector.reset()
        tipLastFlagsRaw = 0
        switch target {
        case .panel:
            showPanelHotKeyTips = true
        case .clipboard:
            showClipboardHotKeyTips = true
        }

        HotKeyBinding.suspendForRecording()

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                Task { @MainActor in
                    recordingDiscard = true
                    showPanelHotKeyTips = false
                    showClipboardHotKeyTips = false
                    finishRecordingAfterTipsDismiss()
                }
                return nil
            }
            // Ignore bare key presses; chords need a modifier.
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods.isEmpty {
                return event
            }
            // Don't treat pure modifier keyDown as a chord (double-tap uses flagsChanged).
            if DoubleModifierKind.from(keyCode: event.keyCode) != nil {
                return nil
            }
            let combo = HotKeyCombo(
                keyCode: UInt32(event.keyCode),
                modifiers: carbonModifiers(from: event)
            )
            Task { @MainActor in
                if let message = hotKeyRejectMessage(combo, for: target) {
                    showSettingsToast(message)
                    return
                }
                recordingCandidate = combo
            }
            return nil
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            Task { @MainActor in
                handleRecordingFlagsChanged(event)
            }
            return event
        }
    }

    private func handleRecordingFlagsChanged(_ event: NSEvent) {
        guard recordingTarget != nil else { return }
        let code = event.keyCode
        let current = event.modifierFlags
        let currentRaw = current.rawValue
        guard let kind = DoubleModifierKind.from(keyCode: code) else {
            _ = tipDetector.handle(.otherKey)
            tipLastFlagsRaw = currentRaw
            return
        }
        let nowDown: Bool = {
            switch kind {
            case .control: return current.contains(.control)
            case .option: return current.contains(.option)
            case .command: return current.contains(.command)
            }
        }()
        let wasDown: Bool = {
            switch kind {
            case .control: return tipLastFlagsRaw & (1 << 18) != 0
            case .option: return tipLastFlagsRaw & (1 << 19) != 0
            case .command: return tipLastFlagsRaw & (1 << 20) != 0
            }
        }()
        tipLastFlagsRaw = currentRaw
        if nowDown && !wasDown {
            _ = tipDetector.handle(.modifierDown(kind))
        } else if !nowDown && wasDown {
            if let fired = tipDetector.handle(.modifierUp(kind)) {
                let combo = HotKeyCombo.doubleTap(fired)
                if let message = hotKeyRejectMessage(combo, for: recordingTarget ?? .panel) {
                    showSettingsToast(message)
                } else {
                    recordingCandidate = combo
                }
            }
        }
    }

    private func finishRecordingAfterTipsDismiss() {
        let target = recordingTarget
        let candidate = recordingCandidate
        let discard = recordingDiscard
        // Idempotent: tip dismiss can fire more than once.
        guard target != nil || candidate != nil || discard else {
            stopRecordingMonitorsOnly()
            HotKeyBinding.applyFromSettings()
            return
        }
        stopRecordingMonitorsOnly()
        recordingTarget = nil
        recordingCandidate = nil
        recordingDiscard = false

        var applied: (HotKeyRecordingTarget, HotKeyCombo)?
        if let target, !discard, let candidate {
            if let message = hotKeyRejectMessage(candidate, for: target) {
                showSettingsToast(message)
            } else {
                switch target {
                case .panel:
                    settings.hotKey = candidate
                    settings.hotKeyEnabled = true
                case .clipboard:
                    settings.clipboardHotKey = candidate
                    settings.clipboardHotKeyEnabled = true
                }
                applied = (target, candidate)
            }
        }

        // Always restore Carbon/double-tap bindings after recording (including cancel).
        HotKeyBinding.applyFromSettings()
        if let (target, combo) = applied {
            toastIfHotKeyBindFailed(target: target, combo: combo)
        }
    }

    private func hotKeyRejectMessage(_ combo: HotKeyCombo, for target: HotKeyRecordingTarget) -> String? {
        if HotKeyManager.isReserved(combo) {
            return "该快捷键被系统保留，请换一组。"
        }
        switch target {
        case .panel:
            if HotKeyCombo.hasDoubleModifierConflict(panel: combo, clipboard: settings.clipboardHotKey) {
                return "与剪贴板唤起的双击快捷键冲突，请换一个。"
            }
            if HotKeyCombo.hasChordConflict(panel: combo, clipboard: settings.clipboardHotKey) {
                return "与剪贴板唤起的快捷键冲突，请换一个。"
            }
        case .clipboard:
            if HotKeyCombo.hasDoubleModifierConflict(panel: settings.hotKey, clipboard: combo) {
                return "与面板唤起的双击快捷键冲突，请换一个。"
            }
            if HotKeyCombo.hasChordConflict(panel: settings.hotKey, clipboard: combo) {
                return "与面板唤起的快捷键冲突，请换一个。"
            }
        }
        return nil
    }

    private func toastIfHotKeyBindFailed(target: HotKeyRecordingTarget, combo: HotKeyCombo? = nil) {
        switch target {
        case .panel:
            let panel = combo ?? settings.hotKey
            if let message = HotKeyManager.shared.lastErrorMessage {
                showSettingsToast(message)
            } else if panel?.isDoubleModifier == true, !DoubleModifierHotKeyMonitor.shared.accessibilityTrusted {
                showSettingsToast("双击快捷键需要辅助功能权限。")
            }
        case .clipboard:
            let clip = combo ?? settings.clipboardHotKey
            if let message = ClipboardHotKeyMonitor.shared.lastErrorMessage {
                showSettingsToast(message)
            } else if clip?.isDoubleModifier == true, !DoubleModifierHotKeyMonitor.shared.accessibilityTrusted {
                showSettingsToast("双击快捷键需要辅助功能权限。")
            }
        }
    }

    private func stopRecording() {
        recordingDiscard = true
        showPanelHotKeyTips = false
        showClipboardHotKeyTips = false
        finishRecordingAfterTipsDismiss()
    }

    private func stopRecordingMonitorsOnly() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        tipDetector.reset()
        tipLastFlagsRaw = 0
    }

    private func carbonModifiers(from event: NSEvent) -> UInt32 {
        let flags = event.modifierFlags
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }
}

private struct ModifierRemapEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: AppModifierRemapRule
    let onSave: (AppModifierRemapRule) -> Void

    init(rule: AppModifierRemapRule, onSave: @escaping (AppModifierRemapRule) -> Void) {
        _draft = State(initialValue: rule)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(draft.displayName)
                    .font(.headline)
                Spacer()
                Text(draft.bundleIdentifier)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            Form {
                Section {
                    ForEach(ModifierRemapSource.allCases) { source in
                        Picker(source.title, selection: targetBinding(for: source)) {
                            ForEach(ModifierRemapTarget.allCases) { target in
                                Text(target.title).tag(target)
                            }
                        }
                    }
                } footer: {
                    Text("与系统设置中的「修饰键」类似。左、右同名键共用同一规则。")
                        .font(.caption)
                }
            }
            .formStyle(.grouped)

            HStack {
                Button("恢复默认") {
                    draft.capsLock = .capsLock
                    draft.control = .control
                    draft.option = .option
                    draft.command = .command
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("存储") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: 420, height: 340)
    }

    private func targetBinding(for source: ModifierRemapSource) -> Binding<ModifierRemapTarget> {
        Binding(
            get: { draft.target(for: source) },
            set: { draft.setTarget($0, for: source) }
        )
    }
}

private enum GestureEditorSession: Identifiable {
    case add
    case edit(MouseGestureDefinition)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let gesture): return gesture.id.uuidString
        }
    }

    var gesture: MouseGestureDefinition? {
        switch self {
        case .add: return nil
        case .edit(let gesture): return gesture
        }
    }
}

private enum GestureEditorActionKind: String, CaseIterable, Identifiable {
    case shortcut
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shortcut: return "快捷键"
        case .text: return "文本"
        }
    }
}

private struct MouseGestureEditor: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    private let existing: MouseGestureDefinition?
    @State private var button: MouseGestureButton
    /// Always three slots so pickers keep a stable layout; only `activeStrokeCount` are used.
    @State private var strokeSlots: [MouseGestureDirection]
    @State private var activeStrokeCount: Int
    @State private var actionKind: GestureEditorActionKind
    @State private var shortcut: HotKeyCombo?
    @State private var pasteText: String
    @State private var isRecording = false
    @State private var recordingPreview = "按下快捷键"
    @State private var capture = ShortcutCapture()
    @State private var errorMessage: String?

    init(existing: MouseGestureDefinition? = nil) {
        self.existing = existing
        _button = State(initialValue: existing?.button ?? .right)
        let initial = existing?.strokes ?? [.left]
        _activeStrokeCount = State(initialValue: min(max(initial.count, 1), 3))
        _strokeSlots = State(initialValue: MouseGestureLibrary.resizing(initial, to: 3))
        switch existing?.action {
        case .shortcut(let combo):
            _actionKind = State(initialValue: .shortcut)
            _shortcut = State(initialValue: combo)
            _pasteText = State(initialValue: "")
        case .text(let text):
            _actionKind = State(initialValue: .text)
            _shortcut = State(initialValue: nil)
            _pasteText = State(initialValue: text)
        case nil:
            _actionKind = State(initialValue: .shortcut)
            _shortcut = State(initialValue: nil)
            _pasteText = State(initialValue: "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(existing == nil ? "添加鼠标手势" : "编辑鼠标手势")
                .font(.headline)
            Picker("鼠标键", selection: $button) {
                ForEach(MouseGestureButton.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            Picker("笔数", selection: $activeStrokeCount) {
                Text("一笔").tag(1)
                Text("两笔").tag(2)
                Text("三笔").tag(3)
            }
            .pickerStyle(.segmented)
            .onChange(of: activeStrokeCount) { _, newCount in
                // Pad hidden slots when increasing so bindings stay valid; keep prior values when decreasing.
                if strokeSlots.count < 3 {
                    strokeSlots = MouseGestureLibrary.resizing(strokeSlots, to: 3)
                }
                if newCount > strokeSlots.count {
                    strokeSlots = MouseGestureLibrary.resizing(strokeSlots, to: newCount)
                }
            }
            HStack(alignment: .top, spacing: 12) {
                ForEach(0..<3, id: \.self) { index in
                    Picker("第 \(index + 1) 笔", selection: strokeSlotBinding(index)) {
                        ForEach(MouseGestureDirection.allCases) { direction in
                            Text(direction.title).tag(direction)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(index < activeStrokeCount ? 1 : 0)
                    .allowsHitTesting(index < activeStrokeCount)
                    .accessibilityHidden(index >= activeStrokeCount)
                }
            }
            Picker("动作", selection: $actionKind) {
                ForEach(GestureEditorActionKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: actionKind) { _, kind in
                if kind != .shortcut {
                    stopRecording()
                }
            }
            if actionKind == .shortcut {
                HStack {
                    Text("快捷键")
                    Spacer()
                    Button(isRecording ? "按下快捷键…" : (shortcut?.displayString ?? "点击设置")) {
                        if isRecording {
                            stopRecording()
                        } else {
                            startRecording()
                        }
                    }
                    .overlay(alignment: .top) {
                        if isRecording {
                            Text(recordingPreview)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(Color.black.opacity(0.78))
                                )
                                .fixedSize()
                                .offset(y: -36)
                                .allowsHitTesting(false)
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("粘贴文本")
                    TextEditor(text: $pasteText)
                        .font(.body)
                        .frame(minHeight: 88, maxHeight: 140)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1)
                        )
                    Text("松开手势后会粘贴到当前输入框。最多 \(MouseGestureAction.maxTextLength) 字。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消") {
                    stopRecording()
                    dismiss()
                }
                Button(existing == nil ? "添加" : "保存") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onDisappear { stopRecording() }
    }

    private func strokeSlotBinding(_ index: Int) -> Binding<MouseGestureDirection> {
        Binding(
            get: {
                guard strokeSlots.indices.contains(index) else { return .left }
                return strokeSlots[index]
            },
            set: { newValue in
                if strokeSlots.count < 3 {
                    strokeSlots = MouseGestureLibrary.resizing(strokeSlots, to: 3)
                }
                guard strokeSlots.indices.contains(index) else { return }
                strokeSlots[index] = newValue
            }
        )
    }

    private var activeStrokes: [MouseGestureDirection] {
        Array(strokeSlots.prefix(activeStrokeCount))
    }

    private func save() {
        let action: MouseGestureAction
        switch actionKind {
        case .shortcut:
            guard let shortcut else {
                errorMessage = "请先设置快捷键。"
                return
            }
            action = .shortcut(shortcut)
        case .text:
            action = .text(pasteText)
        }
        let strokes = activeStrokes
        let error: String?
        if let existing {
            error = settings.updateMouseGesture(
                id: existing.id,
                button: button,
                strokes: strokes,
                action: action
            )
        } else {
            error = settings.addMouseGesture(button: button, strokes: strokes, action: action)
        }
        if let error {
            errorMessage = error
            return
        }
        stopRecording()
        dismiss()
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        recordingPreview = "按下快捷键"
        errorMessage = nil
        capture.onPreview = { recordingPreview = $0 }
        capture.onCommit = { combo in
            shortcut = combo
            stopRecording()
        }
        capture.onCancel = { stopRecording() }
        if !capture.start() {
            errorMessage = "需要在「隐私与安全性 → 设备控制和数据访问」中允许 FastSome，才能录制快捷键。"
            stopRecording()
        }
    }

    private func stopRecording() {
        isRecording = false
        capture.stop()
    }
}

/// Swallows key events while a gesture shortcut is being recorded, so the
/// system does not also perform that shortcut.
private final class ShortcutCapture {
    var onPreview: ((String) -> Void)?
    var onCommit: ((HotKeyCombo) -> Void)?
    var onCancel: (() -> Void)?

    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var modifiers: UInt32 = 0
    private var heldModifierKeys: Set<UInt32> = []
    private var heldKey: UInt32?
    private var pending: HotKeyCombo?

    func start() -> Bool {
        stopTap()
        modifiers = 0
        heldModifierKeys = []
        heldKey = nil
        pending = nil
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let capture = Unmanaged<ShortcutCapture>.fromOpaque(userInfo).takeUnretainedValue()
                return capture.receive(type: type, event: event)
            },
            userInfo: userInfo
        ) else { return false }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    func stop() {
        stopTap()
        onPreview = nil
        onCommit = nil
        onCancel = nil
    }

    private func stopTap() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        port = nil
        source = nil
    }

    fileprivate func receive(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port {
                CGEvent.tapEnable(tap: port, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let mods = Self.carbonModifiers(event.flags)
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        if type == .flagsChanged {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.modifiers = mods
                if Self.isModifier(keyCode) {
                    if Self.modifierStillDown(keyCode, flags: event.flags) {
                        self.heldModifierKeys.insert(keyCode)
                    } else {
                        self.heldModifierKeys.remove(keyCode)
                    }
                }
                self.publish()
            }
            return nil
        }
        if type == .keyDown {
            if keyCode == UInt32(kVK_Escape) {
                DispatchQueue.main.async { [weak self] in self?.onCancel?() }
                return nil
            }
            if isRepeat || Self.isModifier(keyCode) {
                return nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.modifiers = mods
                self.heldKey = keyCode
                let sides = Array(self.heldModifierKeys).sorted()
                self.pending = mods == 0
                    ? nil
                    : HotKeyCombo(keyCode: keyCode, modifiers: mods, modifierKeyCodes: sides)
                self.publish()
            }
            return nil
        }
        if type == .keyUp {
            if Self.isModifier(keyCode) {
                return nil
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let commit = (self.pending?.keyCode == keyCode) ? self.pending : nil
                if self.heldKey == keyCode {
                    self.heldKey = nil
                }
                self.pending = nil
                if let commit {
                    self.onCommit?(commit)
                } else {
                    self.publish()
                }
            }
            return nil
        }
        return nil
    }

    private func publish() {
        let text = HotKeyCombo.liveText(
            modifiers: modifiers,
            keyCode: heldKey,
            modifierKeyCodes: Array(heldModifierKeys).sorted()
        )
        onPreview?(text.isEmpty ? "按下快捷键" : text)
    }

    private static func modifierStillDown(_ keyCode: UInt32, flags: CGEventFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.maskCommand)
        case 56, 60: return flags.contains(.maskShift)
        case 58, 61: return flags.contains(.maskAlternate)
        case 59, 62: return flags.contains(.maskControl)
        default: return false
        }
    }

    private static func isModifier(_ keyCode: UInt32) -> Bool {
        [54, 55, 56, 57, 58, 59, 60, 61, 62, 63].contains(keyCode)
    }

    private static func carbonModifiers(_ flags: CGEventFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.maskCommand) { mods |= UInt32(cmdKey) }
        if flags.contains(.maskAlternate) { mods |= UInt32(optionKey) }
        if flags.contains(.maskShift) { mods |= UInt32(shiftKey) }
        if flags.contains(.maskControl) { mods |= UInt32(controlKey) }
        return mods
    }
}

private struct ClipboardMaxItemsStepper: View {
    @Binding var value: Int

    var body: some View {
        HStack(spacing: 6) {
            Text("\(value)")
                .font(.body.monospacedDigit())
                .frame(minWidth: 36, alignment: .trailing)
            VStack(spacing: 1) {
                stepButton(systemName: "chevron.up", enabled: value < 500) {
                    value = AppSettings.steppedClipboardMaxItems(from: value, up: true)
                }
                stepButton(systemName: "chevron.down", enabled: value > 20) {
                    value = AppSettings.steppedClipboardMaxItems(from: value, up: false)
                }
            }
        }
        .onAppear {
            value = AppSettings.clampedClipboardMaxItems(value)
        }
    }

    private func stepButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 16, height: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.secondary : Color.secondary.opacity(0.35))
        .disabled(!enabled)
    }
}
