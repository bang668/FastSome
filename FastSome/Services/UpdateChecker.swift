import AppKit
import Foundation

enum UpdateCheckOutcome: Equatable {
    case upToDate(current: String)
    case updateAvailable(current: String, latest: String, releaseURL: URL)
    case failed(String)
}

struct AvailableAppUpdate: Equatable {
    var latest: String
    var releaseURL: URL
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let repository = "bang668/FastSome"
    private static let apiURL = URL(string: "https://api.github.com/repos/bang668/FastSome/releases/latest")!

    /// Set when a newer GitHub release is found; drives the About page CTA.
    @Published private(set) var availableUpdate: AvailableAppUpdate?

    private init() {}

    nonisolated static func localVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Ascending means `lhs` is older than `rhs`.
    nonisolated static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionParts(lhs)
        let right = versionParts(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return .orderedSame
    }

    func check() async -> UpdateCheckOutcome {
        let outcome = await Self.fetchLatest()
        switch outcome {
        case .updateAvailable(_, let latest, let releaseURL):
            availableUpdate = AvailableAppUpdate(latest: latest, releaseURL: releaseURL)
        case .upToDate:
            availableUpdate = nil
        case .failed:
            break
        }
        return outcome
    }

    func openAvailableUpdate() {
        guard let availableUpdate else { return }
        NSWorkspace.shared.open(availableUpdate.releaseURL)
    }

    /// Error alert for interactive checks. Update-available is shown inline on About.
    static func presentFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "检查更新失败"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    func scheduleLaunchCheck(delaySeconds: TimeInterval = 12) {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            _ = await check()
        }
    }

    private static func fetchLatest() async -> UpdateCheckOutcome {
        let current = localVersion()
        var request = URLRequest(url: apiURL)
        request.setValue("FastSome/\(current)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                return .failed("无法获取更新信息（\(http.statusCode)）。")
            }
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latest = normalizeTag(release.tagName)
            guard let page = URL(string: release.htmlURL) else {
                return .failed("更新地址无效。")
            }
            if compareVersions(current, latest) == .orderedAscending {
                return .updateAvailable(current: current, latest: latest, releaseURL: page)
            }
            return .upToDate(current: current)
        } catch {
            return .failed("检查更新失败，请稍后再试。")
        }
    }

    nonisolated private static func normalizeTag(_ tag: String) -> String {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "v" || value.first == "V" {
            value.removeFirst()
        }
        return value
    }

    nonisolated private static func versionParts(_ raw: String) -> [Int] {
        let trimmed = normalizeTag(raw)
        return trimmed.split(separator: ".").map { piece in
            let digits = piece.prefix(while: { $0.isNumber })
            return Int(digits) ?? 0
        }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }
}
