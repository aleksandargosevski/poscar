import Foundation

public enum CommandContext: String, Sendable {
    /// The main window: lists and the reading pane.
    case mail
    /// A compose window.
    case composer
}

public enum CommandCategory: String, CaseIterable, Sendable {
    case navigation = "Navigation"
    case actions = "Actions"
    case compose = "Compose"
    case goTo = "Go to"
    case app = "App"
    case composer = "Composer"
}

/// Every action that can be triggered from the keyboard, the command palette or a button.
public enum CommandID: String, CaseIterable, Codable, Sendable {
    // Navigation
    case nextThread, previousThread, openThread, backToList, nextMessage, previousMessage, firstThread, lastThread
    case scrollDown, scrollUp
    // Actions
    case archive, trash, spam, toggleStar, markRead, markUnread, toggleSelection, selectAll, deselectAll
    case label, moveTo, removeLabel, moveToInbox, undo, loadImages, openAttachments
    // Compose
    case compose, reply, replyAll, forward
    // Go to
    case goInbox, goStarred, goSent, goDrafts, goAllMail, goSpam, goTrash, goLabel, goScheduled, goAttachments
    case goUnified, goAccount1, goAccount2, goAccount3, goAccount4, goAccount5
    // App
    case search, showActions, commandPalette, showShortcuts, refresh, toggleSidebar, escape
    // Composer
    case send, sendLater, attachFile, toggleCcBcc, togglePreview, discardDraft, closeComposer

    public var title: String {
        switch self {
        case .nextThread: "Next conversation"
        case .previousThread: "Previous conversation"
        case .openThread: "Open conversation"
        case .backToList: "Back to list"
        case .nextMessage: "Next message"
        case .previousMessage: "Previous message"
        case .firstThread: "First conversation"
        case .lastThread: "Last conversation"
        case .scrollDown: "Scroll down"
        case .scrollUp: "Scroll up"
        case .archive: "Archive"
        case .trash: "Delete"
        case .spam: "Report spam"
        case .toggleStar: "Star"
        case .markRead: "Mark as read"
        case .markUnread: "Mark as unread"
        case .toggleSelection: "Select conversation"
        case .selectAll: "Select all"
        case .deselectAll: "Deselect all"
        case .label: "Label as…"
        case .moveTo: "Move to…"
        case .removeLabel: "Remove label"
        case .moveToInbox: "Move to Inbox"
        case .undo: "Undo"
        case .loadImages: "Load images"
        case .openAttachments: "Open attachments"
        case .compose: "Compose"
        case .reply: "Reply"
        case .replyAll: "Reply all"
        case .forward: "Forward"
        case .goInbox: "Go to Inbox"
        case .goStarred: "Go to Starred"
        case .goSent: "Go to Sent"
        case .goDrafts: "Go to Drafts"
        case .goAllMail: "Go to All Mail"
        case .goSpam: "Go to Spam"
        case .goTrash: "Go to Trash"
        case .goLabel: "Go to label…"
        case .goScheduled: "Go to Scheduled"
        case .goAttachments: "Go to Attachments"
        case .goUnified: "All accounts"
        case .goAccount1: "Account 1"
        case .goAccount2: "Account 2"
        case .goAccount3: "Account 3"
        case .goAccount4: "Account 4"
        case .goAccount5: "Account 5"
        case .search: "Search"
        case .toggleSidebar: "Toggle sidebar"
        case .showActions: "Actions"
        case .commandPalette: "All commands"
        case .showShortcuts: "Keyboard shortcuts"
        case .refresh: "Check for mail"
        case .escape: "Close / clear"
        case .send: "Send"
        case .sendLater: "Send later…"
        case .attachFile: "Attach file"
        case .toggleCcBcc: "Show Cc and Bcc"
        case .togglePreview: "Preview"
        case .discardDraft: "Discard draft"
        case .closeComposer: "Close"
        }
    }

    public var category: CommandCategory {
        switch self {
        case .nextThread, .previousThread, .openThread, .backToList, .nextMessage, .previousMessage, .firstThread, .lastThread,
             .scrollDown, .scrollUp:
            .navigation
        case .archive, .trash, .spam, .toggleStar, .markRead, .markUnread, .toggleSelection, .selectAll, .deselectAll,
             .label, .moveTo, .removeLabel, .moveToInbox, .undo, .loadImages, .openAttachments:
            .actions
        case .compose, .reply, .replyAll, .forward:
            .compose
        case .goInbox, .goStarred, .goSent, .goDrafts, .goAllMail, .goSpam, .goTrash, .goLabel, .goScheduled, .goAttachments,
             .goUnified, .goAccount1, .goAccount2, .goAccount3, .goAccount4, .goAccount5:
            .goTo
        case .search, .showActions, .commandPalette, .showShortcuts, .refresh, .toggleSidebar, .escape:
            .app
        case .send, .sendLater, .attachFile, .toggleCcBcc, .togglePreview, .discardDraft, .closeComposer:
            .composer
        }
    }

    public var context: CommandContext {
        category == .composer ? .composer : .mail
    }

    /// Hidden from the command palette because they make no sense without a key.
    public var isPaletteHidden: Bool {
        [.escape, .commandPalette, .showActions, .scrollDown, .scrollUp].contains(self) || context == .composer
    }

    public var accountIndex: Int? {
        switch self {
        case .goAccount1: 0
        case .goAccount2: 1
        case .goAccount3: 2
        case .goAccount4: 3
        case .goAccount5: 4
        default: nil
        }
    }
}
