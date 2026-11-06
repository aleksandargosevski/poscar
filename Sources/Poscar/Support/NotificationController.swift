import AppKit
import OSLog
import PoscarCore
import UserNotifications

/// Posts "new mail" notifications and opens the conversation when one is clicked.
@MainActor
final class NotificationController: NSObject, UNUserNotificationCenterDelegate {
    private let log = Logger(subsystem: "io.github.aleksandargosevski.poscar", category: "notifications")
    private weak var model: AppModel?
    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter crashes when the binary runs outside an app bundle (swift run).
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func install(model: AppModel) {
        self.model = model
        guard let center else { return }
        center.delegate = self
        // Permission is changed in System Settings; re-read it whenever the user comes back.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] granted, error in
            Task { @MainActor in
                if let error { self?.log.error("Authorization failed: \(error.localizedDescription, privacy: .public)") }
                self?.log.info("Notifications allowed: \(granted)")
                self?.refreshStatus()
            }
        }
    }

    /// Reads the current permission into the model so Settings can show it.
    func refreshStatus() {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            let allowed = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            Task { @MainActor in self?.model?.notificationsAllowed = allowed }
        }
    }

    func post(_ messages: [MessageRecord], account: Account) {
        guard let center else { return }
        log.info("Posting \(messages.count) new mail notification(s) for \(account.email, privacy: .private)")
        for message in messages.suffix(5) {
            let content = UNMutableNotificationContent()
            content.title = message.from.displayName
            content.subtitle = message.subject
            content.body = message.snippet.isEmpty ? account.email : message.snippet
            content.sound = .default
            content.threadIdentifier = message.threadKey
            content.userInfo = ["accountId": message.accountId, "threadKey": message.threadKey]
            let request = UNNotificationRequest(identifier: "\(message.accountId)-\(message.folder)-\(message.uid)", content: content, trigger: nil)
            center.add(request) { [weak self] error in
                guard let error else { return }
                Task { @MainActor in self?.log.error("Notification failed: \(error.localizedDescription, privacy: .public)") }
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let accountID = info["accountId"] as? String
        let threadKey = info["threadKey"] as? String
        Task { @MainActor in
            defer { completionHandler() }
            guard let model, let accountID, let threadKey else { return }
            model.showMainWindow()
            model.setMailbox(.unifiedInbox)
            model.selectFirstWhenLoaded = false
            model.selectedThreadID = ThreadID(accountId: accountID, threadKey: threadKey)
            model.openSelectedThread()
        }
    }

    /// Banners show even while Poscar is in front, so new mail is never silent.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}
