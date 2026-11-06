import Foundation
import GRDB

public enum MailboxKind: Hashable, Codable, Sendable {
    case inbox, starred, sent, drafts, archive, spam, trash
    case label(String)
    /// Every folder of every account; used for searching everywhere.
    case everywhere

    public var title: String {
        switch self {
        case .inbox: "Inbox"
        case .starred: "Starred"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .archive: "All Mail"
        case .spam: "Spam"
        case .trash: "Trash"
        case .label(let name): name
        case .everywhere: "Everywhere"
        }
    }

    public var systemImage: String {
        switch self {
        case .inbox: "tray"
        case .starred: "star"
        case .sent: "paperplane"
        case .drafts: "doc"
        case .archive: "archivebox"
        case .spam: "xmark.octagon"
        case .trash: "trash"
        case .label: "tag"
        case .everywhere: "magnifyingglass"
        }
    }

    public var isTrashOrSpam: Bool { self == .trash || self == .spam }

    public static let standard: [MailboxKind] = [.inbox, .starred, .sent, .drafts, .archive, .spam, .trash]
}

/// A mailbox in one account, or across all accounts when `accountId` is nil.
public struct Mailbox: Hashable, Codable, Sendable {
    public var accountId: String?
    public var kind: MailboxKind

    public init(accountId: String? = nil, kind: MailboxKind) {
        self.accountId = accountId
        self.kind = kind
    }

    public static let unifiedInbox = Mailbox(kind: .inbox)
}

/// Folder layout of one account, needed to turn a mailbox into SQL.
public struct AccountFolders: Sendable, Hashable {
    public var accountId: String
    public var isGmail: Bool
    public var folders: [FolderRecord]

    public init(accountId: String, isGmail: Bool, folders: [FolderRecord]) {
        self.accountId = accountId
        self.isGmail = isGmail
        self.folders = folders
    }

    public func path(for role: FolderRole) -> String? {
        folders.first { $0.role == role }?.path
    }

    public var allMailPath: String? { path(for: .all) }

    /// Labels (Gmail) or folders (IMAP) the user created.
    public var userLabels: [FolderRecord] {
        folders.filter { folder in
            guard folder.role == nil else { return false }
            if isGmail { return !folder.path.hasPrefix("[Gmail]") && !folder.path.hasPrefix("[Google Mail]") }
            return true
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The SQL condition selecting messages of this account that belong to the mailbox.
    func condition(for kind: MailboxKind) -> SQLExpression {
        let account = Column("accountId") == accountId
        return account && (isGmail ? gmailCondition(kind) : imapCondition(kind))
    }

    private func gmailCondition(_ kind: MailboxKind) -> SQLExpression {
        let allMail = Column("folder") == (allMailPath ?? "")
        switch kind {
        case .inbox: return allMail && hasLabel("\\Inbox")
        case .starred: return allMail && Column("flagged") == true
        case .sent: return allMail && hasLabel("\\Sent")
        case .drafts: return allMail && hasLabel("\\Draft")
        case .archive: return allMail
        case .spam: return Column("folder") == (path(for: .junk) ?? "")
        case .trash: return Column("folder") == (path(for: .trash) ?? "")
        case .label(let name): return allMail && hasLabel(name)
        case .everywhere: return true.sqlExpression
        }
    }

    private func imapCondition(_ kind: MailboxKind) -> SQLExpression {
        func folder(_ role: FolderRole) -> SQLExpression {
            Column("folder") == (path(for: role) ?? "\u{0}")
        }
        switch kind {
        case .inbox: return folder(.inbox)
        case .starred:
            return Column("flagged") == true && !trashAndJunk.contains(Column("folder"))
        case .sent: return folder(.sent)
        case .drafts: return folder(.drafts)
        // Like Gmail's All Mail: every folder except Trash and Spam.
        case .archive: return !trashAndJunk.contains(Column("folder"))
        case .spam: return folder(.junk)
        case .trash: return folder(.trash)
        case .label(let path): return Column("folder") == path
        case .everywhere: return true.sqlExpression
        }
    }

    private var trashAndJunk: [String] {
        [path(for: .trash), path(for: .junk)].compactMap { $0 }
    }

    private func hasLabel(_ label: String) -> SQLExpression {
        SQL("instr(labels, \(LabelSet.token(label))) > 0").sqlExpression
    }
}
