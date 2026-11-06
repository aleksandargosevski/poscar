import Foundation
import Markdown

/// Turns what the user typed in the composer into the HTML alternative of an outgoing message.
public enum MarkdownRenderer {
    public static func html(from markdown: String) -> String {
        var rewriter = HardLineBreaks()
        let document = Document(parsing: markdown)
        let rewritten = rewriter.visit(document) ?? document
        let body = HTMLFormatter.format(rewritten)
            .replacingOccurrences(
                of: "<blockquote>",
                with: "<blockquote style=\"margin:0 0 0 .8ex;border-left:2px solid #ccc;padding-left:1ex;color:#555\">"
            )
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"></head>\
        <body><div style="font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:14px;line-height:1.45">\(body)</div></body></html>
        """
    }

    /// In email, a single newline is a line break, not a space as in plain Markdown.
    struct HardLineBreaks: MarkupRewriter {
        func visitSoftBreak(_ softBreak: SoftBreak) -> Markup? {
            LineBreak()
        }
    }
}

public enum HTMLText {
    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    public static func toPlainText(_ html: String) -> String {
        var text = html
        for tag in ["style", "script", "head", "title"] {
            text = text.replacingOccurrences(
                of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive]
            )
        }
        text = text.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[\\r\\n]+", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: "<(br|/p|/div|/tr|/h[1-6]|/li|/blockquote|/table)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<li[^>]*>", with: "\n• ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = decodeEntities(text)
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let namedEntities: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'",
        "copy": "©", "reg": "®", "hellip": "…", "mdash": "—", "ndash": "–", "rsquo": "’", "lsquo": "‘",
        "rdquo": "”", "ldquo": "“", "zwnj": "", "zwj": "", "shy": "", "euro": "€", "bull": "•",
    ]

    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let pattern = try! NSRegularExpression(pattern: "&(#x[0-9a-fA-F]+|#[0-9]+|[a-zA-Z]+);")
        var result = ""
        var cursor = text.startIndex
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text), let nameRange = Range(match.range(at: 1), in: text) else { continue }
            result += text[cursor..<range.lowerBound]
            let name = String(text[nameRange])
            if name.hasPrefix("#x"), let value = UInt32(name.dropFirst(2), radix: 16), let scalar = Unicode.Scalar(value) {
                result.unicodeScalars.append(scalar)
            } else if name.hasPrefix("#"), let value = UInt32(name.dropFirst()), let scalar = Unicode.Scalar(value) {
                result.unicodeScalars.append(scalar)
            } else if let replacement = namedEntities[name.lowercased()] {
                result += replacement
            } else {
                result += text[range]
            }
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }
}
