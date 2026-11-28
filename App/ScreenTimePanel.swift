import DeviceActivity
import FamilyControls
import SwiftUI
import UserNotifications
import WidgetKit

extension Notification.Name {
    static let screenTimeRuleChanged = Notification.Name("MyCompanion.screenTimeRuleChanged")
}

extension ScreenTimePolicy {
    @MainActor
    static func sync(hero: Hero, mode: CompanionMode, schedule: DaySchedule, notifications: Bool,
                     quietStart: Int, quietEnd: Int, nightNotifications: Bool) {
        guard rule != nil else { return }
        let authorization = AuthorizationCenter.shared.authorizationStatus
        guard authorization == .approved else {
            if authorization == .denied { disable() }
            else { clearDelivery() }
            return
        }
        do {
            try setDelivery(deliveryPolicy(hero: hero, mode: mode, schedule: schedule, notifications: notifications,
                                           quietStart: quietStart, quietEnd: quietEnd, nightNotifications: nightNotifications))
        } catch { clearDelivery() }
    }

    static func deliveryPolicy(hero: Hero, mode: CompanionMode, schedule: DaySchedule, notifications: Bool,
                               quietStart: Int, quietEnd: Int, nightNotifications: Bool) -> Delivery {
        Delivery(enabled: notifications, paused: mode == .safe || mode == .paused,
                 quietStart: quietStart, quietEnd: quietEnd, heroID: hero.rawValue,
                 nightStart: schedule.night, dawn: schedule.dawn, nightNotifications: nightNotifications)
    }

    @MainActor
    static func disable() {
        let wasActive = rule != nil
        clearRule()
        DeviceActivityCenter().stopMonitoring([activity])
        if wasActive {
            WidgetCenter.shared.reloadTimelines(ofKind: "Companion")
            NotificationCenter.default.post(name: .screenTimeRuleChanged, object: nil)
        }
    }
}

struct ScreenTimePanel: View {
    @ObservedObject private var authorization = AuthorizationCenter.shared
    @Environment(\.scenePhase) private var phase
    @AppStorage("allNotificationsEnabled") private var allNotifications = true
    @AppStorage("quietStartHour") private var quietStart = 23
    @AppStorage("quietEndHour") private var quietEnd = 7
    @AppStorage("screenTimeNightNotifications") private var nightNotifications = false
    @State private var selection = FamilyActivitySelection()
    @State private var pickerOpen = false
    @State private var minutes = 30
    @State private var activeMinutes: Int?
    @State private var hasSavedRule = false
    @State private var noticeAuthorized = false
    @State private var busy = false
    @State private var error: String?

    let mode: CompanionMode
    let hero: Hero
    let schedule: DaySchedule

    private var validSelection: Bool {
        selection.applicationTokens.count == 1 && selection.categoryTokens.isEmpty && selection.webDomainTokens.isEmpty
    }

    var body: some View {
        Form {
            Section {
                Text(activeMinutes.map { "Напоминание включено. Порог: \($0) мин." } ??
                     (hasSavedRule ? "Подтвердите доступ, чтобы восстановить напоминание." : "Напоминание выключено."))
                    .accessibilityIdentifier("screen-time-status")
                Text("Выберите одно приложение и дневной порог. iOS может показать нейтральное напоминание. Название приложения не попадёт в уведомление.")
            }
#if targetEnvironment(simulator)
            Section {
                Text("Подключение доступно на iPhone.").accessibilityIdentifier("screen-time-simulator")
                Button("Разрешить доступ") {}.disabled(true).accessibilityIdentifier("screen-time-authorize")
            }
            Section("Дневной порог") {
                Button("Выбрать приложение") {}.disabled(true).accessibilityIdentifier("screen-time-picker")
                threshold
                nightPreference.disabled(true)
            }
#else
            Section("Разрешения") {
                if authorization.authorizationStatus == .approved {
                    Button("Отозвать доступ", role: .destructive) { revoke() }.disabled(busy)
                } else {
                    Button("Разрешить доступ") { Task { await requestAccess() } }.disabled(busy)
                        .accessibilityIdentifier("screen-time-authorize")
                }
                if authorization.authorizationStatus == .approved && !noticeAuthorized {
                    Button("Разрешить уведомления") { Task { await requestNotices() } }
                        .disabled(!allNotifications || busy)
                    Text("Если iOS уже отказала в разрешении, его можно изменить в настройках уведомлений iPhone.")
                }
            }
            if authorization.authorizationStatus == .approved {
                Section("Дневной порог") {
                    Button("Выбрать приложение") {
                        selection = FamilyActivitySelection()
                        pickerOpen = true
                    }.accessibilityIdentifier("screen-time-picker")
                    if selection.applicationTokens.count + selection.categoryTokens.count + selection.webDomainTokens.count > 0 {
                        Text(validSelection ? "Выбрано одно приложение." : "Выберите одно приложение без категорий и сайтов.")
                    }
                    threshold
                    Button(activeMinutes == nil ? "Включить напоминание" : "Заменить приложение и порог") { install() }
                        .disabled(!validSelection || !allNotifications || !noticeAuthorized || busy)
                        .accessibilityIdentifier("screen-time-install")
                    if !allNotifications || mode == .safe || mode == .paused {
                        Text("Уведомления приостановлены настройками компаньона.")
                    }
                    nightPreference
                }.familyActivityPicker(isPresented: $pickerOpen, selection: $selection)
            }
            if hasSavedRule {
                Section {
                    Button("Выключить напоминание", role: .destructive) { disable() }.disabled(busy)
                        .accessibilityIdentifier("screen-time-disable")
                }
            }
            if let error { Section { Text(error).foregroundStyle(.secondary).accessibilityIdentifier("screen-time-error") } }
#endif
        }
        .navigationTitle("Экранное время")
#if !targetEnvironment(simulator)
        .task { await refresh() }
        .onChange(of: phase) { _, next in if next == .active { Task { await refresh() } } }
        .onChange(of: authorization.authorizationStatus) { _, _ in Task { await refresh() } }
        .onChange(of: nightNotifications) { _, _ in syncDelivery() }
#endif
    }

