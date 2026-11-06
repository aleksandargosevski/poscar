import AppKit
import PoscarCore

extension AppModel {
    func perform(_ command: CommandID) {
        switch command {
        // Inside a conversation j/k move between its messages, like n/p.
        case .nextThread: focus == .reader ? focusMessage(offset: 1) : moveSelection(by: 1)
        case .previousThread: focus == .reader ? focusMessage(offset: -1) : moveSelection(by: -1)
        case .firstThread: select(index: 0)
        case .lastThread: select(index: threads.count - 1)
        case .openThread: openSelectedThread()
        case .backToList: closeThread()
        case .nextMessage: focusMessage(offset: 1)
        case .previousMessage: focusMessage(offset: -1)
        case .scrollDown: reader.run(ThreadRenderer.scrollScript(pages: 1))
        case .scrollUp: reader.run(ThreadRenderer.scrollScript(pages: -1))

        case .archive: apply(.archive)
        case .trash: apply(.trash)
        case .spam: apply(mailbox.kind == .spam ? .notSpam : .spam)
        case .toggleStar: apply(targetsAreStarred ? .unstar : .star)
        case .markRead: apply(.markRead)
        case .markUnread: apply(.markUnread)
        case .moveToInbox: apply(.moveToInbox)
        case .toggleSelection: toggleChecked()
        case .selectAll: checked = Set(threads.map(\.id))
        case .deselectAll: checked = []
        case .label: openLabelPicker(.add)
        case .moveTo: openLabelPicker(.move)
        case .removeLabel:
            if case .label(let name) = mailbox.kind {
                apply(.removeLabel(name))
            } else {
                showToast("Open a label to remove it from conversations")
            }
        case .undo: undo()
        case .loadImages:
            detail?.loadImages = true
        case .openAttachments: openAllAttachments()

        case .compose: composers.openNew()
        case .reply: replyToFocused(.reply)
        case .replyAll: replyToFocused(.replyAll)
        case .forward: replyToFocused(.forward)

        case .goInbox: go(.inbox)
        case .goStarred: go(.starred)
        case .goSent: go(.sent)
        case .goDrafts: go(.drafts)
        case .goAllMail: go(.archive)
        case .goSpam: go(.spam)
        case .goTrash: go(.trash)
        case .goLabel: openLabelPicker(.go)
        case .goScheduled:
            showingScheduled = true
        case .goAttachments:
            showingAttachments = true
        case .goUnified:
            setMailbox(Mailbox(kind: mailbox.kind.isLabel ? .inbox : mailbox.kind))
        case .goAccount1, .goAccount2, .goAccount3, .goAccount4, .goAccount5:
            guard let index = command.accountIndex, accounts.indices.contains(index) else {
                showToast("There is no account \((command.accountIndex ?? 0) + 1)")
                return
            }
            setMailbox(Mailbox(accountId: accounts[index].id, kind: mailbox.kind.isLabel ? .inbox : mailbox.kind))

        case .search:
            showingScheduled = false
            searchFocusRequest += 1
        case .toggleSidebar:
            sidebarVisible.toggle()
        case .commandPalette: togglePalette(.commands)
        case .showActions: togglePalette(.actions)
        case .showShortcuts: overlay = overlay == .shortcuts ? nil : .shortcuts
        case .refresh: refresh()
        case .escape: escape()

        case .send, .sendLater, .attachFile, .toggleCcBcc, .togglePreview, .discardDraft, .closeComposer:
            break
        }
    }

    private func go(_ kind: MailboxKind) {
        setMailbox(Mailbox(accountId: mailbox.accountId, kind: kind))
    }

    private func moveSelection(by offset: Int) {
        guard let index = selectedIndex else {
            select(index: 0)
            return
        }
        select(index: index + offset)
    }

    private func toggleChecked() {
        guard let selectedThreadID else { return }
        if checked.contains(selectedThreadID) {
            checked.remove(selectedThreadID)
        } else {
            checked.insert(selectedThreadID)
        }
    }

    private func escape() {
        if overlay != nil {
            overlay = nil
        } else if showingScheduled || showingAttachments {
            showingScheduled = false
            showingAttachments = false
        } else if activeSearch != nil {
            clearSearch()
        } else if focus == .reader {
            closeThread()
        } else if !checked.isEmpty {
            checked = []
        }
    }

    /// Gmail mailboxes are keyed by label name, IMAP ones by folder path; this returns what to show.
    func displayName(for kind: MailboxKind) -> String {
        guard case .label(let key) = kind else { return kind.title }
        for accountFolders in folders.values where !accountFolders.isGmail {
            if let folder = accountFolders.folders.first(where: { $0.path == key }) { return folder.name }
        }
        return key
    }

    // MARK: - Mail actions

    var targetThreads: [ThreadSummary] {
        if !checked.isEmpty { return threads.filter { checked.contains($0.id) } }
        return threads.filter { $0.id == selectedThreadID }
    }

