// Layer: EngineAgent (Transfer).
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
    case dictionary([String: BencodeValue], span: Range<Int>)

    public var span: Range<Int> {
        switch self {
        case .integer(_, let span), .bytes(_, let span), .list(_, let span), .dictionary(_, let span):
            return span
        }
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
        return .integer(isNegative ? -magnitude : magnitude, span: start..<cursor)
    }

    private static func parseString(_ data: Data, cursor: inout Int) throws -> BencodeValue {
        let start = cursor
        // length digits
        let lengthStart = cursor
        while let b = data.byte(at: cursor), b != 0x3A /* ':' */ {
            guard b >= 0x30, b <= 0x39 else { throw BencodeError.malformedLength("<non-digit>") }
            cursor += 1
            if cursor - lengthStart > 20 { throw BencodeError.malformedLength("<overlong>") }
        }
        guard data.byte(at: cursor) == 0x3A else { throw BencodeError.truncated }
        let digits = data.subdata(in: lengthStart..<cursor)
        guard let text = String(bytes: digits, encoding: .ascii) else {
            throw BencodeError.malformedLength("<non-ascii>")
        }
        guard !text.isEmpty else { throw BencodeError.malformedLength("") }
        guard text != "0" ? !text.hasPrefix("0") : true else { throw BencodeError.malformedLength(text) }
        guard let length = Int(text) else { throw BencodeError.malformedLength(text) }
        cursor += 1 // ':'
        let payloadStart = cursor
        let payloadEnd = payloadStart + length
        guard payloadEnd <= data.count else { throw BencodeError.truncated }
        cursor = payloadEnd
        return .bytes(data.subdata(in: payloadStart..<payloadEnd), span: start..<cursor)
    }

    private static func parseList(_ data: Data, cursor: inout Int, depth: Int) throws -> BencodeValue {
        let start = cursor
        cursor += 1 // 'l'
        var items: [BencodeValue] = []
        while let b = data.byte(at: cursor) {
            if b == 0x65 /* 'e' */ {
                cursor += 1
                return .list(items, span: start..<cursor)
            }
            items.append(try parseValue(data, cursor: &cursor, depth: depth + 1))
        }
        throw BencodeError.truncated
    }

    private static func parseDictionary(_ data: Data, cursor: inout Int, depth: Int) throws -> BencodeValue {
        let start = cursor
        cursor += 1 // 'd'
        var entries: [String: BencodeValue] = [:]
        while let b = data.byte(at: cursor) {
            if b == 0x65 /* 'e' */ {
                cursor += 1
                return .dictionary(entries, span: start..<cursor)
            }
            // Keys are bencoded strings; reuse the string parser.
            let keyValue = try parseString(data, cursor: &cursor)
            guard case .bytes(let keyBytes, _) = keyValue,
                  let key = String(data: keyBytes, encoding: .utf8) else {
                throw BencodeError.invalidDictionaryKey
            }
            // Duplicate keys are malformed (attacker-controlled ambiguity).
            guard entries[key] == nil else { throw BencodeError.invalidDictionaryKey }
            entries[key] = try parseValue(data, cursor: &cursor, depth: depth + 1)
        }
        throw BencodeError.truncated
    }
}

// MARK: - Small Data helpers

extension Data {
    /// Returns the byte at `index` or nil when out of bounds.
    func byte(at index: Int) -> UInt8? {
        guard index >= startIndex, index < endIndex else { return nil }
        return self[index]
    }
}
