import AppIntents
import SwiftUI
import WidgetKit
import UIKit
import UserNotifications

private struct NoticePreferences: Equatable {
    var morning, bedtime: Bool
    var morningTime, bedtimeTime, quietStart, quietEnd: Int
    var support, gifts, enabled: Bool
    var schedule: DaySchedule
    var intensity: CommunicationIntensity
}

enum NoticeDelivery {
    static var enabled: Bool { UserDefaults.standard.object(forKey: "allNotificationsEnabled") as? Bool ?? true }

    static func add(_ request: UNNotificationRequest, to center: UNUserNotificationCenter) async throws {
        guard enabled else { throw CancellationError() }
        try await center.add(request)
        if !enabled {
            center.removePendingNotificationRequests(withIdentifiers: [request.identifier])
            throw CancellationError()
        }
    }

    static func cancelWhenDisabled() async {
        let center = UNUserNotificationCenter.current()
        let requests = await center.pendingNotificationRequests()
        guard !enabled else { return }
        let ids = requests.map(\.identifier).filter {
            $0 == "mycompanion.preview" || $0.hasPrefix("mycompanion.task.") ||
                $0.hasPrefix("companion.calendar.") || CompanionNoticeSlot.owns($0)
        }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }
}

@MainActor final class NoticeJournalStorage<Value: Equatable> {
    private let store: Store
    private let field: WritableKeyPath<Companion, Value?>
    private var saved: Value?
    var current: Value

    init(_ field: WritableKeyPath<Companion, Value?>, migrate: () throws -> Value) throws {
        self.field = field
        store = try Store.shared()
        let previous = try store.read()[keyPath: field]
        saved = previous
        current = try previous ?? migrate()
    }

    func persist() throws {
        guard current != saved else { return }
        var committed = false
        try store.update { state in
            guard state[keyPath: field] == saved else { return }
            state[keyPath: field] = current
            committed = true
        }
        guard committed else { throw StoreError.database }
        saved = current
    }
}

extension Notification.Name {
    static let companionModeChanged = Notification.Name("MyCompanion.modeChanged")
}

@MainActor private func updatePause(_ pause: Bool) async throws {
    let state = try Store.shared().update { state in
        if pause { state.setMode(.paused) } else { state.resume() }
    }
    WidgetCenter.shared.reloadTimelines(ofKind: "Companion")
    NotificationCenter.default.post(name: .companionModeChanged, object: nil)
    let defaults = UserDefaults.standard
    let settings = NoticePreferences(
        morning: defaults.bool(forKey: "companionMorningEnabled"),
        bedtime: defaults.bool(forKey: "companionBedtimeEnabled"),
        morningTime: defaults.object(forKey: "companionMorningTime") as? Int ?? 480,
        bedtimeTime: defaults.object(forKey: "companionBedtimeTime") as? Int ?? 1365,
        quietStart: defaults.object(forKey: "quietStartHour") as? Int ?? 23,
        quietEnd: defaults.object(forKey: "quietEndHour") as? Int ?? 7,
        support: defaults.bool(forKey: "companionSupportEnabled"), gifts: defaults.bool(forKey: "companionGiftsEnabled"),
        enabled: NoticeDelivery.enabled, schedule: state.daySchedule, intensity: state.communicationIntensity
    )
    await CompanionNotices.shared.update(hero: state.hero, mode: state.mode, settings: settings)
}

struct PauseCompanionIntent: AppIntent {
    static var title: LocalizedStringResource = "Приостановить компаньона"
    func perform() async throws -> some IntentResult {
        try await updatePause(true)
        return .result()
    }
}

struct ResumeCompanionIntent: AppIntent {
    static var title: LocalizedStringResource = "Возобновить компаньона"
    func perform() async throws -> some IntentResult {
        try await updatePause(false)
        return .result()
    }
}

@MainActor private final class CompanionNotices: ObservableObject {
    static let shared = CompanionNotices()
    @Published var status = ""
    private var running: Task<Void, Never>?
    private var latest: (Hero, CompanionMode, NoticePreferences)?

    func update(hero: Hero, mode: CompanionMode, settings: NoticePreferences) async {
        latest = (hero, mode, settings)
        if let running {
            await running.value
            return
        }
        let pass = Task { @MainActor in
            while let (hero, mode, settings) = latest {
                latest = nil
                await apply(hero: hero, mode: mode, settings: settings)
            }
            running = nil
        }
        running = pass
        await pass.value
    }

