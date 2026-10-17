import XCTest
@testable import FastSome

@MainActor
final class LibraryStoreTests: XCTestCase {
    func testDefaultLibraryHasOneGroup() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fastsome-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = LibraryStore(fileURL: url)
        XCTAssertEqual(store.library.groups.count, 1)
        XCTAssertEqual(store.library.groups.first?.name, "默认")
        XCTAssertEqual(store.library.selectedGroupID, store.library.groups.first?.id)
    }

    func testCannotDeleteLastGroup() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fastsome-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = LibraryStore(fileURL: url)
        let id = try XCTUnwrap(store.library.groups.first?.id)
        store.deleteGroup(id)
        XCTAssertEqual(store.library.groups.count, 1)
    }

    func testMoveItemBetweenGroups() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fastsome-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = LibraryStore(fileURL: url)
        store.addGroup(named: "工作")
        let g1 = try XCTUnwrap(store.library.groups.first?.id)
        let g2 = try XCTUnwrap(store.library.groups.last?.id)

        // Create a fake bookmark from /tmp
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fastsome-item-\(UUID().uuidString).txt")
        try "x".write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }

        store.selectGroup(g1)
        store.addItems(from: [tmp])
        let itemID = try XCTUnwrap(store.selectedGroup?.items.first?.id)

        store.moveItem(itemID, toGroup: g2)
        XCTAssertTrue(store.library.groups.first(where: { $0.id == g1 })?.items.isEmpty == true)
        XCTAssertEqual(store.library.groups.first(where: { $0.id == g2 })?.items.first?.id, itemID)
    }
}
