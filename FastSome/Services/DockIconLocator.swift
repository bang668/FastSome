import AppKit
import ApplicationServices

/// Resolves the on-screen frame of this app's Dock icon (Cocoa bottom-left coords).
@MainActor
enum DockIconLocator {
    enum DockEdge {
        case bottom, left, right
    }

    static var dockEdge: DockEdge {
        switch UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") {
        case "left": return .left
        case "right": return .right
        default: return .bottom
        }
    }

    /// Best-effort Dock icon frame. Falls back to mouse location + Dock edge.
    static func iconFrame() -> CGRect? {
        if let ax = accessibilityIconFrame() {
            return ax
        }
        return fallbackFrameNearMouse()
    }

    private static func accessibilityIconFrame() -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }

        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "FastSome"
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)

        guard let list = firstListChild(of: dockElement) else { return nil }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(list, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement]
        else { return nil }

        for child in children {
            var titleRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef) == .success,
                  let title = titleRef as? String,
                  title == appName
            else { continue }

            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef) == .success,
                  AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef) == .success,
                  let posValue = posRef,
                  let sizeValue = sizeRef
            else { continue }

            var axPoint = CGPoint.zero
            var axSize = CGSize.zero
            guard AXValueGetValue(posValue as! AXValue, .cgPoint, &axPoint),
                  AXValueGetValue(sizeValue as! AXValue, .cgSize, &axSize)
            else { continue }

            // Accessibility uses top-left origin relative to the primary display.
            return cocoaRect(fromAXOrigin: axPoint, size: axSize)
        }
        return nil
    }

    private static func firstListChild(of element: AXUIElement) -> AXUIElement? {
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement],
              let first = children.first
        else { return nil }
        return first
    }

    private static func cocoaRect(fromAXOrigin origin: CGPoint, size: CGSize) -> CGRect {
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main
        let screenHeight = primary?.frame.maxY ?? (NSScreen.main?.frame.maxY ?? 0)
        let cocoaY = screenHeight - origin.y - size.height
        return CGRect(x: origin.x, y: cocoaY, width: size.width, height: size.height)
    }

    private static func fallbackFrameNearMouse() -> CGRect? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return nil }
        // Approximate a Dock-tile-sized rect around the click.
        let tile: CGFloat = 48
        switch dockEdge {
        case .bottom:
            return CGRect(x: mouse.x - tile / 2, y: screen.frame.minY + 4, width: tile, height: tile)
        case .left:
            return CGRect(x: screen.frame.minX + 4, y: mouse.y - tile / 2, width: tile, height: tile)
        case .right:
            return CGRect(x: screen.frame.maxX - tile - 4, y: mouse.y - tile / 2, width: tile, height: tile)
        }
    }
}
