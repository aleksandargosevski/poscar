import Foundation

/// Minimal SMTP submission client. Uses Foundation streams because, unlike Network.framework,
/// they can upgrade an open connection to TLS, which STARTTLS (port 587) requires.
public struct SMTPClient: Sendable {
    public let endpoint: ServerEndpoint
    public let username: String
    public let credential: Credential

    public init(endpoint: ServerEndpoint, username: String, credential: Credential) {
        self.endpoint = endpoint
        self.username = username
        self.credential = credential
    }

    public func send(_ message: Data, from sender: String, to recipients: [String]) async throws {
        guard !recipients.isEmpty else { throw PoscarError.invalidInput("Add at least one recipient") }
        try await runBlocking { session in
            try session.authenticate()
            try session.command("MAIL FROM:<\(sender)>", expect: [250])
            for recipient in recipients {
                try session.command("RCPT TO:<\(recipient)>", expect: [250, 251])
            }
            try session.command("DATA", expect: [354])
            try session.writeData(message)
            try session.command(".", expect: [250])
            _ = try? session.command("QUIT", expect: [221])
        }
    }

    /// Connects and logs in without sending, to validate account settings.
    public func verify() async throws {
        try await runBlocking { session in
            try session.authenticate()
            _ = try? session.command("QUIT", expect: [221])
        }
    }

