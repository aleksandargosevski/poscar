import AppKit
import PoscarCore
import SwiftUI

struct ShortcutsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var recording: CommandID?
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Preset", selection: presetBinding) {
                    ForEach(KeymapPreset.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .fixedSize()
                Spacer()
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            if !model.keymapWarnings.isEmpty {
                Text(model.keymapWarnings.joined(separator: "\n")).font(.caption).foregroundStyle(.orange)
            }

            List {
                ForEach(CommandCategory.allCases, id: \.self) { category in
                    let commands = CommandID.allCases.filter { $0.category == category && matches($0) }
                    if !commands.isEmpty {
                        Section(category.rawValue) {
                            ForEach(commands, id: \.self) { command in
                                row(command)
                            }
                        }
                    }
                }
            }

            HStack {
                Button("Reset All") {
                    model.saveKeymap(Keymap(preset: model.keymap.preset))
                }
                Button("Open keybindings.json") {
                    if !FileManager.default.fileExists(atPath: model.keymapStore.fileURL.path) {
                        model.saveKeymap(model.keymap)
                    }
                    NSWorkspace.shared.open(model.keymapStore.fileURL)
                }
                Button("Reload") { model.reloadKeymap() }
                Spacer()
                Text("Click a shortcut, then press keys. Sequences like G then I work too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var presetBinding: Binding<KeymapPreset> {
        Binding {
            model.keymap.preset
        } set: { preset in
            model.saveKeymap(Keymap(preset: preset, overrides: model.keymap.overrides))
        }
    }

    private func matches(_ command: CommandID) -> Bool {
        filter.isEmpty || command.title.localizedCaseInsensitiveContains(filter) || command.rawValue.localizedCaseInsensitiveContains(filter)
    }

    private func row(_ command: CommandID) -> some View {
        let conflicts = model.keymap.conflicts(for: command)
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                if !conflicts.isEmpty {
                    Text("Same keys as \(conflicts.map(\.title).joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            if recording == command {
                ShortcutRecorder { sequence in
                    recording = nil
                    guard let sequence else { return }
                    var keymap = model.keymap
                    keymap.overrides[command] = sequence.chords.isEmpty ? [] : [sequence]
                    model.saveKeymap(keymap)
                }
            } else {
                Button {
                    recording = command
                } label: {
                    let sequences = model.keymap.sequences(for: command)
                    if sequences.isEmpty {
                        Text("Record").foregroundStyle(.secondary)
                    } else {
                        HStack(spacing: 6) {
                            ForEach(sequences, id: \.self) { KeyHint(sequence: $0, prominent: true) }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if model.keymap.overrides[command] != nil {
                Button {
                    var keymap = model.keymap
                    keymap.overrides[command] = nil
                    model.saveKeymap(keymap)
                } label: {
                    Image(systemName: "arrow.uturn.backward").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reset to preset")
            }
        }
    }
}

/// Captures a key sequence: recording ends one second after the last key, or on ↩ after a key.
/// Esc cancels; ⌫ alone clears the shortcut.
struct ShortcutRecorder: View {
    let onFinish: (KeySequence?) -> Void
    @State private var chords: [KeyChord] = []
    @State private var monitor: Any?
    @State private var finishTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 6) {
            if chords.isEmpty {
                Text("Press keys…").foregroundStyle(Color.accentColor)
            } else {
                KeyHint(sequence: KeySequence(chords), prominent: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor))
        .onAppear(perform: start)
        .onDisappear(perform: stop)
    }

    private func start() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let chord = KeyChord(event: event) else { return nil }
            if chord == KeyChord(key: "esc") {
                finish(nil)
            } else if chord == KeyChord(key: "backspace"), chords.isEmpty {
                finish(KeySequence([]))
            } else if chord == KeyChord(key: "enter"), !chords.isEmpty {
                finish(KeySequence(chords))
            } else {
                chords.append(chord)
                if chords.count >= 3 {
                    finish(KeySequence(chords))
                } else {
                    scheduleFinish()
                }
            }
            return nil
        }
    }

    private func scheduleFinish() {
        finishTask?.cancel()
        finishTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !Task.isCancelled { finish(KeySequence(chords)) }
        }
    }

    private func finish(_ sequence: KeySequence?) {
        stop()
        onFinish(sequence)
    }

    private func stop() {
        finishTask?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
