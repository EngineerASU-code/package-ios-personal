import Foundation

enum CompanionMode: String, Codable, CaseIterable {
    case normal = "Обычный", eco = "Экономный", safe = "Безопасный", paused = "Пауза"
}

enum ChibiEmotion: String { case neutral, happy, sleepy, surprised }

struct Reaction {
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
    let theme: Theme
    struct Record: Decodable {
        let id, text, category, action: String
        let triggers, channels, requires: [String]
        let weight: Int
        let shortText: String?
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
    static func notificationLine(in rows: [Record], trigger: String, facts: Set<String>, slot: UInt64) -> Record? {
        let candidates = rows.filter {
            $0.weight > 0 && $0.channels.contains("notification") &&
                $0.triggers.contains(trigger) && facts.isSuperset(of: $0.requires)
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
        let taps = rows.filter { ["tap", "compliment", "support"].contains($0.category) }.map(\.reaction)
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

struct Companion: Codable, Equatable {
    var reminders: [LocalReminder] = []
    var calendarSnapshot = CalendarSnapshot()
    var mode = CompanionMode.normal
    var hero = Hero.gojo
    private var histories: [String: [String]] = [:]
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
    private enum CodingKeys: String, CodingKey { case calendarSnapshot, mode, hero, histories, contacts, greetingDays, unlocks, reminders }
    private enum LegacyKeys: String, CodingKey { case line, contact }
    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        calendarSnapshot = try fields.decodeIfPresent(CalendarSnapshot.self, forKey: .calendarSnapshot) ?? CalendarSnapshot()
        mode = try fields.decode(CompanionMode.self, forKey: .mode)
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
            if let row = hero.pack?.byID[contact.response] { return row.reaction }
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

    @discardableResult mutating func greetIfNeeded(at date: Date, calendar: Calendar) -> Bool {
        guard mode == .normal || mode == .eco else { return false }
        let period = DayPeriod(hour: calendar.component(.hour, from: date))
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let day = (parts.year ?? 0) * 10000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
        if (period == .dawn || period == .morning), day > (greetingDays[hero.rawValue] ?? 0) {
            greetingDays[hero.rawValue] = day
            let greetings = hero.pack?.records.filter { $0.category == "morning" } ?? []
            let id = greetings.isEmpty ? "greeting" : greetings[day % greetings.count].id
            contact = Contact(hero: hero, date: date, response: id)
            return true
        }
        return false
    }

    mutating func react(at date: Date = Date(), calendar: Calendar = .current) {
        guard mode == .normal || mode == .eco else { return }
        let nextSide = !(contact?.portalOnRight ?? false)
        defer {
            if hero == .jinwoo || hero == .maomao { contact?.portalOnRight = nextSide }
        }
        if greetIfNeeded(at: date, calendar: calendar) { return }
        let period = DayPeriod(hour: calendar.component(.hour, from: date))
        if period == .night || period == .lateNight {
            let previous = reaction.id
            let night = hero.pack?.records.filter { $0.category == "night" && $0.id != previous }.randomElement()
            contact = Contact(hero: hero, date: date, response: night?.id ?? (previous == "rest" ? "quiet" : "rest"))
            return
        }
        if mode == .normal, Int.random(in: 0..<12) == 0, discover(at: date) { return }
        var rng = SystemRandomNumberGenerator()
        react(using: &rng)
        contact = Contact(hero: hero, date: date, response: reaction.id)
    }

    mutating func discover(at date: Date) -> Bool {
        guard mode == .normal,
              unlocks.last.map({ date.timeIntervalSince($0.date) >= 6 * 3600 }) ?? true,
              let pack = hero.pack,
              let find = pack.finds.first(where: { find in !unlocks.contains(where: { $0.id == find.id }) }),
              let row = pack.byID[find.lineID] else { return false }
        unlocks.append(Unlock(id: find.id, date: date))
        contact = Contact(hero: hero, date: date, response: row.id)
        return true
    }

    mutating func react<R: RandomNumberGenerator>(using rng: inout R) {
        guard mode == .normal || mode == .eco else { return }
        contact = nil
        var recent = histories[hero.rawValue] ?? [reaction.id]
        let lines = hero.dialogue
        var candidates = lines.filter { !recent.contains($0.id) }
        if candidates.isEmpty {
            // All lines were used. Release the least recently selected one first.
            for id in recent {
                if let oldest = lines.first(where: { $0.id == id }) {
                    candidates = [oldest]
                    break
                }
            }
        }
        guard let next = candidates.randomElement(using: &rng) else { return }
        recent.removeAll { $0 == next.id }
        recent.append(next.id)
        histories[hero.rawValue] = Array(recent.suffix(Self.historyLimit))
    }
}
