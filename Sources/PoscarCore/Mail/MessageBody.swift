import Foundation

/// What the user wrote, their signature and the quoted message, put together in the order they are sent.
public struct MessageBody: Hashable, Sendable {
    public var markdown: String
    public var signature: Signature?
    public var quotedText: String?

    public init(markdown: String, signature: Signature? = nil, quotedText: String? = nil) {
        self.markdown = markdown
        self.signature = signature
        self.quotedText = quotedText
    }

    public var plainText: String {
        var parts = [markdown.trimmingTrailingWhitespace]
        if let signature, !signature.isEmpty { parts.append("-- \n" + signature.plainText) }
        if let quotedText { parts.append(quotedText) }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    public var html: String {
        var fragment = MarkdownRenderer.fragment(from: markdown)
        if let signature, !signature.isEmpty {
            fragment += "<div class=\"poscar-signature\" style=\"margin-top:1.2em\">\(signature.html)</div>"
        }
        if let quotedText {
            fragment += "<div class=\"poscar-quote\" style=\"margin-top:1.2em\">\(MarkdownRenderer.fragment(from: quotedText))</div>"
        }
        return MarkdownRenderer.document(fragment)
    }
}

/// The block under what the user writes, written in Markdown or HTML.
public struct Signature: Codable, Hashable, Sendable {
    public enum Format: String, Codable, CaseIterable, Sendable {
        case markdown
        case html
    }

    public var source: String
    public var format: Format

    public init(source: String, format: Format) {
        self.source = source
        self.format = format
    }

    public var isEmpty: Bool { trimmed.isEmpty }

    /// An HTML fragment for the HTML part of a message.
    public var html: String {
        switch format {
        case .markdown: MarkdownRenderer.fragment(from: trimmed)
        case .html: trimmed
        }
    }

    /// What mail apps that only show plain text display.
    public var plainText: String {
        switch format {
        case .markdown: trimmed
        case .html: HTMLText.toPlainText(trimmed)
        }
    }

    private var trimmed: String { source.trimmingCharacters(in: .whitespacesAndNewlines) }
}

private extension String {
    var trimmingTrailingWhitespace: String {
        guard let last = lastIndex(where: { !$0.isWhitespace }) else { return "" }
        return String(self[...last])
    }
}
