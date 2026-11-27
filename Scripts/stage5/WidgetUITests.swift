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

    func testTwoSmallWidgets() throws {
        continueAfterFailure = false
        app.launch()
        XCUIDevice.shared.press(.home)
        let firstIcon = home.icons["Мой Компаньон"].firstMatch
        XCTAssertTrue(firstIcon.waitForExistence(timeout: 10))
        if firstIcon.frame.width > 210 {
            firstIcon.press(forDuration: 1.4)
            home.buttons["Small widget"].tap()
            let resized = XCTNSPredicateExpectation(predicate: NSPredicate(format: "frame.size.width < 210"), object: firstIcon)
            XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 8), .completed)
        }
        firstIcon.press(forDuration: 1.4)
        let edit = home.buttons["Edit Home Screen"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let menu = home.buttons["Edit"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        home.buttons["Add Widget"].tap()
        print("GALLERY " + home.debugDescription)
        let search = home.searchFields.matching(NSPredicate(format: "identifier != %@ AND placeholderValue != %@", "dewey-search-field", "App Library")).firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 8), home.debugDescription)
        search.tap()
        search.typeText("Мой Компаньон")
        let result = home.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Мой Компаньон")).allElementsBoundByIndex.filter { $0.isHittable && $0.elementType != .searchField }
        let tile = try XCTUnwrap(result.last)
        tile.tap()
        let add = home.buttons["Add Widget"]
        XCTAssertTrue(add.waitForExistence(timeout: 6))
        add.tap()
        let done = home.buttons["Done"]
        if done.waitForExistence(timeout: 5) { done.tap() }
        let widgets = home.icons.matching(NSPredicate(format: "label CONTAINS %@", "Мой Компаньон"))
        let installed = widgets.allElementsBoundByIndex.filter { $0.frame.width > 130 }
        XCTAssertEqual(installed.count, 2, home.debugDescription)
        // Resize the existing large widget after adding the second instance.
        for item in installed where item.frame.width > 210 {
            item.press(forDuration: 1.4)
            home.buttons["Small widget"].tap()
        }
        let small = widgets.allElementsBoundByIndex.filter { $0.frame.width > 130 && $0.frame.width < 210 }
        XCTAssertEqual(small.count, 2, home.debugDescription)
        let second = small[1]
        second.press(forDuration: 1.4)
        home.buttons["Edit Widget"].tap()
        let picker = home.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Как в приложении")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), home.debugDescription)
        picker.tap()
        home.staticTexts["Мао Мао"].firstMatch.tap()
        home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
        let jinwoo = home.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Сон Джин Ву")).firstMatch
        let maomao = home.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Мао Мао")).firstMatch
        XCTAssertTrue(jinwoo.waitForExistence(timeout: 12))
        XCTAssertTrue(maomao.waitForExistence(timeout: 12))
        XCTAssertLessThan(abs(jinwoo.frame.midY - maomao.frame.midY), 30)
        capture("two-small-before")
        let other = maomao.label
        let original = jinwoo.label
        jinwoo.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", original), object: jinwoo)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 15), .completed)
        XCTAssertEqual(maomao.label, other)
        capture("two-small-after")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
