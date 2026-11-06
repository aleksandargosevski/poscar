import AppKit
import SwiftUI

/// Warm, flat look: paper-toned surfaces, white pills for buttons, hairlines instead of shadows.
enum Theme {
    static let canvas = dynamic(light: (0.976, 0.969, 0.957), dark: (0.118, 0.114, 0.110))
    static let sidebarTop = dynamic(light: (0.945, 0.933, 0.914), dark: (0.149, 0.141, 0.133))
    static let sidebarBottom = dynamic(light: (0.914, 0.898, 0.875), dark: (0.122, 0.115, 0.108))
    static let card = dynamic(light: (1.0, 0.996, 0.988), dark: (0.165, 0.157, 0.149))
    static let hairline = dynamic(light: (0.0, 0.0, 0.0), dark: (1.0, 1.0, 1.0), alpha: (0.09, 0.10))
    static let barTop = dynamic(light: (0.985, 0.978, 0.967), dark: (0.172, 0.164, 0.156))
    static let barBottom = dynamic(light: (0.945, 0.935, 0.918), dark: (0.140, 0.133, 0.126))
    static let raisedTop = dynamic(light: (1.0, 1.0, 1.0), dark: (0.255, 0.245, 0.235))
    static let raisedBottom = dynamic(light: (0.937, 0.925, 0.906), dark: (0.200, 0.192, 0.184))
    static let raisedPressed = dynamic(light: (0.890, 0.875, 0.855), dark: (0.160, 0.153, 0.146))
    static let raisedEdge = dynamic(light: (0.0, 0.0, 0.0), dark: (0.0, 0.0, 0.0), alpha: (0.16, 0.55))
    static let highlight = dynamic(light: (1.0, 1.0, 1.0), dark: (1.0, 1.0, 1.0), alpha: (0.9, 0.10))
    static let selection = dynamic(light: (0.988, 0.937, 0.890), dark: (0.255, 0.200, 0.160))
    static let selectionEdge = dynamic(light: (0.890, 0.600, 0.420), dark: (0.780, 0.500, 0.330), alpha: (0.55, 0.6))
    static let accent = Color(nsColor: NSColor(srgbRed: 0.88, green: 0.36, blue: 0.27, alpha: 1))
    static let unread = Color(nsColor: NSColor(srgbRed: 0.27, green: 0.52, blue: 0.95, alpha: 1))

    private static func dynamic(
        light: (Double, Double, Double), dark: (Double, Double, Double), alpha: (Double, Double) = (1, 1)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            return NSColor(srgbRed: r, green: g, blue: b, alpha: isDark ? alpha.1 : alpha.0)
        })
    }
}

/// A flat white pill with a hairline edge, used for buttons and small floating surfaces.
struct ButtonSurface: View {
    var cornerRadius: CGFloat = 8
    var pressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(pressed ? Theme.raisedPressed : Theme.card)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// Initials on a coloured disc, coloured by address so people are recognisable at a glance.
struct Avatar: View {
    let name: String
    let email: String
    var size: CGFloat = 28
    /// When set, a light outlined disc in this colour with one letter, as in Newton.
    var outline: Color?

    var body: some View {
        if let outline {
            Text(String(initials.prefix(1)))
                .font(.system(size: size * 0.5, weight: .regular))
                .foregroundStyle(outline)
                .frame(width: size, height: size)
                .background(Circle().fill(outline.opacity(0.12)))
                .overlay(Circle().strokeBorder(outline, lineWidth: 1.5))
        } else {
            Text(initials)
                .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(Avatar.color(for: email)))
        }
    }

    private var initials: String {
        let words = (name.isEmpty ? email : name)
            .split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" })
            .filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    static func color(for email: String) -> Color {
        let palette: [(Double, Double, Double)] = [
            (0.36, 0.43, 0.88), (0.88, 0.34, 0.36), (0.18, 0.64, 0.48), (0.85, 0.56, 0.17),
            (0.61, 0.35, 0.71), (0.12, 0.61, 0.84), (0.76, 0.33, 0.49), (0.35, 0.56, 0.16),
        ]
        let hash = email.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        let (r, g, b) = palette[hash % palette.count]
        return Color(red: r, green: g, blue: b)
    }
}

/// A flat bar with a hairline towards the content, used at the top and bottom of the content.
struct BarBackground: View {
    var edge: VerticalEdge = .top

    var body: some View {
        Theme.barTop
            .overlay(alignment: edge == .top ? .bottom : .top) {
                Rectangle().fill(Theme.hairline).frame(height: 0.5)
            }
    }
}
