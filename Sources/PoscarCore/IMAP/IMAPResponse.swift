import Foundation

public indirect enum IMAPValue: Equatable, Sendable {
    case atom(String)
    case string(Data)
    case list([IMAPValue])
    case nil_

    public var text: String? {
        switch self {
        case .atom(let value): value
        case .string(let data): Charset.decodeHeaderBytes(data)
        default: nil
        }
    }

    public var data: Data? {
        switch self {
        case .string(let data): data
        case .atom(let value): Data(value.utf8)
        default: nil
        }
    }

    public var list: [IMAPValue]? {
        if case .list(let values) = self { return values }
        return nil
    }

    public var number: UInt64? {
        text.flatMap { UInt64($0) }
    }
}

public enum IMAPStatus: String, Sendable {
    case ok = "OK", no = "NO", bad = "BAD", bye = "BYE", preauth = "PREAUTH"
}

public struct ResponseCode: Sendable, Equatable {
    public var name: String
    public var arguments: [IMAPValue]
}

public enum UntaggedResponse: Sendable {
    case status(IMAPStatus, ResponseCode?, String)
    case capability([String])
    case exists(UInt32)
    case expunge(UInt32)
    case fetch(sequence: UInt32, attributes: [String: IMAPValue])
    case list(attributes: [String], delimiter: String?, name: String)
    case search([UInt32])
    case other(String)
}

public enum IMAPResponse: Sendable {
    case tagged(tag: String, status: IMAPStatus, code: ResponseCode?, text: String)
    case untagged(UntaggedResponse)
    case continuation(String)
}

public enum IMAPResponseParser {
    /// Parses one complete response whose literals are inlined as `{n}\r\n<n bytes>`.
    public static func parse(_ bytes: [UInt8]) throws -> IMAPResponse {
        var tokenizer = IMAPTokenizer(bytes: bytes)
        let first = tokenizer.readAtom()

        if first == "+" {
            return .continuation(tokenizer.rest())
        }
        if first == "*" {
            return .untagged(try parseUntagged(&tokenizer))
        }
        let statusWord = tokenizer.readAtom().uppercased()
        guard let status = IMAPStatus(rawValue: statusWord) else {
            throw PoscarError.protocolViolation(String(decoding: bytes.prefix(200), as: UTF8.self))
        }
        let (code, text) = parseResponseText(&tokenizer)
        return .tagged(tag: first, status: status, code: code, text: text)
    }

    static func parseUntagged(_ tokenizer: inout IMAPTokenizer) throws -> UntaggedResponse {
        let word = tokenizer.readAtom()
        let upper = word.uppercased()

        if let status = IMAPStatus(rawValue: upper) {
            let (code, text) = parseResponseText(&tokenizer)
            return .status(status, code, text)
        }
        switch upper {
        case "CAPABILITY":
            return .capability(tokenizer.rest().split(separator: " ").map { $0.uppercased() })
        case "LIST", "LSUB":
            let values = try tokenizer.parseAll()
            guard values.count >= 3 else { return .other(word) }
            let attributes = values[0].list?.compactMap(\.text) ?? []
            let delimiter = values[1] == .nil_ ? nil : values[1].text
            return .list(attributes: attributes, delimiter: delimiter, name: values[2].text ?? "")
        case "SEARCH":
            let numbers = try tokenizer.parseAll().compactMap { value -> UInt32? in
                value.number.map { UInt32(truncatingIfNeeded: $0) }
            }
            return .search(numbers)
        default:
            break
        }

        if let number = UInt32(word) {
            let kind = tokenizer.readAtom().uppercased()
            switch kind {
            case "EXISTS": return .exists(number)
            case "EXPUNGE": return .expunge(number)
            case "FETCH":
                tokenizer.skipSpaces()
                let values = try tokenizer.parseValue().list ?? []
                var attributes: [String: IMAPValue] = [:]
                var index = 0
                while index + 1 < values.count {
                    if let key = values[index].text { attributes[key.uppercased()] = values[index + 1] }
                    index += 2
                }
                return .fetch(sequence: number, attributes: attributes)
            default:
                return .other("\(word) \(kind)")
            }
        }
        return .other(word + " " + tokenizer.rest())
    }

