import AppKit
import Carbon.HIToolbox
import PoscarCore

/// A system-wide shortcut via Carbon hot keys, which need no Accessibility permission.
@MainActor
final class GlobalHotKey {
    var onPress: (() -> Void)?
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// Returns false when the chord can't be a global shortcut or another app already owns it.
    @discardableResult
    func register(_ chord: KeyChord?) -> Bool {
        unregister()
        guard let chord, let (keyCode, needsShift) = KeyCodes.code(for: chord.key) else { return chord == nil }
        guard !chord.modifiers.intersection([.command, .control, .option]).isEmpty else { return false }

        installHandlerIfNeeded()
        var modifiers: UInt32 = 0
        if chord.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if chord.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if chord.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if chord.modifiers.contains(.shift) || needsShift { modifiers |= UInt32(shiftKey) }

        let identifier = EventHotKeyID(signature: OSType(0x5053_4352), id: 1)
        let status = RegisterEventHotKey(UInt32(keyCode), modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        return status == noErr
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { hotKey.onPress?() } }
            return noErr
        }, 1, &spec, context, &handlerRef)
    }
}
