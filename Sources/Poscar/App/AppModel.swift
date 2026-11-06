import AppKit
import GRDB
import PoscarCore
import SwiftUI

enum FocusArea {
    case list
    case reader
}

enum Overlay: Equatable {
    case palette
    case shortcuts
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var undoable = false
    var isError = false
}

enum UndoEntry {
    case action(UUID)
    case send(Int64)
}

struct ThreadDetail {
    var thread: ThreadID
    var messages: [MessageRecord] = []
    var parsed: [Int64: ParsedMessage] = [:]
    var thumbnails: [Int64: [Int: Data]] = [:]
    var errors: [Int64: String] = [:]
    var initiallyUnread: Set<Int64> = []
    var loadImages: Bool
    var focusedIndex: Int?

    /// Messages are newest first.
    var subject: String { messages.first?.subject ?? "" }

    var focusedMessage: MessageRecord? {
        guard let focusedIndex, messages.indices.contains(focusedIndex) else { return messages.first }
        return messages[focusedIndex]
    }
}

@MainActor
@Observable
final class AppModel {
    // MARK: - State shown by views

    var accounts: [Account] = []
    var folders: [String: AccountFolders] = [:]
    var mailbox: Mailbox = .unifiedInbox
    var threads: [ThreadSummary] = []
    var selectedThreadID: ThreadID? {
        didSet {
            guard oldValue != selectedThreadID else { return }
            // The conversation is only loaded while it is open; browsing the list stays cheap.
            if focus == .reader {
                if selectedThreadID == nil { closeThread() } else { loadDetail() }
            }
        }
    }
    var checked: Set<ThreadID> = []
    var detail: ThreadDetail?
    /// `.reader` means a conversation is open over the list.
    var focus: FocusArea = .list
    var overlay: Overlay?
    var paletteMode: PaletteMode = .commands
    var paletteQuery = "" {
        didSet { paletteIndex = 0 }
    }
    var paletteIndex = 0
    var toast: Toast?
    var syncStatus: [String: String] = [:]
    var accountErrors: [String: String] = [:]
    var keymap = Keymap()
    var keymapWarnings: [String] = []
    var pendingKeys: [KeyChord] = []
    var searchText = ""
    var activeSearch: String?
    var searchResultIDs: [Int64]?
    var isSearching = false
    var scheduled: [OutboxRecord] = []
    var showingScheduled = false {
        didSet { if showingScheduled { showingAttachments = false } }
    }
    var showingAttachments = false {
        didSet {
            if showingAttachments {
                showingScheduled = false
                if focus == .reader { closeThread() }
                observeAttachments()
            } else {
                attachmentObservationStore = nil
            }
        }
    }
    var attachmentFilter = AttachmentFilter() {
        didSet { if showingAttachments, attachmentFilter != oldValue { observeAttachments() } }
    }
    var attachments: [AttachmentRecord] = []
    var selectedAttachmentID: Int64?
    /// Columns the attachment grid currently shows, so ↑/↓ move by a whole row.
    @ObservationIgnored var attachmentColumns = 1
    var attachmentCounts: [AttachmentKind: Int] = [:]
    var searchSuggestions: [SearchSuggestion] = []
    var searchSuggestionIndex = 0
    var unreadCount = 0
    var fatalError: String?
    var threadLimit = 300
    var searchFocusRequest = 0
    /// Where the active search looks: everywhere, or the mailbox named by `in:`.
    var searchScope = Mailbox(kind: .everywhere)
    var sidebarVisible = true
    var listScrollTarget: ThreadID?

    var showInDock = true {
        didSet {
            if !showInDock, !showInMenuBar { showInMenuBar = true }
            UserDefaults.standard.set(showInDock, forKey: "showInDock")
            applyAppearance()
        }
    }
    var showInMenuBar = true {
        didSet {
            if !showInMenuBar, !showInDock { showInDock = true }
            UserDefaults.standard.set(showInMenuBar, forKey: "showInMenuBar")
            applyAppearance()
        }
    }
    /// System-wide shortcut that shows or hides Poscar.
    var toggleHotKey: KeyChord? = KeyChord(parsing: "ctrl+opt+m") {
        didSet {
            UserDefaults.standard.set(toggleHotKey?.description ?? "", forKey: "toggleHotKey")
            registerHotKey()
        }
    }
    var hotKeyError: String?
    var notificationsAllowed: Bool?

