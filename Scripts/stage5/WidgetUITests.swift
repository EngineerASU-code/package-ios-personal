import XCTest

final class WidgetUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "local.mycompanion")
    let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testMediumWidgetReactionAndSafeFallback() throws {
        app.launch()
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Сатору Годжо")).allElementsBoundByIndex.last?.tap()
        let hero = app.buttons["Мао Мао"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        hero.tap()
        XCUIDevice.shared.press(.home)
        let icon = home.icons["Мой Компаньон"]
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        icon.press(forDuration: 1.5)
        home.buttons["Edit Home Screen"].tap()
        let edit = home.buttons["Edit"]
        if edit.exists { edit.tap() }
        let add = home.buttons.matching(NSPredicate(format: "label IN %@", ["Add Widget", "Add Widgets", "Add"])).first
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let search = home.searchFields.first
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Мой Компаньон")
        let result = home.staticTexts["Мой Компаньон"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        result.tap()
        home.swipeLeft()
        home.buttons["Add Widget"].firstMatch.tap()
        let done = home.buttons["Done"]
        if done.waitForExistence(timeout: 3) { done.tap() }

        let reaction = home.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Мао Мао")).firstMatch
        XCTAssertTrue(reaction.waitForExistence(timeout: 15))
        capture("medium-before")
        let before = reaction.label
        reaction.tap()
        let changed = NSPredicate(format: "exists == true AND label != %@", before)
        let update = XCTNSPredicateExpectation(predicate: changed, object: reaction)
        XCTAssertEqual(XCTWaiter.wait(for: [update], timeout: 15), .completed)
        capture("medium-after")

        app.activate()
        app.buttons.containing(NSPredicate(format: "label CONTAINS %@", "Обычный")).firstMatch.tap()
        app.buttons["Безопасный"].tap()
        XCUIDevice.shared.press(.home)
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: reaction)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 15), .completed)
        XCTAssertTrue(home.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Мао Мао")).firstMatch.exists)
        capture("safe-static")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
