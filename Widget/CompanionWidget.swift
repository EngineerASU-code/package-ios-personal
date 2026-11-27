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
    @Parameter(title: "Показывать срок задачи", default: true) var showsTask: Bool
    @Parameter(title: "Показывать число находок", default: false) var showsCount: Bool
    @Parameter(title: "Показывать календарь", default: true) var showsCalendar: Bool
}

private func widgetMode(for preference: CompanionMode, process: ProcessInfo = .processInfo) -> CompanionMode {
    if preference != .paused && process.thermalState == .critical { return .safe }
    if preference == .normal && (process.isLowPowerModeEnabled || process.thermalState == .serious) { return .eco }
    return preference
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
            let preference = state.mode
            let effective = widgetMode(for: preference)
            guard effective == .normal || effective == .eco else { return }
            state.mode = effective
            state.hero = target
            state.react(source: .widgetIntent)
            state.hero = primary
            state.mode = preference
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
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: Date(), state: Companion(), settings: Settings())
    }

    func current(_ configuration: Settings, store: () throws -> Store = Store.shared,
                 effectiveMode: (CompanionMode) -> CompanionMode = { widgetMode(for: $0) },
                 hasResources: (Hero) -> Bool = { hero in
                     hero.pack != nil && UIImage(named: "Characters/" + hero.rawValue + "/chibi.png") != nil
                 }) -> Entry {
        do {
            guard var state = try store().readIfPresent() else { throw StoreError.unavailable }
            if let fixed = Hero(rawValue: configuration.selection.rawValue) { state.hero = fixed }
            guard hasResources(state.hero) else { throw StoreError.unavailable }
            let preference = state.mode
            state.mode = effectiveMode(preference)
            let calendarPrivacy: CalendarPrivacy = configuration.showsCalendar && state.mode != .safe && state.mode != .paused
                ? .current : .off
            state.calendarSnapshot = state.calendarSnapshot.filtered(by: calendarPrivacy)
            let now = Date()
            return Entry(date: now, state: state, settings: configuration,
                         display: DayTimeline.display(state, at: now, calendar: .current, showsTask: configuration.showsTask, channel: "widget"),
                         retryAfterCooling: state.mode == .safe && (preference == .normal || preference == .eco))
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
            // WidgetKit can re-evaluate transient thermal restrictions after a quiet Eco interval.
            let policy: TimelineReloadPolicy = first.retryAfterCooling ? .after(first.date.addingTimeInterval(2 * 3600)) : .never
            return Timeline(entries: [first], policy: policy)
        }
        let calendar = Calendar.current
        var scheduled = Set(DayTimeline.dates(from: first.date, state: first.state, calendar: calendar))
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
        let entries = dates.map { date in
            Entry(date: date, state: first.state, settings: configuration,
                  display: DayTimeline.display(first.state, at: date, calendar: calendar, showsTask: configuration.showsTask, channel: "widget"))
        }
        return Timeline(entries: entries, policy: .after(first.date.addingTimeInterval(12 * 3600)))
    }
}

