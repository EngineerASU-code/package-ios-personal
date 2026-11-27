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
    @AppStorage("portraitForm") private var portrait = false
    @State private var changingReminder = false
    @State private var selectedTab = 0
    private let notice = "mycompanion.preview"
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        Button { save { $0.react() } } label: {
                            CompanionScene(state: state, display: DayTimeline.display(state, at: Date(), calendar: .current), portrait: portrait)
                                .frame(minHeight: 150)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Коснитесь, чтобы получить новую реплику")
                        .disabled(state.mode == .safe || state.mode == .paused)
                        Picker("Форма героя", selection: $portrait) {
                            Text("Чиби").tag(false)
                            Text("Портрет").tag(true)
                        }.pickerStyle(.segmented)
                        heroPicker
                        modePicker
                        Button("Напомнить через минуту") { Task { await schedule() } }
                            .disabled(changingReminder)
                        Button("Отменить напоминание") { Task { await cancel() } }
                            .disabled(changingReminder)
                        if !message.isEmpty { Text(message).font(.footnote) }
                        NavigationLink("Галерея находок") { gallery }
                    }.padding()
                }.navigationTitle("Мой Компаньон")
            }.tabItem { Label("Компаньон", systemImage: "bubble.left") }.tag(0)
            NavigationStack { CalendarPanel() }
                .tabItem { Label("Календарь", systemImage: "calendar") }.tag(1)
            NavigationStack { ReminderList() }
                .tabItem { Label("Напоминания", systemImage: "checklist") }.tag(2)
            NavigationStack {
                List(Hero.allCases, id: \.self) { hero in
                    NavigationLink {
                        CharacterPreview(hero: hero, selected: state.hero == hero) { select(hero) }
                    } label: {
                        HStack {
                            CompanionFigure(hero: hero).frame(width: 48, height: 56)
                            VStack(alignment: .leading) {
                                Text(hero.name).font(.headline)
                                Text(hero.dialogue.first?.text ?? "").font(.callout)
                            }
                            Spacer()
                            if hero == state.hero { Image(systemName: "checkmark") }
                        }
                    }.accessibilityAddTraits(hero == state.hero ? .isSelected : [])
                }.navigationTitle("Персонажи")
            }.tabItem { Label("Персонажи", systemImage: "person.2") }.tag(3)
            NavigationStack {
                Form {
                    NavigationLink("Оформление компаньона") {
                        Form {
                            heroPicker
                            Picker("Форма героя", selection: $portrait) {
                                Text("Чиби").tag(false)
                                Text("Портрет").tag(true)
                            }
                        }.navigationTitle("Оформление")
                    }
                    modePicker
                    NavigationLink("Уведомления и тихие часы") { CompanionNoticePanel() }
                    NavigationLink("Как добавить виджет") {
                        Text("Удерживайте свободное место на экране «Домой», откройте галерею виджетов и найдите «Мой Компаньон». После добавления удерживайте виджет, чтобы выбрать героя.").padding().navigationTitle("Виджет")
                    }
                }.navigationTitle("Настройки")
            }.tabItem { Label("Настройки", systemImage: "gearshape") }.tag(4)
        }
        .onOpenURL { url in
            switch url.absoluteString {
            case "mycompanion://calendar": selectedTab = 1
            case "mycompanion://reminders": selectedTab = 2
            default: break
            }
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
    private var heroPicker: some View {
        Picker("Персонаж", selection: Binding(get: { state.hero }, set: select)) {
            ForEach(Hero.allCases, id: \.self) { Text($0.name).tag($0) }
        }
    }

    private var modePicker: some View {
        Picker("Режим", selection: Binding(get: { state.mode }, set: { mode in save { $0.mode = mode } })) {
            ForEach(CompanionMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
    }

    private func select(_ hero: Hero) {
        save {
            $0.hero = hero
            _ = $0.greetIfNeeded(at: Date(), calendar: .current)
        }
    }

    private var gallery: some View {
        List {
            if state.unlocks.isEmpty {
                Text("Здесь появятся находки ваших компаньонов.")
            }
            ForEach(Hero.allCases, id: \.self) { hero in
                if let pack = hero.pack {
                    let finds = pack.finds.filter { find in state.unlocks.contains { $0.id == find.id } }
                    if !finds.isEmpty {
                        Section(hero.name) {
                            ForEach(finds, id: \.id) { find in
                                NavigationLink(find.title) {
                                    List {
                                        Text(find.title).font(.title2)
                                        if let line = pack.byID[find.lineID] {
                                            Text(line.text)
                                            ShareLink(item: find.title + " — " + line.text) { Label("Поделиться", systemImage: "square.and.arrow.up") }
                                        }
                                    }.navigationTitle("Находка")
                                }
                            }
                        }
                    }
                }
            }
        }.navigationTitle("Галерея находок")
    }

    func refreshSchedules() {
        Task {
            _ = await ReminderNotifications.shared.reconcile()
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

private struct CharacterPreview: View {
    let hero: Hero
    let selected: Bool
    let select: () -> Void
    @State private var emotion: ChibiEmotion = .neutral
    @State private var portrait = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                CompanionFigure(hero: hero, portrait: portrait, emotion: emotion)
                    .frame(maxWidth: .infinity).frame(height: 264)
                    .background { HeroBackdrop(hero: hero) }.clipShape(RoundedRectangle(cornerRadius: 20))
                Picker("Форма героя", selection: $portrait) {
                    Text("Чиби").tag(false)
                    Text("Портрет").tag(true)
                }.pickerStyle(.segmented)
                if !portrait {
                    Picker("Эмоция", selection: $emotion) {
                        Text("Спокойствие").tag(ChibiEmotion.neutral)
                        Text("Радость").tag(ChibiEmotion.happy)
                        Text("Сонливость").tag(ChibiEmotion.sleepy)
                        Text("Удивление").tag(ChibiEmotion.surprised)
                    }.pickerStyle(.menu).accessibilityIdentifier("character-mood")
                }
                Text(hero.dialogue.first?.text ?? "").font(.body)
                Button(selected ? "Выбран" : "Выбрать", action: select)
                    .buttonStyle(.borderedProminent).disabled(selected)
            }.padding()
        }.navigationTitle(hero.name)
    }
}
