import XCTest
@testable import CompanionCore

final class CalendarSnapshotTests: XCTestCase {
    func testPrivacyRedactsHistoricalTitlesAndMissingConsentHidesAllEvents() {
        let now = Date()
        let item = CalendarItem(id: "id", start: now, end: now, allDay: false, title: "Private title")
        let value = CalendarSnapshot(updatedAt: now, expiry: now.addingTimeInterval(600), events: [item])
        XCTAssertEqual(value.filtered(by: .off), CalendarSnapshot())
        XCTAssertEqual(value.filtered(by: .privateTitles).events.first?.label, "Событие")
        XCTAssertEqual(value.filtered(by: .titles).events.first?.title, "Private title")
    }

    func testWarningQuotaExpiryAndElapsedOccurrenceAfterOffsetChanges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 86400)
        func item(_ key: String, minutes: Int) -> CalendarItem {
            let start = now.addingTimeInterval(Double(minutes * 60))
            return CalendarItem(id: key, start: start, end: start, allDay: false, title: nil)
        }
        let value = CalendarSnapshot(updatedAt: now, expiry: now.addingTimeInterval(7200),
                                     events: [item("first", minutes: 30), item("second", minutes: 60)])
        func plan(_ snapshot: CalendarSnapshot, at date: Date, offset: Int, ledger: [String: Date]) -> [String: Date] {
            snapshot.warningDates(now: date, offset: offset, quietStart: 0, quietEnd: 0, calendar: calendar, reservations: ledger)
        }
        let reserved = plan(value, at: now, offset: 15, ledger: [:])
        XCTAssertEqual(reserved, ["first": now.addingTimeInterval(900)])
        XCTAssertTrue(plan(value, at: now.addingTimeInterval(901), offset: 5, ledger: reserved).isEmpty)
        let yesterday = ["first": now.addingTimeInterval(-60)]
        XCTAssertEqual(Set(plan(value, at: now, offset: 5, ledger: yesterday).keys), ["second"])
        var expiresAtFire = value
        expiresAtFire.expiry = now.addingTimeInterval(900)
        XCTAssertTrue(plan(expiresAtFire, at: now, offset: 15, ledger: [:]).isEmpty)
    }

    @MainActor func testFailedRegistrationReleasesReservationForRetry() async throws {
        enum Rejected: Error { case request }
        let now = Date(timeIntervalSince1970: 86400)
        let start = now.addingTimeInterval(1800)
        let item = CalendarItem(id: "event", start: start, end: start, allDay: false, title: nil)
        let snapshot = CalendarSnapshot(updatedAt: now, expiry: start, events: [item])
        var ledger: [String: Date] = [:]
        var persisted: [String: Date] = [:]
        func plan() -> [String: Date] {
            snapshot.warningDates(now: now, offset: 15, quietStart: 0, quietEnd: 0,
                                  calendar: Calendar(identifier: .gregorian), reservations: persisted)
        }
        let date = try XCTUnwrap(plan()[item.id])
        do {
            try await CalendarSnapshot.registerWarning(item.id, at: date, ledger: &ledger, save: { persisted = $0 }) {
                XCTAssertEqual(persisted[item.id], date)
                throw Rejected.request
            }
            XCTFail("Expected rejected notification request")
        } catch Rejected.request {}
        XCTAssertTrue(persisted.isEmpty)
        let retry = try XCTUnwrap(plan()[item.id])
        try await CalendarSnapshot.registerWarning(item.id, at: retry, ledger: &ledger, save: { persisted = $0 }) {}
        XCTAssertEqual(persisted, [item.id: date])
    }

    func testFreshnessAndFinishedEvents() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expired = CalendarItem(id: "yesterday", start: now.addingTimeInterval(-900),
                                   end: now, allDay: false, title: nil)
        let ongoing = CalendarItem(id: "today", start: now.addingTimeInterval(-600),
                                   end: now.addingTimeInterval(60), allDay: true, title: nil)
        let snapshot = CalendarSnapshot(updatedAt: now, expiry: now.addingTimeInterval(120),
                                        events: [expired, ongoing])
        XCTAssertEqual(snapshot.upcoming(at: now), [ongoing])
        XCTAssertEqual(ongoing.label, "Событие")
        XCTAssertTrue(snapshot.upcoming(at: now.addingTimeInterval(-1)).isEmpty)
        XCTAssertFalse(snapshot.isFresh(at: now.addingTimeInterval(120)))
        XCTAssertTrue(snapshot.upcoming(at: now.addingTimeInterval(120)).isEmpty)
    }
}
