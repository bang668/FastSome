import AppKit
import QuickLookThumbnailing
import SwiftUI

/// System Quick Look thumbnails for non-image clipboard files.
enum ClipboardQuickLook {
    private static let cache = NSCache<NSString, NSImage>()

    static func thumbnail(
        for url: URL,
        pointSize: CGSize,
        scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2
    ) async -> NSImage? {
        let key = "\(url.path)|\(Int(pointSize.width))x\(Int(pointSize.height))@\(scale)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: pointSize,
            scale: scale,
            representationTypes: .thumbnail
        )

        let cacheKey = String(key)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                let image = representation?.nsImage
                if let image {
                    cache.setObject(image, forKey: cacheKey as NSString)
                }
                continuation.resume(returning: image)
            }
        }
    }
}

/// Async Quick Look thumbnail; falls back to a document icon while loading / on failure.
struct ClipboardQuickLookThumbnailView: View {
    let url: URL?
    var pointSize: CGFloat = 22
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 4
    var placeholderSystemImage: String = "doc"

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Image(systemName: placeholderSystemImage)
                    .font(.system(size: max(11, pointSize * 0.55), weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: pointSize, height: pointSize)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url?.path) {
            image = nil
            guard let url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            image = await ClipboardQuickLook.thumbnail(
                for: url,
                pointSize: CGSize(width: pointSize, height: pointSize)
            )
        }
    }
}
