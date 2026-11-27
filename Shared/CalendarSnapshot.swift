import Foundation

struct CalendarItem: Codable, Identifiable, Equatable {
    let id: String
    let start: Date
    let end: Date
    let allDay: Bool
    var title: String?

    var label: String { title ?? "Событие" }
    var timeLabel: String {
        allDay ? "Весь день" : start.formatted(date: .omitted, time: .shortened)
    }
}

enum CalendarPrivacy: String {
    case off, privateTitles, titles

    #if os(iOS)
    static var groupDefaults: UserDefaults? {
        let group = "group.local.mycompanion"
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) != nil else { return nil }
        return UserDefaults(suiteName: group)
    }

    static var current: Self {
        groupDefaults?.string(forKey: "calendarWidgetPrivacy").flatMap(Self.init(rawValue:)) ?? .off
    }

    @discardableResult static func publish(_ value: Self) -> Bool {
        guard let defaults = groupDefaults, defaults.string(forKey: "calendarWidgetPrivacy") != value.rawValue else { return false }
        defaults.set(value.rawValue, forKey: "calendarWidgetPrivacy")
        return true
    }
    #endif
}

struct CalendarSnapshot: Codable, Equatable {
    var updatedAt: Date?
    var expiry: Date?
    var events: [CalendarItem] = []
    var overflow = false

    func filtered(by privacy: CalendarPrivacy) -> Self {
        switch privacy {
        case .off: return Self()
        case .titles: return self
        case .privateTitles:
            var copy = self
            for index in copy.events.indices { copy.events[index].title = nil }
            return copy
        }
    }

    func warningDates(now: Date, offset: Int, quietStart: Int, quietEnd: Int,
                      calendar: Calendar, reservations: [String: Date]) -> [String: Date] {
        guard [5, 15, 30, 60].contains(offset), let expiry else { return [:] }
        let elapsed = reservations.filter { $0.value <= now }
        var days = Set(elapsed.values.map { calendar.startOfDay(for: $0) })
        var requests: [String: Date] = [:]
        for item in upcoming(at: now) where !item.allDay && elapsed[item.id] == nil {
            let fire = item.start.addingTimeInterval(Double(-offset * 60))
            let hour = calendar.component(.hour, from: fire)
            let quiet = quietStart < quietEnd ? (quietStart..<quietEnd).contains(hour)
                : quietStart != quietEnd && (hour >= quietStart || hour < quietEnd)
            guard fire > now, fire < expiry, !quiet,
                  days.insert(calendar.startOfDay(for: fire)).inserted else { continue }
            requests[item.id] = fire
            if requests.count == 5 { break }
        }
        return requests
    }

    func isFresh(at date: Date) -> Bool {
        guard let updatedAt, let expiry else { return false }
        return updatedAt <= date && date < expiry
    }

    func upcoming(at date: Date) -> [CalendarItem] {
        isFresh(at: date) ? events.filter { $0.end > date || $0.start >= date } : []
    }
}
