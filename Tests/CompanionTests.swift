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
            let window = min(15, hero.dialogue.count - 1)
            for _ in 0..<80 {
                state.react(using: &rng)
                XCTAssertFalse(recent.suffix(window).contains(state.reaction.id))
                recent.append(state.reaction.id)
            }
        }
    }

    func testSwitchAndRestoreKeepIndependentHistory() throws {
        var state = Companion()
        var rng = SeededGenerator()
        state.react(using: &rng)
        let first = state
        state.hero = .maomao
        state.react(using: &rng)
        let restored = try JSONDecoder().decode(Companion.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(state, restored)
        state = restored
        state.hero = .gojo
        XCTAssertEqual(state.reaction.id, first.reaction.id)
        state.react(using: &rng)
        XCTAssertNotEqual(state.reaction.id, first.reaction.id)
        XCTAssertNotEqual(state.reaction.id, Hero.gojo.dialogue[0].id)
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
