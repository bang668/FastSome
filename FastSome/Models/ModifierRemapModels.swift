import Foundation

/// Source modifier row in a per-app map (left/right share one rule).
enum ModifierRemapSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case capsLock
    case control
    case option
    case command

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capsLock: return "大写锁定"
        case .control: return "Control"
        case .option: return "Option"
        case .command: return "Command"
        }
    }
}

/// Destination for a modifier, matching System Settings style.
enum ModifierRemapTarget: String, Codable, CaseIterable, Identifiable, Sendable {
    case capsLock
    case control
    case option
    case command
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .capsLock: return "大写锁定"
        case .control: return "Control"
        case .option: return "Option"
        case .command: return "Command"
        case .none: return "无动作"
        }
    }

    static func identity(for source: ModifierRemapSource) -> ModifierRemapTarget {
        switch source {
        case .capsLock: return .capsLock
        case .control: return .control
        case .option: return .option
        case .command: return .command
        }
    }
}

struct AppModifierRemapRule: Identifiable, Equatable, Codable, Sendable {
    var id: UUID
    var bundleIdentifier: String
    var displayName: String
    var capsLock: ModifierRemapTarget
    var control: ModifierRemapTarget
    var option: ModifierRemapTarget
    var command: ModifierRemapTarget

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        displayName: String,
        capsLock: ModifierRemapTarget = .capsLock,
        control: ModifierRemapTarget = .control,
        option: ModifierRemapTarget = .option,
        command: ModifierRemapTarget = .command
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.capsLock = capsLock
        self.control = control
        self.option = option
        self.command = command
    }

    var isIdentity: Bool {
        capsLock == .capsLock
            && control == .control
            && option == .option
            && command == .command
    }

    func target(for source: ModifierRemapSource) -> ModifierRemapTarget {
        switch source {
        case .capsLock: return capsLock
        case .control: return control
        case .option: return option
        case .command: return command
        }
    }

    mutating func setTarget(_ target: ModifierRemapTarget, for source: ModifierRemapSource) {
        switch source {
        case .capsLock: capsLock = target
        case .control: control = target
        case .option: option = target
        case .command: command = target
        }
    }

    var summary: String {
        if isIdentity { return "未修改" }
        var parts: [String] = []
        for source in ModifierRemapSource.allCases {
            let target = target(for: source)
            if target != ModifierRemapTarget.identity(for: source) {
                parts.append("\(source.shortSymbol)→\(target.shortSymbol)")
            }
        }
        return parts.isEmpty ? "未修改" : parts.joined(separator: " ")
    }
}

extension ModifierRemapSource {
    var shortSymbol: String {
        switch self {
        case .capsLock: return "⇪"
        case .control: return "⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        }
    }
}

extension ModifierRemapTarget {
    var shortSymbol: String {
        switch self {
        case .capsLock: return "⇪"
        case .control: return "⌃"
        case .option: return "⌥"
        case .command: return "⌘"
        case .none: return "∅"
        }
    }
}
