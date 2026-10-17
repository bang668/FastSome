import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let store = LibraryStore()
    let settings = AppSettings.shared

    @Published var isEditing = false
    @Published var commandKeyHeld = false
    @Published var missingItemIDs: Set<UUID> = []
    /// Group tab under the pointer while a shortcut icon is being drag-reordered.
    @Published var itemDragHoverGroupID: UUID?

    private init() {}

    func refreshMissingFlags() {
        var missing: Set<UUID> = []
        for group in store.library.groups {
            for item in group.items {
                if store.resolveURL(for: item) == nil {
                    missing.insert(item.id)
                }
            }
        }
        missingItemIDs = missing
    }
}
