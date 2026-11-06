import Foundation
import Security

/// Account passwords and Google refresh tokens, kept together in one keychain item.
///
/// Builds signed with a self-made certificate get a new keychain identity on every update, and
/// macOS asks again for each item they touch. With a single item that is one question per update
/// instead of one per account. The secrets are cached in memory after the first read.
public enum Keychain {
    static let service = "io.github.aleksandargosevski.poscar"
    static let vaultAccount = "poscar.secrets"
    private static let vault = Vault()

    public static func savePassword(_ password: String, accountID: String) throws {
        try vault.update { $0[accountID] = password }
    }

    public static func password(accountID: String) throws -> String {
        if let secret = try vault.secrets()[accountID] { return secret }
        // Accounts added before the shared item existed had an item each; move theirs over once.
        let legacy = try readItem(account: accountID)
        try vault.update { $0[accountID] = legacy }
        try? deleteItem(account: accountID)
        return legacy
    }

    public static func deletePassword(accountID: String) throws {
        try vault.update { $0[accountID] = nil }
        try? deleteItem(account: accountID)
    }

    private final class Vault: @unchecked Sendable {
        private let lock = NSLock()
        private var cache: [String: String]?

        func secrets() throws -> [String: String] {
            lock.lock()
            defer { lock.unlock() }
            return try loaded()
        }

        func update(_ change: (inout [String: String]) -> Void) throws {
            lock.lock()
            defer { lock.unlock() }
            var secrets = try loaded()
            change(&secrets)
            let data = try JSONEncoder().encode(secrets)
            try writeItem(account: Keychain.vaultAccount, data: data)
            cache = secrets
        }

        /// Must be called with the lock held. A failed read is not cached, so a later call can ask again.
        private func loaded() throws -> [String: String] {
            if let cache { return cache }
            let secrets: [String: String]
            do {
                let data = try readData(account: Keychain.vaultAccount)
                secrets = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
            } catch PoscarError.keychain(let message) where message == notFoundMessage {
                secrets = [:]
            }
            cache = secrets
            return secrets
        }
    }

    // MARK: - Keychain items

    private static let notFoundMessage = "No password saved for this account"

    private static func readItem(account: String) throws -> String {
        guard let password = String(data: try readData(account: account), encoding: .utf8) else {
            throw PoscarError.keychain("The saved password is unreadable")
        }
        return password
    }

    private static func readData(account: String) throws -> Data {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw status == errSecItemNotFound ? PoscarError.keychain(notFoundMessage) : error(status)
        }
        return data
    }

    private static func writeItem(account: String, data: Data) throws {
        let query = baseQuery(account)
        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw error(updateStatus) }

        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecAttrLabel as String] = "Poscar mail accounts"
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw error(addStatus) }
    }

    private static func deleteItem(account: String) throws {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static func error(_ status: OSStatus) -> PoscarError {
        // Happens when the app's signature changed since the item was saved and the access prompt was dismissed.
        if status == errSecUserCanceled || status == errSecAuthFailed || status == errSecInteractionNotAllowed {
            return .keychain("Pošćar may not read its saved passwords. Allow access when macOS asks (choose Always Allow), or use Check Connection in Settings → Accounts.")
        }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "status \(status)"
        return .keychain(message)
    }
}
