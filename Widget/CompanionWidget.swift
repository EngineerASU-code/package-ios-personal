import AppIntents
import os
import SwiftUI
import WidgetKit

enum WidgetHero: String, AppEnum {
    case followPrimary
    case gojo = "satoru_gojo"
    case toji = "toji_fushiguro"
    case jinshi = "jinshi"
    case jinwoo = "sung_jinwoo"
    case sukuna = "ryomen_sukuna"
    case maomao = "maomao"
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Персонаж"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .followPrimary: "Как в приложении",
        .gojo: "Сатору Годжо",
        .toji: "Тоджи Фушигуро",
        .jinshi: "Женьши",
        .jinwoo: "Сон Джин Ву",
        .sukuna: "Рёмен Сукуна",
        .maomao: "Мао Мао"
    ]
}

enum WidgetForm: String, AppEnum {
    case chibi, portrait

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Форма героя"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .chibi: "Чиби",
        .portrait: "Портрет"
    ]

    var baseImageName: String { self == .portrait ? "portrait.png" : "chibi.png" }
}

struct Settings: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Настройки компаньона"
    @Parameter(title: "Персонаж", default: .followPrimary) var selection: WidgetHero
    @Parameter(title: "Форма героя", default: .chibi) var form: WidgetForm
    @Parameter(title: "Показывать реплики", default: true) var showsSpeech: Bool
    @Parameter(title: "Показывать срок задачи", default: true) var showsTask: Bool
    @Parameter(title: "Показывать число находок", default: false) var showsCount: Bool
    @Parameter(title: "Показывать календарь", default: true) var showsCalendar: Bool
    @Parameter(title: "Скрывать названия событий", default: false) var hidesEventTitles: Bool

    func calendarPrivacy(for mode: CompanionMode) -> CalendarPrivacy {
        guard showsCalendar, mode != .safe, mode != .paused else { return .off }
        let appPrivacy = CalendarPrivacy.current
        if hidesEventTitles && appPrivacy == .titles { return .privateTitles }
        return appPrivacy
    }
}

private let widgetPerformance = OSSignposter(subsystem: "local.mycompanion.widget", category: "Performance")

struct React: AppIntent {
    static var title: LocalizedStringResource = "Поговорить"
    @Parameter(title: "Персонаж") var heroID: String
    @Parameter(title: "Основной персонаж", default: true) var follows: Bool

    init() {}
    init(hero: Hero, follows: Bool) { heroID = hero.rawValue; self.follows = follows }

    func perform() async throws -> some IntentResult {
        let interval = widgetPerformance.beginInterval("React", id: widgetPerformance.makeSignpostID())
        defer { widgetPerformance.endInterval("React", interval) }
        guard let target = Hero(rawValue: heroID) else { return .result() }
        try Store.shared().updateIfPresent { state in
            let primary = state.hero
            guard !follows || primary == target else { return false }
            let preference = state.mode
            let effective = preference.effective()
            guard effective == .normal || effective == .eco else { return false }
            state.mode = effective
            state.hero = target
            state.react(source: .widgetIntent)
            state.hero = primary
            state.mode = preference
            return true
        }
        return .result()
    }
}

struct Entry: TimelineEntry {
    let date: Date
    let state: Companion
    let settings: Settings
    var display: Reaction?
    var available = true
    var retryAfterCooling = false
    var pack: CharacterPack? = nil
    var artwork: [ArtworkRequest: UIImage] = [:]
    var nightScreenTimeAt: Date? = nil

