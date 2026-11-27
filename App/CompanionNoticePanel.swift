import SwiftUI
import UIKit
import UserNotifications

private struct NoticePreferences: Equatable {
    var morning, bedtime: Bool
    var morningTime, bedtimeTime, quietStart, quietEnd: Int
}

@MainActor private final class CompanionNotices: ObservableObject {
    static let shared = CompanionNotices()
    @Published var status = ""
    private var running = false
    private var latest: (Hero, CompanionMode, NoticePreferences)?

    func update(hero: Hero, mode: CompanionMode, settings: NoticePreferences) async {
        latest = (hero, mode, settings)
        guard !running else { return }
        running = true
        defer { running = false }
        while let (hero, mode, settings) = latest {
            latest = nil
            await apply(hero: hero, mode: mode, settings: settings)
        }
    }

    private func apply(hero: Hero, mode: CompanionMode, settings: NoticePreferences) async {
        let center = UNUserNotificationCenter.current()
        let permission = await center.notificationSettings().authorizationStatus
        let permitted = [.authorized, .provisional, .ephemeral].contains(permission)
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let plan = CompanionNoticePlan(morning: settings.morning ? settings.morningTime : nil,
                                      bedtime: settings.bedtime ? settings.bedtimeTime : nil,
                                      quietStart: settings.quietStart, quietEnd: settings.quietEnd)
        let slots = permitted && (mode == .normal || mode == .eco) ? plan.slots(hero: hero, now: now, calendar: calendar) : []
        let pending = await center.pendingNotificationRequests().filter { CompanionNoticeSlot.owns($0.identifier) }
        let defaults = UserDefaults.standard
        let ledgerKey = "companion.notice.appliedDates"
        // Past scheduled slots may already have fired, even after Notification Center was cleared.
        var ledger = (defaults.dictionary(forKey: ledgerKey) as? [String: Date] ?? [:])
            .filter { $0.value > now.addingTimeInterval(-7 * 86400) }
        let desired = slots.filter { (ledger[$0.id] ?? .distantFuture) > now }
        let ids = Set(desired.map(\.id))
        let stale = pending.map(\.identifier).filter { !ids.contains($0) }
        center.removePendingNotificationRequests(withIdentifiers: stale)
        ledger = ledger.filter { $0.value <= now || ids.contains($0.key) }
        let title = "Мой Компаньон · \(hero.name)"
        func matches(_ request: UNNotificationRequest, _ slot: CompanionNoticeSlot) -> Bool {
            request.identifier == slot.id && request.content.title == title && request.content.body == slot.body &&
                request.content.categoryIdentifier == slot.category &&
                (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() == slot.date
        }
        do {
            for slot in desired {
                if !pending.contains(where: { matches($0, slot) }) {
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = slot.body
                    content.categoryIdentifier = slot.category
                    var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: slot.date)
                    parts.timeZone = calendar.timeZone
                    let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                    try await center.add(UNNotificationRequest(identifier: slot.id, content: content, trigger: trigger))
                }
                ledger[slot.id] = slot.date
            }
            let applied = await center.pendingNotificationRequests().filter { CompanionNoticeSlot.owns($0.identifier) }
            let verified = applied.count == desired.count && desired.allSatisfy { slot in applied.contains { matches($0, slot) } }
            if !verified { status = "Система пока не подтвердила расписание." }
            else if !settings.morning && !settings.bedtime { status = "Личные уведомления выключены." }
            else if !permitted { status = "Для доставки разрешите уведомления в настройках iOS." }
            else if mode == .safe || mode == .paused { status = "В этом режиме личные уведомления приостановлены." }
            else { status = "Запланировано на ближайшие три дня: \(applied.count)." }
        } catch { status = "Не удалось обновить расписание. Повторим при следующем открытии." }
        defaults.set(ledger, forKey: ledgerKey)
    }
}

