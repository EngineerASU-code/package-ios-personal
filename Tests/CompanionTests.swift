import Foundation
import XCTest
@testable import CompanionCore

private struct SeededGenerator: RandomNumberGenerator {
    var seed: UInt64 = 42
    mutating func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed
    }
}

final class CompanionTests: XCTestCase {
    private let noon = Date(timeIntervalSince1970: 43200)
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func tap(_ state: inout Companion, using rng: inout SeededGenerator) {
        let last = state.contact?.date ?? noon
        let date = last.addingTimeInterval(3)
        let event = CompanionEvent(id: UUID(), source: .app, kind: .appInteraction, date: date)
        XCTAssertTrue(state.handle([event], at: date, calendar: utc, using: &rng))
    }

    func testPortalSideSurvivesReloadAndIsIndependentPerHero() throws {
        var state = Companion()
        for hero in [Hero.jinwoo, .maomao] {
            state.hero = hero
            XCTAssertNil(state.contact?.portalOnRight)
            state.react()
            XCTAssertEqual(state.contact?.portalOnRight, true)
        }
        state = try JSONDecoder().decode(Companion.self, from: JSONEncoder().encode(state))
        state.react()
        XCTAssertEqual(state.contact?.portalOnRight, false)
        state.hero = .jinwoo
        XCTAssertEqual(state.contact?.portalOnRight, true)
        state.mode = .safe
        state.react()
        XCTAssertEqual(state.contact?.portalOnRight, true)
    }

    func testRecentLinesExcludedForEveryHero() {
        for hero in Hero.allCases {
            var state = Companion()
            state.hero = hero
            var rng = SeededGenerator()
            var recent = [state.reaction.id]
            state.mode = .eco
            let window = min(15, hero.dialogue.count - 1)
            for _ in 0..<80 {
                tap(&state, using: &rng)
                XCTAssertFalse(recent.suffix(window).contains(state.reaction.id))
                recent.append(state.reaction.id)
            }
        }
    }

