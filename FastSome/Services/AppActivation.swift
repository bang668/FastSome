import AppKit

/// Applies Dock visibility from settings (runtime override of LSUIElement).
@MainActor
enum AppActivation {
    static func applyPreferredPolicy() {
        NSApp.setActivationPolicy(AppSettings.shared.showInDock ? .regular : .accessory)
    }
}
