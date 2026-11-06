import Foundation
import GRDB

public struct ThreadSummary: Identifiable, Hashable, Sendable, FetchableRecord {
    public var latest: MessageRecord
    public var messageCount: Int
    public var unreadCount: Int
    public var isFlagged: Bool
    public var hasAttachments: Bool
    public var participants: [String]

    public var id: ThreadID { ThreadID(accountId: latest.accountId, threadKey: latest.threadKey) }
    public var isUnread: Bool { unreadCount > 0 }

    public init(row: Row) throws {
        latest = try MessageRecord(row: row)
        messageCount = row["messageCount"]
        unreadCount = row["unreadCount"]
        isFlagged = row["anyFlagged"]
        hasAttachments = row["anyAttachment"]
        let names: String = row["participantList"] ?? ""
        participants = names.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

public struct ThreadID: Hashable, Codable, Sendable {
    public var accountId: String
    public var threadKey: String

    public init(accountId: String, threadKey: String) {
        self.accountId = accountId
        self.threadKey = threadKey
    }
}

public enum MailQueries {
    /// Threads of a mailbox, newest first. `restrictTo` limits the result to search hits.
    public static func threads(
        _ db: Database,
        mailbox: Mailbox,
        accounts: [AccountFolders],
        restrictTo messageIDs: [Int64]? = nil,
        limit: Int
    ) throws -> [ThreadSummary] {
        let relevant = accounts.filter { mailbox.accountId == nil || $0.accountId == mailbox.accountId }
        guard !relevant.isEmpty else { return [] }

        var condition = relevant.map { $0.condition(for: mailbox.kind) }.joined(operator: .or)
        if let messageIDs {
            condition = condition && messageIDs.contains(Column("id"))
        }
        let request = SQLRequest<ThreadSummary>(literal: """
            SELECT latest.*, thread.messageCount, thread.unreadCount, thread.anyFlagged, thread.anyAttachment, thread.participantList
            FROM (
                SELECT accountId, threadKey, MAX(date) AS lastDate, COUNT(*) AS messageCount,
                       SUM(CASE WHEN seen THEN 0 ELSE 1 END) AS unreadCount,
                       MAX(flagged) AS anyFlagged, MAX(hasAttachments) AS anyAttachment,
                       GROUP_CONCAT(DISTINCT CASE WHEN fromName = '' THEN fromEmail ELSE fromName END) AS participantList
                FROM message
                WHERE hidden = 0 AND (\(condition))
                GROUP BY accountId, threadKey
                ORDER BY lastDate DESC
                LIMIT \(limit)
            ) AS thread
            JOIN message AS latest ON latest.id = (
                SELECT id FROM message
                WHERE accountId = thread.accountId AND threadKey = thread.threadKey AND hidden = 0 AND (\(condition))
                ORDER BY date DESC LIMIT 1
            )
            ORDER BY thread.lastDate DESC
            """)
        return try request.fetchAll(db)
    }

    /// All messages of a thread, newest first, without duplicates copied across folders.
    public static func threadMessages(_ db: Database, thread: ThreadID, folders: AccountFolders, inTrashOrSpam: Bool) throws -> [MessageRecord] {
        let trashAndSpam = [folders.path(for: .trash), folders.path(for: .junk)].compactMap { $0 }
        var request = MessageRecord
            .filter(Column("accountId") == thread.accountId && Column("threadKey") == thread.threadKey && Column("hidden") == false)
            .order(Column("date").desc)
        request = inTrashOrSpam
            ? request.filter(trashAndSpam.contains(Column("folder")))
            : request.filter(!trashAndSpam.contains(Column("folder")))

        var seen = Set<String>()
        return try request.fetchAll(db).filter { message in
            guard let messageId = message.messageId else { return true }
            return seen.insert(messageId).inserted
        }
    }

    public static func unreadInboxThreads(_ db: Database, accounts: [AccountFolders]) throws -> Int {
        guard !accounts.isEmpty else { return 0 }
        let condition = accounts.map { $0.condition(for: .inbox) }.joined(operator: .or)
        let request = SQLRequest<Int>(literal: """
            SELECT COUNT(DISTINCT accountId || ':' || threadKey) FROM message
            WHERE hidden = 0 AND seen = 0 AND (\(condition))
            """)
        return try request.fetchOne(db) ?? 0
    }

    public static func folders(_ db: Database, accountId: String) throws -> [FolderRecord] {
        try FolderRecord.filter(Column("accountId") == accountId).fetchAll(db)
    }

    /// Full-text search over subject, participants and downloaded bodies.
    public static func search(_ db: Database, query: String, limit: Int = 500) throws -> [Int64] {
        let terms = query.split(whereSeparator: \.isWhitespace)
            .map { $0.replacingOccurrences(of: "\"", with: "") }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }
        let pattern = terms.map { "\"\($0)\"*" }.joined(separator: " ")
        return try Int64.fetchAll(db, sql: "SELECT rowid FROM message_fts WHERE message_fts MATCH ? LIMIT ?", arguments: [pattern, limit])
    }

    public static func contacts(_ db: Database, matching prefix: String, limit: Int = 8) throws -> [ContactRecord] {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return try ContactRecord.order(Column("score").desc, Column("lastSeen").desc).limit(limit).fetchAll(db)
        }
        let like = "%\(trimmed.replacingOccurrences(of: "%", with: ""))%"
        return try ContactRecord
            .filter(Column("email").like(like) || Column("name").like(like))
            .order(Column("score").desc, Column("lastSeen").desc)
            .limit(limit)
            .fetchAll(db)
    }

    public static func body(_ db: Database, messageRowId: Int64) throws -> Data? {
        try Data.fetchOne(db, sql: "SELECT raw FROM body WHERE messageRowId = ?", arguments: [messageRowId])
    }

    public static func recordContacts(_ db: Database, _ addresses: [EmailAddress], weight: Int, date: Date) throws {
        for address in addresses where address.isValid {
            let email = address.email.lowercased()
            try db.execute(sql: """
                INSERT INTO contact (email, name, score, lastSeen) VALUES (?, ?, ?, ?)
                ON CONFLICT(email) DO UPDATE SET
                    score = score + excluded.score,
                    name = CASE WHEN excluded.name != '' THEN excluded.name ELSE name END,
                    lastSeen = MAX(lastSeen, excluded.lastSeen)
                """, arguments: [email, address.name, weight, date])
        }
    }
}
