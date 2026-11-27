import Foundation

struct CalendarNoticeJournal: Codable, Equatable {
    var reservations: [String: Date] = [:]
    var desired: [String: Date] = [:]
    var applied: [String: Date] = [:]
}

struct CalendarItem: Codable, Identifiable, Equatable {
    let id: String
    let start: Date
    let end: Date
    let allDay: Bool
    var title: String?
    var seriesKey: String? = nil

    var label: String { title ?? "Событие" }
    var timeLabel: String {
        allDay ? "Весь день" : start.formatted(date: .omitted, time: .shortened)
    }
}

extension Companion {
    mutating func replaceCalendarSnapshot(_ next: CalendarSnapshot, at date: Date) {
        // Changing title visibility or refreshing the expiry is not a schedule change.
        let previous = calendarSnapshot
        calendarSnapshot = next
        guard next.updatedAt != nil else { return }
        let sameEvents = previous.events.elementsEqual(next.events) { old, new in
            old.id == new.id && old.start == new.start && old.end == new.end && old.allDay == new.allDay &&
                (old.title == nil || new.title == nil || old.title == new.title)
        }
        if !sameEvents || previous.overflow != next.overflow {
            let facts = next.changeFacts(since: previous, at: date)
            respond(to: .calendarChanged, at: date, source: .calendarSnapshot, facts: facts)
        }
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
    var cancelledOccurrenceIDs: Set<String>? = nil

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

    // Persist before submission so interruption cannot lead to a second alert for the day.
    @MainActor static func registerWarning(_ key: String, at date: Date, ledger: inout [String: Date],
                                           save: ([String: Date]) throws -> Void, add: () async throws -> Void) async throws {
        ledger[key] = date
        try save(ledger)
        do {
            try await add()
        } catch {
            ledger.removeValue(forKey: key)
            try save(ledger)
            throw error
        }
    }

    func isFresh(at date: Date) -> Bool {
        guard let updatedAt, let expiry else { return false }
        return updatedAt <= date && date < expiry
    }

    func upcoming(at date: Date) -> [CalendarItem] {
        isFresh(at: date) ? events.filter { $0.end > date || $0.start >= date } : []
    }

    func dayFact(at date: Date, calendar: Calendar) -> String? {
        guard isFresh(at: date), let endOfDay = calendar.dateInterval(of: .day, for: date)?.end else { return nil }
        let remaining = upcoming(at: date).filter { $0.start < endOfDay }
        if remaining.count >= 3 { return "calendarBusyDay" }
        return remaining.isEmpty && !overflow ? "calendarClearDay" : nil
    }

    fileprivate func changeFacts(since previous: Self, at date: Date) -> Set<String> {
        guard isFresh(at: date), previous.isFresh(at: date) else { return [] }
        let before = previous.upcoming(at: date)
        let after = upcoming(at: date)
        if let cancelledOccurrenceIDs, before.contains(where: { cancelledOccurrenceIDs.contains($0.id) }) {
            return ["calendarCancelled"]
        }
        guard !previous.overflow, !overflow else { return [] }
        for old in before {
            if after.contains(where: { new in
                (new.id == old.id || (old.seriesKey != nil && old.seriesKey == new.seriesKey)) &&
                    (new.start != old.start || new.end != old.end)
            }) { return ["calendarMoved"] }
        }
        let ids = Set(after.map(\.id))
        return before.contains { !ids.contains($0.id) } ? ["calendarRemoved"] : []
    }
}
