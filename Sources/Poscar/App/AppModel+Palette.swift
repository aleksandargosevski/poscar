import Foundation
import PoscarCore

enum LabelPurpose {
    case add
    case move
    case go
}

enum PaletteMode: Equatable {
    /// Every command, centred like Spotlight.
    case commands
    /// Actions for what is selected or open, in a popover above the Actions button, like Raycast.
    case actions
    case labels(LabelPurpose)

    var isPopover: Bool { self != .commands }
}

struct PaletteItem: Identifiable {
    var id: String
    var title: String
    var subtitle: String?
    var icon: String
    var shortcut: KeySequence?
    var section: String?
    var run: @MainActor () -> Void
}

extension AppModel {
    func openPalette(_ mode: PaletteMode) {
        paletteMode = mode
        paletteQuery = ""
        paletteIndex = 0
        overlay = .palette
    }

    func togglePalette(_ mode: PaletteMode) {
        if overlay == .palette, paletteMode == mode {
            overlay = nil
        } else {
            openPalette(mode)
        }
    }

    func openLabelPicker(_ purpose: LabelPurpose) {
        if purpose != .go {
            let accountIDs = Set(targetThreads.map(\.id.accountId))
            guard !accountIDs.isEmpty else {
                showToast("Select a conversation first")
                return
            }
            guard accountIDs.count == 1 else {
                showToast("Select conversations from one account to label them")
                return
            }
        }
        openPalette(.labels(purpose))
    }

    var palettePlaceholder: String {
        switch paletteMode {
        case .commands: "Search commands, labels and accounts…"
        case .actions: "Search for actions…"
        case .labels(.add): "Label as…"
        case .labels(.move): "Move to…"
        case .labels(.go): "Go to label…"
        }
    }

    var paletteItems: [PaletteItem] {
        let items: [PaletteItem]
        switch paletteMode {
        case .commands: items = commandItems + goToLabelItems
        case .actions: items = actionItems
        case .labels(let purpose): items = labelItems(purpose)
        }
        return FuzzyMatcher.filter(items, query: paletteQuery) { [$0.title, $0.subtitle ?? ""] }
    }

    func runPaletteItem(at index: Int) {
        let items = paletteItems
        guard items.indices.contains(index) else { return }
        overlay = nil
        items[index].run()
    }

    /// Handles keys while an overlay is open. Returns false to let the text field receive the key.
    func handleOverlayKey(_ chord: KeyChord) -> Bool {
        if chord.key == "esc" {
            overlay = nil
            return true
        }
        guard overlay == .palette else {
            if overlay == .shortcuts, chord == KeyChord(key: "?") { overlay = nil }
            return overlay == .shortcuts
        }
        let count = paletteItems.count
        let isControl = chord.modifiers == .control
        switch (chord.key, chord.modifiers) {
        case ("down", []), ("n", .control), ("j", .control):
            if count > 0 { paletteIndex = (paletteIndex + 1) % count }
            return true
        case ("up", []), ("p", .control), ("k", .control):
            if count > 0 { paletteIndex = (paletteIndex - 1 + count) % count }
            return true
        case ("enter", []):
            runPaletteItem(at: paletteIndex)
            return true
        default:
            return isControl
        }
    }

    /// Title shown above the actions: the conversation they apply to.
    var actionsTitle: String {
        if checked.count > 1 { return "\(checked.count) conversations" }
        let subject = targetThreads.first?.latest.subject ?? ""
        return subject.isEmpty ? "Pošćar" : subject
    }

    private var actionItems: [PaletteItem] {
        let target = targetThreads.first
        let isReading = focus == .reader
        var sections: [(String, [CommandID])] = []
        if isReading {
            sections.append(("Reply", [.reply, .replyAll, .forward]))
        } else if target != nil {
            sections.append(("Conversation", [.openThread, .reply, .replyAll, .forward]))
        }
        if target != nil {
            sections.append(("Organize", [.archive, .trash, .spam, .toggleStar, .markRead, .markUnread, .label, .moveTo, .removeLabel, .moveToInbox]))
        }
        if isReading {
            sections.append(("Message", [.loadImages, .openAttachments, .previousMessage, .nextMessage, .backToList]))
        } else if !threads.isEmpty {
            sections.append(("Select", [.toggleSelection, .selectAll, .deselectAll]))
        }
        sections.append(("Mail", [.compose, .refresh, .search, .commandPalette, .showShortcuts]))

        return sections.flatMap { section, commands in
            commands.filter { isRelevant($0, target: target) }.map { command in
                PaletteItem(
                    id: "action.\(command.rawValue)",
                    title: actionTitle(command, target: target),
                    subtitle: nil,
                    icon: icon(for: command),
                    shortcut: keymap.primary(for: command),
                    section: section,
                    run: { [weak self] in self?.perform(command) }
                )
            }
        }
    }

    private func isRelevant(_ command: CommandID, target: ThreadSummary?) -> Bool {
        switch command {
        case .removeLabel: return mailbox.kind.isLabel
        case .moveToInbox: return mailbox.kind != .inbox
        case .markRead: return target?.isUnread == true
        case .markUnread: return target?.isUnread == false
        case .deselectAll: return !checked.isEmpty
        case .loadImages: return renderedThread?.hasBlockedImages == true
        default: return true
        }
    }

    private func actionTitle(_ command: CommandID, target: ThreadSummary?) -> String {
        switch command {
        case .toggleStar: return target?.isFlagged == true ? "Unstar" : "Star"
        case .spam: return mailbox.kind == .spam ? "Not spam" : "Report spam"
        case .toggleSelection: return checked.contains(target?.id ?? ThreadID(accountId: "", threadKey: "")) ? "Deselect" : "Select"
        case .previousMessage: return "Newer message"
        case .nextMessage: return "Older message"
        default: return command.title
        }
    }

