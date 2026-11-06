import AppKit
import GRDB
import PoscarCore

extension AppModel {
    // MARK: - Attachments library

    func observeAttachments() {
        guard let database else { return }
        let filter = attachmentFilter
        attachmentObservationStore = ValueObservation
            .tracking { db in
                (try AttachmentIndex.fetch(db, filter: filter), try AttachmentIndex.counts(db, accountId: filter.accountId))
            }
            .start(in: database.writer, scheduling: .immediate) { [weak self] error in
                self?.showError(error.localizedDescription)
            } onChange: { [weak self] result in
                guard let self else { return }
                attachments = result.0
                attachmentCounts = result.1
                if !attachments.contains(where: { $0.id == self.selectedAttachmentID }) {
                    selectedAttachmentID = attachments.first?.id
                }
            }
    }

    /// Arrow keys move through the grid, ↩ opens, `o` shows the file in Finder.
    func handleAttachmentKey(_ chord: KeyChord) -> Bool {
        guard chord.modifiers.isEmpty, !attachments.isEmpty else { return false }
        let current = attachments.firstIndex { $0.id == selectedAttachmentID } ?? 0
        let columns = max(1, attachmentColumns)
        var next = current
        switch chord.key {
        case "right", "l": next = current + 1
        case "left", "h": next = current - 1
        case "down", "j": next = current + columns
        case "up", "k": next = current - columns
        case "enter":
            openAttachment(attachments[current])
            return true
        case "o":
            revealAttachment(attachments[current])
            return true
        default:
            return false
        }
        selectedAttachmentID = attachments[max(0, min(next, attachments.count - 1))].id
        return true
    }

    /// Indexes attachments of mail downloaded before the library existed, in the background.
    func indexOldAttachments() {
        guard let database else { return }
        Task.detached(priority: .utility) {
            do {
                while try await AttachmentIndex.backfill(database) > 0 {}
            } catch {
                await MainActor.run { self.showError("Indexing attachments failed: \(error.localizedDescription)") }
            }
        }
    }

