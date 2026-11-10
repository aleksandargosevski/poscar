import AppKit
import SwiftUI

@main
struct PoscarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Pošćar", id: "main") {
            RootView()
                .environment(delegate.model)
                .frame(minWidth: 900, minHeight: 520)
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Message") { delegate.model.perform(.compose) }
            }
            CommandGroup(replacing: .undoRedo) {}
        }

        Settings {
            SettingsView()
                .environment(delegate.model)
        }
    }
}

/// Shows setup until the model is ready; startup errors (e.g. a broken database) are shown instead of crashing.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let error = model.fatalError {
            ContentUnavailableView("Pošćar could not start", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if model.accounts.isEmpty {
            WelcomeView()
        } else {
            MainView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        AppLog.write("launched \(version) from \(Bundle.main.bundlePath)")
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [model] note in
            MainActor.assumeIsolated {
                if let window = note.object as? NSWindow, window === model.mainWindow { AppLog.write("main window closed") }
            }
        }
        model.start()
        // SwiftUI sometimes restores the main window as closed; a mail app should always open with it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [model] in
            model.showMainWindow()
        }
    }

    /// A mail app keeps running without its window, for new mail and notifications, as Mail does.
    /// SwiftUI would otherwise quit when the only `Window` scene is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppLog.write("quitting (\(Self.quitReason()))")
        Task {
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLog.write("terminated")
        AppLog.flush()
    }

    /// Who asked to quit: a quit Apple Event names its sender (logout, an updater, a script),
    /// otherwise it came from the app itself (⌘Q, the menu).
    private static func quitReason() -> String {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return "menu or ⌘Q" }
        let pid = event.attributeDescriptor(forKeyword: keySenderPIDAttr)?.int32Value ?? 0
        let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.typeCodeValue
        let sender = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "pid \(pid)"
        let kind: String
        switch reason {
        case kAELogOut, kAEReallyLogOut: kind = "logout"
        case kAEShutDown: kind = "shutdown"
        case kAERestart: kind = "restart"
        default: kind = "quit request"
        }
        return "\(kind) from \(sender)"
    }

    /// mailto: links clicked in other apps when Poscar is the default mail app.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "mailto" {
            model.composeTo(url)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { model.showMainWindow() }
        return true
    }
}
