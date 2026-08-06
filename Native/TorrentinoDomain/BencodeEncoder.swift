// Layer: Domain
// Role: Deterministic bencode encoder for metainfo generation.
// Must-not: produce non-standard key ordering or unpadded output.
// Invariants: lexicographical dictionary key ordering by raw UTF-8 bytes; Sendable.

import Foundation

public enum BencodeEncoder {
    public enum Value: Sendable, Equatable {
        case integer(Int64)
        case bytes(Data)
        case list([Value])
        /// Keys are raw bytes (BEP-52 file-tree path elements must survive
        /// byte-for-byte); sort order is lexicographical over those bytes.
        case dictionary([Data: Value])

        public static func string(_ str: String) -> Value {
            .bytes(Data(str.utf8))
        }

        /// Convenience for ASCII-keyed dictionaries (metainfo field names).
        public static func dictionary(_ pairs: [(String, Value)]) -> Value {
            .dictionary(Dictionary(uniqueKeysWithValues: pairs.map { (Data($0.0.utf8), $0.1) }))
        }
    }

    public static func encode(_ value: Value) -> Data {
        var data = Data()
        encode(value, into: &data)
        return data
    }

    private static func encode(_ value: Value, into data: inout Data) {
        switch value {
        case .integer(let val):
            data.append(0x69) // 'i'
            data.append(contentsOf: String(val).utf8)
            data.append(0x65) // 'e'

        case .bytes(let bytes):
            data.append(contentsOf: String(bytes.count).utf8)
            data.append(0x3A) // ':'
            data.append(bytes)

        case .list(let items):
            data.append(0x6C) // 'l'
            for item in items {
                encode(item, into: &data)
            }
            data.append(0x65) // 'e'

        case .dictionary(let dict):
            data.append(0x64) // 'd'
            // BEP-3 requirement: dictionary keys MUST be sorted lexicographically
            // by raw byte string ordering.
            let sortedKeys = dict.keys.sorted { k1, k2 in
                k1.lexicographicallyPrecedes(k2)
            }
            for key in sortedKeys {
                encode(.bytes(key), into: &data)
                if let val = dict[key] {
                    encode(val, into: &data)
                }
            }
            data.append(0x65) // 'e'
        }
    }
}
