import Foundation

public enum MailAction: Sendable, Hashable {
    case archive
    case trash
    case spam
    case notSpam
    case markRead
    case markUnread
    case star
    case unstar
    case addLabel(String)
    case removeLabel(String)
    case moveTo(String)
    case moveToInbox

    public var pastTense: String {
        switch self {
        case .archive: "Archived"
        case .trash: "Moved to Trash"
        case .spam: "Marked as spam"
        case .notSpam: "Moved to Inbox"
        case .markRead: "Marked as read"
        case .markUnread: "Marked as unread"
        case .star: "Starred"
        case .unstar: "Unstarred"
        case .addLabel(let label): "Labeled \(label)"
        case .removeLabel(let label): "Removed \(label)"
        case .moveTo(let label): "Moved to \(label)"
        case .moveToInbox: "Moved to Inbox"
        }
    }

    /// Whether the thread leaves the current list once the action is applied.
    public func removesThread(from mailbox: MailboxKind) -> Bool {
        switch self {
        case .archive: mailbox == .inbox
        case .trash, .spam, .notSpam, .moveTo: true
        case .moveToInbox: mailbox != .inbox
        case .removeLabel(let label): mailbox == .label(label)
        case .unstar: mailbox == .starred
        default: false
        }
    }
}

/// Optimistic local state plus the server commands that make it real.
public struct ActionPlan: Sendable {
    public var original: [MessageRecord]
    public var updated: [MessageRecord]
    public var operations: [RemoteOperation]

    public init(original: [MessageRecord], updated: [MessageRecord], operations: [RemoteOperation]) {
        self.original = original
        self.updated = updated
        self.operations = operations
    }

    public var isEmpty: Bool { operations.isEmpty }
}

public enum ActionPlanner {
    /// `messages` must be newest first, as returned by `MailQueries.threadMessages`.
    public static func plan(_ action: MailAction, messages: [MessageRecord], folders: AccountFolders, mailbox: MailboxKind) -> ActionPlan {
        var builder = PlanBuilder(messages: messages)
        if folders.isGmail {
            planGmail(action, folders: folders, mailbox: mailbox, builder: &builder)
        } else {
            planIMAP(action, folders: folders, mailbox: mailbox, builder: &builder)
        }
        return builder.plan
    }

    private static func planGmail(_ action: MailAction, folders: AccountFolders, mailbox: MailboxKind, builder: inout PlanBuilder) {
        let allMail = folders.allMailPath ?? ""
        let inAllMail = builder.messages.filter { $0.folder == allMail }
        let inTrashOrSpam = builder.messages.filter { $0.folder != allMail }

        switch action {
        case .archive:
            builder.changeLabels(inAllMail.filter { $0.hasLabel("\\Inbox") }, folder: allMail, add: false, labels: ["\\Inbox"])
        case .trash:
            if mailbox == .trash {
                builder.expunge(inTrashOrSpam)
            } else if let trash = folders.path(for: .trash) {
                builder.move(builder.messages.filter { $0.folder != trash }, to: trash)
            }
        case .spam:
            if let junk = folders.path(for: .junk) { builder.move(inAllMail, to: junk) }
        case .notSpam:
            builder.move(inTrashOrSpam, to: "INBOX")
        case .markRead:
            builder.setFlag("\\Seen", on: true, builder.messages.filter { !$0.seen })
        case .markUnread:
            builder.setFlag("\\Seen", on: false, builder.messages.filter(\.seen).prefix(1))
        case .star:
            builder.setFlag("\\Flagged", on: true, builder.messages.prefix(1))
        case .unstar:
            builder.setFlag("\\Flagged", on: false, builder.messages.filter(\.flagged))
        case .addLabel(let label):
            builder.changeLabels(inAllMail.filter { !$0.hasLabel(label) }, folder: allMail, add: true, labels: [label])
        case .removeLabel(let label):
            builder.changeLabels(inAllMail.filter { $0.hasLabel(label) }, folder: allMail, add: false, labels: [label])
        case .moveTo(let label):
            builder.changeLabels(inAllMail.filter { !$0.hasLabel(label) }, folder: allMail, add: true, labels: [label])
            if mailbox == .inbox {
                builder.changeLabels(inAllMail.filter { $0.hasLabel("\\Inbox") }, folder: allMail, add: false, labels: ["\\Inbox"])
            } else if case .label(let current) = mailbox, current != label {
                builder.changeLabels(inAllMail.filter { $0.hasLabel(current) }, folder: allMail, add: false, labels: [current])
            }
        case .moveToInbox:
            builder.changeLabels(inAllMail.filter { !$0.hasLabel("\\Inbox") }, folder: allMail, add: true, labels: ["\\Inbox"])
            builder.move(inTrashOrSpam, to: "INBOX")
        }
    }

