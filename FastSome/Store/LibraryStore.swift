import AppKit
import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var library: ShortcutLibrary

    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL? = nil) {
        let fm = FileManager.default
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = support.appendingPathComponent("FastSome", isDirectory: true)
            let legacy = support.appendingPathComponent("FastIcon", isDirectory: true)
            if !fm.fileExists(atPath: dir.path), fm.fileExists(atPath: legacy.path) {
                try? fm.moveItem(at: legacy, to: dir)
            }
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            self.fileURL = dir.appendingPathComponent("library.json")
        }

        if FileManager.default.fileExists(atPath: self.fileURL.path) {
            do {
                let data = try Data(contentsOf: self.fileURL)
                let decoded = try decoder.decode(ShortcutLibrary.self, from: data)
                // Keep whatever was on disk (even empty groups); never wipe silently.
                library = decoded.groups.isEmpty ? .empty : decoded
                if decoded.groups.isEmpty {
                    persist()
                }
            } catch {
                // Corrupt file: keep a timestamped backup and start fresh.
                let backup = self.fileURL.deletingPathExtension()
                    .appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: self.fileURL, to: backup)
                NSLog("FastSome: failed to load library.json (\(error.localizedDescription)); backed up to \(backup.lastPathComponent)")
                library = .empty
                persist()
            }
        } else {
            library = .empty
            persist()
        }
        ensureSelection()
    }

    var selectedGroup: ShortcutGroup? {
        library.groups.first(where: { $0.id == library.selectedGroupID }) ?? library.groups.first
    }

    func selectGroup(_ id: UUID) {
        library.selectedGroupID = id
        persist()
    }

    func addItems(from urls: [URL]) {
        guard var group = selectedGroup, let index = library.groups.firstIndex(where: { $0.id == group.id }) else { return }
        for url in urls {
            guard let bookmark = try? url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            ) else { continue }
            let kind = Self.kind(for: url)
            let name = url.deletingPathExtension().lastPathComponent
            let item = ShortcutItem(displayName: name.isEmpty ? url.lastPathComponent : name, kind: kind, bookmarkData: bookmark)
            group.items.append(item)
        }
        library.groups[index] = group
        persist()
    }

    func removeItem(_ itemID: UUID) {
        guard let gIndex = library.groups.firstIndex(where: { $0.id == library.selectedGroupID }) else { return }
        library.groups[gIndex].items.removeAll { $0.id == itemID }
        invalidateIcon(for: itemID)
        persist()
    }

    func moveItem(fromOffsets: IndexSet, toOffset: Int) {
        guard let gIndex = library.groups.firstIndex(where: { $0.id == library.selectedGroupID }) else { return }
        library.groups[gIndex].items.move(fromOffsets: fromOffsets, toOffset: toOffset)
        persist()
    }

    func reorderItem(itemID: UUID, to index: Int) {
        reorderItem(itemID: itemID, toInsertIndex: index)
    }

    /// Insert `itemID` at `rawInsert` in the selected group (0 = before first, count = after last).
    func reorderItem(itemID: UUID, toInsertIndex rawInsert: Int) {
        guard let gIndex = library.groups.firstIndex(where: { $0.id == library.selectedGroupID }) else { return }
        guard let from = library.groups[gIndex].items.firstIndex(where: { $0.id == itemID }) else { return }
        var items = library.groups[gIndex].items
        let item = items.remove(at: from)
        var destination = rawInsert
        if from < rawInsert {
            destination -= 1
        }
        destination = min(max(0, destination), items.count)
        items.insert(item, at: destination)
        guard items.map(\.id) != library.groups[gIndex].items.map(\.id) else { return }
        library.groups[gIndex].items = items
        persist()
    }

    func moveItem(_ itemID: UUID, toGroup groupID: UUID) {
        guard let fromIndex = library.groups.firstIndex(where: { $0.items.contains(where: { $0.id == itemID }) }) else { return }
        guard let toIndex = library.groups.firstIndex(where: { $0.id == groupID }) else { return }
        guard fromIndex != toIndex else { return }
        guard let itemIndex = library.groups[fromIndex].items.firstIndex(where: { $0.id == itemID }) else { return }
        let item = library.groups[fromIndex].items.remove(at: itemIndex)
        library.groups[toIndex].items.append(item)
        library.selectedGroupID = groupID
        persist()
    }

    func addGroup(named name: String) {
        let group = ShortcutGroup(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新分组" : name)
        library.groups.append(group)
        library.selectedGroupID = group.id
        persist()
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = library.groups.firstIndex(where: { $0.id == id }) else { return }
        library.groups[index].name = trimmed
        persist()
    }

    func deleteGroup(_ id: UUID) {
        guard library.groups.count > 1 else { return }
        library.groups.removeAll { $0.id == id }
        if library.selectedGroupID == id {
            library.selectedGroupID = library.groups.first?.id
        }
        persist()
    }

    /// Move `groupID` so it lands at the position currently occupied by `targetID`.
    func reorderGroup(groupID: UUID, toTarget targetID: UUID) {
        guard groupID != targetID else { return }
        guard let from = library.groups.firstIndex(where: { $0.id == groupID }),
              let to = library.groups.firstIndex(where: { $0.id == targetID })
        else { return }
        reorderGroup(groupID: groupID, toInsertIndex: to)
    }

    /// Insert `groupID` at `rawInsert` in the current array (0 = before first, count = after last).
    /// Indices are relative to the order **before** removing the dragged group.
    func reorderGroup(groupID: UUID, toInsertIndex rawInsert: Int) {
        guard let from = library.groups.firstIndex(where: { $0.id == groupID }) else { return }
        var groups = library.groups
        let group = groups.remove(at: from)
        var destination = rawInsert
        if from < rawInsert {
            destination -= 1
        }
        destination = min(max(0, destination), groups.count)
        groups.insert(group, at: destination)
        guard groups.map(\.id) != library.groups.map(\.id) else { return }
        library.groups = groups
        persist()
    }

    func resolveURL(for item: ShortcutItem) -> URL? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: item.bookmarkData,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        if isStale {
            refreshBookmarkIfPossible(for: item.id, url: url)
        }
        return url
    }

    private func refreshBookmarkIfPossible(for itemID: UUID, url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        guard let gIndex = library.groups.firstIndex(where: { $0.items.contains(where: { $0.id == itemID }) }),
              let iIndex = library.groups[gIndex].items.firstIndex(where: { $0.id == itemID })
        else { return }
        library.groups[gIndex].items[iIndex].bookmarkData = data
        invalidateIcon(for: itemID)
        persist()
    }

    /// Cached so SwiftUI redraws (e.g. group-tab drag) reuse the same NSImage instance.
    private var iconCache: [UUID: NSImage] = [:]

    func icon(for item: ShortcutItem) -> NSImage {
        if let cached = iconCache[item.id] { return cached }
        let image: NSImage
        if let url = resolveURL(for: item) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "questionmark.square.dashed", accessibilityDescription: nil)
                ?? NSImage(size: NSSize(width: 64, height: 64))
        }
        iconCache[item.id] = image
        return image
    }

    func invalidateIcon(for itemID: UUID) {
        iconCache.removeValue(forKey: itemID)
    }

    func invalidateAllIcons() {
        iconCache.removeAll(keepingCapacity: true)
    }

    func persist() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(library) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func ensureSelection() {
        if library.selectedGroupID == nil || !library.groups.contains(where: { $0.id == library.selectedGroupID }) {
            library.selectedGroupID = library.groups.first?.id
            persist()
        }
    }

    static func kind(for url: URL) -> ShortcutKind {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
        if url.pathExtension == "app" || (isDirectory.boolValue && url.path.hasSuffix(".app")) {
            return .app
        }
        if isDirectory.boolValue {
            return .folder
        }
        return .file
    }
}
