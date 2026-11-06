import Foundation

public enum FolderRole: String, Codable, Sendable, CaseIterable {
    case inbox, sent, drafts, trash, junk, archive, all, flagged, important
}

public struct IMAPFolder: Sendable, Hashable {
    /// Server name, still in modified UTF-7; used in commands.
    public var path: String
    public var delimiter: String?
    public var attributes: [String]

    public var displayName: String {
        let decoded = ModifiedUTF7.decode(path)
        return path.uppercased() == "INBOX" ? "Inbox" : decoded
    }

    public var isSelectable: Bool {
        !attributes.contains { ["\\noselect", "\\nonexistent"].contains($0.lowercased()) }
    }

    public var specialUse: FolderRole? {
        let lowered = Set(attributes.map { $0.lowercased() })
        if path.uppercased() == "INBOX" { return .inbox }
        if lowered.contains("\\sent") { return .sent }
        if lowered.contains("\\drafts") { return .drafts }
        if lowered.contains("\\trash") { return .trash }
        if lowered.contains("\\junk") { return .junk }
        if lowered.contains("\\archive") { return .archive }
        if lowered.contains("\\all") { return .all }
        if lowered.contains("\\flagged") { return .flagged }
        if lowered.contains("\\important") { return .important }
        return nil
    }

    /// Role guessed from common folder names on servers without SPECIAL-USE.
    public var guessedRole: FolderRole? {
        if let specialUse { return specialUse }
        let leaf = displayName.split(separator: Character(delimiter ?? "/")).last.map(String.init)?.lowercased() ?? ""
        switch leaf {
        case "sent", "sent messages", "sent items", "sent mail": return .sent
        case "drafts", "draft": return .drafts
        case "trash", "deleted messages", "deleted items", "bin": return .trash
        case "junk", "spam", "junk e-mail", "bulk mail": return .junk
        case "archive", "archives": return .archive
        default: return nil
        }
    }
}

public struct SelectResult: Sendable {
    public var exists: UInt32 = 0
    public var uidValidity: UInt32 = 0
    public var uidNext: UInt32 = 0
    public var highestModSeq: UInt64?
}

public struct FetchedMessage: Sendable {
    public var uid: UInt32
    public var flags: [String] = []
    public var internalDate: Date?
    public var size: Int = 0
    public var header: Data?
    public var body: Data?
    public var gmailMessageID: UInt64?
    public var gmailThreadID: UInt64?
    public var gmailLabels: [String]?
    public var modSeq: UInt64?

    init?(attributes: [String: IMAPValue]) {
        guard let uid = attributes["UID"]?.number else { return nil }
        self.uid = UInt32(truncatingIfNeeded: uid)
        flags = attributes["FLAGS"]?.list?.compactMap(\.text) ?? []
        internalDate = attributes["INTERNALDATE"]?.text.flatMap(MailDate.parseInternal)
        size = attributes["RFC822.SIZE"]?.number.map { Int($0) } ?? 0
        gmailMessageID = attributes["X-GM-MSGID"]?.number
        gmailThreadID = attributes["X-GM-THRID"]?.number
        gmailLabels = attributes["X-GM-LABELS"]?.list?.compactMap { value in
            value.text.map { $0.hasPrefix("\\") ? $0 : ModifiedUTF7.decode($0) }
        }
        modSeq = attributes["MODSEQ"]?.list?.first?.number
        for (key, value) in attributes where key.hasPrefix("BODY[") {
            if key.hasPrefix("BODY[HEADER") {
                header = value.data
            } else if key.hasPrefix("BODY[]") {
                body = value.data
            }
        }
    }

    public var isSeen: Bool { flags.contains { $0.caseInsensitiveCompare("\\Seen") == .orderedSame } }
    public var isFlagged: Bool { flags.contains { $0.caseInsensitiveCompare("\\Flagged") == .orderedSame } }
    public var isAnswered: Bool { flags.contains { $0.caseInsensitiveCompare("\\Answered") == .orderedSame } }
    public var isDraft: Bool { flags.contains { $0.caseInsensitiveCompare("\\Draft") == .orderedSame } }
}

public enum CommandPart: Sendable {
    case text(String)
    case literal(Data)

    /// A string argument: quoted when possible, otherwise sent as a literal.
    public static func string(_ value: String) -> CommandPart {
        let needsLiteral = value.unicodeScalars.contains { !$0.isASCII || $0 == "\r" || $0 == "\n" }
        if needsLiteral { return .literal(Data(value.utf8)) }
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return .text("\"\(escaped)\"")
    }
}

