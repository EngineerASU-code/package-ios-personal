import Foundation
import XCTest
@testable import CompanionCore

final class DayTimelineTests: XCTestCase {
    private func calendar(_ zone: String) throws -> Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
        return result
    }

    func testPassiveDialogueUsesOnlyConfirmedFactsAndKeepsReminderTitlesPrivate() throws {
        let cal = try calendar("UTC")
        let start = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-29T09:00:00Z"))
        for hero in Hero.allCases {
            var state = Companion()
            state.hero = hero
            var task = LocalReminder()
            task.title = "confidential-title"
            task.createdAt = start.addingTimeInterval(-7200)
            task.dueAt = start.addingTimeInterval(-60)
            state.reminders = [task]
            var categories = Set<String>()
            for offset in 0..<9 {
                let date = start.addingTimeInterval(Double(offset * 3600))
                let line = DayTimeline.display(state, at: date, calendar: cal)
                let record = try XCTUnwrap(hero.pack?.byID[line.id])
                categories.insert(record.category)
                XCTAssertFalse(line.text.contains(task.title))
                XCTAssertEqual(line.id, DayTimeline.display(state, at: date.addingTimeInterval(30), calendar: cal).id)
                if record.category == "reminder" {
                    XCTAssertTrue(record.triggers.contains("reminderDue"))
                    let hidden = DayTimeline.display(state, at: date, calendar: cal, showsTask: false)
                    XCTAssertNotEqual(hero.pack?.byID[hidden.id]?.category, "reminder")
                    for variant in 0..<5 {
                        var other = state
                        switch variant {
                        case 0: other.reminders = []
                        case 1: other.reminders[0].completedAt = start
                        case 2: other.reminders[0].snoozedUntil = date.addingTimeInterval(600)
                        case 3: other.reminders[0].dueAt = nil
                        default: other.reminders[0].createdAt = date.addingTimeInterval(600)
                        }
                        let response = DayTimeline.display(other, at: date, calendar: cal)
                        XCTAssertNotEqual(hero.pack?.byID[response.id]?.category, "reminder")
                    }
                }
            }
            XCTAssertEqual(categories, ["day", "compliment", "reminder"])
            for mode in [CompanionMode.safe, .paused] {
                state.mode = mode
                XCTAssertEqual(DayTimeline.display(state, at: start, calendar: cal).id, state.reaction.id)
            }
        }
    }

    func testThirtyVirtualDaysOfTimelineAndOneHundredInteractions() throws {
        let cal = try calendar("America/New_York")
        let start = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 13)))
        let heroes = Hero.allCases
        var state = Companion()
        let reminder = LocalReminder(title: "Закрытая задача")
        state.reminders = [reminder]
        for index in 0..<100 {
            state.hero = heroes[(index + 1) % heroes.count]
            let when = start.addingTimeInterval(Double(index * 8))
            state.react(at: when, calendar: cal)
            XCTAssertEqual(state.contact?.date, when)
            XCTAssertEqual(state.contact?.hero, state.hero)
            state = try JSONDecoder().decode(Companion.self, from: JSONEncoder().encode(state))
            XCTAssertEqual(state.reminders, [reminder])
        }
        let plan = CompanionNoticePlan(morning: 480, bedtime: 1365, quietStart: 23, quietEnd: 7)
        for day in 0..<30 {
            let date = try XCTUnwrap(cal.date(byAdding: .day, value: day, to: start))
            for mode in CompanionMode.allCases {
                state.mode = mode
                let original = state
                let dates = DayTimeline.dates(from: date, state: state, calendar: cal)
                XCTAssertEqual(dates, Array(Set(dates)).sorted())
                XCTAssertEqual(dates.first, date)
                XCTAssertLessThanOrEqual(dates.count, 15)
                XCTAssertLessThanOrEqual(try XCTUnwrap(dates.last).timeIntervalSince(date), 12 * 3600)
                if mode == .safe || mode == .paused { XCTAssertEqual(dates, [date]) }
                for frame in dates {
                    XCTAssertFalse(DayTimeline.display(state, at: frame, calendar: cal).text.contains(reminder.title))
                }
                XCTAssertEqual(state, original)
            }
            let slots = plan.slots(hero: state.hero, now: date, calendar: cal)
            XCTAssertLessThanOrEqual(slots.count, 6)
            XCTAssertEqual(Set(slots.map(\.id)).count, slots.count)
        }
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
        // Passive frames never dispatch scheduledGreeting (§16). Only real contact consumes it.
        for offset in 0..<13 {
            let frame = DayTimeline.display(state, at: dawn.addingTimeInterval(Double(offset * 3600)), calendar: cal)
            let record = try XCTUnwrap(state.hero.pack?.byID[frame.id])
            XCTAssertNotEqual(record.category, "morning")
        }
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
