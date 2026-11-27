#if canImport(SQLite3)
import Foundation
import SQLite3
import XCTest
@testable import CompanionCore

final class StoreTests: XCTestCase {
    private var directory: URL!
    private var store: Store!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        store = Store(url: directory.appendingPathComponent("fixture.sqlite"))
    }

    override func tearDownWithError() throws {
        if let directory { try FileManager.default.removeItem(at: directory) }
    }

    private func connection(_ body: (OpaquePointer) throws -> Void) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(store.url.path, &handle) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            throw StoreError.database
        }
        defer { sqlite3_close(db) }
        try body(db)
    }

    private func execute(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw StoreError.database }
    }

    func testOptionalReadDistinguishesAbsentEmptyLockedAndSavedSnapshot() throws {
        XCTAssertNil(try store.readIfPresent())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        let saved = try store.update { $0.hero = .toji }
        XCTAssertEqual(try store.readIfPresent(), saved)
        try connection { db in
            try execute(db, "BEGIN EXCLUSIVE")
            XCTAssertThrowsError(try store.readIfPresent())
            try execute(db, "DELETE FROM snapshot")
            try execute(db, "COMMIT")
        }
        XCTAssertNil(try store.readIfPresent())
        XCTAssertEqual(try store.read(), Companion())
    }

    func testLegacyMigrationAndCorruptSnapshotPreservation() throws {
        XCTAssertEqual(try store.read(), Companion())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.url.path))
        try store.update { _ in }
        try connection { db in
            try execute(db, #"UPDATE snapshot SET version=1, body=CAST('{"mode":"Безопасный","line":2}' AS BLOB)"#)
        }
        let migrated = try store.update { $0.reminders.append(LocalReminder(title: "Сохранить")) }
        XCTAssertEqual(migrated.mode, .safe)
        XCTAssertEqual(migrated.reaction.id, "notice")
        XCTAssertEqual(try store.read(), migrated)
        try connection { db in
            try execute(db, "UPDATE snapshot SET body=X'00FF'")
            XCTAssertThrowsError(try store.read())
            XCTAssertThrowsError(try store.update { _ in XCTFail("Unexpected mutation") })
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT version,hex(body) FROM snapshot", -1, &statement, nil), SQLITE_OK)
            XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
            XCTAssertEqual(sqlite3_column_int(statement, 0), 2)
            XCTAssertEqual(String(cString: sqlite3_column_text(statement, 1)), "00FF")
        }
    }

    func testInterruptedWriteAndBusyDatabaseKeepCommittedState() throws {
        let before = try store.update { $0.hero = .maomao }
        try connection { db in
            try execute(db, "BEGIN IMMEDIATE")
            try execute(db, "DELETE FROM snapshot")
            XCTAssertEqual(try store.read(), before)
            XCTAssertThrowsError(try store.update { $0.hero = .toji })
            // Closing this second connection before COMMIT simulates an interrupted writer.
        }
        XCTAssertEqual(try store.read(), before)
        XCTAssertEqual(try store.update { $0.mode = .eco }.hero, .maomao)
    }

    func testTwoWritersKeepBothEdits() throws {
        let peer = Store(url: store.url)
        try store.update { $0.mode = .eco }
        let firstHasLock = DispatchSemaphore(value: 0)
        let done = expectation(description: "first transaction completes")
        DispatchQueue.global().async {
            defer { done.fulfill() }
            do {
                try peer.update {
                    $0.hero = .jinwoo
                    firstHasLock.signal()
                    Thread.sleep(forTimeInterval: 0.04)
                }
            } catch { XCTFail("First writer: \(error)") }
        }
        XCTAssertEqual(firstHasLock.wait(timeout: .now() + 2), .success)
        let latest = try store.update { $0.reminders.append(LocalReminder(title: "Задача")) }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(latest.hero, .jinwoo)
        XCTAssertEqual(latest.mode, .eco)
        XCTAssertEqual(try peer.read(), latest)
    }
}
#endif