    private func apply(hero: Hero, mode: CompanionMode, settings: NoticePreferences) async {
        let center = UNUserNotificationCenter.current()
        let permission = await center.notificationSettings().authorizationStatus
        let permitted = [.authorized, .provisional, .ephemeral].contains(permission)
        if !settings.enabled {
            center.removePendingNotificationRequests(withIdentifiers: ["mycompanion.preview"])
        }
        let now = Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        var plan = CompanionNoticePlan(morning: settings.morning ? settings.morningTime : nil,
                                      bedtime: settings.bedtime ? settings.bedtimeTime : nil,
                                      quietStart: settings.quietStart, quietEnd: settings.quietEnd)
        let active = settings.enabled && permitted && (mode == .normal || mode == .eco)
        plan.support = settings.support
        plan.daySchedule = settings.schedule
        plan.communicationIntensity = settings.intensity
        if active && settings.gifts, let state = try? Store.shared().read(), state.hero == hero {
            let finds = Set(hero.pack?.finds.map(\.id) ?? [])
            plan.gift = state.unlocks.filter { finds.contains($0.id) }.max { $0.date < $1.date }
        }
        let slots = active ? plan.slots(hero: hero, now: now, calendar: calendar) : []
        let pending = await center.pendingNotificationRequests().filter { CompanionNoticeSlot.owns($0.identifier) }
        // Cancellations remain possible even when the budget journal cannot be read.
        let obsolete = pending.map(\.identifier).filter { id in
            !active || (id.hasPrefix("companion.greeting.") && !settings.morning) ||
                (id.hasPrefix("companion.bedtime.") && !settings.bedtime) ||
                (id.hasPrefix("companion.support.") && !settings.support) ||
                (id.hasPrefix("companion.gift.") && !settings.gifts)
        }
        if !obsolete.isEmpty { center.removePendingNotificationRequests(withIdentifiers: obsolete) }
        let defaults = UserDefaults.standard
        let ledgerKey = "companion.notice.budget.v2"
        let oldKey = "companion.notice.appliedDates"
        let journal: NoticeJournalStorage<PersonalNoticeJournal>
        do {
            journal = try NoticeJournalStorage(\.personalNoticeJournal) {
                var migrated = PersonalNoticeJournal()
                if let data = defaults.object(forKey: ledgerKey) {
                    guard let data = data as? Data else { throw StoreError.database }
                    migrated.ledger = try PropertyListDecoder().decode(CompanionNoticeLedger.self, from: data)
                } else if let raw = defaults.object(forKey: oldKey) {
                    guard let previous = raw as? [String: Date] else { throw StoreError.database }
                    for (id, date) in previous {
                        migrated.ledger.entries[id] = .init(date: date, localDay: CompanionNoticeLedger.day(date, calendar: calendar), spent: false)
                    }
                }
                return migrated
            }
        } catch {
            status = "Не удалось прочитать историю расписания."
            return
        }
        let desired: [CompanionNoticeSlot]
        if slots.isEmpty && journal.current.ledger.entries.isEmpty {
            desired = []
        } else {
            var pendingForBudget = Set(pending.map(\.identifier))
            if now >= journal.current.ledger.latestCheck {
                // A crash may leave a future reservation committed before UN.add or queue verification.
                for slot in journal.current.desired where slot.date > now && !journal.current.applied.contains(slot.id) {
                    pendingForBudget.insert(slot.id)
                }
            }
            desired = journal.current.ledger.reconcile(now: now, pending: pendingForBudget, slots: slots, calendar: calendar)
        }
        let ids = Set(desired.map(\.id))
        let stale = pending.map(\.identifier).filter { !ids.contains($0) }
        journal.current.ledger.entries = journal.current.ledger.entries.filter { $0.value.spent || ids.contains($0.key) }
        journal.current.desired = desired
        journal.current.hero = desired.isEmpty ? nil : hero
        let title = "Мой Компаньон · \(hero.name)"
        func matches(_ request: UNNotificationRequest, _ slot: CompanionNoticeSlot) -> Bool {
            request.identifier == slot.id && request.content.title == title && request.content.body == slot.body &&
                request.content.categoryIdentifier == slot.category &&
                (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() == slot.date
        }
        do {
            try journal.persist()
            defaults.removeObject(forKey: ledgerKey)
            defaults.removeObject(forKey: oldKey)
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
            for slot in desired {
                let previous = journal.current.ledger.entries[slot.id]
                journal.current.ledger.reserve(slot, calendar: calendar)
                try journal.persist()
                if !pending.contains(where: { matches($0, slot) }) {
                    let content = UNMutableNotificationContent()
                    content.title = title
                    content.body = slot.body
                    content.categoryIdentifier = slot.category
                    var parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: slot.date)
                    parts.timeZone = calendar.timeZone
                    let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                    do {
                        try await NoticeDelivery.add(UNNotificationRequest(identifier: slot.id, content: content, trigger: trigger), to: center)
                    } catch {
                        journal.current.ledger.entries[slot.id] = previous
                        try journal.persist()
                    }
                }
            }
            let applied = await center.pendingNotificationRequests().filter { CompanionNoticeSlot.owns($0.identifier) }
            journal.current.applied = Set(desired.filter { slot in applied.contains { matches($0, slot) } }.map(\.id))
            try journal.persist()
            let verified = applied.count == desired.count && desired.allSatisfy { slot in applied.contains { matches($0, slot) } }
            if !verified { status = "Система пока не подтвердила расписание." }
            else if !settings.enabled || (!settings.morning && !settings.bedtime && !settings.support && !settings.gifts) { status = "Личные уведомления выключены." }
            else if !permitted { status = "Для доставки разрешите уведомления в настройках iOS." }
            else if mode == .safe || mode == .paused { status = "В этом режиме личные уведомления приостановлены." }
            else { status = "Запланировано на ближайшие три дня: \(applied.count)." }
        } catch { status = "Не удалось обновить расписание. Повторим при следующем открытии." }
    }
}

