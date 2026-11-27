import CryptoKit
import EventKit
import EventKitUI
import SwiftUI
import UserNotifications
import WidgetKit

private actor CalendarReader {
    private let eventStore = EKEventStore()
    func readEvents(now: Date, showTitles: Bool) -> CalendarSnapshot {
        guard let horizon = Calendar.current.date(byAdding: .day, value: 7, to: now) else {
            return CalendarSnapshot()
        }
        let predicate = eventStore.predicateForEvents(withStart: now, end: horizon, calendars: nil)
        let fetched = eventStore.events(matching: predicate)
        func key(for event: EKEvent) -> String {
            let occurrence = "\(event.calendarItemIdentifier)|\(event.startDate.timeIntervalSince1970)"
            return SHA256.hash(data: Data(occurrence.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        var cancelled = Set<String>()
        for event in fetched where event.status == .canceled && event.startDate != nil {
            cancelled.insert(key(for: event))
            if cancelled.count == 100 { break }
        }
        let events = fetched.filter {
            $0.status != .canceled && ($0.endDate > now || $0.startDate >= now)
        }.sorted {
            if $0.startDate != $1.startDate { return $0.startDate < $1.startDate }
            return $0.calendarItemIdentifier < $1.calendarItemIdentifier
        }
        var seen = Set<String>()
        var items: [CalendarItem] = []
        for event in events {
            let eventID = key(for: event)
            guard seen.insert(eventID).inserted else { continue }
            if items.count == 100 { break }
            let title = showTitles ? String((event.title ?? "").prefix(64)) : ""
            let seriesKey = event.hasRecurrenceRules || event.isDetached ? nil :
                SHA256.hash(data: Data(event.calendarItemIdentifier.utf8)).map { String(format: "%02x", $0) }.joined()
            items.append(CalendarItem(id: eventID, start: event.startDate, end: event.endDate,
                                      allDay: event.isAllDay, title: title.isEmpty ? nil : title, seriesKey: seriesKey))
        }
        return CalendarSnapshot(updatedAt: now, expiry: now.addingTimeInterval(12 * 3600),
                                events: items, overflow: seen.count > 100,
                                cancelledOccurrenceIDs: cancelled.isEmpty ? nil : cancelled)
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
        guard NoticeDelivery.enabled else { message = "Сначала включите уведомления в настройках компаньона."; return }
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
            case .denied: message = enabled ? "Чтение календаря выключено в настройках iPhone." : ""
            case .restricted: message = enabled ? "Чтение календаря ограничено настройками устройства." : ""
            case .writeOnly where enabled: message = "Разрешено только добавление событий."
            case .notDetermined, .fullAccess, .writeOnly: message = ""
            @unknown default: message = enabled ? "Чтение календаря недоступно." : ""
            }
            do {
                let store = try Store.shared()
                let previous = try store.read().calendarSnapshot
                // Preserve the validated horizon during bursts of identical EventKit notifications.
                let recentlyChecked = previous.isFresh(at: now) && previous.updatedAt.map { now.timeIntervalSince($0) < 900 } == true
                let sameContent = previous.events == next.events && previous.overflow == next.overflow &&
                    previous.cancelledOccurrenceIDs == next.cancelledOccurrenceIDs
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
        let allowed = NoticeDelivery.enabled && [.authorized, .provisional, .ephemeral].contains(status)
        let offset = defaults.object(forKey: "calendarWarningMinutes") as? Int ?? 15
        let quietStart = defaults.object(forKey: "quietStartHour") as? Int ?? 23
        let quietEnd = defaults.object(forKey: "quietEndHour") as? Int ?? 7
        let calendar = Calendar.current
        let ledgerKey = "calendarWarningReservations"
        let warningsEnabled = allowed && defaults.bool(forKey: "calendarWarnings") && value.isFresh(at: now)
        if !warningsEnabled && !owned.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(owned))
        }
        let journal: NoticeJournalStorage<CalendarNoticeJournal>
        do {
            journal = try NoticeJournalStorage(\.calendarNoticeJournal) {
                var migrated = CalendarNoticeJournal()
                if let raw = defaults.object(forKey: ledgerKey) {
                    guard let previous = raw as? [String: Date] else { throw StoreError.database }
                    migrated.reservations = previous
                }
                return migrated
            }
        } catch { message = "Не удалось прочитать историю календарных предупреждений."; return }
        let cutoff = now.addingTimeInterval(-8 * 86400)
        var ledger = journal.current.reservations.filter { $0.value >= cutoff }
        // Import visible deliveries from versions predating the local reservation ledger.
        for notice in await center.deliveredNotifications() where notice.date >= cutoff {
            let id = notice.request.identifier
            guard id.hasPrefix(prefix), let key = id.dropFirst(prefix.count).split(separator: ".").first else { continue }
            if ledger[String(key)] == nil { ledger[String(key)] = notice.date }
        }
        let events = warningsEnabled
            ? value.warningDates(now: now, offset: offset, quietStart: quietStart, quietEnd: quietEnd,
                                 calendar: calendar, reservations: ledger) : [:]
        let requests = Dictionary(uniqueKeysWithValues: events.map { (prefix + $0.key + ".\(offset)", $0.value) })
        let desired = Set(requests.keys)
        func matches(_ request: UNNotificationRequest, id: String, fire: Date) -> Bool {
            guard request.identifier == id, let date = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() else { return false }
            return abs(date.timeIntervalSince(fire)) < 1
        }
        // Reserve before registering with the OS. After an interruption an elapsed reservation
        // consumes its day even if Focus or system settings suppressed delivery.
        ledger = ledger.filter { $0.value <= now }
        for (key, fire) in events where pending.contains(where: { matches($0, id: prefix + key + ".\(offset)", fire: fire) }) {
            ledger[key] = fire
        }
        journal.current.reservations = ledger
        journal.current.desired = requests
        do {
            try journal.persist()
            defaults.removeObject(forKey: ledgerKey)
        } catch { message = "Не удалось сохранить расписание предупреждений."; return }
        if warningsEnabled { center.removePendingNotificationRequests(withIdentifiers: Array(owned.subtracting(desired))) }
        for (eventID, fire) in events {
            let id = prefix + eventID + ".\(offset)"
            guard !pending.contains(where: { matches($0, id: id, fire: fire) }) else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Мой Компаньон"
            content.body = "Через \(offset) мин запланировано событие."
            var date = Calendar(identifier: .gregorian)
            date.timeZone = TimeZone(secondsFromGMT: 0)!
            let components = date.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: fire)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            do {
                try await CalendarSnapshot.registerWarning(eventID, at: fire, ledger: &ledger,
                                                          save: {
                    journal.current.reservations = $0
                    try journal.persist()
                }) {
                    try await NoticeDelivery.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger), to: center)
                }
            } catch { message = "Некоторые предупреждения не удалось запланировать." }
        }

        let applied = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(prefix) }
        journal.current.applied = requests.filter { id, fire in applied.contains { matches($0, id: id, fire: fire) } }
        do { try journal.persist() }
        catch { message = "Не удалось сохранить подтверждение очереди предупреждений."; return }
        if Set(applied.map(\.identifier)) != desired || journal.current.applied != requests {
            message = "Расписание предупреждений обновлено частично."
        }
    }
}

