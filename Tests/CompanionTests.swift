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

    func testSceneContextChoosesEachHeroLineOnlyWhileFresh() throws {
        let night = noon.addingTimeInterval(11 * 3600)
        var sunnyLines = Set<String>()
        var bedtimeLines = Set<String>()
        for hero in Hero.allCases {
            var state = Companion()
            state.hero = hero
            let pack = try XCTUnwrap(hero.pack)
            state.sceneWeather = SceneWeather(isSunny: true, observedAt: noon)
            state = try JSONDecoder().decode(Companion.self, from: JSONEncoder().encode(state))
            for channel in ["app", "widget"] {
                let sunny = DayTimeline.display(state, at: noon, calendar: utc, channel: channel, using: pack)
                XCTAssertEqual(sunny.emotion, .happy)
                XCTAssertEqual(sunny.id, "context-sunny")
                sunnyLines.insert(sunny.text)
                let stale = DayTimeline.display(state, at: noon.addingTimeInterval(90 * 60), calendar: utc, channel: channel, using: pack)
                XCTAssertNotEqual(stale.id, sunny.id)
                let bedtime = DayTimeline.display(state, at: night, calendar: utc, channel: channel, using: pack, nightScreenTimeAt: night)
                XCTAssertEqual(bedtime.emotion, .frowning)
                bedtimeLines.insert(bedtime.text)
                for event in [nil, night.addingTimeInterval(-20 * 60), night.addingTimeInterval(1)] as [Date?] {
                    let ordinary = DayTimeline.display(state, at: night, calendar: utc, channel: channel, using: pack, nightScreenTimeAt: event)
                    XCTAssertEqual(ordinary.emotion, .sleepy)
                }
            }
            state.mode = .paused
            XCTAssertNotEqual(DayTimeline.display(state, at: night, calendar: utc, using: pack, nightScreenTimeAt: night).id, "context-bedtime")
        }
        XCTAssertEqual(sunnyLines.count, Hero.allCases.count)
        XCTAssertEqual(bedtimeLines.count, Hero.allCases.count)
        XCTAssertTrue(bedtimeLines.allSatisfy { $0.contains("спать") })
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

    func testHeroIntroductionsAndRapidTapsUseTheirOwnDialogue() throws {
        for hero in Hero.allCases {
            let pack = try XCTUnwrap(hero.pack)
            for opening in [CompanionEvent.Kind.appOpened, .characterSelected] {
                var state = Companion()
                state.hero = hero
                state.mode = .eco
                XCTAssertTrue(state.appContact(opening, at: noon, calendar: utc))
                XCTAssertEqual(state.reaction.id, "intro")
                for source in [CompanionEvent.Source.app, .widgetIntent] {
                    state.react(at: noon.addingTimeInterval(1), calendar: utc, source: source)
                    let reply = try XCTUnwrap(pack.byID[state.reaction.id])
                    XCTAssertTrue(reply.triggers.contains("repeatInteraction"))
                    XCTAssertTrue(reply.channels.contains(source == .app ? "app" : "widget"))
                }
            }
        }
    }

    func testRareObservationsRemainAvailableBetweenCollectibleFinds() throws {
        for hero in Hero.allCases {
            var state = Companion()
            state.hero = hero
            let pack = try XCTUnwrap(hero.pack)
            XCTAssertTrue(state.discover(at: noon))
            var rng = SeededGenerator()
            var observed = Set<String>()
            for index in 1...400 {
                let date = noon.addingTimeInterval(Double(index * 3))
                let event = CompanionEvent(id: UUID(), source: .app, kind: .appInteraction, date: date)
                XCTAssertTrue(state.handle([event], at: date, calendar: utc, using: &rng))
                if pack.byID[state.reaction.id]?.category == "rare" { observed.insert(state.reaction.id) }
            }
            XCTAssertEqual(observed, Set(pack.records.filter { $0.category == "rare" }.map(\.id))
                .subtracting(pack.finds.map(\.lineID)))
            XCTAssertEqual(state.unlocks.count, 1)
        }
    }

    func testSukunaSarcasmAcrossSurfacesAndOldSnapshots() throws {
        let old = Data(#"{"mode":"Обычный","hero":"ryomen_sukuna","histories":{}}"#.utf8)
        let original = try JSONDecoder().decode(Companion.self, from: old)
        XCTAssertEqual(original.sukunaSarcasm, .regular)
        let pack = try XCTUnwrap(original.hero.pack)
        for tone in SukunaSarcasm.allCases {
            var state = original
            state.sukunaSarcasm = tone
            state.mode = .eco
            XCTAssertEqual(try JSONDecoder().decode(Companion.self, from: JSONEncoder().encode(state)), state)
            var rng = SeededGenerator()
            var seen = Set<SukunaSarcasm>()
            for index in 0..<180 {
                let date = noon.addingTimeInterval(Double(index * 3))
                let widget = index.isMultiple(of: 2)
                let event = CompanionEvent(id: UUID(), source: widget ? .widgetIntent : .app,
                                           kind: widget ? .widgetInteraction : .appInteraction, date: date)
                XCTAssertTrue(state.handle([event], at: date, calendar: utc, using: &rng))
                let row = try XCTUnwrap(pack.byID[state.reaction.id])
                XCTAssertTrue(tone.permits(row))
                seen.insert(row.sarcasm ?? .mild)
            }
            XCTAssertEqual(seen.contains(.sharp), tone == .sharp)
            XCTAssertEqual(seen.contains(.regular), tone != .mild)
            state.contact = Contact(hero: .sukuna, date: noon, response: "ryomen_sukuna_tap_014")
            state.mode = .safe
            let saved = DayTimeline.display(state, at: noon, calendar: utc, channel: "widget")
            XCTAssertEqual(saved.id == state.contact?.response, tone == .sharp)

            var plan = CompanionNoticePlan(morning: 480, bedtime: 1365, quietStart: 23, quietEnd: 7)
            plan.sukunaSarcasm = tone
            let allowed = Set(pack.records.filter(tone.permits).map { $0.shortText ?? $0.text })
            let slots = plan.slots(hero: .sukuna, now: noon, calendar: utc)
            XCTAssertFalse(slots.isEmpty)
            XCTAssertTrue(slots.allSatisfy { allowed.contains($0.body) })
            state.resetPreferences()
            XCTAssertEqual(state.sukunaSarcasm, .regular)
        }
        for hero in Hero.allCases where hero != .sukuna {
            XCTAssertTrue(try XCTUnwrap(hero.pack).records.allSatisfy { $0.sarcasm == nil })
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
        let correctedClock = later.addingTimeInterval(-60)
        let pause = CompanionEvent(id: UUID(), source: .app, kind: .pauseChanged,
                                   date: correctedClock, newMode: .paused)
        XCTAssertFalse(state.handle([pause], at: correctedClock.addingTimeInterval(1), calendar: utc, using: &rng))
        XCTAssertEqual(state.mode, .paused)
        XCTAssertEqual(state.contact, before)
    }

    func testResumeRestoresPersistedModeAndSupportsLegacyPausedSnapshot() throws {
        for previous in [CompanionMode.normal, .eco, .safe] {
            var state = Companion()
            state.setMode(previous, at: noon)
            state.reminders = [LocalReminder(title: "Оставить задачу")]
            state.setMode(.paused, at: noon)
            state.setMode(.paused, at: noon)
            let data = try JSONEncoder().encode(state)
            var restored = try JSONDecoder().decode(Companion.self, from: data)
            restored.resume(at: noon)
            XCTAssertEqual(restored.mode, previous)
            XCTAssertEqual(restored.reminders, state.reminders)
            let resumed = restored
            restored.resume(at: noon)
            XCTAssertEqual(restored, resumed)
        }
        var legacy = Companion()
        legacy.mode = .paused
        var restored = try JSONDecoder().decode(Companion.self, from: JSONEncoder().encode(legacy))
        restored.resume(at: noon)
        XCTAssertEqual(restored.mode, .normal)
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
            XCTAssertEqual(state.reaction.id, "notice")
            XCTAssertEqual(state.reaction.text, try XCTUnwrap(Hero.gojo.pack?.byID["notice"]?.text))
            let before = state
            state.react()
            XCTAssertEqual(state, before)
        }
    }
}
