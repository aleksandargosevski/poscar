import Foundation
import GRDB

public enum RemoteOperation: Sendable, Hashable {
    case store(folder: String, uids: [UInt32], operation: String)
    case gmailLabels(folder: String, uids: [UInt32], add: Bool, labels: [String])
    case move(folder: String, uids: [UInt32], destination: String)
    case expunge(folder: String, uids: [UInt32])
    case createFolder(String)
}

/// Keeps one account's local cache in sync with its IMAP server and runs remote changes.
///
/// Two connections are used so that a long initial sync never blocks user actions,
/// plus a third one that waits in IDLE for new mail.
public actor AccountSync {
    public nonisolated let account: Account
    private let database: MailDatabase
    private let background: IMAPSession
    private let interactive: IMAPSession
    private let makeClient: @Sendable () async throws -> IMAPClient

    private var idleTask: Task<Void, Never>?
    private var idleClient: IMAPClient?
    private var isSyncing = false
    private var syncRequested = false
    private var backfillQueues: [String: [UInt32]] = [:]
    private var failedBodies: Set<Int64> = []
    private var protectedRowIDs: Set<Int64> = []

    private var newMailHandler: (@Sendable ([MessageRecord]) -> Void)?
    private var statusHandler: (@Sendable (String?) -> Void)?
    private var errorHandler: (@Sendable (Error) -> Void)?

    static let bodyPrefetchDays: Double = 90
    static let bodyPrefetchMaxSize = 10_000_000
    static let backfillChunk = 300

    /// `credentials` is asked on every connect, so OAuth access tokens can be refreshed in between.
    public init(account: Account, credentials: @escaping CredentialProvider, database: MailDatabase) {
        self.account = account
        self.database = database
        let endpoint = account.imap
        let username = account.username
        let makeClient: @Sendable () async throws -> IMAPClient = {
            let client = IMAPClient(endpoint: endpoint, username: username, credential: try await credentials())
            try await client.connect()
            return client
        }
        self.makeClient = makeClient
        background = IMAPSession(makeClient: makeClient)
        interactive = IMAPSession(makeClient: makeClient)
    }

    public func setHandlers(
        newMail: @escaping @Sendable ([MessageRecord]) -> Void,
        status: @escaping @Sendable (String?) -> Void,
        error: @escaping @Sendable (Error) -> Void
    ) {
        newMailHandler = newMail
        statusHandler = status
        errorHandler = error
    }

    /// Rows with pending local changes; sync must not overwrite them until they are committed.
    public func setProtectedRows(_ ids: Set<Int64>) {
        protectedRowIDs = ids
    }

    public func start() {
        guard idleTask == nil else { return }
        idleTask = Task { [weak self] in await self?.idleLoop() }
        Task { await sync() }
    }

    public func stop() async {
        idleTask?.cancel()
        idleTask = nil
        await idleClient?.disconnect()
        idleClient = nil
        await background.close()
        await interactive.close()
    }

    /// Verifies credentials by logging in once.
    public static func verify(account: Account, credential: Credential) async throws {
        let client = IMAPClient(endpoint: account.imap, username: account.username, credential: credential)
        try await client.connect()
        await client.logout()
    }

    // MARK: - Sync

    public func sync() async {
        guard !isSyncing else {
            syncRequested = true
            return
        }
        isSyncing = true
        defer {
            isSyncing = false
            statusHandler?(nil)
        }

        repeat {
            syncRequested = false
            do {
                let synced = prioritized(try await refreshFolders().filter(\.synced))
                for folder in synced {
                    try await syncFolder(folder.path)
                }
                try await prefetchBodies(limit: 100)
                for folder in synced {
                    try await backfill(folder.path, keepingCurrent: synced)
                }
                try await prefetchBodies(limit: nil)
            } catch {
                errorHandler?(error)
            }
        } while syncRequested
    }

    private func prioritized(_ folders: [FolderRecord]) -> [FolderRecord] {
        let order: [FolderRole?] = [.inbox, .all, .sent, .drafts, .archive]
        return folders.sorted { lhs, rhs in
            let left = order.firstIndex(of: lhs.role) ?? order.count
            let right = order.firstIndex(of: rhs.role) ?? order.count
            return left < right
        }
    }

    private func refreshFolders() async throws -> [FolderRecord] {
        let listed = try await background.run { try await $0.list() }
        let accountId = account.id
        let isGmail = account.isGmail

        return try await database.writer.write { db in
            let existing = try MailQueries.folders(db, accountId: accountId)
            let existingByPath = Dictionary(existing.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
            var assignedRoles = Set<FolderRole>()
            var result: [FolderRecord] = []

            for folder in listed where folder.isSelectable {
                var role = isGmail ? folder.specialUse : folder.guessedRole
                if let candidate = role {
                    if assignedRoles.contains(candidate) { role = nil } else { assignedRoles.insert(candidate) }
                }
                let synced = isGmail ? [.all, .trash, .junk].contains(role) : true
                var record = existingByPath[folder.path] ?? FolderRecord(accountId: accountId, folder: folder, role: role, synced: synced)
                record.role = role
                record.synced = synced
                record.name = folder.displayName
                record.delimiter = folder.delimiter
                try record.save(db)
                result.append(record)
            }

            let listedPaths = Set(result.map(\.path))
            for stale in existing where !listedPaths.contains(stale.path) {
                try db.execute(sql: "DELETE FROM message WHERE accountId = ? AND folder = ?", arguments: [accountId, stale.path])
                try stale.delete(db)
            }
            return result
        }
    }

    private func folderState(_ path: String) async throws -> FolderRecord? {
        let accountId = account.id
        return try await database.writer.read { db in
            try FolderRecord.fetchOne(db, key: ["accountId": accountId, "path": path])
        }
    }

    private struct FolderChanges: Sendable {
        var state: FolderRecord
        var newRecords: [MessageRecord] = []
        var flagUpdates: [MessageRecord] = []
        var serverUIDs: Set<UInt32>?
        var resetFolder = false
    }

    private func syncFolder(_ path: String) async throws {
        guard let initialState = try await folderState(path) else { return }
        let isGmail = account.isGmail
        let accountId = account.id
        let database = database

        let changes = try await background.run { client -> FolderChanges in
            var changes = FolderChanges(state: initialState)
            let info = try await client.select(path)

            if changes.state.uidValidity != Int64(info.uidValidity) {
                var top = Int64(info.uidNext) - 1
                if info.uidNext == 0 {
                    top = Int64(try await client.uidSearch([.text("ALL")]).max() ?? 0)
                }
                changes.resetFolder = true
                changes.state.uidValidity = Int64(info.uidValidity)
                changes.state.maxUid = max(top, 0)
                changes.state.backfillCursor = changes.state.maxUid + 1
                changes.state.backfillDone = changes.state.maxUid == 0
                changes.state.highestModSeq = Int64(info.highestModSeq ?? 0)
                return changes
            }

            var state = changes.state
            if info.uidNext == 0 || Int64(info.uidNext) - 1 > state.maxUid {
                let fetched = try await client.uidFetch("\(state.maxUid + 1):*", items: MessageFactory.headerFetchItems(gmail: isGmail))
                let fresh = fetched.filter { Int64($0.uid) > state.maxUid }
                changes.newRecords = fresh.map { MessageFactory.record(from: $0, accountId: accountId, folder: path, gmail: isGmail) }
                state.maxUid = max(state.maxUid, Int64(fresh.map(\.uid).max() ?? 0))
            }

            let lowest = max(state.backfillCursor, 1)
            if lowest <= state.maxUid {
                let items = MessageFactory.flagFetchItems(gmail: isGmail)
                if let modSeq = info.highestModSeq, state.highestModSeq > 0, await client.supportsCondstore {
                    if modSeq != UInt64(state.highestModSeq) {
                        changes.flagUpdates = try await client.uidFetch(
                            "\(lowest):\(state.maxUid)", items: items, changedSince: UInt64(state.highestModSeq)
                        ).map { Self.flagUpdate($0, accountId: accountId, folder: path) }
                    }
                } else {
                    changes.flagUpdates = try await client.uidFetch("\(lowest):\(state.maxUid)", items: items)
                        .map { Self.flagUpdate($0, accountId: accountId, folder: path) }
                }
            }
            state.highestModSeq = Int64(info.highestModSeq ?? 0)

            if state.backfillDone {
                let localCount = try await database.writer.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE accountId = ? AND folder = ?", arguments: [accountId, path]) ?? 0
                }
                if localCount + changes.newRecords.count != Int(info.exists) {
                    changes.serverUIDs = Set(try await client.uidSearch([.text("ALL")]))
                }
            }
            changes.state = state
            return changes
        }

        let protected = protectedRowIDs
        let account = account
        let newMessages = try await database.writer.write { db -> [MessageRecord] in
            if changes.resetFolder {
                try db.execute(sql: "DELETE FROM message WHERE accountId = ? AND folder = ?", arguments: [accountId, path])
            }
            var added: [MessageRecord] = []
            for record in changes.newRecords {
                if let saved = try Self.insert(record, db: db, account: account) { added.append(saved) }
            }
            for update in changes.flagUpdates {
                try Self.applyFlags(update, db: db, protected: protected)
            }
            if let serverUIDs = changes.serverUIDs {
                let local = try Int64.fetchAll(db, sql: "SELECT uid FROM message WHERE accountId = ? AND folder = ?", arguments: [accountId, path])
                let gone = local.filter { !serverUIDs.contains(UInt32(truncatingIfNeeded: $0)) }
                for chunk in gone.chunked(500) {
                    try db.execute(literal: "DELETE FROM message WHERE accountId = \(accountId) AND folder = \(path) AND uid IN \(chunk)")
                }
            }
            try changes.state.save(db)
            return added
        }

        let inboxMessages = newMessages.filter { message in
            guard !message.seen else { return false }
            return isGmail ? message.hasLabel("\\Inbox") : changes.state.role == .inbox
        }
        if !inboxMessages.isEmpty { newMailHandler?(inboxMessages) }
    }

    /// Downloads headers of older messages, newest first, a chunk at a time.
    /// New mail reported meanwhile is fetched between chunks, so a long first sync never hides it.
    private func backfill(_ path: String, keepingCurrent folders: [FolderRecord]) async throws {
        while let state = try await folderState(path), !state.backfillDone {
            if syncRequested {
                syncRequested = false
                for folder in folders { try await syncFolder(folder.path) }
            }
            let accountId = account.id
            let isGmail = account.isGmail
            let queued = backfillQueues[path]

            let (records, remaining) = try await background.run { client -> ([MessageRecord], [UInt32]) in
                if await client.selectedPath != path { _ = try await client.select(path) }
                var queue = queued ?? []
                if queued == nil, state.backfillCursor > 1 {
                    queue = try await client.uidSearch([.text("UID 1:\(state.backfillCursor - 1)")])
                        .filter { Int64($0) < state.backfillCursor }
                        .sorted()
                }
                let chunk = Array(queue.suffix(Self.backfillChunk))
                queue.removeLast(chunk.count)
                guard !chunk.isEmpty else { return ([], []) }
                let fetched = try await client.uidFetch(UIDSet.string(chunk), items: MessageFactory.headerFetchItems(gmail: isGmail))
                return (fetched.map { MessageFactory.record(from: $0, accountId: accountId, folder: path, gmail: isGmail) }, queue)
            }

            backfillQueues[path] = remaining
            let account = account
            let total = try await database.writer.write { db -> Int in
                var updated = state
                for record in records { _ = try Self.insert(record, db: db, account: account) }
                if remaining.isEmpty {
                    updated.backfillDone = true
                    updated.backfillCursor = 0
                } else {
                    updated.backfillCursor = Int64(remaining.last.map { $0 + 1 } ?? 0)
                }
                try updated.save(db)
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE accountId = ? AND folder = ?", arguments: [accountId, path]) ?? 0
            }
            if remaining.isEmpty {
                backfillQueues[path] = nil
            } else {
                statusHandler?("\(account.name): \(total.formatted()) downloaded, \(remaining.count.formatted()) to go")
            }
        }
    }

    private func prefetchBodies(limit: Int?) async throws {
        let accountId = account.id
        let cutoff = Date().addingTimeInterval(-Self.bodyPrefetchDays * 86_400)
        var downloaded = 0
        while limit.map({ downloaded < $0 }) ?? true {
            let failed = failedBodies
            let candidates = try await database.writer.read { db in
                try MessageRecord.fetchAll(db, sql: """
                    SELECT message.* FROM message JOIN folder ON folder.accountId = message.accountId AND folder.path = message.folder
                    WHERE message.accountId = ? AND message.hasBody = 0 AND message.date > ? AND message.size < ?
                          AND folder.synced = 1 AND message.hidden = 0
                    ORDER BY message.date DESC LIMIT 60
                    """, arguments: [accountId, cutoff, Self.bodyPrefetchMaxSize])
            }
            .filter { !failed.contains($0.id ?? 0) }
            guard !candidates.isEmpty else { return }
            downloaded += candidates.count

            for (folder, messages) in Dictionary(grouping: candidates, by: \.folder) {
                for batch in messages.chunked(15) {
                    try await downloadBodies(batch, folder: folder, session: background)
                }
            }
        }
    }

    private func downloadBodies(_ messages: [MessageRecord], folder: String, session: IMAPSession) async throws {
        let uids = messages.map { UInt32(truncatingIfNeeded: $0.uid) }
        let fetched = try await session.run { client -> [FetchedMessage] in
            if await client.selectedPath != folder { _ = try await client.select(folder) }
            return try await client.uidFetch(UIDSet.string(uids), items: "UID BODY.PEEK[]")
        }
        let byUID = Dictionary(fetched.compactMap { item in item.body.map { (Int64(item.uid), $0) } }, uniquingKeysWith: { first, _ in first })

        var parsed: [StoredBody] = []
        for message in messages {
            guard let id = message.id else { continue }
            if let raw = byUID[message.uid] {
                parsed.append(StoredBody(message: message, rowId: id, raw: raw))
            } else {
                failedBodies.insert(id)
            }
        }
        guard !parsed.isEmpty else { return }
        // One transaction per batch, so the UI re-queries once instead of once per message.
        let bodies = parsed
        try await database.writer.write { db in
            for body in bodies {
                try db.execute(sql: "INSERT OR REPLACE INTO body (messageRowId, raw) VALUES (?, ?)", arguments: [body.rowId, body.raw])
                try db.execute(
                    sql: "UPDATE message SET hasBody = 1, snippet = ?, hasAttachments = ? WHERE id = ?",
                    arguments: [body.snippet, body.hasAttachments, body.rowId]
                )
                try db.execute(sql: "UPDATE message_fts SET body = ? WHERE rowid = ?", arguments: [body.searchText, body.rowId])
                try AttachmentIndex.replace(body.attachments, messageRowId: body.rowId, in: db)
                try db.execute(sql: "UPDATE message SET attachmentsIndexed = 1 WHERE id = ?", arguments: [body.rowId])
            }
        }
    }

    private struct StoredBody: Sendable {
        let rowId: Int64
        let raw: Data
        let snippet: String
        let searchText: String
        let hasAttachments: Bool
        let attachments: [AttachmentRecord]

        init(message: MessageRecord, rowId: Int64, raw: Data) {
            let parsed = MIMEParser.parse(raw)
            self.rowId = rowId
            self.raw = raw
            snippet = parsed.snippet
            searchText = String(parsed.plainText.prefix(20_000))
            hasAttachments = !parsed.visibleAttachments.isEmpty
            attachments = AttachmentIndex.records(for: message, parsed: parsed)
        }
    }

    // MARK: - On demand

    /// Returns the raw message, downloading it first when it is not cached.
    public func body(for message: MessageRecord) async throws -> Data {
        guard let id = message.id else { throw PoscarError.invalidInput("Message is not saved") }
        if let cached = try await database.writer.read({ db in try MailQueries.body(db, messageRowId: id) }) {
            return cached
        }
        try await downloadBodies([message], folder: message.folder, session: interactive)
        guard let raw = try await database.writer.read({ db in try MailQueries.body(db, messageRowId: id) }) else {
            throw PoscarError.command("The message is no longer on the server")
        }
        return raw
    }

    public func perform(_ operations: [RemoteOperation]) async throws {
        guard !operations.isEmpty else { return }
        try await interactive.run { client in
            for operation in operations {
                switch operation {
                case .createFolder(let path):
                    do { try await client.create(path) } catch PoscarError.command {}
                case .store(let folder, let uids, let flagOperation):
                    try await Self.select(folder, client)
                    try await client.uidStore(UIDSet.string(uids), [.text(flagOperation)])
                case .gmailLabels(let folder, let uids, let add, let labels):
                    try await Self.select(folder, client)
                    var parts: [CommandPart] = [.text(add ? "+X-GM-LABELS.SILENT (" : "-X-GM-LABELS.SILENT (")]
                    for (index, label) in labels.enumerated() {
                        if index > 0 { parts.append(.text(" ")) }
                        parts.append(.string(label.hasPrefix("\\") ? label : ModifiedUTF7.encode(label)))
                    }
                    parts.append(.text(")"))
                    try await client.uidStore(UIDSet.string(uids), parts)
                case .move(let folder, let uids, let destination):
                    try await Self.select(folder, client)
                    try await client.uidMove(UIDSet.string(uids), to: destination)
                case .expunge(let folder, let uids):
                    try await Self.select(folder, client)
                    try await client.uidExpunge(UIDSet.string(uids))
                }
            }
        }
        Task { await sync() }
    }

    public func append(_ raw: Data, to folder: String, flags: [String]) async throws {
        try await interactive.run { client in
            try await client.append(folder, flags: flags, message: raw)
        }
    }

    /// Server-side search (Gmail search syntax on Gmail). Missing headers are downloaded on the way.
    public func search(_ query: String) async throws -> [Int64] {
        let accountId = account.id
        let isGmail = account.isGmail
        let folders = try await database.writer.read { db in try MailQueries.folders(db, accountId: accountId) }
        let searchFolders = isGmail
            ? folders.filter { $0.role == .all }
            : folders.filter { $0.synced && $0.role != .trash && $0.role != .junk }
        let criteria: [CommandPart]
        if isGmail {
            let isASCII = query.unicodeScalars.allSatisfy(\.isASCII)
            criteria = (isASCII ? [] : [.text("CHARSET UTF-8 ")]) + [.text("X-GM-RAW "), .string(query)]
        } else {
            criteria = SearchQuery(query).imapCriteria
        }

        var ids: [Int64] = []
        for folder in searchFolders {
            let path = folder.path
            let uids = try await interactive.run { client in
                try await Self.select(path, client)
                return try await client.uidSearch(criteria)
            }
            let recent = Array(uids.sorted().suffix(300))
            let recentUIDs = recent.map(Int64.init)
            let known: [(id: Int64, uid: Int64)] = try await database.writer.read { db in
                let request = SQLRequest<Row>(literal: "SELECT id, uid FROM message WHERE accountId = \(accountId) AND folder = \(path) AND uid IN \(recentUIDs)")
                return try request.fetchAll(db).map { (id: $0["id"], uid: $0["uid"]) }
            }
            let knownUIDs = Set(known.map(\.uid))
            ids += known.map(\.id)

            let missing = recent.filter { !knownUIDs.contains(Int64($0)) }
            if !missing.isEmpty {
                let fetched = try await interactive.run { client in
                    try await Self.select(path, client)
                    return try await client.uidFetch(UIDSet.string(missing), items: MessageFactory.headerFetchItems(gmail: isGmail))
                }
                let account = account
                ids += try await database.writer.write { db in
                    try fetched.compactMap { item in
                        let record = MessageFactory.record(from: item, accountId: accountId, folder: path, gmail: isGmail)
                        return try Self.insert(record, db: db, account: account)?.id
                    }
                }
            }
        }
        return ids
    }

    private static func select(_ path: String, _ client: IMAPClient) async throws {
        if await client.selectedPath != path { _ = try await client.select(path) }
    }

    // MARK: - IDLE

    private func idleLoop() async {
        var backoff: UInt64 = 10
        while !Task.isCancelled {
            do {
                let client = try await makeClient()
                idleClient = client
                guard await client.supportsIdle else {
                    await client.logout()
                    try await Task.sleep(nanoseconds: 120 * 1_000_000_000)
                    Task { await sync() }
                    continue
                }
                _ = try await client.select("INBOX")
                backoff = 10
                while !Task.isCancelled {
                    if try await client.idle(maxDuration: 24 * 60) {
                        Task { await sync() }
                    }
                }
            } catch {
                if Task.isCancelled { break }
                try? await Task.sleep(nanoseconds: backoff * 1_000_000_000)
                backoff = min(backoff * 2, 300)
            }
        }
    }

    // MARK: - Database helpers

    /// Marker record used to carry a flag update through the same list as inserts.
    private static func flagUpdate(_ fetched: FetchedMessage, accountId: String, folder: String) -> MessageRecord {
        var record = MessageFactory.record(from: fetched, accountId: accountId, folder: folder, gmail: fetched.gmailLabels != nil)
        record.threadKey = ""
        record.labels = fetched.gmailLabels.map(LabelSet.encode) ?? "\u{0}"
        return record
    }

    private static func applyFlags(_ record: MessageRecord, db: Database, protected: Set<Int64>) throws {
        let keepLabels = record.labels == "\u{0}"
        try db.execute(sql: """
            UPDATE message SET seen = ?, flagged = ?, answered = ?, draft = ?, labels = CASE WHEN ? THEN labels ELSE ? END
            WHERE accountId = ? AND folder = ? AND uid = ? AND hidden = 0
            """ + (protected.isEmpty ? "" : " AND id NOT IN (\(protected.map(String.init).joined(separator: ",")))"),
            arguments: [record.seen, record.flagged, record.answered, record.draft, keepLabels, record.labels,
                        record.accountId, record.folder, record.uid])
    }

    private static func insert(_ record: MessageRecord, db: Database, account: Account) throws -> MessageRecord? {
        var saved = record
        try saved.insert(db, onConflict: .ignore)
        guard db.changesCount > 0, let id = saved.id else { return nil }

        let participants = [record.fromName, record.fromEmail, record.toAddresses, record.ccAddresses].joined(separator: " ")
        try db.execute(
            sql: "INSERT INTO message_fts (rowid, subject, participants, body) VALUES (?, ?, ?, '')",
            arguments: [id, record.subject, participants]
        )
        if record.fromEmail.caseInsensitiveCompare(account.email) == .orderedSame {
            try MailQueries.recordContacts(db, record.to + record.cc, weight: 3, date: record.date)
        } else {
            try MailQueries.recordContacts(db, [record.from], weight: 1, date: record.date)
        }
        return saved
    }
}

extension Array {
    func chunked(_ size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
