import Foundation
import GRDB

public struct MessageRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "message"

    public var id: Int64?
    public var accountId: String
    public var folder: String
    public var uid: Int64
    public var gmailMessageId: Int64?
    public var threadKey: String
    public var messageId: String?
    public var inReplyTo: String?
    public var references: String
    public var subject: String
    public var fromName: String
    public var fromEmail: String
    public var toAddresses: String
    public var ccAddresses: String
    public var replyTo: String
    public var date: Date
    public var size: Int
    public var seen: Bool
    public var flagged: Bool
    public var answered: Bool
    public var draft: Bool
    /// Gmail labels wrapped in \u{1F} separators so SQL can match whole labels with instr().
    public var labels: String
    public var hasAttachments: Bool
    public var snippet: String
    public var hasBody: Bool
    public var hidden: Bool

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public var from: EmailAddress { EmailAddress(name: fromName, email: fromEmail) }
    public var to: [EmailAddress] { AddressParser.parse(toAddresses) }
    public var cc: [EmailAddress] { AddressParser.parse(ccAddresses) }
    public var referenceIDs: [String] { references.split(separator: " ").map(String.init) }

    public var labelList: [String] {
        labels.split(separator: LabelSet.separator).map(String.init)
    }

    public func hasLabel(_ label: String) -> Bool {
        labels.contains(LabelSet.token(label))
    }
}

public enum LabelSet {
    public static let separator: Character = "\u{1F}"

    public static func token(_ label: String) -> String {
        "\(separator)\(label)\(separator)"
    }

    public static func encode(_ labels: [String]) -> String {
        guard !labels.isEmpty else { return "" }
        return String(separator) + labels.joined(separator: String(separator)) + String(separator)
    }
}

public struct FolderRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "folder"

    public var accountId: String
    public var path: String
    public var name: String
    public var delimiter: String?
    public var role: FolderRole?
    public var synced: Bool
    public var uidValidity: Int64
    public var maxUid: Int64
    public var backfillCursor: Int64
    public var backfillDone: Bool
    public var highestModSeq: Int64

    public init(accountId: String, folder: IMAPFolder, role: FolderRole?, synced: Bool) {
        self.accountId = accountId
        path = folder.path
        name = folder.displayName
        delimiter = folder.delimiter
        self.role = role
        self.synced = synced
        uidValidity = 0
        maxUid = 0
        backfillCursor = 0
        backfillDone = false
        highestModSeq = 0
    }
}

public struct OutboxRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable, Sendable {
    public static let databaseTableName = "outbox"

    public var id: Int64?
    public var accountId: String
    public var sendAt: Date
    public var message: Data
    public var raw: Data
    public var messageId: String
    public var replyToMessageRowId: Int64?
    public var lastError: String?

    public init(
        id: Int64? = nil, accountId: String, sendAt: Date, message: Data, raw: Data,
        messageId: String, replyToMessageRowId: Int64?, lastError: String? = nil
    ) {
        self.id = id
        self.accountId = accountId
        self.sendAt = sendAt
        self.message = message
        self.raw = raw
        self.messageId = messageId
        self.replyToMessageRowId = replyToMessageRowId
        self.lastError = lastError
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    public func decodedMessage() throws -> OutgoingMessage {
        try JSONDecoder().decode(OutgoingMessage.self, from: message)
    }
}

public struct ContactRecord: Codable, FetchableRecord, PersistableRecord, Hashable, Sendable {
    public static let databaseTableName = "contact"

    public var email: String
    public var name: String
    public var score: Int
    public var lastSeen: Date

    public var address: EmailAddress { EmailAddress(name: name, email: email) }
}
