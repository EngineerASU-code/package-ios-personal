import Foundation

enum CompanionMode: String, Codable, CaseIterable {
    case normal = "Обычный", eco = "Экономный", safe = "Безопасный", paused = "Пауза"
}

enum ComplimentFrequency: String, Codable, CaseIterable {
    case regular = "Обычная", reduced = "Реже", off = "Выключены"
}

enum PassivePhraseFrequency: String, Codable, CaseIterable {
    case regular = "Обычная", reduced = "Реже", off = "Только по делу"
}

enum CommunicationIntensity: String, Codable, CaseIterable {
    case standard = "Характер героя", restrained = "Сдержанная"

    func permits(_ row: CharacterPack.Record, channel: String) -> Bool {
        guard self == .restrained else { return true }
        let text = channel == "notification" ? (row.shortText ?? row.text) : row.text
        return text.count <= 60 && !text.contains("!") && !text.contains("?")
    }
}

enum ChibiEmotion: String { case neutral, happy, sleepy, surprised }

struct Reaction {
    var daytimePose = false
    let emotion: ChibiEmotion
    let id: String
    let text: String
    let action: String

    init(_ id: String, _ text: String, _ action: String, emotion: ChibiEmotion = .neutral) {
        self.emotion = emotion
        self.id = id
        self.text = text
        self.action = action
    }
}

enum Hero: String, Codable, CaseIterable {
    case gojo = "satoru_gojo"
    case toji = "toji_fushiguro"
    case jinshi = "jinshi"
    case jinwoo = "sung_jinwoo"
    case sukuna = "ryomen_sukuna"
    case maomao = "maomao"

    var name: String {
        switch self {
        case .gojo: return "Сатору Годжо"
        case .toji: return "Тоджи Фушигуро"
        case .jinshi: return "Женьши"
        case .jinwoo: return "Сон Джин Ву"
        case .sukuna: return "Рёмен Сукуна"
        case .maomao: return "Мао Мао"
        }
    }

    var pack: CharacterPack? { CharacterPack.load(self) }
    var dialogue: [Reaction] { pack?.interactive ?? [Reaction("intro", "Я здесь.", "Отдыхает")] }
}

struct Find: Decodable {
    let id: String
    let title: String
    let lineID: String
    let assetID: String
}

struct Unlock: Codable, Equatable {
    let id: String
    let date: Date
    var assetID: String? = nil
}

final class CharacterPack {
    struct AnimationDescriptor: Decodable {
        enum Surface: String, Decodable { case app, widgetMedium, widgetLarge }
        enum Effect: String, Decodable { case gaze, spirit, fan, portal, summon, expression }
        let id: Effect
        let surfaces: [Surface]
        let from, to, fallback, motion: String
        let duration: Double
        let assets: [String]

        func isUsable(for hero: Hero, in directory: URL) -> Bool {
            let allowed: Bool
            switch (hero, id) {
            case (.gojo, .gaze), (.toji, .spirit), (.jinshi, .fan), (.sukuna, .expression),
                 (.jinwoo, .portal), (.jinwoo, .summon), (.maomao, .portal): allowed = true
            default: allowed = false
            }
            return allowed && !surfaces.isEmpty && duration > 0 && duration <= 2
                && !from.isEmpty && !to.isEmpty && from != to && fallback == "staticPose" && motion == "full"
                && !assets.isEmpty && assets.allSatisfy {
                    $0.range(of: #"^[a-z0-9_-]+\.png$"#, options: .regularExpression) != nil &&
                        FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
                }
        }
    }
    private struct AnimationFile: Decodable { let transitions: [AnimationDescriptor] }
    let animations: [AnimationDescriptor.Surface: AnimationDescriptor]
    struct Theme: Decodable { let accent, symbol: String }
    struct Disposition: Decodable {
        let defaultMood, recovery: String

        func expression(for mood: String) -> ChibiEmotion {
            switch mood {
            case "playful", "happy": return .happy
            case "curious", "surprised": return .surprised
            case "sleepy", "resting": return .sleepy
            default: return .neutral
            }
        }
    }
    struct Behavior: Decodable {
        static let states: Set<String> = ["idle", "talking", "resting", "sleeping", "greeting", "working",
                                          "training", "exploring", "celebrating", "annoyed", "specialAction"]
        let id, label, from, to: String
        let triggers, channels, requires: [String]?
        let priority, weight, cooldownSeconds: Int?