    private static func planIMAP(_ action: MailAction, folders: AccountFolders, mailbox: MailboxKind, builder: inout PlanBuilder) {
        let viewFolder: String? = {
            switch mailbox {
            case .inbox: folders.path(for: .inbox)
            case .sent: folders.path(for: .sent)
            case .drafts: folders.path(for: .drafts)
            case .spam: folders.path(for: .junk)
            case .trash: folders.path(for: .trash)
            case .label(let path): path
            case .starred, .archive, .everywhere: nil
            }
        }()
        let excluded = Set([folders.path(for: .trash), folders.path(for: .junk), folders.path(for: .sent)].compactMap { $0 })
        let inView = viewFolder.map { path in builder.messages.filter { $0.folder == path } }
            ?? builder.messages.filter { !excluded.contains($0.folder) }

        switch action {
        case .archive:
            if let archive = folders.path(for: .archive) {
                builder.move(inView.filter { $0.folder != archive }, to: archive)
            } else {
                builder.operations.append(.createFolder("Archive"))
                builder.move(inView, to: "Archive")
            }
        case .trash:
            if let trash = folders.path(for: .trash), mailbox != .trash {
                builder.move(inView, to: trash)
            } else {
                builder.expunge(inView)
            }
        case .spam:
            if let junk = folders.path(for: .junk) { builder.move(inView, to: junk) }
        case .notSpam, .moveToInbox:
            builder.move(inView.filter { $0.folder != "INBOX" }, to: folders.path(for: .inbox) ?? "INBOX")
        case .markRead:
            builder.setFlag("\\Seen", on: true, builder.messages.filter { !$0.seen })
        case .markUnread:
            builder.setFlag("\\Seen", on: false, builder.messages.filter(\.seen).prefix(1))
        case .star:
            builder.setFlag("\\Flagged", on: true, (inView.isEmpty ? builder.messages : inView).prefix(1))
        case .unstar:
            builder.setFlag("\\Flagged", on: false, builder.messages.filter(\.flagged))
        case .addLabel(let path), .moveTo(let path):
            builder.move(inView.filter { $0.folder != path }, to: path)
        case .removeLabel:
            break
        }
    }
}

struct PlanBuilder {
    let messages: [MessageRecord]
    var updated: [Int64: MessageRecord] = [:]
    var operations: [RemoteOperation] = []

    init(messages: [MessageRecord]) {
        self.messages = messages
    }

    var plan: ActionPlan {
        let changedIDs = Set(updated.keys)
        return ActionPlan(
            original: messages.filter { changedIDs.contains($0.id ?? -1) },
            updated: Array(updated.values),
            operations: operations
        )
    }

    mutating func update(_ message: MessageRecord, _ change: (inout MessageRecord) -> Void) {
        guard let id = message.id else { return }
        var record = updated[id] ?? message
        change(&record)
        updated[id] = record
    }

    mutating func move(_ targets: [MessageRecord], to destination: String) {
        for (folder, group) in Dictionary(grouping: targets, by: \.folder) {
            operations.append(.move(folder: folder, uids: uids(group), destination: destination))
            group.forEach { update($0) { $0.hidden = true } }
        }
    }

    mutating func expunge(_ targets: [MessageRecord]) {
        for (folder, group) in Dictionary(grouping: targets, by: \.folder) {
            operations.append(.expunge(folder: folder, uids: uids(group)))
            group.forEach { update($0) { $0.hidden = true } }
        }
    }

    mutating func setFlag<S: Sequence>(_ flag: String, on: Bool, _ targets: S) where S.Element == MessageRecord {
        let list = Array(targets)
        for (folder, group) in Dictionary(grouping: list, by: \.folder) {
            operations.append(.store(folder: folder, uids: uids(group), operation: "\(on ? "+" : "-")FLAGS.SILENT (\(flag))"))
            for message in group {
                update(message) { record in
                    if flag == "\\Seen" { record.seen = on } else { record.flagged = on }
                }
            }
        }
    }

    mutating func changeLabels(_ targets: [MessageRecord], folder: String, add: Bool, labels: [String]) {
        guard !targets.isEmpty else { return }
        operations.append(.gmailLabels(folder: folder, uids: uids(targets), add: add, labels: labels))
        for message in targets {
            update(message) { record in
                var current = record.labelList
                if add {
                    current += labels.filter { !current.contains($0) }
                } else {
                    current.removeAll { labels.contains($0) }
                }
                record.labels = LabelSet.encode(current)
            }
        }
    }

    private func uids(_ group: [MessageRecord]) -> [UInt32] {
        group.map { UInt32(truncatingIfNeeded: $0.uid) }.sorted()
    }
}