private struct NoticeReconciliation: ViewModifier {
    let hero: Hero
    let mode: CompanionMode
    let schedule: DaySchedule
    let latestUnlock: String?
    let intensity: CommunicationIntensity
    @Environment(\.scenePhase) private var phase
    @AppStorage("companionMorningEnabled") private var morning = false
    @AppStorage("companionBedtimeEnabled") private var bedtime = false
    @AppStorage("companionSupportEnabled") private var support = false
    @AppStorage("companionGiftsEnabled") private var gifts = false
    @AppStorage("allNotificationsEnabled") private var enabled = true
    @AppStorage("companionMorningTime") private var morningTime = 480
    @AppStorage("companionBedtimeTime") private var bedtimeTime = 1365
    @AppStorage("quietStartHour") private var quietStart = 23
    @AppStorage("quietEndHour") private var quietEnd = 7

    func body(content: Content) -> some View {
        let preferences = NoticePreferences(morning: morning, bedtime: bedtime, morningTime: morningTime,
                                           bedtimeTime: bedtimeTime, quietStart: quietStart, quietEnd: quietEnd,
                                           support: support, gifts: gifts, enabled: enabled, schedule: schedule, intensity: intensity)
        let refresh = {
            Task { @MainActor in await CompanionNotices.shared.update(hero: hero, mode: mode, settings: preferences) }
        }
        return content.onAppear { _ = refresh() }
            .onChange(of: enabled) { _, _ in Task { _ = await ReminderNotifications.shared.reconcile() } }
            .onChange(of: phase) { _, value in if value == .active { _ = refresh() } }
            .onChange(of: preferences) { _, _ in _ = refresh() }
            .onChange(of: hero) { _, _ in _ = refresh() }
            .onChange(of: mode) { _, _ in _ = refresh() }
            .onChange(of: latestUnlock) { _, _ in if gifts { _ = refresh() } }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in _ = refresh() }
    }
}

extension View {
    func companionNoticeReconciliation(hero: Hero, mode: CompanionMode, schedule: DaySchedule, latestUnlock: String?,
                                      intensity: CommunicationIntensity) -> some View {
        modifier(NoticeReconciliation(hero: hero, mode: mode, schedule: schedule, latestUnlock: latestUnlock, intensity: intensity))
    }
}

struct CompanionNoticePanel: View {
    @ObservedObject private var notices = CompanionNotices.shared
    @AppStorage("companionMorningEnabled") private var morning = false
    @AppStorage("companionBedtimeEnabled") private var bedtime = false
    @AppStorage("companionSupportEnabled") private var support = false
    @AppStorage("companionGiftsEnabled") private var gifts = false
    @AppStorage("allNotificationsEnabled") private var enabled = true
    @State private var confirmDisable = false
    @AppStorage("companionMorningTime") private var morningTime = 480
    @AppStorage("companionBedtimeTime") private var bedtimeTime = 1365
    @AppStorage("quietStartHour") private var quietStart = 23
    @AppStorage("quietEndHour") private var quietEnd = 7
    @AppStorage("allowTasksDuringQuiet") private var allowTasks = true
    @State private var requesting = false
    @State private var authorizationMessage = ""

    var body: some View {
        Form {
            Section {
                Toggle("Все уведомления", isOn: Binding(get: { enabled }, set: { value in
                    if value { enabled = true } else { confirmDisable = true }
                }))
            }
            Section("Расписание") {
                noticeToggle("Доброе утро", setting: $morning)
                if morning { timePicker("Утром", setting: $morningTime) }
                noticeToggle("Пора отдыхать", setting: $bedtime)
                if bedtime { timePicker("Перед сном", setting: $bedtimeTime) }
                noticeToggle("Редкая поддержка", setting: $support)
                noticeToggle("Сообщать о полученных находках", setting: $gifts)
                if support || gifts {
                    Text("До двух личных сообщений в день. Сначала учитываются утро и сон. Для календаря предусмотрено отдельное предупреждение.")
                        .font(.footnote)
                }
            }.disabled(!enabled)
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
        .confirmationDialog("Отключить все уведомления?", isPresented: $confirmDisable, titleVisibility: .visible) {
            Button("Отключить все уведомления", role: .destructive) {
                enabled = false
                Task { await NoticeDelivery.cancelWhenDisabled() }
            }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Предупреждения о событиях и задачах будут отменены. Сами задачи и события сохранятся.")
        }
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
