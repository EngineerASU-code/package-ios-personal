import Foundation

struct CalendarItem: Codable, Identifiable, Equatable {
    let id: String
    let start: Date
    let end: Date
    let allDay: Bool
    let title: String?

    var label: String { title ?? "Событие" }
    var timeLabel: String {
        allDay ? "Весь день" : start.formatted(date: .omitted, time: .shortened)
    }
}

struct CalendarSnapshot: Codable, Equatable {
    var updatedAt: Date?
    var expiry: Date?
    var events: [CalendarItem] = []
    var overflow = false

    func isFresh(at date: Date) -> Bool {
        guard let updatedAt, let expiry else { return false }
        return updatedAt <= date && date < expiry
    }

    func upcoming(at date: Date) -> [CalendarItem] {
        isFresh(at: date) ? events.filter { $0.end > date || $0.start >= date } : []
    }
}