    private var targetsAreStarred: Bool {
        let targets = targetThreads
        return !targets.isEmpty && targets.allSatisfy(\.isFlagged)
    }

    func apply(_ action: MailAction) {
        let targets = targetThreads
        guard !targets.isEmpty, let database else { return }
        let mailboxKind = mailbox.kind
        let removes = action.removesThread(from: mailboxKind) && !showingScheduled

        if removes {
            // Leaving a conversation that just went away returns to its folder's list, not the next thread.
            if focus == .reader { closeThread() }
            selectNeighbor(excluding: Set(targets.map(\.id)))
        }
        checked = []

        let foldersByAccount = folders
        Task {
            do {
                let plans = try await database.writer.read { db -> [String: [ActionPlan]] in
                    var result: [String: [ActionPlan]] = [:]
                    for thread in targets {
                        guard let accountFolders = foldersByAccount[thread.id.accountId] else { continue }
                        let messages = try MailQueries.threadMessages(
                            db, thread: thread.id, folders: accountFolders, inTrashOrSpam: mailboxKind.isTrashOrSpam
                        )
                        result[thread.id.accountId, default: []].append(
                            ActionPlanner.plan(action, messages: messages, folders: accountFolders, mailbox: mailboxKind)
                        )
                    }
                    return result
                }
                let merged = plans.mapValues { list in
                    ActionPlan(original: list.flatMap(\.original), updated: list.flatMap(\.updated), operations: list.flatMap(\.operations))
                }.filter { !$0.value.isEmpty }
                guard !merged.isEmpty else { return }

                let id = try await actions.enqueue(merged)
                undoStack.append(.action(id))
                let suffix = targets.count > 1 ? " · \(targets.count) conversations" : ""
                showToast(action.pastTense + suffix, undoable: true)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    /// Marks a thread read right away; reading is not something to undo.
    func markThreadRead(_ thread: ThreadID, messages: [MessageRecord]) {
        guard let accountFolders = folders[thread.accountId], let engine = engines[thread.accountId], let database else { return }
        let plan = ActionPlanner.plan(.markRead, messages: messages, folders: accountFolders, mailbox: mailbox.kind)
        guard !plan.isEmpty else { return }
        Task {
            do {
                try await database.writer.write { db in
                    for record in plan.updated { try record.update(db) }
                }
                try await engine.perform(plan.operations)
            } catch {
                showError("Could not mark as read: \(error.localizedDescription)")
            }
        }
    }

    private func selectNeighbor(excluding removed: Set<ThreadID>) {
        guard let current = selectedIndex ?? threads.firstIndex(where: { removed.contains($0.id) }) else { return }
        let after = threads[current...].first { !removed.contains($0.id) }
        let before = threads[..<current].last { !removed.contains($0.id) }
        if let next = after ?? before {
            selectedThreadID = next.id
            listScrollTarget = next.id
        } else {
            selectedThreadID = nil
        }
    }

    func undo() {
        guard let entry = undoStack.popLast() else {
            showToast("Nothing to undo")
            return
        }
        switch entry {
        case .action(let id):
            Task {
                if await actions.undo(id) {
                    showToast("Undone")
                } else {
                    showToast("Too late to undo")
                }
            }
        case .send(let outboxID):
            cancelSend(outboxID)
        }
    }

    // MARK: - Compose

    private func replyToFocused(_ mode: ReplyMode) {
        guard let detail, let message = detail.focusedMessage, let account = account(message.accountId) else {
            showToast("Select a conversation first")
            return
        }
        let parsed = message.id.flatMap { detail.parsed[$0] }
        composers.openReply(mode, to: message, parsed: parsed, account: account)
    }

    /// Opens a draft from `mailto:a@b.com?subject=Hi&cc=c@d.com&body=Text`.
    func composeTo(_ url: URL) {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let items = components?.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        let to = [components?.path, value("to")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        composers.openNew(to: to, cc: value("cc") ?? "", subject: value("subject") ?? "", body: value("body") ?? "")
    }

    // MARK: - Attachments

    func openAttachment(messageRowId: Int64, attachmentId: Int) {
        guard let attachment = detail?.parsed[messageRowId]?.attachments.first(where: { $0.id == attachmentId }) else { return }
        open(attachment)
    }

    private func openAllAttachments() {
        guard let detail, let message = detail.focusedMessage, let id = message.id,
              let attachments = detail.parsed[id]?.visibleAttachments, !attachments.isEmpty else {
            showToast("No attachments")
            return
        }
        attachments.forEach(open)
    }

    func open(_ attachment: MailAttachment) {
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("Poscar/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = attachment.filename.replacingOccurrences(of: "/", with: "-")
            let url = directory.appendingPathComponent(name.isEmpty ? "attachment" : name)
            try attachment.data.write(to: url)
            NSWorkspace.shared.open(url)
        } catch {
            showError("Could not open \(attachment.filename): \(error.localizedDescription)")
        }
    }
}

extension MailboxKind {
    var isLabel: Bool {
        if case .label = self { return true }
        return false
    }
}
