import Foundation

public struct MIMEHeaders: Sendable {
    public struct Field: Sendable {
        public var name: String
        public var value: String
    }

    public private(set) var fields: [Field] = []

    public init(fields: [Field] = []) {
        self.fields = fields
    }

    public init(data: Data) {
        self.init(text: Charset.decodeHeaderBytes(data))
    }

    public init(text: String) {
        var current: Field?
        for line in text.components(separatedBy: "\n") {
            let line = line.hasSuffix("\r") ? String(line.dropLast()) : line
            if line.isEmpty { break }
            if line.first == " " || line.first == "\t" {
                current?.value += " " + line.trimmingCharacters(in: .whitespaces)
                continue
            }
            if let field = current { fields.append(field) }
            guard let colon = line.firstIndex(of: ":") else {
                current = nil
                continue
            }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            current = Field(name: name, value: value)
        }
        if let field = current { fields.append(field) }
    }

    public subscript(name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    public func all(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    public func decoded(_ name: String) -> String? {
        self[name].map(EncodedWords.decode)
    }

    public func addresses(_ name: String) -> [EmailAddress] {
        all(name).flatMap { AddressParser.parse(EncodedWords.decode($0)) }
    }

    /// Message-IDs listed in a header such as References, without angle brackets.
    public func messageIDs(_ name: String) -> [String] {
        guard let value = self[name] else { return [] }
        let pattern = try! NSRegularExpression(pattern: "<([^<>\\s]+)>")
        let range = NSRange(value.startIndex..., in: value)
        let ids = pattern.matches(in: value, range: range).compactMap { match in
            Range(match.range(at: 1), in: value).map { String(value[$0]) }
        }
        if ids.isEmpty {
            let bare = value.trimmingCharacters(in: .whitespaces)
            return bare.isEmpty || bare.contains(" ") ? [] : [bare]
        }
        return ids
    }

    public var contentType: HeaderValue {
        HeaderValue(self["Content-Type"] ?? "text/plain; charset=us-ascii")
    }

    public var contentDisposition: HeaderValue? {
        self["Content-Disposition"].map(HeaderValue.init)
    }
}

/// A structured header value such as `text/plain; charset="utf-8"`, including RFC 2231 parameters.
public struct HeaderValue: Sendable {
    public var value: String
    public var parameters: [String: String]

    public init(_ raw: String) {
        let segments = HeaderValue.splitParameters(raw)
        value = (segments.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()

        var simple: [String: String] = [:]
        var continuations: [String: [(index: Int, value: String, encoded: Bool)]] = [:]

        for segment in segments.dropFirst() {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            var key = segment[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var paramValue = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if paramValue.hasPrefix("\""), paramValue.hasSuffix("\""), paramValue.count >= 2 {
                paramValue = String(paramValue.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }

            let encoded = key.hasSuffix("*")
            if encoded { key.removeLast() }
            let pieces = key.split(separator: "*", maxSplits: 1)
            if pieces.count == 2, let index = Int(pieces[1]) {
                continuations[String(pieces[0]), default: []].append((index, paramValue, encoded))
            } else if encoded {
                simple[key] = HeaderValue.decodeExtended(paramValue, charset: nil).value
            } else {
                simple[key] = paramValue
            }
        }

        for (key, parts) in continuations {
            let sorted = parts.sorted { $0.index < $1.index }
            var charset: String?
            var result = ""
            for part in sorted {
                if part.encoded {
                    let decoded = HeaderValue.decodeExtended(part.value, charset: charset)
                    charset = decoded.charset
                    result += decoded.value
                } else {
                    result += part.value
                }
            }
            simple[key] = result
        }

        parameters = simple.mapValues { EncodedWords.decode($0) }
    }

    /// Decodes `utf-8'en'%E2%82%AC` (the first segment of an RFC 2231 value) or a later percent-encoded segment.
    static func decodeExtended(_ raw: String, charset: String?) -> (value: String, charset: String?) {
        var charset = charset
        var encoded = raw
        let quoteParts = raw.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
        if charset == nil, quoteParts.count == 3 {
            charset = String(quoteParts[0])
            encoded = String(quoteParts[2])
        }
        var bytes = Data()
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let character = encoded[index]
            if character == "%",
               let end = encoded.index(index, offsetBy: 3, limitedBy: encoded.endIndex),
               let byte = UInt8(encoded[encoded.index(after: index)..<end], radix: 16) {
                bytes.append(byte)
                index = end
            } else {
                bytes.append(contentsOf: Array(String(character).utf8))
                index = encoded.index(after: index)
            }
        }
        return (Charset.decode(bytes, charset: charset), charset)
    }

    static func splitParameters(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        for character in raw {
            if character == "\"" { inQuotes.toggle() }
            if character == ";", !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }
}

/// RFC 2047 encoded words: `=?utf-8?B?...?=` and `=?iso-8859-2?Q?...?=`.
public enum EncodedWords {
    private static let pattern = try! NSRegularExpression(pattern: "=\\?([^?\\s]+)\\?([BbQq])\\?([^?\\s]*)\\?=")
    private static let gapBetweenWords = try! NSRegularExpression(pattern: "(\\?=)\\s+(=\\?)")

    public static func decode(_ input: String) -> String {
        guard input.contains("=?") else { return input }
        let joined = gapBetweenWords.stringByReplacingMatches(
            in: input, range: NSRange(input.startIndex..., in: input), withTemplate: "$1$2"
        )

        var result = ""
        var cursor = joined.startIndex
        // Adjacent words may split one multibyte character, so bytes of the same charset are decoded together.
        var pendingBytes = Data()
        var pendingCharset: String?

        func flushPending() {
            if !pendingBytes.isEmpty {
                result += Charset.decode(pendingBytes, charset: pendingCharset)
                pendingBytes = Data()
            }
            pendingCharset = nil
        }

        for match in pattern.matches(in: joined, range: NSRange(joined.startIndex..., in: joined)) {
            guard let range = Range(match.range, in: joined),
                  let charsetRange = Range(match.range(at: 1), in: joined),
                  let encodingRange = Range(match.range(at: 2), in: joined),
                  let textRange = Range(match.range(at: 3), in: joined) else { continue }

            if cursor < range.lowerBound {
                flushPending()
                result += joined[cursor..<range.lowerBound]
            }
            let charset = String(joined[charsetRange]).split(separator: "*").first.map(String.init)
            let text = String(joined[textRange])
            let bytes = joined[encodingRange].uppercased() == "B"
                ? (Data(base64Encoded: padBase64(text)) ?? Data())
                : decodeQ(text)
            if pendingCharset != nil, pendingCharset?.lowercased() != charset?.lowercased() {
                flushPending()
            }
            pendingCharset = charset
            pendingBytes.append(bytes)
            cursor = range.upperBound
        }
        flushPending()
        if cursor < joined.endIndex { result += joined[cursor...] }
        return result
    }

    /// Encodes a header value only when it contains non-ASCII characters.
    public static func encodeIfNeeded(_ value: String) -> String {
        guard value.unicodeScalars.contains(where: { $0.value > 126 || $0.value < 32 }) else { return value }
        // Keep each encoded word under the 75 character limit without splitting characters.
        var words: [String] = []
        var chunk = ""
        for character in value {
            let candidate = chunk + String(character)
            if Data(candidate.utf8).base64EncodedString().count > 45 {
                words.append(chunk)
                chunk = String(character)
            } else {
                chunk = candidate
            }
        }
        if !chunk.isEmpty { words.append(chunk) }
        return words.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: " ")
    }

    static func decodeQ(_ text: String) -> Data {
        var bytes = Data()
        var iterator = Array(text.utf8).makeIterator()
        while let byte = iterator.next() {
            switch byte {
            case UInt8(ascii: "_"):
                bytes.append(UInt8(ascii: " "))
            case UInt8(ascii: "="):
                if let high = iterator.next(), let low = iterator.next(),
                   let value = UInt8(String(bytes: [high, low], encoding: .ascii) ?? "", radix: 16) {
                    bytes.append(value)
                }
            default:
                bytes.append(byte)
            }
        }
        return bytes
    }

    static func padBase64(_ text: String) -> String {
        let remainder = text.count % 4
        return remainder == 0 ? text : text + String(repeating: "=", count: 4 - remainder)
    }
}

public enum MailDate {
    private static let rfc5322Formats = [
        "d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm Z", "d MMM yy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss z", "d MMM yyyy HH:mm z", "d MMM yyyy HH:mm:ss",
    ]

    private static let formatters: [DateFormatter] = rfc5322Formats.map(makeFormatter)
    private static let internalFormatter = makeFormatter("dd-MMM-yyyy HH:mm:ss Z")

    public static func parse(_ value: String) -> Date? {
        var text = value.replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        if let comma = text.firstIndex(of: ",") {
            text = String(text[text.index(after: comma)...])
        }
        text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        for formatter in formatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// Parses an IMAP INTERNALDATE such as ` 7-Jul-1996 02:44:25 -0700`.
    public static func parseInternal(_ value: String) -> Date? {
        internalFormatter.date(from: value.trimmingCharacters(in: .whitespaces))
    }

    public static func format(_ date: Date) -> String {
        let formatter = makeFormatter("EEE, d MMM yyyy HH:mm:ss Z")
        return formatter.string(from: date)
    }

    private static func makeFormatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }
}