        func permits(state: String, trigger: String, channel: String, facts: Set<String>,
                     date: Date, lastUsed: Date?) -> Bool {
            from == state && Self.states.contains(to)
                && (triggers?.contains(trigger) ?? true) && (channels?.contains(channel) ?? true)
                && facts.isSuperset(of: requires ?? []) && (weight ?? 1) > 0
                && (lastUsed.map { max(0, date.timeIntervalSince($0)) >= Double(max(0, cooldownSeconds ?? 0)) } ?? true)
        }
    }
    struct Personality: Decodable {
        let intensity: String
        var voice: String?
    }
    let personality: Personality
    let disposition: Disposition
    let behaviors: [String: Behavior]
    let theme: Theme
    struct Record: Decodable {
        let id, text, category, action: String
        let triggers, channels, requires: [String]
        let weight: Int
        let shortText: String?
        var periods: [DayPeriod]? = nil
        func allows(_ period: DayPeriod) -> Bool {
            if let periods { return periods.contains(period) }
            switch category {
            case "morning": return period == .morning || period == .dawn
            case "night": return period == .night || period == .lateNight
            default: return true
            }
        }
        var behaviorID: String? = nil
        var intensity: String? = nil
        var emotions: [String]? = nil
        var variables: [String]? = nil
        var cooldownSeconds: Int? = nil

        func eligible(trigger: String, channel: String, facts: Set<String>, mood: String?,
                      intensity level: String, period: DayPeriod?, substitutions: [String: String] = [:]) -> Bool {
            weight > 0 && triggers.contains(trigger) && channels.contains(channel)
                && facts.isSuperset(of: requires) && (variables ?? []).allSatisfy { substitutions[$0] != nil }
                && rendered(text, using: substitutions) != nil && (shortText.map { rendered($0, using: substitutions) != nil } ?? true)
                && (emotions.map { allowed in allowed.isEmpty || (mood.map(allowed.contains) ?? false) } ?? true)
                && (intensity == nil || intensity == level) && (period.map(allows) ?? true)
        }
        func rendered(_ template: String, using substitutions: [String: String]) -> String? {
            guard template.contains("{") || template.contains("}") else { return template }
            var result = template
            for name in variables ?? [] {
                guard let value = substitutions[name] else { return nil }
                result = result.replacingOccurrences(of: "{\(name)}", with: value)
            }
            return result.contains("{") || result.contains("}") ? nil : result
        }

        var reaction: Reaction {
            let emotion: ChibiEmotion
            switch category {
            case "night": emotion = .sleepy
            case "compliment", "morning", "return": emotion = .happy
            case "rare": emotion = .surprised
            default: emotion = .neutral
            }
            return Reaction(id, text, action, emotion: emotion)
        }
    }

    // A stable slot value keeps the chosen text unchanged during reconciliation.
    static func notificationLine(in rows: [Record], trigger: String, facts: Set<String>, slot: UInt64,
                                 mood: String? = nil, intensity: String = "gentle", period: DayPeriod? = nil,
                                 communicationIntensity: CommunicationIntensity = .standard) -> Record? {
        let candidates = rows.filter {
            communicationIntensity.permits($0, channel: "notification") &&
            $0.eligible(trigger: trigger, channel: "notification", facts: facts, mood: mood, intensity: intensity, period: period)
        }
        let total = candidates.reduce(UInt64(0)) { $0 + UInt64($1.weight) }
        guard total > 0 else { return nil }
        var choice = slot % total
        for row in candidates {
            if choice < UInt64(row.weight) { return row }
            choice -= UInt64(row.weight)
        }
        return nil
    }

    private struct Manifest: Decodable { let id: String; let schemaVersion: Int }
    private static let cache = NSCache<NSString, CharacterPack>()
    let records: [Record]
    let interactive: [Reaction]
    let finds: [Find]
    let byID: [String: Record]
    let byTrigger: [String: [Record]]

    // JSONDecoder validates the syntax. Reject excessive nesting before decoding any containers.
    private static func hasBoundedDepth(_ data: Data) -> Bool {
        var depth = 0
        var quoted = false
        var escaped = false
        for byte in data {
            if quoted {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { quoted = false }
            } else {
                switch byte {
                case 0x22: quoted = true
                case 0x7B, 0x5B:
                    depth += 1
                    if depth > 24 { return false }
                case 0x7D, 0x5D:
                    depth -= 1
                    if depth < 0 { return false }
                default: break
                }
            }
        }
        return depth == 0 && !quoted
    }

