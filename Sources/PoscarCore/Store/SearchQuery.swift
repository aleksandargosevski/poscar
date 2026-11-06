import Foundation
import GRDB

/// A search such as `from:ana to:marko in:sent ponuda`. Gmail gets the raw text; other servers and
/// the local index get the parsed filters.
public struct SearchQuery: Equatable, Sendable {
    public var raw: String
    public var text: [String] = []
    public var from: [String] = []
    public var to: [String] = []
    /// Values of `in:` (folder or label names), as typed.
    public var folders: [String] = []

    public init(_ raw: String) {
        self.raw = raw
        for token in Self.tokenize(raw) {
            let lower = token.lowercased()
            if lower.hasPrefix("from:") {
                let value = String(token.dropFirst(5))
                if !value.isEmpty { from.append(value) }
            } else if lower.hasPrefix("to:") {
                let value = String(token.dropFirst(3))
                if !value.isEmpty { to.append(value) }
            } else if lower.hasPrefix("in:") {
                let value = String(token.dropFirst(3))
                if !value.isEmpty { folders.append(value) }
            } else if !token.contains(":") {
                // Other Gmail operators (has:, label:) only make sense on Gmail's server.
                text.append(token)
            }
        }
    }

    public var isEmpty: Bool { text.isEmpty && from.isEmpty && to.isEmpty }

    /// The standard mailbox an `in:` value names, following Gmail's names. `nil` for labels;
    /// `in:anywhere` and `in:all` mean no folder restriction.
    public static func standardMailbox(named value: String) -> MailboxKind?? {
        switch value.lowercased() {
        case "inbox": .some(.inbox)
        case "sent", "sentmail": .some(.sent)
        case "draft", "drafts": .some(.drafts)
        case "starred", "flagged": .some(.starred)
        case "spam", "junk": .some(.spam)
        case "trash", "bin", "deleted": .some(.trash)
        case "archive", "allmail", "all-mail": .some(.archive)
        case "anywhere", "all": .some(nil)
        default: nil
        }
    }

    /// IMAP SEARCH criteria; several keys are ANDed by the protocol.
    public var imapCriteria: [CommandPart] {
        var parts: [CommandPart] = []
        func add(_ key: String, _ value: String) {
            if !parts.isEmpty { parts.append(.text(" ")) }
            parts.append(.text("\(key) "))
            parts.append(.string(value))
        }
        from.forEach { add("FROM", $0) }
        to.forEach { add("TO", $0) }
        if !text.isEmpty { add("TEXT", text.joined(separator: " ")) }
        if parts.isEmpty { parts = [.text("ALL")] }
        let isASCII = raw.unicodeScalars.allSatisfy(\.isASCII)
        return isASCII ? parts : [.text("CHARSET UTF-8 ")] + parts
    }

    /// Splits on spaces, keeping quoted phrases (`from:"Ana Petrović"`) together without the quotes.
    static func tokenize(_ input: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in input {
            if character == "\"" {
                inQuotes.toggle()
            } else if character.isWhitespace, !inQuotes {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

extension MailQueries {
    /// Local search: full text for words, address filters for from:/to:.
    public static func search(_ db: Database, query: SearchQuery, limit: Int = 500) throws -> [Int64] {
        guard !query.isEmpty else { return [] }
        var sql: SQL = "SELECT id FROM message WHERE hidden = 0"
        for value in query.from {
            let pattern = likePattern(value)
            sql += " AND (fromEmail LIKE \(pattern) ESCAPE '\\' OR fromName LIKE \(pattern) ESCAPE '\\')"
        }
        for value in query.to {
            let pattern = likePattern(value)
            sql += " AND (toAddresses LIKE \(pattern) ESCAPE '\\' OR ccAddresses LIKE \(pattern) ESCAPE '\\')"
        }
        if !query.text.isEmpty {
            let match = query.text.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"*" }.joined(separator: " ")
            sql += " AND id IN (SELECT rowid FROM message_fts WHERE message_fts MATCH \(match))"
        }
        sql += " ORDER BY date DESC LIMIT \(limit)"
        return try SQLRequest<Int64>(literal: sql).fetchAll(db)
    }

    private static func likePattern(_ value: String) -> String {
        "%\(value.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_"))%"
    }
}
