import SwiftUI
import WidgetKit
import UserNotifications

@main struct CompanionApp: App {
    @UIApplicationDelegateAdaptor(NotificationActions.self) private var actions
    var body: some Scene { WindowGroup { Home() } }
}

struct Home: View {
    @Environment(\.scenePhase) private var phase
    @State private var state = Companion()
    @State private var message = ""
    @AppStorage("quietStartHour") private var quietStartHour = 23
    @AppStorage("quietEndHour") private var quietEndHour = 7
    @AppStorage("allowTasksDuringQuiet") private var allowTasksDuringQuiet = true
    @State private var changingReminder = false
    private let notice = "mycompanion.preview"
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Button { save { $0.react() } } label: { CompanionScene(state: state, display: DayTimeline.display(state, at: Date(), calendar: .current)) }
                        .buttonStyle(.plain).disabled(state.mode == .safe || state.mode == .paused)
                    Picker("Персонаж", selection: Binding(get: { state.hero }, set: { hero in
                        save {
                            $0.hero = hero
                            _ = $0.greetIfNeeded(at: Date(), calendar: .current)
                        }
                    })) {
                        ForEach(Hero.allCases, id: \.self) { Text($0.name).tag($0) }
                    }
                    if let pack = state.hero.pack {
                        let finds = pack.finds.filter { find in state.unlocks.contains { $0.id == find.id } }
                        if !finds.isEmpty {
                            NavigationLink("Находки · \(finds.count)") {
                                List(finds, id: \.id) { find in
                                    VStack(alignment: .leading) {
                                        Text(find.title).font(.headline)
                                        Text(pack.byID[find.lineID]?.text ?? "")
                                    }
                                }.navigationTitle("Находки")
                            }
                        }
                    }
                    Picker("Режим", selection: Binding(get: { state.mode }, set: { mode in save { $0.mode = mode } })) {
                        ForEach(CompanionMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Button("Напомнить через минуту") { Task { await schedule() } }
                        .disabled(changingReminder)
                    Button("Отменить напоминание") { Task { await cancel() } }
                        .disabled(changingReminder)
                    NavigationLink("Напоминания") { ReminderList() }
                    NavigationLink("Календарь") { CalendarPanel() }
                    NavigationLink("Уведомления и тихие часы") { CompanionNoticePanel() }
                    DisclosureGroup("Как добавить виджет") {
                        Text("Удерживайте свободное место на экране «Домой», откройте галерею виджетов и найдите «Мой Компаньон». После добавления удерживайте виджет, чтобы выбрать героя.")
                    }
                    Text(message).font(.footnote)
                }.padding()
            }.navigationTitle("Мой Компаньон")
        }
        .modifier(CalendarRefresh())
        .companionNoticeReconciliation(hero: state.hero, mode: state.mode)
        .onChange(of: quietStartHour) { _, _ in refreshSchedules() }
        .onChange(of: quietEndHour) { _, _ in refreshSchedules() }
        .onChange(of: allowTasksDuringQuiet) { _, _ in refreshSchedules() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            if phase == .active { refreshSchedules() }
        }
        .onAppear { refresh() }.onChange(of: phase) { _, next in if next == .active { refresh() } }
    }
    func refreshSchedules() {
        Task {
            _ = await ReminderNotifications.shared.reconcile()
            await CalendarController.shared.refresh()
        }
    }
    func refresh() {
        Task { _ = await ReminderNotifications.shared.reconcile() }
        do {
            let store = try Store.shared()
            state = try store.read()
            let date = Date()
            let calendar = Calendar.current
            var preview = state
            if preview.greetIfNeeded(at: date, calendar: calendar) {
                state = try store.update { _ = $0.greetIfNeeded(at: date, calendar: calendar) }
                WidgetCenter.shared.reloadTimelines(ofKind: "Companion")
            }
        } catch { message = "Общее хранилище недоступно" }
    }
    func save(_ change: (inout Companion) -> Void) {
        do {
            state = try Store.shared().update(change)
            WidgetCenter.shared.reloadTimelines(ofKind: "Companion")
            message = ""
        } catch { message = "Не удалось сохранить изменение" }
    }
    @MainActor func cancel() async {
        guard !changingReminder else { return }
        changingReminder = true
        defer { changingReminder = false }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notice])
        let pending = await center.pendingNotificationRequests()
        message = pending.contains { $0.identifier == notice }
            ? "Не удалось отменить напоминание" : "Напоминание отменено"
    }

    @MainActor func schedule() async {
        guard !changingReminder else { return }
        changingReminder = true
        defer { changingReminder = false }
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert]) else { message = "Уведомления выключены"; return }
            let content = UNMutableNotificationContent()
            content.title = "Мой Компаньон"
            content.body = "Время для небольшой передышки."
            try await center.add(UNNotificationRequest(identifier: notice, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)))
            let pending = await center.pendingNotificationRequests()
            message = pending.filter { $0.identifier == notice }.count == 1
                ? "Напоминание запланировано" : "Не удалось подтвердить напоминание"
        } catch { message = "Не удалось создать напоминание" }
    }
}
