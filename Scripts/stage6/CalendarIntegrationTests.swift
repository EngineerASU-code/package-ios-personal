import EventKit
import XCTest
@testable import MyCompanion

final class CalendarIntegrationTests: XCTestCase {
    @MainActor func testSnapshotPrivacyAndWithdrawal() async throws {
        XCTAssertEqual(EKEventStore.authorizationStatus(for: .event), .fullAccess)
        let service = CalendarController.shared
        let store = service.eventStore
        let event = EKEvent(eventStore: store)
        event.calendar = try XCTUnwrap(store.defaultCalendarForNewEvents)
        event.title = "Private simulator fixture"
        event.startDate = Date().addingTimeInterval(3600)
        event.endDate = event.startDate.addingTimeInterval(1200)
        try store.save(event, span: .thisEvent)
        defer { try? store.remove(event, span: .thisEvent) }

        let settings = UserDefaults.standard
        settings.set(true, forKey: "calendarEnabled")
        settings.set(false, forKey: "calendarTitles")
        await service.refresh()
        let privateState = try Store.shared().read().calendarSnapshot
        let item = try XCTUnwrap(privateState.events.first { abs($0.start.timeIntervalSince(event.startDate)) < 1 })
        XCTAssertNil(item.title)
        XCTAssertEqual(item.label, "Событие")

        settings.set(true, forKey: "calendarTitles")
        await service.refresh()
        XCTAssertEqual(try Store.shared().read().calendarSnapshot.events.first { $0.id == item.id }?.title, event.title)

        settings.set(false, forKey: "calendarEnabled")
        settings.set(false, forKey: "calendarTitles")
        await service.refresh()
        XCTAssertTrue(try Store.shared().read().calendarSnapshot.events.isEmpty)
        XCTAssertNotNil(store.event(withIdentifier: event.eventIdentifier))
    }
}
