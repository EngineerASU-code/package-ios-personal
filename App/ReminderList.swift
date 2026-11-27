import AppIntents
import SwiftUI
import UserNotifications
import WidgetKit

struct CreateLocalReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Создать напоминание"
    static var openAppWhenRun = true

    @Parameter(title: "Название", requestValueDialog: "О чём напомнить?")
    var taskTitle: String

    @Parameter(title: "Срок", requestValueDialog: "Когда напомнить?")
    var dueDate: Date

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw $taskTitle.needsValueError("О чём напомнить?") }
        guard dueDate > Date() else { throw $dueDate.needsValueError("На какое время в будущем поставить напоминание?") }

        let status = try await ReminderNotifications.shared.create(title: name, due: dueDate)
        if status.isEmpty { return .result(dialog: "Напоминание сохранено.") }
        return .result(dialog: "Напоминание сохранено. \(status)")
    }
}

struct ReminderOccurrence: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Локальная задача"
    static let defaultQuery = ReminderOccurrenceQuery()
    let task: LocalReminder
    var id: String { task.id.uuidString + "." + String(task.revision) }
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(task.title)", subtitle: "\(task.target?.formatted() ?? "Без срока")")
    }
}

struct ReminderOccurrenceQuery: EntityQuery {
    func suggestedEntities() async throws -> [ReminderOccurrence] {
        try Store.shared().read().reminders.filter { $0.completedAt == nil }
            .sorted { ($0.target ?? .distantFuture) < ($1.target ?? .distantFuture) }
            .map { ReminderOccurrence(task: $0) }
    }
    func entities(for identifiers: [String]) async throws -> [ReminderOccurrence] {
        let ids = Set(identifiers)
        return try await suggestedEntities().filter { ids.contains($0.id) }
    }
}

struct CompleteReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Завершить локальную задачу"
    @Parameter(title: "Задача") var occurrence: ReminderOccurrence
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let task = occurrence.task
        let status = try await ReminderNotifications.shared.apply(id: task.id, revision: task.revision, snoozeMinutes: nil)
        return .result(dialog: "\(status.isEmpty ? "Готово." : status)")
    }
}

struct SnoozeReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Отложить задачу на 10 минут"
    @Parameter(title: "Задача") var occurrence: ReminderOccurrence
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let task = occurrence.task
        let status = try await ReminderNotifications.shared.apply(id: task.id, revision: task.revision, snoozeMinutes: 10)
        return .result(dialog: "\(status.isEmpty ? "Готово." : status)")
    }
}

struct QuickReminderIntent: AppIntent {
    static var title: LocalizedStringResource = "Напомнить о перерыве в 16 часов"
    static var openAppWhenRun = true
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let due = Calendar.current.nextDate(after: Date(), matching: DateComponents(hour: 16, minute: 0, second: 0),
                                                  matchingPolicy: .nextTime) else {
            return .result(dialog: "Не удалось определить время перерыва.")
        }
        let status = try await ReminderNotifications.shared.create(title: "Перерыв", due: due, preset: true)
        return .result(dialog: "\(status.isEmpty ? "Задача «Перерыв» есть в списке." : status)")
    }
}

struct CompanionAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CreateLocalReminderIntent(), phrases: [
            "Создай напоминание в \(.applicationName)",
            "Добавь задачу в \(.applicationName)"
        ], shortTitle: "Создать напоминание", systemImageName: "checklist")
    }
}

