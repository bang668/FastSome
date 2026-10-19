import CoreGraphics
import Foundation

enum MouseGestureButton: String, Codable, CaseIterable, Identifiable {
    case left
    case right
    case middle
    case back
    case forward

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "左键"
        case .right: return "右键"
        case .middle: return "中键"
        case .back: return "侧键（后退）"
        case .forward: return "侧键（前进）"
        }
    }

    /// Unmatched movement on the left button is given back to the system.
    var replaysUnmatchedDrag: Bool { self == .left }
}

/// Preset neon colors for the gesture trail. Global, not per-gesture.
enum MouseGestureTrailColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case cyan
    case pink
    case green
    case orange
    case purple
    case white

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cyan: return "青"
        case .pink: return "粉"
        case .green: return "绿"
        case .orange: return "橙"
        case .purple: return "紫"
        case .white: return "白"
        }
    }

    /// Bright core in sRGB 0...1.
    var rgb: (CGFloat, CGFloat, CGFloat) {
        switch self {
        case .cyan: return (0.20, 0.95, 1.00)
        case .pink: return (1.00, 0.35, 0.85)
        case .green: return (0.35, 1.00, 0.45)
        case .orange: return (1.00, 0.65, 0.15)
        case .purple: return (0.75, 0.40, 1.00)
        case .white: return (1.00, 1.00, 1.00)
        }
    }
}

enum MouseGestureDirection: String, Codable, CaseIterable, Identifiable {
    case left
    case right
    case up
    case down
    case upLeft
    case upRight
    case downLeft
    case downRight

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "左 ←"
        case .right: return "右 →"
        case .up: return "上 ↑"
        case .down: return "下 ↓"
        case .upLeft: return "左上 ↖"
        case .upRight: return "右上 ↗"
        case .downLeft: return "左下 ↙"
        case .downRight: return "右下 ↘"
        }
    }

    /// Maps a vector to one of eight directions.
    /// Cardinals win when one axis clearly dominates (~2:1, within ~26° of the axis).
    /// That keeps L-shapes like「左 → 下」from becoming「左 → 左下」on a slightly rounded corner.
    /// More balanced vectors use equal 45° octants centered on each direction.
    /// 0° is right; positive angles point up.
    static func quantize(dx: CGFloat, dy: CGFloat) -> MouseGestureDirection {
        let ax = abs(dx)
        let ay = abs(dy)
        if ax >= ay * 2 { return dx >= 0 ? .right : .left }
        if ay >= ax * 2 { return dy >= 0 ? .up : .down }

        var degrees = atan2(dy, dx) * 180 / .pi
        if degrees < 0 { degrees += 360 }
        // Center each octant on its compass point (right at 0°, upRight at 45°, …).
        switch degrees {
        case 0..<22.5, 337.5..<360: return .right
        case 22.5..<67.5: return .upRight
        case 67.5..<112.5: return .up
        case 112.5..<157.5: return .upLeft
        case 157.5..<202.5: return .left
        case 202.5..<247.5: return .downLeft
        case 247.5..<292.5: return .down
        default: return .downRight
        }
    }
}

enum MouseGestureAction: Equatable, Sendable {
    case shortcut(HotKeyCombo)
    case text(String)

    var listSummary: String {
        switch self {
        case .shortcut(let combo):
            return combo.displayString
        case .text(let text):
            return "粘贴：\(MouseGestureAction.preview(text, limit: 24))"
        }
    }

    var tipSummary: String {
        switch self {
        case .shortcut(let combo):
            return "松开后 \(combo.displayString)"
        case .text(let text):
            return "松开后 粘贴：\(MouseGestureAction.preview(text, limit: 18))"
        }
    }

    static let maxTextLength = 2000

    static func preview(_ text: String, limit: Int) -> String {
        let flat = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit)) + "…"
    }
}

