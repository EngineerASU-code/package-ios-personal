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
        let hero = app.buttons["select-hero-sung_jinwoo"]
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        if !hero.isHittable { app.scrollViews["hero-strip"].swipeLeft() }
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
        let mediumButton = home.buttons["Medium widget"]
        if mediumButton.exists { mediumButton.tap() } else { medium.tap() }
        let done = home.buttons["Done"]
        if done.waitForExistence(timeout: 3) { done.tap() }

        // SpringBoard exposes third-party widgets as a single icon on some runtimes.
        let widget = home.icons.matching(NSPredicate(format: "label CONTAINS %@", "Мой Компаньон")).firstMatch
        let reaction = home.buttons.matching(NSPredicate(format: "label CONTAINS %@", heroName)).firstMatch
        let hasReactionLabel = reaction.waitForExistence(timeout: 8)
        capture("medium-before")
        XCTAssertTrue(widget.exists && widget.frame.width > 130)
        let oldLabel = hasReactionLabel ? reaction.label : nil
        let oldWidget = oldLabel == nil ? widget.screenshot().pngRepresentation : nil
        widget.coordinate(withNormalizedOffset: CGVector(dx: 0.48, dy: 0.44)).tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if let oldLabel {
                return reaction.exists && reaction.label.contains(heroName) && reaction.label != oldLabel
            }
            return widget.exists && widget.frame.width > 130 && widget.screenshot().pngRepresentation != oldWidget
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 20), .completed)
        capture("medium-after")
        app.activate()
        if !app.navigationBars["Настройки"].exists {
            app.tabBars.buttons["Компаньон"].tap()
            let settings = app.buttons["open-settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 8))
            settings.tap()
        }
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
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 8))
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

    func testTwoHomeWidgetsKeepIndependentHeroesAndReplies() throws {
        continueAfterFailure = false
        let primary = "Сон Джин Ву"
        let fixed = "Мао Мао"

        func selectPrimary(_ name: String) {
            app.activate()
            app.tabBars.buttons["Компаньон"].tap()
            let characters = app.buttons["open-characters"]
            XCTAssertTrue(characters.waitForExistence(timeout: 8))
            characters.tap()
            let hero = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
            XCTAssertTrue(hero.waitForExistence(timeout: 8))
            hero.tap()
            let select = app.buttons["Выбрать"]
            if select.exists { select.tap() }
            XCTAssertTrue(app.buttons["Выбран"].waitForExistence(timeout: 8))
            app.navigationBars[name].buttons.firstMatch.tap()
            app.navigationBars["Персонажи"].buttons.firstMatch.tap()
            XCUIDevice.shared.press(.home)
        }
        func control(_ label: String) -> XCUIElement {
            home.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
        }
        func addSmallWidget(expectedHero: String) throws {
            // Long-press the page indicator area, away from other widgets.
            home.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.84)).press(forDuration: 1.5)
            let edit = home.buttons["Edit"]
            if !edit.waitForExistence(timeout: 2), control("Edit Home Screen").exists {
                control("Edit Home Screen").tap()
            }
            XCTAssertTrue(edit.waitForExistence(timeout: 4))
            edit.tap()
            control("Add Widget").tap()
            let searchLabels = ["Search Widgets", "Поиск виджетов"]
            func isVisible(_ element: XCUIElement) -> Bool {
                let frame = element.frame
                return !frame.isEmpty && home.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) && element.isHittable
            }
            func visibleSearch() -> XCUIElement? {
                home.searchFields.allElementsBoundByIndex.first {
                    (searchLabels.contains($0.label) || searchLabels.contains($0.placeholderValue ?? "")) && isVisible($0)
                }
            }
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in visibleSearch() != nil }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
            let search = try XCTUnwrap(visibleSearch(), "Visible Search Widgets field")
            capture("два-виджета-поиск")

            let providers = home.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Мой Компаньон"))
            func visibleProvider() -> XCUIElement? {
                providers.allElementsBoundByIndex.first {
                    $0.elementType != .icon && $0.frame.midY > search.frame.maxY && isVisible($0)
                }
            }
            if let provider = visibleProvider() {
                provider.tap()
            } else {
                search.tap()
                let focusedSearch = try XCTUnwrap(visibleSearch(), "Visible Search Widgets field after tap")
                capture("два-виджета-перед-вводом")
                focusedSearch.typeText("Мой Компаньон")
                let found = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in visibleProvider() != nil }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [found], timeout: 8), .completed)
                try XCTUnwrap(visibleProvider(), "Visible Companion provider").tap()
            }
            let add = home.buttons.matching(NSPredicate(
                format: "label MATCHES[c] %@", #"\s*(Add Widget|Добавить виджет)\s*"#
            )).firstMatch
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            add.tap()
            capture("два-виджета-после-добавления")
            let hierarchy = XCTAttachment(string: home.debugDescription)
            hierarchy.name = "два-виджета-иерархия-после-добавления"
            hierarchy.lifetime = .keepAlways
            self.add(hierarchy)
            let done = home.buttons.matching(NSPredicate(
                format: "label MATCHES[c] %@", #"\s*(Done|Готово)\s*"#
            )).firstMatch
            if done.waitForExistence(timeout: 3), done.isHittable {
                done.tap()
            } else if home.buttons["Edit"].isHittable || reaction(expectedHero) == nil {
                XCUIDevice.shared.press(.home)
            }
            XCTAssertTrue(waitForSmall(expectedHero), "Expected an installed small Home Screen widget for " + expectedHero)
        }
        func reaction(_ hero: String) -> XCUIElement? {
            home.buttons.matching(NSPredicate(format: "label CONTAINS %@", hero)).allElementsBoundByIndex
                .first {
                    let frame = $0.frame
                    return (100..<210).contains(frame.width) && (100..<210).contains(frame.height)
                        && home.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) && $0.isHittable
                }
        }
        func waitForSmall(_ hero: String, timeout: TimeInterval = 20) -> Bool {
            let placed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in reaction(hero) != nil }, object: nil)
            return XCTWaiter.wait(for: [placed], timeout: timeout) == .completed
        }
        func waitFor(_ condition: @escaping () -> Bool) {
            let change = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [change], timeout: 20), .completed)
        }

        selectPrimary(primary)
        if reaction(fixed) == nil {
            if !waitForSmall(primary, timeout: 10) { try addSmallWidget(expectedHero: primary) }
            try XCTUnwrap(reaction(primary)).press(forDuration: 1.3)
            control("Edit Widget").tap()
            let selection = home.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Как в приложении")).firstMatch
            XCTAssertTrue(selection.waitForExistence(timeout: 5))
            selection.tap()
            control(fixed).tap()
            // Dismiss the configuration card by tapping the wallpaper.
            home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1)).tap()
            waitFor { reaction(fixed) != nil }
        }
        if !waitForSmall(primary, timeout: 10) { try addSmallWidget(expectedHero: primary) }
        waitFor { reaction(primary) != nil && reaction(fixed) != nil }
        let fixedBefore = reaction(fixed)?.label
        selectPrimary("Женьши")
        waitFor { reaction("Женьши") != nil && reaction(fixed) != nil && reaction(primary) == nil }
        XCTAssertEqual(reaction(fixed)?.label, fixedBefore)
        let followingBefore = reaction("Женьши")?.label
        try XCTUnwrap(reaction(fixed)).tap()
        waitFor { reaction(fixed) != nil && reaction(fixed)?.label != fixedBefore }
        XCTAssertEqual(reaction("Женьши")?.label, followingBefore)
        let fixedAfter = reaction(fixed)?.label
        try XCTUnwrap(reaction("Женьши")).tap()
        waitFor { reaction("Женьши") != nil && reaction("Женьши")?.label != followingBefore }
        XCTAssertEqual(reaction(fixed)?.label, fixedAfter)
        capture("two-widgets-independent-replies")
    }

    func testZInstallLockAccessory() throws {
        continueAfterFailure = true
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let gallery = XCUIApplication(bundleIdentifier: "com.apple.PosterBoard")
        let surfaces = [settings, gallery, home]

        defer { capture("lock-accessory-final-state") }

        func find(_ titles: [String], timeout: TimeInterval = 6, hittable: Bool = true) -> XCUIElement? {
            let deadline = Date().addingTimeInterval(timeout)
            repeat {
                for surface in surfaces where surface.state == .runningForeground {
                    let matches = surface.descendants(matching: .any)
                        .matching(NSPredicate(format: "label IN %@", titles)).allElementsBoundByIndex
                    if let match = matches.first(where: { !hittable || $0.isHittable }) { return match }
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
        let openedFromGallery: Bool
        if let wallpaper = find(["Wallpaper"], timeout: 1) {
            openedFromGallery = false
            wallpaper.tap()
            // The left Customize control belongs to the Lock Screen of the current pair.
            try XCTUnwrap(find(["Customize", "Customize Lock Screen"]), "Lock Screen Customize").tap()
        } else {
            openedFromGallery = true
            // Some simulator Settings lists omit Wallpaper. Open the same editor
            // from Notification Center and keep the installation assertions below.
            XCUIDevice.shared.press(.home)
            let top = home.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.01))
            top.press(forDuration: 0.1, thenDragTo: home.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.85)))
            home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.4)).press(forDuration: 1.5)
            capture("lock-screen-gallery")
            try XCTUnwrap(find(["Customize", "Customise"]), "Wallpaper gallery Customize").tap()
        }
        let widgetRowLabels = ["Add Widgets", "Add Widgets to Lock Screen"]
        var widgetRow = find(widgetRowLabels, timeout: 2)
        if widgetRow == nil {
            let chooser = ["Customize Wallpaper", "Customise Wallpaper"]
            if openedFromGallery || find(chooser, timeout: 2, hittable: false) != nil {
                capture("lock-wallpaper-chooser")
                // In the iOS 18 chooser, the tappable Lock Screen preview fills the left card.
                // The accessibility text sits below the card and can leave the chooser open.
                home.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.50)).tap()
            } else if let lock = find(["Lock Screen", "Customize Lock Screen"], timeout: 2) {
                lock.tap()
            }
            widgetRow = find(widgetRowLabels)
        }
        capture("lock-accessory-editor")
        if widgetRow == nil {
            let hierarchy = surfaces.filter { $0.state == .runningForeground }.map(\.debugDescription)
                .joined(separator: "\n")
            let attachment = XCTAttachment(string: hierarchy)
            attachment.name = "lock-accessory-editor-hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        let widgetRowControl = try XCTUnwrap(widgetRow, "Lock Screen widget row")
        let rowFrame = widgetRowControl.frame
        let companionLabels = ["Remove Мой Компаньон", "Мой Компаньон", "Сатору Годжо", "Тоджи Фушигуро",
                               "Женьши", "Сон Джин Ву", "Рёмен Сукуна", "Мао Мао"]
        func companionMarkersInRow() -> Int {
            surfaces.filter { $0.state == .runningForeground }.map { surface in
                surface.descendants(matching: .any)
                    .matching(NSPredicate(format: "label IN %@", companionLabels))
                    .allElementsBoundByIndex.filter { marker in
                        marker.isHittable && rowFrame.contains(CGPoint(x: marker.frame.midX, y: marker.frame.midY))
                    }.count
            }.max() ?? 0
        }
        let initialMarkers = companionMarkersInRow()
        widgetRowControl.tap()
        for _ in 0..<6 {
            if find(["Мой Компаньон"], timeout: 0.5) != nil { break }
            guard let sheet = find(["Add Widgets"]) else { break }
            let start = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
                .withOffset(CGVector(dx: 0, dy: 220))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: 0, dy: -155)))
        }
        try XCTUnwrap(find(["Мой Компаньон"]), "Companion widget in gallery").tap()
        capture("lock-accessory-gallery")
        let provider = try XCTUnwrap(find(["Мой Компаньон", "Компаньон"]), "Provider sheet")
        let providerTop = provider.frame.minY
        let widgetLabels = NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@", "widget", "виджет")
        var preview: XCUIElement?
        for surface in surfaces where surface.state == .runningForeground {
            let candidates = surface.descendants(matching: .any).matching(widgetLabels).allElementsBoundByIndex
            preview = candidates.first { candidate in
                let frame = candidate.frame
                return candidate.isHittable && frame.width >= 45 && (45...110).contains(frame.height) && frame.midY > providerTop
            }
            if preview != nil { break }
        }
        try XCTUnwrap(preview, "Accessory preview in provider sheet").tap()
        for _ in 0..<2 {
            if let close = find(["Close", "Close Add Widgets"], timeout: 2) { close.tap() }
        }
        let added = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            companionMarkersInRow() > initialMarkers
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [added], timeout: 5), .completed,
                       "Expected a new Companion-specific accessibility label inside the edited widget row")
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
