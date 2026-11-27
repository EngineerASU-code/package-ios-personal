import CryptoKit
import EventKit
import EventKitUI
import SwiftUI
import UserNotifications
import WidgetKit

@MainActor
final class CalendarController: ObservableObject {
    static let shared = CalendarController()
    let eventStore = EKEventStore()
    @Published private(set) var snapshot = CalendarSnapshot()
    @Published var message = ""
    private var refreshing = false
    private var needsRefresh = false
    private let defaults = UserDefaults.standard
    private let center = UNUserNotificationCenter.current()
    private let prefix = "companion.calendar."

    func connect() async {
        do {
            let status = EKEventStore.authorizationStatus(for: .event)
            if status == .notDetermined || status == .writeOnly {
                _ = try await eventStore.requestFullAccessToEvents()
            }
            defaults.set(true, forKey: "calendarEnabled")
            await refresh()
        } catch { message = "Не удалось запросить доступ к календарю." }
    }

    func enableWarnings() async {
        do {
            let granted = try await center.requestAuthorization(options: [.alert])
            defaults.set(granted, forKey: "calendarWarnings")
            await refresh()
            if !granted { message = "Уведомления выключены в настройках iPhone." }
        } catch { message = "Не удалось запросить разрешение на уведомления." }
    }

    private func readEvents(now: Date) -> CalendarSnapshot {
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        let predicate = eventStore.predicateForEvents(withStart: now, end: horizon, calendars: nil)
        let events = eventStore.events(matching: predicate).filter {
            $0.status != .canceled && ($0.endDate > now || $0.startDate >= now)
        }.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.calendarItemIdentifier < $1.calendarItemIdentifier
        }
        let showTitles = defaults.bool(forKey: "calendarTitles")
        var seen = Set<String>()
        var items: [CalendarItem] = []
        for event in events {
            let occurrence = "\(event.calendarItemIdentifier)|\(event.startDate.timeIntervalSince1970)"
            let key = SHA256.hash(data: Data(occurrence.utf8)).map { String(format: "%02x", $0) }.joined()
            guard seen.insert(key).inserted else { continue }
            if items.count == 100 { break }
            let title = showTitles ? String((event.title ?? "").prefix(64)) : ""
            items.append(CalendarItem(id: key, start: event.startDate, end: event.endDate,
                                      allDay: event.isAllDay, title: title.isEmpty ? nil : title))
        }
        return CalendarSnapshot(updatedAt: now, expiry: now.addingTimeInterval(12 * 3600),
                                events: items, overflow: seen.count > 100)
    }

    func refresh() async {
        if refreshing { needsRefresh = true; return }
        refreshing = true
        defer { refreshing = false }
        repeat {
            needsRefresh = false
            let now = Date()
            let enabled = defaults.bool(forKey: "calendarEnabled")
            let status = EKEventStore.authorizationStatus(for: .event)
            let readable = enabled && status == .fullAccess
            let next = readable ? readEvents(now: now) : CalendarSnapshot()
            snapshot = next
            switch status {
            case .denied, .restricted: message = enabled ? "Чтение календаря недоступно. Проверьте настройки iPhone." : ""
            case .writeOnly where enabled: message = "Разрешено только добавление событий."
            default: message = ""
            }
            do {
                let store = try Store.shared()
                if try store.read().calendarSnapshot != next {
                    try store.update { $0.calendarSnapshot = next }
                    WidgetCenter.shared.reloadTimelines(ofKind: "Companion")
                }
            } catch { message = "Не удалось обновить локальный снимок календаря." }
            await reconcile(next, now: now)
        } while needsRefresh
    }

    private func reconcile(_ value: CalendarSnapshot, now: Date) async {
        let pending = await center.pendingNotificationRequests()
        let owned = Set(pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        let status = await center.notificationSettings().authorizationStatus
        let allowed = status == .authorized || status == .provisional || status == .ephemeral
        let offset = defaults.object(forKey: "calendarWarningMinutes") as? Int ?? 15
        let quietStart = defaults.object(forKey: "quietStartHour") as? Int ?? 23
        let quietEnd = defaults.object(forKey: "quietEndHour") as? Int ?? 7
        let calendar = Calendar.current
        var requests: [String: Date] = [:]
        var daily: [Date: Int] = [:]
        for request in pending where CompanionNoticeSlot.owns(request.identifier) {
            if let fire = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() {
                daily[calendar.startOfDay(for: fire), default: 0] += 1
            }
        }
        var overflow = false
        if allowed && defaults.bool(forKey: "calendarWarnings") {
            for item in value.upcoming(at: now) where !item.allDay {
                let fire = item.start.addingTimeInterval(Double(-offset * 60))
                let hour = calendar.component(.hour, from: fire)
                let quiet = quietStart < quietEnd ? (quietStart..<quietEnd).contains(hour)
                    : quietStart != quietEnd && (hour >= quietStart || hour < quietEnd)
                guard fire > now, !quiet else { continue }
                let day = calendar.startOfDay(for: fire)
                guard daily[day, default: 0] < 3 else { continue }
                if requests.count == 5 { overflow = true; break }
                requests[prefix + item.id + ".\(offset)"] = fire
                daily[day, default: 0] += 1
            }
        }
        let desired = Set(requests.keys)
        center.removePendingNotificationRequests(withIdentifiers: Array(owned.subtracting(desired)))
        for (id, fire) in requests where !owned.contains(id) {
            let content = UNMutableNotificationContent()
            content.title = "Мой Компаньон"
            content.body = "Через \(offset) мин запланировано событие."
            var date = Calendar(identifier: .gregorian)
            date.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = date.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) }
            catch { message = "Некоторые предупреждения не удалось запланировать." }
        }
        if overflow { message = "Запланированы пять ближайших предупреждений. Откройте приложение для обновления." }
        let applied = Set(await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) })
        if applied != desired { message = "Расписание предупреждений обновлено частично." }
    }
}