extension MouseGestureAction: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case shortcut
        case text
    }

    private enum Kind: String, Codable {
        case shortcut
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .shortcut:
            self = .shortcut(try container.decode(HotKeyCombo.self, forKey: .shortcut))
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .shortcut(let combo):
            try container.encode(Kind.shortcut, forKey: .type)
            try container.encode(combo, forKey: .shortcut)
        case .text(let text):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(text, forKey: .text)
        }
    }
}

struct MouseGestureDefinition: Identifiable, Equatable {
    var id: UUID
    var button: MouseGestureButton
    var strokes: [MouseGestureDirection]
    var action: MouseGestureAction

    var summary: String {
        button.title + " · " + strokes.map(\.title).joined(separator: " → ")
    }
}

extension MouseGestureDefinition: Codable {
    private enum CodingKeys: String, CodingKey {
        case id
        case button
        case strokes
        case action
        case shortcut
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        button = try container.decode(MouseGestureButton.self, forKey: .button)
        strokes = try container.decode([MouseGestureDirection].self, forKey: .strokes)
        if let action = try container.decodeIfPresent(MouseGestureAction.self, forKey: .action) {
            self.action = action
        } else if let shortcut = try container.decodeIfPresent(HotKeyCombo.self, forKey: .shortcut) {
            // Legacy saves only had a shortcut field.
            action = .shortcut(shortcut)
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .action,
                in: container,
                debugDescription: "Mouse gesture is missing action/shortcut."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(button, forKey: .button)
        try container.encode(strokes, forKey: .strokes)
        try container.encode(action, forKey: .action)
    }
}

enum MouseGestureValidation: Equatable, Error {
    case empty
    case tooMany
    case adjacentRepeat
    case duplicate
    case emptyText
    case textTooLong
}

enum MouseGestureLibrary {
    static func make(
        button: MouseGestureButton,
        strokes: [MouseGestureDirection],
        shortcut: HotKeyCombo,
        existing: [MouseGestureDefinition]
    ) -> Result<MouseGestureDefinition, MouseGestureValidation> {
        make(button: button, strokes: strokes, action: .shortcut(shortcut), existing: existing)
    }

    static func make(
        button: MouseGestureButton,
        strokes: [MouseGestureDirection],
        action: MouseGestureAction,
        existing: [MouseGestureDefinition]
    ) -> Result<MouseGestureDefinition, MouseGestureValidation> {
        guard !strokes.isEmpty else { return .failure(.empty) }
        guard strokes.count <= 3 else { return .failure(.tooMany) }
        for index in strokes.indices.dropFirst() where strokes[index] == strokes[index - 1] {
            return .failure(.adjacentRepeat)
        }
        if existing.contains(where: { $0.button == button && $0.strokes == strokes }) {
            return .failure(.duplicate)
        }
        switch action {
        case .shortcut:
            break
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .failure(.emptyText) }
            guard text.count <= MouseGestureAction.maxTextLength else { return .failure(.textTooLong) }
        }
        return .success(MouseGestureDefinition(
            id: UUID(),
            button: button,
            strokes: strokes,
            action: action
        ))
    }

    static func resizing(_ strokes: [MouseGestureDirection], to count: Int) -> [MouseGestureDirection] {
        let count = min(max(count, 1), 3)
        guard count > 0 else { return strokes }
        if strokes.count == count { return strokes }
        if strokes.count > count { return Array(strokes.prefix(count)) }
        var result = strokes
        if result.isEmpty { result = [.left] }
        while result.count < count {
            let previous = result.last
            let next = MouseGestureDirection.allCases.first { $0 != previous } ?? .right
            result.append(next)
        }
        return result
    }
}

enum MouseGestureEffect: Equatable {
    case beginTrail
    case clearTrail
    case showTip(String)
    /// Drop the tip immediately (match lost while still drawing).
    case hideTip
    /// Keep the tip briefly after mouse-up, then ease out.
    case fadeTip
    case fireShortcut(HotKeyCombo)
    case pasteText(String)
    case replayClick(MouseGestureButton, CGPoint)
    case replayDrag(MouseGestureButton, [CGPoint])
}

