import AppKit
import PoscarCore
import SwiftUI
import WebKit

/// Shows the whole message exactly as it will be sent.
struct MessagePreview: View {
    let content: MessageBody

    var body: some View {
        HTMLView(html: content.html)
    }
}

/// An HTML fragment on white, as recipients see it, as tall as its content up to `maxHeight`.
struct HTMLSnippet: View {
    let html: String
    var maxHeight: CGFloat = 200
    @State private var contentHeight: CGFloat = 20

    var body: some View {
        HTMLView(html: MarkdownRenderer.document(html), padding: "8px 12px") { contentHeight = $0 }
            .frame(height: min(max(contentHeight, 20), maxHeight))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

struct HTMLView: NSViewRepresentable {
    let html: String
    var padding = "14px 18px"
    var onContentHeight: ((CGFloat) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        // Turns off scripts in the page only; measuring the height below still works.
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onContentHeight = onContentHeight
        // Recipients see a white message, so the preview uses the same frame as the reader.
        let page = html.replacingOccurrences(of: "<body>", with: "<body style=\"margin:0;padding:\(padding);background:#fff;color:#222\">")
        guard context.coordinator.loadedHTML != page else { return }
        context.coordinator.loadedHTML = page
        webView.loadHTMLString(page, baseURL: nil)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedHTML = ""
        var onContentHeight: ((CGFloat) -> Void)?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let onContentHeight else { return }
            // The body's own box, not scrollHeight, which never drops below the view's height.
            webView.evaluateJavaScript("Math.ceil(document.body.getBoundingClientRect().height)") { value, error in
                if let error {
                    AppLog.write("Could not measure HTML height: \(error.localizedDescription)")
                }
                guard let height = value as? Double else { return }
                Task { @MainActor in onContentHeight(CGFloat(height)) }
            }
        }
    }
}
