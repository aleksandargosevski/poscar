import Foundation

public enum KeymapPreset: String, Codable, CaseIterable, Sendable {
    case gmail
    case superhuman
    case vim

    public var title: String {
        switch self {
        case .gmail: "Gmail"
        case .superhuman: "Superhuman"
        case .vim: "Vim"
        }
    }

    public var defaults: [CommandID: [String]] {
        var map = Self.gmailDefaults
        switch self {
        case .gmail:
            break
        case .superhuman:
            map[.reply] = ["r", "enter"]
            map[.openThread] = ["o"]
            map[.replyAll] = ["a", "shift+enter"]
            map[.toggleStar] = ["s", "cmd+shift+l"]
            map[.goScheduled] = ["g h"]
        case .vim:
            map[.openThread] = ["o", "enter", "l"]
            map[.backToList] = ["u", "h"]
            map[.firstThread] = ["g g"]
            map[.lastThread] = ["G"]
            map[.trash] = ["#", "d d"]
            map[.scrollDown] = ["space", "ctrl+d"]
            map[.scrollUp] = ["shift+space", "ctrl+u"]
            map[.label] = ["L"]
        }
        return map
    }

    static let gmailDefaults: [CommandID: [String]] = [
        .nextThread: ["j"],
        .previousThread: ["k"],
        .openThread: ["o", "enter"],
        .backToList: ["u"],
        .nextMessage: ["n"],
        .previousMessage: ["p"],
        .firstThread: [],
        .lastThread: [],
        .scrollDown: ["space"],
        .scrollUp: ["shift+space"],
        .archive: ["e"],
        .trash: ["#"],
        .spam: ["!"],
        .toggleStar: ["s"],
        .markRead: ["I"],
        .markUnread: ["U"],
        .toggleSelection: ["x"],
        .selectAll: ["* a"],
        .deselectAll: ["* n"],
        .label: ["l"],
        .moveTo: ["v"],
        .removeLabel: ["y"],
        .moveToInbox: [],
        .undo: ["z", "cmd+z"],
        .loadImages: ["i"],
        .openAttachments: ["shift+o"],
        .compose: ["c"],
        .reply: ["r"],
        .replyAll: ["a"],
        .forward: ["f"],
        .goInbox: ["g i"],
        .goStarred: ["g s"],
        .goSent: ["g t"],
        .goDrafts: ["g d"],
        .goAllMail: ["g a"],
        .goSpam: ["g !"],
        .goTrash: ["g #"],
        .goLabel: ["g l"],
        .goScheduled: ["g o"],
        .goAttachments: ["g f"],
        .goUnified: ["cmd+0"],
        .goAccount1: ["cmd+1"],
        .goAccount2: ["cmd+2"],
        .goAccount3: ["cmd+3"],
        .goAccount4: ["cmd+4"],
        .goAccount5: ["cmd+5"],
        .search: ["/", "cmd+f"],
        .toggleSidebar: ["cmd+s"],
        .showActions: ["cmd+k"],
        .commandPalette: ["cmd+p"],
        .showShortcuts: ["?"],
        .refresh: ["cmd+r"],
        .escape: ["esc"],
        .send: ["cmd+enter"],
        .sendLater: ["cmd+shift+enter"],
        .attachFile: ["cmd+shift+a"],
        .toggleCcBcc: ["cmd+shift+c"],
        .togglePreview: ["cmd+shift+p"],
        .discardDraft: ["cmd+shift+backspace"],
        .closeComposer: ["esc"],
    ]
}

public struct Keymap: Equatable, Sendable {
    public var preset: KeymapPreset
    public var overrides: [CommandID: [KeySequence]]

    public init(preset: KeymapPreset = .vim, overrides: [CommandID: [KeySequence]] = [:]) {
        self.preset = preset
        self.overrides = overrides
    }

    public func sequences(for command: CommandID) -> [KeySequence] {
        if let custom = overrides[command] { return custom }
        return (preset.defaults[command] ?? []).compactMap(KeySequence.init(parsing:))
    }

