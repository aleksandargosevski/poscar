import Foundation

public struct EmailAddress: Hashable, Codable, Sendable {
    public var name: String
    public var email: String

    public init(name: String = "", email: String) {
        self.name = name
        self.email = email
    }

    public var displayName: String { name.isEmpty ? email : name }

    /// "Name <email>" with the name quoted when needed; for display and editing, not for headers.
    public var formatted: String {
        guard !name.isEmpty else { return email }
        let needsQuotes = name.contains(where: { ",;<>@\"".contains($0) })
        let safeName = needsQuotes ? "\"\(name.replacingOccurrences(of: "\"", with: "'"))\"" : name
        return "\(safeName) <\(email)>"
    }

    public var isValid: Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".") && !email.contains(" ")
    }
}

public enum AddressParser {
    /// Parses an address list such as `"Doe, John" <j@d.com>, a@b.com, Group: x@y.com;`.
    /// The input must already be RFC 2047 decoded.
    public static func parse(_ input: String) -> [EmailAddress] {
        splitTopLevel(input).compactMap(parseSingle)
    }

    public static func format(_ addresses: [EmailAddress]) -> String {
        addresses.map(\.formatted).joined(separator: ", ")
    }

    public static func parseSingle(_ raw: String) -> EmailAddress? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Group syntax: "Team: a@b.com" — drop the group name.
        if let colon = text.firstIndex(of: ":"), !text[..<colon].contains("<"), !text[..<colon].contains("\"") {
            text = String(text[text.index(after: colon)...]).trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
        }
        guard !text.isEmpty else { return nil }

        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            let email = text[text.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            let name = unquote(String(text[..<open]))
            guard !email.isEmpty else { return nil }
            return EmailAddress(name: name, email: email)
        }

        let withoutComment = text.replacingOccurrences(of: #"\(.*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard withoutComment.contains("@") else { return nil }
        return EmailAddress(email: withoutComment)
    }

    static func unquote(_ value: String) -> String {
        var name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
            name = String(name.dropFirst().dropLast())
                .replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if name.hasPrefix("'"), name.hasSuffix("'"), name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        return name.trimmingCharacters(in: .whitespaces)
    }

    /// Splits on commas and semicolons that are outside quotes and angle brackets.
    public static func splitTopLevel(_ input: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var angleDepth = 0
        var escaped = false

        for character in input {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inQuotes:
                escaped = true
                current.append(character)
            case "\"":
                inQuotes.toggle()
                current.append(character)
            case "<" where !inQuotes:
                angleDepth += 1
                current.append(character)
            case ">" where !inQuotes:
                angleDepth = max(0, angleDepth - 1)
                current.append(character)
            case ",", ";":
                if inQuotes || angleDepth > 0 {
                    current.append(character)
                } else {
                    parts.append(current)
                    current = ""
                }
            default:
                current.append(character)
            }
        }
        parts.append(current)
        return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}