    private init?(hero: Hero, directory: URL) {
        func decode<T: Decodable>(_ file: String) -> T? {
            let url = directory.appendingPathComponent(file)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  (1...1_000_000).contains(size),
                  let data = try? Data(contentsOf: url), data.count == size, Self.hasBoundedDepth(data) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        guard let manifest: Manifest = decode("manifest.json"), manifest.schemaVersion == 1, manifest.id == hero.rawValue,
              let palette: Theme = decode("theme.json"), let rows: [Record] = decode("dialogue.ru.json"), let eggs: [Find] = decode("easter_eggs.json"),
              (100...200).contains(rows.count), eggs.count >= 5,
              Set(rows.map(\.id)).count == rows.count, rows.first?.id == "intro" else { return nil }
        guard let profile: Personality = decode("personality.json"), let moods: Disposition = decode("emotions.json"),
              let actions: [Behavior] = decode("behaviors.json"),
              Set(actions.map(\.id)).count == actions.count else { return nil }
        let actionIDs = Set(actions.map(\.id))
        let rareIDs = Set(rows.filter { $0.category == "rare" }.map(\.id))
        guard rows.allSatisfy({ row in
            (1...1_000_000).contains(row.weight) && (row.cooldownSeconds ?? 0) >= 0 &&
            row.behaviorID.map(actionIDs.contains) == true
        }), actions.allSatisfy({ action in
            Behavior.states.contains(action.from) && Behavior.states.contains(action.to) &&
            (1...1_000_000).contains(action.weight ?? 1) && (action.cooldownSeconds ?? 0) >= 0
        }), Set(eggs.map(\.id)).count == eggs.count, eggs.allSatisfy({ rareIDs.contains($0.lineID) }) else { return nil }
        var scenes: [AnimationDescriptor.Surface: AnimationDescriptor] = [:]
        if let file: AnimationFile = decode("animations.json") {
            for scene in file.transitions where scene.isUsable(for: hero, in: directory) {
                for surface in scene.surfaces { scenes[surface] = scene }
            }
        }
        animations = scenes
        personality = profile
        disposition = moods
        behaviors = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0) })
        let taps = rows.filter {
            ["tap", "compliment", "support"].contains($0.category) && $0.weight > 0 &&
                $0.requires.isEmpty && ["widgetInteraction", "appInteraction"].allSatisfy($0.triggers.contains) &&
                ["widget", "app"].allSatisfy($0.channels.contains)
        }.map(\.reaction)
        guard !taps.isEmpty else { return nil }
        theme = palette
        records = rows
        var index: [String: [Record]] = [:]
        for row in rows {
            for trigger in Set(row.triggers) { index[trigger, default: []].append(row) }
        }
        byTrigger = index
        interactive = taps
        finds = eggs
        byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
    }

    static func load(_ hero: Hero) -> CharacterPack? {
        let key = hero.rawValue as NSString
        if let cached = cache.object(forKey: key) { return cached }
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let root = bundle.resourceURL,
              let pack = CharacterPack(hero: hero, directory: root.appendingPathComponent("Characters").appendingPathComponent(hero.rawValue)) else { return nil }
        cache.setObject(pack, forKey: key)
        return pack
    }
}

enum TaskRecurrence: String, Codable, CaseIterable {
    case once, daily, weekly

    var label: String {
        switch self {
        case .once: return "Без повтора"
        case .daily: return "Каждый день"
        case .weekly: return "Каждую неделю"
        }
    }
}

struct LocalReminder: Codable, Equatable, Identifiable {
    enum Status { case active, overdue, completed }
    enum Source: String { case local = "На этом iPhone" }
    var id = UUID()
    var title = ""
    var createdAt = Date()
    var dueAt: Date?
    var recurrence = TaskRecurrence.once
    var seriesAnchor: Date?
    var seriesTimeZone: String?
    var snoozedUntil: Date?
    var completedAt: Date?
    var notificationEnabled = false
    var revision = 0
    var updatedAt = Date()
    var target: Date? { snoozedUntil ?? dueAt }
    var source: Source { .local }
    var occurrenceKey: String {
        let occurrence = dueAt.map { String($0.timeIntervalSinceReferenceDate.bitPattern, radix: 16) } ?? "undated"
        return id.uuidString + "." + occurrence
    }

    func status(at date: Date) -> Status {
        if completedAt != nil { return .completed }
        if let target, target <= date { return .overdue }
        return .active
    }

    mutating func complete(at now: Date, calendar: Calendar = .current) {
        guard completedAt == nil else { return }
        snoozedUntil = nil
        if let current = dueAt, recurrence != .once {
            var calendar = calendar
            if let seriesTimeZone, let zone = TimeZone(identifier: seriesTimeZone) {
                calendar.timeZone = zone
            } else {
                seriesTimeZone = calendar.timeZone.identifier
            }
            let anchor = seriesAnchor ?? current
            seriesAnchor = anchor
            let threshold = max(current, now)
            let interval = recurrence == .daily ? 1 : 7
            let elapsed = calendar.dateComponents([.day], from: calendar.startOfDay(for: anchor),
                                                   to: calendar.startOfDay(for: threshold)).day ?? 0
            var days = max(1, elapsed / interval) * interval
            var next = calendar.date(byAdding: .day, value: days, to: anchor)
            if let date = next, date <= threshold {
                days += interval
                next = calendar.date(byAdding: .day, value: days, to: anchor)
            }
            if let next { dueAt = next } else { completedAt = now }
        } else { completedAt = now }
        revision += 1
        updatedAt = now
    }

    mutating func snooze(minutes: Int, at now: Date) {
        guard completedAt == nil, [10, 30, 60].contains(minutes) else { return }
        snoozedUntil = now.addingTimeInterval(Double(minutes * 60))
        revision += 1
        updatedAt = now
    }