    func prepared(for family: WidgetFamily) async -> Self {
        guard available else { return self }
        var result = self
        let hero = state.hero
        result.pack = pack ?? hero.pack
        let compact = [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(family)
        let base = ArtworkRequest(hero: hero, file: settings.form.baseImageName, pixels: compact ? 160 : 512)
        guard result.pack != nil, let baseImage = await ArtworkDecoder.shared.image(for: base) else {
            return Entry(date: date, state: Companion(), settings: settings, available: false)
        }
        let line = display ?? state.reaction(using: result.pack)
        result.display = line
        guard family != .accessoryInline else { return result }
        let figure = ArtworkRequest.figure(hero, portrait: settings.form == .portrait, emotion: line.emotion,
                                           daytime: line.daytimePose, pixels: compact ? 160 : 512)
        var requests: Set<ArtworkRequest> = [figure]
        if !compact {
            requests.insert(.backdrop(hero, date: date, mode: state.mode, schedule: state.daySchedule))
            if state.mode == .normal && state.animationsEnabled && settings.form == .chibi && family != .systemSmall,
               let descriptor = result.pack?.animation(for: family == .systemLarge ? .widgetLarge : .widgetMedium,
                                                       reactionID: line.id) {
                let contactVisible = state.contact.map { $0.response == line.id } ?? false
                let layeredRest = line.emotion == .neutral && (descriptor.id == .spirit || descriptor.id == .expression)
                if contactVisible || descriptor.id == .portal || layeredRest {
                    for file in descriptor.assets { requests.insert(ArtworkRequest(hero: hero, file: file)) }
                }
            }
        }
        result.artwork = await ArtworkDecoder.shared.images(for: requests)
        result.artwork[base] = baseImage
        return result
    }
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), state: Companion(), settings: Settings(), available: false)
    }

    func current(_ configuration: Settings, store: () throws -> Store = Store.shared,
                 effectiveMode: (CompanionMode) -> CompanionMode = { $0.effective() },
                 hasResources: ((Hero) -> Bool)? = nil) -> Entry {
        do {
            guard var state = try store().readIfPresent() else { throw StoreError.unavailable }
            state.personalNoticeJournal = nil
            state.calendarNoticeJournal = nil
            if let fixed = Hero(rawValue: configuration.selection.rawValue) { state.hero = fixed }
            let hero = state.hero
            guard let pack = hero.pack, hasResources?(hero) != false else { throw StoreError.unavailable }
            let preference = state.mode
            state.mode = effectiveMode(preference)
            let now = Date()
            state.calendarSnapshot = state.calendarSnapshot.isFresh(at: now)
                ? state.calendarSnapshot.filtered(by: configuration.calendarPrivacy(for: state.mode)) : CalendarSnapshot()
            if configuration.showsTask {
                state.reminders.removeAll { $0.completedAt != nil || $0.target == nil }
                for index in state.reminders.indices { state.reminders[index].title = "" }
            } else {
                state.reminders.removeAll()
            }
            let nightScreenTimeAt = ScreenTimePolicy.nightEvent(at: now)?.date
            return Entry(date: now, state: state, settings: configuration,
                         display: DayTimeline.display(state, at: now, calendar: .current, showsTask: configuration.showsTask, channel: "widget", using: pack, nightScreenTimeAt: nightScreenTimeAt),
                         retryAfterCooling: state.mode == .safe && (preference == .normal || preference == .eco), pack: pack,
                         nightScreenTimeAt: nightScreenTimeAt)
        } catch {
            return Entry(date: Date(), state: Companion(), settings: configuration, available: false)
        }
    }

    func snapshot(for configuration: Settings, in context: Context) async -> Entry {
        if context.isPreview {
            var sample = Companion()
            sample.hero = Hero(rawValue: configuration.selection.rawValue) ?? .gojo
            return await Entry(date: Date(), state: sample, settings: configuration).prepared(for: context.family)
        }
        return await current(configuration).prepared(for: context.family)
    }

    func timeline(for configuration: Settings, in context: Context) async -> Timeline<Entry> {
        let interval = widgetPerformance.beginInterval("Timeline", id: widgetPerformance.makeSignpostID())
        defer { widgetPerformance.endInterval("Timeline", interval) }
        let first = await current(configuration).prepared(for: context.family)
        guard first.available, first.state.mode == .normal || first.state.mode == .eco else {
            // WidgetKit can re-evaluate transient thermal restrictions after a quiet Eco interval.
            let policy: TimelineReloadPolicy = first.retryAfterCooling ? .after(first.date.addingTimeInterval(2 * 3600)) : .never
            return Timeline(entries: [first], policy: policy)
        }
        let calendar = Calendar.current
        var scheduled = Set(DayTimeline.dates(from: first.date, state: first.state, calendar: calendar))
        if let event = first.nightScreenTimeAt {
            let expiry = event.addingTimeInterval(DayTimeline.bedtimeReactionDuration)
            if expiry > first.date { scheduled.insert(expiry) }
        }
        if let weather = first.state.sceneWeather, weather.isSunny(at: first.date) {
            scheduled.insert(weather.expiry)
        }
        let snapshot = first.state.calendarSnapshot
        if let expiry = snapshot.expiry, snapshot.isFresh(at: first.date) {
            scheduled.insert(expiry)
            for end in snapshot.events.map(\.end).sorted() where end > first.date && end < expiry {
                if scheduled.count >= 48 { break }
                if scheduled.allSatisfy({ abs($0.timeIntervalSince(end)) >= 300 }) {
                    scheduled.insert(end)
                }
            }
        }
        let dates = scheduled.sorted()
        var entries = [first]
        for date in dates where date > first.date {
            var state = first.state
            if !snapshot.isFresh(at: date) { state.calendarSnapshot = CalendarSnapshot() }
            let entry = Entry(date: date, state: state, settings: configuration,
                              display: DayTimeline.display(state, at: date, calendar: calendar, showsTask: configuration.showsTask, channel: "widget", using: first.pack, nightScreenTimeAt: first.nightScreenTimeAt),
                              pack: first.pack)
            entries.append(await entry.prepared(for: context.family))
        }
        return Timeline(entries: entries, policy: .after(first.date.addingTimeInterval(12 * 3600)))
    }
}

