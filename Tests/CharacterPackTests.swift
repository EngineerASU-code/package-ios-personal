import Foundation
import XCTest
@testable import CompanionCore

final class CharacterPackTests: XCTestCase {
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
