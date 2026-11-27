import EventKit
import XCTest
import UserNotifications
@testable import MyCompanion

final class CalendarIntegrationTests: XCTestCase {
    func testRepeatedIntentCannotSnoozeOrCompleteANewerRevision() async throws {
        let store = try Store.shared()
        let task = LocalReminder(title: "Проверка команды", dueAt: Date().addingTimeInterval(3600), revision: 1)
        try store.update { $0.reminders.append(task) }
        defer { _ = try? store.update { $0.reminders.removeAll { $0.id == task.id } } }

        var snooze = SnoozeReminderIntent()
        snooze.occurrence = ReminderOccurrence(task: task)
        _ = try await snooze.perform()
        let afterSnooze = try XCTUnwrap(store.read().reminders.first { $0.id == task.id })
        XCTAssertNotNil(afterSnooze.snoozedUntil)
        _ = try await snooze.perform()
        var complete = CompleteReminderIntent()
        complete.occurrence = ReminderOccurrence(task: task)
        _ = try await complete.perform()
        XCTAssertEqual(try store.read().reminders.first { $0.id == task.id }, afterSnooze)

        complete.occurrence = ReminderOccurrence(task: afterSnooze)
        _ = try await complete.perform()
        let afterComplete = try XCTUnwrap(store.read().reminders.first { $0.id == task.id })
        XCTAssertNotNil(afterComplete.completedAt)
        _ = try await complete.perform()
        XCTAssertEqual(try store.read().reminders.first { $0.id == task.id }, afterComplete)
    }

    func testSystemDeliveredReminder() async throws {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications()
        let item = try XCTUnwrap(delivered.first { $0.request.identifier == "mycompanion.preview" })
        XCTAssertEqual(item.request.content.body, "Время для небольшой передышки.")
        let pending = await center.pendingNotificationRequests()
        XCTAssertFalse(pending.contains { $0.identifier == item.request.identifier })
    }

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

        let movedStart = event.startDate.addingTimeInterval(2 * 3600)
        event.startDate = movedStart
        event.endDate = movedStart.addingTimeInterval(1200)
        try store.save(event, span: .thisEvent)
        await service.refresh()
        let movedSnapshot = try Store.shared().read().calendarSnapshot
        XCTAssertFalse(movedSnapshot.events.contains { $0.id == item.id })
        let moved = try XCTUnwrap(movedSnapshot.events.first { $0.title == event.title })
        XCTAssertEqual(moved.start.timeIntervalSince(movedStart), 0, accuracy: 1)

        let allDay = EKEvent(eventStore: store)
        allDay.calendar = event.calendar
        allDay.title = "All-day simulator fixture"
        let today = Calendar.current.startOfDay(for: Date())
        allDay.startDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: today))
        allDay.endDate = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 2, to: today))
        allDay.isAllDay = true
        try store.save(allDay, span: .thisEvent)
        var removed = false
        defer { if !removed { try? store.remove(allDay, span: .thisEvent) } }
        await service.refresh()
        let full = try Store.shared().read().calendarSnapshot
        let day = try XCTUnwrap(full.events.first { $0.title == allDay.title })
        XCTAssertTrue(day.allDay)
        XCTAssertEqual(day.timeLabel, "Весь день")
        try store.remove(allDay, span: .thisEvent)
        removed = true
        await service.refresh()
        let afterDelete = try Store.shared().read().calendarSnapshot
        XCTAssertFalse(afterDelete.events.contains { $0.id == day.id })
        XCTAssertTrue(afterDelete.events.contains { $0.id == moved.id })

        settings.set(false, forKey: "calendarEnabled")
        settings.set(false, forKey: "calendarTitles")
        await service.refresh()
        XCTAssertTrue(try Store.shared().read().calendarSnapshot.events.isEmpty)
        XCTAssertNotNil(store.event(withIdentifier: event.eventIdentifier))
    }
}