struct WidgetAccessory: View {
    let entry: Entry
    let size: WidgetFamily
    @Environment(\.dynamicTypeSize) private var typeSize
    private var line: Reaction { entry.display ?? Reaction("idle", "", "Отдыхает") }
    private var speech: String { entry.settings.showsSpeech ? line.text : "" }
    private var symbol: String { entry.pack?.theme.symbol ?? "sparkles" }
    private var characterFigure: CompanionFigure {
        CompanionFigure(hero: entry.state.hero, portrait: entry.settings.form == .portrait,
                        emotion: line.emotion, daytimePose: line.daytimePose, pixels: 160)
    }

    @ViewBuilder var body: some View {
        switch size {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                characterFigure
                    .contrast(1.18).padding(1)
            }.accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(entry.state.hero.name))
        case .accessoryInline:
            Label(entry.state.hero.name, systemImage: symbol)
        case .accessoryRectangular:
            HStack(spacing: 4) {
                if !typeSize.isAccessibilitySize {
                    characterFigure
                        .frame(width: 40, height: 46)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.state.hero.name).font(.headline).lineLimit(1)
                    ViewThatFits(in: .vertical) {
                        Text(speech.isEmpty ? line.action : (entry.pack?.byID[line.id]?.shortText ?? speech))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(line.action).lineLimit(2)
                    }
                    .font(.caption)
                    .accessibilityLabel(Text(speech.isEmpty ? line.action : speech))
                }
            }
        default: EmptyView()
        }
    }
}

struct WidgetScene: View {
    @Environment(\.widgetFamily) private var systemFamily
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let entry: Entry
    private let familyOverride: WidgetFamily?
    private var family: WidgetFamily { familyOverride ?? systemFamily }

    init(entry: Entry, family: WidgetFamily? = nil) {
        self.entry = entry
        familyOverride = family
    }
    private var line: Reaction { entry.display ?? Reaction("idle", "", "Отдыхает") }
    private var speech: String { entry.settings.showsSpeech ? line.text : "" }
    private var animates: Bool {
        entry.available && entry.state.animationsEnabled && !reduceMotion && entry.state.mode == .normal
    }

    private var allowsConversation: Bool {
        entry.state.mode == .normal || entry.state.mode == .eco
    }

    private var showsMortar: Bool {
        entry.state.hero == .maomao && entry.state.mode == .normal && entry.pack?.byID[line.id]?.behaviorID == "mortar"
    }

    private var characterFigure: CompanionFigure {
        CompanionFigure(hero: entry.state.hero, portrait: entry.settings.form == .portrait,
                        emotion: line.emotion, daytimePose: line.daytimePose, apothecaryMortar: showsMortar)
    }

