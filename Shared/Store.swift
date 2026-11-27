#if canImport(SQLite3) || os(iOS) || os(macOS)
import Foundation
import SQLite3

enum StoreError: Error { case unavailable, database, unsupportedVersion }

struct Store {
    let url: URL
    #if STAGE5_WIDGET_TESTS
    private static let databaseName = "stage5-\(UUID().uuidString).sqlite"
    #else
    private static let databaseName = "companion.sqlite"
    #endif

    #if os(iOS) || os(macOS)
    static func shared() throws -> Store {
        guard let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.local.mycompanion") else { throw StoreError.unavailable }
        return Store(url: directory.appendingPathComponent(databaseName))
    }

    #endif

    private func withDB<T>(writing: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        var connection: OpaquePointer?
        let flags = writing ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        let result = sqlite3_open_v2(url.path, &connection, flags, nil)
        defer { sqlite3_close(connection) }
        if !writing && result == SQLITE_CANTOPEN {
            // SQLite also returns CANTOPEN for permissions and inaccessible paths.
            // Only a confirmed missing file is a first launch.
            _ = try FileManager.default.attributesOfItem(atPath: url.path)
        }
        guard result == SQLITE_OK, let db = connection else { throw StoreError.database }
        sqlite3_busy_timeout(db, 250)
        if writing {
            try execute(db, "CREATE TABLE IF NOT EXISTS snapshot(id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, body BLOB NOT NULL)")
        }
        return try body(db)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.database }
    }

    private func read(_ db: OpaquePointer) throws -> Companion? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT version,body FROM snapshot WHERE id=1", -1, &stmt, nil) == SQLITE_OK else { throw StoreError.database }
        let step = sqlite3_step(stmt)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw StoreError.database }
        guard (1...2).contains(sqlite3_column_int(stmt, 0)) else { throw StoreError.unsupportedVersion }
        guard let bytes = sqlite3_column_blob(stmt, 1) else { throw StoreError.database }
        return try JSONDecoder().decode(Companion.self, from: Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 1))))
    }

    func readIfPresent() throws -> Companion? {
        do { return try withDB(writing: false) { try read($0) } }
        catch let failure as NSError where failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError {
            return nil
        }
    }

    func read() throws -> Companion {
        try readIfPresent() ?? Companion()
    }

    @discardableResult func update(_ change: (inout Companion) -> Void) throws -> Companion {
        try withDB(writing: true) { db in
            try execute(db, "BEGIN IMMEDIATE")
            defer { if sqlite3_get_autocommit(db) == 0 { _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
            var value = try read(db) ?? Companion()
            change(&value)
            let data = try JSONEncoder().encode(value)
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO snapshot VALUES(1,2,?)", -1, &stmt, nil) == SQLITE_OK else { throw StoreError.database }
            try data.withUnsafeBytes { bytes in
                guard sqlite3_bind_blob(stmt, 1, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) == SQLITE_OK,
                      sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.database }
            }
            try execute(db, "COMMIT")
            return value
        }
    }
}
#endif
