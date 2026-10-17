import SwiftUI

@main
struct FastSomeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Accessory apps cannot reliably present the SwiftUI Settings scene.
        // All entry points (⌘,, App menu, panel gear, status menu) use SettingsOpener.
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    SettingsOpener.open()
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