/// One IMAP connection. Commands run one at a time; callers that need several commands
/// in a row (SELECT then FETCH) should go through `IMAPSession`.
public actor IMAPClient {
    public let endpoint: ServerEndpoint
    private let username: String
    private let credential: Credential

    private var connection: NetworkConnection?
    private var buffer: [UInt8] = []
    private var readIndex = 0
    private var tagCounter = 0
    private var idleTag: String?
    private var idleDoneSent = false
    private var timedOut = false

    public private(set) var capabilities: Set<String> = []
    public private(set) var selectedPath: String?

    public init(endpoint: ServerEndpoint, username: String, credential: Credential) {
        self.endpoint = endpoint
        self.username = username
        self.credential = credential
    }

    public var isConnected: Bool { connection != nil }
    public var supportsCondstore: Bool { capabilities.contains("CONDSTORE") }
    public var supportsMove: Bool { capabilities.contains("MOVE") }
    public var supportsIdle: Bool { capabilities.contains("IDLE") }
    public var isGmail: Bool { capabilities.contains("X-GM-EXT-1") }

    public func connect() async throws {
        guard endpoint.security == .tls else {
            throw PoscarError.connection("IMAP needs a TLS port (usually 993); STARTTLS is not supported")
        }
        let connection = NetworkConnection(host: endpoint.host, port: endpoint.port, useTLS: true)
        try await connection.open()
        self.connection = connection
        buffer = []
        readIndex = 0
        selectedPath = nil

        do {
            let greeting = try await withTimeout(30) { try await self.readResponse() }
            if case .untagged(.status(.bye, _, let text)) = greeting {
                throw PoscarError.connection(text)
            }
            try await refreshCapabilities()
            do {
                switch credential {
                case .password(let password):
                    try await execute([.text("LOGIN "), .string(username), .text(" "), .string(password)])
                case .oauthAccessToken(let token):
                    try await authenticateXOAuth2(token: token)
                }
            } catch PoscarError.command(let message) {
                throw PoscarError.authentication(message)
            }
            try await refreshCapabilities()
        } catch {
            disconnect()
            throw error
        }
    }

    /// SASL XOAUTH2. On failure the server sends a continuation with error details, which must be
    /// answered with an empty line before it sends the final NO.
    private func authenticateXOAuth2(token: String) async throws {
        guard let connection else { throw PoscarError.connection("Not connected") }
        tagCounter += 1
        let tag = "P\(tagCounter)"
        let payload = Data("user=\(username)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
        try await connection.send(Data("\(tag) AUTHENTICATE XOAUTH2 \(payload)\r\n".utf8))
        try await withTimeout(30) {
            while true {
                switch try await self.readResponse() {
                case .continuation:
                    try await connection.send(Data("\r\n".utf8))
                case .tagged(let responseTag, let status, _, let text) where responseTag == tag:
                    guard status == .ok else { throw PoscarError.command(text.isEmpty ? "Google sign-in was rejected" : text) }
                    return
                default:
                    continue
                }
            }
        }
    }

    public func disconnect() {
        connection?.close()
        connection = nil
        selectedPath = nil
        idleTag = nil
    }

    public func logout() async {
        _ = try? await execute([.text("LOGOUT")], timeout: 5)
        disconnect()
    }

    public func refreshCapabilities() async throws {
        let responses = try await execute([.text("CAPABILITY")])
        for case .capability(let list) in responses {
            capabilities = Set(list)
        }
    }

    public func list() async throws -> [IMAPFolder] {
        let responses = try await execute([.text("LIST \"\" \"*\"")])
        return responses.compactMap { response in
            guard case .list(let attributes, let delimiter, let name) = response else { return nil }
            return IMAPFolder(path: name, delimiter: delimiter, attributes: attributes)
        }
    }

    public func select(_ path: String) async throws -> SelectResult {
        var parts: [CommandPart] = [.text("SELECT "), .string(path)]
        if supportsCondstore { parts.append(.text(" (CONDSTORE)")) }
        let responses = try await execute(parts)
        selectedPath = path

        var result = SelectResult()
        for response in responses {
            switch response {
            case .exists(let count):
                result.exists = count
            case .status(.ok, let code?, _):
                let value = code.arguments.first?.number
                switch code.name {
                case "UIDVALIDITY": result.uidValidity = UInt32(truncatingIfNeeded: value ?? 0)
                case "UIDNEXT": result.uidNext = UInt32(truncatingIfNeeded: value ?? 0)
                case "HIGHESTMODSEQ": result.highestModSeq = value
                default: break
                }
            default:
                break
            }
        }
        return result
    }

    public func create(_ path: String) async throws {
        try await execute([.text("CREATE "), .string(path)])
    }

    public func uidFetch(_ set: String, items: String, changedSince: UInt64? = nil) async throws -> [FetchedMessage] {
        var command = "UID FETCH \(set) (\(items))"
        if let changedSince { command += " (CHANGEDSINCE \(changedSince))" }
        let responses = try await execute([.text(command)], timeout: 300)
        return responses.compactMap { response in
            guard case .fetch(_, let attributes) = response else { return nil }
            return FetchedMessage(attributes: attributes)
        }
    }

    public func uidSearch(_ criteria: [CommandPart]) async throws -> [UInt32] {
        let responses = try await execute([.text("UID SEARCH ")] + criteria, timeout: 180)
        return responses.flatMap { response -> [UInt32] in
            guard case .search(let uids) = response else { return [] }
            return uids
        }
    }

    public func uidStore(_ set: String, _ operation: [CommandPart]) async throws {
        try await execute([.text("UID STORE \(set) ")] + operation)
    }

    public func uidMove(_ set: String, to destination: String) async throws {
        if supportsMove {
            try await execute([.text("UID MOVE \(set) "), .string(destination)])
        } else {
            try await execute([.text("UID COPY \(set) "), .string(destination)])
            try await uidExpunge(set)
        }
    }

    /// Marks messages deleted and expunges them.
    public func uidExpunge(_ set: String) async throws {
        try await uidStore(set, [.text("+FLAGS.SILENT (\\Deleted)")])
        if capabilities.contains("UIDPLUS") {
            try await execute([.text("UID EXPUNGE \(set)")])
        } else {
            try await execute([.text("EXPUNGE")])
        }
    }

    public func append(_ path: String, flags: [String], message: Data) async throws {
        let flagList = flags.joined(separator: " ")
        try await execute([.text("APPEND "), .string(path), .text(" (\(flagList)) "), .literal(message)], timeout: 300)
    }

    /// Waits for changes in the selected mailbox. Returns true when the server reported new or removed messages.
    public func idle(maxDuration: TimeInterval) async throws -> Bool {
        guard let connection else { throw PoscarError.connection("Not connected") }
        tagCounter += 1
        let tag = "P\(tagCounter)"
        idleTag = tag
        idleDoneSent = false
        defer { idleTag = nil }

        try await connection.send(Data("\(tag) IDLE\r\n".utf8))
        let timer = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(maxDuration * 1_000_000_000))
            await self?.endIdle()
        }
        defer { timer.cancel() }

        var changed = false
        while true {
            let response = try await readResponse()
            switch response {
            case .continuation:
                continue
            case .untagged(.exists), .untagged(.expunge), .untagged(.fetch):
                changed = true
                await endIdle()
            case .untagged(.status(.bye, _, let text)):
                disconnect()
                throw PoscarError.connection(text)
            case .tagged(let responseTag, let status, _, let text) where responseTag == tag:
                guard status == .ok else { throw PoscarError.command(text) }
                return changed
            default:
                continue
            }
        }
    }

    public func endIdle() async {
        guard idleTag != nil, !idleDoneSent, let connection else { return }
        idleDoneSent = true
        try? await connection.send(Data("DONE\r\n".utf8))
    }

    // MARK: - Command execution

    @discardableResult
    func execute(_ parts: [CommandPart], timeout: TimeInterval = 90) async throws -> [UntaggedResponse] {
        guard let connection else { throw PoscarError.connection("Not connected to \(endpoint.host)") }
        tagCounter += 1
        let tag = "P\(tagCounter)"

        do {
            return try await withTimeout(timeout) {
                var pending = Data("\(tag) ".utf8)
                var untagged: [UntaggedResponse] = []
                for part in parts {
                    switch part {
                    case .text(let text):
                        pending.append(Data(text.utf8))
                    case .literal(let data):
                        pending.append(Data("{\(data.count)}\r\n".utf8))
                        try await connection.send(pending)
                        try await self.waitForContinuation(tag: tag, collecting: &untagged)
                        pending = data
                    }
                }
                pending.append(Data("\r\n".utf8))
                try await connection.send(pending)

                while true {
                    switch try await self.readResponse() {
                    case .untagged(let response):
                        untagged.append(response)
                    case .tagged(let responseTag, let status, _, let text) where responseTag == tag:
                        guard status == .ok else { throw PoscarError.command(text.isEmpty ? status.rawValue : text) }
                        return untagged
                    default:
                        continue
                    }
                }
            }
        } catch let error as PoscarError {
            if case .command = error { throw error }
            disconnect()
            throw error
        }
    }

    private func waitForContinuation(tag: String, collecting untagged: inout [UntaggedResponse]) async throws {
        while true {
            switch try await readResponse() {
            case .continuation:
                return
            case .untagged(let response):
                untagged.append(response)
            case .tagged(let responseTag, _, _, let text) where responseTag == tag:
                throw PoscarError.command(text)
            default:
                continue
            }
        }
    }

    /// Closes the connection when the operation takes too long, which unblocks any pending read.
    private func withTimeout<T>(_ seconds: TimeInterval, _ operation: () async throws -> T) async throws -> T {
        timedOut = false
        let watchdog = Task { [weak self] in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            await self?.expire()
        }
        defer { watchdog.cancel() }
        do {
            return try await operation()
        } catch {
            if timedOut { throw PoscarError.timeout("\(endpoint.host) did not respond in \(Int(seconds))s") }
            throw error
        }
    }

    private func expire() {
        timedOut = true
        disconnect()
    }

    // MARK: - Reading

    func readResponse() async throws -> IMAPResponse {
        try IMAPResponseParser.parse(try await readRawResponse())
    }

    /// Reads one logical response line, inlining any literals it announces.
    private func readRawResponse() async throws -> [UInt8] {
        var output: [UInt8] = []
        while true {
            let line = try await readLine()
            output += line
            guard let length = literalLength(atEndOf: line) else { return output }
            output += [13, 10]
            output += try await readBytes(length)
        }
    }

    private func literalLength(atEndOf line: [UInt8]) -> Int? {
        guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        let digits = line[(open + 1)..<(line.count - 1)].filter { $0 != UInt8(ascii: "+") }
        return Int(String(decoding: digits, as: UTF8.self))
    }

    private func readLine() async throws -> [UInt8] {
        var scanFrom = readIndex
        while true {
            if let newline = buffer[scanFrom...].firstIndex(of: 10) {
                var end = newline
                if end > readIndex, buffer[end - 1] == 13 { end -= 1 }
                let line = Array(buffer[readIndex..<end])
                readIndex = newline + 1
                compactBuffer()
                return line
            }
            scanFrom = buffer.count
            try await fillBuffer()
        }
    }

    private func readBytes(_ count: Int) async throws -> [UInt8] {
        while buffer.count - readIndex < count {
            try await fillBuffer()
        }
        let bytes = Array(buffer[readIndex..<readIndex + count])
        readIndex += count
        compactBuffer()
        return bytes
    }

    private func fillBuffer() async throws {
        guard let connection else { throw PoscarError.connection("Not connected to \(endpoint.host)") }
        let data = try await connection.receive()
        buffer.append(contentsOf: data)
    }

    private func compactBuffer() {
        if readIndex == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            readIndex = 0
        } else if readIndex > 1_000_000 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
    }
}