    /// Parses `[CODE args] free text`; free text may contain anything, so it is never tokenized.
    static func parseResponseText(_ tokenizer: inout IMAPTokenizer) -> (ResponseCode?, String) {
        tokenizer.skipSpaces()
        var code: ResponseCode?
        if tokenizer.peek == UInt8(ascii: "[") {
            let inner = tokenizer.readBracketed()
            var codeTokenizer = IMAPTokenizer(bytes: Array(inner.utf8))
            let name = codeTokenizer.readAtom().uppercased()
            let arguments = (try? codeTokenizer.parseAll()) ?? []
            code = ResponseCode(name: name, arguments: arguments)
        }
        return (code, tokenizer.rest().trimmingCharacters(in: .whitespaces))
    }
}

struct IMAPTokenizer {
    let bytes: [UInt8]
    var position = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var isAtEnd: Bool { position >= bytes.count }
    var peek: UInt8? { isAtEnd ? nil : bytes[position] }

    mutating func skipSpaces() {
        while let byte = peek, byte == 32 { position += 1 }
    }

    mutating func rest() -> String {
        skipSpaces()
        defer { position = bytes.count }
        return Charset.decodeHeaderBytes(Data(bytes[min(position, bytes.count)...]))
    }

    mutating func parseAll() throws -> [IMAPValue] {
        var values: [IMAPValue] = []
        while true {
            skipSpaces()
            guard let byte = peek, byte != 13, byte != 10 else { break }
            values.append(try parseValue())
        }
        return values
    }

    mutating func parseValue() throws -> IMAPValue {
        skipSpaces()
        guard let byte = peek else { throw PoscarError.protocolViolation("Unexpected end of response") }
        switch byte {
        case UInt8(ascii: "("):
            position += 1
            var items: [IMAPValue] = []
            while true {
                skipSpaces()
                guard let next = peek else { throw PoscarError.protocolViolation("Unterminated list") }
                if next == UInt8(ascii: ")") {
                    position += 1
                    break
                }
                items.append(try parseValue())
            }
            return .list(items)
        case UInt8(ascii: "\""):
            return .string(readQuoted())
        case UInt8(ascii: "{"):
            return .string(try readLiteral())
        default:
            let atom = readAtom()
            if atom.isEmpty {
                position += 1
                throw PoscarError.protocolViolation("Unexpected character \(UnicodeScalar(byte))")
            }
            return atom.uppercased() == "NIL" ? .nil_ : .atom(atom)
        }
    }

    /// Reads an atom; `[...]` sections (as in `BODY[HEADER.FIELDS (FROM)]`) may contain spaces and parentheses.
    mutating func readAtom() -> String {
        skipSpaces()
        let start = position
        var bracketDepth = 0
        while let byte = peek {
            if byte == UInt8(ascii: "[") {
                bracketDepth += 1
            } else if byte == UInt8(ascii: "]") {
                bracketDepth = max(0, bracketDepth - 1)
            } else if bracketDepth == 0, byte == 32 || byte == 40 || byte == 41 || byte == 13 || byte == 10 || byte == 34 {
                break
            }
            position += 1
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    mutating func readBracketed() -> String {
        guard peek == UInt8(ascii: "[") else { return "" }
        position += 1
        let start = position
        while let byte = peek, byte != UInt8(ascii: "]") { position += 1 }
        let inner = String(decoding: bytes[start..<position], as: UTF8.self)
        if !isAtEnd { position += 1 }
        return inner
    }

    mutating func readQuoted() -> Data {
        position += 1
        var data = Data()
        while let byte = peek {
            position += 1
            if byte == UInt8(ascii: "\\"), let escaped = peek {
                data.append(escaped)
                position += 1
            } else if byte == UInt8(ascii: "\"") {
                break
            } else {
                data.append(byte)
            }
        }
        return data
    }

    mutating func readLiteral() throws -> Data {
        position += 1
        var digits = ""
        while let byte = peek, byte != UInt8(ascii: "}") {
            if byte != UInt8(ascii: "+") { digits.append(Character(UnicodeScalar(byte))) }
            position += 1
        }
        position += 1
        guard let length = Int(digits) else { throw PoscarError.protocolViolation("Bad literal length \(digits)") }
        if peek == 13 { position += 1 }
        if peek == 10 { position += 1 }
        guard position + length <= bytes.count else { throw PoscarError.protocolViolation("Truncated literal") }
        defer { position += length }
        return Data(bytes[position..<position + length])
    }
}
