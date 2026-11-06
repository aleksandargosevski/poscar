import Foundation
import UniformTypeIdentifiers

public struct OutgoingAttachment: Codable, Hashable, Sendable {
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(filename: String, mimeType: String? = nil, data: Data) {
        self.filename = filename
        self.data = data
        let ext = (filename as NSString).pathExtension
        self.mimeType = mimeType ?? UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }
}

public struct OutgoingMessage: Codable, Hashable, Sendable {
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    public var body: String
    public var attachments: [OutgoingAttachment]
    public var inReplyTo: String?
    public var references: [String]

    public init(
        from: EmailAddress,
        to: [EmailAddress],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        subject: String,
        body: String,
        attachments: [OutgoingAttachment] = [],
        inReplyTo: String? = nil,
        references: [String] = []
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
    }

    public var allRecipients: [EmailAddress] { to + cc + bcc }
}

public enum MessageBuilder {
    /// Builds an RFC 5322 message: plain text plus Markdown-rendered HTML, with attachments when present.
    public static func build(_ message: OutgoingMessage, messageID: String, date: Date = Date()) -> Data {
        var headers: [(String, String)] = [
            ("From", encodeAddress(message.from)),
            ("Date", MailDate.format(date)),
            ("Message-ID", "<\(messageID)>"),
            ("Subject", EncodedWords.encodeIfNeeded(message.subject)),
            ("MIME-Version", "1.0"),
        ]
        if !message.to.isEmpty { headers.append(("To", message.to.map(encodeAddress).joined(separator: ", "))) }
        if !message.cc.isEmpty { headers.append(("Cc", message.cc.map(encodeAddress).joined(separator: ", "))) }
        if let inReplyTo = message.inReplyTo { headers.append(("In-Reply-To", "<\(inReplyTo)>")) }
        if !message.references.isEmpty {
            headers.append(("References", message.references.map { "<\($0)>" }.joined(separator: " ")))
        }
        headers.append(("X-Mailer", "Poscar"))

        let alternative = alternativePart(for: message.body)
        let body: String
        if message.attachments.isEmpty {
            body = alternative
        } else {
            let boundary = makeBoundary()
            var mixed = "Content-Type: multipart/mixed; boundary=\"\(boundary)\"\r\n\r\n"
            mixed += "--\(boundary)\r\n\(alternative)\r\n"
            for attachment in message.attachments {
                mixed += "--\(boundary)\r\n\(attachmentPart(attachment))\r\n"
            }
            mixed += "--\(boundary)--\r\n"
            body = mixed
        }

        let headerBlock = headers.map { "\($0.0): \($0.1)" }.joined(separator: "\r\n")
        return Data((headerBlock + "\r\n" + body).utf8)
    }

    public static func makeMessageID(domain: String) -> String {
        "\(UUID().uuidString.lowercased())@\(domain)"
    }

    static func alternativePart(for markdown: String) -> String {
        let boundary = makeBoundary()
        let plain = quotedPrintable(normalizeNewlines(markdown))
        let html = quotedPrintable(normalizeNewlines(MarkdownRenderer.html(from: markdown)))
        return """
        Content-Type: multipart/alternative; boundary="\(boundary)"\r
        \r
        --\(boundary)\r
        Content-Type: text/plain; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        \(plain)\r
        --\(boundary)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Transfer-Encoding: quoted-printable\r
        \r
        \(html)\r
        --\(boundary)--\r

        """
    }

    static func attachmentPart(_ attachment: OutgoingAttachment) -> String {
        let fallbackName = attachment.filename.unicodeScalars
            .map { $0.isASCII && $0 != "\"" && $0.value >= 32 ? String($0) : "_" }
            .joined()
        let encodedName = attachment.filename.addingPercentEncoding(withAllowedCharacters: .rfc2231Allowed) ?? fallbackName
        let base64 = attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return """
        Content-Type: \(attachment.mimeType); name="\(fallbackName)"\r
        Content-Disposition: attachment; filename="\(fallbackName)"; filename*=UTF-8''\(encodedName)\r
        Content-Transfer-Encoding: base64\r
        \r
        \(base64)
        """
    }

    static func encodeAddress(_ address: EmailAddress) -> String {
        guard !address.name.isEmpty else { return address.email }
        let isPlainASCII = address.name.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 32 }
        if isPlainASCII {
            let escaped = address.name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(address.email)>"
        }
        return "\(EncodedWords.encodeIfNeeded(address.name)) <\(address.email)>"
    }

    static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Quoted-printable with CRLF line endings and soft breaks at 76 characters.
    static func quotedPrintable(_ text: String) -> String {
        var output: [String] = []
        for line in text.components(separatedBy: "\n") {
            var encoded = ""
            let bytes = Array(line.utf8)
            for (index, byte) in bytes.enumerated() {
                let isLast = index == bytes.count - 1
                let needsEncoding = byte == UInt8(ascii: "=") || byte > 126 || (byte < 32 && byte != 9)
                    || (isLast && (byte == 32 || byte == 9))
                encoded += needsEncoding ? String(format: "=%02X", byte) : String(UnicodeScalar(byte))
            }
            output.append(contentsOf: softWrap(encoded))
        }
        return output.joined(separator: "\r\n")
    }

    static func softWrap(_ encoded: String) -> [String] {
        var lines: [String] = []
        var remaining = Substring(encoded)
        while remaining.count > 75 {
            var cut = remaining.index(remaining.startIndex, offsetBy: 75)
            // Never split an =XX escape.
            if let equals = remaining[remaining.index(cut, offsetBy: -2)..<cut].firstIndex(of: "=") {
                cut = equals
            }
            lines.append(remaining[..<cut] + "=")
            remaining = remaining[cut...]
        }
        lines.append(String(remaining))
        return lines
    }

    static func makeBoundary() -> String {
        "poscar-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
    }
}

extension CharacterSet {
    static let rfc2231Allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&+-.^_`|~")
}
