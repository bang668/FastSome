import Foundation
import Combine

enum PanelLayout: String, CaseIterable, Identifiable, Codable, Sendable {
    case tabsGrid
    case sidebar
    case list

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tabsGrid: return "顶部分组 + 图标网格"
        case .sidebar: return "左侧分组栏"
        case .list: return "列表"
        }
    }

    var subtitle: String {
        switch self {
        case .tabsGrid: return "分组横排在上方，下面四列图标。"
        case .sidebar: return "分组竖排在左边，右边显示图标。"
        case .list: return "一行一个，名称更完整。"
        }
    }
}

enum DoubleModifierKind: String, Codable, CaseIterable, Sendable {
    case control
    case option
    case command

    var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        }
    }

    var displayString: String { "双击 \(symbol)" }

    /// Carbon/NSEvent modifier bit used by this key.
    var carbonBit: UInt32 {
        switch self {
        case .control: return 4096
        case .option: return 2048
        case .command: return 256
        }
    }

    /// Left and right physical key codes.
    var keyCodes: Set<UInt16> {
        switch self {
        case .control: return [59, 62]
        case .option: return [58, 61]
        case .command: return [55, 54]
        }
    }

    var primaryKeyCode: UInt32 { UInt32(keyCodes.min() ?? 0) }

    static func from(keyCode: UInt16) -> DoubleModifierKind? {
        allCases.first { $0.keyCodes.contains(keyCode) }
    }
}