    private var descriptor: CharacterPack.AnimationDescriptor? {
        guard animates, !typeSize.isAccessibilitySize, entry.settings.form == .chibi else { return nil }
        switch family {
        case .systemMedium: return entry.pack?.animation(for: .widgetMedium, reactionID: line.id)
        case .systemLarge: return entry.pack?.animation(for: .widgetLarge, reactionID: line.id)
        default: return nil
        }
    }

    @ViewBuilder private var homeFigure: some View {
        if entry.settings.form == .chibi && entry.state.hero == .maomao && family == .systemSmall && !showsMortar {
            characterFigure.aspectRatio(1, contentMode: .fit).scaleEffect(1.42, anchor: .top).clipped()
        } else {
            CharacterActionFigure(figure: characterFigure, descriptor: descriptor,
                                  contactDate: entry.state.contact.flatMap { $0.response == line.id ? $0.date : nil },
                                  emotion: line.emotion)
                .scaleEffect(family == .systemMedium && descriptor?.id == .spirit ? 1.14 :
                             (family == .systemMedium && descriptor?.id == .expression ? 1.12 : 1))
        }
    }

    private var figure: some View {
        let summon = descriptor?.id == .summon
        return homeFigure
            .frame(maxWidth: family == .systemSmall ? 110 : (summon ? ShadowSummonLayout.preferredGroupWidth : (family == .systemLarge ? 172 : 124)),
                   maxHeight: family == .systemSmall ? 90 : (family == .systemLarge ? 190 : 126))
            .shadow(color: .black.opacity(0.42), radius: 3, y: 2)
            .transition(.opacity)
    }

    private var bubble: some View {
        Text(speech).font(.callout).foregroundStyle(.black).padding(7)
            .background(Color(red: 1, green: 0.97, blue: 0.91), in: RoundedRectangle(cornerRadius: 10))
            .lineLimit(family == .systemSmall ? 3 : 5)
            .contentTransition(animates ? .opacity : .identity)
    }

