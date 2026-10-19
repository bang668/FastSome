import AppKit
import QuartzCore

/// Click-through stroke that follows the pointer across displays.
@MainActor
final class DesktopSwipeTrail {
    private(set) var isShowing = false
    private(set) var isFading = false

    private var window: NSWindow?
    private var canvas: TrailCanvas?
    private var points: [CGPoint] = []
    private var label: String?
    private var fadeGeneration = 0

    func prepare() {
        let window = ensureWindow()
        window.alphaValue = 1
        window.orderOut(nil)
    }

    func show(_ points: [CGPoint]) {
        self.points = points
        label = nil
        isFading = false
        isShowing = true
        fadeGeneration += 1
        present()
        SwipeLog.write("trail show \(points.count)")
    }

    func update(_ points: [CGPoint]) {
        guard isShowing, !isFading else { return }
        self.points = points
        present()
    }

    func setCaption(_ title: String?) {
        label = title
        guard isShowing, !isFading else { return }
        present()
    }

    func clearImmediately() {
        fadeGeneration += 1
        isFading = false
        isShowing = false
        points = []
        label = nil
        window?.alphaValue = 1
        window?.orderOut(nil)
    }

    func fade(title: String) {
        guard isShowing else { return }
        label = title
        isFading = true
        present()
        SwipeLog.write("trail fade \(title)")
        let generation = fadeGeneration
        window?.alphaValue = 1
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.4
            self.window?.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.fadeGeneration == generation else { return }
                self.isFading = false
                self.isShowing = false
                self.points = []
                self.label = nil
                self.window?.alphaValue = 1
                self.window?.orderOut(nil)
            }
        })
    }

    private func present() {
        let window = ensureWindow()
        let frame = Self.frame(around: points).integral
        if window.frame != frame {
            window.setFrame(frame, display: false)
        }
        canvas?.points = points
        canvas?.label = label
        canvas?.trailColor = AppSettings.shared.mouseGestureTrailColor
        canvas?.needsDisplay = true
        if !isFading {
            window.alphaValue = 1
        }
        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    private func ensureWindow() -> NSWindow {
        if let window { return window }
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isExcludedFromWindowsMenu = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = true
        let canvas = TrailCanvas(frame: window.contentView?.bounds ?? .zero)
        canvas.autoresizingMask = [.width, .height]
        window.contentView = canvas
        self.window = window
        self.canvas = canvas
        return window
    }

    /// Extra room on the right and top so the caption sits beside the pointer.
    private static func frame(around points: [CGPoint]) -> NSRect {
        guard let first = points.first else { return .zero }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return NSRect(
            x: minX - 24,
            y: minY - 24,
            width: (maxX - minX) + 24 + 240,
            height: (maxY - minY) + 24 + 48
        )
    }
}

private final class TrailCanvas: NSView {
    var points: [CGPoint] = []
    var label: String?
    var trailColor: MouseGestureTrailColor = .cyan {
        didSet {
            guard trailColor != oldValue else { return }
            let rgb = trailColor.rgb
            coreColor = NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
            glowColor = NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 0.35)
        }
    }

    private var coreColor = NSColor(srgbRed: 0.20, green: 0.95, blue: 1.00, alpha: 1)
    private var glowColor = NSColor(srgbRed: 0.20, green: 0.95, blue: 1.00, alpha: 0.35)
    private let edgeColor = NSColor.black.withAlphaComponent(0.4)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let rgb = trailColor.rgb
        coreColor = NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        glowColor = NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 0.35)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count >= 2, let origin = window?.frame.origin else { return }
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for (index, point) in points.enumerated() {
            let local = NSPoint(x: point.x - origin.x, y: point.y - origin.y)
            if index == 0 {
                path.move(to: local)
            } else {
                path.line(to: local)
            }
        }
        glowColor.setStroke()
        path.lineWidth = 12
        path.stroke()
        edgeColor.setStroke()
        path.lineWidth = 7
        path.stroke()
        coreColor.setStroke()
        path.lineWidth = 4
        path.stroke()
        guard let label, let last = points.last else { return }
        let local = NSPoint(x: last.x - origin.x + 16, y: last.y - origin.y + 14)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: coreColor,
            .shadow: shadow
        ])
        text.draw(at: local)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

/// Recognition text fixed below the center of the screen under the pointer.
@MainActor
final class MouseGestureTip {
    private var window: NSPanel?
    private var label = ""
    private var fadeGeneration = 0

    func hide() {
        fadeGeneration += 1
        label = ""
        window?.alphaValue = 1
        window?.orderOut(nil)
    }

    func fadeOut() {
        guard let window, window.isVisible, window.alphaValue > 0.02 else {
            hide()
            return
        }
        fadeGeneration += 1
        let generation = fadeGeneration
        // Hold the tip briefly after release, then ease out without flashing back to opaque.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self, self.fadeGeneration == generation else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                window.animator().alphaValue = 0
            }, completionHandler: {
                Task { @MainActor in
                    guard self.fadeGeneration == generation else { return }
                    self.label = ""
                    window.orderOut(nil)
                    window.alphaValue = 1
                }
            })
        }
    }

    func show(_ text: String, near point: CGPoint) {
        fadeGeneration += 1
        label = text
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        let frame = screen?.frame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
        let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let textWidth = (text as NSString).size(withAttributes: [.font: font]).width
        let size = CGSize(width: max(180, ceil(textWidth) + 48), height: 46)
        let center = CGPoint(x: frame.midX, y: frame.midY - frame.height * 0.18)
        let windowFrame = CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        let window = ensureWindow()
        window.alphaValue = 1
        window.setFrame(windowFrame, display: false)
        (window.contentView as? TipCanvas)?.text = text
        window.contentView?.needsDisplay = true
        window.orderFrontRegardless()
        window.displayIfNeeded()
    }

    private func ensureWindow() -> NSPanel {
        if let window { return window }
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 46),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.hidesOnDeactivate = false
        let canvas = TipCanvas(frame: window.contentView?.bounds ?? .zero)
        canvas.autoresizingMask = [.width, .height]
        window.contentView = canvas
        self.window = window
        return window
    }
}

private final class TipCanvas: NSView {
    var text = ""

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14)
        NSColor.black.withAlphaComponent(0.45).setFill()
        path.fill()
        let font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }
}
