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
    var to = RecipientList()
    var cc = RecipientList()
    var bcc = RecipientList()
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
    /// The address field being edited, if any; keys like `,` and ⌫ act on it.
    var activeField: AddressFieldKind?
    /// A token selected by ⌫; the next ⌫ removes it.
    var selectedToken: (field: AddressFieldKind, index: Int)?

    @ObservationIgnored private var initialSnapshot = ""

    init(accountId: String) {
        self.accountId = accountId
    }

    func markClean() {
        initialSnapshot = snapshot
    }

    var isDirty: Bool { snapshot != initialSnapshot }

    private var snapshot: String {
        let recipients = [to, cc, bcc].map { list in list.addresses.map(\.email).joined(separator: ",") + "|" + list.draft }
        return (recipients + [subject, body, attachments.map(\.filename).joined()]).joined(separator: "\u{1}")
    }

    var windowTitle: String {
        subject.trimmingCharacters(in: .whitespaces).isEmpty ? "New Message" : subject
    }

    // MARK: - Recipients

    func list(for field: AddressFieldKind) -> RecipientList {
        switch field {
        case .to: to
        case .cc: cc
        case .bcc: bcc
        }
    }

    func update(_ field: AddressFieldKind, _ change: (inout RecipientList) -> Void) {
        switch field {
        case .to: change(&to)
        case .cc: change(&cc)
        case .bcc: change(&bcc)
        }
    }

    func setDraft(_ text: String, for field: AddressFieldKind, database: MailDatabase?) {
        selectedToken = nil
        update(field) { $0.updateDraft(text) }
        updateSuggestions(for: field, database: database)
    }

    func removeToken(at index: Int, from field: AddressFieldKind) {
        selectedToken = nil
        update(field) { $0.remove(at: index) }
    }

    /// Leaving a field turns what was typed into a token when it is an address.
    func fieldLostFocus(_ field: AddressFieldKind) {
        update(field) { $0.commitDraft() }
        if suggestionField == field { suggestions = [] }
        if selectedToken?.field == field { selectedToken = nil }
        if activeField == field { activeField = nil }
    }

    func updateSuggestions(for field: AddressFieldKind, database: MailDatabase?) {
        let query = list(for: field).draft.trimmingCharacters(in: .whitespaces)
        guard let database, !query.isEmpty else {
            suggestions = []
            return
        }
        let added = [to, cc, bcc].flatMap(\.addresses).map { $0.email.lowercased() }
        let found = (try? database.writer.read { db in try MailQueries.contacts(db, matching: query, limit: 12) }) ?? []
        suggestionField = field
        suggestions = Array(found.filter { !added.contains($0.email.lowercased()) }.prefix(8))
        suggestionIndex = 0
    }

    func acceptSuggestion(at index: Int? = nil) {
        guard let field = suggestionField, suggestions.indices.contains(index ?? suggestionIndex) else { return }
        let contact = suggestions[index ?? suggestionIndex]
        update(field) { list in
            list.add(contact.address)
            list.draft = ""
        }
        suggestions = []
    }

    /// Keys in an address field. Returns true when the key was used and must not reach the text field.
    func handleRecipientKey(_ chord: KeyChord) -> Bool {
        guard let field = activeField else { return false }
        let plain = chord.modifiers.isEmpty

        if !suggestions.isEmpty, suggestionField == field {
            switch (chord.key, chord.modifiers) {
            case ("down", []), ("n", .control):
                suggestionIndex = (suggestionIndex + 1) % suggestions.count
                return true
            case ("up", []), ("p", .control):
                suggestionIndex = (suggestionIndex - 1 + suggestions.count) % suggestions.count
                return true
            case ("enter", []), ("tab", []):
                acceptSuggestion()
                return true
            case ("esc", []):
                suggestions = []
                return true
            default:
                break
            }
        }

        let list = list(for: field)
        switch chord.key {
        case "backspace" where plain && list.draft.isEmpty && !list.addresses.isEmpty:
            let last = list.addresses.count - 1
            if let selected = selectedToken, selected.field == field {
                removeToken(at: selected.index, from: field)
            } else {
                selectedToken = (field, last)
            }
            return true
        case "," where plain, ";" where plain:
            update(field) { $0.commitDraft() }
            suggestions = []
            return true
        case "enter" where plain && !list.draft.isEmpty:
            update(field) { $0.commitDraft() }
            suggestions = []
            return true
        case "tab" where plain && !list.draft.isEmpty:
            // Commit, then let Tab move on to the next field.
            update(field) { $0.commitDraft() }
            suggestions = []
            return false
        case "space" where plain && list.draftIsBareAddress:
            update(field) { $0.commitDraft() }
            suggestions = []
            return true
        default:
            selectedToken = nil
            return false
        }
    }

    // MARK: - Building the message

    func outgoingMessage(from account: Account) throws -> OutgoingMessage {
        let to = try self.to.resolved(field: "To")
        let cc = try self.cc.resolved(field: "Cc")
        let bcc = try self.bcc.resolved(field: "Bcc")
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
        draft.to = RecipientList(AddressParser.parse(to))
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
            draft.to = RecipientList(recipients)
            draft.cc = RecipientList(copies)
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
        draft.to = RecipientList(message.to)
        draft.cc = RecipientList(message.cc)
        draft.bcc = RecipientList(message.bcc)
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
