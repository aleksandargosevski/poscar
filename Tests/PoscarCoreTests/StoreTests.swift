import Foundation
import GRDB
import Testing
@testable import PoscarCore

@Suite struct StoreTests {
    let allMail = "[Gmail]/All Mail"
    let trash = "[Gmail]/Trash"

    func gmailFolders() -> AccountFolders {
        func folder(_ path: String, _ role: FolderRole) -> FolderRecord {
            FolderRecord(accountId: "g", folder: IMAPFolder(path: path, delimiter: "/", attributes: []), role: role, synced: true)
        }
        return AccountFolders(accountId: "g", isGmail: true, folders: [folder(allMail, .all), folder(trash, .trash)])
    }

    func message(uid: Int64, thread: String, labels: [String], seen: Bool = true, minutesAgo: Double = 0) -> MessageRecord {
        MessageRecord(
            id: nil, accountId: "g", folder: allMail, uid: uid, gmailMessageId: nil, threadKey: thread,
            messageId: "m\(uid)@x", inReplyTo: nil, references: "", subject: "Subject \(thread)",
            fromName: "Sender \(uid)", fromEmail: "s\(uid)@x.com", toAddresses: "me@x.com", ccAddresses: "", replyTo: "",
            date: Date().addingTimeInterval(-minutesAgo * 60), size: 100, seen: seen, flagged: false, answered: false,
            draft: false, labels: LabelSet.encode(labels), hasAttachments: false, snippet: "", hasBody: false, hidden: false
        )
    }

    func seed(_ database: MailDatabase) throws {
        try database.writer.write { db in
            var messages = [
                message(uid: 1, thread: "t1", labels: ["\\Inbox"], minutesAgo: 30),
                message(uid: 2, thread: "t1", labels: ["\\Inbox"], seen: false, minutesAgo: 10),
                message(uid: 3, thread: "t2", labels: ["\\Sent"], minutesAgo: 5),
                message(uid: 4, thread: "t3", labels: ["\\Inbox", "Posao"], minutesAgo: 1),
            ]
            for index in messages.indices { try messages[index].insert(db) }
        }
    }

    @Test func groupsInboxIntoThreads() throws {
        let database = try MailDatabase()
        try seed(database)
        let threads = try database.writer.read { db in
            try MailQueries.threads(db, mailbox: .unifiedInbox, accounts: [gmailFolders()], limit: 50)
        }
        #expect(threads.map(\.latest.threadKey) == ["t3", "t1"])
        #expect(threads[1].messageCount == 2)
        #expect(threads[1].unreadCount == 1)
        #expect(threads[1].latest.uid == 2)
        #expect(threads[1].participants.sorted() == ["Sender 1", "Sender 2"])

        let label = try database.writer.read { db in
            try MailQueries.threads(db, mailbox: Mailbox(accountId: "g", kind: .label("Posao")), accounts: [gmailFolders()], limit: 50)
        }
        #expect(label.map(\.latest.threadKey) == ["t3"])
    }

    /// Regression: the OR between accounts once escaped the per-thread filter and repeated one thread.
    @Test func unifiedMailboxKeepsThreadsOfSeveralAccountsApart() throws {
        let database = try MailDatabase()
        try seed(database)
        let imapFolders = AccountFolders(accountId: "i", isGmail: false, folders: [
            FolderRecord(accountId: "i", folder: IMAPFolder(path: "Sent", delimiter: "/", attributes: []), role: .sent, synced: true),
        ])
        try database.writer.write { db in
            for (uid, thread) in [(1, "a"), (2, "b"), (3, "b")] as [(Int64, String)] {
                var record = message(uid: uid, thread: thread, labels: [], minutesAgo: Double(uid))
                record.accountId = "i"
                record.folder = "Sent"
                try record.insert(db)
            }
        }
        let threads = try database.writer.read { db in
            try MailQueries.threads(db, mailbox: Mailbox(kind: .sent), accounts: [gmailFolders(), imapFolders], limit: 50)
        }
        #expect(Set(threads.map(\.id)).count == threads.count)
        #expect(threads.map(\.latest.threadKey).sorted() == ["a", "b", "t2"])
        #expect(threads.first { $0.latest.threadKey == "b" }?.latest.uid == 2)
    }

