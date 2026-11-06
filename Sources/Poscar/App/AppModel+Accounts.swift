import AppKit
import Foundation
import GRDB
import PoscarCore

extension AppModel {
    /// How connections of this account log in. The keychain holds the password, or for Google
    /// sign-in the refresh token, which is traded for short-lived access tokens as needed.
    func credentialProvider(for account: Account) throws -> CredentialProvider {
        let secret = try Keychain.password(accountID: account.id)
        guard account.usesGoogleOAuth else { return { .password(secret) } }
        let tokens = googleTokens
        let accountID = account.id
        return { .oauthAccessToken(try await tokens.accessToken(accountID: accountID, refreshToken: secret)) }
    }

    /// Verifies the IMAP and SMTP logins, then stores the account and starts syncing it.
    func addAccount(_ account: Account, password: String) async throws {
        try ensureNotAdded(account.email)
        try await AccountSync.verify(account: account, credential: .password(password))
        try await SMTPClient(endpoint: account.smtp, username: account.username, credential: .password(password)).verify()
        try Keychain.savePassword(password, accountID: account.id)
        try store(account)
    }

    /// Signs in with Google in the browser and adds the account it returns.
    func addGoogleAccount() async throws {
        let signIn = try await GoogleOAuth(client: GoogleClient.config).signIn(openBrowser: Self.openInBrowser)
        NSApp.activate(ignoringOtherApps: true)
        try ensureNotAdded(signIn.email)
        guard let imap = AccountPreset.gmail.imap, let smtp = AccountPreset.gmail.smtp else { return }
        let account = Account(
            kind: .gmail,
            name: signIn.name.isEmpty ? signIn.email : signIn.name,
            email: signIn.email,
            username: signIn.email,
            imap: imap,
            smtp: smtp,
            colorIndex: accounts.count % AccountPalette.colors.count,
            authMethod: .googleOAuth
        )
        try await AccountSync.verify(account: account, credential: .oauthAccessToken(signIn.accessToken))
        await googleTokens.remember(GoogleOAuth.AccessToken(value: signIn.accessToken, expiresAt: signIn.expiresAt), accountID: account.id)
        try Keychain.savePassword(signIn.refreshToken, accountID: account.id)
        try store(account)
    }

    /// Moves an App Password account to Google sign-in, or signs a Google account in again.
    func signInWithGoogle(_ account: Account) async throws {
        let signIn = try await GoogleOAuth(client: GoogleClient.config).signIn(loginHint: account.email, openBrowser: Self.openInBrowser)
        NSApp.activate(ignoringOtherApps: true)
        guard signIn.email.caseInsensitiveCompare(account.email) == .orderedSame else {
            throw PoscarError.invalidInput("You signed in as \(signIn.email), but this account is \(account.email)")
        }
        var updated = account
        updated.authMethod = .googleOAuth
        try await AccountSync.verify(account: updated, credential: .oauthAccessToken(signIn.accessToken))
        await googleTokens.remember(GoogleOAuth.AccessToken(value: signIn.accessToken, expiresAt: signIn.expiresAt), accountID: account.id)
        try Keychain.savePassword(signIn.refreshToken, accountID: account.id)

        var all = accounts
        guard let index = all.firstIndex(where: { $0.id == account.id }) else { return }
        all[index] = updated
        try accountStore.save(all)
        accounts = all
        accountErrors[account.id] = nil
        await stopEngine(account.id)
        startEngine(updated)
    }

    nonisolated private static func openInBrowser(_ url: URL) {
        DispatchQueue.main.async { NSWorkspace.shared.open(url) }
    }

    private func ensureNotAdded(_ email: String) throws {
        guard !accounts.contains(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) else {
            throw PoscarError.invalidInput("\(email) is already added")
        }
    }

    private func store(_ account: Account) throws {
        var updated = accounts
        updated.append(account)
        try accountStore.save(updated)
        accounts = updated
        observeFolders()
        startEngine(account)
        if accounts.count == 1 { setMailbox(.unifiedInbox) }
    }

