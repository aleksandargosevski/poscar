import AppKit
import GRDB
import PoscarCore

enum ReplyMode {
    case reply
    case replyAll
    case forward
}

enum AddressFieldKind: Hashable {
    case to, cc, bcc
}

enum ComposerFocus: Hashable {
    case to, cc, bcc, subject, body
}

@MainActor
@Observable
final class ComposerModel {
    var accountId: String
    var to = ""
    var cc = ""
    var bcc = ""
    var subject = ""
    var body = ""
    var attachments: [OutgoingAttachment] = []
    var showCcBcc = false
    var inReplyTo: String?
    var references: [String] = []
    var replyToRowId: Int64?
    var error: String?
    var isSending = false
    var showingSendLater = false
    var showingPreview = false
    var customSendDate = Date().addingTimeInterval(3600)
    var initialFocus: ComposerFocus = .to
    var cursorAtStart = false

    var suggestions: [ContactRecord] = []
    var suggestionIndex = 0
    var suggestionField: AddressFieldKind?

    @ObservationIgnored private var initialSnapshot = ""

    init(accountId: String) {
        self.accountId = accountId
    }

    func markClean() {
        initialSnapshot = snapshot
    }

    var isDirty: Bool { snapshot != initialSnapshot }

    private var snapshot: String {
        [to, cc, bcc, subject, body, attachments.map(\.filename).joined()].joined(separator: "\u{1}")
    }

    var windowTitle: String {
        subject.trimmingCharacters(in: .whitespaces).isEmpty ? "New Message" : subject
    }

    // MARK: - Recipients

    func text(for field: AddressFieldKind) -> String {
        switch field {
        case .to: to
        case .cc: cc
        case .bcc: bcc
        }
    }

    func setText(_ value: String, for field: AddressFieldKind) {
        switch field {
        case .to: to = value
        case .cc: cc = value
        case .bcc: bcc = value
        }
    }

    func updateSuggestions(for field: AddressFieldKind, database: MailDatabase?) {
        let token = Self.lastToken(text(for: field))
        guard let database, token.count >= 1, !token.contains("<") else {
            suggestions = []
            return
        }
        suggestionField = field
        suggestions = (try? database.writer.read { db in try MailQueries.contacts(db, matching: token) }) ?? []
        suggestionIndex = 0
    }

    func acceptSuggestion(at index: Int? = nil) {
        guard let field = suggestionField, suggestions.indices.contains(index ?? suggestionIndex) else { return }
        let contact = suggestions[index ?? suggestionIndex]
        var parts = AddressParser.splitTopLevel(text(for: field)).map { $0.trimmingCharacters(in: .whitespaces) }
        if !parts.isEmpty, !text(for: field).trimmingCharacters(in: .whitespaces).hasSuffix(",") { parts.removeLast() }
        parts.append(contact.address.formatted)
        setText(parts.joined(separator: ", ") + ", ", for: field)
        suggestions = []
    }

    /// Keyboard handling for the suggestion list. Returns true when the key was used.
    func handleSuggestionKey(_ chord: KeyChord) -> Bool {
        guard !suggestions.isEmpty else { return false }
        switch (chord.key, chord.modifiers) {
        case ("down", []), ("n", .control):
            suggestionIndex = (suggestionIndex + 1) % suggestions.count
        case ("up", []), ("p", .control):
            suggestionIndex = (suggestionIndex - 1 + suggestions.count) % suggestions.count
        case ("enter", []), ("tab", []):
            acceptSuggestion()
        case ("esc", []):
            suggestions = []
        default:
            return false
        }
        return true
    }

