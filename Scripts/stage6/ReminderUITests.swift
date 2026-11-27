import XCTest

final class ReminderUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "local.mycompanion")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func start(grant: Bool) {
        continueAfterFailure = false
        app.launch()
        app.tabBars.buttons["Настройки"].tap()
        let diagnostics = app.buttons["Диагностика"]
        for _ in 0..<4 where !diagnostics.isHittable { app.swipeUp() }
        XCTAssertTrue(diagnostics.isHittable)
        diagnostics.tap()
        app.buttons["Напомнить через минуту"].tap()
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 12))
        if grant {
            alert.buttons["Allow"].tap()
        } else {
            let deny = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Don")).firstMatch
            deny.tap()
        }
    }

    func testCreateAndCompleteTask() {
        continueAfterFailure = false
        app.launch()
        let skipWelcome = app.buttons["Пропустить знакомство"]
        XCTAssertTrue(skipWelcome.waitForExistence(timeout: 8))
        app.buttons["companion-interaction"].tap()
        XCTAssertFalse(skipWelcome.exists)
        app.buttons["Напоминания"].tap()
        app.buttons["Добавить"].tap()
        let title = app.descendants(matching: .any)["task-title"].firstMatch
        title.tap()
        title.typeText("Test task")
        app.buttons["Сохранить"].tap()
        let options = app.buttons["Действия с задачей Test task"]
        XCTAssertTrue(options.waitForExistence(timeout: 8))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Мой Компаньон"].waitForExistence(timeout: 8))
        XCTAssertFalse(skipWelcome.exists)
        app.buttons["Напоминания"].tap()
        options.tap()
        app.buttons["Выполнить"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label =[c] %@", "Завершённые")).firstMatch.waitForExistence(timeout: 8))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "completed-local-task"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCalendarPrivacy() {
        continueAfterFailure = false
        app.launch()
        app.buttons["Календарь"].tap()
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        app.buttons["Подключить календарь для чтения"].tap()
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 12))
        alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Full Access")).firstMatch.tap()
        let titles = app.switches["Показывать названия в расписании и виджете"]
        XCTAssertTrue(titles.waitForExistence(timeout: 8))
        XCTAssertEqual(titles.value as? String, "0")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "calendar-private"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Отключить календарь"].tap()
        XCTAssertTrue(app.buttons["Подключить календарь для чтения"].waitForExistence(timeout: 8))
    }

    func testStageSevenNavigation() {
        continueAfterFailure = false
        app.launch()
        func capture(_ name: String) {
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = name
            shot.lifetime = .keepAlways
            add(shot)
        }
        let tabs = app.tabBars.firstMatch
        let skipWelcome = app.buttons["Пропустить знакомство"]
        XCTAssertTrue(skipWelcome.waitForExistence(timeout: 8))
        capture("Первое знакомство")
        skipWelcome.tap()
        for name in ["Компаньон", "Календарь", "Напоминания", "Персонажи", "Настройки"] {
            let tab = tabs.buttons[name]
            XCTAssertTrue(tab.waitForExistence(timeout: 8))
            tab.tap()
            XCTAssertTrue(tab.isSelected)
            let title = name == "Компаньон" ? "Мой Компаньон" : name
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
            // Selection changes before UIKit finishes the visible tab transition.
            Thread.sleep(forTimeInterval: 1)
            capture(name)
        }
        tabs.buttons["Персонажи"].tap()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Мао Мао")).firstMatch.tap()
        let moods = app.buttons["character-mood"]
        for name in ["Радость", "Сонливость", "Удивление"] {
            moods.tap()
            app.buttons[name].tap()
            capture("Мао Мао " + name)
        }
        app.buttons["Портрет"].tap()
        app.buttons["Выбрать"].tap()
        XCTAssertTrue(app.buttons["Выбран"].waitForExistence(timeout: 8))
        tabs.buttons["Компаньон"].tap()
        XCTAssertTrue(app.buttons["Портрет"].isSelected)
        capture("Портрет")
        app.buttons["Чиби"].tap()
        XCTAssertTrue(app.buttons["Чиби"].isSelected)
        app.buttons["Галерея находок"].tap()
        XCTAssertTrue(app.navigationBars["Галерея находок"].waitForExistence(timeout: 5))
        capture("Галерея")
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let heading = app.staticTexts["companion-heading"]
        XCTAssertTrue(heading.waitForExistence(timeout: 8))
        XCTAssertEqual(heading.label, "Мой Компаньон")
        XCTAssertFalse(app.navigationBars["Мой Компаньон"].exists)
        XCTAssertFalse(skipWelcome.exists)
        capture("Компаньон крупный текст")
        let heroScene = app.buttons["companion-interaction"]
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", "Мао Мао"),
            object: heroScene
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 8), .completed)
        XCTAssertTrue(app.buttons["Чиби"].isSelected)

    }

    func testDenied() {
        start(grant: false)
        XCTAssertTrue(app.staticTexts["Уведомления выключены"].waitForExistence(timeout: 8))
        app.buttons["Напомнить через минуту"].tap()
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Уведомления выключены"].exists)
    }

    func testScheduleReplaceCancel() {
        start(grant: true)
        let scheduled = app.staticTexts["Напоминание запланировано"]
        XCTAssertTrue(scheduled.waitForExistence(timeout: 8))
        app.buttons["Напомнить через минуту"].tap()
        let cancel = app.buttons["Отменить напоминание"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: cancel)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        XCTAssertTrue(scheduled.exists)
        cancel.tap()
        XCTAssertTrue(app.staticTexts["Напоминание отменено"].waitForExistence(timeout: 8))
        let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        evidence.name = "reminder-cancelled"
        evidence.lifetime = .keepAlways
        add(evidence)

        // Keep the app in the background while iOS reaches the notification trigger.
        app.buttons["Напомнить через минуту"].tap()
        XCTAssertTrue(scheduled.waitForExistence(timeout: 8))
        XCUIDevice.shared.press(.home)
        Thread.sleep(forTimeInterval: 70)

    }
}
