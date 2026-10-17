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

struct HotKeyCombo: Equatable, Codable, Sendable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let optionSpace = HotKeyCombo(keyCode: 49, modifiers: 2048) // option + space (Carbon cmdKey=256, option=2048, shift=512, control=4096)

    var displayString: String {
        var parts: [String] = []
        if modifiers & 4096 != 0 { parts.append("⌃") }
        if modifiers & 2048 != 0 { parts.append("⌥") }
        if modifiers & 512 != 0 { parts.append("⇧") }
        if modifiers & 256 != 0 { parts.append("⌘") }
        parts.append(Self.keyName(keyCode: keyCode))
        return parts.joined()
    }

    private static func keyName(keyCode: UInt32) -> String {
        switch keyCode {
        case 49: return "Space"
        case 36: return "↩"
        case 53: return "Esc"
        case 123: return "←"
        case 124: return "→"
        case 125: return "↓"
        case 126: return "↑"
        default:
            let map: [UInt32: String] = [
                0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
                8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
                16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
                23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
                31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
                45: "N", 46: "M"
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

    @Published var hotKeyEnabled: Bool {
        didSet { defaults.set(hotKeyEnabled, forKey: Keys.hotKeyEnabled) }
    }

    @Published var hotKey: HotKeyCombo? {
        didSet {
            if let hotKey {
                defaults.set(hotKey.keyCode, forKey: Keys.hotKeyCode)
                defaults.set(hotKey.modifiers, forKey: Keys.hotKeyModifiers)
                defaults.set(true, forKey: Keys.hotKeyEnabled)
                hotKeyEnabled = true
            } else {
                defaults.removeObject(forKey: Keys.hotKeyCode)
                defaults.removeObject(forKey: Keys.hotKeyModifiers)
            }
        }
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
        static let hotKeyEnabled = "settings.hotKeyEnabled"
        static let hotKeyCode = "settings.hotKeyCode"
        static let hotKeyModifiers = "settings.hotKeyModifiers"
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

        if defaults.object(forKey: Keys.hotKeyCode) != nil {
            let code = UInt32(defaults.integer(forKey: Keys.hotKeyCode))
            let mods = UInt32(defaults.integer(forKey: Keys.hotKeyModifiers))
            hotKey = HotKeyCombo(keyCode: code, modifiers: mods)
            hotKeyEnabled = defaults.object(forKey: Keys.hotKeyEnabled) as? Bool ?? true
        } else {
            hotKey = .optionSpace
            hotKeyEnabled = true
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
