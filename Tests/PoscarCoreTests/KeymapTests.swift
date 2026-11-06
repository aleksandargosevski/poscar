import Foundation
import Testing
@testable import PoscarCore

@Suite struct KeyChordTests {
    @Test func parsesModifiersAndNormalizesShiftedCharacters() {
        #expect(KeyChord(parsing: "cmd+k") == KeyChord(key: "k", modifiers: .command))
        #expect(KeyChord(parsing: "cmd+shift+A") == KeyChord(key: "a", modifiers: [.command, .shift]))
        #expect(KeyChord(parsing: "shift+i") == KeyChord(key: "I"))
        #expect(KeyChord(parsing: "#") == KeyChord(key: "#"))
        #expect(KeyChord(parsing: "shift+enter") == KeyChord(key: "enter", modifiers: .shift))
        #expect(KeyChord(parsing: "return") == KeyChord(key: "enter"))
        #expect(KeyChord(parsing: "hyper+x") == nil)
        #expect(KeyChord(parsing: "cmd+notakey") == nil)
    }

    @Test func roundTripsThroughDescription() {
        for text in ["cmd+k", "g", "I", "shift+cmd+enter", "ctrl+d", "#", "?"] {
            let chord = KeyChord(parsing: text)!
            #expect(KeyChord(parsing: chord.description) == chord)
        }
    }

    @Test func showsKeycapSymbols() {
        #expect(KeyChord(parsing: "cmd+k")!.symbols == ["⌘", "K"])
        #expect(KeyChord(parsing: "I")!.symbols == ["⇧", "I"])
        #expect(KeyChord(parsing: "e")!.symbols == ["E"])
        #expect(KeyChord(parsing: "cmd+enter")!.symbols == ["⌘", "↩"])
    }

    @Test func parsesSequences() {
        let sequence = KeySequence(parsing: "g i")
        #expect(sequence?.chords == [KeyChord(key: "g"), KeyChord(key: "i")])
        #expect(KeySequence(parsing: "g bogus+x") == nil)
    }
}

@Suite struct KeySequenceResolverTests {
    let bindings = Keymap().bindings(for: .mail)

    @Test func matchesSingleKeys() {
        var resolver = KeySequenceResolver()
        #expect(resolver.handle(KeyChord(key: "e"), bindings: bindings) == .matched(.archive))
        #expect(resolver.handle(KeyChord(key: "#"), bindings: bindings) == .matched(.trash))
    }

    @Test func waitsForSequences() {
        var resolver = KeySequenceResolver()
        let start = Date()
        #expect(resolver.handle(KeyChord(key: "g"), bindings: bindings, now: start) == .pending)
        #expect(resolver.handle(KeyChord(key: "i"), bindings: bindings, now: start.addingTimeInterval(0.3)) == .matched(.goInbox))
    }

    @Test func dropsStalePrefixAfterTimeout() {
        var resolver = KeySequenceResolver()
        let start = Date()
        _ = resolver.handle(KeyChord(key: "g"), bindings: bindings, now: start)
        #expect(resolver.handle(KeyChord(key: "i"), bindings: bindings, now: start.addingTimeInterval(5)) == .matched(.loadImages))
    }

    @Test func retriesKeyAloneWhenSequenceBreaks() {
        var resolver = KeySequenceResolver()
        _ = resolver.handle(KeyChord(key: "g"), bindings: bindings)
        #expect(resolver.handle(KeyChord(key: "e"), bindings: bindings) == .matched(.archive))
        #expect(resolver.pending.isEmpty)
    }

    @Test func unknownKeysPassThrough() {
        var resolver = KeySequenceResolver()
        #expect(resolver.handle(KeyChord(key: "q"), bindings: bindings) == .unmatched)
    }
}

@Suite struct KeymapTests {
    @Test(arguments: KeymapPreset.allCases)
    func presetsHaveNoConflicts(preset: KeymapPreset) {
        let keymap = Keymap(preset: preset)
        for command in CommandID.allCases {
            #expect(keymap.conflicts(for: command).isEmpty, "\(preset) \(command) conflicts with \(keymap.conflicts(for: command))")
        }
    }

    @Test func vimIsTheDefault() {
        #expect(Keymap().preset == .vim)
        #expect(Keymap().bindings(for: .mail)[KeySequence(parsing: "d d")!] == .trash)
    }

    @Test func everyPresetParses() {
        for preset in KeymapPreset.allCases {
            for (command, texts) in preset.defaults {
                for text in texts {
                    #expect(KeySequence(parsing: text) != nil, "\(preset) \(command): \(text)")
                }
            }
        }
    }

    @Test func savesAndLoadsOverrides() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poscar-keys-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = KeymapStore(fileURL: url)
        let keymap = Keymap(preset: .vim, overrides: [.archive: [KeySequence(parsing: "y")!]])
        try store.save(keymap)
        let loaded = store.load()
        #expect(loaded.keymap == keymap)
        #expect(loaded.warnings.isEmpty)
    }

    @Test func reportsInvalidEntries() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("poscar-keys-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"preset":"gmail","bindings":{"archive":["bogus+e"],"nope":["x"]}}"#.utf8).write(to: url)
        let loaded = KeymapStore(fileURL: url).load()
        #expect(loaded.warnings.count == 2)
    }
}