    func openAttachment(_ record: AttachmentRecord) {
        selectedAttachmentID = record.id
        Task {
            do {
                open(try await loadAttachment(record))
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    /// Saves the file to Downloads and selects it in Finder.
    func revealAttachment(_ record: AttachmentRecord) {
        selectedAttachmentID = record.id
        Task {
            do {
                let attachment = try await loadAttachment(record)
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                let url = Self.availableURL(for: attachment.filename, in: downloads)
                try attachment.data.write(to: url)
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                showError("Could not save \(record.filename): \(error.localizedDescription)")
            }
        }
    }

    private func loadAttachment(_ record: AttachmentRecord) async throws -> MailAttachment {
        guard let database,
              let raw = try await database.writer.read({ db in try MailQueries.body(db, messageRowId: record.messageRowId) }) else {
            throw PoscarError.storage("The message of this attachment is no longer stored")
        }
        let parsed = await Task.detached { MIMEParser.parse(raw) }.value
        guard let attachment = parsed.attachments.first(where: { $0.id == record.attachmentIndex }) else {
            throw PoscarError.storage("\(record.filename) was not found in its message")
        }
        return attachment
    }

    /// `name.pdf`, or `name 2.pdf` when that already exists.
    private static func availableURL(for filename: String, in directory: URL) -> URL {
        let safe = filename.replacingOccurrences(of: "/", with: "-")
        let base = (safe as NSString).deletingPathExtension
        let ext = (safe as NSString).pathExtension
        var candidate = directory.appendingPathComponent(safe.isEmpty ? "attachment" : safe)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    /// Opens the conversation an attachment came from.
    func showMessage(of record: AttachmentRecord) {
        guard let database else { return }
        Task {
            guard let message = try? await database.writer.read({ db in try MessageRecord.fetchOne(db, key: record.messageRowId) }) else {
                showError("The message is no longer available")
                return
            }
            showingAttachments = false
            selectFirstWhenLoaded = false
            selectedThreadID = ThreadID(accountId: message.accountId, threadKey: message.threadKey)
            openSelectedThread()
        }
    }

    // MARK: - Search suggestions for from:, to: and in:

    /// The filter token being typed at the end of the search text, if any.
    private var filterToken: (prefix: String, value: String)? {
        guard let last = searchText.split(separator: " ", omittingEmptySubsequences: false).last else { return nil }
        for prefix in ["from:", "to:", "in:"] where last.lowercased().hasPrefix(prefix) {
            return (prefix, String(last.dropFirst(prefix.count)))
        }
        return nil
    }

    func updateSearchSuggestions() {
        guard let database, let token = filterToken else {
            searchSuggestions = []
            return
        }
        if token.prefix == "in:" {
            searchSuggestions = folderSuggestions(matching: token.value)
        } else {
            let contacts = (try? database.writer.read { db in try MailQueries.contacts(db, matching: token.value, limit: 6) }) ?? []
            searchSuggestions = contacts.map { contact in
                SearchSuggestion(
                    id: contact.email,
                    title: contact.name.isEmpty ? contact.email : contact.name,
                    subtitle: contact.name.isEmpty ? nil : contact.email,
                    icon: nil,
                    avatarEmail: contact.email,
                    completion: contact.email
                )
            }
        }
        searchSuggestionIndex = 0
    }

    /// Gmail's folder names first, then every label or folder the accounts have.
    private func folderSuggestions(matching prefix: String) -> [SearchSuggestion] {
        let standard: [(String, MailboxKind)] = [
            ("inbox", .inbox), ("sent", .sent), ("drafts", .drafts), ("starred", .starred),
            ("archive", .archive), ("spam", .spam), ("trash", .trash),
        ]
        var suggestions = standard.map { name, kind in
            SearchSuggestion(id: "in:\(name)", title: kind.title, subtitle: "in:\(name)", icon: kind.systemImage, avatarEmail: nil, completion: name)
        }
        var seen = Set<String>()
        for account in accounts {
            for folder in folders[account.id]?.userLabels ?? [] where seen.insert(folder.name.lowercased()).inserted {
                // Labels with spaces need quotes: in:"Moji projekti".
                let completion = folder.name.contains(" ") ? "\"\(folder.name)\"" : folder.name
                suggestions.append(SearchSuggestion(
                    id: "label:\(folder.name)", title: folder.name, subtitle: "in:\(completion)",
                    icon: account.isGmail ? "tag" : "folder", avatarEmail: nil, completion: completion
                ))
            }
        }
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return Array(suggestions.prefix(8)) }
        return Array(suggestions.filter { $0.title.lowercased().contains(needle) || $0.completion.lowercased().hasPrefix(needle) }.prefix(8))
    }

    func acceptSearchSuggestion(at index: Int? = nil) {
        let index = index ?? searchSuggestionIndex
        guard let token = filterToken, searchSuggestions.indices.contains(index) else { return }
        var words = searchText.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        words.removeLast()
        words.append(token.prefix + searchSuggestions[index].completion)
        searchText = words.joined(separator: " ") + " "
        searchSuggestions = []
    }

    /// Starts a filter in the search field, ready for autocomplete.
    func insertSearchFilter(_ prefix: String) {
        if !searchText.isEmpty, !searchText.hasSuffix(" ") { searchText += " " }
        searchText += prefix
        searchFocusRequest += 1
        updateSearchSuggestions()
    }

    func handleSearchSuggestionKey(_ chord: KeyChord) -> Bool {
        guard !searchSuggestions.isEmpty else { return false }
        switch (chord.key, chord.modifiers) {
        case ("down", []), ("n", .control):
            searchSuggestionIndex = (searchSuggestionIndex + 1) % searchSuggestions.count
        case ("up", []), ("p", .control):
            searchSuggestionIndex = (searchSuggestionIndex - 1 + searchSuggestions.count) % searchSuggestions.count
        case ("tab", []), ("enter", []):
            acceptSearchSuggestion()
        case ("esc", []):
            searchSuggestions = []
        default:
            return false
        }
        return true
    }
}

struct SearchSuggestion: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String?
    let avatarEmail: String?
    /// Text inserted after the filter prefix.
    let completion: String
}