    private func runBlocking(_ work: @escaping @Sendable (SMTPSession) throws -> Void) async throws {
        let endpoint = endpoint
        let username = username
        let credential = credential
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Thread.detachNewThread {
                do {
                    let session = try SMTPSession(endpoint: endpoint, username: username, credential: credential)
                    defer { session.close() }
                    try work(session)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

final class SMTPSession: @unchecked Sendable {
    private let input: InputStream
    private let output: OutputStream
    private let endpoint: ServerEndpoint
    private let username: String
    private let credential: Credential
    private var pending = Data()
    private var extensions: [String] = []

    init(endpoint: ServerEndpoint, username: String, credential: Credential) throws {
        self.endpoint = endpoint
        self.username = username
        self.credential = credential

        var readStream: InputStream?
        var writeStream: OutputStream?
        Stream.getStreamsToHost(withName: endpoint.host, port: endpoint.port, inputStream: &readStream, outputStream: &writeStream)
        guard let readStream, let writeStream else {
            throw PoscarError.connection("Could not open a connection to \(endpoint.host)")
        }
        input = readStream
        output = writeStream

        if endpoint.security == .tls { enableTLS() }
        input.open()
        output.open()
        try waitUntilOpen()
    }

    func close() {
        input.close()
        output.close()
    }

    func authenticate() throws {
        try expectReply([220])
        try hello()
        if endpoint.security == .startTLS {
            try command("STARTTLS", expect: [220])
            enableTLS()
            try hello()
        }

        let mechanisms = extensions.first { $0.uppercased().hasPrefix("AUTH") }?.uppercased() ?? "AUTH PLAIN LOGIN"
        let password: String
        switch credential {
        case .oauthAccessToken(let token):
            try authenticateXOAuth2(token: token)
            return
        case .password(let value):
            password = value
        }
        if mechanisms.contains("PLAIN") {
            let token = Data("\0\(username)\0\(password)".utf8).base64EncodedString()
            try authCommand("AUTH PLAIN \(token)", expect: [235])
        } else if mechanisms.contains("LOGIN") {
            try authCommand("AUTH LOGIN", expect: [334])
            try authCommand(Data(username.utf8).base64EncodedString(), expect: [334])
            try authCommand(Data(password.utf8).base64EncodedString(), expect: [235])
        } else {
            throw PoscarError.authentication("\(endpoint.host) offers no supported login method (\(mechanisms))")
        }
    }

    @discardableResult
    func command(_ line: String, expect codes: [Int]) throws -> String {
        try write(Data((line + "\r\n").utf8))
        return try expectReply(codes)
    }

    /// Writes the message body for DATA: CRLF line endings and leading dots doubled.
    func writeData(_ message: Data) throws {
        var text = String(decoding: message, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n")
        if text.hasPrefix(".") { text = "." + text }
        text = text.replacingOccurrences(of: "\r\n.", with: "\r\n..")
        if !text.hasSuffix("\r\n") { text += "\r\n" }
        try write(Data(text.utf8))
    }

    /// On failure Gmail answers 334 with error details; an empty line then yields the final 535.
    private func authenticateXOAuth2(token: String) throws {
        let payload = Data("user=\(username)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
        let reply = try command("AUTH XOAUTH2 \(payload)", expect: [235, 334])
        guard reply.isEmpty || !reply.hasPrefix("eyJ") else {
            _ = try? command("", expect: [535])
            let details = Data(base64Encoded: reply).flatMap { String(data: $0, encoding: .utf8) } ?? reply
            throw PoscarError.authentication("Google rejected the sign-in: \(details)")
        }
    }

    private func authCommand(_ line: String, expect codes: [Int]) throws {
        do {
            try command(line, expect: codes)
        } catch PoscarError.command(let message) {
            throw PoscarError.authentication(message)
        }
    }

    private func hello() throws {
        let reply = try command("EHLO poscar.local", expect: [250])
        extensions = reply.components(separatedBy: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func enableTLS() {
        let level = StreamSocketSecurityLevel.negotiatedSSL.rawValue as CFString
        input.setProperty(level, forKey: Stream.PropertyKey(kCFStreamPropertySocketSecurityLevel as String))
        output.setProperty(level, forKey: Stream.PropertyKey(kCFStreamPropertySocketSecurityLevel as String))
    }

    private func waitUntilOpen() throws {
        let deadline = Date().addingTimeInterval(20)
        while output.streamStatus == .opening || input.streamStatus == .opening {
            if Date() > deadline { throw PoscarError.timeout("Connecting to \(endpoint.host)") }
            Thread.sleep(forTimeInterval: 0.02)
        }
        if let error = input.streamError ?? output.streamError {
            throw PoscarError.connection("\(endpoint.host): \(error.localizedDescription)")
        }
    }

    private func write(_ data: Data) throws {
        var offset = 0
        while offset < data.count {
            let written = data[offset...].withUnsafeBytes { buffer in
                output.write(buffer.bindMemory(to: UInt8.self).baseAddress!, maxLength: buffer.count)
            }
            guard written > 0 else {
                throw PoscarError.connection(output.streamError?.localizedDescription ?? "Write to \(endpoint.host) failed")
            }
            offset += written
        }
    }

    /// Reads a possibly multi-line reply ("250-..." lines followed by "250 ...").
    @discardableResult
    private func expectReply(_ codes: [Int]) throws -> String {
        var lines: [String] = []
        while true {
            let line = try readLine()
            lines.append(String(line.dropFirst(4)))
            let isLast = line.count < 4 || line[line.index(line.startIndex, offsetBy: 3)] != "-"
            guard isLast else { continue }
            let code = Int(line.prefix(3)) ?? 0
            let text = lines.joined(separator: "\n")
            guard codes.contains(code) else {
                throw PoscarError.command("\(endpoint.host) replied \(code): \(text)")
            }
            return text
        }
    }

    private func readLine() throws -> String {
        let deadline = Date().addingTimeInterval(60)
        while true {
            if let newline = pending.firstIndex(of: 10) {
                let lineData = pending[pending.startIndex..<newline]
                pending = Data(pending[pending.index(after: newline)...])
                return String(decoding: lineData, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            }
            if Date() > deadline { throw PoscarError.timeout("Waiting for \(endpoint.host)") }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = input.read(&chunk, maxLength: chunk.count)
            if count < 0 {
                throw PoscarError.connection(input.streamError?.localizedDescription ?? "Read from \(endpoint.host) failed")
            }
            if count == 0 { throw PoscarError.connection("\(endpoint.host) closed the connection") }
            pending.append(contentsOf: chunk[0..<count])
        }
    }
}
