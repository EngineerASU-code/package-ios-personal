import XCTest

final class ReminderUITests: XCTestCase {
    let app = XCUIApplication(bundleIdentifier: "local.mycompanion")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    private let heroes: [(name: String, id: String)] = [
        ("Сатору Годжо", "satoru_gojo"), ("Тоджи Фушигуро", "toji_fushiguro"),
        ("Женьши", "jinshi"), ("Сон Джин Ву", "sung_jinwoo"),
        ("Рёмен Сукуна", "ryomen_sukuna"), ("Мао Мао", "maomao")
    ]

    private func openSettings() {
        let settings = app.buttons["open-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 8))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 8))
    }

    private func notificationSwitch(in settings: XCUIApplication) -> XCUIElement {
        let allow = settings.switches.matching(NSPredicate(
            format: "label IN %@", ["Allow Notifications", "Допуск уведомлений", "Разрешить уведомления"]
        )).firstMatch
        if allow.waitForExistence(timeout: 3) { return allow }

        func row(_ names: [String]) -> XCUIElement {
            let match = NSPredicate(format: "identifier IN %@ OR label IN %@", names, names)
            let button = settings.buttons.matching(match).firstMatch
            if button.exists { return button }
            let cell = settings.cells.matching(match).firstMatch
            return cell.exists ? cell : settings.staticTexts.matching(match).firstMatch
        }

        let appNames = ["local.mycompanion", "Мой Компаньон", "My Companion", "MyCompanion"]
        let notificationNames = ["com.apple.settings.notifications", "Notifications", "Уведомления"]
        let appPageTitle = settings.navigationBars.matching(NSPredicate(format: "identifier IN %@", appNames)).firstMatch
        if !appPageTitle.exists {
            let apps = ["com.apple.settings.apps", "Apps", "Приложения"]
            for _ in 0..<8 where !row(apps).isHittable { settings.swipeUp() }
            XCTAssertTrue(row(apps).isHittable, "Settings > Apps")
            row(apps).tap()
            for _ in 0..<16 where !row(appNames).isHittable { settings.swipeUp() }
            XCTAssertTrue(row(appNames).isHittable, "Settings > Apps > Мой Компаньон")
            row(appNames).tap()
        }
        if !allow.exists {
            XCTAssertTrue(row(notificationNames).waitForExistence(timeout: 6),
                          "Settings > Apps > Мой Компаньон > Notifications")
            if !row(notificationNames).isHittable { settings.swipeUp() }
            row(notificationNames).tap()
        }
        return allow
    }

    private func start(grant: Bool) {
        continueAfterFailure = false
        // Override only the launch defaults. Keep the persisted onboarding and delivery preferences.
        app.launchArguments += ["-didFinishWelcome", "YES", "-allNotificationsEnabled", "YES"]
        app.launch()
        openSettings()
        let diagnostics = app.buttons["Диагностика"]
        for _ in 0..<4 where !diagnostics.isHittable { app.swipeUp() }
        XCTAssertTrue(diagnostics.isHittable)
        diagnostics.tap()
        let schedule = app.buttons["Напомнить через минуту"]
        let scheduled = app.staticTexts["Напоминание запланировано"]
        let denied = app.staticTexts["Уведомления выключены"]
        let desiredStatus = grant ? scheduled : denied
        let initialOutcome = app.staticTexts.matching(NSPredicate(
            format: "label IN %@", ["Напоминание запланировано", "Уведомления выключены"]
        )).firstMatch
        XCTAssertTrue(schedule.isHittable)
        schedule.tap()
        let alert = springboard.alerts.firstMatch
        let outcome = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            initialOutcome.exists || alert.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [outcome], timeout: 15), .completed)
        if alert.exists {
            if grant {
                alert.buttons["Allow"].tap()
            } else {
                let deny = alert.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Don")).firstMatch
                deny.tap()
            }
            XCTAssertTrue(desiredStatus.waitForExistence(timeout: 8))
            return
        }

        if desiredStatus.exists { return }
        if !grant && scheduled.exists {
            app.buttons["Отменить напоминание"].tap()
            XCTAssertTrue(app.staticTexts["Напоминание отменено"].waitForExistence(timeout: 8))
        }
        let link = app.descendants(matching: .any)["diagnostic-notification-settings"].firstMatch
        if !link.isHittable { app.swipeUp() }
        XCTAssertTrue(link.isHittable)
        link.tap()

        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        let allow = notificationSwitch(in: settings)
        XCTAssertTrue(allow.waitForExistence(timeout: 8))
        let desired = grant ? "1" : "0"
        if allow.value as? String != desired { allow.tap() }
        XCTAssertEqual(allow.value as? String, desired)

