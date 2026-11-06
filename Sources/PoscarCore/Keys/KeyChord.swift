import Foundation

public struct KeyModifiers: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

/// One key press, e.g. `e`, `#`, `cmd+k`, `shift+enter`.
///
/// Printable keys pressed without command, option or control are stored as the character they
/// produce, so `#` and `I` need no explicit shift. Other keys keep shift as a modifier.
public struct KeyChord: Hashable, Codable, Sendable, CustomStringConvertible {
    public var key: String
    public var modifiers: KeyModifiers

    public init(key: String, modifiers: KeyModifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    public static let namedKeys: Set<String> = [
        "enter", "esc", "tab", "space", "backspace", "delete", "up", "down", "left", "right", "home", "end", "pageup", "pagedown",
    ]

    /// Parses `cmd+shift+a`, `g`, `#`, `enter`.
    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "+" {
            self.init(key: "+")
            return
        }
        var parts = trimmed.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if parts.last == "" {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let keyPart = parts.popLast(), !keyPart.isEmpty else { return nil }

        var modifiers: KeyModifiers = []
        for part in parts {
            switch part.lowercased() {
            case "cmd", "command", "⌘": modifiers.insert(.command)
            case "shift", "⇧": modifiers.insert(.shift)
            case "opt", "option", "alt", "⌥": modifiers.insert(.option)
            case "ctrl", "control", "⌃": modifiers.insert(.control)
            default: return nil
            }
        }

        let lowered = keyPart.lowercased()
        let key: String
        if Self.namedKeys.contains(lowered) || lowered == "return" || lowered == "escape" {
            key = lowered == "return" ? "enter" : lowered == "escape" ? "esc" : lowered
        } else if keyPart.count == 1 {
            key = keyPart
        } else {
            return nil
        }
        self.init(normalizingKey: key, modifiers: modifiers)
    }

    /// Applies the storage rules described on the type.
    public init(normalizingKey key: String, modifiers: KeyModifiers) {
        var key = key
        var modifiers = modifiers
        let isPrintable = !Self.namedKeys.contains(key)
        let hasCommandLike = !modifiers.intersection([.command, .option, .control]).isEmpty

        if isPrintable {
            if hasCommandLike {
                if key.count == 1, key.uppercased() == key, key.lowercased() != key {
                    modifiers.insert(.shift)
                }
                key = key.lowercased()
            } else {
                if modifiers.contains(.shift), key.count == 1 { key = key.uppercased() }
                modifiers.remove(.shift)
            }
        }
        self.key = key
        self.modifiers = modifiers
    }

    /// Canonical text form used in keybindings.json.
    public var description: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// Keycap labels for display, e.g. ["⌘", "K"] or ["⇧", "I"].
    public var symbols: [String] {
        var symbols: [String] = []
        if modifiers.contains(.control) { symbols.append("⌃") }
        if modifiers.contains(.option) { symbols.append("⌥") }
        if modifiers.contains(.shift) { symbols.append("⇧") }
        if modifiers.contains(.command) { symbols.append("⌘") }

        switch key {
        case "enter": symbols.append("↩")
        case "esc": symbols.append("esc")
        case "tab": symbols.append("⇥")
        case "space": symbols.append("space")
        case "backspace": symbols.append("⌫")
        case "delete": symbols.append("⌦")
        case "up": symbols.append("↑")
        case "down": symbols.append("↓")
        case "left": symbols.append("←")
        case "right": symbols.append("→")
        case "home": symbols.append("↖")
        case "end": symbols.append("↘")
        case "pageup": symbols.append("⇞")
        case "pagedown": symbols.append("⇟")
        default:
            if key.count == 1, key.lowercased() != key.uppercased() {
                if key == key.uppercased(), modifiers.isEmpty { symbols.append("⇧") }
                symbols.append(key.uppercased())
            } else {
                symbols.append(key)
            }
        }
        return symbols
    }

    /// Whether the chord can fire while the user is typing in a text field.
    public var worksWhileTyping: Bool {
        !modifiers.intersection([.command, .control]).isEmpty || key == "esc"
    }
}

/// A sequence of chords such as `g i`.
public struct KeySequence: Hashable, Codable, Sendable, CustomStringConvertible {
    public var chords: [KeyChord]

    public init(_ chords: [KeyChord]) {
        self.chords = chords
    }

    public init?(parsing text: String) {
        let pieces = text.split(separator: " ").map(String.init)
        let chords = pieces.compactMap(KeyChord.init(parsing:))
        guard !chords.isEmpty, chords.count == pieces.count else { return nil }
        self.chords = chords
    }

    public var description: String {
        chords.map(\.description).joined(separator: " ")
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = KeySequence(parsing: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid shortcut \"\(text)\""))
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
