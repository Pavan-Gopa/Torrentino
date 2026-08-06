// Layer: Domain
// Role: strict bencode parser for .torrent metainfo. Untrusted input only —
// every structural failure is an error, never a partial tree. The parser
// records each value's byte span so the SHA-1 info hash can be computed over
// the exact "info" dictionary bytes (BEP-3).
// Must-not: accept truncated/oversized/nested-too-deep input, tolerate
// negative or malformed lengths, or return partial values after an error.
// Invariants: deterministic, no I/O, Sendable; input size and depth are
// bounded; parse() consumes the ENTIRE input or throws.

import Foundation

/// Bencode value tree. `span` is the half-open byte range of this value
/// inside the original input (needed for info-hash computation).
public enum BencodeValue: Sendable, Equatable {
    case integer(Int64, span: Range<Int>)
    case bytes(Data, span: Range<Int>)
    case list([BencodeValue], span: Range<Int>)
    /// Dictionary keys are raw bytes, not decoded strings: BEP-52 file-tree
    /// path elements may be any UTF-8 byte sequence and must round-trip
    /// byte-for-byte. Look up ASCII field names with `value(for:)`.
    case dictionary([Data: BencodeValue], span: Range<Int>)

    public var span: Range<Int> {
        switch self {
        case .integer(_, let span), .bytes(_, let span), .list(_, let span), .dictionary(_, let span):
            return span
        }
    }
}

public extension BencodeValue {
    /// Looks up an ASCII field name (e.g. "info", "length") by its exact
    /// UTF-8 bytes. Field names in metainfo are ASCII by convention, so the
    /// byte form is unambiguous.
    func value(for key: String) -> BencodeValue? {
        guard case .dictionary(let dict, _) = self else { return nil }
        return dict[Data(key.utf8)]
    }
}

public extension Dictionary where Key == Data {
    func value(for key: String) -> Value? {
        self[Data(key.utf8)]
    }
}

public enum BencodeError: Error, Sendable, Equatable, CustomStringConvertible {
    case emptyInput
    case truncated
    case trailingData
    case malformedInteger(String)
    case malformedLength(String)
    case depthExceeded
    case sizeExceeded(Int)
    case unexpectedToken(UInt8)
    case invalidDictionaryKey
    case unterminatedValue

    public var description: String {
        switch self {
        case .emptyInput: return "empty input"
        case .truncated: return "truncated input"
        case .trailingData: return "trailing data"
        case .malformedInteger(let s): return "malformed integer '\(s)'"
        case .malformedLength(let s): return "malformed length '\(s)'"
        case .depthExceeded: return "nesting depth exceeded"
        case .sizeExceeded(let n): return "size limit exceeded (\(n) bytes)"
        case .unexpectedToken(let b): return "unexpected token 0x\(String(format: "%02x", b))"
        case .invalidDictionaryKey: return "invalid dictionary key"
        case .unterminatedValue: return "unterminated value"
        }
    }
}

public enum BencodeParser {
    /// Maximum nesting depth (negative corpus: nested too deep → reject).
    public static let maxDepth = 64

    /// Maximum parseable input. .torrent files are additionally capped at
    /// 10 MiB by preflight (HTTP limit), so this is a hard structural ceiling.
    public static let maxInputBytes = 16 * 1024 * 1024

    /// Parses `data` completely. Throws on any structural problem; on success
    /// the whole input is consumed.
    public static func parse(_ data: Data) throws -> BencodeValue {
        guard !data.isEmpty else { throw BencodeError.emptyInput }
        guard data.count <= maxInputBytes else { throw BencodeError.sizeExceeded(data.count) }
        var cursor = 0
        let value = try parseValue(data, cursor: &cursor, depth: 0)
        guard cursor == data.count else { throw BencodeError.trailingData }
        return value
    }

    // MARK: - Recursive descent

    private static func parseValue(_ data: Data, cursor: inout Int, depth: Int) throws -> BencodeValue {
        guard depth <= maxDepth else { throw BencodeError.depthExceeded }
        guard let token = data.byte(at: cursor) else { throw BencodeError.truncated }
        switch token {
        case 0x69: // 'i'
            return try parseInteger(data, cursor: &cursor)
        case 0x6C: // 'l'
            return try parseList(data, cursor: &cursor, depth: depth)
        case 0x64: // 'd'
            return try parseDictionary(data, cursor: &cursor, depth: depth)
        case 0x30...0x39: // '0'...'9'
            return try parseString(data, cursor: &cursor)
        default:
            throw BencodeError.unexpectedToken(token)
        }
    }

