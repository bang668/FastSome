import AppKit
import Foundation

enum Launcher {
    @MainActor
    static func open(_ item: ShortcutItem, store: LibraryStore) -> Bool {
        guard let url = store.resolveURL(for: item) else {
            presentMissingAlert(name: item.displayName)
            return false
        }

        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }

        let configuration = NSWorkspace.OpenConfiguration()
        do {
            switch item.kind {
            case .app:
                try NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                return true
            case .file, .folder:
                let ok = NSWorkspace.shared.open(url)
                if !ok {
                    presentMissingAlert(name: item.displayName)
                }
                return ok
            }
        } catch {
            presentMissingAlert(name: item.displayName)
            return false
        }
    }

    @MainActor
    private static func presentMissingAlert(name: String) {
        PanelController.shared.performModal {
            let alert = NSAlert()
            alert.messageText = "找不到项目"
            alert.informativeText = "「\(name)」对应的文件可能已被移动或删除。"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }
}
