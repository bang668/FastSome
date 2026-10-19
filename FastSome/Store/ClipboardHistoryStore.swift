import AppKit
import Combine
import CryptoKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    @Published private(set) var items: [ClipboardHistoryItem] = []
    /// Sorted ascending local day keys (`yyyy-MM-dd`) with at least one capture.
    private var usageDayKeys: [String] = []

    private let rootDirectory: URL
    private let indexURL: URL
    private let imagesDirectory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// While > 0, pasteboard changes are treated as our own writes.
    private var ignoreOwnWritesDepth = 0
    private var ignoreUntil: Date?
    private let listThumbnailCache = NSCache<NSString, NSImage>()

    static let maxImageBytes = 10 * 1024 * 1024
    static let maxSummaryLength = 120
    static let listThumbnailSide: CGFloat = 36

    init(rootDirectory: URL? = nil) {
        let fm = FileManager.default
        if let rootDirectory {
            self.rootDirectory = rootDirectory
        } else {
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.rootDirectory = support
                .appendingPathComponent("FastSome", isDirectory: true)
                .appendingPathComponent("ClipboardHistory", isDirectory: true)
        }
        indexURL = self.rootDirectory.appendingPathComponent("index.json")
        imagesDirectory = self.rootDirectory.appendingPathComponent("images", isDirectory: true)

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        try? fm.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        load()
    }

    var isIgnoringOwnWrites: Bool {
        if ignoreOwnWritesDepth > 0 { return true }
        if let ignoreUntil, Date() < ignoreUntil { return true }
        return false
    }

    func beginIgnoringOwnWrites(duration: TimeInterval = 1.2) {
        ignoreOwnWritesDepth += 1
        ignoreUntil = Date().addingTimeInterval(duration)
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            self.ignoreOwnWritesDepth = max(0, self.ignoreOwnWritesDepth - 1)
        }
    }

    func load() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            items = []
            usageDayKeys = []
            return
        }
        do {
            let data = try Data(contentsOf: indexURL)
            let index = try decoder.decode(ClipboardHistoryIndex.self, from: data)
            items = index.items
            usageDayKeys = index.usageDayKeys
            if usageDayKeys.isEmpty, !items.isEmpty {
                usageDayKeys = Self.usageDayKeys(from: items)
            }
        } catch {
            let backup = indexURL.deletingPathExtension()
                .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: indexURL, to: backup)
            NSLog("FastSome: clipboard history load failed (\(error.localizedDescription)); backed up")
            items = []
            usageDayKeys = []
            persist()
        }
    }

    func persist() {
        let index = ClipboardHistoryIndex(items: items, usageDayKeys: usageDayKeys)
        do {
            let data = try encoder.encode(index)
            try data.write(to: indexURL, options: .atomic)
        } catch {
            NSLog("FastSome: clipboard history save failed (\(error.localizedDescription))")
        }
    }

    func applyRetention(maxItems: Int, retentionDays: Int) {
        let limit = max(1, retentionDays)
        if usageDayKeys.isEmpty, !items.isEmpty {
            usageDayKeys = Self.usageDayKeys(from: items)
        }
        let previousDays = usageDayKeys
        let keptDayKeys = Set(previousDays.suffix(limit))
        usageDayKeys = Array(previousDays.suffix(limit))

        var kept = items.filter { keptDayKeys.contains(Self.dayKey(for: $0.createdAt)) }
        if kept.count > maxItems {
            kept = Array(kept.prefix(max(1, maxItems)))
        }
        let removed = items.filter { item in !kept.contains(where: { $0.id == item.id }) }
        for item in removed {
            removeImageFile(for: item)
        }
        if kept.map(\.id) != items.map(\.id) || usageDayKeys != previousDays {
            items = kept
            persist()
        }
    }

    @discardableResult
    func recordFromPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard !isIgnoringOwnWrites else { return false }
        guard let captured = Self.capture(from: pasteboard) else { return false }

        if let first = items.first, first.contentHash == captured.contentHash {
            var updated = first
            updated.createdAt = Date()
            items[0] = updated
            markUsageDay(updated.createdAt)
            let settings = AppSettings.shared
            applyRetention(maxItems: settings.clipboardMaxItems, retentionDays: settings.clipboardRetentionDays)
            persist()
            return true
        }

        var item = captured.item
        if let imageData = captured.imageData {
            let ext = captured.imageExtension ?? "png"
            let name = "\(item.id.uuidString).\(ext)"
            let url = imagesDirectory.appendingPathComponent(name)
            do {
                try imageData.write(to: url, options: .atomic)
                item.imageFileName = name
            } catch {
                NSLog("FastSome: failed to store clipboard image (\(error.localizedDescription))")
                return false
            }
        }

        items.insert(item, at: 0)
        markUsageDay(item.createdAt)
        let settings = AppSettings.shared
        applyRetention(maxItems: settings.clipboardMaxItems, retentionDays: settings.clipboardRetentionDays)
        persist()
        return true
    }


    private func markUsageDay(_ date: Date) {
        let key = Self.dayKey(for: date)
        if usageDayKeys.contains(key) { return }
        usageDayKeys.append(key)
        usageDayKeys.sort()
    }

    private static func dayKey(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let y = parts.year ?? 0
        let m = parts.month ?? 0
        let d = parts.day ?? 0
        return String(format: "%04d-%02d-%02d", y, m, d)
    }

    private static func usageDayKeys(from items: [ClipboardHistoryItem]) -> [String] {
        Array(Set(items.map { dayKey(for: $0.createdAt) })).sorted()
    }

    func item(id: UUID) -> ClipboardHistoryItem? {
        items.first { $0.id == id }
    }

    func deleteItem(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        removeImageFile(for: item)
        listThumbnailCache.removeObject(forKey: item.id.uuidString as NSString)
        persist()
    }

    func imageURL(for item: ClipboardHistoryItem) -> URL? {
        guard let name = item.imageFileName else { return nil }
        let url = imagesDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func nsImage(for item: ClipboardHistoryItem) -> NSImage? {
        if let url = imageURL(for: item), let image = NSImage(contentsOf: url) {
            return image
        }
        // Image files recorded as `.file`, or images that still have a source path.
        if let url = resolvedFileURL(for: item), Self.isImageFileURL(url) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return NSImage(contentsOf: url)
        }
        return nil
    }

    /// Small square thumbnail for the left list. Cached per item id.
    func listThumbnail(for item: ClipboardHistoryItem) -> NSImage? {
        guard Self.isImageFileItem(item) else { return nil }
        let key = item.id.uuidString as NSString
        if let cached = listThumbnailCache.object(forKey: key) {
            return cached
        }
        guard let image = nsImage(for: item) else { return nil }
        let thumb = Self.makeListThumbnail(from: image, side: Self.listThumbnailSide)
        listThumbnailCache.setObject(thumb, forKey: key)
        return thumb
    }

    private static func makeListThumbnail(from image: NSImage, side: CGFloat) -> NSImage {
        let target = NSSize(width: side, height: side)
        let out = NSImage(size: target)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let srcSize = image.size
        guard srcSize.width > 0, srcSize.height > 0 else {
            out.unlockFocus()
            return out
        }
        let scale = max(side / srcSize.width, side / srcSize.height)
        let drawSize = NSSize(width: srcSize.width * scale, height: srcSize.height * scale)
        let origin = NSPoint(
            x: (side - drawSize.width) / 2,
            y: (side - drawSize.height) / 2
        )
        image.draw(
            in: NSRect(origin: origin, size: drawSize),
            from: NSRect(origin: .zero, size: srcSize),
            operation: .copy,
            fraction: 1
        )
        out.unlockFocus()
        return out
    }

    static func isImageFileURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        let known: Set<String> = [
            "png", "jpg", "jpeg", "gif", "webp", "tiff", "tif", "heic", "heif", "bmp"
        ]
        if known.contains(ext) { return true }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) {
            return true
        }
        return false
    }

    static func isImageFileItem(_ item: ClipboardHistoryItem) -> Bool {
        if item.kind == .image { return true }
        guard let path = item.filePath else { return false }
        return isImageFileURL(URL(fileURLWithPath: path))
    }

    func resolvedFileURL(for item: ClipboardHistoryItem) -> URL? {
        if let data = item.fileBookmarkData {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url
            }
        }
        if let path = item.filePath {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Writes the item onto the general pasteboard. Marks own-write ignore.
    func writeToPasteboard(_ item: ClipboardHistoryItem) -> Bool {
        beginIgnoringOwnWrites()
        let pb = NSPasteboard.general
        pb.clearContents()

        switch item.kind {
        case .text:
            guard let text = item.text else { return false }
            return pb.setString(text, forType: .string)
        case .image:
            // Prefer original file when this image was copied from Finder.
            if let fileURL = resolvedFileURL(for: item),
               FileManager.default.fileExists(atPath: fileURL.path) {
                return pb.writeObjects([fileURL as NSURL])
            }
            return writeStoredImageData(for: item, to: pb)
        case .file:
            guard let url = resolvedFileURL(for: item) else { return false }
            return pb.writeObjects([url as NSURL])
        }
    }

    /// Writes the on-disk image bytes in their original format (png/tiff/jpeg…), not re-encoded.
    private func writeStoredImageData(for item: ClipboardHistoryItem, to pb: NSPasteboard) -> Bool {
        guard let url = imageURL(for: item),
              let data = try? Data(contentsOf: url) else { return false }
        let jpegType = NSPasteboard.PasteboardType("public.jpeg")
        switch url.pathExtension.lowercased() {
        case "png":
            return pb.setData(data, forType: .png)
        case "tif", "tiff":
            return pb.setData(data, forType: .tiff)
        case "jpg", "jpeg":
            return pb.setData(data, forType: jpegType)
        default:
            // Last resort: let AppKit publish whatever representation it can.
            guard let image = NSImage(data: data) else { return false }
            return pb.writeObjects([image])
        }
    }

    func matches(_ item: ClipboardHistoryItem, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }

        // Files: filename only — never full path / directory / source app.
        if item.kind == .file {
            if item.summary.lowercased().contains(q) { return true }
            if let path = item.filePath, !path.isEmpty {
                return (path as NSString).lastPathComponent.lowercased().contains(q)
            }
            return false
        }

        if item.summary.lowercased().contains(q) { return true }
        // Cap body scan — huge paste payloads must not freeze/crash the search path.
        if let text = item.text {
            let sample = text.count > 8_000 ? String(text.prefix(8_000)) : text
            if sample.lowercased().contains(q) { return true }
        }
        if let app = item.sourceAppName?.lowercased(), app.contains(q) { return true }
        return false
    }

    private func removeImageFile(for item: ClipboardHistoryItem) {
        guard let name = item.imageFileName else { return }
        let url = imagesDirectory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
    }

    private struct CaptureResult {
        var item: ClipboardHistoryItem
        /// Original image bytes to persist (same format as `imageExtension`).
        var imageData: Data?
        var imageExtension: String?
        var contentHash: String { item.contentHash }
    }

    private static func capture(from pasteboard: NSPasteboard) -> CaptureResult? {
        let front = NSWorkspace.shared.frontmostApplication
        let appName = front?.localizedName
        let bundleID = front?.bundleIdentifier

        // File URLs first. Finder / Office often also put a preview TIFF/PNG on the
        // pasteboard when copying a document — preferring bitmap mis-labels Word as 图片.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], let url = urls.first, url.isFileURL {
            return captureFile(url: url, appName: appName, bundleID: bundleID)
        }

        // Screenshots / "Copy Image" — keep original pasteboard bytes (png/tiff).
        if let captured = captureBitmap(from: pasteboard, appName: appName, bundleID: bundleID) {
            return captured
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            return captureText(text, appName: appName, bundleID: bundleID)
        }

        return nil
    }

    private static func captureText(
        _ text: String,
        appName: String?,
        bundleID: String?
    ) -> CaptureResult {
        let summary = summarize(text)
        let hash = sha256("text|" + text)
        let item = ClipboardHistoryItem(
            kind: .text,
            sourceAppName: appName,
            sourceBundleID: bundleID,
            summary: summary,
            contentHash: hash,
            text: text,
            characterCount: text.count,
            byteSize: text.utf8.count
        )
        return CaptureResult(item: item, imageData: nil)
    }

    /// Bitmap clipboard: prefer original PNG/TIFF bytes — do not re-encode to PNG.
    private static func captureBitmap(
        from pasteboard: NSPasteboard,
        appName: String?,
        bundleID: String?
    ) -> CaptureResult? {
        let jpegType = NSPasteboard.PasteboardType("public.jpeg")
        if let png = pasteboard.data(forType: .png), !png.isEmpty {
            return makeBitmapItem(data: png, ext: "png", appName: appName, bundleID: bundleID)
        }
        if let jpeg = pasteboard.data(forType: jpegType), !jpeg.isEmpty {
            return makeBitmapItem(data: jpeg, ext: "jpg", appName: appName, bundleID: bundleID)
        }
        if let tiff = pasteboard.data(forType: .tiff), !tiff.isEmpty {
            return makeBitmapItem(data: tiff, ext: "tiff", appName: appName, bundleID: bundleID)
        }
        return nil
    }

    private static func makeBitmapItem(
        data: Data,
        ext: String,
        appName: String?,
        bundleID: String?
    ) -> CaptureResult? {
        guard data.count <= maxImageBytes else { return nil }
        let image = NSImage(data: data)
        let pixelW = image.flatMap { img -> Int? in
            guard let rep = img.representations.first else { return nil }
            return rep.pixelsWide
        }
        let pixelH = image.flatMap { img -> Int? in
            guard let rep = img.representations.first else { return nil }
            return rep.pixelsHigh
        }
        let sizeLabel: String = {
            if let pixelW, let pixelH, pixelW > 0, pixelH > 0 {
                return "图片 · \(pixelW)×\(pixelH)"
            }
            return "图片"
        }()
        let hash = sha256Data(data)
        let item = ClipboardHistoryItem(
            kind: .image,
            sourceAppName: appName,
            sourceBundleID: bundleID,
            summary: sizeLabel,
            contentHash: hash,
            imagePixelWidth: pixelW,
            imagePixelHeight: pixelH,
            byteSize: data.count
        )
        return CaptureResult(item: item, imageData: data, imageExtension: ext)
    }

    private static func captureFile(
        url: URL,
        appName: String?,
        bundleID: String?
    ) -> CaptureResult? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return nil }

        let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let size = values?.fileSize
        let name = url.lastPathComponent

        // Image files: keep as file references so paste returns the original file/format.
        // Preview loads from the path (or QL); no format conversion on ingest.
        if isImageFileURL(url) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            var pixelW: Int?
            var pixelH: Int?
            if let image = NSImage(contentsOf: url),
               let rep = image.representations.first {
                pixelW = rep.pixelsWide
                pixelH = rep.pixelsHigh
            }
            let hash = sha256("file-image|" + url.path + "|" + String(size ?? -1))
            let item = ClipboardHistoryItem(
                kind: .file,
                sourceAppName: appName,
                sourceBundleID: bundleID,
                summary: name,
                contentHash: hash,
                imagePixelWidth: pixelW,
                imagePixelHeight: pixelH,
                byteSize: size,
                fileBookmarkData: bookmark,
                filePath: url.path
            )
            return CaptureResult(item: item, imageData: nil, imageExtension: nil)
        }

        let hash = sha256("file|" + url.path + "|" + String(size ?? -1))
        let item = ClipboardHistoryItem(
            kind: .file,
            sourceAppName: appName,
            sourceBundleID: bundleID,
            summary: name,
            contentHash: hash,
            byteSize: size,
            fileBookmarkData: bookmark,
            filePath: url.path
        )
        return CaptureResult(item: item, imageData: nil, imageExtension: nil)
    }

    private static func summarize(_ text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= maxSummaryLength { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: maxSummaryLength)
        return String(collapsed[..<end]) + "…"
    }

    private static func sha256(_ string: String) -> String {
        sha256Data(Data(string.utf8))
    }

    private static func sha256Data(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func formatByteSize(_ bytes: Int?) -> String? {
        guard let bytes else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
