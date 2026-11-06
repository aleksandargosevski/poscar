import PoscarCore
import SwiftUI

/// Keycaps for a shortcut, e.g. [G] [I] or [⌘][K].
struct KeyHint: View {
    let sequence: KeySequence?
    var prominent = false

    var body: some View {
        if let sequence {
            HStack(spacing: 3) {
                ForEach(Array(sequence.chords.enumerated()), id: \.offset) { _, chord in
                    HStack(spacing: 1) {
                        ForEach(Array(chord.symbols.enumerated()), id: \.offset) { _, symbol in
                            Keycap(symbol: symbol, prominent: prominent)
                        }
                    }
                }
            }
            .accessibilityLabel(sequence.description)
        }
    }
}

/// An outlined key label, as in Raycast.
struct Keycap: View {
    let symbol: String
    var prominent = false

    var body: some View {
        Text(symbol)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(prominent ? .primary : .secondary)
            .frame(minWidth: 18, minHeight: 18)
            .padding(.horizontal, symbol.count > 1 ? 4 : 0)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.primary.opacity(prominent ? 0.32 : 0.2), lineWidth: 1)
            )
    }
}

/// A button that shows the shortcut of the command it runs.
struct CommandButton: View {
    @Environment(AppModel.self) private var model
    let command: CommandID
    var icon: String?
    var title: String?
    var showTitle = true
    /// Toolbar items already get a capsule from the system, so they skip their own background.
    var bordered = true

    var body: some View {
        Button {
            model.perform(command)
        } label: {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon) }
                if showTitle { Text(title ?? command.title) }
                KeyHint(sequence: model.keymap.primary(for: command))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(HintButtonStyle(bordered: bordered))
        .help(helpText)
    }

    private var helpText: String {
        let shortcut = model.keymap.primary(for: command).map { " (\($0.description))" } ?? ""
        return (title ?? command.title) + shortcut
    }
}

/// A button for a key that isn't a remappable command, such as ↩ in a grid.
struct ShortcutButton: View {
    let title: String
    let icon: String
    let keys: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(title)
                KeyHint(sequence: KeySequence(parsing: keys))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(HintButtonStyle())
    }
}

/// A flat white pill; the quiet sibling of the prominent Send button.
struct HintButtonStyle: ButtonStyle {
    var bordered = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                if bordered {
                    ButtonSurface(pressed: configuration.isPressed)
                } else if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.08))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension Account {
    var color: Color {
        if let customColor, let color = Color(hex: customColor) { return color }
        return AccountPalette.colors[colorIndex % AccountPalette.colors.count]
    }
}

enum AccountPalette {
    /// Indices are stored in accounts.json, so new colours are only ever appended.
    static let colors: [Color] = [
        Color(hex: "#3b82f6")!, Color(hex: "#f97316")!, Color(hex: "#22c55e")!, Color(hex: "#ec4899")!,
        Color(hex: "#8b5cf6")!, Color(hex: "#14b8a6")!, Color(hex: "#ef4444")!, Color(hex: "#a16207")!,
        Color(hex: "#4f46e5")!, Color(hex: "#0ea5e9")!, Color(hex: "#84cc16")!, Color(hex: "#f59e0b")!,
        Color(hex: "#64748b")!,
    ]

    /// The order swatches are shown in: around the colour wheel, then grey.
    static let displayOrder = [8, 0, 9, 5, 2, 10, 11, 1, 6, 3, 4, 7, 12]
}

extension Color {
    /// `#rrggbb` or `rrggbb`.
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }

    var hexString: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        return String(format: "#%02x%02x%02x",
                      Int((rgb.redComponent * 255).rounded()), Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}
