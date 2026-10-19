import AppKit
import Combine
import Foundation

@MainActor
final class ClipboardHistoryMonitor {
    static let shared = ClipboardHistoryMonitor()

    private var timer: Timer?
    private var lastChangeCount: Int = -1
    private var isEnabled = false

    private init() {}

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        if enabled {
            start()
        } else {
            stop()
        }
    }

    func applyRetentionFromSettings() {
        let settings = AppSettings.shared
        ClipboardHistoryStore.shared.applyRetention(
            maxItems: settings.clipboardMaxItems,
            retentionDays: settings.clipboardRetentionDays
        )
    }

    private func start() {
        stop()
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        applyRetentionFromSettings()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard isEnabled else { return }
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        _ = ClipboardHistoryStore.shared.recordFromPasteboard(pb)
    }
}
