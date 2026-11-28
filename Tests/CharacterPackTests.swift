import Foundation
import XCTest
@testable import CompanionCore

final class CharacterPackTests: XCTestCase {
    func testNightContactsUseTheSleepyFigureAndRestingActionForEveryHero() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let night = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 23)))
        for hero in Hero.allCases {
            let pack = try XCTUnwrap(hero.pack)
            let rest = try XCTUnwrap(pack.behaviors["nightRest"])
            XCTAssertEqual(rest.to, "resting", hero.name)
            let lines = pack.records.filter { $0.category == "night" }
            XCTAssertEqual(lines.count, 15, hero.name)
            XCTAssertTrue(lines.allSatisfy { $0.behaviorID == "nightRest" && $0.action == rest.label && $0.reaction.emotion == .sleepy }, hero.name)
            XCTAssertFalse(pack.records.contains { $0.category != "night" && $0.behaviorID == "nightRest" })
            var state = Companion()
            state.hero = hero
            state.react(at: night, calendar: calendar)
            let reaction = DayTimeline.display(state, at: night, calendar: calendar, using: pack)
            XCTAssertEqual(reaction.action, rest.label, hero.name)
            XCTAssertEqual(reaction.emotion, .sleepy, hero.name)
        }
    }

    func testFanAndBladeMatchTheSelectedAction() throws {
        let jinshi = try XCTUnwrap(Hero.jinshi.pack)
        let toji = try XCTUnwrap(Hero.toji.pack)
        for surface in [CharacterPack.AnimationDescriptor.Surface.app, .widgetMedium, .widgetLarge] {
            XCTAssertEqual(jinshi.animation(for: surface, reactionID: "notice")?.id, .fan)
            XCTAssertNil(jinshi.animation(for: surface, reactionID: "jinshi_night_007"))
            XCTAssertEqual(toji.animation(for: surface, reactionID: "toji_fushiguro_tap_013")?.id, .spirit)
            XCTAssertNil(toji.animation(for: surface, reactionID: "toji_fushiguro_night_012"))
        }
        XCTAssertEqual(jinshi.byID["notice"]?.action, "Раскрывает веер")
        XCTAssertEqual(toji.byID["toji_fushiguro_tap_013"]?.action, "Достаёт клинок")
    }
    func testBundledPacksAndFinds() throws {
        for hero in Hero.allCases {
            let pack = try XCTUnwrap(hero.pack)
            XCTAssertEqual(pack.records.count, 150)
            XCTAssertEqual(Set(pack.finds.map(\.id)).count, 5)
            var state = Companion()
            state.hero = hero
            let start = Date(timeIntervalSince1970: 100000)
            for index in 0..<5 {
                let date = start.addingTimeInterval(Double(index) * 21600)
                XCTAssertTrue(state.discover(at: date))
                XCTAssertEqual(pack.byID[state.reaction.id]?.category, "rare")
                XCTAssertFalse(state.discover(at: date))
            }
            XCTAssertFalse(state.discover(at: start.addingTimeInterval(6 * 21600)))
            let restored = try JSONDecoder().decode(Companion.self, from: JSONEncoder().encode(state))
            XCTAssertEqual(restored, state)
        }
    }

    func testModesAndIndependentContacts() {
        var state = Companion()
        let date = Date(timeIntervalSince1970: 100000)
        for mode in [CompanionMode.eco, .safe, .paused] {
            state.mode = mode
            XCTAssertFalse(state.discover(at: date))
        }
        state.mode = .normal
        XCTAssertTrue(state.discover(at: date))
        let first = state.contact
        state.hero = .maomao
        XCTAssertNil(state.contact)
        XCTAssertTrue(state.discover(at: date.addingTimeInterval(21600)))
        state.hero = .gojo
        XCTAssertEqual(state.contact, first)
    }
}
