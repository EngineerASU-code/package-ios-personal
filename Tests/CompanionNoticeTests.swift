import Foundation
import XCTest
@testable import CompanionCore

final class CompanionNoticeTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }

    func testBudgetOptInQuietAndStableContent() {
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 27))!
        var plan = CompanionNoticePlan(morning: nil, bedtime: nil, quietStart: 23, quietEnd: 7)
        XCTAssertTrue(plan.slots(hero: .gojo, now: now, calendar: calendar).isEmpty)
        plan.morning = 480
        plan.bedtime = 1365
        for hero in Hero.allCases {
            let slots = plan.slots(hero: hero, now: now, calendar: calendar)
            XCTAssertEqual(slots.count, 6)
            XCTAssertEqual(Set(slots.map(\.id)).count, 6)
            XCTAssertEqual(slots, plan.slots(hero: hero, now: now, calendar: calendar))
        }
        plan.bedtime = 23 * 60
        XCTAssertEqual(plan.slots(hero: .gojo, now: now, calendar: calendar).count, 3)
        plan.morning = 6 * 60
        XCTAssertTrue(plan.slots(hero: .gojo, now: now, calendar: calendar).isEmpty)
    }

    func testAfterMidnightNightIdentityAndDST() {
        let plan = CompanionNoticePlan(morning: nil, bedtime: 150, quietStart: 0, quietEnd: 0)
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7))!
        let slots = plan.slots(hero: .gojo, now: now, calendar: calendar)
        // 02:30 on March 8 does not exist in New York.
        XCTAssertEqual(slots.map(\.id), ["companion.bedtime.2026-03-06", "companion.bedtime.2026-03-08"])
        let autumn = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let repeatPlan = CompanionNoticePlan(morning: nil, bedtime: 90, quietStart: 0, quietEnd: 0)
        let repeatSlots = repeatPlan.slots(hero: .gojo, now: autumn, calendar: calendar)
        XCTAssertEqual(repeatSlots.count, 3)
        XCTAssertEqual(repeatSlots.first?.date.timeIntervalSince(autumn), 5400)
    }

    func testChannelTriggerConditionsAndWeights() throws {
        func row(_ id: String, weight: Int, channel: String = "notification", trigger: String = "scheduledGreeting",
                 requires: [String] = []) -> CharacterPack.Record {
            CharacterPack.Record(id: id, text: id, category: "morning", action: "", triggers: [trigger],
                                 channels: [channel], requires: requires, weight: weight, shortText: nil)
        }
        let rows = [row("a", weight: 1), row("b", weight: 3), row("app", weight: 10, channel: "app"),
                    row("wrong", weight: 10, trigger: "lateInteraction"), row("condition", weight: 1, requires: ["fact"])]
        func select(_ slot: UInt64, _ facts: Set<String> = []) -> String? {
            CharacterPack.notificationLine(in: rows, trigger: "scheduledGreeting", facts: facts, slot: slot)?.id
        }
        XCTAssertEqual((0..<4).map { select(UInt64($0)) }, ["a","b","b","b"])
        XCTAssertEqual(select(4, ["fact"]), "condition")
        XCTAssertFalse(CompanionNoticeSlot.owns("companion.reminder.123"))
    }
}
