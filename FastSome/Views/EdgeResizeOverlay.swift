import AppKit

/// Transparent overlay that lets users resize a borderless window by dragging its edges / corners.
final class EdgeResizeOverlay: NSView {
    private let thickness: CGFloat = 6
    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        resizeEdges(at: point).isEmpty ? nil : self
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        applyCursor(for: resizeEdges(at: point))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        applyCursor(for: resizeEdges(at: point))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let edges = resizeEdges(at: point)
        guard !edges.isEmpty, let window else { return }

        let startFrame = window.frame
        let startMouse = NSEvent.mouseLocation
        let minSize = window.minSize
        let maxSize = window.maxSize

        while true {
            guard let dragEvent = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: Date.distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { break }

            if dragEvent.type == NSEvent.EventType.leftMouseUp { break }

            let mouse = NSEvent.mouseLocation
            let dx = mouse.x - startMouse.x
            let dy = mouse.y - startMouse.y
            var frame = startFrame

            if edges.contains(.left) {
                let width = min(max(startFrame.width - dx, minSize.width), maxSize.width)
                frame.origin.x = startFrame.maxX - width
                frame.size.width = width
            } else if edges.contains(.right) {
                frame.size.width = min(max(startFrame.width + dx, minSize.width), maxSize.width)
            }

            if edges.contains(.bottom) {
                let height = min(max(startFrame.height - dy, minSize.height), maxSize.height)
                frame.origin.y = startFrame.maxY - height
                frame.size.height = height
            } else if edges.contains(.top) {
                frame.size.height = min(max(startFrame.height + dy, minSize.height), maxSize.height)
            }

            window.setFrame(frame, display: true)
        }

        NSCursor.arrow.set()
        // Notify controller so size is persisted for the active open source.
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: window)
    }

    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let top = Edges(rawValue: 1 << 2)
        static let bottom = Edges(rawValue: 1 << 3)
    }

    private func resizeEdges(at point: NSPoint) -> Edges {
        var edges: Edges = []
        if point.x <= thickness { edges.insert(.left) }
        if point.x >= bounds.width - thickness { edges.insert(.right) }
        if point.y <= thickness { edges.insert(.bottom) }
        if point.y >= bounds.height - thickness { edges.insert(.top) }
        return edges
    }

    private func applyCursor(for edges: Edges) {
        if edges.contains(.left) || edges.contains(.right),
           edges.contains(.top) || edges.contains(.bottom) {
            NSCursor.crosshair.set()
        } else if edges.contains(.left) || edges.contains(.right) {
            NSCursor.resizeLeftRight.set()
        } else if edges.contains(.top) || edges.contains(.bottom) {
            NSCursor.resizeUpDown.set()
        }
    }
}
