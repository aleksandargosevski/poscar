import Foundation

/// Persists account settings (never passwords) as JSON in Application Support.
public struct AccountStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = AppPaths.supportDirectory.appendingPathComponent("accounts.json")) {
        self.fileURL = fileURL
    }

    public func load() throws -> [Account] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([Account].self, from: data)
        } catch {
            throw PoscarError.storage("Could not read \(fileURL.path): \(error.localizedDescription)")
        }
    }

    public func save(_ accounts: [Account]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(accounts).write(to: fileURL, options: .atomic)
        } catch {
            throw PoscarError.storage("Could not save accounts: \(error.localizedDescription)")
        }
    }
}

public enum AppPaths {
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Poscar", isDirectory: true)
    }

    public static var configDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/poscar", isDirectory: true)
    }
}

public enum PoscarError: LocalizedError, Equatable {
    case storage(String)
    case keychain(String)
    case connection(String)
    case authentication(String)
    case command(String)
    case protocolViolation(String)
    case timeout(String)
    case invalidInput(String)

    public var errorDescription: String? {
        switch self {
        case .storage(let message): message
        case .keychain(let message): "Keychain: \(message)"
        case .connection(let message): "Connection failed: \(message)"
        case .authentication(let message): "Login failed: \(message)"
        case .command(let message): "Server error: \(message)"
        case .protocolViolation(let message): "Unexpected server response: \(message)"
        case .timeout(let message): "Timed out: \(message)"
        case .invalidInput(let message): message
        }
    }
}