    private var commandItems: [PaletteItem] {
        CommandID.allCases.filter { !$0.isPaletteHidden && isAvailable($0) }.map { command in
            PaletteItem(
                id: "command.\(command.rawValue)",
                title: paletteTitle(for: command),
                subtitle: command.category.rawValue,
                icon: icon(for: command),
                shortcut: keymap.primary(for: command),
                section: nil,
                run: { [weak self] in self?.perform(command) }
            )
        }
    }

    private func isAvailable(_ command: CommandID) -> Bool {
        guard let index = command.accountIndex else { return command != .goUnified || accounts.count > 1 }
        return accounts.indices.contains(index)
    }

    private func paletteTitle(for command: CommandID) -> String {
        if let index = command.accountIndex, accounts.indices.contains(index) {
            return "Go to \(accounts[index].name)"
        }
        return command.title
    }

    private var goToLabelItems: [PaletteItem] {
        labelItems(.go).map { item in
            var copy = item
            copy.title = "Go to \(item.title)"
            return copy
        }
    }

    private func labelItems(_ purpose: LabelPurpose) -> [PaletteItem] {
        let accountIDs: [String]
        switch purpose {
        case .go: accountIDs = mailbox.accountId.map { [$0] } ?? accounts.map(\.id)
        case .add, .move: accountIDs = Array(Set(targetThreads.map(\.id.accountId)))
        }

        var items: [PaletteItem] = []
        for accountID in accountIDs {
            guard let accountFolders = folders[accountID], let account = account(accountID) else { continue }
            let showAccount = accounts.count > 1
            var candidates = accountFolders.userLabels.map { folder in
                (key: accountFolders.isGmail ? folder.name : folder.path, name: folder.name)
            }
            if purpose == .move, !accountFolders.isGmail {
                candidates += accountFolders.folders
                    .filter { [.inbox, .archive].contains($0.role) }
                    .map { (key: $0.path, name: $0.name) }
            }
            for candidate in candidates {
                let action: @MainActor () -> Void
                switch purpose {
                case .add:
                    action = { [weak self] in self?.apply(.addLabel(candidate.key)) }
                case .move:
                    action = { [weak self] in self?.apply(.moveTo(candidate.key)) }
                case .go:
                    action = { [weak self] in self?.setMailbox(Mailbox(accountId: accountID, kind: .label(candidate.key))) }
                }
                items.append(PaletteItem(
                    id: "label.\(accountID).\(candidate.key)",
                    title: candidate.name,
                    subtitle: showAccount ? account.name : nil,
                    icon: purpose == .move ? "folder" : "tag",
                    shortcut: nil,
                    section: nil,
                    run: action
                ))
            }
        }
        return items
    }

    private func icon(for command: CommandID) -> String {
        switch command {
        case .archive: "archivebox"
        case .trash: "trash"
        case .spam: "xmark.octagon"
        case .toggleStar: "star"
        case .markRead: "envelope.open"
        case .markUnread: "envelope.badge"
        case .label: "tag"
        case .moveTo: "folder"
        case .undo: "arrow.uturn.backward"
        case .compose: "square.and.pencil"
        case .reply: "arrowshape.turn.up.left"
        case .replyAll: "arrowshape.turn.up.left.2"
        case .forward: "arrowshape.turn.up.right"
        case .search: "magnifyingglass"
        case .refresh: "arrow.clockwise"
        case .showShortcuts: "keyboard"
        case .loadImages: "photo"
        case .openAttachments: "paperclip"
        case .openThread: "envelope.open"
        case .backToList: "chevron.left"
        case .moveToInbox: "tray.and.arrow.down"
        case .removeLabel: "tag.slash"
        case .toggleSelection, .selectAll: "checkmark.circle"
        case .deselectAll: "circle"
        case .commandPalette: "command"
        case .previousMessage: "chevron.up"
        case .nextMessage: "chevron.down"
        case .goInbox: "tray"
        case .goStarred: "star"
        case .goSent: "paperplane"
        case .goDrafts: "doc"
        case .goAllMail: "archivebox"
        case .goSpam: "xmark.octagon"
        case .goTrash: "trash"
        case .goScheduled: "clock"
        case .goAttachments: "paperclip.circle"
        case .goUnified, .goAccount1, .goAccount2, .goAccount3, .goAccount4, .goAccount5: "person.crop.circle"
        default: "command"
        }
    }
}

enum FuzzyMatcher {
    /// Keeps items whose text contains the query's characters in order, best matches first.
    static func filter<T>(_ items: [T], query: String, fields: (T) -> [String]) -> [T] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return items }
        return items
            .compactMap { item -> (T, Int)? in
                let best = fields(item).compactMap { score(needle, in: $0.lowercased()) }.max()
                return best.map { (item, $0) }
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    static func score(_ needle: String, in haystack: String) -> Int? {
        if haystack.hasPrefix(needle) { return 1000 - haystack.count }
        if let range = haystack.range(of: needle) {
            let wordStart = range.lowerBound == haystack.startIndex || haystack[haystack.index(before: range.lowerBound)] == " "
            return (wordStart ? 800 : 600) - haystack.count
        }
        var score = 0
        var searchIndex = haystack.startIndex
        var previousMatch: String.Index?
        for character in needle {
            guard let found = haystack[searchIndex...].firstIndex(of: character) else { return nil }
            score += previousMatch.map { haystack.index(after: $0) == found ? 10 : 1 } ?? 1
            previousMatch = found
            searchIndex = haystack.index(after: found)
        }
        return score
    }
}