struct CalendarRefresh: ViewModifier {
    @Environment(\.scenePhase) private var phase
    @AppStorage("quietStartHour") private var quietStart = 23
    @AppStorage("quietEndHour") private var quietEnd = 7
    @AppStorage("allNotificationsEnabled") private var enabled = true
    func body(content: Content) -> some View {
        content.task(id: phase) {
            if phase == .active { await CalendarController.shared.refresh() }
        }.onChange(of: enabled) { _, _ in
            Task { await CalendarController.shared.refresh() }
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
    @State private var showDay = false
    @State private var selectedDate = Date()

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
                if enabled && EKEventStore.authorizationStatus(for: .event) == .denied,
                   let settings = URL(string: UIApplication.openSettingsURLString) {
                    Link("Открыть настройки iPhone", destination: settings)
                }
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
                Section("Расписание") {
                    let now = Date()
                    let calendar = Calendar.current
                    let today = calendar.startOfDay(for: now)
                    let lastDay = calendar.date(byAdding: .day, value: 6, to: today) ?? today
                    let day = min(max(calendar.startOfDay(for: selectedDate), today), lastDay)
                    let interval = calendar.dateInterval(of: .day, for: day)
                    let items = model.snapshot.upcoming(at: now).filter { item in
                        guard showDay, let interval else { return true }
                        return item.start < interval.end && (item.end > interval.start || item.start >= interval.start)
                    }
                    if !model.snapshot.isFresh(at: now) { Text("Актуальное расписание недоступно") }
                    else {
                        Picker("Период", selection: $showDay) {
                            Text("Семь дней").tag(false)
                            Text("День").tag(true)
                        }.pickerStyle(.segmented)
                        if showDay {
                            DatePicker("Дата", selection: Binding(get: { day }, set: { selectedDate = $0 }),
                                       in: today...lastDay, displayedComponents: .date)
                        }
                        if items.isEmpty {
                            if model.snapshot.overflow { Text("Среди загруженных событий подходящих нет.") }
                            else { Text(showDay ? "На этот день предстоящих событий нет." : "В ближайшие семь дней событий нет") }
                        }
                        ForEach(items) { item in
                            VStack(alignment: .leading) {
                                Text(item.label)
                                Text("\(item.start.formatted(date: .abbreviated, time: .omitted)) · \(item.timeLabel)").font(.caption)
                            }
                        }
                        if model.snapshot.overflow { Text("Показаны первые 100 событий.") }
                    }
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
