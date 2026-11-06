import Foundation

/// IMAP mailbox names (and Gmail labels) use modified UTF-7 (RFC 3501 §5.1.3).
public enum ModifiedUTF7 {
    public static func decode(_ input: String) -> String {
        var result = ""
        var index = input.startIndex
        while index < input.endIndex {
            let character = input[index]
            guard character == "&", let end = input[input.index(after: index)...].firstIndex(of: "-") else {
                result.append(character)
                index = input.index(after: index)
                continue
            }
            let encoded = input[input.index(after: index)..<end]
            if encoded.isEmpty {
                result += "&"
            } else {
                var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                while base64.count % 4 != 0 { base64 += "=" }
                if let data = Data(base64Encoded: base64), let text = String(data: data, encoding: .utf16BigEndian) {
                    result += text
                } else {
                    result += input[index...end]
                }
            }
            index = input.index(after: end)
        }
        return result
    }

    public static func encode(_ input: String) -> String {
        var result = ""
        var pending: [UInt16] = []

        func flush() {
            guard !pending.isEmpty else { return }
            var data = Data()
            for unit in pending {
                data.append(UInt8(unit >> 8))
                data.append(UInt8(unit & 0xff))
            }
            let base64 = data.base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "/", with: ",")
            result += "&\(base64)-"
            pending = []
        }

        for scalar in input.unicodeScalars {
            if scalar.value >= 0x20, scalar.value <= 0x7e {
                flush()
                result += scalar == "&" ? "&-" : String(scalar)
            } else {
                pending.append(contentsOf: String(scalar).utf16)
            }
        }
        flush()
        return result
    }
}
