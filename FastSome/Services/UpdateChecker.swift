import AppKit
import Foundation

enum UpdateCheckOutcome: Equatable {
    case upToDate(current: String)
    case updateAvailable(current: String, latest: String, releaseURL: URL, dmgURL: URL)
    case failed(String)
}

struct AvailableAppUpdate: Equatable {
    var latest: String
    var releaseURL: URL
    var dmgURL: URL
}

@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    static let repository = "bang668/FastSome"
    static let homepageURL = URL(string: "https://github.com/bang668/FastSome")!
    private static let apiURL = URL(string: "https://api.github.com/repos/bang668/FastSome/releases/latest")!

    /// Set when a newer GitHub release is found; drives the About page CTA.
    @Published private(set) var availableUpdate: AvailableAppUpdate?

    @Published private(set) var isDownloading = false
    /// 0...1 while downloading.
    @Published private(set) var downloadProgress: Double = 0

    var downloadPercentLabel: String {
        "\(Int((downloadProgress * 100).rounded()))%"
    }

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
        case .updateAvailable(_, let latest, let releaseURL, let dmgURL):
            availableUpdate = AvailableAppUpdate(latest: latest, releaseURL: releaseURL, dmgURL: dmgURL)
        case .upToDate:
            availableUpdate = nil
        case .failed:
            break
        }
        return outcome
    }

    /// Downloads the release DMG, opens it (Finder install window), then quits.
    func downloadAndInstall() async {
        guard let update = availableUpdate, !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        defer {
            isDownloading = false
            downloadProgress = 0
        }

        do {
            let localDMG = try await Self.downloadDMG(from: update.dmgURL) { [weak self] fraction in
                Task { @MainActor in
                    self?.downloadProgress = fraction
                }
            }
            downloadProgress = 1
            let opened = NSWorkspace.shared.open(localDMG)
            guard opened else {
                Self.presentFailure("无法打开安装包，请稍后再试。", title: "更新失败")
                return
            }
            // Let Finder mount/present the DMG before we exit.
            try? await Task.sleep(nanoseconds: 400_000_000)
            NSApp.terminate(nil)
        } catch {
            Self.presentFailure("下载失败，请检查网络后重试。", title: "更新失败")
        }
    }

    /// Error alert for interactive checks / downloads.
    static func presentFailure(_ message: String, title: String = "检查更新失败") {
        let alert = NSAlert()
        alert.messageText = title
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
            guard compareVersions(current, latest) == .orderedAscending else {
                return .upToDate(current: current)
            }
            guard let dmgURL = pickDMGURL(from: release.assets) else {
                return .failed("新版本没有 DMG 安装包。")
            }
            return .updateAvailable(current: current, latest: latest, releaseURL: page, dmgURL: dmgURL)
        } catch {
            return .failed("检查更新失败，请稍后再试。")
        }
    }

    private static func pickDMGURL(from assets: [GitHubAsset]) -> URL? {
        let dmgs = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let preferred = dmgs.first { $0.name.lowercased().contains("fastsome") } ?? dmgs.first
        guard let preferred, let url = URL(string: preferred.browserDownloadURL) else { return nil }
        return url
    }

    private static func downloadDMG(
        from remote: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let bridge = DownloadBridge(onProgress: onProgress)
        return try await bridge.download(from: remote)
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
        let assets: [GitHubAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }
    }

    private struct GitHubAsset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

/// URLSession download with fraction progress; copies the temp file to a stable path.
private final class DownloadBridge: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let onProgress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var settled = false

    init(onProgress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = onProgress
    }

    func download(from url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 60 * 30
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            var request = URLRequest(url: url)
            request.setValue("FastSome", forHTTPHeaderField: "User-Agent")
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let name = downloadTask.response?.suggestedFilename ?? "FastSome-update.dmg"
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: location, to: dest)
            finish(.success(dest))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !settled else { return }
        settled = true
        session?.finishTasksAndInvalidate()
        session = nil
        switch result {
        case .success(let url):
            continuation?.resume(returning: url)
        case .failure(let error):
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }
}
