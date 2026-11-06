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
        model.start()
        // SwiftUI sometimes restores the main window as closed; a mail app should always open with it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [model] in
            model.showMainWindow()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
