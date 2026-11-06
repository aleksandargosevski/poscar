import Foundation

public enum AccountKind: String, Codable, Sendable {
    case gmail
    case imap
}

public enum ConnectionSecurity: String, Codable, Sendable, CaseIterable {
    /// TLS from the first byte (IMAP 993, SMTP 465).
    case tls
    /// Plain connection upgraded with STARTTLS (SMTP 587).
    case startTLS
}

public enum AuthMethod: String, Codable, Sendable {
    /// A password or app password, stored in the keychain.
    case password
    /// Google sign-in in the browser; the keychain holds the OAuth refresh token.
    case googleOAuth
}

/// What a connection logs in with.
public enum Credential: Sendable {
    case password(String)
    case oauthAccessToken(String)
}

public typealias CredentialProvider = @Sendable () async throws -> Credential

public struct ServerEndpoint: Codable, Hashable, Sendable {
    public var host: String
    public var port: Int
    public var security: ConnectionSecurity

    public init(host: String, port: Int, security: ConnectionSecurity) {
        self.host = host
        self.port = port
        self.security = security
    }
}

public struct Account: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var kind: AccountKind
    public var name: String
    public var email: String
    public var username: String
    public var imap: ServerEndpoint
    public var smtp: ServerEndpoint
    public var colorIndex: Int
    /// A hex colour such as `#f97316` that overrides `colorIndex` when set.
    public var customColor: String?
    public var signature: String
    public var notificationsEnabled: Bool
    /// Missing in accounts saved before Google sign-in existed, which all used passwords.
    public var authMethod: AuthMethod?

    public var usesGoogleOAuth: Bool { authMethod == .googleOAuth }

    public init(
        id: String = UUID().uuidString,
        kind: AccountKind,
        name: String,
        email: String,
        username: String,
        imap: ServerEndpoint,
        smtp: ServerEndpoint,
        colorIndex: Int = 0,
        signature: String = "",
        notificationsEnabled: Bool = true,
        authMethod: AuthMethod = .password
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.email = email
        self.username = username
        self.imap = imap
        self.smtp = smtp
        self.colorIndex = colorIndex
        self.signature = signature
        self.notificationsEnabled = notificationsEnabled
        self.authMethod = authMethod
    }

    public var isGmail: Bool { kind == .gmail }

    /// Domain used for generated Message-IDs.
    public var domain: String {
        email.split(separator: "@").last.map(String.init) ?? "poscar.local"
    }
}

/// Server settings for well-known providers. Users pick one when adding an account.
public enum AccountPreset: String, CaseIterable, Identifiable, Sendable {
    case gmail
    case icloud
    case fastmail
    case other

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .gmail: "Gmail / Google Workspace"
        case .icloud: "iCloud"
        case .fastmail: "Fastmail"
        case .other: "Other IMAP"
        }
    }

    public var passwordHelp: String {
        switch self {
        case .gmail: "Use an App Password (Google Account → Security → 2-Step Verification → App passwords)."
        case .icloud: "Use an app-specific password from account.apple.com."
        case .fastmail: "Use an app password from Fastmail → Settings → Privacy & Security."
        case .other: "Your IMAP password."
        }
    }

    public var kind: AccountKind { self == .gmail ? .gmail : .imap }

    public var imap: ServerEndpoint? {
        switch self {
        case .gmail: ServerEndpoint(host: "imap.gmail.com", port: 993, security: .tls)
        case .icloud: ServerEndpoint(host: "imap.mail.me.com", port: 993, security: .tls)
        case .fastmail: ServerEndpoint(host: "imap.fastmail.com", port: 993, security: .tls)
        case .other: nil
        }
    }

    public var smtp: ServerEndpoint? {
        switch self {
        case .gmail: ServerEndpoint(host: "smtp.gmail.com", port: 465, security: .tls)
        case .icloud: ServerEndpoint(host: "smtp.mail.me.com", port: 587, security: .startTLS)
        case .fastmail: ServerEndpoint(host: "smtp.fastmail.com", port: 465, security: .tls)
        case .other: nil
        }
    }
}
