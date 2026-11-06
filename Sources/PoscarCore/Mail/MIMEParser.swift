import Foundation

public struct MailAttachment: Identifiable, Sendable {
    public var id: Int
    public var filename: String
    public var mimeType: String
    public var data: Data
    public var contentID: String?
    public var isInline: Bool

    public var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
    }
}

public struct ParsedMessage: Sendable {
    public var headers: MIMEHeaders
    public var html: String?
    public var text: String?
    public var attachments: [MailAttachment]

    /// Attachments the user should see; inline images referenced from the HTML are hidden.
    public var visibleAttachments: [MailAttachment] {
        attachments.filter { attachment in
            guard attachment.isInline, let contentID = attachment.contentID, let html else { return true }
            return !html.contains("cid:\(contentID)")
        }
    }

    public var plainText: String {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return html.map(HTMLText.toPlainText) ?? ""
    }

    public var snippet: String {
        Self.snippet(from: plainText)
    }

    public static func snippet(from text: String, length: Int = 200) -> String {
        var collected = ""
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix(">") { continue }
            collected += (collected.isEmpty ? "" : " ") + trimmed
            if collected.count >= length { break }
        }
        let collapsed = collected.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(collapsed.prefix(length))
    }
}

public enum MIMEParser {
    public static func parse(_ raw: Data) -> ParsedMessage {
        let root = parsePart(raw)
        var collector = Collector()
        collector.walk(root)
        return ParsedMessage(
            headers: root.headers,
            html: collector.html.isEmpty ? nil : collector.html.joined(separator: "<hr>"),
            text: collector.text.isEmpty ? nil : collector.text.joined(separator: "\n\n"),
            attachments: collector.attachments.enumerated().map { index, attachment in
                var numbered = attachment
                numbered.id = index
                return numbered
            }
        )
    }

    struct Part {
        var headers: MIMEHeaders
        var contentType: HeaderValue
        var body: Data
        var children: [Part]
    }

    static func parsePart(_ data: Data) -> Part {
        let (headerData, bodyData) = splitHeaderAndBody(data)
        let headers = MIMEHeaders(data: headerData)
        let contentType = headers.contentType

        if contentType.value.hasPrefix("multipart/"), let boundary = contentType.parameters["boundary"], !boundary.isEmpty {
            let children = splitMultipart(bodyData, boundary: boundary).map(parsePart)
            return Part(headers: headers, contentType: contentType, body: Data(), children: children)
        }
        let encoding = headers["Content-Transfer-Encoding"]?.lowercased().trimmingCharacters(in: .whitespaces)
        return Part(headers: headers, contentType: contentType, body: decodeTransfer(bodyData, encoding: encoding), children: [])
    }

    static func splitHeaderAndBody(_ data: Data) -> (Data, Data) {
        let candidates = [Data("\r\n\r\n".utf8), Data("\n\n".utf8)]
        let separator = candidates
            .compactMap { data.range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
        guard let separator else {
            // A part may start directly with its body when it has no headers.
            if data.first == UInt8(ascii: "\r") || data.first == UInt8(ascii: "\n") {
                return (Data(), data.drop { $0 == 13 || $0 == 10 })
            }
            return (data, Data())
        }
        return (data[data.startIndex..<separator.lowerBound], data[separator.upperBound...])
    }

    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let delimiter = Data("--\(boundary)".utf8)
        var positions: [Range<Data.Index>] = []
        var searchStart = body.startIndex
        while let range = body.range(of: delimiter, in: searchStart..<body.endIndex) {
            let atLineStart = range.lowerBound == body.startIndex || body[body.index(before: range.lowerBound)] == 10
            if atLineStart { positions.append(range) }
            searchStart = range.upperBound
        }

        var parts: [Data] = []
        for (index, range) in positions.enumerated() {
            let afterDelimiter = body[range.upperBound...]
            if afterDelimiter.starts(with: Data("--".utf8)) { break }
            guard let lineEnd = afterDelimiter.firstIndex(of: 10) else { break }
            let start = body.index(after: lineEnd)
            var end = index + 1 < positions.count ? positions[index + 1].lowerBound : body.endIndex
            // The line break before the next delimiter belongs to the delimiter.
            if end > start, body[body.index(before: end)] == 10 { end = body.index(before: end) }
            if end > start, body[body.index(before: end)] == 13 { end = body.index(before: end) }
            if start <= end { parts.append(body[start..<end]) }
        }
        return parts
    }

    static func decodeTransfer(_ data: Data, encoding: String?) -> Data {
        switch encoding {
        case "base64":
            return Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? data
        case "quoted-printable":
            return decodeQuotedPrintable(data)
        default:
            return data
        }
    }

    static func decodeQuotedPrintable(_ data: Data) -> Data {
        var output = Data(capacity: data.count)
        let bytes = [UInt8](data)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte == UInt8(ascii: "=") else {
                output.append(byte)
                index += 1
                continue
            }
            if index + 1 < bytes.count, bytes[index + 1] == 10 {
                index += 2
            } else if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 {
                index += 3
            } else if index + 2 < bytes.count, let value = hexValue(bytes[index + 1], bytes[index + 2]) {
                output.append(value)
                index += 3
            } else {
                output.append(byte)
                index += 1
            }
        }
        return output
    }

    private static func hexValue(_ high: UInt8, _ low: UInt8) -> UInt8? {
        guard let h = hexDigit(high), let l = hexDigit(low) else { return nil }
        return h << 4 | l
    }

    private static func hexDigit(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }

    struct Collector {
        var html: [String] = []
        var text: [String] = []
        var attachments: [MailAttachment] = []

        mutating func walk(_ part: Part) {
            let type = part.contentType.value
            if type == "multipart/alternative" {
                walkAlternative(part)
                return
            }
            if type.hasPrefix("multipart/") {
                part.children.forEach { walk($0) }
                return
            }

            let disposition = part.headers.contentDisposition
            let isAttachment = disposition?.value == "attachment"
            let charset = part.contentType.parameters["charset"]

            if type == "text/html", !isAttachment {
                html.append(Charset.decode(part.body, charset: charset))
            } else if type == "text/plain" || (type.isEmpty && !isAttachment), !isAttachment {
                text.append(Charset.decode(part.body, charset: charset))
            } else {
                addAttachment(part, disposition: disposition)
            }
        }

        /// Uses the richest alternative for HTML and the plain text alternative for text.
        mutating func walkAlternative(_ part: Part) {
            var best: Collector?
            var plain: Collector?
            for child in part.children {
                var collector = Collector()
                collector.walk(child)
                if !collector.html.isEmpty { best = collector }
                if !collector.text.isEmpty, collector.html.isEmpty { plain = collector }
            }
            if let best {
                html += best.html
                attachments += best.attachments
            }
            if let plain {
                text += plain.text
                if best == nil { attachments += plain.attachments }
            } else if let best {
                text += best.text
            }
        }

        mutating func addAttachment(_ part: Part, disposition: HeaderValue?) {
            let filename = disposition?.parameters["filename"]
                ?? part.contentType.parameters["name"]
                ?? defaultFilename(for: part.contentType.value)
            let contentID = part.headers["Content-ID"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
            attachments.append(MailAttachment(
                id: attachments.count,
                filename: filename,
                mimeType: part.contentType.value,
                data: part.body,
                contentID: contentID,
                isInline: disposition?.value != "attachment" && contentID != nil
            ))
        }

        private func defaultFilename(for type: String) -> String {
            switch type {
            case "message/rfc822": "message.eml"
            case "text/calendar": "invite.ics"
            default: "attachment"
            }
        }
    }
}
