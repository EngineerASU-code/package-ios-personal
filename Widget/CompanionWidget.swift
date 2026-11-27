import AppIntents
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

struct Settings: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Настройки компаньона"
    @Parameter(title: "Персонаж", default: .followPrimary) var selection: WidgetHero
    @Parameter(title: "Показывать реплики", default: true) var showsSpeech: Bool
    @Parameter(title: "Показывать число находок", default: false) var showsCount: Bool
}

struct React: AppIntent {
    static var title: LocalizedStringResource = "Поговорить"
    @Parameter(title: "Персонаж") var heroID: String
    @Parameter(title: "Основной персонаж", default: true) var follows: Bool

    init() {}
    init(hero: Hero, follows: Bool) { heroID = hero.rawValue; self.follows = follows }

    func perform() async throws -> some IntentResult {
        guard let target = Hero(rawValue: heroID) else { return .result() }
        try Store.shared().update { state in
            let primary = state.hero
            guard !follows || primary == target else { return }
            state.hero = target
            state.react()
            state.hero = primary
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
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), state: Companion(), settings: Settings())
    }

    func current(_ configuration: Settings) -> Entry {
        do {
            var state = try Store.shared().read()
            if let fixed = Hero(rawValue: configuration.selection.rawValue) { state.hero = fixed }
            let process = ProcessInfo.processInfo
            if state.mode != .paused && process.thermalState == .critical { state.mode = .safe }
            if state.mode == .normal && (process.isLowPowerModeEnabled || process.thermalState == .serious) { state.mode = .eco }
            let now = Date()
            return Entry(date: now, state: state, settings: configuration,
                         display: DayTimeline.display(state, at: now, calendar: .current))
        } catch {
            return Entry(date: Date(), state: Companion(), settings: configuration, available: false)
        }
    }

    func snapshot(for configuration: Settings, in context: Context) async -> Entry {
        if context.isPreview {
            var sample = Companion()
            sample.hero = Hero(rawValue: configuration.selection.rawValue) ?? .gojo
            return Entry(date: Date(), state: sample, settings: configuration)
        }
        return current(configuration)
    }

    func timeline(for configuration: Settings, in context: Context) async -> Timeline<Entry> {
        let first = current(configuration)
        guard first.available, first.state.mode == .normal || first.state.mode == .eco else {
            return Timeline(entries: [first], policy: .never)
        }
        let calendar = Calendar.current
        let dates = DayTimeline.dates(from: first.date, mode: first.state.mode, calendar: calendar)
        let entries = dates.map { date in
            Entry(date: date, state: first.state, settings: configuration,
                  display: DayTimeline.display(first.state, at: date, calendar: calendar))
        }
        return Timeline(entries: entries, policy: .after(first.date.addingTimeInterval(12 * 3600)))
    }
}

struct WidgetScene: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let entry: Entry
    private var line: Reaction { entry.display ?? entry.state.reaction }
    private var symbol: String { entry.state.hero.sceneSymbol }
    private var speech: String { entry.settings.showsSpeech ? line.text : "" }
    @ViewBuilder var scene: some View {
        switch family {
        case .accessoryCircular:
            Image(systemName: symbol).widgetAccentable().accessibilityLabel(entry.state.hero.name)
        case .accessoryInline:
            Label(entry.state.hero.name, systemImage: symbol)
        case .accessoryRectangular:
            VStack(alignment: .leading) {
                Text(entry.state.hero.name).font(.headline)
                Text(speech.isEmpty ? line.action : speech).lineLimit(2)
            }
        default:
            VStack(alignment: .leading, spacing: family == .systemSmall ? 4 : 10) {
                Label(entry.state.hero.name, systemImage: symbol).font(.headline)
                if family != .systemSmall || speech.isEmpty { Text(line.action).font(.caption) }
                if !speech.isEmpty {
                    Text(speech).font(.callout).padding(6)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                        .lineLimit(family == .systemSmall ? 3 : 5)
                        .contentTransition(.opacity)
                }
                if family == .systemLarge && entry.settings.showsCount {
                    let count = entry.state.unlocks.filter { $0.id.hasPrefix(entry.state.hero.rawValue + "_") }.count
                    Text("Находки · \(count)").font(.subheadline)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
    var body: some View {
        Group {
            if !entry.available { Text("Откройте Мой Компаньон") }
            else if family == .accessoryInline || entry.state.mode == .safe || entry.state.mode == .paused { scene }
            else {
                Button(intent: React(hero: entry.state.hero, follows: entry.settings.selection == .followPrimary)) { scene }
                    .buttonStyle(.plain).accessibilityHint("Новая реакция персонажа")
            }
        }.animation(!reduceMotion && entry.state.mode == .normal ? .easeOut(duration: 0.2) : nil, value: line.id)
        .containerBackground(for: .widget) { entry.state.hero.sceneColor.opacity(0.18) }
    }
}

@main struct CompanionWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Companion", intent: Settings.self, provider: Provider()) { entry in
            WidgetScene(entry: entry)
        }.configurationDisplayName("Мой Компаньон")
        .description("Выберите персонажа и коснитесь его, чтобы поговорить.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
