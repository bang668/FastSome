import Foundation

enum ShortcutKind: String, Codable, CaseIterable, Sendable {
    case app
    case file
    case folder
}

struct ShortcutItem: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var displayName: String
    var kind: ShortcutKind
    var bookmarkData: Data

    init(id: UUID = UUID(), displayName: String, kind: ShortcutKind, bookmarkData: Data) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.bookmarkData = bookmarkData
    }
}

struct ShortcutGroup: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    var items: [ShortcutItem]

    init(id: UUID = UUID(), name: String, items: [ShortcutItem] = []) {
        self.id = id
        self.name = name
        self.items = items
    }
}

struct ShortcutLibrary: Codable, Equatable, Sendable {
    var groups: [ShortcutGroup]
    var selectedGroupID: UUID?

    static var empty: ShortcutLibrary {
        let group = ShortcutGroup(name: "默认")
        return ShortcutLibrary(groups: [group], selectedGroupID: group.id)
    }
}
