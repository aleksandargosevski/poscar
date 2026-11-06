import Foundation
import GRDB

public final class MailDatabase: Sendable {
    public let writer: any DatabaseWriter

    public init(url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var configuration = Configuration()
            configuration.foreignKeysEnabled = true
            writer = try DatabasePool(path: url.path, configuration: configuration)
            try Self.migrator.migrate(writer)
        } catch {
            throw PoscarError.storage("Could not open the mail database: \(error.localizedDescription)")
        }
    }

    /// In-memory database for tests.
    public init() throws {
        var configuration = Configuration()
        configuration.foreignKeysEnabled = true
        writer = try DatabaseQueue(configuration: configuration)
        try Self.migrator.migrate(writer)
    }

    public static var defaultURL: URL {
        AppPaths.supportDirectory.appendingPathComponent("mail.sqlite")
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "folder") { table in
                table.column("accountId", .text).notNull()
                table.column("path", .text).notNull()
                table.column("name", .text).notNull()
                table.column("delimiter", .text)
                table.column("role", .text)
                table.column("synced", .boolean).notNull()
                table.column("uidValidity", .integer).notNull()
                table.column("maxUid", .integer).notNull()
                table.column("backfillCursor", .integer).notNull()
                table.column("backfillDone", .boolean).notNull()
                table.column("highestModSeq", .integer).notNull()
                table.primaryKey(["accountId", "path"])
            }

            try db.create(table: "message") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("accountId", .text).notNull()
                table.column("folder", .text).notNull()
                table.column("uid", .integer).notNull()
                table.column("gmailMessageId", .integer)
                table.column("threadKey", .text).notNull()
                table.column("messageId", .text)
                table.column("inReplyTo", .text)
                table.column("references", .text).notNull()
                table.column("subject", .text).notNull()
                table.column("fromName", .text).notNull()
                table.column("fromEmail", .text).notNull()
                table.column("toAddresses", .text).notNull()
                table.column("ccAddresses", .text).notNull()
                table.column("replyTo", .text).notNull()
                table.column("date", .datetime).notNull()
                table.column("size", .integer).notNull()
                table.column("seen", .boolean).notNull()
                table.column("flagged", .boolean).notNull()
                table.column("answered", .boolean).notNull()
                table.column("draft", .boolean).notNull()
                table.column("labels", .text).notNull()
                table.column("hasAttachments", .boolean).notNull()
                table.column("snippet", .text).notNull()
                table.column("hasBody", .boolean).notNull()
                table.column("hidden", .boolean).notNull().defaults(to: false)
                table.uniqueKey(["accountId", "folder", "uid"])
            }
            try db.create(index: "message_thread", on: "message", columns: ["accountId", "threadKey"])
            try db.create(index: "message_folder_date", on: "message", columns: ["accountId", "folder", "date"])
            try db.create(index: "message_date", on: "message", columns: ["date"])

            try db.create(table: "body") { table in
                table.column("messageRowId", .integer).primaryKey()
                    .references("message", onDelete: .cascade)
                table.column("raw", .blob).notNull()
            }

            try db.execute(sql: """
                CREATE VIRTUAL TABLE message_fts USING fts5(subject, participants, body, tokenize = 'unicode61 remove_diacritics 2');
                CREATE TRIGGER message_fts_delete AFTER DELETE ON message BEGIN
                    DELETE FROM message_fts WHERE rowid = old.id;
                END;
                """)

            try db.create(table: "outbox") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("accountId", .text).notNull()
                table.column("sendAt", .datetime).notNull()
                table.column("message", .blob).notNull()
                table.column("raw", .blob).notNull()
                table.column("messageId", .text).notNull()
                table.column("replyToMessageRowId", .integer)
                table.column("lastError", .text)
            }

            try db.create(table: "contact") { table in
                table.column("email", .text).primaryKey()
                table.column("name", .text).notNull()
                table.column("score", .integer).notNull()
                table.column("lastSeen", .datetime).notNull()
            }
        }
        migrator.registerMigration("v2-thread-indexes") { db in
            // Covering indexes for grouping a folder into threads and finding each thread's newest message.
            try db.drop(index: "message_thread")
            try db.create(index: "message_thread_date", on: "message", columns: ["accountId", "threadKey", "date"])
            try db.create(index: "message_folder_thread", on: "message", columns: ["accountId", "folder", "threadKey", "date"])
            try db.execute(sql: "ANALYZE")
        }
        migrator.registerMigration("v3-attachments") { db in
            try db.alter(table: "message") { table in
                table.add(column: "attachmentsIndexed", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "attachment") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("messageRowId", .integer).notNull().indexed().references("message", onDelete: .cascade)
                table.column("attachmentIndex", .integer).notNull()
                table.column("accountId", .text).notNull()
                table.column("filename", .text).notNull()
                table.column("mimeType", .text).notNull()
                table.column("kind", .text).notNull()
                table.column("size", .integer).notNull()
                table.column("date", .datetime).notNull()
                table.column("sender", .text).notNull()
                table.column("subject", .text).notNull()
                table.column("thumbnail", .blob)
            }
            try db.create(index: "attachment_date", on: "attachment", columns: ["date"])
        }
        return migrator
    }

    public func removeAccount(_ accountID: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM message WHERE accountId = ?", arguments: [accountID])
            try db.execute(sql: "DELETE FROM folder WHERE accountId = ?", arguments: [accountID])
            try db.execute(sql: "DELETE FROM outbox WHERE accountId = ?", arguments: [accountID])
        }
    }
}