struct WidgetScene: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize
    let entry: Entry
    private var line: Reaction { entry.display ?? entry.state.reaction }
    private var symbol: String { entry.state.hero.sceneSymbol }
    private var speech: String { entry.settings.showsSpeech ? line.text : "" }
    private var animates: Bool {
        entry.available && !reduceMotion && entry.state.mode == .normal
    }

    private var showsPortal: Bool {
        animates && (family == .systemMedium || family == .systemLarge)
            && entry.state.hero == .maomao
            && entry.state.hero.pack != nil
    }

    private var portalOnRight: Bool { entry.state.contact?.portalOnRight ?? false }

    @ViewBuilder private var homeFigure: some View {
        let model = CompanionFigure(hero: entry.state.hero, emotion: line.emotion, daytimePose: line.daytimePose)
        if animates && entry.state.hero == .jinwoo && (family == .systemMedium || family == .systemLarge) {
            ShadowSummon(figure: model, contact: entry.state.contact.flatMap { $0.response == line.id ? $0.date : nil }, animate: animates)
        } else if entry.state.hero == .maomao {
            model.aspectRatio(1, contentMode: .fit)
                .scaleEffect(family == .systemSmall ? 1.42 : 1, anchor: .top)
                .clipped()
        } else if animates && entry.state.hero == .toji && (family == .systemMedium || family == .systemLarge) {
            ZStack {
                if let contact = entry.state.contact, contact.response == line.id {
                    TojiSpirit(progress: 1)
                        .id(contact.date)
                        .transition(.asymmetric(insertion: .modifier(
                            active: TojiSpiritPhase(progress: 0), identity: TojiSpiritPhase(progress: 1)),
                            removal: .identity))
                } else if line.emotion == .neutral {
                    TojiSpirit(progress: 0)
                } else {
                    model
                }
            }
            .scaleEffect(family == .systemMedium ? 1.14 : 1)
            .animation(animates ? .linear(duration: 1.38) : nil, value: entry.state.contact?.date)
        } else if animates && entry.state.hero == .sukuna && (family == .systemMedium || family == .systemLarge) {
            ZStack {
                if let contact = entry.state.contact, contact.response == line.id {
                    Color.clear.modifier(SukunaExpression(progress: 1))
                        .aspectRatio(1, contentMode: .fit)
                        .id(contact.date)
                        .transition(.asymmetric(insertion: .modifier(
                            active: SukunaExpression(progress: 0), identity: SukunaExpression(progress: 1)),
                            removal: .identity))
                } else if line.emotion == .neutral {
                    Color.clear.modifier(SukunaExpression(progress: 0))
                } else {
                    model
                }
            }
            .scaleEffect(family == .systemMedium ? 1.12 : 1)
            .animation(animates ? .linear(duration: 0.9) : nil, value: entry.state.contact?.date)
        } else {
            model
        }
    }

    private var figure: some View {
        let summon = entry.state.hero == .jinwoo && entry.state.mode == .normal
        return homeFigure
            .frame(maxWidth: family == .systemSmall ? 110 : (summon ? 190 : (family == .systemLarge ? 172 : 124)),
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

    @ViewBuilder func accessory(_ size: WidgetFamily) -> some View {
        switch size {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                CompanionFigure(hero: entry.state.hero, emotion: line.emotion, daytimePose: line.daytimePose)
                    .contrast(1.18).padding(1)
            }.accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(entry.state.hero.name))
        case .accessoryInline:
            Label(entry.state.hero.name, systemImage: symbol)
        case .accessoryRectangular:
            HStack(spacing: 4) {
                if !typeSize.isAccessibilitySize {
                    CompanionFigure(hero: entry.state.hero, emotion: line.emotion, daytimePose: line.daytimePose)
                        .frame(width: 40, height: 46)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.state.hero.name).font(.headline).lineLimit(1)
                    Text(speech.isEmpty ? line.action : (entry.state.hero.pack?.byID[line.id]?.shortText ?? speech))
                        .font(.caption).lineLimit(2)
                }
            }
        default: EmptyView()
        }
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
                        Text(entry.state.hero.pack?.byID[line.id]?.shortText ?? speech)
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
            accessory(family)
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
                            Text(entry.state.hero.pack?.byID[line.id]?.shortText ?? speech)
                                .font(.caption).lineLimit(2).padding(4)
                                .foregroundStyle(.black).background(.white, in: RoundedRectangle(cornerRadius: 6))
                                .accessibilityLabel(Text(speech))
                        }
                    }
                } else if showsPortal {
                    CompanionPortalScene(hero: entry.state.hero, right: portalOnRight, figure: figure, caption: caption)
                } else {
                    HStack(spacing: 8) {
                        if animates, entry.state.hero == .gojo,
                           let contact = entry.state.contact, contact.response == line.id,
                           line.emotion != .sleepy {
                            GojoGaze(progress: 1)
                                .id(contact.date)
                                .transition(.asymmetric(insertion: .modifier(
                                    active: GojoGazePhase(progress: 0),
                                    identity: GojoGazePhase(progress: 1)), removal: .identity))
                                .frame(maxWidth: family == .systemLarge ? 172 : 124,
                                       maxHeight: family == .systemLarge ? 190 : 126)
                                .animation(animates ? .linear(duration: 1.4) : nil, value: contact.date)
                        } else if animates && entry.state.hero == .jinshi {
                            figure.overlay {
                                ZStack {
                                    if let contact = entry.state.contact, contact.response == line.id {
                                        JinshiFan(opening: 1)
                                            .id(contact.date)
                                            .transition(.asymmetric(insertion: .modifier(
                                                active: FoldedFan(progress: 0), identity: FoldedFan(progress: 1)),
                                                removal: .identity))
                                    }
                                }
                                .animation(animates ? .easeInOut(duration: 0.95) : nil, value: entry.state.contact?.date)
                                .accessibilityHidden(true)
                            }
                        } else {
                            figure
                        }
                        caption
                    }.animation(entry.state.hero == .gojo && animates ? .linear(duration: 1.4) : nil,
                                value: entry.state.hero == .gojo ? entry.state.contact?.date : nil)
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
            else if family == .accessoryInline || entry.state.mode == .safe || entry.state.mode == .paused { scene }
            else if family == .systemLarge {
                VStack(spacing: 4) {
                    Button(intent: React(hero: entry.state.hero, follows: entry.settings.selection == .followPrimary)) { scene }
                        .buttonStyle(.plain)
                    HStack(spacing: 4) {
                        Link(destination: URL(string: "mycompanion://calendar")!) { actionLabel("Календарь", "calendar") }
                        Button(intent: React(hero: entry.state.hero, follows: entry.settings.selection == .followPrimary)) {
                            actionLabel("Поговорить", "bubble.left")
                        }.buttonStyle(.plain)
                        Link(destination: URL(string: "mycompanion://reminders")!) { actionLabel("Задачи", "checklist") }
                    }
                }
            }
            else {
                Button(intent: React(hero: entry.state.hero, follows: entry.settings.selection == .followPrimary)) { scene }
                    .buttonStyle(.plain).accessibilityHint("Новая реакция персонажа")
            }
        }.animation(animates ? .easeOut(duration: 0.2) : nil, value: line.id)
        .transaction { if !animates { $0.disablesAnimations = true; $0.animation = nil } }
        .containerBackground(for: .widget) {
            if entry.available && [.systemSmall, .systemMedium, .systemLarge].contains(family) {
                HeroBackdrop(hero: entry.state.hero, date: entry.date, mode: entry.state.mode)
            } else { Color.clear }
        }
    }
}