/// Segments one press into directions and matches the whole sequence.
struct MouseGestureRecognizer {
    static let trailDistance: CGFloat = 4
    static let strokeDistance: CGFloat = 100

    private var button: MouseGestureButton?
    private var origin: CGPoint?
    private var anchor: CGPoint?
    private var points: [CGPoint] = []
    private var trailVisible = false
    private var strokes: [MouseGestureDirection] = []
    private var definitions: [MouseGestureDefinition] = []
    private var tipText: String?

    mutating func press(
        _ button: MouseGestureButton,
        at point: CGPoint,
        definitions: [MouseGestureDefinition]
    ) {
        self.button = button
        origin = point
        anchor = point
        points = [point]
        trailVisible = false
        strokes = []
        self.definitions = definitions
        tipText = nil
    }

    mutating func move(to point: CGPoint) -> [MouseGestureEffect] {
        guard let origin, var anchor else { return [] }
        appendSample(point)
        var effects: [MouseGestureEffect] = []
        let travel = hypot(point.x - origin.x, point.y - origin.y)
        if !trailVisible, travel > Self.trailDistance {
            trailVisible = true
            effects.append(.beginTrail)
        }
        let dx = point.x - anchor.x
        let dy = point.y - anchor.y
        if hypot(dx, dy) >= Self.strokeDistance {
            let direction = MouseGestureDirection.quantize(dx: dx, dy: dy)
            if strokes.last != direction {
                strokes.append(direction)
            }
            anchor = point
            self.anchor = anchor
        }
        effects.append(contentsOf: tipEffects())
        return effects
    }

    private mutating func appendSample(_ point: CGPoint) {
        guard let last = points.last else {
            points = [point]
            return
        }
        // Keep recognition math on every event; only thin the stored path for replay/draw.
        if hypot(point.x - last.x, point.y - last.y) < 3, points.count > 1 {
            points[points.count - 1] = point
        } else {
            points.append(point)
        }
    }

    mutating func release() -> [MouseGestureEffect] {
        ending(fireIfMatched: true)
    }

    mutating func cancel() -> [MouseGestureEffect] {
        ending(fireIfMatched: false)
    }

    private mutating func ending(fireIfMatched: Bool) -> [MouseGestureEffect] {
        guard let button, let origin else { return [] }
        let drawn = trailVisible
        let match = fireIfMatched ? matched() : nil
        let path = points
        let start = origin
        // Release keeps the tip for a beat; cancel / interrupt clears it now.
        let tipEffect: MouseGestureEffect = fireIfMatched ? .fadeTip : .hideTip
        reset()
        if let match {
            return [tipEffect, .clearTrail] + Self.fireEffects(for: match.action)
        }
        if !drawn {
            return [.replayClick(button, start)]
        }
        if button.replaysUnmatchedDrag {
            return [tipEffect, .clearTrail, .replayDrag(button, path)]
        }
        return [tipEffect, .clearTrail]
    }

    private static func fireEffects(for action: MouseGestureAction) -> [MouseGestureEffect] {
        switch action {
        case .shortcut(let combo):
            return [.fireShortcut(combo)]
        case .text(let text):
            return [.pasteText(text)]
        }
    }

    private func matched() -> MouseGestureDefinition? {
        guard let button else { return nil }
        return definitions.first { $0.button == button && $0.strokes == strokes }
    }

    private mutating func tipEffects() -> [MouseGestureEffect] {
        guard strokes.isEmpty == false, let match = matched() else {
            if tipText != nil {
                tipText = nil
                return [.hideTip]
            }
            return []
        }
        let text = match.action.tipSummary
        guard text != tipText else { return [] }
        tipText = text
        return [.showTip(text)]
    }

    private mutating func reset() {
        button = nil
        origin = nil
        anchor = nil
        points = []
        trailVisible = false
        strokes = []
        definitions = []
        tipText = nil
    }
}
