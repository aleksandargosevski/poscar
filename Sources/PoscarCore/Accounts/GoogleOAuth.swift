import CryptoKit
import Foundation
import Network

/// Google sign-in for installed apps: browser consent with PKCE and a loopback redirect,
/// then IMAP/SMTP via XOAUTH2. See developers.google.com/identity/protocols/oauth2/native-app.
public struct GoogleOAuth: Sendable {
    public struct Client: Sendable {
        public let id: String
        /// Not confidential for desktop apps; Google requires it for the token exchange anyway.
        public let secret: String

        public init(id: String, secret: String) {
            self.id = id
            self.secret = secret
        }

        public var isConfigured: Bool { !id.isEmpty && !secret.isEmpty }
    }

    public struct SignIn: Sendable {
        public var email: String
        public var name: String
        public var refreshToken: String
        public var accessToken: String
        public var expiresAt: Date
    }

    public struct AccessToken: Sendable {
        public var value: String
        public var expiresAt: Date

        public init(value: String, expiresAt: Date) {
            self.value = value
            self.expiresAt = expiresAt
        }
    }

    static let scopes = "https://mail.google.com/ openid email profile"
    static let authorizationURL = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!

    public let client: Client

    public init(client: Client) {
        self.client = client
    }

    /// Opens Google's consent page via `openBrowser` and waits up to five minutes for the user.
    public func signIn(loginHint: String? = nil, openBrowser: @escaping @Sendable (URL) -> Void) async throws -> SignIn {
        guard client.isConfigured else { throw PoscarError.authentication("Google sign-in is not configured in this build") }

        let verifier = Self.randomURLSafeString(bytes: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
        let state = Self.randomURLSafeString(bytes: 16)

        let receiver = try await LoopbackReceiver.start()
        defer { receiver.stop() }
        let redirectURI = "http://127.0.0.1:\(receiver.port)"

        var components = URLComponents(url: Self.authorizationURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: client.id),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "access_type", value: "offline"),
            // Forces a refresh token even when the account approved Poscar before.
            URLQueryItem(name: "prompt", value: "consent select_account"),
        ] + (loginHint.map { [URLQueryItem(name: "login_hint", value: $0)] } ?? [])
        openBrowser(components.url!)

        let callback = try await receiver.waitForCallback(timeout: 300)
        guard callback["state"] == state else { throw PoscarError.authentication("Sign-in response did not match the request") }
        if let error = callback["error"] {
            throw PoscarError.authentication(error == "access_denied" ? "Access was not granted" : error)
        }
        guard let code = callback["code"] else { throw PoscarError.authentication("Google sent no authorization code") }

        let response = try await tokenRequest([
            "code": code,
            "client_id": client.id,
            "client_secret": client.secret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ])
        guard let refreshToken = response.refresh_token else {
            throw PoscarError.authentication("Google returned no refresh token; remove Poscar's access in your Google account and try again")
        }
        let identity = response.id_token.flatMap(Self.decodeIdentity) ?? [:]
        guard let email = identity["email"] as? String else { throw PoscarError.authentication("Google did not share the email address") }
        return SignIn(
            email: email,
            name: identity["name"] as? String ?? "",
            refreshToken: refreshToken,
            accessToken: response.access_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3600))
        )
    }

    public func refresh(_ refreshToken: String) async throws -> AccessToken {
        let response = try await tokenRequest([
            "refresh_token": refreshToken,
            "client_id": client.id,
            "client_secret": client.secret,
            "grant_type": "refresh_token",
        ])
        return AccessToken(value: response.access_token, expiresAt: Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3600)))
    }

    // MARK: - Helpers

    struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Int?
        let refresh_token: String?
        let id_token: String?
    }

    struct TokenError: Decodable {
        let error: String
        let error_description: String?
    }

    private func tokenRequest(_ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value)"
        }.joined(separator: "&").utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let failure = try? JSONDecoder().decode(TokenError.self, from: data)
            if failure?.error == "invalid_grant" {
                throw PoscarError.authentication("Google sign-in expired or was revoked; sign in again in Settings → Accounts")
            }
            throw PoscarError.authentication(failure?.error_description ?? failure?.error ?? "Google token request failed")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    /// Reads the claims of the ID token. It arrives over TLS straight from Google, so the signature isn't checked.
    static func decodeIdentity(_ idToken: String) -> [String: Any]? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2, let payload = Data(base64URLEncoded: String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }

    static func randomURLSafeString(bytes: Int) -> String {
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            for index in buffer.indices { buffer[index] = UInt8.random(in: 0...255) }
        }
        return data.base64URLEncoded
    }
}