private struct FoldedFan: AnimatableModifier {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        JinshiFan(opening: progress)
    }
}

private struct JinshiFan: View {
    let opening: Double

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let pivot = CGPoint(x: size.width / 2 + side * 0.10, y: size.height / 2 + side * 0.17)
            context.translateBy(x: pivot.x, y: pivot.y)
            context.rotate(by: .degrees(-18 + 10 * opening))
            let radius = side * 0.31
            let halfAngle = 4 + 59 * opening
            let gold = Color(red: 0.96, green: 0.79, blue: 0.51)
            for leaf in 0..<10 {
                let a = (-90 - halfAngle + Double(leaf) * halfAngle / 5) * .pi / 180
                let b = a + halfAngle * .pi / 900
                let outer = CGPoint(x: radius * cos(a), y: radius * sin(a))
                let next = CGPoint(x: radius * cos(b), y: radius * sin(b))
                var panel = Path()
                panel.move(to: .zero)
                panel.addLine(to: outer)
                panel.addLine(to: next)
                panel.closeSubpath()
                context.fill(panel, with: .color(leaf.isMultiple(of: 2)
                    ? Color(red: 0.52, green: 0.28, blue: 0.46)
                    : Color(red: 0.71, green: 0.46, blue: 0.60)))
                context.stroke(panel, with: .color(gold), lineWidth: side * 0.005)
            }
            context.fill(Path(ellipseIn: CGRect(x: -2, y: -2, width: 4, height: 4)), with: .color(gold))
        }
    }
}

private struct SukunaExpression: AnimatableModifier {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let chin = blend(from: 0.04, to: 0.43)
        let smile = blend(from: 0.58, to: 1)
        return ZStack {
            pose("tap-calm").opacity(1 - chin)
            pose("tap-chin").opacity(chin * (1 - smile))
            pose("tap-smirk").opacity(smile)
        }.accessibilityHidden(true)
    }

    private func blend(from start: Double, to end: Double) -> Double {
        let t = min(1, max(0, (progress - start) / (end - start)))
        return t * t * (3 - 2 * t)
    }

    private func pose(_ name: String) -> some View {
        Image("Characters/ryomen_sukuna/" + name + ".png").resizable().scaledToFit()
    }
}

private struct TojiSpiritPhase: AnimatableModifier {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View { TojiSpirit(progress: progress) }
}

private struct TojiSpirit: View {
    let progress: Double

    private func blend(from start: Double, to end: Double) -> Double {
        let t = min(1, max(0, (progress * 980 - start) / (end - start)))
        return t * t * (3 - 2 * t)
    }

    var body: some View {
        let reach = blend(from: 80, to: 310)
        let lower = blend(from: 700, to: 980)
        ZStack {
            pose("spirit-idle").opacity(1 - reach)
            pose("spirit-draw").opacity(reach * (1 - lower))
            pose("spirit-blade").opacity(lower)
        }.accessibilityHidden(true)
    }

    private func pose(_ name: String) -> some View {
        Image("Characters/toji_fushiguro/" + name + ".png").resizable().scaledToFit()
    }
}

private struct GojoGazePhase: AnimatableModifier {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View { GojoGaze(progress: progress) }
}

private struct GojoGaze: View {
    let progress: Double

    private func layer(_ name: String, from start: Double, to end: Double) -> some View {
        let amount = min(1, max(0, (progress - start) / (end - start)))
        return Image("Characters/satoru_gojo/" + name + ".png")
            .resizable().scaledToFit().opacity(amount * amount * (3 - 2 * amount))
    }

    var body: some View {
        ZStack {
            // Complementary alpha on the moving arm avoids leaving the original hand beneath it.
            layer("chibi", from: -1, to: 0).opacity(1 - min(1, max(0, progress / 0.22)))
            layer("blindfold-touch", from: 0, to: 0.22).opacity(1 - min(1, max(0, (progress - 0.22) / 0.24)))
            layer("blindfold-gaze", from: 0.22, to: 0.46)
            layer("blindfold-smirk", from: 0.78, to: 1)
        }.accessibilityHidden(true)
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