    func notificationDate(after now: Date, quietStart: Int, quietEnd: Int,
                          allowDuringQuiet: Bool, calendar: Calendar = .current) -> Date? {
        guard notificationEnabled, completedAt == nil, var date = target else { return nil }
        let hour = calendar.component(.hour, from: date)
        let quiet = quietStart > quietEnd ? hour >= quietStart || hour < quietEnd :
            hour >= quietStart && hour < quietEnd
        if quiet && !allowDuringQuiet {
            guard let end = calendar.nextDate(after: date, matching: DateComponents(hour: quietEnd, minute: 0),
                                              matchingPolicy: .nextTime) else { return nil }
            date = end
        }
        return date > now ? date : nil
    }
}

struct CompanionEvent {
    enum Source: String, Codable { case app, widgetIntent, localSchedule, calendarSnapshot, simulatedTest }
    enum Kind: String, Codable, CaseIterable {
        case firstLaunch, appOpened, foregrounded, characterSelected, appInteraction, widgetInteraction
        case repeatInteraction, morningInteraction, scheduledGreeting, daytimeChanged, lateInteraction
        case bedtimeReminder, inactivityElapsed, calendarUpcoming, calendarChanged, reminderDue
        case reminderCreated, reminderCompleted, reminderSnoozed, randomSlot, easterEgg, safeModeChanged, pauseChanged

        var isContact: Bool {
            switch self {
            case .firstLaunch, .appOpened, .foregrounded, .characterSelected, .appInteraction, .widgetInteraction,
                 .repeatInteraction, .morningInteraction, .lateInteraction: return true
            default: return false
            }
        }

        var priority: Int {
            switch self {
            case .pauseChanged: return 100
            case .safeModeChanged: return 99
            case .characterSelected, .appInteraction, .widgetInteraction, .repeatInteraction,
                 .reminderCreated, .reminderCompleted, .reminderSnoozed: return 90
            case .reminderDue: return 85
            case .calendarUpcoming, .calendarChanged: return 80
            case .lateInteraction, .bedtimeReminder: return 60
            case .morningInteraction, .scheduledGreeting: return 55
            case .randomSlot: return 30
            case .easterEgg: return 20
            default: return 10
            }
        }
    }
    let id: UUID
    let source: Source
    let kind: Kind
    let date: Date
    var facts: Set<String> = []
    var newMode: CompanionMode? = nil
}

struct HeroActivity: Codable, Equatable {
    var mood: String
    var behavior = "idle"
    var energy = 70
    var affinity = 50
    var irritation = 0
    var curiosity = 50
    var updatedAt: Date
    var behaviorDates: [String: Date] = [:]
    var lineDates: [String: Date] = [:]
    var lastSource: CompanionEvent.Source?
    var lastEvent: UUID?
    var lastKind: CompanionEvent.Kind?
    var lastPriority: Int?
    var lastInteractionAt: Date?
    var substitutions: [String: String]?

    func recovered(at date: Date, baseline: String) -> Self {
        let seconds = date.timeIntervalSince(updatedAt)
        guard seconds >= 2 else { return self }
        var result = self
        result.behavior = "idle"
        if seconds >= 300 { result.mood = baseline }
        let steps = Int(min(100, seconds / 60))
        func toward(_ value: Int, _ target: Int) -> Int {
            value < target ? min(target, value + steps) : max(target, value - steps)
        }
        result.energy = toward(energy, 70)
        result.curiosity = toward(curiosity, 50)
        result.irritation = toward(irritation, 0)
        return result
    }
}

struct Companion: Codable, Equatable {
    var reminders: [LocalReminder] = []
    var calendarSnapshot = CalendarSnapshot()
    var personalNoticeJournal: PersonalNoticeJournal?
    var calendarNoticeJournal: CalendarNoticeJournal?
    var mode = CompanionMode.normal
    var daySchedule = DaySchedule()
    var animationsEnabled = true
    var randomEventsEnabled = true
    var complimentFrequency = ComplimentFrequency.regular
    var passivePhraseFrequency = PassivePhraseFrequency.regular
    var communicationIntensity = CommunicationIntensity.standard
    var complimentsOnlyInWidget = false

    func allowsCompliments(on channel: String) -> Bool {
        complimentFrequency != .off && (!complimentsOnlyInWidget || channel == "widget")
    }
    private var modeBeforePause: CompanionMode?
    var hero = Hero.gojo
    private var histories: [String: [String]] = [:]
    var recentDialogueIDs: [String] { histories[hero.rawValue] ?? [] }
    private var activities: [String: HeroActivity] = [:]
    private var events: [UUID: Date] = [:]
    // Keep a bounded arrival history across wall-clock jumps, independent of event dates.
    private var recentEventIDs: [UUID] = []
    private var contacts: [String: Contact] = [:]
    var contact: Contact? {
        get { contacts[hero.rawValue] }
        set { contacts[hero.rawValue] = newValue }
    }
    private var greetingDays: [String: Int] = [:]
    private(set) var unlocks: [Unlock] = []
    private static let historyLimit = 15

