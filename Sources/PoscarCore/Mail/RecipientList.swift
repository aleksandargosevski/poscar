import Foundation

/// The recipients of one address field: finished addresses shown as tokens, plus the text still
/// being typed. Separators (`,` `;` newline) and pasted lists turn complete addresses into tokens.
public struct RecipientList: Equatable, Sendable {
    public private(set) var addresses: [EmailAddress]
    public var draft: String

    public init(_ addresses: [EmailAddress] = [], draft: String = "") {
        self.addresses = []
        self.draft = draft
        addresses.forEach { add($0) }
    }

    public var isEmpty: Bool { addresses.isEmpty && draft.trimmingCharacters(in: .whitespaces).isEmpty }

    public func contains(_ email: String) -> Bool {
        addresses.contains { $0.email.caseInsensitiveCompare(email) == .orderedSame }
    }

    /// Adds an address unless it is already in the list. Returns false for a duplicate.
    @discardableResult
    public mutating func add(_ address: EmailAddress) -> Bool {
        guard !contains(address.email) else { return false }
        addresses.append(address)
        return true
    }

    public mutating func remove(at index: Int) {
        guard addresses.indices.contains(index) else { return }
        addresses.remove(at: index)
    }

    /// Takes new text of the field. Complete addresses before a separator become tokens; the rest
    /// stays as the draft. Text without separators is kept as typed.
    public mutating func updateDraft(_ text: String) {
        let normalized = text.replacingOccurrences(of: "\n", with: ",").replacingOccurrences(of: "\r", with: "")
        let parts = AddressParser.splitTopLevel(normalized)
        let trimmed = normalized.trimmingCharacters(in: .whitespaces)
        let endsWithSeparator = trimmed.hasSuffix(",") || trimmed.hasSuffix(";")
        guard parts.count > 1 || (endsWithSeparator && !parts.isEmpty) else {
            draft = text
            return
        }

        let complete = endsWithSeparator ? parts : Array(parts.dropLast())
        var leftover: [String] = []
        for part in complete {
            if let address = Self.address(in: part) {
                add(address)
            } else {
                leftover.append(part.trimmingCharacters(in: .whitespaces))
            }
        }
        if !endsWithSeparator, let last = parts.last { leftover.append(last.trimmingCharacters(in: .whitespaces)) }
        draft = leftover.joined(separator: ", ")
    }

    /// Turns the draft into a token. Returns true when the draft is now empty.
    @discardableResult
    public mutating func commitDraft() -> Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            draft = ""
            return true
        }
        updateDraft(trimmed + ",")
        return draft.isEmpty
    }

    /// Whether the draft is a bare address such as `ana@x.com`, which a space may complete.
    public var draftIsBareAddress: Bool {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        return !trimmed.contains(" ") && !trimmed.contains("<") && EmailAddress(email: trimmed).isValid
    }

    /// Every address including the draft, for sending. Throws when the draft is not an address.
    public func resolved(field: String) throws -> [EmailAddress] {
        var copy = self
        guard copy.commitDraft() else {
            throw PoscarError.invalidInput("\(field): \"\(draft.trimmingCharacters(in: .whitespaces))\" is not a valid address")
        }
        return copy.addresses
    }

    static func address(in part: String) -> EmailAddress? {
        guard let address = AddressParser.parseSingle(part), address.isValid else { return nil }
        return address
    }
}
