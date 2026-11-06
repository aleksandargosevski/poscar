import Foundation
import Testing
@testable import PoscarCore

/// Talks to real servers with invalid credentials to exercise TLS, STARTTLS and response parsing.
/// Run with POSCAR_NETWORK_TESTS=1 ./scripts/test.sh
@Suite(.enabled(if: ProcessInfo.processInfo.environment["POSCAR_NETWORK_TESTS"] == "1"))
struct NetworkTests {
    @Test func imapRejectsBadLoginCleanly() async throws {
        let client = IMAPClient(endpoint: ServerEndpoint(host: "imap.gmail.com", port: 993, security: .tls),
                                username: "poscar.test@gmail.com", credential: .password("wrong-password"))
        await #expect(throws: PoscarError.self) { try await client.connect() }
        do {
            try await client.connect()
        } catch let error as PoscarError {
            guard case .authentication = error else {
                Issue.record("expected an authentication error, got \(error)")
                return
            }
        }
    }

    @Test func xoauth2RejectionDoesNotHang() async throws {
        let imap = IMAPClient(endpoint: ServerEndpoint(host: "imap.gmail.com", port: 993, security: .tls),
                              username: "poscar.test@gmail.com", credential: .oauthAccessToken("invalid-token"))
        do {
            try await imap.connect()
            Issue.record("IMAP login should fail")
        } catch let error as PoscarError {
            guard case .authentication = error else { Issue.record("IMAP: expected authentication error, got \(error)"); return }
        }

        let smtp = SMTPClient(endpoint: ServerEndpoint(host: "smtp.gmail.com", port: 465, security: .tls),
                              username: "poscar.test@gmail.com", credential: .oauthAccessToken("invalid-token"))
        do {
            try await smtp.verify()
            Issue.record("SMTP login should fail")
        } catch let error as PoscarError {
            guard case .authentication = error else { Issue.record("SMTP: expected authentication error, got \(error)"); return }
        }
    }

    @Test(arguments: [
        ServerEndpoint(host: "smtp.gmail.com", port: 465, security: .tls),
        ServerEndpoint(host: "smtp.gmail.com", port: 587, security: .startTLS),
    ])
    func smtpRejectsBadLogin(endpoint: ServerEndpoint) async throws {
        let client = SMTPClient(endpoint: endpoint, username: "poscar.test@gmail.com", credential: .password("wrong-password"))
        do {
            try await client.verify()
            Issue.record("login should fail")
        } catch let error as PoscarError {
            guard case .authentication = error else {
                Issue.record("expected an authentication error, got \(error)")
                return
            }
        }
    }
}
