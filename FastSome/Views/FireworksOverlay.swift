import AppKit
import QuartzCore

/// Full-screen, click-through fireworks using AppKit drawing (same approach as gesture trails).
@MainActor
enum FireworksPresenter {
    private static var panels: [NSPanel] = []
    private static var finishWorkItem: DispatchWorkItem?
    private(set) static var isPlaying = false

    static func play() {
        guard !isPlaying else { return }
        isPlaying = true
        finishWorkItem?.cancel()
        teardownWindows()

        let screens = NSScreen.screens.isEmpty ? [NSScreen.main].compactMap { $0 } : NSScreen.screens
        var remaining = screens.count
        for screen in screens {
            let panel = makePanel(frame: screen.frame)
            let canvas = FireworksCanvas(frame: NSRect(origin: .zero, size: screen.frame.size))
            canvas.autoresizingMask = [.width, .height]
            canvas.onFinished = {
                remaining -= 1
                if remaining <= 0 {
                    teardown()
                }
            }
            panel.contentView = canvas
            panel.setFrame(screen.frame, display: true)
            panel.orderFrontRegardless()
            panels.append(panel)
            canvas.start(duration: 5)
        }

        let work = DispatchWorkItem { teardown() }
        finishWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.8, execute: work)
    }

    private static func teardown() {
        finishWorkItem?.cancel()
        finishWorkItem = nil
        teardownWindows()
        isPlaying = false
    }

    private static func teardownWindows() {
        for panel in panels {
            (panel.contentView as? FireworksCanvas)?.stop()
            panel.orderOut(nil)
        }
        panels.removeAll()
    }

    private static func makePanel(frame: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isExcludedFromWindowsMenu = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        return panel
    }
}

// MARK: - Canvas

private final class FireworksCanvas: NSView {
    var onFinished: (() -> Void)?

    private var bursts: [Burst] = []
    private var startedAt: CFTimeInterval = 0
    private var duration: CFTimeInterval = 5
    private var timer: Timer?
    private var finished = false

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    required init?(coder: NSCoder) {
        nil
    }

    func start(duration: TimeInterval) {
        stop()
        finished = false
        self.duration = duration
        startedAt = CACurrentMediaTime()
        bursts = Burst.makeShow(
            seed: UInt64(Date().timeIntervalSince1970 * 1000) &+ UInt64(abs(frame.origin.x)),
            duration: duration
        )
        let tick = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(tick, forMode: .common)
        timer = tick
        needsDisplay = true
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard !finished else { return }
        needsDisplay = true
        if CACurrentMediaTime() - startedAt >= duration {
            finished = true
            stop()
            onFinished?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let elapsed = CACurrentMediaTime() - startedAt
        let size = bounds.size
        guard size.width > 1, size.height > 1 else { return }

        ctx.setFillColor(NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.fill(bounds)

        let speedScale = max(1.0, min(size.width, size.height) / 900)

        for burst in bursts {
            let age = elapsed - burst.delay
            guard age >= 0, age < burst.life else { continue }
            let origin = CGPoint(x: burst.x * size.width, y: burst.y * size.height)
            let fade = max(0, 1 - age / burst.life)

            if age < 0.22 {
                let flash = 1 - age / 0.22
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.95 * flash).cgColor)
                let r = 16 + 26 * flash
                ctx.fillEllipse(in: CGRect(x: origin.x - r, y: origin.y - r, width: r * 2, height: r * 2))
            }

            for particle in burst.particles {
                let t = age
                // AppKit Y grows upward; subtract gravity so sparks fall visually downward.
                let x = origin.x + cos(particle.angle) * particle.speed * speedScale * t
                let y = origin.y + sin(particle.angle) * particle.speed * speedScale * t - 140 * t * t
                let alpha = fade * particle.alpha
                guard alpha > 0.04 else { continue }
                let r = particle.radius * (0.85 + 0.35 * fade) * min(1.6, speedScale)
                ctx.setFillColor(particle.color.withAlphaComponent(alpha).cgColor)
                ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
        }
    }
}

// MARK: - Model

private struct Burst {
    var delay: Double
    var life: Double
    var x: Double
    var y: Double
    var particles: [Particle]

    struct Particle {
        var angle: Double
        var speed: Double
        var radius: Double
        var alpha: Double
        var color: NSColor
    }

    static func makeShow(seed: UInt64, duration: TimeInterval) -> [Burst] {
        var rng = SplitMix64(seed: seed)
        let palette: [NSColor] = [
            NSColor(srgbRed: 1.00, green: 0.35, blue: 0.25, alpha: 1),
            NSColor(srgbRed: 1.00, green: 0.80, blue: 0.15, alpha: 1),
            NSColor(srgbRed: 0.25, green: 0.90, blue: 1.00, alpha: 1),
            NSColor(srgbRed: 0.40, green: 1.00, blue: 0.35, alpha: 1),
            NSColor(srgbRed: 1.00, green: 0.35, blue: 0.90, alpha: 1),
            NSColor(srgbRed: 1.00, green: 0.95, blue: 0.45, alpha: 1),
            .white,
        ]
        let count = 12
        let lastStart = max(0.5, duration - 1.15)
        return (0..<count).map { index in
            let delay = lastStart * Double(index) / Double(max(count - 1, 1))
            let particleCount = 48 + Int(rng.next() % 20)
            let base = palette[Int(rng.next() % UInt64(palette.count))]
            var particles: [Particle] = []
            particles.reserveCapacity(particleCount)
            for i in 0..<particleCount {
                let angle = (Double(i) / Double(particleCount)) * .pi * 2 + rng.nextUnit() * 0.45
                particles.append(
                    Particle(
                        angle: angle,
                        speed: 120 + rng.nextUnit() * 180,
                        radius: 2.8 + rng.nextUnit() * 3.8,
                        alpha: 0.92,
                        color: i.isMultiple(of: 3)
                            ? palette[Int(rng.next() % UInt64(palette.count))]
                            : base
                    )
                )
            }
            return Burst(
                delay: delay,
                life: 1.4 + rng.nextUnit() * 0.45,
                x: 0.12 + rng.nextUnit() * 0.76,
                y: 0.22 + rng.nextUnit() * 0.55,
                particles: particles
            )
        }
    }
}

private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    mutating func nextUnit() -> Double {
        Double(next() % 10_000) / 10_000
    }
}