    @ObservationIgnored var alwaysLoadImages: Bool {
        get { UserDefaults.standard.bool(forKey: "alwaysLoadImages") }
        set { UserDefaults.standard.set(newValue, forKey: "alwaysLoadImages") }
    }

    // MARK: - Services

    @ObservationIgnored private(set) var database: MailDatabase?
    @ObservationIgnored var engines: [String: AccountSync] = [:]
    @ObservationIgnored let accountStore = AccountStore()
    @ObservationIgnored let keymapStore = KeymapStore()
    @ObservationIgnored let reader = ReaderController()
    @ObservationIgnored let keyboard = KeyboardRouter()
    @ObservationIgnored let notifications = NotificationController()
    @ObservationIgnored let menuBar = MenuBarController()
    @ObservationIgnored let hotKey = GlobalHotKey()
    @ObservationIgnored let googleTokens = GoogleTokenStore(oauth: GoogleOAuth(client: GoogleClient.config))
    @ObservationIgnored lazy var actions = ActionQueue(model: self)
    @ObservationIgnored lazy var composers = ComposerManager(model: self)
    @ObservationIgnored var undoStack: [UndoEntry] = []
    @ObservationIgnored weak var mainWindow: NSWindow?
    @ObservationIgnored var openMainWindow: (() -> Void)?

    @ObservationIgnored private var threadObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var detailObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var folderObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var badgeObservation: AnyDatabaseCancellable?
    @ObservationIgnored private var outboxObservation: AnyDatabaseCancellable?
    @ObservationIgnored var attachmentObservationStore: AnyDatabaseCancellable?
    @ObservationIgnored private var outboxTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var bodyLoads: Set<Int64> = []
    @ObservationIgnored private var markedReadThread: ThreadID?
    @ObservationIgnored private var lastSelectedIndex = 0
    @ObservationIgnored var isSendingOutbox = false
    /// Expanded messages change through scripts in the web view; keeping them out of observation avoids a reload.
    @ObservationIgnored var expandedMessages: Set<Int64> = []
    /// Opening a folder selects its first conversation once the list has loaded.
    @ObservationIgnored var selectFirstWhenLoaded = true
    @ObservationIgnored private var renderCache: (key: String, output: ThreadRenderer.Output)?

    // MARK: - Lifecycle