    func updateAccount(_ edited: Account, newPassword: String? = nil) async throws {
        var account = edited
        // A typed password replaces Google sign-in for this account.
        if newPassword?.isEmpty == false { account.authMethod = .password }
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let previous = accounts[index]
        let serversChanged = previous.imap != account.imap || previous.smtp != account.smtp || previous.username != account.username

        if let newPassword, !newPassword.isEmpty {
            try await AccountSync.verify(account: account, credential: .password(newPassword))
            try Keychain.savePassword(newPassword, accountID: account.id)
        } else if serversChanged {
            try await AccountSync.verify(account: account, credential: try await credentialProvider(for: account)())
        }

        var updated = accounts
        updated[index] = account
        try accountStore.save(updated)
        accounts = updated

        if serversChanged || newPassword?.isEmpty == false || previous.email != account.email {
            accountErrors[account.id] = nil
            await stopEngine(account.id)
            startEngine(account)
        }
    }

    /// Runs every step a sync needs and reports each one; a healthy account is (re)started.
    func checkConnection(_ account: Account) async -> [ConnectionStep] {
        var steps: [ConnectionStep] = []
        let signInTitle = account.usesGoogleOAuth ? "Google sign-in" : "Saved password"
        let credential: Credential
        do {
            credential = try await credentialProvider(for: account)()
            steps.append(ConnectionStep(title: signInTitle, detail: "OK", succeeded: true))
        } catch {
            steps.append(ConnectionStep(title: signInTitle, detail: error.localizedDescription, succeeded: false))
            return steps
        }

        do {
            try await AccountSync.verify(account: account, credential: credential)
            steps.append(ConnectionStep(title: "Incoming mail (IMAP)", detail: "\(account.imap.host) — OK", succeeded: true))
        } catch {
            steps.append(ConnectionStep(title: "Incoming mail (IMAP)", detail: error.localizedDescription, succeeded: false))
        }
        do {
            try await SMTPClient(endpoint: account.smtp, username: account.username, credential: credential).verify()
            steps.append(ConnectionStep(title: "Outgoing mail (SMTP)", detail: "\(account.smtp.host) — OK", succeeded: true))
        } catch {
            steps.append(ConnectionStep(title: "Outgoing mail (SMTP)", detail: error.localizedDescription, succeeded: false))
        }

        if steps.allSatisfy(\.succeeded) {
            accountErrors[account.id] = nil
            await stopEngine(account.id)
            startEngine(account)
        }
        return steps
    }

    func setColor(of accountID: String, index: Int, custom: String?) {
        guard let position = accounts.firstIndex(where: { $0.id == accountID }) else { return }
        var updated = accounts
        updated[position].colorIndex = index
        updated[position].customColor = custom
        do {
            try accountStore.save(updated)
            accounts = updated
        } catch {
            showError(error.localizedDescription)
        }
    }

    func removeAccount(_ id: String) async {
        await stopEngine(id)
        await googleTokens.forget(accountID: id)
        do {
            try Keychain.deletePassword(accountID: id)
            var updated = accounts
            updated.removeAll { $0.id == id }
            try accountStore.save(updated)
            accounts = updated
            try await database?.removeAccount(id)
        } catch {
            showError(error.localizedDescription)
        }
        observeFolders()
        if mailbox.accountId == id { setMailbox(.unifiedInbox) }
        syncStatus[id] = nil
        accountErrors[id] = nil
    }

