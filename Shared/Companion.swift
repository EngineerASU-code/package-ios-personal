import Foundation

enum CompanionMode: String, Codable, CaseIterable {
    case normal = "Обычный", eco = "Экономный", safe = "Безопасный", paused = "Пауза"
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
}

struct Unlock: Codable, Equatable {
    let id: String
    let date: Date
}

final class CharacterPack {
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
        let id, label, from, to: String
        let triggers, channels, requires: [String]?
        let priority, weight, cooldownSeconds: Int?

        func permits(state: String, trigger: String, channel: String, facts: Set<String>,
                     date: Date, lastUsed: Date?) -> Bool {
            from == state && ["talking", "resting", "sleeping", "greeting", "working", "training",
                              "exploring", "celebrating", "annoyed", "specialAction", "idle"].contains(to)
                && (triggers?.contains(trigger) ?? true) && (channels?.contains(channel) ?? true)
                && facts.isSuperset(of: requires ?? []) && (weight ?? 1) > 0
                && (lastUsed.map { date.timeIntervalSince($0) >= Double(max(0, cooldownSeconds ?? 0)) } ?? true)
        }
    }
    struct Personality: Decodable { let intensity: String }
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
                                 mood: String? = nil, intensity: String = "gentle", period: DayPeriod? = nil) -> Record? {
        let candidates = rows.filter {
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

    private init?(hero: Hero, directory: URL) {
        func decode<T: Decodable>(_ file: String) -> T? {
            let url = directory.appendingPathComponent(file)
            guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  (1...1_000_000).contains(size),
                  let data = try? Data(contentsOf: url), data.count == size else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        guard let manifest: Manifest = decode("manifest.json"), manifest.schemaVersion == 1, manifest.id == hero.rawValue,
              let palette: Theme = decode("theme.json"), let rows: [Record] = decode("dialogue.ru.json"), let eggs: [Find] = decode("easter_eggs.json"),
              Set(rows.map(\.id)).count == rows.count, rows.first?.id == "intro" else { return nil }
        guard let profile: Personality = decode("personality.json"), let moods: Disposition = decode("emotions.json"),
              let actions: [Behavior] = decode("behaviors.json"),
              Set(actions.map(\.id)).count == actions.count else { return nil }
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
    var id = UUID()
    var title = ""
    var createdAt = Date()
    var dueAt: Date?
    var recurrence = TaskRecurrence.once
    var seriesAnchor: Date?
    var snoozedUntil: Date?
    var completedAt: Date?
    var notificationEnabled = false
    var revision = 0
    var updatedAt = Date()
    var target: Date? { snoozedUntil ?? dueAt }

    mutating func complete(at now: Date, calendar: Calendar = .current) {
        guard completedAt == nil else { return }
        snoozedUntil = nil
        if let current = dueAt, recurrence != .once {
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
    var mode = CompanionMode.normal
    private var modeBeforePause: CompanionMode?
    var hero = Hero.gojo
    private var histories: [String: [String]] = [:]
    private var activities: [String: HeroActivity] = [:]
    private var events: [UUID: Date] = [:]
    private var contacts: [String: Contact] = [:]
    var contact: Contact? {
        get { contacts[hero.rawValue] }
        set { contacts[hero.rawValue] = newValue }
    }
    private var greetingDays: [String: Int] = [:]
    private(set) var unlocks: [Unlock] = []
    private static let historyLimit = 15

    init() {}

    // Old snapshots stored Gojo's first three phrases by position.
    private enum CodingKeys: String, CodingKey { case calendarSnapshot, mode, modeBeforePause, hero, histories, contacts, greetingDays, unlocks, reminders, activities, events }
    private enum LegacyKeys: String, CodingKey { case line, contact }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        activities = try fields.decodeIfPresent([String: HeroActivity].self, forKey: .activities) ?? [:]
        events = try fields.decodeIfPresent([UUID: Date].self, forKey: .events) ?? [:]
        calendarSnapshot = try fields.decodeIfPresent(CalendarSnapshot.self, forKey: .calendarSnapshot) ?? CalendarSnapshot()
        mode = try fields.decode(CompanionMode.self, forKey: .mode)
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

    var reaction: Reaction {
        if let contact, contact.hero == hero {
            if let pack = hero.pack, let row = pack.byID[contact.response] {
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
        let lines = hero.dialogue
        return lines.first { $0.id == histories[hero.rawValue]?.last } ?? lines[0]
    }

    func activity(at date: Date) -> HeroActivity {
        let baseline = hero.pack?.disposition.defaultMood ?? "neutral"
        return activities[hero.rawValue]?.recovered(at: date, baseline: baseline)
            ?? HeroActivity(mood: baseline, updatedAt: date)
    }

    private func greetingDay(at date: Date, calendar: Calendar) -> Int? {
        let period = DayPeriod(hour: calendar.component(.hour, from: date))
        guard period == .dawn || period == .morning else { return nil }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
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
        let last = activities[hero.rawValue]?.lastInteractionAt ?? contact?.date
        let first = last == nil
        guard first || kind == .characterSelected || greetingDay(at: date, calendar: calendar) != nil
                || last.map({ date.timeIntervalSince($0) >= 86400 }) == true else { return false }
        var rng = SystemRandomNumberGenerator()
        let event = CompanionEvent(id: UUID(), source: .app, kind: first && kind != .characterSelected ? .firstLaunch : kind, date: date)
        return handle([event], at: date, calendar: calendar, using: &rng)
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

    mutating func respond(to kind: CompanionEvent.Kind, at date: Date = Date(), source: CompanionEvent.Source = .app) {
        var rng = SystemRandomNumberGenerator()
        let event = CompanionEvent(id: UUID(), source: source, kind: kind, date: date)
        _ = handle([event], at: date, calendar: .current, using: &rng)
    }

    @discardableResult mutating func handle<R: RandomNumberGenerator>(_ incoming: [CompanionEvent], at now: Date,
                               calendar: Calendar, using rng: inout R) -> Bool {
        let active = mode == .normal || mode == .eco
        let valid = incoming.filter {
            let age = now.timeIntervalSince($0.date)
            let changesMode = ($0.kind == .pauseChanged || $0.kind == .safeModeChanged) && $0.newMode != nil
            return (active || changesMode) && age >= 0 && age < 300 && events[$0.id] == nil
        }
        guard let event = valid.sorted(by: {
            if $0.kind.priority != $1.kind.priority { return $0.kind.priority > $1.kind.priority }
            if $0.date != $1.date { return $0.date > $1.date }
            return $0.id.uuidString < $1.id.uuidString
        }).first else { return false }
        events = events.filter { now.timeIntervalSince($0.value) < 300 }
        for candidate in valid { events[candidate.id] = candidate.date }
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
        if let last = contact, event.date < last.date && event.date < now { return false }
        let pack = hero.pack
        var state = activity(at: event.date)
        let period = DayPeriod(hour: calendar.component(.hour, from: event.date))
        let tap = event.kind == .appInteraction || event.kind == .widgetInteraction || event.kind == .repeatInteraction
        let actualContact = tap || [.firstLaunch, .appOpened, .foregrounded, .characterSelected, .morningInteraction].contains(event.kind)
        let morning = actualContact ? greetingDay(at: event.date, calendar: calendar) : nil
        var trigger = event.kind.rawValue
        if morning != nil { trigger = "morningInteraction" }
        else if tap && (period == .night || period == .lateNight) { trigger = "lateInteraction" }
        else if tap, let previous = contact, event.date >= previous.date, event.date.timeIntervalSince(previous.date) < 2 {
            trigger = "repeatInteraction"
        } else if actualContact, let previous = state.lastInteractionAt ?? contact?.date, event.date.timeIntervalSince(previous) >= 86400 {
            trigger = "inactivityElapsed"
        } else if tap && mode == .normal && Int.random(in: 0..<12, using: &rng) == 0,
                availableFind(at: event.date) != nil { trigger = "easterEgg" }
        let channel = event.source == .widgetIntent ? "widget" : "app"
        var facts = event.facts
        facts.insert(trigger)
        let nextSide = !(contact?.portalOnRight ?? false)
        let substitutions = ["pendingTasks": String(reminders.filter { $0.completedAt == nil }.count),
                             "completedTasks": String(reminders.filter { $0.completedAt != nil }.count)]
        // A new explicit contact can interrupt a previously shown one-shot action.
        if actualContact { state.behavior = "idle" }
        func candidates(_ trigger: String) -> [CharacterPack.Record] {
            guard let pack else { return [] }
            return pack.records.filter { row in
                guard row.eligible(trigger: trigger, channel: channel, facts: facts, mood: state.mood,
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
            state.lineDates[row.id].map { event.date.timeIntervalSince($0) >= Double(row.cooldownSeconds ?? 0) } ?? true
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
                unlocks.append(Unlock(id: find.id, date: event.date))
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
        if actualContact { state.lastInteractionAt = max(state.lastInteractionAt ?? event.date, event.date) }
        activities[hero.rawValue] = state
        contact = Contact(hero: hero, date: event.date, response: response)
        if tap, hero == .maomao || hero == .jinwoo { contact?.portalOnRight = nextSide }
        return true
    }

    private func availableFind(at date: Date) -> Find? {
        guard mode == .normal, let pack = hero.pack else { return nil }
        if let last = unlocks.last, date.timeIntervalSince(last.date) < 21600 { return nil }
        return pack.finds.first { find in !unlocks.contains { $0.id == find.id } }
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
