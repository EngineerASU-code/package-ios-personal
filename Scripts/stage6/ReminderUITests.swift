import XCTest

final class ReminderUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "local.mycompanion")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private func start(grant: Bool) {
        continueAfterFailure = false
        app.launch()
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
    }
}
