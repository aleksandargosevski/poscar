import AppKit
import PoscarCore

/// The menu bar item: unread count plus quick actions.
@MainActor
final class MenuBarController: NSObject {
    private var item: NSStatusItem?
    private weak var model: AppModel?
    private var unreadCount = 0

    func install(model: AppModel) {
        self.model = model
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.menu = makeMenu()
            self.item = item
            update(unread: unreadCount)
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    func update(unread: Int) {
        unreadCount = unread
        guard let button = item?.button else { return }
        button.title = ""
        button.imagePosition = .imageOnly
        button.image = Self.statusImage(unread: unread)
        button.setAccessibilityLabel(unread > 0 ? "Pošćar, \(unread) unread" : "Pošćar")
    }

    /// Symbol and count drawn into one template image, so both share one vertical centre.
    private static func statusImage(unread: Int) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let symbol = NSImage(systemSymbolName: unread > 0 ? "envelope.badge" : "envelope", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        guard unread > 0 else {
            symbol.isTemplate = true
            return symbol
        }

        let text = NSAttributedString(string: "\(unread)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.black,
        ])
        let textSize = text.size()
        let height: CGFloat = 18
        let spacing: CGFloat = 4
        let size = NSSize(width: ceil(symbol.size.width + spacing + textSize.width), height: height)
        let image = NSImage(size: size, flipped: false) { _ in
            symbol.draw(in: NSRect(
                x: 0, y: (height - symbol.size.height) / 2,
                width: symbol.size.width, height: symbol.size.height
            ))
            text.draw(at: NSPoint(x: symbol.size.width + spacing, y: (height - textSize.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(menuItem("Open Pošćar", #selector(openApp), key: ""))
        menu.addItem(menuItem("New Message", #selector(compose), key: ""))
        menu.addItem(menuItem("Check for Mail", #selector(checkMail), key: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", #selector(openSettings), key: ","))
        menu.addItem(menuItem("Quit Pošćar", #selector(quit), key: "q"))
        return menu
    }

    private func menuItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openApp() { model?.showMainWindow() }

    @objc private func compose() {
        model?.showMainWindow()
        model?.perform(.compose)
    }

    @objc private func checkMail() { model?.refresh() }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