    func testSwitchAndRestoreKeepIndependentHistory() throws {
        var state = Companion()
        var rng = SeededGenerator()
        tap(&state, using: &rng)
        let first = state
        state.hero = .maomao
        tap(&state, using: &rng)
        let restored = try JSONDecoder().decode(Companion.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(state, restored)
        state = restored
        state.hero = .gojo
        XCTAssertEqual(state.reaction.id, first.reaction.id)
        tap(&state, using: &rng)
        XCTAssertNotEqual(state.reaction.id, first.reaction.id)
        XCTAssertNotEqual(state.reaction.id, Hero.gojo.dialogue[0].id)
    }

    func testEventRoundTripRecoveryAndReplayForEveryHero() throws {
        for hero in Hero.allCases {
            var state = Companion()
            state.hero = hero
            state.mode = .eco
            var rng = SeededGenerator()
            let pack = try XCTUnwrap(hero.pack)
            XCTAssertEqual(state.activity(at: noon).mood, pack.disposition.defaultMood)
            let event = CompanionEvent(id: UUID(), source: .widgetIntent, kind: .widgetInteraction, date: noon)
            let low = CompanionEvent(id: UUID(), source: .localSchedule, kind: .randomSlot, date: noon)
            XCTAssertTrue(state.handle([low, event], at: noon, calendar: utc, using: &rng))
            let row = try XCTUnwrap(pack.byID[state.reaction.id])
            XCTAssertTrue(row.channels.contains("widget"))
            XCTAssertTrue(row.triggers.contains("widgetInteraction"))
            let action = try XCTUnwrap(row.behaviorID.flatMap { pack.behaviors[$0] })
            XCTAssertEqual(state.reaction.action, action.label)
            XCTAssertEqual(state.activity(at: noon).behavior, action.to)
            XCTAssertEqual(state.activity(at: noon).lastSource, .widgetIntent)
            let restored = try JSONDecoder().decode(Companion.self, from: JSONEncoder().encode(state))
            XCTAssertEqual(restored, state)
            XCTAssertFalse(state.handle([low, event], at: noon, calendar: utc, using: &rng))
            XCTAssertEqual(restored, state)
            let stale = CompanionEvent(id: UUID(), source: .app, kind: .appOpened, date: noon)
            XCTAssertFalse(state.handle([stale], at: noon.addingTimeInterval(300), calendar: utc, using: &rng))
            XCTAssertEqual(restored, state)
            let recovered = state.activity(at: noon.addingTimeInterval(31_536_000))
            XCTAssertEqual(recovered.mood, pack.disposition.defaultMood)
            XCTAssertEqual(recovered.behavior, "idle")
            XCTAssertEqual(recovered.energy, 70)
            XCTAssertEqual(recovered.curiosity, 50)
            XCTAssertEqual(state.activity(at: noon.addingTimeInterval(-30)), state.activity(at: noon))
        }
    }

    func testFastTapsStayBoundedAndPausedTasksSurvive() {
        var state = Companion()
        state.mode = .eco
        var rng = SeededGenerator()
        for index in 0..<120 {
            let date = noon.addingTimeInterval(Double(index) / 10)
            let event = CompanionEvent(id: UUID(), source: .app, kind: .appInteraction, date: date)
            XCTAssertTrue(state.handle([event], at: date, calendar: utc, using: &rng))
        }
        let active = state.activity(at: noon.addingTimeInterval(12))
        XCTAssertEqual(active.lastKind, .repeatInteraction)
        XCTAssertEqual(active.energy, 0)
        XCTAssertEqual(active.affinity, 100)
        XCTAssertEqual(active.irritation, 20)
        XCTAssertEqual(active.curiosity, 100)
        state.mode = .paused
        state.reminders = [LocalReminder(title: "Сохранить задачу")]
        state.reminders[0].complete(at: noon)
        let before = state
        state.respond(to: .reminderCompleted, at: noon)
        XCTAssertEqual(before, state)
        XCTAssertEqual(state.reminders[0].completedAt, noon)
    }

    func testModePriorityAndRealReturnContact() throws {
        var state = Companion()
        var rng = SeededGenerator()
        let tap = CompanionEvent(id: UUID(), source: .widgetIntent, kind: .widgetInteraction, date: noon)
        let stop = CompanionEvent(id: UUID(), source: .app, kind: .pauseChanged, date: noon, newMode: .paused)
        XCTAssertFalse(state.handle([tap, stop], at: noon, calendar: utc, using: &rng))
        XCTAssertNil(state.contact)
        XCTAssertEqual(state.mode, .paused)
        state.setMode(.eco, at: noon)
        XCTAssertFalse(state.handle([tap], at: noon, calendar: utc, using: &rng))
        XCTAssertTrue(state.appContact(.appOpened, at: noon, calendar: utc))
        XCTAssertFalse(state.appContact(.foregrounded, at: noon, calendar: utc))
        let later = noon.addingTimeInterval(3 * 86400)
        XCTAssertTrue(state.appContact(.foregrounded, at: later, calendar: utc))
        XCTAssertEqual(state.hero.pack?.byID[state.reaction.id]?.category, "return")
        let before = state.contact
        state.respond(to: .calendarChanged, at: later.addingTimeInterval(5), source: .calendarSnapshot)
        XCTAssertEqual(state.contact, before)
        let expired = CompanionEvent(id: UUID(), source: .localSchedule, kind: .reminderDue, date: later.addingTimeInterval(-20))
        XCTAssertFalse(state.handle([expired], at: later.addingTimeInterval(5), calendar: utc, using: &rng))
        XCTAssertEqual(state.contact, before)
    }

    func testBehaviorConditionsAndDialogueFilters() throws {
        let json = #"{"id":"test","label":"test","from":"idle","to":"working","channels":["widget"],"requires":["fact"],"triggers":["randomSlot"],"weight":2,"priority":3,"cooldownSeconds":60}"#
        let action = try JSONDecoder().decode(CharacterPack.Behavior.self, from: Data(json.utf8))
        func permits(_ state: String, _ used: Date?) -> Bool {
            action.permits(state: state, trigger: "randomSlot", channel: "widget", facts: ["fact"], date: noon, lastUsed: used)
        }
        XCTAssertTrue(permits("idle", noon.addingTimeInterval(-60)))
        XCTAssertFalse(permits("working", nil))
        XCTAssertFalse(permits("idle", noon.addingTimeInterval(-59)))
        var row = CharacterPack.Record(id: "one", text: "one", category: "day", action: "", triggers: ["randomSlot"],
                                       channels: ["widget"], requires: ["fact"], weight: 1, shortText: nil)
        row.emotions = ["curious"]
        row.intensity = "gentle"
        func eligible(_ mood: String?, _ intensity: String) -> Bool {
            row.eligible(trigger: "randomSlot", channel: "widget", facts: ["fact"], mood: mood, intensity: intensity, period: .day)
        }
        XCTAssertTrue(eligible("curious", "gentle"))
        XCTAssertFalse(eligible(nil, "gentle"))
        XCTAssertFalse(eligible("curious", "strong"))
        row.variables = ["pendingTasks"]
        XCTAssertFalse(eligible("curious", "gentle"))
        XCTAssertTrue(row.eligible(trigger: "randomSlot", channel: "widget", facts: ["fact"], mood: "curious",
                                   intensity: "gentle", period: .day, substitutions: ["pendingTasks": "2"]))
        XCTAssertEqual(row.rendered("Задач: {pendingTasks}", using: ["pendingTasks": "2"]), "Задач: 2")
        XCTAssertNil(row.rendered("{reminderTitle}", using: [:]))
    }

    func testLegacySnapshotAndStaticModes() throws {
        for mode in [CompanionMode.safe, .paused] {
            let bytes = try JSONSerialization.data(withJSONObject: ["mode": mode.rawValue, "line": 2])
            var state = try JSONDecoder().decode(Companion.self, from: bytes)
            XCTAssertEqual(state.hero, .gojo)
            XCTAssertEqual(state.reaction.text, "Один шаг сделан. Следующий подождёт.")
            let before = state
            state.react()
            XCTAssertEqual(state, before)
        }
    }
}