struct CalendarRefresh: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @AppStorage("quietStartHour") private var quietStart = 23
    @AppStorage("quietEndHour") private var quietEnd = 7
    func body(content: Content) -> some View {
        content.task(id: phase) {
            if phase == .active { await CalendarController.shared.refresh() }
        }.onChange(of: [quietStart, quietEnd]) { _, _ in
            if phase == .active { Task { await CalendarController.shared.refresh() } }
        }.onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged)) { _ in
            if phase == .active { Task { await CalendarController.shared.refresh() } }
        }.onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            if phase == .active { Task { await CalendarController.shared.refresh() } }
        }
    }
}

struct CalendarPanel: View {
    @ObservedObject private var model = CalendarController.shared
    @AppStorage("calendarEnabled") private var enabled = false
    @AppStorage("calendarTitles") private var titles = false
    @AppStorage("calendarWarnings") private var warnings = false
    @AppStorage("calendarWarningMinutes") private var offset = 15
    @State private var editing = false

    var body: some View {
        Form {
            Section("Системный календарь") {
                Button("Создать событие") { editing = true }
                if enabled {
                    Button("Отключить календарь") {
                        enabled = false
                        titles = false
                        warnings = false
                        Task { await model.refresh() }
                    }
                } else {
                    Button("Подключить календарь для чтения") { Task { await model.connect() } }
                }
                if !model.message.isEmpty { Text(model.message).font(.footnote) }
            }
            if enabled {
                Section("Настройки") {
                    Toggle("Показывать названия в расписании и виджете", isOn: $titles)
                    Toggle("Предупреждать о событиях", isOn: Binding(get: { warnings }, set: { value in
                        if value { Task { await model.enableWarnings() } }
                        else { warnings = false; Task { await model.refresh() } }
                    }))
                    if warnings {
                        Picker("Предупреждать за", selection: $offset) {
                            ForEach([5, 15, 30, 60], id: \.self) { Text("\($0) мин").tag($0) }
                        }
                    }
                    Button("Обновить расписание") { Task { await model.refresh() } }
                }
                Section("Ближайшие семь дней") {
                    let now = Date()
                    if !model.snapshot.isFresh(at: now) { Text("Актуальное расписание недоступно") }
                    else if model.snapshot.upcoming(at: now).isEmpty { Text("В ближайшие семь дней событий нет") }
                    ForEach(model.snapshot.upcoming(at: now)) { item in
                        VStack(alignment: .leading) {
                            Text(item.label)
                            Text("\(item.start.formatted(date: .abbreviated, time: .omitted)) · \(item.timeLabel)").font(.caption)
                        }
                    }
                    if model.snapshot.overflow { Text("Показаны первые 100 событий.") }
                }
            }
        }.navigationTitle("Календарь")
        .onChange(of: titles) { _, _ in Task { await model.refresh() } }
        .onChange(of: offset) { _, _ in Task { await model.refresh() } }
        .sheet(isPresented: $editing) { CalendarEditor(store: model.eventStore) }
    }
}

private struct CalendarEditor: UIViewControllerRepresentable {
    let store: EKEventStore
    @Environment(\.dismiss) private var dismiss

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let finish: () -> Void
        init(finish: @escaping () -> Void) { self.finish = finish }
        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            finish()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator { dismiss() } }
    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let editor = EKEventEditViewController()
        editor.eventStore = store
        editor.event = EKEvent(eventStore: store)
        editor.editViewDelegate = context.coordinator
        return editor
    }
    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}
}
