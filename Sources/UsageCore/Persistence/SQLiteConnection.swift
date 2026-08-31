import Foundation
import SQLite3

final class SQLiteConnection {
    private var database: OpaquePointer?

    init(databaseURL: URL) throws {
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(databaseURL.path, &opened, flags, nil)
        guard result == SQLITE_OK, let opened else {
            let code = opened.map(sqlite3_extended_errcode) ?? result
            if let opened {
                sqlite3_close_v2(opened)
            }
            throw SQLiteStoreError.operationFailed(operation: "open database", code: code)
        }
        database = opened
        sqlite3_extended_result_codes(opened, 1)

        do {
            try execute("PRAGMA foreign_keys = ON;", operation: "configure database")
            try execute("PRAGMA journal_mode = WAL;", operation: "configure database")
            try execute("PRAGMA synchronous = NORMAL;", operation: "configure database")
        } catch {
            sqlite3_close_v2(opened)
            database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    func execute(_ sql: String, operation: String) throws {
        guard let database else {
            throw SQLiteStoreError.closed
        }
        var errorMessage: UnsafeMutablePointer<CChar>?
        defer {
            if let errorMessage {
                sqlite3_free(errorMessage)
            }
        }
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            throw SQLiteStoreError.operationFailed(
                operation: operation,
                code: sqlite3_extended_errcode(database)
            )
        }
    }

    func prepare(_ sql: String, operation: String) throws -> SQLiteStatement {
        guard let database else {
            throw SQLiteStoreError.closed
        }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw SQLiteStoreError.operationFailed(
                operation: operation,
                code: sqlite3_extended_errcode(database)
            )
        }
        return SQLiteStatement(
            connection: self,
            database: database,
            statement: statement,
            operation: operation
        )
    }

    func changes() throws -> Int {
        guard let database else {
            throw SQLiteStoreError.closed
        }
        return Int(sqlite3_changes(database))
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;", operation: "begin transaction")
        do {
            let value = try body()
            try execute("COMMIT;", operation: "commit transaction")
            return value
        } catch {
            try? execute("ROLLBACK;", operation: "rollback transaction")
            throw error
        }
    }
}

enum SQLiteStepResult {
    case row
    case done
}

final class SQLiteStatement {
    private let connection: SQLiteConnection
    private let database: OpaquePointer
    private var statement: OpaquePointer?
    private let operation: String

    init(
        connection: SQLiteConnection,
        database: OpaquePointer,
        statement: OpaquePointer,
        operation: String
    ) {
        self.connection = connection
        self.database = database
        self.statement = statement
        self.operation = operation
    }

    deinit {
        if let statement {
            sqlite3_finalize(statement)
        }
    }

    func bind(_ value: Int64, at index: Int32) throws {
        try check(sqlite3_bind_int64(try pointer(), index, value), suffix: "bind integer")
    }

    func bind(_ value: Double, at index: Int32) throws {
        try check(sqlite3_bind_double(try pointer(), index, value), suffix: "bind double")
    }

    func bind(_ value: String, at index: Int32) throws {
        let statement = try pointer()
        let result = value.withCString { bytes in
            sqlite3_bind_text(
                statement,
                index,
                bytes,
                -1,
                unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            )
        }
        try check(result, suffix: "bind text")
    }

    func bind(_ value: Data, at index: Int32) throws {
        let statement = try pointer()
        let result: Int32
        if value.isEmpty {
            result = sqlite3_bind_zeroblob(statement, index, 0)
        } else {
            result = value.withUnsafeBytes { bytes in
                sqlite3_bind_blob(
                    statement,
                    index,
                    bytes.baseAddress,
                    Int32(bytes.count),
                    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
                )
            }
        }
        try check(result, suffix: "bind blob")
    }

    func bindNull(at index: Int32) throws {
        try check(sqlite3_bind_null(try pointer(), index), suffix: "bind null")
    }

    func step() throws -> SQLiteStepResult {
        let result = sqlite3_step(try pointer())
        switch result {
        case SQLITE_ROW:
            return .row
        case SQLITE_DONE:
            return .done
        default:
            throw failure(suffix: "step")
        }
    }

    func reset() throws {
        let statement = try pointer()
        try check(sqlite3_reset(statement), suffix: "reset")
        try check(sqlite3_clear_bindings(statement), suffix: "clear bindings")
    }

    func int64(at column: Int32) throws -> Int64 {
        sqlite3_column_int64(try pointer(), column)
    }

    func optionalInt64(at column: Int32) throws -> Int64? {
        let statement = try pointer()
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return sqlite3_column_int64(statement, column)
    }

    func double(at column: Int32) throws -> Double {
        sqlite3_column_double(try pointer(), column)
    }

    func string(at column: Int32) throws -> String {
        guard let bytes = sqlite3_column_text(try pointer(), column) else {
            throw failure(suffix: "read text")
        }
        return String(cString: UnsafeRawPointer(bytes).assumingMemoryBound(to: CChar.self))
    }

    func data(at column: Int32) throws -> Data {
        let statement = try pointer()
        let count = Int(sqlite3_column_bytes(statement, column))
        if count == 0 {
            return Data()
        }
        guard let bytes = sqlite3_column_blob(statement, column) else {
            throw failure(suffix: "read blob")
        }
        return Data(bytes: bytes, count: count)
    }

    private func pointer() throws -> OpaquePointer {
        guard let statement else {
            throw SQLiteStoreError.closed
        }
        return statement
    }

    private func check(_ result: Int32, suffix: String) throws {
        guard result == SQLITE_OK else {
            throw failure(suffix: suffix)
        }
    }

    private func failure(suffix: String) -> SQLiteStoreError {
        SQLiteStoreError.operationFailed(
            operation: "\(operation): \(suffix)",
            code: sqlite3_extended_errcode(database)
        )
    }
}