private struct NoticeReconciliation: ViewModifier {
    let hero: Hero
    let mode: CompanionMode
    @Environment(\.scenePhase) private var phase
    @AppStorage("companionMorningEnabled") private var morning = false
    @AppStorage("companionBedtimeEnabled") private var bedtime = false
    @AppStorage("companionMorningTime") private var morningTime = 480
    @AppStorage("companionBedtimeTime") private var bedtimeTime = 1365
    @AppStorage("quietStartHour") private var quietStart = 23
    @AppStorage("quietEndHour") private var quietEnd = 7

    func body(content: Content) -> some View {
        let preferences = NoticePreferences(morning: morning, bedtime: bedtime, morningTime: morningTime,
                                           bedtimeTime: bedtimeTime, quietStart: quietStart, quietEnd: quietEnd)
        let refresh = {
            Task { @MainActor in await CompanionNotices.shared.update(hero: hero, mode: mode, settings: preferences) }
        }
        return content.onAppear { _ = refresh() }
            .onChange(of: phase) { _, value in if value == .active { _ = refresh() } }
            .onChange(of: preferences) { _, _ in _ = refresh() }
            .onChange(of: hero) { _, _ in _ = refresh() }
            .onChange(of: mode) { _, _ in _ = refresh() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in _ = refresh() }
    }
}

extension View {
    func companionNoticeReconciliation(hero: Hero, mode: CompanionMode) -> some View {
        modifier(NoticeReconciliation(hero: hero, mode: mode))
    }
}

struct CompanionNoticePanel: View {
    @ObservedObject private var notices = CompanionNotices.shared
    @AppStorage("companionMorningEnabled") private var morning = false
    @AppStorage("companionBedtimeEnabled") private var bedtime = false
    @AppStorage("companionMorningTime") private var morningTime = 480
    @AppStorage("companionBedtimeTime") private var bedtimeTime = 1365
    @AppStorage("quietStartHour") private var quietStart = 23
    @AppStorage("quietEndHour") private var quietEnd = 7
    @AppStorage("allowTasksDuringQuiet") private var allowTasks = true
    @State private var requesting = false
    @State private var authorizationMessage = ""

    var body: some View {
        Form {
            Section("Расписание") {
                noticeToggle("Доброе утро", setting: $morning)
                if morning { timePicker("Утром", setting: $morningTime) }
                noticeToggle("Пора отдыхать", setting: $bedtime)
                if bedtime { timePicker("Перед сном", setting: $bedtimeTime) }
            }
            Section("Тихие часы") {
                hourPicker("Начало", setting: $quietStart)
                hourPicker("Окончание", setting: $quietEnd)
                Toggle("Разрешить уведомления о задачах", isOn: $allowTasks)
                Text(quietStart == quietEnd ? "Тихие часы отключены." : "Личные сообщения в эти часы пропускаются.")
                    .font(.footnote)
            }
            if !authorizationMessage.isEmpty { Text(authorizationMessage) }
            if !notices.status.isEmpty { Text(notices.status) }
        }.navigationTitle("Уведомления героя")
    }

    private func noticeToggle(_ label: String, setting: Binding<Bool>) -> some View {
        Toggle(label, isOn: Binding(get: { setting.wrappedValue }, set: { value in
            authorizationMessage = ""
            guard value else { setting.wrappedValue = false; return }
            requesting = true
            Task { @MainActor in
                defer { requesting = false }
                do {
                    if try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
                        setting.wrappedValue = true
                    } else { authorizationMessage = "Разрешить доставку можно в настройках уведомлений iOS." }
                } catch { authorizationMessage = "Не удалось запросить разрешение на уведомления." }
            }
        })).disabled(requesting)
    }

    private func hourPicker(_ title: String, setting: Binding<Int>) -> some View {
        Picker(title, selection: setting) {
            ForEach(0..<24, id: \.self) { hour in Text(String(format: "%02d:00", hour)).tag(hour) }
        }
    }

    private func timePicker(_ title: String, setting: Binding<Int>) -> some View {
        DatePicker(title, selection: Binding(get: {
            let minute = setting.wrappedValue
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            setting.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        }), displayedComponents: .hourAndMinute)
    }
}