    init() {}

    mutating func resetPreferences() {
        let defaults = Companion()
        hero = defaults.hero
        mode = defaults.mode
        modeBeforePause = nil
        daySchedule = defaults.daySchedule
        animationsEnabled = defaults.animationsEnabled
        randomEventsEnabled = defaults.randomEventsEnabled
        complimentFrequency = defaults.complimentFrequency
        passivePhraseFrequency = defaults.passivePhraseFrequency
        communicationIntensity = defaults.communicationIntensity
        complimentsOnlyInWidget = defaults.complimentsOnlyInWidget
    }

    mutating func clearCollection() {
        unlocks.removeAll()
    }

    mutating func clearDialogueHistory() {
        histories.removeAll()
        for id in Array(activities.keys) {
            activities[id]?.lineDates.removeAll()
            activities[id]?.substitutions = nil
        }
        contacts = contacts.mapValues { Contact(hero: $0.hero, date: $0.date, response: "idle", portalOnRight: $0.portalOnRight) }
    }

    mutating func clearActivityHistory(at date: Date = Date()) {
        contacts.removeAll()
        greetingDays.removeAll()
        events.removeAll()
        recentEventIDs.removeAll()
        for hero in Hero.allCases {
            let lines = activities.removeValue(forKey: hero.rawValue)?.lineDates ?? [:]
            if !lines.isEmpty {
                activities[hero.rawValue] = HeroActivity(mood: hero.pack?.disposition.defaultMood ?? "neutral",
                                                         updatedAt: date, lineDates: lines)
            }
        }
    }