    private var smallFeaturedHero: some View {
        GeometryReader { bounds in
            ZStack(alignment: .bottomLeading) {
                homeFigure
                    .shadow(color: .white.opacity(0.60), radius: 2)
                    .frame(width: bounds.size.width, height: bounds.size.height, alignment: .top)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.state.hero.name).font(.caption.bold())
                        .foregroundStyle(.white).padding(.horizontal, 4)
                        .background(.black.opacity(0.78), in: Capsule())
                    if !speech.isEmpty {
                        Text(entry.pack?.byID[line.id]?.shortText ?? speech)
                            .font(.caption).foregroundStyle(.black).lineLimit(3)
                            .padding(4).background(.white, in: RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel(Text(speech))
                    }
                }
            }
        }
    }

    @ViewBuilder var scene: some View {
        switch family {
        case .accessoryCircular, .accessoryInline, .accessoryRectangular:
            WidgetAccessory(entry: entry, size: family)
        case .systemSmall:
            smallFeaturedHero
        default:
            VStack(alignment: .leading, spacing: 10) {
                let caption = VStack(alignment: .leading, spacing: 4) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.state.hero.name).font(.headline)
                        Text(line.action).font(.caption)
                    }.widgetCaptionBackground()
                    if !speech.isEmpty { bubble }
                }
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.state.hero.name).font(.headline).lineLimit(1).widgetCaptionBackground()
                        if !speech.isEmpty {
                            Text(entry.pack?.byID[line.id]?.shortText ?? speech)
                                .font(.caption).lineLimit(2).padding(4)
                                .foregroundStyle(.black).background(.white, in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel(Text(speech))
                        }
                    }
                } else if let descriptor, descriptor.id == .portal {
                    CompanionPortalScene(hero: entry.state.hero, right: entry.state.contact?.portalOnRight ?? false,
                                         duration: descriptor.duration, figure: figure, caption: caption)
                } else {
                    HStack(spacing: 8) { figure; caption }
                }
                if family == .systemMedium || family == .systemLarge {
                    ForEach(entry.state.calendarSnapshot.upcoming(at: entry.date).prefix(family == .systemLarge ? 3 : 1)) { event in
                        HStack(spacing: 4) {
                            Image(systemName: "calendar")
                            Text(event.start, format: .dateTime.day().month())
                            Text(event.timeLabel)
                            Text(event.label)
                        }.font(.caption2).lineLimit(1).widgetCaptionBackground().privacySensitive()
                    }
                }
                if (family == .systemMedium || family == .systemLarge), entry.settings.showsTask,
                   let due = entry.state.reminders.filter({ $0.completedAt == nil }).compactMap(\.target).min() {
                    Label("Задача · \(due.formatted(date: .abbreviated, time: .shortened))", systemImage: "checklist")
                        .font(.caption2).lineLimit(1).widgetCaptionBackground().privacySensitive()
                }
                if family == .systemLarge && entry.settings.showsCount {
                    let count = entry.state.unlocks.filter { $0.id.hasPrefix(entry.state.hero.rawValue + "_") }.count
                    Text("Находки · \(count)").font(.subheadline).widgetCaptionBackground()
                }
            }.foregroundStyle(.white).shadow(color: .black.opacity(0.35), radius: 1).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
    private func actionLabel(_ title: String, _ icon: String) -> some View {
        VStack(spacing: 2) {
            Image(systemName: icon)
            if !typeSize.isAccessibilitySize { Text(title).font(.caption2.bold()) }
        }.foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 44)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 11))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(title))
    }

    var body: some View {
        Group {
            if !entry.available {
                if family == .accessoryCircular {
                    Image(systemName: "moon.stars").accessibilityLabel("Откройте Мой Компаньон")
                } else {
                    Label("Откройте Мой Компаньон", systemImage: "moon.stars")
                }
            }
            else if family == .systemLarge {
                VStack(spacing: 4) {
                    if allowsConversation {
                        Button(intent: React(hero: entry.state.hero, follows: entry.settings.selection == .followPrimary)) { scene }
                            .buttonStyle(.plain)
                    } else { scene }
                    HStack(spacing: 4) {
                        Link(destination: URL(string: "mycompanion://calendar")!) { actionLabel("Календарь", "calendar") }
                        if allowsConversation {
                            Button(intent: React(hero: entry.state.hero, follows: entry.settings.selection == .followPrimary)) {
                                actionLabel("Поговорить", "bubble.left")
                            }.buttonStyle(.plain)
                        }
                        Link(destination: URL(string: "mycompanion://reminders")!) { actionLabel("Задачи", "checklist") }
                    }
                }
            }
            else if family == .accessoryInline || !allowsConversation { scene }
            else {
                Button(intent: React(hero: entry.state.hero, follows: entry.settings.selection == .followPrimary)) { scene }
                    .buttonStyle(.plain).accessibilityHint("Новая реакция персонажа")
            }
        }.animation(animates ? .easeOut(duration: 0.2) : nil, value: line.id)
        .transaction { if !animates { $0.disablesAnimations = true; $0.animation = nil } }
        .containerBackground(for: .widget) {
            if entry.available && [.systemSmall, .systemMedium, .systemLarge].contains(family) {
                HeroBackdrop(hero: entry.state.hero, date: entry.date, mode: entry.state.mode,
                             daySchedule: entry.state.daySchedule)
                    .environment(\.preparedArtwork, entry.artwork)
                    .environment(\.scenePack, entry.pack)
            } else { Color.clear }
        }.environment(\.preparedArtwork, entry.artwork)
            .environment(\.scenePack, entry.pack)
    }
}

private extension View {
    func widgetCaptionBackground() -> some View {
        foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color(red: 0.12, green: 0.13, blue: 0.16), in: RoundedRectangle(cornerRadius: 6))
    }
}

#if !STAGE5_WIDGET_TESTS
@main
#endif
struct CompanionWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Companion", intent: Settings.self, provider: Provider()) { entry in
            WidgetScene(entry: entry)
        }.configurationDisplayName("Мой Компаньон")
        .description("Выберите персонажа и коснитесь его, чтобы поговорить.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
