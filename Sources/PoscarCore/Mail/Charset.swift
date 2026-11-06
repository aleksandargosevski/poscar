import Foundation

public enum Charset {
    public static func decode(_ data: Data, charset: String?) -> String {
        if let encoding = encoding(named: charset), let text = String(data: data, encoding: encoding) {
            return text
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
            ?? String(decoding: data, as: UTF8.self)
    }

    /// Raw headers are ASCII in theory but often contain unencoded UTF-8 or Latin-1.
    public static func decodeHeaderBytes(_ data: Data) -> String {
        String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    static func encoding(named name: String?) -> String.Encoding? {
        guard var name = name?.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased(), !name.isEmpty else {
            return nil
        }
        switch name {
        case "utf8", "utf-8", "unicode-1-1-utf-8": return .utf8
        case "us-ascii", "ascii", "ansi_x3.4-1968": return .utf8
        case "latin1", "latin-1": name = "iso-8859-1"
        default: break
        }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }
}