/// Caches access tokens and refreshes them shortly before they expire.
public actor GoogleTokenStore {
    private let oauth: GoogleOAuth
    private var tokens: [String: GoogleOAuth.AccessToken] = [:]

    public init(oauth: GoogleOAuth) {
        self.oauth = oauth
    }

    public func remember(_ token: GoogleOAuth.AccessToken, accountID: String) {
        tokens[accountID] = token
    }

    public func accessToken(accountID: String, refreshToken: String) async throws -> String {
        if let token = tokens[accountID], token.expiresAt.timeIntervalSinceNow > 120 { return token.value }
        let fresh = try await oauth.refresh(refreshToken)
        tokens[accountID] = fresh
        return fresh.value
    }

    public func forget(accountID: String) {
        tokens[accountID] = nil
    }
}

/// A one-shot HTTP server on 127.0.0.1 that receives the browser redirect.
final class LoopbackReceiver: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "poscar.oauth.loopback")
    private let lock = NSLock()
    private var continuation: CheckedContinuation<[String: String], Error>?
    private var result: Result<[String: String], Error>?
    let port: UInt16

    private init(listener: NWListener, port: UInt16) {
        self.listener = listener
        self.port = port
    }

    static func start() async throws -> LoopbackReceiver {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        let queue = DispatchQueue(label: "poscar.oauth.listener")

        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // State updates arrive on the listener's serial queue, so the flag needs no lock.
            let resumed = ResumedFlag()
            listener.stateUpdateHandler = { state in
                guard !resumed.value else { return }
                switch state {
                case .ready:
                    resumed.value = true
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed.value = true
                    continuation.resume(throwing: PoscarError.connection("Could not wait for Google: \(error.localizedDescription)"))
                default:
                    break
                }
            }
            listener.newConnectionHandler = { _ in }
            listener.start(queue: queue)
        }

        let receiver = LoopbackReceiver(listener: listener, port: port)
        listener.newConnectionHandler = { [weak receiver] connection in receiver?.handle(connection) }
        return receiver
    }

    func waitForCallback(timeout: TimeInterval) async throws -> [String: String] {
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(PoscarError.timeout("Google sign-in was not completed")))
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let result {
                    lock.unlock()
                    continuation.resume(with: result)
                } else {
                    self.continuation = continuation
                    lock.unlock()
                }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            guard let self else { return }
            let request = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
            guard let line = request.split(separator: "\r\n").first,
                  let target = line.split(separator: " ").dropFirst().first,
                  let components = URLComponents(string: "http://127.0.0.1\(target)"),
                  let items = components.queryItems, !items.isEmpty else {
                self.respond(connection, status: "404 Not Found", body: "")
                return
            }
            var query: [String: String] = [:]
            for item in items { query[item.name] = item.value ?? "" }
            let succeeded = query["code"] != nil
            self.respond(connection, status: "200 OK", body: Self.page(succeeded: succeeded))
            self.finish(.success(query))
        }
    }

    private func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }

    private func finish(_ outcome: Result<[String: String], Error>) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = outcome
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: outcome)
    }

    private static func page(succeeded: Bool) -> String {
        let message = succeeded ? "You're signed in. You can close this tab and return to Pošćar." : "Sign-in was cancelled. You can close this tab."
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>Pošćar</title></head>
        <body style="font:16px -apple-system,sans-serif;display:flex;height:90vh;align-items:center;justify-content:center;color:#2a2622;background:#f9f7f4">
        <p>\(message)</p></body></html>
        """
    }
}

private final class ResumedFlag: @unchecked Sendable {
    var value = false
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}

extension CharacterSet {
    static let urlQueryValueAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
}
