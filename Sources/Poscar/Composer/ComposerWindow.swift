import AppKit
import PoscarCore
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ComposerManager {
    private unowned let model: AppModel
    private var controllers: [ComposerController] = []

    init(model: AppModel) {
        self.model = model
    }

    func controller(for window: NSWindow) -> ComposerController? {
        controllers.first { $0.window === window }
    }

    /// New mail goes out from the account in scope, or the first account.
    func openNew(to: String = "", cc: String = "", subject: String = "", body: String = "") {
        guard let account = model.mailbox.accountId.flatMap(model.account) ?? model.accounts.first else {
            model.showToast("Add an account first")
            return
        }
        let draft = ComposerModel.new(account: account, to: to)
        draft.cc = cc
        draft.showCcBcc = !cc.isEmpty
        draft.subject = subject
        draft.body = body + draft.body
        draft.markClean()
        open(draft)
    }

    func openReply(_ mode: ReplyMode, to message: MessageRecord, parsed: ParsedMessage?, account: Account) {
        open(ComposerModel.reply(mode, to: message, parsed: parsed, account: account))
    }

    func reopen(_ record: OutboxRecord, error: String?) {
        do {
            let draft = try ComposerModel.restored(from: record)
            draft.error = error
            open(draft)
        } catch {
            model.showError("Could not restore the draft: \(error.localizedDescription)")
        }
    }

    private func open(_ draft: ComposerModel) {
        let controller = ComposerController(draft: draft, model: model, manager: self)
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closed(_ controller: ComposerController) {
        controllers.removeAll { $0 === controller }
    }
}

@MainActor
final class ComposerController: NSWindowController, NSWindowDelegate {
    let draft: ComposerModel
    private unowned let model: AppModel
    private weak var manager: ComposerManager?
    private var forceClose = false

    init(draft: ComposerModel, model: AppModel, manager: ComposerManager) {
        self.draft = draft
        self.model = model
        self.manager = manager
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = draft.windowTitle
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 480, height: 360)
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ComposerView(draft: draft, controller: self).environment(model))
        window.center()
        window.setFrameAutosaveName("PoscarComposer")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func updateTitle() {
        window?.title = draft.windowTitle
    }

    // MARK: - Keys and commands

    func handleKey(_ chord: KeyChord, isTyping: Bool) -> Bool {
        if draft.handleSuggestionKey(chord) { return true }
        if draft.showingSendLater {
            if chord.key == "esc" {
                draft.showingSendLater = false
                return true
            }
            if chord.modifiers.isEmpty, let number = Int(chord.key), let option = SendLaterOption.all[safe: number - 1] {
                send(at: option.date())
                return true
            }
        }
        guard let command = model.keymap.bindings(for: .composer)[KeySequence([chord])] else { return false }
        perform(command)
        return true
    }

    func perform(_ command: CommandID) {
        switch command {
        case .send: send(at: nil)
        case .sendLater: draft.showingSendLater.toggle()
        case .attachFile: chooseAttachments()
        case .toggleCcBcc: draft.showCcBcc.toggle()
        case .togglePreview: draft.showingPreview.toggle()
        case .discardDraft:
            forceClose = true
            window?.close()
        case .closeComposer: window?.performClose(nil)
        default: break
        }
    }

    func send(at date: Date?) {
        guard !draft.isSending, let account = model.account(draft.accountId) else { return }
        do {
            let message = try draft.outgoingMessage(from: account)
            if message.subject.trimmingCharacters(in: .whitespaces).isEmpty, !confirm("Send without a subject?") { return }
            draft.isSending = true
            draft.showingSendLater = false
            Task {
                do {
                    try await model.enqueueSend(message, account: account, replyToRowId: draft.replyToRowId, sendAt: date)
                    forceClose = true
                    window?.close()
                } catch {
                    draft.error = error.localizedDescription
                }
                draft.isSending = false
            }
        } catch {
            draft.error = error.localizedDescription
        }
    }

    func chooseAttachments() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK else { return }
            self?.draft.addAttachments(panel.urls)
        }
    }

    // MARK: - Window

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if forceClose || !draft.isDirty { return true }
        let alert = NSAlert()
        alert.messageText = "Discard this draft?"
        alert.informativeText = "Pošćar does not save drafts yet."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep Editing")
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.forceClose = true
            sender.close()
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        manager?.closed(self)
    }

    private func confirm(_ question: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = question
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

struct SendLaterOption {
    let title: String
    let date: () -> Date

    static var all: [SendLaterOption] {
        let calendar = Calendar.current
        func at(_ hour: Int, daysFromNow: Int) -> Date {
            let day = calendar.date(byAdding: .day, value: daysFromNow, to: Date()) ?? Date()
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day) ?? day
        }
        func nextMonday() -> Date {
            let weekday = calendar.component(.weekday, from: Date())
            let days = (9 - weekday) % 7 == 0 ? 7 : (9 - weekday) % 7
            return at(8, daysFromNow: days)
        }
        return [
            SendLaterOption(title: "In 1 hour") { Date().addingTimeInterval(3600) },
            SendLaterOption(title: "Tomorrow morning, 8:00") { at(8, daysFromNow: 1) },
            SendLaterOption(title: "Tomorrow afternoon, 13:00") { at(13, daysFromNow: 1) },
            SendLaterOption(title: "Monday morning, 8:00") { nextMonday() },
        ]
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