    private static func parseInteger(_ data: Data, cursor: inout Int) throws -> BencodeValue {
        let start = cursor
        cursor += 1 // 'i'
        let isNegative: Bool
        if let b = data.byte(at: cursor), b == 0x2D /* '-' */ {
            isNegative = true
            cursor += 1
        } else {
            isNegative = false
        }
        let digitsStart = cursor
        var digitCount = 0
        while let b = data.byte(at: cursor), b != 0x65 /* 'e' */ {
            guard b >= 0x30, b <= 0x39 else { throw BencodeError.malformedInteger("<non-digit>") }
            cursor += 1
            digitCount += 1
            guard digitCount <= 19 else { throw BencodeError.malformedInteger("<overlong>") }
        }
        guard data.byte(at: cursor) == 0x65 else { throw BencodeError.truncated }
        guard digitCount > 0 else { throw BencodeError.malformedInteger("") }
        // Strict grammar: no leading zeros except the single digit "0" itself;
        // "-0" is malformed (BEP-3: "i-0e" is invalid).
        if digitCount == 1, data[digitsStart] == 0x30, isNegative {
            throw BencodeError.malformedInteger("-0")
        }
        if digitCount > 1, data[digitsStart] == 0x30 {
            throw BencodeError.malformedInteger("<leading-zero>")
        }
        guard let magnitude = Int64(String(data: data.subdata(in: digitsStart..<cursor), encoding: .ascii) ?? "") else {
            throw BencodeError.malformedInteger("<overflow>")
        }
        cursor += 1 // 'e'
        let val = isNegative ? -magnitude : magnitude
        return .integer(val, span: start..<cursor)
    }

    private static func parseString(_ data: Data, cursor: inout Int) throws -> BencodeValue {
        let start = cursor
        let lenStart = cursor
        var lenDigits = 0
        while let b = data.byte(at: cursor), b != 0x3A /* ':' */ {
            guard b >= 0x30, b <= 0x39 else { throw BencodeError.malformedLength("<non-digit>") }
            cursor += 1
            lenDigits += 1
            guard lenDigits <= 10 else { throw BencodeError.malformedLength("<overlong>") }
        }
        guard data.byte(at: cursor) == 0x3A else { throw BencodeError.truncated }
        guard lenDigits > 0 else { throw BencodeError.malformedLength("") }
        if lenDigits > 1, data[lenStart] == 0x30 {
            throw BencodeError.malformedLength("<leading-zero>")
        }
        guard let lengthInt = Int(String(data: data.subdata(in: lenStart..<cursor), encoding: .ascii) ?? ""),
              lengthInt >= 0 else {
            throw BencodeError.malformedLength("<bad-len>")
        }
        cursor += 1 // ':'
        let payloadStart = cursor
        guard cursor + lengthInt <= data.count else { throw BencodeError.truncated }
        cursor += lengthInt
        let strBytes = data.subdata(in: payloadStart..<cursor)
        return .bytes(strBytes, span: start..<cursor)
    }

    private static func parseList(_ data: Data, cursor: inout Int, depth: Int) throws -> BencodeValue {
        let start = cursor
        cursor += 1 // 'l'
        var items: [BencodeValue] = []
        while let b = data.byte(at: cursor), b != 0x65 /* 'e' */ {
            let item = try parseValue(data, cursor: &cursor, depth: depth + 1)
            items.append(item)
        }
        guard data.byte(at: cursor) == 0x65 else { throw BencodeError.truncated }
        cursor += 1 // 'e'
        return .list(items, span: start..<cursor)
    }

    private static func parseDictionary(_ data: Data, cursor: inout Int, depth: Int) throws -> BencodeValue {
        let start = cursor
        cursor += 1 // 'd'
        var dict: [Data: BencodeValue] = [:]
        var lastKeyData: Data? = nil
        while let b = data.byte(at: cursor), b != 0x65 /* 'e' */ {
            let keyVal = try parseValue(data, cursor: &cursor, depth: depth + 1)
            guard case .bytes(let keyData, _) = keyVal else {
                throw BencodeError.invalidDictionaryKey
            }
            // Strict BEP-3: dictionary keys MUST be sorted in lexicographical
            // byte order and MUST NOT contain duplicates.
            if let lastKeyData {
                if keyData == lastKeyData { throw BencodeError.invalidDictionaryKey }
                if keyData.lexicographicallyPrecedes(lastKeyData) { throw BencodeError.invalidDictionaryKey }
            }
            lastKeyData = keyData
            let val = try parseValue(data, cursor: &cursor, depth: depth + 1)
            dict[keyData] = val
        }
        guard data.byte(at: cursor) == 0x65 else { throw BencodeError.truncated }
        cursor += 1 // 'e'
        return .dictionary(dict, span: start..<cursor)
    }
}

private extension Data {
    func byte(at index: Int) -> UInt8? {
        guard index >= 0, index < count else { return nil }
        return self[self.startIndex + index]
    }
}
