import XCTest
@testable import CompanionCore

final class CalendarSnapshotTests: XCTestCase {
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