    func moveAccount(from source: IndexSet, to destination: Int) {
        var updated = accounts
        updated.move(fromOffsets: source, toOffset: destination)
        do {
            try accountStore.save(updated)
            accounts = updated
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: - Outbox

    static let undoSendDelay: TimeInterval = 5

    /// Queues a message. It is sent after the undo window, or at `sendAt` when scheduled.
    func enqueueSend(_ message: OutgoingMessage, account: Account, replyToRowId: Int64?, sendAt: Date?) async throws {
        guard let database else { return }
        let messageID = MessageBuilder.makeMessageID(domain: account.domain)
        let raw = MessageBuilder.build(message, messageID: messageID)
        let unsaved = OutboxRecord(
            id: nil,
            accountId: account.id,
            sendAt: sendAt ?? Date().addingTimeInterval(Self.undoSendDelay),
            message: try JSONEncoder().encode(message),
            raw: raw,
            messageId: messageID,
            replyToMessageRowId: replyToRowId,
            lastError: nil
        )
        let record = try await database.writer.write { db -> OutboxRecord in
            var record = unsaved
            try record.insert(db)
            return record
        }

        if let id = record.id {
            undoStack.append(.send(id))
            if let sendAt {
                showToast("Scheduled for \(sendAt.formatted(date: .abbreviated, time: .shortened))", undoable: true)
            } else {
                showToast("Sending…", undoable: true)
            }
        }
    }

    func cancelSend(_ outboxID: Int64) {
        guard let database else { return }
        Task {
            do {
                let record = try await database.writer.write { db -> OutboxRecord? in
                    guard let record = try OutboxRecord.fetchOne(db, key: outboxID) else { return nil }
                    try record.delete(db)
                    return record
                }
                guard let record else {
                    showToast("Already sent")
                    return
                }
                composers.reopen(record, error: nil)
                showToast("Sending undone")
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    func sendNow(_ outboxID: Int64) {
        guard let database else { return }
        Task {
            try? await database.writer.write { db in
                try db.execute(sql: "UPDATE outbox SET sendAt = ? WHERE id = ?", arguments: [Date(), outboxID])
            }
            await processOutbox()
        }
    }

    func processOutbox() async {
        guard let database, !isSendingOutbox else { return }
        isSendingOutbox = true
        defer { isSendingOutbox = false }

        let due = (try? await database.writer.read { db in
            try OutboxRecord.filter(Column("sendAt") <= Date() && Column("lastError") == nil).order(Column("sendAt")).fetchAll(db)
        }) ?? []

        for item in due {
            guard let id = item.id else { continue }
            guard let account = account(item.accountId) else {
                _ = try? await database.writer.write { db in try OutboxRecord.deleteOne(db, key: id) }
                continue
            }
            do {
                // Claim the row first so undo can no longer take it back mid-send.
                let claimed = try await database.writer.write { db -> Bool in
                    try OutboxRecord.deleteOne(db, key: id)
                }
                guard claimed else { continue }
                undoStack.removeAll { entry in
                    if case .send(id) = entry { return true }
                    return false
                }
                try await send(item, account: account)
                if toast?.text == "Sending…" { showToast("Message sent") }
            } catch {
                composers.reopen(item, error: "Not sent: \(error.localizedDescription)")
                showError("Message to \((try? item.decodedMessage().to.first?.displayName) ?? "recipient") was not sent")
            }
        }
    }

    private func send(_ item: OutboxRecord, account: Account) async throws {
        let message = try item.decodedMessage()
        let credential = try await credentialProvider(for: account)()
        let smtp = SMTPClient(endpoint: account.smtp, username: account.username, credential: credential)
        try await smtp.send(item.raw, from: account.email, to: message.allRecipients.map(\.email))

        guard let engine = engines[account.id] else { return }
        // Gmail files sent mail itself; other servers need a copy in Sent.
        if !account.isGmail, let sent = folders[account.id]?.path(for: .sent) {
            try? await engine.append(item.raw, to: sent, flags: ["\\Seen"])
        }
        if let rowID = item.replyToMessageRowId,
           let original = try? await database?.writer.read({ db in try MessageRecord.fetchOne(db, key: rowID) }) {
            try? await engine.perform([.store(folder: original.folder, uids: [UInt32(original.uid)], operation: "+FLAGS.SILENT (\\Answered)")])
        } else {
            await engine.sync()
        }
    }
}

struct ConnectionStep: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let succeeded: Bool
}
