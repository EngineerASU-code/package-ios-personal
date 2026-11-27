import CryptoKit
import EventKit
import EventKitUI
import SwiftUI
import UserNotifications
import WidgetKit

private actor CalendarReader {
    private let eventStore = EKEventStore()
    func readEvents(now: Date, showTitles: Bool) -> CalendarSnapshot {
        let horizon = Calendar.current.date(byAdding: .day, value: 7, to: now)!
        let predicate = eventStore.predicateForEvents(withStart: now, end: horizon, calendars: nil)
        let events = eventStore.events(matching: predicate).filter {
            $0.status != .canceled && ($0.endDate > now || $0.startDate >= now)
        }.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.calendarItemIdentifier < $1.calendarItemIdentifier
        }
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
}

@MainActor
final class CalendarController: ObservableObject {
    static let shared = CalendarController()
    let eventStore = EKEventStore()
    @Published private(set) var snapshot = CalendarSnapshot()
    @Published var message = ""
    private let reader = CalendarReader()
    private var refreshing = false
    private var needsRefresh = false
    private var refreshWaiters: [CheckedContinuation<Void, Never>] = []
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

    private var access: CalendarPrivacy {
        guard defaults.bool(forKey: "calendarEnabled"),
              EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return .off }
        return defaults.bool(forKey: "calendarTitles") ? .titles : .privateTitles
    }

    func refresh() async {
        if CalendarPrivacy.publish(access) {
            WidgetCenter.shared.reloadTimelines(ofKind: "Companion")
        }
        snapshot = snapshot.filtered(by: access)
        if refreshing {
            needsRefresh = true
            await withCheckedContinuation { refreshWaiters.append($0) }
            return
        }
        refreshing = true
        defer {
            refreshing = false
            for waiter in refreshWaiters { waiter.resume() }
            refreshWaiters.removeAll()
        }
        repeat {
            needsRefresh = false
            let now = Date()
            let enabled = defaults.bool(forKey: "calendarEnabled")
            let status = EKEventStore.authorizationStatus(for: .event)
            let privacy = access
            let next = privacy == .off ? CalendarSnapshot() : await reader.readEvents(now: now, showTitles: privacy == .titles)
            guard access == privacy else {
                if CalendarPrivacy.publish(access) { WidgetCenter.shared.reloadTimelines(ofKind: "Companion") }
                needsRefresh = true
                continue
            }
            snapshot = next
            switch status {
            case .denied, .restricted: message = enabled ? "Чтение календаря недоступно. Проверьте настройки iPhone." : ""
            case .writeOnly where enabled: message = "Разрешено только добавление событий."
            default: message = ""
            }
            do {
                let store = try Store.shared()
                let previous = try store.read().calendarSnapshot
                // Preserve the validated horizon during bursts of identical EventKit notifications.
                let recentlyChecked = previous.isFresh(at: now) && previous.updatedAt.map { now.timeIntervalSince($0) < 900 } == true
                let sameContent = previous.events == next.events && previous.overflow == next.overflow
                if previous != next && !(privacy != .off && recentlyChecked && sameContent) {
                    try store.update { $0.replaceCalendarSnapshot(next, at: now) }
                    WidgetCenter.shared.reloadTimelines(ofKind: "Companion")
                } else {
                    snapshot = previous.filtered(by: privacy)
                }
            } catch { message = "Не удалось обновить локальный снимок календаря." }
            await reconcile(snapshot, now: now)
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
        let ledgerKey = "calendarWarningReservations"
        let cutoff = now.addingTimeInterval(-8 * 86400)
        var ledger = (defaults.dictionary(forKey: ledgerKey) as? [String: Date] ?? [:]).filter { $0.value >= cutoff }
        // Import visible deliveries from versions predating the local reservation ledger.
        for notice in await center.deliveredNotifications() where notice.date >= cutoff {
            let id = notice.request.identifier
            guard id.hasPrefix(prefix), let key = id.dropFirst(prefix.count).split(separator: ".").first else { continue }
            if ledger[String(key)] == nil { ledger[String(key)] = notice.date }
        }
        let events = allowed && defaults.bool(forKey: "calendarWarnings")
            ? value.warningDates(now: now, offset: offset, quietStart: quietStart, quietEnd: quietEnd,
                                 calendar: calendar, reservations: ledger) : [:]
        let requests = Dictionary(uniqueKeysWithValues: events.map { (prefix + $0.key + ".\(offset)", $0.value) })
        let desired = Set(requests.keys)
        center.removePendingNotificationRequests(withIdentifiers: Array(owned.subtracting(desired)))
        // Reserve before registering with the OS. After an interruption an elapsed reservation
        // consumes its day even if Focus or system settings suppressed delivery.
        ledger = ledger.filter { $0.value <= now }
        for (key, fire) in events where owned.contains(prefix + key + ".\(offset)") {
            ledger[key] = fire
        }
        defaults.set(ledger, forKey: ledgerKey)
        for (eventID, fire) in events {
            let id = prefix + eventID + ".\(offset)"
            guard !owned.contains(id) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Мой Компаньон"
            content.body = "Через \(offset) мин запланировано событие."
            var date = Calendar(identifier: .gregorian)
            date.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = date.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            do {
                try await CalendarSnapshot.registerWarning(eventID, at: fire, ledger: &ledger,
                                                          save: { defaults.set($0, forKey: ledgerKey) }) {
                    try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                }
            } catch { message = "Некоторые предупреждения не удалось запланировать." }
        }

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
                        Text("До одного предупреждения в сутки в пределах актуального расписания.").font(.footnote)
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