    // Old snapshots stored Gojo's first three phrases by position.
    private enum CodingKeys: String, CodingKey {
        case calendarSnapshot, mode, modeBeforePause, hero, histories, contacts, greetingDays, unlocks, reminders, activities, events
        case complimentFrequency, complimentsOnlyInWidget, daySchedule, animationsEnabled, randomEventsEnabled
        case personalNoticeJournal, calendarNoticeJournal
        case recentEventIDs
        case passivePhraseFrequency, communicationIntensity
    }
    private enum LegacyKeys: String, CodingKey { case line, contact }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        activities = try fields.decodeIfPresent([String: HeroActivity].self, forKey: .activities) ?? [:]
        events = try fields.decodeIfPresent([UUID: Date].self, forKey: .events) ?? [:]
        recentEventIDs = Array((try fields.decodeIfPresent([UUID].self, forKey: .recentEventIDs) ?? []).suffix(128))
        calendarSnapshot = try fields.decodeIfPresent(CalendarSnapshot.self, forKey: .calendarSnapshot) ?? CalendarSnapshot()
        personalNoticeJournal = try fields.decodeIfPresent(PersonalNoticeJournal.self, forKey: .personalNoticeJournal)
        calendarNoticeJournal = try fields.decodeIfPresent(CalendarNoticeJournal.self, forKey: .calendarNoticeJournal)
        mode = try fields.decode(CompanionMode.self, forKey: .mode)
        animationsEnabled = try fields.decodeIfPresent(Bool.self, forKey: .animationsEnabled) ?? true
        randomEventsEnabled = try fields.decodeIfPresent(Bool.self, forKey: .randomEventsEnabled) ?? true
        let schedule = try fields.decodeIfPresent(DaySchedule.self, forKey: .daySchedule)
        if let schedule, schedule.isValid { daySchedule = schedule }
        complimentFrequency = try fields.decodeIfPresent(ComplimentFrequency.self, forKey: .complimentFrequency) ?? .regular
        passivePhraseFrequency = try fields.decodeIfPresent(PassivePhraseFrequency.self, forKey: .passivePhraseFrequency) ?? .regular
        communicationIntensity = try fields.decodeIfPresent(CommunicationIntensity.self, forKey: .communicationIntensity) ?? .standard
        complimentsOnlyInWidget = try fields.decodeIfPresent(Bool.self, forKey: .complimentsOnlyInWidget) ?? false
        modeBeforePause = try fields.decodeIfPresent(CompanionMode.self, forKey: .modeBeforePause)
        reminders = try fields.decodeIfPresent([LocalReminder].self, forKey: .reminders) ?? []
        unlocks = try fields.decodeIfPresent([Unlock].self, forKey: .unlocks) ?? []
        contacts = try fields.decodeIfPresent([String: Contact].self, forKey: .contacts) ?? [:]
        let old = try decoder.container(keyedBy: LegacyKeys.self)
        if let last = try old.decodeIfPresent(Contact.self, forKey: .contact), contacts[last.hero.rawValue] == nil {
            contacts[last.hero.rawValue] = last
        }
        greetingDays = try fields.decodeIfPresent([String: Int].self, forKey: .greetingDays) ?? [:]
        if fields.contains(.hero) {
            hero = try fields.decode(Hero.self, forKey: .hero)
            histories = try fields.decode([String: [String]].self, forKey: .histories)
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let index = try legacy.decode(Int.self, forKey: .line)
            let id = (0..<3).contains(index) && hero.dialogue.indices.contains(index) ? hero.dialogue[index].id : hero.dialogue[0].id
            histories[hero.rawValue] = [id]
        }
    }

    var reaction: Reaction { reaction(using: hero.pack) }

    func reaction(using pack: CharacterPack?) -> Reaction {
        if let contact, contact.hero == hero {
            if let pack, let row = pack.byID[contact.response] {
                let line = row.reaction
                let action = row.behaviorID.flatMap { pack.behaviors[$0]?.label } ?? line.action
                let emotion = activities[hero.rawValue].map { pack.disposition.expression(for: $0.mood) } ?? line.emotion
                let text = row.rendered(row.text, using: activities[hero.rawValue]?.substitutions ?? [:]) ?? "Я здесь."
                return Reaction(row.id, text, action, emotion: emotion)
            }
            if contact.response == "idle" { return Reaction("idle", "Я здесь.", "Отдыхает") }
            switch contact.response {
            case "greeting": return hero.greeting
            case "rest": return Reaction("rest", "Уже поздно. Пора отдыхать.", "Зевает", emotion: .sleepy)
            case "quiet": return Reaction("quiet", "До утра. Пусть ночь будет спокойной.", "Прикрывает глаза", emotion: .sleepy)
            default: break
            }
        }
        guard let lines = pack?.interactive, !lines.isEmpty else { return Reaction("intro", "Я здесь.", "Отдыхает") }
        return lines.first { $0.id == histories[hero.rawValue]?.last } ?? lines[0]
    }

    func activity(at date: Date) -> HeroActivity {
        activity(at: date, using: hero.pack)
    }

    func activity(at date: Date, using pack: CharacterPack?) -> HeroActivity {
        let baseline = pack?.disposition.defaultMood ?? "neutral"
        return activities[hero.rawValue]?.recovered(at: date, baseline: baseline)
            ?? HeroActivity(mood: baseline, updatedAt: date)
    }

    private func greetingDay(at date: Date, calendar: Calendar) -> Int? {
        let period = daySchedule.period(at: date, calendar: calendar)
        guard period == .dawn || period == .morning else { return nil }
        var civilCalendar = Calendar(identifier: .gregorian)
        civilCalendar.timeZone = calendar.timeZone
        let parts = civilCalendar.dateComponents([.year, .month, .day], from: date)
        let day = (parts.year ?? 0) * 10000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
        return day > (greetingDays[hero.rawValue] ?? 0) ? day : nil
    }

    @discardableResult mutating func greetIfNeeded(at date: Date, calendar: Calendar) -> Bool {
        guard greetingDay(at: date, calendar: calendar) != nil else { return false }
        var rng = SystemRandomNumberGenerator()
        let event = CompanionEvent(id: UUID(), source: .app, kind: .appOpened, date: date)
        return handle([event], at: date, calendar: calendar, using: &rng)
    }

    @discardableResult mutating func appContact(_ kind: CompanionEvent.Kind, at date: Date, calendar: Calendar) -> Bool {
        let last = lastInteractionAt
        let first = last == nil
        guard first || kind == .characterSelected || greetingDay(at: date, calendar: calendar) != nil
                || last.map({ date.timeIntervalSince($0) >= 86400 }) == true else { return false }
        var rng = SystemRandomNumberGenerator()
        let event = CompanionEvent(id: UUID(), source: .app, kind: first && kind != .characterSelected ? .firstLaunch : kind, date: date)
        return handle([event], at: date, calendar: calendar, using: &rng)
    }

    private var lastInteractionAt: Date? {
        // Snapshots predating event tracking only recorded the last contact.
        guard let activity = activities[hero.rawValue] else { return contact?.date }
        return activity.lastInteractionAt
    }

    mutating func react(at date: Date = Date(), calendar: Calendar = .current, source: CompanionEvent.Source = .app) {
        var rng = SystemRandomNumberGenerator()
        let event = CompanionEvent(id: UUID(), source: source,
                                   kind: source == .widgetIntent ? .widgetInteraction : .appInteraction, date: date)
        _ = handle([event], at: date, calendar: calendar, using: &rng)
    }

    mutating func setMode(_ next: CompanionMode, at date: Date = Date()) {
        guard next != mode else { return }
        var rng = SystemRandomNumberGenerator()
        let event = CompanionEvent(id: UUID(), source: .app, kind: mode == .paused || next == .paused ? .pauseChanged : .safeModeChanged,
                                   date: date, newMode: next)
        _ = handle([event], at: date, calendar: .current, using: &rng)
    }

    mutating func resume(at date: Date = Date()) {
        guard mode == .paused else { return }
        setMode(modeBeforePause.flatMap { $0 == .paused ? nil : $0 } ?? .normal, at: date)
    }

    mutating func respond(to kind: CompanionEvent.Kind, at date: Date = Date(), source: CompanionEvent.Source = .app,
                          facts: Set<String> = []) {
        var rng = SystemRandomNumberGenerator()
        let event = CompanionEvent(id: UUID(), source: source, kind: kind, date: date, facts: facts)
        _ = handle([event], at: date, calendar: .current, using: &rng)
    }

    @discardableResult mutating func handle<R: RandomNumberGenerator>(_ incoming: [CompanionEvent], at now: Date,
                               calendar: Calendar, using rng: inout R) -> Bool {
        let active = mode == .normal || mode == .eco
        let valid = incoming.filter {
            let age = now.timeIntervalSince($0.date)
            let changesMode = $0.kind == .pauseChanged || $0.kind == .safeModeChanged
            if changesMode && $0.newMode == nil { return false }
            let random = $0.kind == .randomSlot || $0.kind == .easterEgg
            if $0.kind.isContact && ![.app, .widgetIntent, .simulatedTest].contains($0.source) { return false }
            if $0.kind == .morningInteraction {
                guard greetingDay(at: $0.date, calendar: calendar) != nil else { return false }
            }
            if $0.kind == .lateInteraction {
                let period = daySchedule.period(at: $0.date, calendar: calendar)
                guard period == .night || period == .lateNight else { return false }
            }
            return (active || changesMode) && (!random || randomEventsEnabled) && age >= 0 && age < 300 &&
                events[$0.id] == nil && !recentEventIDs.contains($0.id)
        }
        guard let event = valid.sorted(by: {
            if $0.kind.priority != $1.kind.priority { return $0.kind.priority > $1.kind.priority }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }).first else { return false }
        events = events.filter { (0..<300).contains(now.timeIntervalSince($0.value)) }
        for candidate in valid where events[candidate.id] == nil {
            events[candidate.id] = candidate.date
            recentEventIDs.append(candidate.id)
        }
        if recentEventIDs.count > 128 { recentEventIDs.removeFirst(recentEventIDs.count - 128) }
        // A wall-clock adjustment must never prevent the user from pausing decoration.
        if event.kind == .pauseChanged || event.kind == .safeModeChanged {
            if let next = event.newMode, next != mode {
                modeBeforePause = next == .paused ? mode : nil
                mode = next
            }
            return false
        }
        if let previous = activities[hero.rawValue], let priority = previous.lastPriority, let last = contact,
           now >= last.date, now.timeIntervalSince(last.date) < 2 && priority > event.kind.priority { return false }
        if let last = contact, last.date <= now && event.date < last.date { return false }
        let pack = hero.pack
        var state = activity(at: event.date)
        state.lastInteractionAt = lastInteractionAt
        let period = daySchedule.period(at: event.date, calendar: calendar)
        let tap = event.kind == .appInteraction || event.kind == .widgetInteraction || event.kind == .repeatInteraction
        let actualContact = event.kind.isContact
        let morning = actualContact ? greetingDay(at: event.date, calendar: calendar) : nil
        var trigger = event.kind == .repeatInteraction
            ? (event.source == .widgetIntent ? "widgetInteraction" : "appInteraction") : event.kind.rawValue
        if morning != nil { trigger = "morningInteraction" }
        else if actualContact && (period == .night || period == .lateNight) { trigger = "lateInteraction" }
        else if tap, let previous = state.lastInteractionAt, event.date >= previous, event.date.timeIntervalSince(previous) < 2 {
            trigger = "repeatInteraction"
        } else if actualContact, let previous = state.lastInteractionAt, event.date.timeIntervalSince(previous) >= 86400 {
            trigger = "inactivityElapsed"
        } else if tap && randomEventsEnabled && mode == .normal && Int.random(in: 0..<12, using: &rng) == 0,
                availableFind(at: event.date) != nil { trigger = "easterEgg" }
        let channel = event.source == .widgetIntent ? "widget" : "app"
        let includeCompliments = allowsCompliments(on: channel) &&
            (complimentFrequency != .reduced || Int.random(in: 0..<3, using: &rng) == 0)
        var facts = event.facts
        facts.insert(trigger)
        let nextSide = !(contact?.portalOnRight ?? false)
        let substitutions = ["pendingTasks": String(reminders.filter { $0.completedAt == nil }.count),
                             "completedTasks": String(reminders.filter { $0.completedAt != nil }.count)]
        // A new explicit contact can interrupt a previously shown one-shot action.
        if actualContact { state.behavior = "idle" }
        func candidates(_ trigger: String) -> [CharacterPack.Record] {
            guard let pack else { return [] }
            return (pack.byTrigger[trigger] ?? []).filter { row in
                guard (row.category != "compliment" || includeCompliments), communicationIntensity.permits(row, channel: channel),
                      row.eligible(trigger: trigger, channel: channel, facts: facts, mood: state.mood,
                                   intensity: pack.personality.intensity, period: period, substitutions: substitutions),
                      let id = row.behaviorID, let action = pack.behaviors[id],
                      action.permits(state: state.behavior, trigger: trigger, channel: channel, facts: facts,
                                     date: event.date, lastUsed: state.behaviorDates[id]) else { return false }
                if trigger == "easterEgg" { return row.id == availableFind(at: event.date)?.lineID }
                return true
            }
        }
        var choices = candidates(trigger)
        let repeated = trigger == "repeatInteraction"
        if choices.isEmpty && repeated {
            trigger = channel == "widget" ? "widgetInteraction" : "appInteraction"
            choices = candidates(trigger)
        }
        let recent = histories[hero.rawValue] ?? [reaction.id]
        if let priority = choices.compactMap({ pack?.behaviors[$0.behaviorID ?? ""]?.priority ?? 0 }).max() {
            choices = choices.filter { (pack?.behaviors[$0.behaviorID ?? ""]?.priority ?? 0) == priority }
        }
        let cooled = choices.filter { row in
            state.lineDates[row.id].map { max(0, event.date.timeIntervalSince($0)) >= Double(row.cooldownSeconds ?? 0) } ?? true
        }
        if !cooled.isEmpty { choices = cooled }
        let unused = choices.filter { !recent.contains($0.id) }
        if !unused.isEmpty { choices = unused }
        else if let oldest = recent.first(where: { id in choices.contains { $0.id == id } }) {
            choices = choices.filter { $0.id == oldest }
        }
        func weight(_ row: CharacterPack.Record) -> Int {
            min(1_000_000, row.weight) * min(1_000_000, pack?.behaviors[row.behaviorID ?? ""]?.weight ?? 1)
        }
        let total = choices.reduce(0) { $0 + weight($1) }
        var ticket = total > 0 ? Int.random(in: 0..<total, using: &rng) : 0
        let selected = choices.first { ticket -= weight($0); return ticket < 0 }
        if selected == nil && event.kind == .calendarChanged { return false }
        let response: String
        if let row = selected, let id = row.behaviorID, let action = pack?.behaviors[id] {
            response = row.id
            state.behavior = action.to
            state.behaviorDates[id] = event.date
            state.lineDates[row.id] = event.date
            histories[hero.rawValue] = Array((recent.filter { $0 != row.id } + [row.id]).suffix(Self.historyLimit))
            if trigger == "easterEgg", let find = availableFind(at: event.date) {
                unlocks.append(Unlock(id: find.id, date: event.date, assetID: find.assetID))
            }
            switch row.category {
            case "night": state.mood = "sleepy"
            case "morning", "compliment": state.mood = "happy"
            case "rare": state.mood = "surprised"
            default: state.mood = pack?.disposition.defaultMood ?? "neutral"
            }
            if actualContact {
                if repeated { state.irritation = min(20, state.irritation + 1) }
                state.affinity = min(100, state.affinity + 1)
                state.energy = max(0, state.energy - 1)
                state.curiosity = min(100, state.curiosity + (state.mood == "curious" ? 2 : 1))
            }
        } else {
            response = morning != nil ? "greeting" : (trigger == "lateInteraction" ? "rest" : "idle")
            state.behavior = "idle"
            state.mood = pack?.disposition.recovery ?? "neutral"
        }
        if let morning { greetingDays[hero.rawValue] = morning }
        state.updatedAt = max(state.updatedAt, event.date)
        state.lastEvent = event.id
        state.lastKind = repeated ? .repeatInteraction : (CompanionEvent.Kind(rawValue: trigger) ?? event.kind)
        state.lastSource = event.source
        state.lastPriority = event.kind.priority
        state.substitutions = selected?.variables.flatMap { names in
            names.isEmpty ? nil : substitutions.filter { names.contains($0.key) }
        }
        if actualContact { state.lastInteractionAt = event.date }
        activities[hero.rawValue] = state
        contact = Contact(hero: hero, date: event.date, response: response)
        if tap, hero == .maomao || hero == .jinwoo { contact?.portalOnRight = nextSide }
        return true
    }

    private func availableFind(at date: Date) -> Find? {
        guard randomEventsEnabled, mode == .normal, let pack = hero.pack else { return nil }
        if let last = unlocks.last, date.timeIntervalSince(last.date) < 21600 { return nil }
        return pack.finds.first { find in
            !unlocks.contains { $0.id == find.id } &&
            pack.byID[find.lineID].map { communicationIntensity.permits($0, channel: "app") } == true
        }
    }

    mutating func discover(at date: Date) -> Bool {
        guard availableFind(at: date) != nil else { return false }
        let event = CompanionEvent(id: UUID(), source: .app, kind: .easterEgg, date: date)
        var rng = SystemRandomNumberGenerator()
        let before = unlocks.count
        _ = handle([event], at: date, calendar: .current, using: &rng)
        return unlocks.count > before
    }

}
