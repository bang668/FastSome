import Foundation
import ServiceManagement

enum LoginItemService {
    /// Returns whether the change succeeded.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                return isEnabled == enabled || (!enabled && SMAppService.mainApp.status == .notRegistered)
            } catch {
                NSLog("Login item update failed: \(error.localizedDescription)")
                return false
            }
        }
        return false
    }

    static var isEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }
}
