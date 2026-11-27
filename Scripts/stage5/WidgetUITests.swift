import XCTest
import UIKit

final class WidgetUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "local.mycompanion")
    let home = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    func testSelectedJinwooAppearsAndAnswersOnHomeScreen() throws {
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
        XCTAssertTrue(reaction.exists)
        XCTAssertTrue(reaction.label.contains(heroName))
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

    func testZInstallLockAccessory() throws {
        continueAfterFailure = true
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let gallery = XCUIApplication(bundleIdentifier: "com.apple.PosterBoard")
        let surfaces = [settings, gallery, home]

        defer {
            capture("lock-accessory-final-state")
            for surface in surfaces where surface.state != .notRunning {
                let tree = XCTAttachment(string: surface.debugDescription)
                tree.name = "Lock accessory accessibility tree " + surface.label
                tree.lifetime = .keepAlways
                add(tree)
            }
        }

        func find(_ titles: [String], timeout: TimeInterval = 6) -> XCUIElement? {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                for surface in surfaces where surface.state != .notRunning {
                    let matches = surface.descendants(matching: .any)
                        .matching(NSPredicate(format: "label IN %@", titles))
                        .allElementsBoundByIndex.filter { $0.isHittable }
                    if let first = matches.sorted(by: { $0.frame.minX < $1.frame.minX }).first {
                        return first
                    }
                }
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            } while Date() < deadline
            return nil
        }

        settings.launch()
        for _ in 0..<5 {
            if find(["Wallpaper"], timeout: 0.5) != nil { break }
            settings.swipeUp()
        }
        try XCTUnwrap(find(["Wallpaper"]), "Wallpaper settings").tap()
        // The left Customize control belongs to the Lock Screen of the current pair.
        try XCTUnwrap(find(["Customize", "Customize Lock Screen"]), "Lock Screen Customize").tap()
        if let lock = find(["Lock Screen"], timeout: 1), find(["Add Widgets", "Add Widgets to Lock Screen"], timeout: 0.5) == nil {
            lock.tap()
        }
        capture("lock-accessory-editor")
        try XCTUnwrap(find(["Add Widgets", "Add Widgets to Lock Screen"]), "Empty widget row").tap()
        for _ in 0..<6 {
            if find(["Мой Компаньон"], timeout: 0.5) != nil { break }
            guard let sheet = find(["Add Widgets"]) else { break }
            let start = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
                .withOffset(CGVector(dx: 0, dy: 220))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -155)))
        }
        try XCTUnwrap(find(["Мой Компаньон"]), "Companion widget in gallery").tap()
        capture("lock-accessory-gallery")
        let preview = try XCTUnwrap(find(["Мой Компаньон", "Компаньон"]).flatMap { element in
            surfaces.filter { $0.state != .notRunning }.flatMap {
                $0.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "widget", "виджет")).allElementsBoundByIndex
            }.first { $0.isHittable && $0.frame.width >= 45 && $0.frame.height >= 45 && $0.frame.height <= 110 && $0.frame.midY > element.frame.minY }
        }, "Accessory preview in provider sheet")
        preview.tap()
        for _ in 0..<2 {
            if let close = find(["Close", "Close Add Widgets"], timeout: 2) { close.tap() }
        }
        let placed = find(["Remove Widget", "Remove Мой Компаньон", "Мой Компаньон", "Сон Джин Ву", "Мао Мао"], timeout: 5)
        _ = try XCTUnwrap(placed, "Companion or its removal control in the edited Lock Screen row")
        capture("lock-accessory-configured")
        try XCTUnwrap(find(["Done"]), "Save Lock Screen").tap()
        XCTAssertNotNil(find(["Customize", "Customize Lock Screen"]), "Returned to saved wallpaper pair")
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
