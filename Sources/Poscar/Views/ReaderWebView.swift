import AppKit
import PoscarCore
import SwiftUI
import WebKit

/// Lets the model drive the reading pane (scrolling, expanding messages) with scripts.
@MainActor
final class ReaderController {
    weak var webView: WKWebView?

    func run(_ script: String) {
        webView?.evaluateJavaScript(script, completionHandler: nil)
        resizeSoon()
    }

    func resizeSoon() {
        guard let webView else { return }
        for delay in [0.05, 0.3, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak webView] in
                webView?.evaluateJavaScript(ThreadRenderer.resizeScript, completionHandler: nil)
            }
        }
    }
}

struct ReaderWebView: NSViewRepresentable {
    let html: String
    let model: AppModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // WebKit does not render srcdoc iframes when content JavaScript is off, so it stays on.
        // Scripts are still blocked: the page CSP has no script-src and message frames are
        // sandboxed without allow-scripts. The app sizes frames via evaluateJavaScript.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isElementFullscreenEnabled = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        model.reader.webView = webView
        context.coordinator.startResizeTimer(webView)
        // Arrow keys and space scroll the open conversation.
        DispatchQueue.main.async { [weak webView] in
            if let webView { webView.window?.makeFirstResponder(webView) }
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        model.reader.webView = webView
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        webView.loadHTMLString(html, baseURL: nil)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.resizeTimer?.invalidate()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let model: AppModel
        var loadedHTML = ""
        var resizeTimer: Timer?

        init(model: AppModel) {
            self.model = model
        }

        /// Images and fonts keep loading after the page finishes, so frame heights are re-checked.
        func startResizeTimer(_ webView: WKWebView) {
            resizeTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak webView] _ in
                Task { @MainActor in
                    webView?.evaluateJavaScript(ThreadRenderer.resizeScript, completionHandler: nil)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.reader.resizeSoon()
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if url.scheme == ThreadRenderer.scheme {
                handleInternal(url)
                decisionHandler(.cancel)
                return
            }
            let isInitialLoad = url.absoluteString == "about:blank" || url.absoluteString == "about:srcdoc"
            if isInitialLoad && navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }
            if url.scheme == "data" && navigationAction.navigationType == .other {
                decisionHandler(.allow)
                return
            }
            openExternally(url)
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url { openExternally(url) }
            return nil
        }

        private func openExternally(_ url: URL) {
            switch url.scheme?.lowercased() {
            case ThreadRenderer.scheme:
                // Links inside message frames arrive here because frames open links in a new window.
                handleInternal(url)
            case "mailto":
                model.composeTo(url)
            case "http", "https":
                NSWorkspace.shared.open(url)
            default:
                break
            }
        }

        private func handleInternal(_ url: URL) {
            let parts = url.pathComponents.filter { $0 != "/" }
            switch url.host {
            case "toggle":
                if let index = parts.first.flatMap(Int.init) { model.toggleMessage(at: index) }
            case "attachment":
                if parts.count == 2, let rowID = Int64(parts[0]), let attachmentID = Int(parts[1]) {
                    model.openAttachment(messageRowId: rowID, attachmentId: attachmentID)
                }
            case "quotes":
                if let index = parts.first.flatMap(Int.init) { model.reader.run(ThreadRenderer.toggleQuotesScript(index: index)) }
            case "load-images":
                model.perform(.loadImages)
            default:
                break
            }
        }
    }
}