        app.activate()
        XCTAssertTrue(app.navigationBars["Диагностика"].waitForExistence(timeout: 8))
        if !schedule.isHittable { app.swipeDown() }
        schedule.tap()
        XCTAssertTrue(desiredStatus.waitForExistence(timeout: 8))
    }

    func testCreateAndCompleteTask() {
        continueAfterFailure = false
        app.launch()
        let skipWelcome = app.buttons["Пропустить знакомство"]
        let scene = app.buttons["companion-interaction"]
        XCTAssertTrue(scene.waitForExistence(timeout: 8))
        if skipWelcome.exists && scene.isEnabled {
            scene.tap()
            XCTAssertFalse(skipWelcome.exists)
        }
        app.tabBars.buttons["Напоминания"].tap()
        app.buttons["Добавить"].tap()
        let title = app.descendants(matching: .any)["task-title"].firstMatch
        title.tap()
        let taskName = "Test " + String(UUID().uuidString.prefix(8))
        title.typeText(taskName)
        app.buttons["Сохранить"].tap()
        let options = app.buttons["Действия с задачей " + taskName]
        XCTAssertTrue(options.waitForExistence(timeout: 8))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Мой Компаньон"].waitForExistence(timeout: 8))
        XCTAssertFalse(skipWelcome.exists)
        app.tabBars.buttons["Напоминания"].tap()
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
        app.resetAuthorizationStatus(for: .calendar)
        app.launch()
        app.tabBars.buttons["Календарь"].tap()
        let connect = app.buttons["Подключить календарь для чтения"]
        let disconnect = app.buttons["Отключить календарь"]
        if disconnect.exists { disconnect.tap() }
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        connect.tap()
        let alert = springboard.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 12))
        let fullAccess = alert.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Full Access")).firstMatch
        XCTAssertTrue(fullAccess.exists)
        fullAccess.tap()
        let titles = app.switches["Показывать названия в расписании и виджете"]
        XCTAssertTrue(titles.waitForExistence(timeout: 8))
        XCTAssertEqual(titles.value as? String, "0")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "calendar-private"
        attachment.lifetime = .keepAlways
        add(attachment)
        disconnect.tap()
        XCTAssertTrue(connect.waitForExistence(timeout: 8))
        XCTAssertFalse(titles.exists)
    }

    func testScreenTimeRemainsOffWithoutConsent() {
        continueAfterFailure = false
        app.launch()
        let scene = app.buttons["companion-interaction"]
        XCTAssertTrue(scene.waitForExistence(timeout: 8))
        XCTAssertTrue(scene.isHittable)
        XCTAssertFalse(springboard.alerts.firstMatch.exists)

        openSettings()
        let screenTime = app.buttons["screen-time-settings"]
        for _ in 0..<4 where !screenTime.isHittable { app.swipeUp() }
        XCTAssertTrue(screenTime.isHittable)
        screenTime.tap()
        XCTAssertTrue(app.navigationBars["Экранное время"].waitForExistence(timeout: 8))

        let status = app.staticTexts["screen-time-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertEqual(status.label, "Напоминание выключено.")
        let authorize = app.buttons["screen-time-authorize"]
        XCTAssertTrue(authorize.exists)
        #if targetEnvironment(simulator)
        XCTAssertTrue(app.staticTexts["screen-time-simulator"].exists)
        XCTAssertFalse(authorize.isEnabled)
        #endif
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        XCTAssertEqual(app.state, .runningForeground)
        capture("Экранное время — выключено")

        app.navigationBars["Экранное время"].buttons.firstMatch.tap()
        app.navigationBars["Настройки"].buttons.firstMatch.tap()
        for name in ["Календарь", "Напоминания"] {
            app.tabBars.buttons[name].tap()
            XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 8))
        }
        app.tabBars.buttons["Компаньон"].tap()
        XCTAssertTrue(scene.waitForExistence(timeout: 8))
        XCTAssertTrue(scene.isHittable)
    }

    func testWeatherRemainsOffWithoutConsent() {
        continueAfterFailure = false
        app.launch()
        let scene = app.buttons["companion-interaction"]
        XCTAssertTrue(scene.waitForExistence(timeout: 8))
        openSettings()
        app.buttons["open-weather-settings"].tap()
        XCTAssertTrue(app.navigationBars["Погода и эмоции"].waitForExistence(timeout: 8))

        let status = app.staticTexts["weather-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 8))
        XCTAssertEqual(status.label, "Погода выключена")
        let automatic = app.descendants(matching: .any)["weather-automatic-emotions"].firstMatch
        XCTAssertTrue(automatic.waitForExistence(timeout: 8))
        let setting = [automatic.label, automatic.value as? String ?? ""].joined(separator: " ")
        XCTAssertTrue(setting.contains("Авто") || automatic.staticTexts["Авто"].exists)
        let query = app.textFields["weather-city-query"]
        let search = app.buttons["weather-city-search"]
        XCTAssertTrue(query.exists)
        XCTAssertTrue(search.exists)
        XCTAssertFalse(search.isEnabled)
        XCTAssertFalse(app.buttons["weather-enable"].exists)
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 2))
        XCTAssertFalse(app.alerts.firstMatch.exists)
        capture("Погода и эмоции — выключено")

        app.navigationBars["Погода и эмоции"].buttons.firstMatch.tap()
        app.navigationBars["Настройки"].buttons.firstMatch.tap()
        XCTAssertTrue(scene.waitForExistence(timeout: 8))
        XCTAssertTrue(scene.isHittable)
    }

    func testStageSevenNavigation() {
        continueAfterFailure = false
        app.launch()
        let tabs = app.tabBars.firstMatch
        let skipWelcome = app.buttons["Пропустить знакомство"]
        XCTAssertTrue(app.buttons["companion-interaction"].waitForExistence(timeout: 8))
        if skipWelcome.exists {
            capture("Первое знакомство")
            if !skipWelcome.isHittable { app.swipeUp() }
            skipWelcome.tap()
            app.swipeDown()
        }
        app.buttons["Чиби"].tap()
        XCTAssertEqual(tabs.buttons.count, 3)
        for name in ["Календарь", "Компаньон", "Напоминания"] {
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
        tabs.buttons["Компаньон"].tap()
        openSettings()
        capture("Настройки")
        app.navigationBars["Настройки"].buttons.firstMatch.tap()
        app.buttons["open-characters"].tap()
        XCTAssertTrue(app.navigationBars["Персонажи"].waitForExistence(timeout: 8))
        capture("Персонажи")
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Мао Мао")).firstMatch.tap()
        let moods = app.buttons["character-mood"]
        for name in ["Радость", "Сонливость", "Удивление"] {
            moods.tap()
            app.buttons[name].tap()
            capture("Мао Мао " + name)
        }
        app.buttons["Портрет"].tap()
        let choose = app.buttons["Выбрать"]
        if choose.exists { choose.tap() }
        XCTAssertTrue(app.buttons["Выбран"].waitForExistence(timeout: 8))
        app.navigationBars["Мао Мао"].buttons.firstMatch.tap()
        app.navigationBars["Персонажи"].buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["Портрет"].isSelected)
        capture("Портрет")
        app.buttons["Чиби"].tap()
        XCTAssertTrue(app.buttons["Чиби"].isSelected)
        openSettings()
        app.buttons["open-gallery"].tap()
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

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testVisualCompanionTour() {
        continueAfterFailure = false
        app.launch()
        let scene = app.buttons["companion-interaction"]
        XCTAssertTrue(scene.waitForExistence(timeout: 8))
        let originalHero = heroes.first { scene.label.contains($0.0) }
        let originalForm = app.buttons["Портрет"].isSelected ? "Портрет" : "Чиби"

        for (hero, id) in heroes {
            showHero(hero, id: id, scene: scene)
            for form in ["Чиби", "Портрет"] {
                app.buttons[form].tap()
                XCTAssertTrue(app.buttons[form].isSelected)
                capture("Компаньон — " + hero + " — " + form)
            }
        }
        if let (name, id) = originalHero { showHero(name, id: id, scene: scene) }
        app.buttons[originalForm].tap()

        openSettings()
        capture("Настройки — главная")
        let labels = ["Обычный", "Экономный", "Безопасный", "Пауза"]
        let mode = app.buttons["companion-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 8))
        mode.tap()
        let originalMode = labels.first { name in
            app.buttons[name].isSelected || app.cells[name].isSelected
        } ?? "Обычный"
        for (index, name) in (labels + [originalMode]).enumerated() {
            if index > 0 { mode.tap() }
            let option = app.buttons[name]
            XCTAssertTrue(option.waitForExistence(timeout: 8))
            option.tap()
            if index < labels.count {
                XCTAssertTrue(app.navigationBars["Настройки"].waitForExistence(timeout: 8))
                capture("Настройки — " + name)
            }
        }
        app.buttons["Оформление компаньона"].tap()
        XCTAssertTrue(app.navigationBars["Оформление"].waitForExistence(timeout: 8))
        capture("Настройки — оформление")
        app.navigationBars["Оформление"].buttons.firstMatch.tap()
        app.navigationBars["Настройки"].buttons.firstMatch.tap()

        app.buttons["open-characters"].tap()
        XCTAssertTrue(app.navigationBars["Персонажи"].waitForExistence(timeout: 8))
        capture("Персонажи — список")
        app.navigationBars["Персонажи"].buttons.firstMatch.tap()
        openSettings()
        app.buttons["open-gallery"].tap()
        XCTAssertTrue(app.navigationBars["Галерея находок"].waitForExistence(timeout: 8))
        capture("Галерея находок")
        app.navigationBars["Галерея находок"].buttons.firstMatch.tap()
        for name in ["Календарь", "Напоминания"] {
            app.tabBars.buttons[name].tap()
            XCTAssertTrue(app.navigationBars[name].waitForExistence(timeout: 8))
            capture(name)
        }
    }

    private func showHero(_ name: String, id: String, scene: XCUIElement) {
        let strip = app.scrollViews["hero-strip"]
        XCTAssertTrue(strip.waitForExistence(timeout: 8))
        let tile = app.buttons["select-hero-" + id]
        XCTAssertTrue(tile.waitForExistence(timeout: 8), name)
        func tileCenterIsVisible() -> Bool {
            let center = CGPoint(x: tile.frame.midX, y: tile.frame.midY)
            return tile.isHittable && strip.frame.insetBy(dx: 6, dy: 0).contains(center)
        }
        for _ in 0..<3 where !tileCenterIsVisible() {
            if tile.frame.midX < strip.frame.midX { strip.swipeRight() }
            else { strip.swipeLeft() }
        }
        XCTAssertTrue(tileCenterIsVisible(), name)
        if !scene.label.contains(name) { tile.tap() }
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", name), object: scene
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 8), .completed, name)
    }

    func testVisualHeroAnimations() throws {
        continueAfterFailure = false
        app.launch()
        let scene = app.buttons["companion-interaction"]
        XCTAssertTrue(scene.waitForExistence(timeout: 8))
        let originalHero = try XCTUnwrap(heroes.first { scene.label.contains($0.name) })
        let originalForm = app.buttons["Портрет"].isSelected ? "Портрет" : "Чиби"
        app.buttons["Чиби"].tap()

        openSettings()
        let settings = app.navigationBars["Настройки"]
        let mode = app.buttons["companion-mode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 8))
        let currentMode = [mode.label, mode.value as? String ?? ""].joined(separator: " ")
        let modes = ["Обычный", "Экономный", "Безопасный", "Пауза"]
        mode.tap()
        let originalMode = try XCTUnwrap(modes.first { name in
            let option = app.buttons[name]
            return currentMode.contains(name) || (option.exists && option.isSelected)
        }, "Current companion mode")
        app.buttons["Обычный"].tap()

        let animations = app.switches["Анимации героя"]
        XCTAssertTrue(animations.waitForExistence(timeout: 8))
        let originalAnimations = try XCTUnwrap(animations.value as? String)
        if originalAnimations == "0" { animations.tap() }
        XCTAssertEqual(animations.value as? String, "1")
        settings.buttons.firstMatch.tap()

        for (name, id) in heroes {
            showHero(name, id: id, scene: scene)
            XCTAssertTrue(scene.isEnabled)
            let prior = scene.label
            scene.tap()
            let response = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label != %@", prior), object: scene
            )
            XCTAssertEqual(XCTWaiter.wait(for: [response], timeout: 5), .completed, name)
            // The longest configured app animation runs for 1.4 seconds.
            Thread.sleep(forTimeInterval: 1.5)
            capture("Реакция — " + name)
        }

        showHero(originalHero.name, id: originalHero.id, scene: scene)
        app.buttons[originalForm].tap()
        openSettings()
        if originalAnimations == "0" { animations.tap() }
        if originalMode != "Обычный" {
            mode.tap()
            app.buttons[originalMode].tap()
        }
        settings.buttons.firstMatch.tap()
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

    func testGrantNotificationPermission() {
        start(grant: true)
        XCTAssertTrue(app.staticTexts["Напоминание запланировано"].waitForExistence(timeout: 8))
        let evidence = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        evidence.name = "notification-grant-diagnostic-scheduled"
        evidence.lifetime = .keepAlways
        add(evidence)
        app.buttons["Отменить напоминание"].tap()
        XCTAssertTrue(app.staticTexts["Напоминание отменено"].waitForExistence(timeout: 8))
    }
}
