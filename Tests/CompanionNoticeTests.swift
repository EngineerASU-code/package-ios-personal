import Foundation
import XCTest
@testable import CompanionCore

final class CompanionNoticeTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }

    func testOptedInSupportUsesOnlySupportLinesForEveryHero() throws {
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 28))!
        var plan = CompanionNoticePlan(morning: nil, bedtime: nil, quietStart: 23, quietEnd: 7)
        plan.sukunaSarcasm = .mild
        plan.communicationIntensity = .restrained
        for hero in Hero.allCases {
            plan.support = false
            XCTAssertTrue(plan.slots(hero: hero, now: now, calendar: calendar).isEmpty)
            let pack = try XCTUnwrap(hero.pack)
            let support = pack.records.filter { $0.category == "support" && $0.channels.contains("notification") }
            XCTAssertEqual(support.count, 3)
            plan.support = true
            let slots = plan.slots(hero: hero, now: now, calendar: calendar)
            XCTAssertFalse(slots.isEmpty, hero.name)
            XCTAssertTrue(slots.allSatisfy { slot in
                slot.category == "companion.support" && support.contains { $0.shortText == slot.body }
            })
        }
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

    func testBedtimeCannotRepeatAfterMovingAcrossFiveAMAndRollingClockBack() throws {
        let midnight = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let early = CompanionNoticePlan(morning: 8 * 60, bedtime: 90, quietStart: 0, quietEnd: 0)
        var late = early
        late.bedtime = 22 * 60
        var ledger = CompanionNoticeLedger()
        let firstNight = try XCTUnwrap(early.slots(hero: .gojo, now: midnight, calendar: calendar).first)
        ledger.reserve(firstNight, calendar: calendar)
        // Roll the clock back before the first 01:30 in the DST fold after the request left pending.
        let updated = late.slots(hero: .gojo, now: midnight, calendar: calendar)
        XCTAssertNotEqual(firstNight.id, updated.first { $0.category == firstNight.category }?.id)
        let remaining = ledger.reconcile(now: midnight, pending: [], slots: updated, calendar: calendar)
        let today = remaining.filter { calendar.isDate($0.date, inSameDayAs: midnight) }
        XCTAssertEqual(today.map(\.category), ["companion.greeting"])
        ledger.reserve(try XCTUnwrap(today.first), calendar: calendar)
        let later = ledger.reconcile(now: midnight, pending: [], slots: updated, calendar: calendar)
        XCTAssertFalse(later.contains { calendar.isDate($0.date, inSameDayAs: midnight) })
    }

    func testTravelKeepsOriginalAndCurrentCivilDayBudget() throws {
        var utc = calendar
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let before = calendar.date(from: DateComponents(year: 2026, month: 4, day: 2, hour: 21))!
        let original = CompanionNoticePlan(morning: nil, bedtime: 22 * 60, quietStart: 0, quietEnd: 0)
        let oldSlot = try XCTUnwrap(original.slots(hero: .gojo, now: before, calendar: calendar).first)
        var ledger = CompanionNoticeLedger()
        ledger.reserve(oldSlot, calendar: calendar)
        let after = oldSlot.date.addingTimeInterval(60)
        let relocated = CompanionNoticePlan(morning: 480, bedtime: 22 * 60, quietStart: 0, quietEnd: 0)
        let proposed = relocated.slots(hero: .maomao, now: after, calendar: utc)
        let accepted = ledger.reconcile(now: after, pending: [], slots: proposed, calendar: utc)
        XCTAssertEqual(accepted.filter { utc.isDate($0.date, inSameDayAs: after) }.map(\.category), ["companion.greeting"])
        // Back to the original zone, previous date and a different night key.
        let early = CompanionNoticeSlot(id: "companion.bedtime.2026-04-01", category: "companion.bedtime", body: "", date: before)
        XCTAssertTrue(ledger.reconcile(now: before.addingTimeInterval(-3600), pending: [], slots: [early], calendar: calendar).isEmpty)
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
