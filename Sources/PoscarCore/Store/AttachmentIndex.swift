import Foundation
import GRDB
import UniformTypeIdentifiers

public enum AttachmentKind: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case image, pdf, document, spreadsheet, presentation, archive, other

    public var title: String {
        switch self {
        case .image: "Images"
        case .pdf: "PDFs"
        case .document: "Documents"
        case .spreadsheet: "Spreadsheets"
        case .presentation: "Presentations"
        case .archive: "Archives"
        case .other: "Other"
        }
    }

    public var systemImage: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .presentation: "rectangle.on.rectangle"
        case .archive: "doc.zipper"
        case .other: "doc"
        }
    }

    /// Classifies by MIME type and extension; senders often use `application/octet-stream`.
    public static func classify(filename: String, mimeType: String) -> AttachmentKind {
        let ext = (filename as NSString).pathExtension.lowercased()
        let declared = mimeType.lowercased() == "application/octet-stream" ? nil : UTType(mimeType: mimeType)
        let types = [declared, UTType(filenameExtension: ext)].compactMap { $0 }
        if types.contains(where: { $0.conforms(to: .pdf) }) { return .pdf }
        if types.contains(where: { $0.conforms(to: .image) }) { return .image }
        if types.contains(where: { $0.conforms(to: .spreadsheet) }) || ["xls", "xlsx", "csv", "numbers", "ods"].contains(ext) { return .spreadsheet }
        if types.contains(where: { $0.conforms(to: .presentation) }) || ["ppt", "pptx", "key", "odp"].contains(ext) { return .presentation }
        // Extension-based archive types are too broad (".bin" counts as MacBinary), so only known ones count.
        if declared?.conforms(to: .archive) == true || ["zip", "rar", "7z", "gz", "tgz", "tar", "bz2", "xz"].contains(ext) { return .archive }
        if ["doc", "docx", "pages", "odt", "rtf", "txt", "md"].contains(ext) || types.contains(where: { $0.conforms(to: .text) }) {
            return .document
        }
        return .other
    }
}

/// One attachment of a downloaded message, with its preview, for the Attachments library.
public struct AttachmentRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "attachment"

    public var id: Int64?
    public var messageRowId: Int64
    /// The attachment's id within its parsed message.
    public var attachmentIndex: Int
    public var accountId: String
    public var filename: String
    public var mimeType: String
    public var kind: AttachmentKind
    public var size: Int
    public var date: Date
    public var sender: String
    public var subject: String
    public var thumbnail: Data?

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct AttachmentFilter: Equatable, Sendable {
    public var text = ""
    public var kind: AttachmentKind?
    public var accountId: String?

    public init(text: String = "", kind: AttachmentKind? = nil, accountId: String? = nil) {
        self.text = text
        self.kind = kind
        self.accountId = accountId
    }
}

public enum AttachmentIndex {
    /// Rows describing the visible attachments of one message.
    static func records(for message: MessageRecord, parsed: ParsedMessage) -> [AttachmentRecord] {
        guard let rowId = message.id else { return [] }
        return parsed.visibleAttachments.map { attachment in
            AttachmentRecord(
                id: nil,
                messageRowId: rowId,
                attachmentIndex: attachment.id,
                accountId: message.accountId,
                filename: attachment.filename,
                mimeType: attachment.mimeType,
                kind: AttachmentKind.classify(filename: attachment.filename, mimeType: attachment.mimeType),
                size: attachment.data.count,
                date: message.date,
                sender: message.from.displayName,
                subject: message.subject,
                thumbnail: AttachmentThumbnails.thumbnail(for: attachment)
            )
        }
    }

    static func replace(_ records: [AttachmentRecord], messageRowId: Int64, in db: Database) throws {
        try db.execute(sql: "DELETE FROM attachment WHERE messageRowId = ?", arguments: [messageRowId])
        for var record in records { try record.insert(db) }
    }

    /// Indexes messages downloaded before the library existed, a batch at a time.
    /// Returns the number of messages processed; 0 means everything is indexed.
    public static func backfill(_ database: MailDatabase, batchSize: Int = 20) async throws -> Int {
        let pending = try await database.writer.read { db in
            try MessageRecord.fetchAll(db, sql: """
                SELECT message.* FROM message
                WHERE hasBody = 1 AND hasAttachments = 1 AND attachmentsIndexed = 0
                ORDER BY date DESC LIMIT ?
                """, arguments: [batchSize])
        }
        guard !pending.isEmpty else { return 0 }

        var batch: [(Int64, [AttachmentRecord])] = []
        for message in pending {
            guard let id = message.id,
                  let raw = try await database.writer.read({ db in try MailQueries.body(db, messageRowId: id) }) else { continue }
            batch.append((id, records(for: message, parsed: MIMEParser.parse(raw))))
        }
        let ids = pending.compactMap(\.id)
        let indexed = batch
        try await database.writer.write { db in
            for (id, records) in indexed { try replace(records, messageRowId: id, in: db) }
            try db.execute(literal: "UPDATE message SET attachmentsIndexed = 1 WHERE id IN \(ids)")
        }
        return pending.count
    }

    public static func fetch(_ db: Database, filter: AttachmentFilter, limit: Int = 600) throws -> [AttachmentRecord] {
        var request = AttachmentRecord.order(Column("date").desc).limit(limit)
        if let kind = filter.kind { request = request.filter(Column("kind") == kind.rawValue) }
        if let accountId = filter.accountId { request = request.filter(Column("accountId") == accountId) }
        let text = filter.text.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty {
            let pattern = "%\(text.replacingOccurrences(of: "%", with: ""))%"
            request = request.filter(Column("filename").like(pattern) || Column("sender").like(pattern) || Column("subject").like(pattern))
        }
        return try request.fetchAll(db)
    }

    /// How many attachments of each kind match the other filters, for the filter chips.
    public static func counts(_ db: Database, accountId: String?) throws -> [AttachmentKind: Int] {
        let rows = try Row.fetchAll(db, sql: """
            SELECT kind, COUNT(*) AS count FROM attachment
            WHERE (? IS NULL OR accountId = ?) GROUP BY kind
            """, arguments: [accountId, accountId])
        var result: [AttachmentKind: Int] = [:]
        for row in rows {
            if let kind = AttachmentKind(rawValue: row["kind"]) { result[kind] = row["count"] }
        }
        return result
    }
}