    @Test func imapAllMailCoversEveryFolderButTrashAndSpam() throws {
        let database = try MailDatabase()
        func folder(_ path: String, _ role: FolderRole?) -> FolderRecord {
            FolderRecord(accountId: "i", folder: IMAPFolder(path: path, delimiter: "/", attributes: []), role: role, synced: true)
        }
        let folders = AccountFolders(accountId: "i", isGmail: false, folders: [
            folder("INBOX", .inbox), folder("Archive", .archive), folder("Trash", .trash), folder("Spam", .junk), folder("Projekti", nil),
        ])
        try database.writer.write { db in
            for (uid, path) in [(1, "INBOX"), (2, "Archive"), (3, "Trash"), (4, "Spam"), (5, "Projekti")] as [(Int64, String)] {
                var record = message(uid: uid, thread: "t\(uid)", labels: [])
                record.accountId = "i"
                record.folder = path
                try record.insert(db)
            }
        }
        let threads = try database.writer.read { db in
            try MailQueries.threads(db, mailbox: Mailbox(kind: .archive), accounts: [folders], limit: 50)
        }
        #expect(Set(threads.map(\.latest.folder)) == ["INBOX", "Archive", "Projekti"])
    }

    @Test func archivePlanRemovesInboxLabel() throws {
        let database = try MailDatabase()
        try seed(database)
        let messages = try database.writer.read { db in
            try MailQueries.threadMessages(db, thread: ThreadID(accountId: "g", threadKey: "t1"), folders: gmailFolders(), inTrashOrSpam: false)
        }
        let plan = ActionPlanner.plan(.archive, messages: messages, folders: gmailFolders(), mailbox: .inbox)
        #expect(plan.operations == [.gmailLabels(folder: allMail, uids: [1, 2], add: false, labels: ["\\Inbox"])])
        #expect(plan.updated.allSatisfy { !$0.hasLabel("\\Inbox") })

        try database.writer.write { db in
            for var record in plan.updated { try record.update(db) }
        }
        let threads = try database.writer.read { db in
            try MailQueries.threads(db, mailbox: .unifiedInbox, accounts: [gmailFolders()], limit: 50)
        }
        #expect(threads.map(\.latest.threadKey) == ["t3"])
    }

    @Test func starAndUnreadTargetTheNewestMessage() throws {
        let database = try MailDatabase()
        try seed(database)
        let messages = try database.writer.read { db in
            try MailQueries.threadMessages(db, thread: ThreadID(accountId: "g", threadKey: "t1"), folders: gmailFolders(), inTrashOrSpam: false)
        }
        #expect(messages.map(\.uid) == [2, 1])
        let star = ActionPlanner.plan(.star, messages: messages, folders: gmailFolders(), mailbox: .inbox)
        #expect(star.operations == [.store(folder: allMail, uids: [2], operation: "+FLAGS.SILENT (\\Flagged)")])
        let unread = ActionPlanner.plan(.markUnread, messages: messages, folders: gmailFolders(), mailbox: .inbox)
        #expect(unread.operations == [.store(folder: allMail, uids: [1], operation: "-FLAGS.SILENT (\\Seen)")])
    }

    @Test func trashPlanMovesAndHides() throws {
        let database = try MailDatabase()
        try seed(database)
        let messages = try database.writer.read { db in
            try MailQueries.threadMessages(db, thread: ThreadID(accountId: "g", threadKey: "t3"), folders: gmailFolders(), inTrashOrSpam: false)
        }
        let plan = ActionPlanner.plan(.trash, messages: messages, folders: gmailFolders(), mailbox: .inbox)
        #expect(plan.operations == [.move(folder: allMail, uids: [4], destination: trash)])
        #expect(plan.updated.allSatisfy { $0.hidden })
    }

    @Test func searchesSubjectsAndParticipants() throws {
        let database = try MailDatabase()
        try database.writer.write { db in
            try db.execute(sql: "INSERT INTO message_fts (rowid, subject, participants, body) VALUES (1, 'Ponuda za sajt', 'Marko', 'Dobar dan')")
        }
        let hits = try database.writer.read { db in try MailQueries.search(db, query: "ponud") }
        #expect(hits == [1])
        let accentless = try database.writer.read { db in try MailQueries.search(db, query: "marko dobar") }
        #expect(accentless == [1])
    }
}
