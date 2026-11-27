import Foundation
import XCTest
@testable import CompanionCore

final class LocalReminderTests: XCTestCase {
    func testOldSnapshotAndReminderRoundTrip() throws {
        let old = Data(#"{"mode":"Обычный","hero":"satoru_gojo","histories":{}}"#.utf8)
        var state = try JSONDecoder().decode(Companion.self, from: old)
        XCTAssertTrue(state.reminders.isEmpty)
        var item = LocalReminder()
        item.title = "Проверка"
        state.reminders.append(item)
        XCTAssertEqual(try JSONDecoder().decode(Companion.self, from: JSONEncoder().encode(state)), state)
    }

    func testSnoozePreservesWeeklyAnchorAcrossDSTAndMissedWeeks() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        func date(_ day: Int, _ hour: Int) throws -> Date {
            try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour)))
        }
        var item = LocalReminder()
        item.dueAt = try date(1, 9)
        item.recurrence = .weekly
        let now = try date(16, 14)
        item.snooze(minutes: 30, at: now)
        XCTAssertEqual(item.target, now.addingTimeInterval(1800))
        item.complete(at: now.addingTimeInterval(1800), calendar: calendar)
        XCTAssertNil(item.snoozedUntil)
        XCTAssertNil(item.completedAt)
        XCTAssertEqual(item.target, try date(22, 9))
        XCTAssertEqual(item.revision, 2)
    }

    func testQuietDeferralAndCompletion() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let day = Date(timeIntervalSince1970: 86400)
        let target = day.addingTimeInterval(23 * 3600)
        let morning = day.addingTimeInterval(31 * 3600)
        var item = LocalReminder()
        item.dueAt = target
        item.notificationEnabled = true
        XCTAssertEqual(item.notificationDate(after: target, quietStart: 23, quietEnd: 7, allowDuringQuiet: false, calendar: calendar), morning)
        XCTAssertEqual(item.notificationDate(after: day, quietStart: 23, quietEnd: 7, allowDuringQuiet: true, calendar: calendar), target)
        item.complete(at: target, calendar: calendar)
        item.complete(at: morning, calendar: calendar)
        XCTAssertEqual(item.revision, 1)
        XCTAssertNil(item.notificationDate(after: day, quietStart: 23, quietEnd: 7, allowDuringQuiet: true, calendar: calendar))
    }
}
