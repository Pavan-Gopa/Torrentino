// Layer: Agent durable persistence (WP-06).
// Role: minimal, zero-dependency wrapper over the SQLite3 C API (system
// libsqlite3). A connection owns a single sqlite3 handle; statements are
// prepared per call site and finalized on deinit.
// Must-not: escape the PersistenceStore actor (the sqlite3 handle is not
// Sendable; @unchecked Sendable is safe ONLY because the connection and its
// statements are created, used and destroyed inside the store actor).
// Invariants: every method maps non-OK return codes to SQLiteError with the
// engine message; close() is idempotent; no Swift value is ever written to
// SQLite without going through the bind helpers (blob/text/int64).

import Foundation
import SQLite3

enum SQLiteError: Error, CustomStringConvertible, Sendable {
    case openFailed(path: String, code: Int32, message: String)
    case prepareFailed(code: Int32, message: String)
    case stepFailed(code: Int32, message: String)
    case executionFailed(code: Int32, message: String)
    case bindFailed(code: Int32, message: String)
    case databaseClosed

    var description: String {
        switch self {
        case .openFailed(let path, let code, let message):
            return "sqlite open failed \(path) code=\(code) message=\(message)"
        case .prepareFailed(let code, let message):
            return "sqlite prepare failed code=\(code) message=\(message)"
        case .stepFailed(let code, let message):
            return "sqlite step failed code=\(code) message=\(message)"
        case .executionFailed(let code, let message):
            return "sqlite exec failed code=\(code) message=\(message)"
        case .bindFailed(let code, let message):
            return "sqlite bind failed code=\(code) message=\(message)"
        case .databaseClosed:
            return "sqlite database is closed"
        }
    }
}

/// Opaque statement wrapper. Finalized in deinit; reset() re-runs a bound
/// statement without re-preparing (used by the journal trim loop).
final class SQLiteStatement: @unchecked Sendable {
    /// SQLITE_TRANSIENT is a C macro ((sqlite3_destructor_type)-1), so it is
    /// not visible from Swift; this is the same value as a destructor.
    private static let transientDestructor = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let handle: OpaquePointer?

    init(handle: OpaquePointer?) {
        self.handle = handle
    }

    deinit {
        if let handle { sqlite3_finalize(handle) }
    }

    func reset() {
        guard let handle else { return }
        _ = sqlite3_reset(handle)
    }

    func bindText(_ value: String?, index: Int32) throws {
        guard let handle else { throw SQLiteError.databaseClosed }
        if let value {
            let code = sqlite3_bind_text(handle, index, value, -1, Self.transientDestructor)
            guard code == SQLITE_OK else {
                throw SQLiteError.bindFailed(code: code, message: lastErrorMessage)
            }
        } else {
            let code = sqlite3_bind_null(handle, index)
            guard code == SQLITE_OK else {
                throw SQLiteError.bindFailed(code: code, message: lastErrorMessage)
            }
        }
    }

    func bindInt64(_ value: Int64, index: Int32) throws {
        guard let handle else { throw SQLiteError.databaseClosed }
        let code = sqlite3_bind_int64(handle, index, value)
        guard code == SQLITE_OK else {
            throw SQLiteError.bindFailed(code: code, message: lastErrorMessage)
        }
    }

    func bindBlob(_ data: Data?, index: Int32) throws {
        guard let handle else { throw SQLiteError.databaseClosed }
        if let data {
            let length = Int32(clamping: data.count)
            let code = data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Int32 in
                sqlite3_bind_blob(handle, index, bytes.baseAddress, length, Self.transientDestructor)
            }
            guard code == SQLITE_OK else {
                throw SQLiteError.bindFailed(code: code, message: lastErrorMessage)
            }
        } else {
            let code = sqlite3_bind_null(handle, index)
            guard code == SQLITE_OK else {
                throw SQLiteError.bindFailed(code: code, message: lastErrorMessage)
            }
        }
    }

    enum StepResult: Sendable {
        case row
        case done
    }

    func step() throws -> StepResult {
        guard let handle else { throw SQLiteError.databaseClosed }
        let code = sqlite3_step(handle)
        switch code {
        case SQLITE_ROW: return .row
        case SQLITE_DONE: return .done
        default:
            throw SQLiteError.stepFailed(code: code, message: lastErrorMessage)
        }
    }

    var columnCount: Int32 {
        handle.map { sqlite3_column_count($0) } ?? 0
    }

    func columnInt64(_ index: Int32) -> Int64 {
        guard let handle else { return 0 }
        return sqlite3_column_int64(handle, index)
    }

    func columnText(_ index: Int32) -> String? {
        guard let handle,
              let bytes = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: bytes)
    }

    func columnData(_ index: Int32) -> Data? {
        guard let handle,
              let bytes = sqlite3_column_blob(handle, index) else { return nil }
        let length = Int(sqlite3_column_bytes(handle, index))
        return Data(bytes: bytes, count: length)
    }

    private var lastErrorMessage: String {
        guard let handle else { return "closed" }
        return String(cString: sqlite3_errmsg(handle))
    }
}

/// Connection wrapper. open()/close()/exec()/prepare() are the only entry
/// points; statement stepping is handled by SQLiteStatement.
final class SQLiteConnection: @unchecked Sendable {
    let path: String
    private var handle: OpaquePointer?

    init(path: String) {
        self.path = path
    }

    deinit {
        close()
    }

    var isOpen: Bool { handle != nil }

    var lastErrorMessage: String {
        handle.map { String(cString: sqlite3_errmsg($0)) } ?? "closed"
    }

    /// Opens (creating if needed). readOnly is used by the corruption probe —
    /// a read-only open never writes recovery data into the damaged file.
    func open(readOnly: Bool = false) throws {
        guard handle == nil else { return }
        var flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        if readOnly { flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX }
        var db: OpaquePointer?
        let code = sqlite3_open_v2(path, &db, flags, nil)
        guard code == SQLITE_OK, let opened = db else {
            if let db { sqlite3_close_v2(db) }
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed with code \(code)"
            throw SQLiteError.openFailed(path: path, code: code, message: message)
        }
        handle = opened
    }

    func close() {
        if let handle {
            sqlite3_close_v2(handle)
        }
        handle = nil
    }

    func exec(_ sql: String) throws {
        guard let handle else { throw SQLiteError.databaseClosed }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard code == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            if let errorMessage { sqlite3_free(errorMessage) }
            throw SQLiteError.executionFailed(code: code, message: message)
        }
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        guard let handle else { throw SQLiteError.databaseClosed }
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
        return SQLiteStatement(handle: statement)
    }
}