/// Serializes multi-command operations on one connection and reconnects when it drops.
public actor IMAPSession {
    private let makeClient: @Sendable () async throws -> IMAPClient
    private var client: IMAPClient?
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(makeClient: @escaping @Sendable () async throws -> IMAPClient) {
        self.makeClient = makeClient
    }

    public func run<T: Sendable>(_ operation: @Sendable (IMAPClient) async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        let client = try await connectedClient()
        return try await operation(client)
    }

    public func close() async {
        await client?.logout()
        client = nil
    }

    private func connectedClient() async throws -> IMAPClient {
        if let client, await client.isConnected { return client }
        let fresh = try await makeClient()
        client = fresh
        return fresh
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}

public enum UIDSet {
    /// Compresses UIDs into ranges: [1, 2, 3, 7] → "1:3,7".
    public static func string(_ uids: [UInt32]) -> String {
        let sorted = Array(Set(uids)).sorted()
        guard var start = sorted.first else { return "" }
        var parts: [String] = []
        var previous = start
        for uid in sorted.dropFirst() {
            if uid == previous + 1 {
                previous = uid
                continue
            }
            parts.append(start == previous ? "\(start)" : "\(start):\(previous)")
            start = uid
            previous = uid
        }
        parts.append(start == previous ? "\(start)" : "\(start):\(previous)")
        return parts.joined(separator: ",")
    }
}