actor ReminderNotifications {
    static let shared = ReminderNotifications()
    private let center = UNUserNotificationCenter.current()
    private let prefix = "mycompanion.task."
    private var lastPass: Task<String, Never>?

    func create(title: String, due: Date, preset: Bool = false) async throws -> String {
        try Store.shared().update { state in
            guard !state.reminders.contains(where: {
                $0.title == title && $0.dueAt == due && $0.recurrence == .once &&
                    (preset || ($0.completedAt == nil && $0.notificationEnabled && $0.snoozedUntil == nil))
            }) else { return }
            state.reminders.append(LocalReminder(title: title, dueAt: due, notificationEnabled: true, revision: 1))
            state.respond(to: .reminderCreated)
        }
        WidgetCenter.shared.reloadTimelines(ofKind: "Companion")
        if await center.notificationSettings().authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert])
        }
        return await reconcile()
    }

    func reconcile() async -> String {
        let previous = lastPass
        let pass = Task {
            _ = await previous?.value
            return await self.sync()
        }
        lastPass = pass
        return await pass.value
    }

    @discardableResult func apply(id: UUID, revision: Int, snoozeMinutes: Int?) async throws -> String {
        var applied = false
        try Store.shared().update { state in
            guard let i = state.reminders.firstIndex(where: { $0.id == id && $0.revision == revision }) else { return }
            let now = Date()
            if let minutes = snoozeMinutes { state.reminders[i].snooze(minutes: minutes, at: now) }
            else { state.reminders[i].complete(at: now) }
            if state.reminders[i].revision != revision {
                applied = true
                state.respond(to: snoozeMinutes == nil ? .reminderCompleted : .reminderSnoozed, at: now)
            }
        }
        if applied { WidgetCenter.shared.reloadTimelines(ofKind: "Companion") }
        let status = await reconcile()
        return applied || !status.isEmpty ? status : "Задача уже изменилась."
    }

    private func sync() async -> String {
        do {
            let tasks = try Store.shared().read().reminders
            let defaults = UserDefaults.standard
            let start = defaults.object(forKey: "quietStartHour") as? Int ?? 23
            let end = defaults.object(forKey: "quietEndHour") as? Int ?? 7
            let allow = defaults.object(forKey: "allowTasksDuringQuiet") as? Bool ?? true
            let now = Date()
            let dates = tasks.compactMap { task -> (LocalReminder, Date)? in
                guard let date = task.notificationDate(after: now, quietStart: start, quietEnd: end,
                                                       allowDuringQuiet: allow) else { return nil }
                return (task, date)
            }.sorted { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.id.uuidString < rhs.0.id.uuidString : lhs.1 < rhs.1
            }
            let settings = await center.notificationSettings()
            let allowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
            let pending = await center.pendingNotificationRequests()
            let own = pending.filter { $0.identifier.hasPrefix(prefix) }
            let slots = min(36, max(0, 48 - (pending.count - own.count)))
            let desired = dates.prefix(allowed ? slots : 0)
            let ids = Set(desired.map { prefix + $0.0.id.uuidString })
            center.removePendingNotificationRequests(withIdentifiers: own.map(\.identifier).filter { !ids.contains($0) })
            let delivered = await center.deliveredNotifications()
            let revisions = Dictionary(uniqueKeysWithValues: tasks.filter { $0.completedAt == nil }.map { (prefix + $0.id.uuidString, $0.revision) })
            center.removeDeliveredNotifications(withIdentifiers: delivered.compactMap { item in
                let request = item.request
                guard request.identifier.hasPrefix(prefix) else { return nil }
                return revisions[request.identifier] == request.content.userInfo["revision"] as? Int ? nil : request.identifier
            })
            var failures = 0
            for (task, date) in desired {
                let id = prefix + task.id.uuidString
                let stamp = Int(date.timeIntervalSince1970)
                if own.contains(where: { $0.identifier == id && $0.content.userInfo["revision"] as? Int == task.revision &&
                    $0.content.userInfo["fireTime"] as? Int == stamp }) { continue }
                let content = UNMutableNotificationContent()
                content.title = "Мой Компаньон"
                content.body = "У вас запланирована задача."
                content.categoryIdentifier = "MYCOMPANION_TASK"
                content.userInfo = ["taskID": task.id.uuidString, "revision": task.revision, "fireTime": stamp]
                let parts = Calendar.current.dateComponents([.timeZone, .year, .month, .day, .hour, .minute, .second], from: date)
                let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
                do { try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger)) }
                catch { failures += 1 }
            }
            let verified = await center.pendingNotificationRequests().filter { $0.identifier.hasPrefix(prefix) }
            let matchesPlan = desired.allSatisfy { task, date in
                verified.contains { request in
                    request.identifier == prefix + task.id.uuidString &&
                    request.content.userInfo["revision"] as? Int == task.revision &&
                    request.content.userInfo["fireTime"] as? Int == Int(date.timeIntervalSince1970)
                }
            }
            if failures > 0 || !matchesPlan || Set(verified.map(\.identifier)) != ids {
                return "Часть уведомлений не поставлена в очередь. Проверьте разрешение и обновите расписание."
            }
            if !allowed && !dates.isEmpty { return "Задачи сохранены. Для уведомлений требуется разрешение в настройках iOS." }
            if dates.count > slots { return "Запланированы ближайшие \(slots) уведомлений. Остальные добавятся при открытии приложения, когда освободится место." }
            return ""
        } catch { return "Не удалось прочитать задачи для обновления уведомлений." }
    }
}

