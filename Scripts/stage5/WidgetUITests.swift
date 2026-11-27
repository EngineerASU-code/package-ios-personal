import XCTest
import UIKit

final class WidgetUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "local.mycompanion")
    let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testMediumWidgetReactionAndSafeFallback() throws {
        try exerciseHomeWidget(heroName: "Сон Джин Ву")
    }

    private func exerciseHomeWidget(heroName: String) throws {
        continueAfterFailure = false
        app.launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Сатору Годжо")).allElementsBoundByIndex.last?.tap()
        let hero = app.buttons[heroName]
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
        let reaction = home.buttons.matching(NSPredicate(format: "label CONTAINS %@", heroName)).firstMatch
        let target = reaction.waitForExistence(timeout: 8) ? reaction : widget
        capture("medium-before")
        print("HOME BEFORE " + home.debugDescription)
        XCTAssertTrue(target.exists && target.frame.width > 130)
        let oldLabel = reaction.label
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.44)).tap()
        // Wait for the system transition and the asynchronous AppIntent reload.
        Thread.sleep(forTimeInterval: 4)
        capture("medium-after")
        XCTAssertNotEqual(reaction.label, oldLabel)
        app.activate()
        app.tabBars.buttons["Настройки"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Обычный")).firstMatch.tap()
        app.buttons["Безопасный"].tap()
        capture("app-state")
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 4)
        capture("safe-static")
        XCTAssertFalse(reaction.exists)
        XCTAssertTrue(home.staticTexts[heroName].firstMatch.exists)

        // Return to Normal, then verify the other two Home Screen sizes.
        app.activate()
        app.tabBars.buttons["Настройки"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Безопасный")).firstMatch.tap()
        app.buttons["Обычный"].tap()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(reaction.waitForExistence(timeout: 20))
        for name in ["small", "large"] {
            let current = home.icons["Мой Компаньон"].firstMatch
            XCTAssertTrue(current.waitForExistence(timeout: 10))
            current.press(forDuration: 1.3)
            let size = home.buttons[name.capitalized + " widget"]
            XCTAssertTrue(size.waitForExistence(timeout: 5))
            size.tap()
            Thread.sleep(forTimeInterval: 3)
            capture("home-" + name)
            XCTAssertTrue(current.exists)
            if name == "small" { XCTAssertLessThan(current.frame.width, 210) }
            else {
                XCTAssertGreaterThan(current.frame.height, 300)
                XCTAssertTrue(reaction.waitForExistence(timeout: 10))
                let before = reaction.label
                let talk = home.buttons["Поговорить"]
                XCTAssertTrue(talk.waitForExistence(timeout: 8))
                talk.tap()
                let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", before), object: reaction)
                XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15), .completed)
                capture("large-after")
                for (title, screen) in [("Календарь", "Календарь"), ("Задачи", "Напоминания")] {
                    let shortcut = home.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
                    XCTAssertTrue(shortcut.waitForExistence(timeout: 8))
                    shortcut.tap()
                    XCTAssertTrue(app.navigationBars[screen].waitForExistence(timeout: 10))
                    capture("widget-" + screen)
                    XCUIDevice.shared.press(.home)
                }
            }
        }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