struct HotKeyCombo: Equatable, Codable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32
    /// Left/right modifier keycodes held when the combo was recorded. Empty means side unknown.
    var modifierKeyCodes: [UInt32]
    /// When non-nil, this binding is a double-tap of that modifier (not a Carbon chord).
    var doubleModifier: DoubleModifierKind?

    static let optionSpace = HotKeyCombo(keyCode: 49, modifiers: 2048, modifierKeyCodes: [58])
    /// Default clipboard history hotkey: ⌥⌘V
    static let optionCommandV = HotKeyCombo(keyCode: 9, modifiers: 2048 | 256, modifierKeyCodes: [58, 55])

    var isDoubleModifier: Bool { doubleModifier != nil }

    static func doubleTap(_ kind: DoubleModifierKind) -> HotKeyCombo {
        HotKeyCombo(
            keyCode: kind.primaryKeyCode,
            modifiers: kind.carbonBit,
            modifierKeyCodes: [kind.primaryKeyCode],
            doubleModifier: kind
        )
    }

    init(
        keyCode: UInt32,
        modifiers: UInt32,
        modifierKeyCodes: [UInt32] = [],
        doubleModifier: DoubleModifierKind? = nil
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.modifierKeyCodes = modifierKeyCodes
        self.doubleModifier = doubleModifier
    }

    private enum CodingKeys: String, CodingKey {
        case keyCode
        case modifiers
        case modifierKeyCodes
        case doubleModifier
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        modifiers = try container.decode(UInt32.self, forKey: .modifiers)
        modifierKeyCodes = try container.decodeIfPresent([UInt32].self, forKey: .modifierKeyCodes) ?? []
        doubleModifier = try container.decodeIfPresent(DoubleModifierKind.self, forKey: .doubleModifier)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(modifiers, forKey: .modifiers)
        try container.encode(modifierKeyCodes, forKey: .modifierKeyCodes)
        try container.encodeIfPresent(doubleModifier, forKey: .doubleModifier)
    }

    var displayString: String {
        if let doubleModifier {
            return doubleModifier.displayString
        }
        return Self.format(modifiers: modifiers, keyCode: keyCode, modifierKeyCodes: modifierKeyCodes)
    }

    /// True when panel and clipboard are both bound to the same double-modifier.
    static func hasDoubleModifierConflict(panel: HotKeyCombo?, clipboard: HotKeyCombo?) -> Bool {
        guard let a = panel?.doubleModifier, let b = clipboard?.doubleModifier else { return false }
        return a == b
    }

    /// True when both sides use the same Carbon chord (key + modifiers).
    static func hasChordConflict(panel: HotKeyCombo?, clipboard: HotKeyCombo?) -> Bool {
        guard let panel, let clipboard else { return false }
        guard !panel.isDoubleModifier, !clipboard.isDoubleModifier else { return false }
        return panel.keyCode == clipboard.keyCode && panel.modifiers == clipboard.modifiers
    }

    static func liveText(
        modifiers: UInt32,
        keyCode: UInt32?,
        modifierKeyCodes: [UInt32] = []
    ) -> String {
        format(modifiers: modifiers, keyCode: keyCode, modifierKeyCodes: modifierKeyCodes)
    }

    private static func format(
        modifiers: UInt32,
        keyCode: UInt32?,
        modifierKeyCodes: [UInt32]
    ) -> String {
        var parts = modifierNames(modifiers: modifiers, modifierKeyCodes: modifierKeyCodes)
        if let keyCode {
            parts.append(keyName(keyCode: keyCode))
        }
        // Symbols read better without "+" (⌥⌘V), matching system shortcut style.
        return parts.joined(separator: "")
    }

    private static func modifierNames(modifiers: UInt32, modifierKeyCodes: [UInt32]) -> [String] {
        var names: [String] = []
        let codes = Set(modifierKeyCodes)
        func appendSide(left: UInt32, right: UInt32, generic: String, bit: UInt32) {
            guard modifiers & bit != 0 else { return }
            if codes.contains(left) { names.append("左 \(generic)") }
            else if codes.contains(right) { names.append("右 \(generic)") }
            else { names.append(generic) }
        }
        appendSide(left: 59, right: 62, generic: "⌃", bit: 4096)
        appendSide(left: 58, right: 61, generic: "⌥", bit: 2048)
        appendSide(left: 56, right: 60, generic: "⇧", bit: 512)
        appendSide(left: 55, right: 54, generic: "⌘", bit: 256)
        return names
    }

    private static func keyName(keyCode: UInt32) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "Return"
        case 53: return "Esc"
        case 48: return "Tab"
        case 51: return "Delete"
        case 117: return "Forward Delete"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        case 122: return "F1"
        case 120: return "F2"
        case 99: return "F3"
        case 118: return "F4"
        case 96: return "F5"
        case 97: return "F6"
        case 98: return "F7"
        case 100: return "F8"
        case 101: return "F9"
        case 109: return "F10"
        case 103: return "F11"
        case 111: return "F12"
        case 105: return "F13"
        case 107: return "F14"
        case 113: return "F15"
        case 106: return "F16"
        case 64: return "F17"
        case 79: return "F18"
        case 80: return "F19"
        case 90: return "F20"
        default:
            let map: [UInt32: String] = [
                0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
                8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
                16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
                23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
                30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P",
                37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\",
                43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`"
            ]
            return map[keyCode] ?? "Key\(keyCode)"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private var isApplyingLoginItemResult = false

    @Published var layout: PanelLayout {
        didSet { defaults.set(layout.rawValue, forKey: Keys.layout) }
    }

    /// Master switch for the launcher panel (hotkey, menu bar click, Dock).
    @Published var panelEnabled: Bool {
        didSet { defaults.set(panelEnabled, forKey: Keys.panelEnabled) }
    }

    /// Master switch for mouse-gesture listening. Saved gestures are kept when off.
    @Published var mouseGesturesEnabled: Bool {
        didSet { defaults.set(mouseGesturesEnabled, forKey: Keys.mouseGesturesEnabled) }
    }

    /// Reverse vertical scrolling for mice only; trackpad follows system natural scrolling.
    @Published var mouseScrollReverseEnabled: Bool {
        didSet { defaults.set(mouseScrollReverseEnabled, forKey: Keys.mouseScrollReverseEnabled) }
    }

    /// Mouse wheel step as percent of default (50 / 75 / 100 / 150 / 200). Trackpad unchanged.
    @Published var mouseScrollStepPercent: Int {
        didSet {
            let clamped = Self.clampedMouseScrollStepPercent(mouseScrollStepPercent)
            if mouseScrollStepPercent != clamped {
                mouseScrollStepPercent = clamped
                return
            }
            defaults.set(mouseScrollStepPercent, forKey: Keys.mouseScrollStepPercent)
        }
    }

    static let mouseScrollStepPercentMin = 50
    static let mouseScrollStepPercentMax = 200
    static let mouseScrollStepPercentStep = 5
    static let mouseScrollStepPercentDefault = 100

    nonisolated static func clampedMouseScrollStepPercent(_ value: Int) -> Int {
        let lo = mouseScrollStepPercentMin
        let hi = mouseScrollStepPercentMax
        let step = mouseScrollStepPercentStep
        let clamped = min(max(value, lo), hi)
        let offset = clamped - lo
        let snapped = lo + Int((Double(offset) / Double(step)).rounded()) * step
        return min(max(snapped, lo), hi)
    }

    /// Event tap needed when reverse is on or step is not default.
    var mouseScrollNeedsEventTap: Bool {
        mouseScrollReverseEnabled || mouseScrollStepPercent != 100
    }

    /// Master switch for per-app modifier remapping.
    @Published var modifierRemapEnabled: Bool {
        didSet { defaults.set(modifierRemapEnabled, forKey: Keys.modifierRemapEnabled) }
    }

    /// Master switch for clipboard history recording and hotkey.
    @Published var clipboardHistoryEnabled: Bool {
        didSet { defaults.set(clipboardHistoryEnabled, forKey: Keys.clipboardHistoryEnabled) }
    }

    @Published var clipboardHotKeyEnabled: Bool {
        didSet { defaults.set(clipboardHotKeyEnabled, forKey: Keys.clipboardHotKeyEnabled) }
    }

    @Published var clipboardHotKey: HotKeyCombo? {
        didSet {
            if let clipboardHotKey {
                defaults.set(clipboardHotKey.keyCode, forKey: Keys.clipboardHotKeyCode)
                defaults.set(clipboardHotKey.modifiers, forKey: Keys.clipboardHotKeyModifiers)
                if let kind = clipboardHotKey.doubleModifier {
                    defaults.set(kind.rawValue, forKey: Keys.clipboardHotKeyDoubleModifier)
                } else {
                    defaults.removeObject(forKey: Keys.clipboardHotKeyDoubleModifier)
                }
                defaults.set(true, forKey: Keys.clipboardHotKeyEnabled)
                clipboardHotKeyEnabled = true
            } else {
                defaults.removeObject(forKey: Keys.clipboardHotKeyCode)
                defaults.removeObject(forKey: Keys.clipboardHotKeyModifiers)
                defaults.removeObject(forKey: Keys.clipboardHotKeyDoubleModifier)
            }
        }
    }

    @Published var clipboardSelectionAction: ClipboardSelectionAction {
        didSet { defaults.set(clipboardSelectionAction.rawValue, forKey: Keys.clipboardSelectionAction) }
    }

    @Published var clipboardRetentionDays: Int {
        didSet {
            let clamped = Self.clampedClipboardRetentionDays(clipboardRetentionDays)
            if clipboardRetentionDays != clamped {
                clipboardRetentionDays = clamped
                return
            }
            defaults.set(clipboardRetentionDays, forKey: Keys.clipboardRetentionDays)
        }
    }

    @Published var clipboardMaxItems: Int {
        didSet {
            let clamped = Self.clampedClipboardMaxItems(clipboardMaxItems)
            if clipboardMaxItems != clamped {
                clipboardMaxItems = clamped
                return
            }
            defaults.set(clipboardMaxItems, forKey: Keys.clipboardMaxItems)
        }
    }

    static let clipboardRetentionDayOptions = [1, 3, 5, 10]

    nonisolated static func clampedClipboardRetentionDays(_ value: Int) -> Int {
        let options = clipboardRetentionDayOptions
        if options.contains(value) { return value }
        return options.min(by: { abs($0 - value) < abs($1 - value) }) ?? 5
    }

    /// Allowed values: 20…100 step 20, then 150…500 step 50.
    nonisolated static func clampedClipboardMaxItems(_ value: Int) -> Int {
        let v = min(max(value, 20), 500)
        if v <= 100 {
            let stepped = Int((Double(v) / 20.0).rounded()) * 20
            return min(max(stepped, 20), 100)
        }
        let steps = Int((Double(v - 100) / 50.0).rounded())
        if steps <= 0 { return 100 }
        return min(500, 100 + steps * 50)
    }

    /// One notch up/down for the settings stepper.
    nonisolated static func steppedClipboardMaxItems(from value: Int, up: Bool) -> Int {
        let current = clampedClipboardMaxItems(value)
        if up {
            if current < 100 { return current + 20 }
            if current == 100 { return 150 }
            return min(500, current + 50)
        }
        if current <= 100 { return max(20, current - 20) }
        if current == 150 { return 100 }
        return current - 50
    }

    /// Per-app modifier maps. Empty means nothing to remap even when enabled.
    @Published var modifierRemapRules: [AppModifierRemapRule] {
        didSet {
            guard !isLoadingModifierRemapRules else { return }
            saveModifierRemapRules()
        }
    }

    @Published var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Keys.hotKeyEnabled) }
    }

    @Published var hotKey: HotKeyCombo? {
        didSet {
            if let hotKey {
                defaults.set(hotKey.keyCode, forKey: Keys.hotKeyCode)
                defaults.set(hotKey.modifiers, forKey: Keys.hotKeyModifiers)
                if let kind = hotKey.doubleModifier {
                    defaults.set(kind.rawValue, forKey: Keys.hotKeyDoubleModifier)
                } else {
                    defaults.removeObject(forKey: Keys.hotKeyDoubleModifier)
                }
                defaults.set(true, forKey: Keys.hotKeyEnabled)
                hotKeyEnabled = true
            } else {
                defaults.removeObject(forKey: Keys.hotKeyCode)
                defaults.removeObject(forKey: Keys.hotKeyModifiers)
                defaults.removeObject(forKey: Keys.hotKeyDoubleModifier)
            }
        }
    }

    /// Saved mouse gestures. Empty means the mouse is left to the system.
    @Published var mouseGestures: [MouseGestureDefinition] {
        didSet {
            guard !isLoadingMouseGestures else { return }
            saveMouseGestures()
        }
    }

    /// When false, live gesture trail is not drawn (recognition unchanged).
    @Published var mouseGestureTrailVisible: Bool {
        didSet { defaults.set(mouseGestureTrailVisible, forKey: Keys.mouseGestureTrailVisible) }
    }

    /// When false, match tip ("松开后 …") is not shown (recognition unchanged).
    @Published var mouseGestureTipVisible: Bool {
        didSet { defaults.set(mouseGestureTipVisible, forKey: Keys.mouseGestureTipVisible) }
    }

    /// Neon preset for the live gesture trail.
    @Published var mouseGestureTrailColor: MouseGestureTrailColor {
        didSet { defaults.set(mouseGestureTrailColor.rawValue, forKey: Keys.mouseGestureTrailColor) }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
            guard !isApplyingLoginItemResult else { return }
            _ = LoginItemService.setEnabled(launchAtLogin)
            let actual = LoginItemService.isEnabled
            if actual != launchAtLogin {
                isApplyingLoginItemResult = true
                launchAtLogin = actual
                isApplyingLoginItemResult = false
            }
        }
    }

    @Published var closePanelAfterLaunch: Bool {
        didSet { defaults.set(closePanelAfterLaunch, forKey: Keys.closePanelAfterLaunch) }
    }

    /// When true, show FastSome in the Dock; clicking the Dock icon toggles the panel.
    @Published var showInDock: Bool {
        didSet {
            defaults.set(showInDock, forKey: Keys.showInDock)
            if !SettingsOpener.isShowing {
                AppActivation.applyPreferredPolicy()
            }
        }
    }

    /// Panel size when opened from the menu bar.
    @Published var menuBarPanelSize: CGSize {
        didSet {
            defaults.set(menuBarPanelSize.width, forKey: Keys.menuBarPanelWidth)
            defaults.set(menuBarPanelSize.height, forKey: Keys.menuBarPanelHeight)
        }
    }

    /// Panel size when opened from the Dock.
    @Published var dockPanelSize: CGSize {
        didSet {
            defaults.set(dockPanelSize.width, forKey: Keys.dockPanelWidth)
            defaults.set(dockPanelSize.height, forKey: Keys.dockPanelHeight)
        }
    }

    static let defaultPanelSize = CGSize(width: 360, height: 480)
    static let minPanelSize = CGSize(width: 280, height: 320)
    static let maxPanelSize = CGSize(width: 900, height: 900)

    private let defaults = UserDefaults.standard
    private var isLoadingMouseGestures = false
    private var isLoadingModifierRemapRules = false

    /// Bundle id changed from com.fasticon.app. Copy missing keys so layout and hotkey survive.
    private static func migrateLegacyDomainIfNeeded() {
        let defaults = UserDefaults.standard
        guard let old = defaults.persistentDomain(forName: "com.fasticon.app") else { return }
        for (key, value) in old where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
        }
    }

    private enum Keys {
        static let layout = "settings.layout"
        static let panelEnabled = "settings.panelEnabled"
        static let mouseGesturesEnabled = "settings.mouseGesturesEnabled"
        static let mouseScrollReverseEnabled = "settings.mouseScrollReverseEnabled"
        static let mouseScrollStepPercent = "settings.mouseScrollStepPercent"
        static let modifierRemapEnabled = "settings.modifierRemapEnabled"
        static let modifierRemapRules = "settings.modifierRemapRules"
        static let clipboardHistoryEnabled = "settings.clipboardHistoryEnabled"
        static let clipboardHotKeyEnabled = "settings.clipboardHotKeyEnabled"
        static let clipboardHotKeyCode = "settings.clipboardHotKeyCode"
        static let clipboardHotKeyModifiers = "settings.clipboardHotKeyModifiers"
        static let clipboardHotKeyDoubleModifier = "settings.clipboardHotKeyDoubleModifier"
        static let clipboardSelectionAction = "settings.clipboardSelectionAction"
        static let clipboardRetentionDays = "settings.clipboardRetentionDays"
        static let clipboardMaxItems = "settings.clipboardMaxItems"
        static let hotKeyEnabled = "settings.hotKeyEnabled"
        static let hotKeyCode = "settings.hotKeyCode"
        static let hotKeyModifiers = "settings.hotKeyModifiers"
        static let hotKeyDoubleModifier = "settings.hotKeyDoubleModifier"
        static let mouseGestures = "settings.mouseGestures"
        static let mouseGestureTrailVisible = "settings.mouseGestureTrailVisible"
        static let mouseGestureTipVisible = "settings.mouseGestureTipVisible"
        static let mouseGestureTrailColor = "settings.mouseGestureTrailColor"
        static let launchAtLogin = "settings.launchAtLogin"
        static let closePanelAfterLaunch = "settings.closePanelAfterLaunch"
        static let showInDock = "settings.showInDock"
        static let menuBarPanelWidth = "settings.menuBarPanelWidth"
        static let menuBarPanelHeight = "settings.menuBarPanelHeight"
        static let dockPanelWidth = "settings.dockPanelWidth"
        static let dockPanelHeight = "settings.dockPanelHeight"
        /// Legacy single size (migrated into menuBarPanelSize).
        static let panelWidth = "settings.panelWidth"
        static let panelHeight = "settings.panelHeight"
    }

    private init() {
        Self.migrateLegacyDomainIfNeeded()
        if let raw = defaults.string(forKey: Keys.layout), let value = PanelLayout(rawValue: raw) {
            layout = value
        } else {
            layout = .tabsGrid
        }

        if defaults.object(forKey: Keys.panelEnabled) != nil {
            panelEnabled = defaults.bool(forKey: Keys.panelEnabled)
        } else {
            panelEnabled = true
        }

        if defaults.object(forKey: Keys.mouseGesturesEnabled) != nil {
            mouseGesturesEnabled = defaults.bool(forKey: Keys.mouseGesturesEnabled)
        } else {
            mouseGesturesEnabled = true
        }

        if defaults.object(forKey: Keys.mouseScrollReverseEnabled) != nil {
            mouseScrollReverseEnabled = defaults.bool(forKey: Keys.mouseScrollReverseEnabled)
        } else {
            mouseScrollReverseEnabled = false
        }

        if defaults.object(forKey: Keys.mouseScrollStepPercent) != nil {
            mouseScrollStepPercent = Self.clampedMouseScrollStepPercent(
                defaults.integer(forKey: Keys.mouseScrollStepPercent)
            )
        } else {
            mouseScrollStepPercent = 100
        }

        if defaults.object(forKey: Keys.modifierRemapEnabled) != nil {
            modifierRemapEnabled = defaults.bool(forKey: Keys.modifierRemapEnabled)
        } else {
            modifierRemapEnabled = false
        }

        if defaults.object(forKey: Keys.clipboardHistoryEnabled) != nil {
            clipboardHistoryEnabled = defaults.bool(forKey: Keys.clipboardHistoryEnabled)
        } else {
            clipboardHistoryEnabled = true
        }

        if defaults.object(forKey: Keys.clipboardHotKeyCode) != nil {
            let code = UInt32(defaults.integer(forKey: Keys.clipboardHotKeyCode))
            let mods = UInt32(defaults.integer(forKey: Keys.clipboardHotKeyModifiers))
            let doubleRaw = defaults.string(forKey: Keys.clipboardHotKeyDoubleModifier)
            let doubleKind = doubleRaw.flatMap(DoubleModifierKind.init(rawValue:))
            if let doubleKind {
                clipboardHotKey = .doubleTap(doubleKind)
            } else {
                clipboardHotKey = HotKeyCombo(keyCode: code, modifiers: mods)
            }
            clipboardHotKeyEnabled = defaults.object(forKey: Keys.clipboardHotKeyEnabled) as? Bool ?? true
        } else {
            clipboardHotKey = .optionCommandV
            clipboardHotKeyEnabled = true
        }

        if let raw = defaults.string(forKey: Keys.clipboardSelectionAction),
           let action = ClipboardSelectionAction(rawValue: raw) {
            clipboardSelectionAction = action
        } else {
            clipboardSelectionAction = .paste
        }

        if defaults.object(forKey: Keys.clipboardRetentionDays) != nil {
            clipboardRetentionDays = Self.clampedClipboardRetentionDays(defaults.integer(forKey: Keys.clipboardRetentionDays))
        } else {
            clipboardRetentionDays = 5
        }

        if defaults.object(forKey: Keys.clipboardMaxItems) != nil {
            clipboardMaxItems = Self.clampedClipboardMaxItems(defaults.integer(forKey: Keys.clipboardMaxItems))
        } else {
            clipboardMaxItems = 200
        }

        isLoadingModifierRemapRules = true
        if let data = defaults.data(forKey: Keys.modifierRemapRules),
           let stored = try? JSONDecoder().decode([AppModifierRemapRule].self, from: data) {
            modifierRemapRules = stored
        } else {
            modifierRemapRules = []
        }
        isLoadingModifierRemapRules = false

        if defaults.object(forKey: Keys.hotKeyCode) != nil {
            let code = UInt32(defaults.integer(forKey: Keys.hotKeyCode))
            let mods = UInt32(defaults.integer(forKey: Keys.hotKeyModifiers))
            let doubleRaw = defaults.string(forKey: Keys.hotKeyDoubleModifier)
            let doubleKind = doubleRaw.flatMap(DoubleModifierKind.init(rawValue:))
            if let doubleKind {
                hotKey = .doubleTap(doubleKind)
            } else {
                hotKey = HotKeyCombo(keyCode: code, modifiers: mods)
            }
            hotKeyEnabled = defaults.object(forKey: Keys.hotKeyEnabled) as? Bool ?? true
        } else {
            hotKey = .optionSpace
            hotKeyEnabled = true
        }

        isLoadingMouseGestures = true
        if let data = defaults.data(forKey: Keys.mouseGestures),
           let stored = try? JSONDecoder().decode([MouseGestureDefinition].self, from: data) {
            mouseGestures = stored
        } else {
            mouseGestures = []
        }
        isLoadingMouseGestures = false

        if defaults.object(forKey: Keys.mouseGestureTrailVisible) != nil {
            mouseGestureTrailVisible = defaults.bool(forKey: Keys.mouseGestureTrailVisible)
        } else {
            mouseGestureTrailVisible = true
        }

        if defaults.object(forKey: Keys.mouseGestureTipVisible) != nil {
            mouseGestureTipVisible = defaults.bool(forKey: Keys.mouseGestureTipVisible)
        } else {
            mouseGestureTipVisible = true
        }

        if let raw = defaults.string(forKey: Keys.mouseGestureTrailColor),
           let color = MouseGestureTrailColor(rawValue: raw) {
            mouseGestureTrailColor = color
        } else {
            mouseGestureTrailColor = .cyan
        }

        if defaults.object(forKey: Keys.launchAtLogin) != nil {
            launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        } else {
            launchAtLogin = true
            defaults.set(true, forKey: Keys.launchAtLogin)
        }

        if defaults.object(forKey: Keys.closePanelAfterLaunch) != nil {
            closePanelAfterLaunch = defaults.bool(forKey: Keys.closePanelAfterLaunch)
        } else {
            closePanelAfterLaunch = true
        }

        if defaults.object(forKey: Keys.showInDock) != nil {
            showInDock = defaults.bool(forKey: Keys.showInDock)
        } else {
            showInDock = false
        }

        if defaults.object(forKey: Keys.menuBarPanelWidth) != nil {
            menuBarPanelSize = Self.clampedPanelSize(
                CGSize(
                    width: defaults.double(forKey: Keys.menuBarPanelWidth),
                    height: defaults.double(forKey: Keys.menuBarPanelHeight)
                )
            )
        } else if defaults.object(forKey: Keys.panelWidth) != nil {
            // Migrate pre-split size into the menu-bar slot.
            menuBarPanelSize = Self.clampedPanelSize(
                CGSize(
                    width: defaults.double(forKey: Keys.panelWidth),
                    height: defaults.double(forKey: Keys.panelHeight)
                )
            )
        } else {
            menuBarPanelSize = Self.defaultPanelSize
        }

        if defaults.object(forKey: Keys.dockPanelWidth) != nil {
            dockPanelSize = Self.clampedPanelSize(
                CGSize(
                    width: defaults.double(forKey: Keys.dockPanelWidth),
                    height: defaults.double(forKey: Keys.dockPanelHeight)
                )
            )
        } else {
            dockPanelSize = Self.defaultPanelSize
        }
    }

    static func clampedPanelSize(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minPanelSize.width), maxPanelSize.width),
            height: min(max(size.height, minPanelSize.height), maxPanelSize.height)
        )
    }

    func panelSize(for source: PanelSizeSource) -> CGSize {
        switch source {
        case .menuBar: return menuBarPanelSize
        case .dock: return dockPanelSize
        }
    }

    func setPanelSize(_ size: CGSize, for source: PanelSizeSource) {
        let clamped = Self.clampedPanelSize(size)
        switch source {
        case .menuBar: menuBarPanelSize = clamped
        case .dock: dockPanelSize = clamped
        }
    }

    func resetHotKeyToDefault() {
        hotKey = .optionSpace
        hotKeyEnabled = true
    }

    func resetClipboardHotKeyToDefault() {
        clipboardHotKey = .optionCommandV
        clipboardHotKeyEnabled = true
    }

    func clearClipboardHotKey() {
        clipboardHotKey = nil
        clipboardHotKeyEnabled = false
        defaults.set(false, forKey: Keys.clipboardHotKeyEnabled)
    }

    func addMouseGesture(
        button: MouseGestureButton,
        strokes: [MouseGestureDirection],
        action: MouseGestureAction
    ) -> String? {
        switch MouseGestureLibrary.make(
            button: button,
            strokes: strokes,
            action: action,
            existing: mouseGestures
        ) {
        case .success(let gesture):
            mouseGestures.append(gesture)
            return nil
        case .failure(let error):
            return Self.gestureErrorText(error)
        }
    }

    func updateMouseGesture(
        id: UUID,
        button: MouseGestureButton,
        strokes: [MouseGestureDirection],
        action: MouseGestureAction
    ) -> String? {
        switch MouseGestureLibrary.make(
            button: button,
            strokes: strokes,
            action: action,
            existing: mouseGestures.filter { $0.id != id }
        ) {
        case .success(var gesture):
            gesture.id = id
            guard let index = mouseGestures.firstIndex(where: { $0.id == id }) else {
                return "找不到这条手势。"
            }
            mouseGestures[index] = gesture
            return nil
        case .failure(let error):
            return Self.gestureErrorText(error)
        }
    }

    func removeMouseGesture(_ id: UUID) {
        mouseGestures.removeAll { $0.id == id }
    }

    @discardableResult
    func addModifierRemapRule(bundleIdentifier: String, displayName: String) -> String? {
        guard !bundleIdentifier.isEmpty else { return "无法识别该应用。" }
        if modifierRemapRules.contains(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return "列表里已经有这个应用。"
        }
        modifierRemapRules.append(
            AppModifierRemapRule(bundleIdentifier: bundleIdentifier, displayName: displayName)
        )
        return nil
    }

    func updateModifierRemapRule(_ rule: AppModifierRemapRule) {
        guard let index = modifierRemapRules.firstIndex(where: { $0.id == rule.id }) else { return }
        modifierRemapRules[index] = rule
    }

    func removeModifierRemapRule(_ id: UUID) {
        modifierRemapRules.removeAll { $0.id == id }
    }

    private static func gestureErrorText(_ error: MouseGestureValidation) -> String {
        switch error {
        case .empty: return "至少要有一笔。"
        case .tooMany: return "最多三笔。"
        case .adjacentRepeat: return "相邻两笔不能相同。"
        case .duplicate: return "已经有一条相同的手势。"
        case .emptyText: return "请先填写要粘贴的文本。"
        case .textTooLong: return "文本最多 \(MouseGestureAction.maxTextLength) 字。"
        }
    }

    private func saveMouseGestures() {
        if let data = try? JSONEncoder().encode(mouseGestures) {
            defaults.set(data, forKey: Keys.mouseGestures)
        }
    }

    private func saveModifierRemapRules() {
        if let data = try? JSONEncoder().encode(modifierRemapRules) {
            defaults.set(data, forKey: Keys.modifierRemapRules)
        }
    }

    func clearHotKey() {
        hotKey = nil
        hotKeyEnabled = false
        defaults.set(false, forKey: Keys.hotKeyEnabled)
    }
}

enum PanelSizeSource: Equatable {
    case menuBar
    case dock
}