struct ReminderList: View {
    @Environment(\.scenePhase) private var phase
    @State private var items: [LocalReminder] = []
    @State private var editing: LocalReminder?
    @State private var deleting: LocalReminder?
    @State private var message = ""
    @State private var scheduleMessage = ""

    var body: some View {
        List {
            if items.isEmpty {
                ContentUnavailableView("Задач пока нет", systemImage: "checklist", description: Text("Нажмите «Добавить», чтобы создать напоминание."))
            } else {
                let now = Date()
                let active = items.filter { $0.completedAt == nil }.sorted { ($0.target ?? .distantFuture) < ($1.target ?? .distantFuture) }
                group("Просроченные", active.filter { ($0.target ?? .distantFuture) < now })
                group("Активные", active.filter { ($0.target ?? .distantFuture) >= now })
                group("Завершённые", items.filter { $0.completedAt != nil }.sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) })
            }
            if !message.isEmpty { Text(message) }
            if !scheduleMessage.isEmpty { Text(scheduleMessage).font(.footnote) }
        }
        .navigationTitle("Напоминания")
        .toolbar {
            Button { editing = LocalReminder() } label: { Label("Добавить", systemImage: "plus") }
        }
        .sheet(item: $editing, onDismiss: { Task { await refresh() } }) { item in
            ReminderEditor(original: item, existing: items.contains { $0.id == item.id }) { value, existing in
                try persist(value, existing: existing)
            }
        }
        .confirmationDialog("Удалить задачу?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { item in
            Button("Удалить", role: .destructive) {
                mutate { state in state.reminders.removeAll { $0.id == item.id && $0.revision == item.revision } }
            }
        }
        .task { await refresh() }
        .onChange(of: phase) { _, phase in if phase == .active { Task { await refresh() } } }
        .refreshable { await refresh() }
    }

    @ViewBuilder private func group(_ name: String, _ group: [LocalReminder]) -> some View {
        if !group.isEmpty {
            Section(name) {
                ForEach(group) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                            if let target = item.target { Text(target.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(.secondary) }
                            if item.recurrence != .once { Text(item.recurrence.label).font(.caption) }
                        }
                        Spacer()
                        Menu {
                            if item.completedAt == nil {
                                Button("Выполнить") { act(item, minutes: nil) }
                                Button("Редактировать") { editing = item }
                                Menu("Отложить") {
                                    ForEach([10, 30, 60], id: \.self) { minutes in
                                        Button("На \(minutes) мин") { act(item, minutes: minutes) }
                                    }
                                }
                            }
                            Button("Удалить", role: .destructive) { deleting = item }
                        } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Действия с задачей \(item.title)")
                    }
                }
            }
        }
    }

    private func refresh() async {
        do { items = try Store.shared().read().reminders; message = "" }
        catch { message = "Не удалось загрузить задачи. Потяните список вниз для повтора." }
        scheduleMessage = await ReminderNotifications.shared.reconcile()
    }

    private func act(_ item: LocalReminder, minutes: Int?) {
        Task {
            do {
                scheduleMessage = try await ReminderNotifications.shared.apply(id: item.id, revision: item.revision, snoozeMinutes: minutes)
                items = try Store.shared().read().reminders
            } catch { message = "Не удалось изменить задачу. Повторите попытку." }
        }
    }

    private func mutate(_ change: (inout Companion) -> Void) {
        do {
            items = try Store.shared().update(change).reminders
            WidgetCenter.shared.reloadTimelines(ofKind: "Companion")
            Task { scheduleMessage = await ReminderNotifications.shared.reconcile() }
        } catch { message = "Не удалось сохранить изменение. Повторите попытку." }
    }

    private func persist(_ item: LocalReminder, existing: Bool) throws {
        var applied = false
        let snapshot = try Store.shared().update { state in
            if existing {
                guard let i = state.reminders.firstIndex(where: { $0.id == item.id && $0.revision == item.revision - 1 }) else { return }
                var updated = item
                if state.reminders[i].dueAt != item.dueAt || state.reminders[i].recurrence != item.recurrence {
                    updated.seriesAnchor = nil
                }
                state.reminders[i] = updated
            } else {
                guard !state.reminders.contains(where: { $0.id == item.id }) else { return }
                state.reminders.append(item)
                state.respond(to: .reminderCreated)
            }
            applied = true
        }
        items = snapshot.reminders
        guard applied else { throw ReminderEditError.changed }
        WidgetCenter.shared.reloadTimelines(ofKind: "Companion")
    }
}

