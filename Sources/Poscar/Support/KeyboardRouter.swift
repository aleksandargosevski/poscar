import AppKit
import PoscarCore

/// Routes key presses to commands before AppKit sees them, Gmail style:
/// single keys work whenever no text field is being edited.
@MainActor
final class KeyboardRouter {
    private var monitor: Any?
    private var resolver = KeySequenceResolver()
    private weak var model: AppModel?

    func install(model: AppModel) {
        self.model = model
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let model, let window = event.window, let chord = KeyChord(event: event) else { return event }
        if window === model.mainWindow {
            return handleMain(event, chord: chord, window: window, model: model)
        }
        if let composer = model.composers.controller(for: window) {
            return composer.handleKey(chord, isTyping: Self.isTyping(in: window)) ? nil : event
        }
        return event
    }

    private func handleMain(_ event: NSEvent, chord: KeyChord, window: NSWindow, model: AppModel) -> NSEvent? {
        if model.overlay != nil {
            return model.handleOverlayKey(chord) ? nil : event
        }

        if Self.isTyping(in: window) {
            if model.handleSearchSuggestionKey(chord) { return nil }
            if chord == KeyChord(key: "esc") {
                if model.searchText.isEmpty { model.clearSearch() }
                window.makeFirstResponder(nil)
                return nil
            }
            guard chord.worksWhileTyping else { return event }
        } else if model.showingAttachments, model.handleAttachmentKey(chord) {
            return nil
        } else if model.focus == .list, let command = Self.listArrowCommands[chord] {
            // Arrows move through the list wherever the first responder is, unless reading.
            model.perform(command)
            return nil
        }

        switch resolver.handle(chord, bindings: model.keymap.bindings(for: .mail)) {
        case .matched(let command):
            model.pendingKeys = []
            model.perform(command)
            return nil
        case .pending:
            model.pendingKeys = resolver.pending
            return nil
        case .unmatched:
            model.pendingKeys = []
            return event
        }
    }

    private static let listArrowCommands: [KeyChord: CommandID] = [
        KeyChord(key: "down"): .nextThread,
        KeyChord(key: "up"): .previousThread,
    ]

    static func isTyping(in window: NSWindow) -> Bool {
        guard let textView = window.firstResponder as? NSTextView else { return false }
        return textView.isEditable
    }
}

extension KeyChord {
    init?(event: NSEvent) {
        var modifiers: KeyModifiers = []
        let flags = event.modifierFlags
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }

        if let named = KeyCodes.named[event.keyCode] {
            self.init(normalizingKey: named, modifiers: modifiers)
            return
        }

        // Non-Latin layouts (e.g. Cyrillic) still trigger shortcuts by key position.
        let typed = event.charactersIgnoringModifiers ?? ""
        let key: String
        if typed.count == 1, typed.unicodeScalars.allSatisfy({ $0.isASCII && $0.value >= 32 }) {
            key = typed
        } else if let position = KeyCodes.usLayout[event.keyCode] {
            key = flags.contains(.shift) ? position.shifted : position.plain
        } else {
            return nil
        }
        self.init(normalizingKey: key, modifiers: modifiers)
    }
}

/// Virtual key codes of the US layout, used for layout-independent shortcuts and global hot keys.
enum KeyCodes {
    static let named: [UInt16: String] = [
        36: "enter", 76: "enter", 53: "esc", 48: "tab", 49: "space", 51: "backspace", 117: "delete",
        126: "up", 125: "down", 123: "left", 124: "right", 115: "home", 119: "end", 116: "pageup", 121: "pagedown",
    ]

    static let usLayout: [UInt16: (plain: String, shifted: String)] = {
        let table: [(UInt16, String, String)] = [
            (0, "a", "A"), (1, "s", "S"), (2, "d", "D"), (3, "f", "F"), (4, "h", "H"), (5, "g", "G"), (6, "z", "Z"),
            (7, "x", "X"), (8, "c", "C"), (9, "v", "V"), (11, "b", "B"), (12, "q", "Q"), (13, "w", "W"), (14, "e", "E"),
            (15, "r", "R"), (16, "y", "Y"), (17, "t", "T"), (18, "1", "!"), (19, "2", "@"), (20, "3", "#"), (21, "4", "$"),
            (22, "6", "^"), (23, "5", "%"), (24, "=", "+"), (25, "9", "("), (26, "7", "&"), (27, "-", "_"), (28, "8", "*"),
            (29, "0", ")"), (30, "]", "}"), (31, "o", "O"), (32, "u", "U"), (33, "[", "{"), (34, "i", "I"), (35, "p", "P"),
            (37, "l", "L"), (38, "j", "J"), (39, "'", "\""), (40, "k", "K"), (41, ";", ":"), (42, "\\", "|"), (43, ",", "<"),
            (44, "/", "?"), (45, "n", "N"), (46, "m", "M"), (47, ".", ">"), (50, "`", "~"),
        ]
        return Dictionary(uniqueKeysWithValues: table.map { ($0.0, ($0.1, $0.2)) })
    }()

    /// The key code that produces `key`, and whether shift is needed for it.
    static func code(for key: String) -> (code: UInt16, shift: Bool)? {
        if let named = named.first(where: { $0.value == key }) { return (named.key, false) }
        if let plain = usLayout.first(where: { $0.value.plain == key }) { return (plain.key, false) }
        if let shifted = usLayout.first(where: { $0.value.shifted == key }) { return (shifted.key, true) }
        return nil
    }
}
