import SwiftUI
import WidgetKit
import UserNotifications
import UniformTypeIdentifiers

@main struct CompanionApp: App {
    @UIApplicationDelegateAdaptor(NotificationActions.self) private var actions
    var body: some Scene { WindowGroup { Home() } }
}

private struct CompanionClock: TimelineSchedule {
    let state: Companion
    let active: Bool

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> AnySequence<Date> {
        guard active, state.mode == .normal || state.mode == .eco else {
            return AnySequence([startDate])
        }
        return AnySequence(sequence(first: startDate) { current in
            DayTimeline.dates(from: current, state: state, calendar: .current).dropFirst().first
        })
    }
}

struct Home: View {
    private struct OpenedGift: Identifiable {
        let hero: Hero
        let find: Find
        var id: String { find.id }
    }
    @Environment(\.scenePhase) private var phase
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var state = Companion()
    @ObservedObject private var calendarController = CalendarController.shared
    @ObservedObject private var notificationNavigation = NotificationNavigation.shared
    @State private var openedGift: OpenedGift?
    @State private var message = ""
    @AppStorage("quietStartHour") private var quietStartHour = 23
    @AppStorage("quietEndHour") private var quietEndHour = 7
    @AppStorage("allowTasksDuringQuiet") private var allowTasksDuringQuiet = true
    @AppStorage("portraitForm") private var portrait = false
    @AppStorage("appAppearance") private var appearance = AppAppearance.system.rawValue
    @AppStorage("didFinishWelcome") private var didFinishWelcome = false
    @AppStorage("preferredName") private var preferredName = ""
    @AppStorage("addressForm") private var addressForm = AddressForm.character.rawValue
    @State private var selectedTab = 0
    @State private var thermal = ProcessInfo.processInfo.thermalState
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var clearing: HistorySection?
    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                ScrollView {
                    VStack(spacing: 16) {
                        if typeSize.isAccessibilitySize {
                            Text("Мой Компаньон")
                                .font(.title.bold())
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("companion-heading")
                        }
                        Button {
                            let now = Date()
                            if save({ value in
                                withEffectiveMode(&value) { $0.react(at: now) }
                            }), state.contact?.date == now {
                                didFinishWelcome = true
                            }
                        } label: {
                            CharacterPackContent(state.hero) { pack in
                                TimelineView(CompanionClock(state: displayState, active: phase == .active && selectedTab == 0)) { tick in
                                    let now = max(tick.date, Date())
                                    CompanionScene(state: displayState, date: now, display: sceneReaction(at: now, using: pack), portrait: portrait)
                                        .frame(minHeight: 150)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Коснитесь, чтобы получить новую реплику")
                        .accessibilityIdentifier("companion-interaction")
                        .disabled(displayState.mode == .safe || displayState.mode == .paused)
                        Picker("Форма героя", selection: $portrait) {
                            Text("Чиби").tag(false)
                            Text("Портрет").tag(true)
                        }.pickerStyle(.segmented)
                        heroPicker
                        if !didFinishWelcome {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Знакомство с компаньоном").font(.headline)
                                Text("Выберите героя и коснитесь его, чтобы увидеть реплику. Чтобы добавить его на экран «Домой», удерживайте свободное место и найдите «Мой Компаньон» в галерее виджетов.")
                                Button("Пропустить знакомство") { didFinishWelcome = true }
                            }
                        }
                        modePicker
                        Button {
                            selectedTab = 2
                        } label: {
                            if let task = state.reminders.filter({ $0.completedAt == nil && $0.target != nil })
                                .min(by: { ($0.target ?? .distantFuture) < ($1.target ?? .distantFuture) }),
                               let due = task.target {
                                VStack(alignment: .leading) {
                                    Label(task.title, systemImage: "checklist")
                                    Text(due, format: .dateTime.day().month().hour().minute()).font(.caption)
                                }.privacySensitive()
                            } else {
                                Label("Открыть напоминания", systemImage: "checklist")
                            }
                        }
                        if !message.isEmpty { Text(message).font(.footnote) }
                        NavigationLink("Галерея находок") { gallery }
                    }.padding()
                }
                .navigationTitle("Мой Компаньон")
                .toolbar(typeSize.isAccessibilitySize ? .hidden : .visible, for: .navigationBar)
            }.tabItem { Label("Компаньон", systemImage: "bubble.left") }.tag(0)
            NavigationStack { CalendarPanel() }
                .tabItem { Label("Календарь", systemImage: "calendar") }.tag(1)
            NavigationStack { ReminderList() }
                .tabItem { Label("Напоминания", systemImage: "checklist") }.tag(2)
            NavigationStack {
                List(Hero.allCases, id: \.self) { hero in
                    NavigationLink {
                        CharacterPreview(hero: hero, mode: state.mode, daySchedule: state.daySchedule, selected: state.hero == hero) { select(hero) }
                    } label: {
                        CharacterPackContent(hero) { pack in
                            HStack {
                                CompanionFigure(hero: hero, pixels: 160).frame(width: 48, height: 56)
                                VStack(alignment: .leading) {
                                    Text(hero.name).font(.headline)
                                    Text(pack?.interactive.first?.text ?? "").font(.callout)
                                }
                                Spacer()
                                if hero == state.hero { Image(systemName: "checkmark") }
                            }
                        }
                    }.accessibilityAddTraits(hero == state.hero ? .isSelected : [])
                }.navigationTitle("Персонажи")
            }.tabItem { Label("Персонажи", systemImage: "person.2") }.tag(3)
            NavigationStack {
                Form {
                    NavigationLink("Оформление компаньона") {
                        Form {
                            heroPicker
                            Picker("Тема приложения", selection: $appearance) {
                                ForEach(AppAppearance.allCases, id: \.self) { option in
                                    Text(option.rawValue).tag(option.rawValue)
                                }
                            }
                            Picker("Форма героя", selection: $portrait) {
                                Text("Чиби").tag(false)
                                Text("Портрет").tag(true)
                            }
                        }.navigationTitle("Оформление")
                    }
                    modePicker
                    Toggle("Анимации героя", isOn: Binding(get: { state.animationsEnabled }, set: { enabled in
                        save { $0.animationsEnabled = enabled }
                    }))
                    NavigationLink("Как ко мне обращаться") {
                        Form {
                            Section {
                                TextField("Имя или прозвище", text: Binding(get: { preferredName }, set: { name in
                                    preferredName = String(name.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }.prefix(32))
                                }))
                                .textInputAutocapitalization(.words)
                                .autocorrectionDisabled()
                                .privacySensitive()
                                if !preferredName.isEmpty {
                                    Button("Удалить имя", role: .destructive) { preferredName = "" }
                                }
                                Picker("Обращение", selection: $addressForm) {
                                    ForEach(AddressForm.allCases, id: \.self) { Text($0.rawValue).tag($0.rawValue) }
                                }
                            } footer: {
                                Text("Имя можно оставить пустым. Обращение используется в отдельных репликах на вкладке «Компаньон».")
                            }
                        }.navigationTitle("Как ко мне обращаться")
                    }
                    Toggle("Случайные события", isOn: Binding(get: { state.randomEventsEnabled }, set: { enabled in
                        save { $0.randomEventsEnabled = enabled }
                    }))
                    NavigationLink("Распорядок героя") {
                        Form {
                            periodHour("Поздняя ночь", \.lateNight, 0...(state.daySchedule.dawn - 1))
                            periodHour("Раннее утро", \.dawn, (state.daySchedule.lateNight + 1)...(state.daySchedule.morning - 1))
                            periodHour("Утро", \.morning, (state.daySchedule.dawn + 1)...(state.daySchedule.day - 1))
                            periodHour("День", \.day, (state.daySchedule.morning + 1)...(state.daySchedule.evening - 1))
                            periodHour("Вечер", \.evening, (state.daySchedule.day + 1)...(state.daySchedule.night - 1))
                            periodHour("Ночь", \.night, (state.daySchedule.evening + 1)...23)
                        }.navigationTitle("Распорядок героя")
                    }
                    Picker("Частота комплиментов", selection: Binding(get: { state.complimentFrequency }, set: { value in
                        save { $0.complimentFrequency = value }
                    })) {
                        ForEach(ComplimentFrequency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Частота реплик", selection: Binding(get: { state.passivePhraseFrequency }, set: { value in
                        save { $0.passivePhraseFrequency = value }
                    })) {
                        ForEach(PassivePhraseFrequency.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Picker("Интенсивность общения", selection: Binding(get: { state.communicationIntensity }, set: { value in
                        save { $0.communicationIntensity = value }
                    })) {
                        ForEach(CommunicationIntensity.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Toggle("Комплименты только в виджете", isOn: Binding(get: { state.complimentsOnlyInWidget }, set: { value in
                        save { $0.complimentsOnlyInWidget = value }
                    }))
                    NavigationLink("Уведомления и тихие часы") { CompanionNoticePanel() }
                    NavigationLink("Диагностика") { LocalDiagnostics() }
                    NavigationLink("Конфиденциальность") {
                        Form {
                            Section("Данные на устройстве") {
                                Text("История героя, коллекция и задачи хранятся на iPhone. Приложение и виджет используют общее локальное хранилище.")
                            }
                            Section("Календарь") {
                                Text("Доступ запрашивается при подключении. Названия событий по умолчанию скрыты. Отключить календарь и очистить снимок можно в разделе «Локальные данные».")
                            }
                            Section("Уведомления") {
                                Text("Доставкой управляет iOS. Чтобы отключить сообщения и напоминания приложения, откройте «Уведомления и тихие часы».")
                            }
                        }.navigationTitle("Конфиденциальность")
                    }
                    NavigationLink("Локальные данные") {
                        Form {
                            ForEach(HistorySection.allCases, id: \.self) { section in
                                Button(section.rawValue, role: .destructive) { clearing = section }
                            }
                            if !message.isEmpty { Text(message) }
                        }.navigationTitle("Локальные данные")
                        .alert(item: $clearing) { section in
                            Alert(title: Text(section.rawValue + "?"), message: Text("Это действие нельзя отменить."),
                                  primaryButton: .destructive(Text("Очистить")) { clear(section) },
                                  secondaryButton: .cancel(Text("Отмена")))
                        }
                    }
                    NavigationLink("Как добавить виджет") {
                        Text("Удерживайте свободное место на экране «Домой», откройте галерею виджетов и найдите «Мой Компаньон». Выберите героя на вкладке «Компаньон». Виджет с настройкой «Как в приложении» покажет его на домашнем экране. Настроение и реплики меняются сами. Коснитесь героя, чтобы он ответил.").padding().navigationTitle("Виджет")
                    }
                }.navigationTitle("Настройки")
            }.tabItem { Label("Настройки", systemImage: "gearshape") }.tag(4)
        }
        .onChange(of: notificationNavigation.pending, initial: true) { _, destination in
            guard let destination else { return }
            notificationNavigation.pending = nil
            openedGift = nil
            switch destination {
            case .calendar: selectedTab = 1
            case .reminders: selectedTab = 2
            case .gift(let id):
                selectedTab = 0
                openGift(id)
            }
        }
        .sheet(item: $openedGift) { gift in
            NavigationStack {
                giftCard(hero: gift.hero, find: gift.find)
                    .toolbar { Button("Закрыть") { openedGift = nil } }
            }
        }
        .onOpenURL { url in
            switch url.absoluteString {
            case "mycompanion://calendar": selectedTab = 1
            case "mycompanion://reminders": selectedTab = 2
            default: break
            }
        }
        .modifier(CalendarRefresh())
        .preferredColorScheme(AppAppearance(rawValue: appearance)?.scheme)
        .onReceive(NotificationCenter.default.publisher(for: ProcessInfo.thermalStateDidChangeNotification)) { _ in
            thermal = ProcessInfo.processInfo.thermalState
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
            lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            CharacterArtwork.releaseCachedImages()
        }
        .onChange(of: selectedTab) { _, tab in
            if tab == 0 {
                do { state = try Store.shared().read() }
                catch { message = "Общее хранилище недоступно" }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .companionModeChanged)) { _ in
            do { state = try Store.shared().read() }
            catch { message = "Общее хранилище недоступно" }
        }
        .companionNoticeReconciliation(hero: state.hero, mode: state.mode, schedule: state.daySchedule,
                                      latestUnlock: state.unlocks.last?.id, intensity: state.communicationIntensity)
        .onChange(of: quietStartHour) { _, _ in refreshSchedules() }
        .onChange(of: quietEndHour) { _, _ in refreshSchedules() }
        .onChange(of: allowTasksDuringQuiet) { _, _ in refreshSchedules() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            if phase == .active { refreshSchedules() }
        }
        .onAppear { refresh(.appOpened) }.onChange(of: phase) { _, next in
            if next == .active { refresh(.foregrounded) }
            if next == .background { CharacterArtwork.releaseCachedImages() }
        }
    }
    private func sceneReaction(at date: Date, using pack: CharacterPack?) -> Reaction {
        var current = displayState
        current.calendarSnapshot = calendarController.snapshot
        let line = DayTimeline.display(current, at: date, calendar: .current, using: pack)
        guard current.mode == .normal || current.mode == .eco, let contact = current.contact,
              contact.response == line.id, date >= contact.date, date.timeIntervalSince(contact.date) < 300 else { return line }
        let form = AddressForm(rawValue: addressForm) ?? .character
        return form.personalize(line, hero: current.hero, name: preferredName, intensity: current.communicationIntensity)
    }

    private var displayState: Companion {
        var current = state
        current.mode = effectiveMode(for: current.mode)
        return current
    }

    private func effectiveMode(for preference: CompanionMode) -> CompanionMode {
        if preference != .paused && thermal == .critical { return .safe }
        if preference == .normal && (thermal == .serious || lowPower) { return .eco }
        return preference
    }

    private func withEffectiveMode<T>(_ value: inout Companion, _ action: (inout Companion) -> T) -> T {
        let preference = value.mode
        value.mode = effectiveMode(for: preference)
        defer { value.mode = preference }
        return action(&value)
    }

    private func periodHour(_ label: String, _ key: WritableKeyPath<DaySchedule, Int>, _ range: ClosedRange<Int>) -> some View {
        Picker(label, selection: Binding(get: { state.daySchedule[keyPath: key] }, set: { hour in
            save {
                var schedule = $0.daySchedule
                schedule[keyPath: key] = hour
                if schedule.isValid { $0.daySchedule = schedule }
            }
        })) {
            ForEach(range, id: \.self) { hour in Text(String(format: "%02d:00", hour)).tag(hour) }
        }
    }

    private var heroPicker: some View {
        Picker("Персонаж", selection: Binding(get: { state.hero }, set: select)) {
            ForEach(Hero.allCases, id: \.self) { Text($0.name).tag($0) }
        }
    }

    private var modePicker: some View {
        Picker("Режим", selection: Binding(get: { state.mode }, set: { mode in save { $0.setMode(mode) } })) {
            ForEach(CompanionMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
    }

    private func select(_ hero: Hero) {
        save {
            $0.hero = hero
            _ = withEffectiveMode(&$0) { $0.appContact(.characterSelected, at: Date(), calendar: .current) }
        }
    }

    private func openGift(_ id: String) {
        do {
            state = try Store.shared().read()
            if state.unlocks.contains(where: { $0.id == id }) {
                for hero in Hero.allCases {
                    if let find = hero.pack?.finds.first(where: { $0.id == id }) {
                        openedGift = OpenedGift(hero: hero, find: find)
                        return
                    }
                }
            }
            message = "Этой находки больше нет в галерее."
        } catch {
            message = "Не удалось открыть галерею. Попробуйте ещё раз."
        }
    }

    private func giftCard(hero: Hero, find: Find) -> some View {
        CharacterPackContent(hero) { pack in giftCard(hero: hero, find: find, pack: pack) }
    }

    private func giftCard(hero: Hero, find: Find, pack: CharacterPack?) -> some View {
        List {
            if let unlock = state.unlocks.first(where: { $0.id == find.id }) {
                VStack(alignment: .leading, spacing: 8) {
                    CompanionFigure(hero: hero, portrait: portrait)
                        .frame(height: 160)
                        .frame(maxWidth: .infinity)
                        .background { HeroBackdrop(hero: hero, date: unlock.date, mode: state.mode, daySchedule: state.daySchedule) }
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .accessibilityHidden(true)
                    Text(hero.name).font(.headline)
                    Image(systemName: unlock.assetID ?? find.assetID)
                        .font(.title).accessibilityHidden(true)
                    Text(unlock.date, format: .dateTime.day().month(.wide).year())
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            if let line = pack?.byID[find.lineID] {
                Text(line.text).padding(10)
                    .foregroundStyle(.primary)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                ShareLink(item: find.title + " — " + line.text) { Label("Поделиться", systemImage: "square.and.arrow.up") }
            }
        }.navigationTitle(find.title)
    }

    private var gallery: some View {
        List {
            if state.unlocks.isEmpty {
                Text("Здесь появятся находки ваших компаньонов.")
            }
            ForEach(Hero.allCases.filter { hero in state.unlocks.contains { $0.id.hasPrefix(hero.rawValue + "_") } }, id: \.self) { hero in
                CharacterPackContent(hero) { pack in
                    let finds = pack?.finds.filter { find in state.unlocks.contains { $0.id == find.id } } ?? []
                    if !finds.isEmpty {
                        Section(hero.name) {
                            ForEach(finds, id: \.id) { find in
                                NavigationLink(find.title) {
                                    giftCard(hero: hero, find: find)
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
    private func clear(_ section: HistorySection) {
        guard save({ value in
            switch section {
            case .dialogue: value.clearDialogueHistory()
            case .activity: value.clearActivityHistory()
            case .collection: value.clearCollection()
            case .tasks: value.reminders.removeAll()
            case .calendar: value.calendarSnapshot = CalendarSnapshot()
            case .preferences: value.resetPreferences()
            }
        }) else { return }
        let defaults = UserDefaults.standard
        if section == .preferences {
            for key in ["portraitForm", "appAppearance", "didFinishWelcome", "preferredName", "addressForm", "companionMorningEnabled", "companionBedtimeEnabled",
                        "companionSupportEnabled", "companionGiftsEnabled", "companionMorningTime", "companionBedtimeTime",
                        "quietStartHour", "quietEndHour", "allowTasksDuringQuiet", "calendarWarningMinutes"] {
                defaults.removeObject(forKey: key)
            }
            // A settings reset must not silently resume delivery that the user disabled.
        }
        if section == .calendar || section == .preferences {
            for key in ["calendarEnabled", "calendarTitles", "calendarWarnings"] { defaults.removeObject(forKey: key) }
            _ = CalendarPrivacy.publish(.off)
            Task { await calendarController.refresh() }
        }
        if section == .tasks || section == .preferences { refreshSchedules() }
    }
    func refresh(_ kind: CompanionEvent.Kind) {
        Task { _ = await ReminderNotifications.shared.reconcile() }
        do {
            let store = try Store.shared()
            state = try store.read()
            let date = Date()
            let calendar = Calendar.current
            var preview = state
            if withEffectiveMode(&preview, { $0.appContact(kind, at: date, calendar: calendar) }) {
                state = try store.update { value in
                    _ = withEffectiveMode(&value) { $0.appContact(kind, at: date, calendar: calendar) }
                }
                WidgetCenter.shared.reloadTimelines(ofKind: "Companion")
            }
        } catch { message = "Общее хранилище недоступно" }
    }
    @discardableResult func save(_ change: (inout Companion) -> Void) -> Bool {
        do {
            state = try Store.shared().update(change)
            WidgetCenter.shared.reloadTimelines(ofKind: "Companion")
            message = ""
            return true
        } catch {
            message = "Не удалось сохранить изменение"
            return false
        }
    }

}

private enum AddressForm: String, CaseIterable {
    case character = "Как у героя", familiar = "На ты", formal = "На вы"

    func personalize(_ line: Reaction, hero: Hero, name: String, intensity: CommunicationIntensity) -> Reaction {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty || self != .character else { return line }
        guard line.id == "intro" || line.id == "greeting" || line.id == hero.rawValue + "_morning_001" else { return line }
        let formal = self == .formal || (self == .character && (hero == .jinshi || hero == .maomao))
        let words: String
        switch hero {
        case .gojo: words = formal ? "Угадайте, где я спрятал последний моти." : "Угадай, где я спрятал последний моти."
        case .toji: words = formal ? "Передохните. Я подожду." : "Передохни. Я подожду."
        case .jinshi: words = formal ? "Позвольте налить вам чаю." : "Позволь налить тебе чаю."
        case .jinwoo: words = formal ? "Взгляните на карту. Я отметил тропу." : "Взгляни на карту. Я отметил тропу."
        case .sukuna: words = formal ? "Входите. Я сегодня в добром расположении." : "Входи. Я сегодня в добром расположении."
        case .maomao: words = formal ? "Посмотрите на прожилки этого листа." : "Посмотри на прожилки этого листа."
        }
        let addressed = name.isEmpty ? words : name + ", " + words.prefix(1).lowercased() + words.dropFirst()
        let greeting = line.id != "intro"
        let text = (greeting ? "Доброе утро. " : "") + addressed
        guard intensity != .restrained || text.count <= 60 else { return line }
        var result = Reaction(line.id, text, line.action, emotion: line.emotion)
        result.daytimePose = line.daytimePose
        return result
    }
}

private enum AppAppearance: String, CaseIterable {
    case system = "Как на iPhone", light = "Светлая", dark = "Тёмная"
    var scheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

private enum HistorySection: String, CaseIterable, Identifiable {
    case dialogue = "Очистить историю реплик"
    case activity = "Очистить историю взаимодействий"
    case collection = "Очистить коллекцию находок"
    case tasks = "Удалить все локальные задачи"
    case calendar = "Отключить календарь и очистить его снимок"
    case preferences = "Сбросить настройки компаньона"
    var id: Self { self }
}

private struct LocalDiagnostics: View {
    @State private var changingReminder = false
    @AppStorage("allNotificationsEnabled") private var allNotificationsEnabled = true
    private let notice = "mycompanion.preview"
    @State private var message = ""
    @State private var exportPresented = false
    @State private var exportFailed = false
    @State private var storage = ""
    @State private var version = ""

    var body: some View {
        Form {
            LabeledContent("Версия", value: version)
            LabeledContent("Общее хранилище", value: storage)
            Button("Проверить снова", action: inspect)
            Button("Сохранить отчёт в Файлы") { inspect(); exportFailed = false; exportPresented = true }
            if exportFailed { Text("Не удалось сохранить отчёт.") }
            Section("Проверка локальных уведомлений") {
                Button("Напомнить через минуту") { Task { await schedule() } }
                    .disabled(changingReminder || !allNotificationsEnabled)
                Button("Отменить напоминание") { Task { await cancel() } }
                    .disabled(changingReminder)
                if !message.isEmpty { Text(message).font(.footnote) }
            }
        }.navigationTitle("Диагностика").onAppear(perform: inspect)
        .fileExporter(isPresented: $exportPresented, document: DiagnosticReport(version: version, storage: storage),
                      contentType: .plainText, defaultFilename: "Диагностика компаньона") { result in
            if case .failure(let error) = result {
                let failure = error as NSError
                exportFailed = !(failure.domain == NSCocoaErrorDomain && failure.code == NSUserCancelledError)
            }
        }
    }

    @MainActor private func cancel() async {
        guard !changingReminder else { return }
        changingReminder = true
        defer { changingReminder = false }
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notice])
        let pending = await center.pendingNotificationRequests()
        message = pending.contains { $0.identifier == notice }
            ? "Не удалось отменить напоминание" : "Напоминание отменено"
    }

    @MainActor private func schedule() async {
        guard !changingReminder, allNotificationsEnabled else { return }
        changingReminder = true
        defer { changingReminder = false }
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert]) else { message = "Уведомления выключены"; return }
            guard allNotificationsEnabled else { return }
            let content = UNMutableNotificationContent()
            content.title = "Мой Компаньон"
            content.body = "Время для небольшой передышки."
            try await center.add(UNNotificationRequest(identifier: notice, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)))
            guard allNotificationsEnabled else {
                center.removePendingNotificationRequests(withIdentifiers: [notice])
                return
            }
            let pending = await center.pendingNotificationRequests()
            message = pending.filter { $0.identifier == notice }.count == 1
                ? "Напоминание запланировано" : "Не удалось подтвердить напоминание"
        } catch { message = "Не удалось создать напоминание" }
    }

    private func inspect() {
        let info = Bundle.main.infoDictionary
        version = (info?["CFBundleShortVersionString"] as? String ?? "—") +
            " (" + (info?["CFBundleVersion"] as? String ?? "—") + ")"
        do {
            storage = try Store.shared().readIfPresent() == nil ? "Пока пусто" : "Снимок доступен"
        } catch StoreError.unsupportedVersion {
            storage = "Требуется совместимая версия приложения"
        } catch {
            storage = "Не удалось прочитать снимок. Попробуйте после разблокировки iPhone."
        }
    }
}

private struct DiagnosticReport: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    private let contents: Data

    init(version: String, storage: String) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let report = ["Мой Компаньон", "Версия приложения: \(version)", "iOS: \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
                      "Общее хранилище: \(storage)"].joined(separator: "\n")
        contents = Data(report.utf8)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        contents = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: contents)
    }
}

private struct CharacterPreview: View {
    let hero: Hero
    let mode: CompanionMode
    let daySchedule: DaySchedule
    let selected: Bool
    let select: () -> Void
    @State private var emotion: ChibiEmotion = .neutral
    @State private var family = WidgetFamily.systemMedium
    @AppStorage("portraitForm") private var portrait = false

    var body: some View {
        CharacterPackContent(hero) { pack in preview(pack) }
    }

    private func preview(_ pack: CharacterPack?) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Picker("Размер предпросмотра", selection: $family) {
                    Text("Малый").tag(WidgetFamily.systemSmall)
                    Text("Средний").tag(WidgetFamily.systemMedium)
                    Text("Большой").tag(WidgetFamily.systemLarge)
                }.pickerStyle(.segmented)
                let layout = family == .systemMedium ? AnyLayout(HStackLayout()) : AnyLayout(VStackLayout())
                layout {
                    CompanionFigure(hero: hero, portrait: portrait, emotion: emotion)
                        .frame(height: family == .systemLarge ? 170 : 92)
                    if let line = pack?.interactive.first {
                        Text(pack?.byID[line.id]?.shortText ?? line.text).font(.callout)
                            .foregroundStyle(.black).padding(8)
                            .background(.white, in: RoundedRectangle(cornerRadius: 12))
                    }
                }.padding()
                    .frame(maxWidth: family == .systemSmall ? 176 : .infinity)
                    .background { HeroBackdrop(hero: hero, date: Date(), mode: mode, daySchedule: daySchedule) }
                    .clipShape(RoundedRectangle(cornerRadius: 20))
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
                if let voice = pack?.personality.voice { Text(voice).font(.callout) }
                Button(selected ? "Выбран" : "Выбрать", action: select)
                    .buttonStyle(.borderedProminent).disabled(selected)
            }.padding()
        }.navigationTitle(hero.name)
    }
}