private enum ReminderEditError: Error { case changed }

private struct ReminderEditor: View {
    @Environment(\.dismiss) private var dismiss
    let existing: Bool
    let save: (LocalReminder, Bool) throws -> Void
    @State private var item: LocalReminder
    @State private var timed: Bool
    @State private var date: Date
    @State private var error = ""
    @State private var saving = false

    init(original: LocalReminder, existing: Bool, save: @escaping (LocalReminder, Bool) throws -> Void) {
        self.existing = existing
        self.save = save
        _item = State(initialValue: original)
        _timed = State(initialValue: original.dueAt != nil)
        _date = State(initialValue: original.dueAt ?? Date().addingTimeInterval(3600))
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название задачи", text: $item.title, axis: .vertical).accessibilityIdentifier("task-title")
                Toggle("Указать срок", isOn: $timed)
                if timed {
                    DatePicker("Срок", selection: $date)
                    Picker("Повтор", selection: $item.recurrence) {
                        ForEach(TaskRecurrence.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    if item.recurrence != .once {
                        Text("После выполнения появится следующий срок. Пропущенная задача остаётся просроченной до выполнения.").font(.footnote)
                    }
                    Toggle("Уведомить", isOn: $item.notificationEnabled)
                }
                if !error.isEmpty { Text(error) }
            }
            .navigationTitle(existing ? "Редактирование" : "Новая задача")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { Task { await submit() } }
                        .disabled(saving || item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    @MainActor private func submit() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        var value = item
        value.title = value.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !timed || value.dueAt != date { value.snoozedUntil = nil }
        value.dueAt = timed ? date : nil
        if !timed { value.notificationEnabled = false; value.recurrence = .once }
        value.updatedAt = Date()
        value.revision += 1
        do {
            try save(value, existing)
            if value.notificationEnabled {
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                if settings.authorizationStatus == .notDetermined {
                    _ = try? await center.requestAuthorization(options: [.alert])
                }
                _ = await ReminderNotifications.shared.reconcile()
            }
            dismiss()
        } catch ReminderEditError.changed { error = "Задача уже изменилась. Закройте форму и откройте её заново." }
        catch { self.error = "Не удалось сохранить задачу. Попробуйте ещё раз." }
    }
}