    static func lastToken(_ text: String) -> String {
        if text.trimmingCharacters(in: .whitespaces).hasSuffix(",") { return "" }
        return (AddressParser.splitTopLevel(text).last ?? "").trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Building the message

    func outgoingMessage(from account: Account) throws -> OutgoingMessage {
        let to = try parseRecipients(self.to, field: "To")
        let cc = try parseRecipients(self.cc, field: "Cc")
        let bcc = try parseRecipients(self.bcc, field: "Bcc")
        guard !(to + cc + bcc).isEmpty else { throw PoscarError.invalidInput("Add at least one recipient") }
        return OutgoingMessage(
            from: EmailAddress(name: account.name, email: account.email),
            to: to, cc: cc, bcc: bcc,
            subject: subject,
            body: body,
            attachments: attachments,
            inReplyTo: inReplyTo,
            references: references
        )
    }

    private func parseRecipients(_ text: String, field: String) throws -> [EmailAddress] {
        let pieces = AddressParser.splitTopLevel(text).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return try pieces.map { piece in
            guard let address = AddressParser.parseSingle(piece), address.isValid else {
                throw PoscarError.invalidInput("\(field): \"\(piece)\" is not a valid address")
            }
            return address
        }
    }

    func addAttachments(_ urls: [URL]) {
        for url in urls {
            do {
                let data = try Data(contentsOf: url)
                if data.count > 25_000_000 {
                    error = "\(url.lastPathComponent) is larger than 25 MB, which most servers reject"
                }
                attachments.append(OutgoingAttachment(filename: url.lastPathComponent, data: data))
            } catch {
                self.error = "Could not attach \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Drafts from existing mail

    static func signatureBlock(_ account: Account) -> String {
        let signature = account.signature.trimmingCharacters(in: .whitespacesAndNewlines)
        return signature.isEmpty ? "" : "\n\n-- \n\(signature)"
    }

    static func new(account: Account, to: String = "") -> ComposerModel {
        let draft = ComposerModel(accountId: account.id)
        draft.to = to
        draft.body = signatureBlock(account)
        draft.initialFocus = to.isEmpty ? .to : .body
        draft.cursorAtStart = true
        draft.markClean()
        return draft
    }

    static func reply(_ mode: ReplyMode, to message: MessageRecord, parsed: ParsedMessage?, account: Account) -> ComposerModel {
        let draft = ComposerModel(accountId: account.id)
        let me = account.email.lowercased()
        let isMine = message.fromEmail.lowercased() == me
        let replyTargets = isMine ? message.to : (AddressParser.parse(message.replyTo).nonEmpty ?? [message.from])
        let originalText = String((parsed?.plainText ?? message.snippet).prefix(20_000))
        let date = message.date.formatted(date: .abbreviated, time: .shortened)

        switch mode {
        case .reply, .replyAll:
            var recipients = replyTargets
            var copies: [EmailAddress] = []
            if mode == .replyAll {
                let known = Set(recipients.map { $0.email.lowercased() })
                copies = (message.to + message.cc).filter { address in
                    let email = address.email.lowercased()
                    return email != me && !known.contains(email)
                }
                copies = copies.uniqued(by: { $0.email.lowercased() })
            }
            recipients = recipients.filter { $0.email.lowercased() != me || isMine }
            draft.to = AddressParser.format(recipients)
            draft.cc = AddressParser.format(copies)
            draft.showCcBcc = !copies.isEmpty
            draft.subject = prefixed(message.subject, with: "Re:")
            let quoted = originalText.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> \($0)" }.joined(separator: "\n")
            draft.body = signatureBlock(account) + "\n\nOn \(date), \(message.from.formatted) wrote:\n\n" + quoted
            draft.inReplyTo = message.messageId
            draft.references = message.referenceIDs + [message.messageId].compactMap { $0 }
            draft.replyToRowId = message.id
            draft.initialFocus = .body
        case .forward:
            draft.subject = prefixed(message.subject, with: "Fwd:")
            draft.body = signatureBlock(account) + """


            ---------- Forwarded message ----------
            From: \(message.from.formatted)
            Date: \(date)
            Subject: \(message.subject)
            To: \(message.toAddresses)


            """ + originalText
            draft.attachments = parsed?.visibleAttachments.map {
                OutgoingAttachment(filename: $0.filename, mimeType: $0.mimeType, data: $0.data)
            } ?? []
            draft.references = message.referenceIDs + [message.messageId].compactMap { $0 }
            draft.initialFocus = .to
        }
        draft.cursorAtStart = true
        draft.markClean()
        return draft
    }

    static func restored(from record: OutboxRecord) throws -> ComposerModel {
        let message = try record.decodedMessage()
        let draft = ComposerModel(accountId: record.accountId)
        draft.to = AddressParser.format(message.to)
        draft.cc = AddressParser.format(message.cc)
        draft.bcc = AddressParser.format(message.bcc)
        draft.showCcBcc = !message.cc.isEmpty || !message.bcc.isEmpty
        draft.subject = message.subject
        draft.body = message.body
        draft.attachments = message.attachments
        draft.inReplyTo = message.inReplyTo
        draft.references = message.references
        draft.replyToRowId = record.replyToMessageRowId
        draft.initialFocus = .body
        return draft
    }

    private static func prefixed(_ subject: String, with prefix: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        return trimmed.lowercased().hasPrefix(prefix.lowercased()) ? trimmed : "\(prefix) \(trimmed)"
    }
}

private extension Array {
    var nonEmpty: Self? { isEmpty ? nil : self }

    func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen = Set<Key>()
        return filter { seen.insert(key($0)).inserted }
    }
}