    private var threshold: some View {
        Stepper("Порог: \(minutes) мин.", value: $minutes, in: ScreenTimePolicy.minutesRange, step: 5)
            .accessibilityIdentifier("screen-time-minutes")
    }

    private var nightPreference: some View {
        Group {
            Text("Учитываются тихие часы. Изменение порога требует заново выбрать приложение.")
            Toggle("Разрешить ночное уведомление", isOn: $nightNotifications)
                .accessibilityIdentifier("screen-time-night-notifications")
            Text("Без этого разрешения ночная реакция появится в сцене героя без уведомления. При включении уведомление может прийти в тихие часы.")
        }
    }

    @MainActor private func refresh() async {
        if authorization.authorizationStatus == .denied { disable() }
        let rule = ScreenTimePolicy.rule
        if rule != nil && !DeviceActivityCenter().activities.contains(ScreenTimePolicy.activity) {
            disable()
        }
        hasSavedRule = ScreenTimePolicy.rule != nil
        activeMinutes = authorization.authorizationStatus == .approved ? ScreenTimePolicy.rule?.minutes : nil
        syncDelivery()
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        noticeAuthorized = status == .authorized || status == .provisional
    }

    @MainActor private func requestAccess() async {
        busy = true
        defer { busy = false }
        error = nil
        do { try await authorization.requestAuthorization(for: .individual) }
        catch { self.error = "Доступ к экранному времени не предоставлен. Проверьте настройки iPhone." }
        await refresh()
    }

    @MainActor private func requestNotices() async {
        busy = true
        defer { busy = false }
        error = nil
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
            if !granted { error = "Уведомления не разрешены." }
        } catch { self.error = "Не удалось запросить разрешение на уведомления." }
        await refresh()
    }

    @MainActor private func install() {
        guard authorization.authorizationStatus == .approved, allNotifications, noticeAuthorized,
              validSelection, ScreenTimePolicy.minutesRange.contains(minutes) else { return }
        let prior = ScreenTimePolicy.rule
        let rule = ScreenTimePolicy.Rule(eventID: UUID().uuidString, minutes: minutes)
        let activitySchedule = DeviceActivitySchedule(
            intervalStart: DateComponents(hour: 0, minute: 0, second: 0),
            intervalEnd: DateComponents(hour: 23, minute: 59, second: 59),
            repeats: true
        )
        let event = DeviceActivityEvent(applications: selection.applicationTokens,
                                        threshold: DateComponents(hour: minutes / 60, minute: minutes % 60))
        error = nil
        do {
            try ScreenTimePolicy.setDelivery(ScreenTimePolicy.deliveryPolicy(
                hero: hero, mode: mode, schedule: schedule, notifications: allNotifications,
                quietStart: quietStart, quietEnd: quietEnd, nightNotifications: nightNotifications))
            try ScreenTimePolicy.setRule(rule)
            try DeviceActivityCenter().startMonitoring(ScreenTimePolicy.activity, during: activitySchedule,
                                                        events: [DeviceActivityEvent.Name(rule.eventID): event])
            selection = FamilyActivitySelection()
            activeMinutes = rule.minutes
            hasSavedRule = true
        } catch {
            if let prior { try? ScreenTimePolicy.setRule(prior) }
            else { ScreenTimePolicy.clearRule() }
            self.error = "Не удалось установить дневной порог. Проверьте разрешения и повторите попытку."
        }
    }

    @MainActor private func disable() {
        ScreenTimePolicy.disable()
        selection = FamilyActivitySelection()
        activeMinutes = nil
        hasSavedRule = false
    }

    @MainActor private func syncDelivery() {
        ScreenTimePolicy.sync(hero: hero, mode: mode, schedule: schedule, notifications: allNotifications,
                              quietStart: quietStart, quietEnd: quietEnd, nightNotifications: nightNotifications)
    }

    @MainActor private func revoke() {
        disable()
        busy = true
        error = nil
        authorization.revokeAuthorization { result in
            Task { @MainActor in
                busy = false
                if case .failure = result { error = "Порог отключён. Доступ можно отозвать в настройках iPhone." }
                await refresh()
            }
        }
    }
}
