import Foundation

enum SystemEventsPaste {
    /// Posts ⌘V via System Events. `completion(failed)` — true means the script failed.
    static func postCommandV(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = [
                "-e",
                "tell application \"System Events\" to keystroke \"v\" using command down"
            ]
            do {
                try process.run()
                process.waitUntilExit()
                completion(process.terminationStatus != 0)
            } catch {
                completion(true)
            }
        }
    }
}
