import Foundation
import XCTest
@testable import CompanionCore

final class DayTimelineTests: XCTestCase {
    private func calendar(_ zone: String) throws -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return result
    }

    func testLocalPeriods() {
        let periods: [DayPeriod] = [.lateNight, .dawn, .morning, .day, .evening, .night]
        for (hour, expected) in zip([0, 5, 8, 12, 18, 22], periods) {
            XCTAssertEqual(DayPeriod(hour: hour), expected)
        }
    }

    func testDSTAndBudget() throws {
        let cal = try calendar("America/New_York")
        for iso in ["2026-03-08T05:58:00Z", "2026-11-01T04:58:00Z"] {
            let start = try XCTUnwrap(ISO8601DateFormatter().date(from: iso))
            let normal = DayTimeline.dates(from: start, mode: .normal, calendar: cal)
            let eco = DayTimeline.dates(from: start, mode: .eco, calendar: cal)
            XCTAssertLessThan(eco.count, normal.count)
            for dates in [eco, normal] {
                XCTAssertEqual(dates.first, start)
                XCTAssertTrue((6...14).contains(dates.count))
                for (before, after) in zip(dates, dates.dropFirst()) {
                    XCTAssertGreaterThanOrEqual(after.timeIntervalSince(before), 300)
                    XCTAssertLessThanOrEqual(after.timeIntervalSince(start), 43200)
                }
                XCTAssertTrue(dates.contains { cal.component(.hour, from: $0) == 5 })
            }
            for mode in [CompanionMode.safe, .paused] {
                XCTAssertEqual(DayTimeline.dates(from: start, mode: mode, calendar: cal), [start])
            }
        }
    }

    func testPassiveFramesDoNotConsumeMorningGreeting() throws {
        let cal = try calendar("Asia/Tokyo")
        let dawn = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-26T20:01:00Z"))
        var state = Companion()
        let baseline = state
        let night = dawn.addingTimeInterval(-3600)
        XCTAssertEqual(DayTimeline.display(state, at: night, calendar: cal).text, "")
        XCTAssertNotEqual(DayTimeline.display(state, at: dawn, calendar: cal).id, "greeting")
        XCTAssertEqual(state, baseline)
        state.react(at: dawn, calendar: cal)
        XCTAssertEqual(state.hero.pack?.byID[DayTimeline.display(state, at: dawn, calendar: cal).id]?.category, "morning")
        var restored = try JSONDecoder().decode(Companion.self, from: JSONEncoder().encode(state))
        XCTAssertFalse(restored.greetIfNeeded(at: dawn, calendar: cal))
        XCTAssertFalse(restored.greetIfNeeded(at: dawn.addingTimeInterval(-86400), calendar: cal))
        XCTAssertTrue(restored.greetIfNeeded(at: dawn.addingTimeInterval(86400), calendar: cal))
        restored.react(at: night, calendar: cal)
        XCTAssertEqual(restored.hero.pack?.byID[DayTimeline.display(restored, at: night, calendar: cal).id]?.category, "night")
    }
}