    func start() {
        do {
            database = try MailDatabase(url: MailDatabase.defaultURL)
        } catch {
            fatalError = error.localizedDescription
            return
        }
        do {
            accounts = try accountStore.load()
        } catch {
            showError(error.localizedDescription)
        }
        reloadKeymap()
        loadAppearance()
        accounts.forEach(startEngine)
        observeFolders()
        observeOutbox()
        keyboard.install(model: self)
        notifications.install(model: self)
        indexOldAttachments()
        outboxTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.processOutbox()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.restartEngines() }
        }
    }

    func prepareForTermination() async {
        await actions.commitAll()
        for engine in engines.values { await engine.stop() }
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        let window = mainWindow ?? NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Pošćar" }
        if let window {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    // MARK: - Dock, menu bar and global shortcut

    private func loadAppearance() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "showInDock") != nil { showInDock = defaults.bool(forKey: "showInDock") }
        if defaults.object(forKey: "showInMenuBar") != nil { showInMenuBar = defaults.bool(forKey: "showInMenuBar") }
        if let stored = defaults.string(forKey: "toggleHotKey") { toggleHotKey = KeyChord(parsing: stored) }
        menuBar.install(model: self)
        hotKey.onPress = { [weak self] in self?.toggleAppVisibility() }
        applyAppearance()
        registerHotKey()
    }

    private func applyAppearance() {
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        if NSApp.activationPolicy() != policy {
            NSApp.setActivationPolicy(policy)
            // Switching to accessory hides the app's windows from the switcher; keep the window up front.
            if !showInDock { DispatchQueue.main.async { [weak self] in self?.showMainWindow() } }
        }
        menuBar.setVisible(showInMenuBar)
        updateBadges()
    }

    private func updateBadges() {
        NSApp.dockTile.badgeLabel = showInDock && unreadCount > 0 ? "\(unreadCount)" : nil
        menuBar.update(unread: unreadCount)
    }

    private func registerHotKey() {
        hotKeyError = hotKey.register(toggleHotKey) ? nil : "\(toggleHotKey?.symbols.joined() ?? "") is taken by another app or needs ⌘, ⌃ or ⌥."
    }

    func toggleAppVisibility() {
        if NSApp.isActive, mainWindow?.isKeyWindow == true {
            NSApp.hide(nil)
        } else {
            showMainWindow()
        }
    }

    func reloadKeymap() {
        let loaded = keymapStore.load()
        keymap = loaded.keymap
        keymapWarnings = loaded.warnings
    }

    func saveKeymap(_ keymap: Keymap) {
        do {
            try keymapStore.save(keymap)
            self.keymap = keymap
            keymapWarnings = []
        } catch {
            showError(error.localizedDescription)
        }
    }

    // MARK: - Engines

    func startEngine(_ account: Account) {
        guard let database else { return }
        let credentials: CredentialProvider
        do {
            credentials = try credentialProvider(for: account)
        } catch {
            accountErrors[account.id] = error.localizedDescription
            return
        }
        let engine = AccountSync(account: account, credentials: credentials, database: database)
        engines[account.id] = engine
        let accountID = account.id
        Task {
            await engine.setHandlers(
                newMail: { [weak self] messages in
                    Task { @MainActor in self?.notifyNewMail(messages, accountID: accountID) }
                },
                status: { [weak self] status in
                    Task { @MainActor in self?.syncStatus[accountID] = status }
                },
                error: { [weak self] error in
                    Task { @MainActor in self?.accountErrors[accountID] = error.localizedDescription }
                }
            )
            await engine.start()
        }
    }

    func stopEngine(_ accountID: String) async {
        if let engine = engines.removeValue(forKey: accountID) {
            await engine.stop()
        }
    }

    func restartEngines() {
        Task {
            for account in accounts {
                await stopEngine(account.id)
                startEngine(account)
            }
        }
    }

    func refresh() {
        accountErrors = [:]
        for (id, engine) in engines {
            syncStatus[id] = "Checking for mail…"
            Task { await engine.sync() }
        }
        for account in accounts where engines[account.id] == nil {
            startEngine(account)
        }
    }

    func engine(for accountID: String) -> AccountSync? {
        engines[accountID]
    }

    func account(_ id: String) -> Account? {
        accounts.first { $0.id == id }
    }

    func accountIndex(_ id: String) -> Int {
        accounts.firstIndex { $0.id == id } ?? 0
    }

    private func notifyNewMail(_ messages: [MessageRecord], accountID: String) {
        accountErrors[accountID] = nil
        guard let account = account(accountID), account.notificationsEnabled else { return }
        notifications.post(messages, account: account)
    }

    // MARK: - Observation

    func observeFolders() {
        guard let database else { return }
        folderObservation = ValueObservation
            .tracking { db in try FolderRecord.fetchAll(db) }
            .removeDuplicates()
            .start(in: database.writer, scheduling: .immediate) { [weak self] error in
                self?.showError(error.localizedDescription)
            } onChange: { [weak self] records in
                self?.foldersChanged(records)
            }
    }

    func foldersChanged(_ records: [FolderRecord]) {
        let grouped = Dictionary(grouping: records, by: \.accountId)
        var result: [String: AccountFolders] = [:]
        for account in accounts {
            result[account.id] = AccountFolders(accountId: account.id, isGmail: account.isGmail, folders: grouped[account.id] ?? [])
        }
        guard result != folders else { return }
        folders = result
        observeThreads()
        observeBadge()
        if detail != nil { loadDetail() }
    }

    func observeThreads() {
        guard let database else { return }
        let mailbox = activeSearch != nil ? searchScope : mailbox
        let accountFolders = accounts.compactMap { folders[$0.id] }
        let restrictTo = searchResultIDs
        let limit = threadLimit

        if activeSearch != nil, restrictTo == nil {
            threadObservation = nil
            threads = []
            return
        }
        threadObservation = ValueObservation
            .tracking { db in
                try MailQueries.threads(db, mailbox: mailbox, accounts: accountFolders, restrictTo: restrictTo, limit: limit)
            }
            .removeDuplicates()
            .start(in: database.writer, scheduling: .immediate) { [weak self] error in
                self?.showError(error.localizedDescription)
            } onChange: { [weak self] threads in
                self?.threadsChanged(threads)
            }
    }

    private func threadsChanged(_ newThreads: [ThreadSummary]) {
        threads = newThreads
        checked = checked.filter { id in newThreads.contains { $0.id == id } }
        if selectFirstWhenLoaded, let first = newThreads.first {
            selectFirstWhenLoaded = false
            lastSelectedIndex = 0
            selectedThreadID = first.id
            listScrollTarget = first.id
            return
        }
        // Nothing is opened automatically: opening marks mail as read.
        guard let current = selectedThreadID else { return }
        if let index = newThreads.firstIndex(where: { $0.id == current }) {
            lastSelectedIndex = index
            return
        }
        guard !newThreads.isEmpty else {
            selectedThreadID = nil
            return
        }
        selectedThreadID = newThreads[min(lastSelectedIndex, newThreads.count - 1)].id
    }

    private func observeBadge() {
        guard let database else { return }
        let accountFolders = accounts.compactMap { folders[$0.id] }
        badgeObservation = ValueObservation
            .tracking { db in try MailQueries.unreadInboxThreads(db, accounts: accountFolders) }
            .removeDuplicates()
            .start(in: database.writer, scheduling: .immediate) { _ in } onChange: { [weak self] count in
                self?.unreadCount = count
                self?.updateBadges()
            }
    }

    private func observeOutbox() {
        guard let database else { return }
        outboxObservation = ValueObservation
            .tracking { db in try OutboxRecord.order(Column("sendAt")).fetchAll(db) }
            .start(in: database.writer, scheduling: .immediate) { _ in } onChange: { [weak self] records in
                self?.scheduled = records
            }
    }

    // MARK: - Mailbox and selection

    func setMailbox(_ newMailbox: Mailbox) {
        showingScheduled = false
        showingAttachments = false
        guard newMailbox != mailbox || activeSearch != nil else {
            // Going to the folder you are already in returns to its top, e.g. `g i` from a thread.
            if focus == .reader { closeThread() }
            checked = []
            select(index: 0)
            return
        }
        mailbox = newMailbox
        clearSearchState()
        resetListPosition()
        observeThreads()
    }

    func resetListPosition() {
        checked = []
        lastSelectedIndex = 0
        threadLimit = 300
        selectedThreadID = nil
        selectFirstWhenLoaded = true
        if focus == .reader { closeThread() }
    }

    var selectedIndex: Int? {
        guard let selectedThreadID else { return nil }
        return threads.firstIndex { $0.id == selectedThreadID }
    }

    func select(index: Int) {
        guard !threads.isEmpty else { return }
        let clamped = max(0, min(index, threads.count - 1))
        selectedThreadID = threads[clamped].id
        lastSelectedIndex = clamped
        listScrollTarget = threads[clamped].id
        if clamped >= threads.count - 20, threads.count >= threadLimit {
            threadLimit += 300
            observeThreads()
        }
    }

    func loadMoreIfNeeded(_ thread: ThreadSummary) {
        guard threads.count >= threadLimit, thread.id == threads.last?.id else { return }
        threadLimit += 300
        observeThreads()
    }

    var mailboxTitle: String {
        if let activeSearch { return "Search: \(activeSearch)" }
        if showingScheduled { return "Scheduled" }
        if showingAttachments { return "Attachments" }
        let title = displayName(for: mailbox.kind)
        let scope = mailbox.accountId.flatMap(account)?.name
        return scope.map { "\(title) · \($0)" } ?? title
    }

    // MARK: - Reading pane

    func openSelectedThread() {
        if selectedThreadID == nil { select(index: 0) }
        guard selectedThreadID != nil else { return }
        overlay = nil
        focus = .reader
        loadDetail()
    }

    func closeThread() {
        focus = .list
        detailObservation = nil
        detail = nil
        mainWindow?.makeFirstResponder(nil)
        if let selectedThreadID { listScrollTarget = selectedThreadID }
    }

    func loadDetail() {
        detailObservation = nil
        guard let database, let threadID = selectedThreadID, let accountFolders = folders[threadID.accountId] else {
            detail = nil
            return
        }
        if detail?.thread != threadID {
            detail = ThreadDetail(thread: threadID, loadImages: alwaysLoadImages)
        }
        let inTrashOrSpam = mailbox.kind.isTrashOrSpam
        detailObservation = ValueObservation
            .tracking { db in
                try MailQueries.threadMessages(db, thread: threadID, folders: accountFolders, inTrashOrSpam: inTrashOrSpam)
            }
            .removeDuplicates()
            .start(in: database.writer, scheduling: .immediate) { [weak self] error in
                self?.showError(error.localizedDescription)
            } onChange: { [weak self] messages in
                self?.detailMessagesChanged(messages, thread: threadID)
            }
    }

    private func detailMessagesChanged(_ messages: [MessageRecord], thread: ThreadID) {
        guard var current = detail, current.thread == thread else { return }
        let isFirstLoad = current.messages.isEmpty
        current.messages = messages
        if isFirstLoad {
            current.initiallyUnread = Set(messages.filter { !$0.seen }.compactMap(\.id))
            expandedMessages = current.initiallyUnread
        }
        detail = current
        loadBodies(for: messages)

        if messages.contains(where: { !$0.seen }), markedReadThread != thread {
            markedReadThread = thread
            Task {
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard selectedThreadID == thread, let current = detail?.messages else {
                    if markedReadThread == thread { markedReadThread = nil }
                    return
                }
                markThreadRead(thread, messages: current)
            }
        }
    }

    private func loadBodies(for messages: [MessageRecord]) {
        guard let database else { return }
        for message in messages {
            guard let id = message.id, detail?.parsed[id] == nil, !bodyLoads.contains(id) else { continue }
            bodyLoads.insert(id)
            let engine = engines[message.accountId]
            Task {
                defer { bodyLoads.remove(id) }
                do {
                    let cached = try await database.writer.read { db in try MailQueries.body(db, messageRowId: id) }
                    let raw: Data
                    if let cached {
                        raw = cached
                    } else if let engine {
                        raw = try await engine.body(for: message)
                    } else {
                        throw PoscarError.connection("Account is offline")
                    }
                    let (parsed, thumbnails) = await Task.detached(priority: .userInitiated) {
                        let parsed = MIMEParser.parse(raw)
                        return (parsed, AttachmentThumbnails.make(for: parsed.visibleAttachments))
                    }.value
                    detail?.thumbnails[id] = thumbnails
                    detail?.parsed[id] = parsed
                } catch {
                    detail?.errors[id] = error.localizedDescription
                }
            }
        }
    }

    /// Rendering embeds whole message bodies, so the result is reused until its inputs change.
    var renderedThread: ThreadRenderer.Output? {
        guard let detail, !detail.messages.isEmpty else { return nil }
        let key = renderKey(detail)
        if let renderCache, renderCache.key == key { return renderCache.output }
        let messages = detail.messages.map { record -> RenderableMessage in
            var shown = record
            if let id = record.id { shown.seen = !detail.initiallyUnread.contains(id) }
            return RenderableMessage(
                record: shown,
                parsed: record.id.flatMap { detail.parsed[$0] },
                loadError: record.id.flatMap { detail.errors[$0] },
                thumbnails: record.id.flatMap { detail.thumbnails[$0] } ?? [:]
            )
        }
        let output = ThreadRenderer.render(
            subject: detail.subject,
            messages: messages,
            expanded: expandedMessages,
            loadImages: detail.loadImages,
            accountEmail: account(detail.thread.accountId)?.email ?? ""
        )
        renderCache = (key, output)
        return output
    }

    private func renderKey(_ detail: ThreadDetail) -> String {
        let messages = detail.messages.map { message -> String in
            let id = message.id ?? 0
            let state = detail.parsed[id] != nil ? "p" : detail.errors[id] != nil ? "e" : "-"
            return "\(id)\(state)\(message.snippet.count)"
        }
        return "\(detail.thread.threadKey)|\(detail.loadImages)|\(expandedMessages.sorted())|" + messages.joined(separator: ",")
    }

    func toggleMessage(at index: Int) {
        guard let detail, detail.messages.indices.contains(index), let id = detail.messages[index].id else { return }
        if expandedMessages.contains(id) {
            expandedMessages.remove(id)
        } else {
            expandedMessages.insert(id)
        }
        reader.run(ThreadRenderer.toggleScript(index: index))
    }

    func focusMessage(offset: Int) {
        guard let detail, !detail.messages.isEmpty else { return }
        let current = detail.focusedIndex ?? 0
        let next = max(0, min(current + offset, detail.messages.count - 1))
        self.detail?.focusedIndex = next
        if let id = detail.messages[next].id { expandedMessages.insert(id) }
        focus = .reader
        reader.run(ThreadRenderer.focusScript(index: next))
    }

    // MARK: - Search

    /// Searches all accounts and folders; `in:` narrows it to one mailbox, as in Gmail.
    func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, let database else {
            clearSearch()
            return
        }
        let parsed = SearchQuery(query)
        showingScheduled = false
        showingAttachments = false
        searchSuggestions = []
        searchScope = parsed.folders.last.map(mailbox(forSearchFolder:)) ?? Mailbox(kind: .everywhere)
        activeSearch = query
        searchResultIDs = nil
        isSearching = true
        resetListPosition()
        observeThreads()

        let allEngines = Array(engines.values)
        Task {
            var ids = Set<Int64>()
            ids.formUnion((try? await database.writer.read { db in try MailQueries.search(db, query: parsed) }) ?? [])
            guard activeSearch == query else { return }
            searchResultIDs = Array(ids)
            observeThreads()

            for engine in allEngines {
                do {
                    ids.formUnion(try await engine.search(query))
                } catch {
                    showError("Search failed for \(engine.account.name): \(error.localizedDescription)")
                }
                guard activeSearch == query else { return }
                searchResultIDs = Array(ids)
                observeThreads()
            }
            isSearching = false
        }
    }

    /// `in:sent` → Sent of every account; `in:Posao` → that label or folder wherever it exists.
    func mailbox(forSearchFolder value: String) -> Mailbox {
        if let standard = SearchQuery.standardMailbox(named: value) {
            return Mailbox(kind: standard ?? .everywhere)
        }
        for accountFolders in folders.values {
            if let folder = accountFolders.userLabels.first(where: { $0.name.caseInsensitiveCompare(value) == .orderedSame }) {
                return Mailbox(kind: .label(accountFolders.isGmail ? folder.name : folder.path))
            }
        }
        return Mailbox(kind: .label(value))
    }

    func clearSearch() {
        guard activeSearch != nil || !searchText.isEmpty else { return }
        clearSearchState()
        resetListPosition()
        observeThreads()
    }

    private func clearSearchState() {
        searchScope = Mailbox(kind: .everywhere)
        searchText = ""
        activeSearch = nil
        searchResultIDs = nil
        isSearching = false
    }

    // MARK: - Messages to the user

    func showToast(_ text: String, undoable: Bool = false, isError: Bool = false) {
        toast = Toast(text: text, undoable: undoable, isError: isError)
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: isError ? 8_000_000_000 : 5_000_000_000)
            if !Task.isCancelled { toast = nil }
        }
    }

    func showError(_ message: String) {
        showToast(message, isError: true)
    }
}