    public func primary(for command: CommandID) -> KeySequence? {
        sequences(for: command).first
    }

    public func bindings(for context: CommandContext) -> [KeySequence: CommandID] {
        var result: [KeySequence: CommandID] = [:]
        for command in CommandID.allCases where command.context == context {
            for sequence in sequences(for: command) where result[sequence] == nil {
                result[sequence] = command
            }
        }
        return result
    }

    /// Commands in the same context that share a sequence with `command`.
    public func conflicts(for command: CommandID) -> [CommandID] {
        let mine = Set(sequences(for: command))
        return CommandID.allCases.filter { other in
            other != command && other.context == command.context && !mine.isDisjoint(with: sequences(for: other))
        }
    }
}

/// Reads and writes `~/.config/poscar/keybindings.json`:
/// `{ "preset": "gmail", "bindings": { "archive": ["e"], "goInbox": ["g i"] } }`.
public struct KeymapStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = AppPaths.configDirectory.appendingPathComponent("keybindings.json")) {
        self.fileURL = fileURL
    }

    struct File: Codable {
        var preset: KeymapPreset
        var bindings: [String: [String]]
    }

    /// Returns the keymap and human-readable problems with entries that were skipped.
    public func load() -> (keymap: Keymap, warnings: [String]) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return (Keymap(), []) }
        let file: File
        do {
            file = try JSONDecoder().decode(File.self, from: Data(contentsOf: fileURL))
        } catch {
            return (Keymap(), ["\(fileURL.lastPathComponent) could not be read (\(error.localizedDescription)); using the default shortcuts."])
        }

        var warnings: [String] = []
        var overrides: [CommandID: [KeySequence]] = [:]
        for (name, sequences) in file.bindings {
            guard let command = CommandID(rawValue: name) else {
                warnings.append("Unknown command \"\(name)\"")
                continue
            }
            var parsed: [KeySequence] = []
            for text in sequences {
                if let sequence = KeySequence(parsing: text) {
                    parsed.append(sequence)
                } else {
                    warnings.append("Invalid shortcut \"\(text)\" for \(name)")
                }
            }
            overrides[command] = parsed
        }
        return (Keymap(preset: file.preset, overrides: overrides), warnings)
    }

    public func save(_ keymap: Keymap) throws {
        let bindings = Dictionary(uniqueKeysWithValues: keymap.overrides.map { command, sequences in
            (command.rawValue, sequences.map(\.description))
        })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(File(preset: keymap.preset, bindings: bindings)).write(to: fileURL, options: .atomic)
        } catch {
            throw PoscarError.storage("Could not save shortcuts: \(error.localizedDescription)")
        }
    }
}

/// Matches incoming chords against bindings, waiting for the next key of sequences such as `g i`.
public struct KeySequenceResolver: Sendable {
    public enum Outcome: Equatable, Sendable {
        case matched(CommandID)
        case pending
        case unmatched
    }

    public private(set) var pending: [KeyChord] = []
    private var lastKeyTime = Date.distantPast
    public var timeout: TimeInterval = 1.5

    public init() {}

    public mutating func handle(_ chord: KeyChord, bindings: [KeySequence: CommandID], now: Date = Date()) -> Outcome {
        if now.timeIntervalSince(lastKeyTime) > timeout { pending = [] }
        lastKeyTime = now

        let candidate = pending + [chord]
        if let command = bindings[KeySequence(candidate)] {
            pending = []
            return .matched(command)
        }
        let isPrefix = bindings.keys.contains { sequence in
            sequence.chords.count > candidate.count && Array(sequence.chords.prefix(candidate.count)) == candidate
        }
        if isPrefix {
            pending = candidate
            return .pending
        }
        if !pending.isEmpty {
            pending = []
            return handle(chord, bindings: bindings, now: now)
        }
        return .unmatched
    }

    public mutating func reset() {
        pending = []
    }
}
