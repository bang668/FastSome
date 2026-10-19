import Foundation

enum ClipboardItemKind: String, Codable, Sendable, CaseIterable {
    case text
    case image
    case file

    var title: String {
        switch self {
        case .text: return "文本"
        case .image: return "图片"
        case .file: return "文件"
        }
    }

    var systemImage: String {
        switch self {
        case .text: return "textformat"
        case .image: return "photo"
        case .file: return "doc"
        }
    }
}

enum ClipboardSelectionAction: String, Codable, Sendable, CaseIterable, Identifiable {
    case paste
    case copyOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .paste: return "直接粘贴"
        case .copyOnly: return "写入剪贴板"
        }
    }

    var settingsHint: String {
        switch self {
        case .paste:
            return "选中后直接粘贴到当前输入位置（需要辅助功能权限）。"
        case .copyOnly:
            return "选中后只写入系统剪贴板，不会自动粘贴。"
        }
    }
}

struct ClipboardHistoryItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var kind: ClipboardItemKind
    var createdAt: Date
    var sourceAppName: String?
    var sourceBundleID: String?
    var summary: String
    var contentHash: String

    /// Plain text body when `kind == .text`.
    var text: String?
    var characterCount: Int?

    /// Relative file name under the store's `images/` directory.
    var imageFileName: String?
    var imagePixelWidth: Int?
    var imagePixelHeight: Int?
    var byteSize: Int?

    /// Security-scoped bookmark and display path for file items.
    var fileBookmarkData: Data?
    var filePath: String?

    init(
        id: UUID = UUID(),
        kind: ClipboardItemKind,
        createdAt: Date = Date(),
        sourceAppName: String? = nil,
        sourceBundleID: String? = nil,
        summary: String,
        contentHash: String,
        text: String? = nil,
        characterCount: Int? = nil,
        imageFileName: String? = nil,
        imagePixelWidth: Int? = nil,
        imagePixelHeight: Int? = nil,
        byteSize: Int? = nil,
        fileBookmarkData: Data? = nil,
        filePath: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.sourceAppName = sourceAppName
        self.sourceBundleID = sourceBundleID
        self.summary = summary
        self.contentHash = contentHash
        self.text = text
        self.characterCount = characterCount
        self.imageFileName = imageFileName
        self.imagePixelWidth = imagePixelWidth
        self.imagePixelHeight = imagePixelHeight
        self.byteSize = byteSize
        self.fileBookmarkData = fileBookmarkData
        self.filePath = filePath
    }
}

struct ClipboardHistoryIndex: Codable, Equatable, Sendable {
    var items: [ClipboardHistoryItem]
    /// Local calendar days (`yyyy-MM-dd`) on which at least one capture was recorded.
    /// Retention counts these usage days, not wall-clock days away from the Mac.
    var usageDayKeys: [String]

    static let empty = ClipboardHistoryIndex(items: [], usageDayKeys: [])

    init(items: [ClipboardHistoryItem], usageDayKeys: [String] = []) {
        self.items = items
        self.usageDayKeys = usageDayKeys
    }

    private enum CodingKeys: String, CodingKey {
        case items
        case usageDayKeys
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decode([ClipboardHistoryItem].self, forKey: .items)
        usageDayKeys = try container.decodeIfPresent([String].self, forKey: .usageDayKeys) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        try container.encode(usageDayKeys, forKey: .usageDayKeys)
    }
}
