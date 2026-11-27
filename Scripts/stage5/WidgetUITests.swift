import XCTest
import UIKit

final class WidgetUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "local.mycompanion")
    let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testMediumWidgetReactionAndSafeFallback() throws {
        continueAfterFailure = false
        app.launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Сатору Годжо")).allElementsBoundByIndex.last?.tap()
        let hero = app.buttons["Мао Мао"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        hero.tap()
        capture("app-state")
        XCUIDevice.shared.press(.home)
        let icon = home.icons["Мой Компаньон"]
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        icon.press(forDuration: 1.5)
        // iOS 18 offers small, medium and large sizes directly above Edit Home Screen.
        let edit = home.buttons["Edit Home Screen"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        let medium = edit.coordinate(withNormalizedOffset: CGVector(dx: 0.625, dy: 0.5))
            .withOffset(CGVector(dx: 0, dy: -50))
        medium.tap()
        let done = home.buttons["Done"]
        if done.waitForExistence(timeout: 3) { done.tap() }

        // SpringBoard exposes third-party widgets as a single icon on some runtimes.
        let widget = home.icons.matching(NSPredicate(format: "label CONTAINS %@", "Мой Компаньон")).firstMatch
        let reaction = home.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Мао Мао")).firstMatch
        let target = reaction.waitForExistence(timeout: 8) ? reaction : widget
        capture("medium-before")
        print("HOME BEFORE " + home.debugDescription)
        XCTAssertTrue(target.exists && target.frame.width > 130)
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.44)).tap()
        // Wait for the system transition and the asynchronous AppIntent reload.
        Thread.sleep(forTimeInterval: 4)
        capture("medium-after")
        print("HOME AFTER " + home.debugDescription)
        app.activate()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Обычный")).firstMatch.tap()
        app.buttons["Безопасный"].tap()
        capture("app-state")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 4)
        capture("safe-static")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
