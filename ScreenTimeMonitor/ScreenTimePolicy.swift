import DeviceActivity
import Foundation
import UserNotifications

enum ScreenTimePolicy {
    static let activity = DeviceActivityName("companion.screen-time.daily")
    static let notificationID = "companion.screen-time.daily"
    static let nightNotificationID = "companion.screen-time.night"
    static let minutesRange = 5...180

    struct Rule: Codable, Equatable {
        let eventID: String
        let minutes: Int
    }

    struct NightEvent: Codable, Equatable {
        let id: String
        let date: Date
    }

    struct Delivery: Codable, Equatable {
        let enabled: Bool
        let paused: Bool
        let quietStart: Int
        let quietEnd: Int
        let heroID: String
        let nightStart: Int
        let dawn: Int
        let nightNotifications: Bool

        func isNight(_ date: Date, calendar: Calendar = .current) -> Bool {
            let hour = calendar.component(.hour, from: date)
            return hour >= nightStart || hour < dawn
        }

        func permits(_ date: Date, calendar: Calendar = .current) -> Bool {
            guard enabled, !paused else { return false }
            if isNight(date, calendar: calendar) { return nightNotifications }
            let hour = calendar.component(.hour, from: date)
            return switch (quietStart, quietEnd) {
            case let (start, end) where start < end: !(start..<end).contains(hour)
            case let (start, end) where start > end: hour < start && hour >= end
            default: true
            }
        }
    }

    private static func file(_ name: String) throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.local.mycompanion"
        ) else { throw CocoaError(.fileNoSuchFile) }
        return container.appendingPathComponent("screen-time-" + name + ".json")
    }

    private static func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let url = try? file(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to name: String) throws {
        try JSONEncoder().encode(value).write(to: file(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static var rule: Rule? { read(Rule.self, from: "rule") }
    static var delivery: Delivery? { read(Delivery.self, from: "delivery") }

    static func setRule(_ rule: Rule) throws {
        try write(rule, to: "rule")
    }

    static func clearRule() {
        for name in ["rule", "delivery", "night-event"] {
            if let url = try? file(name) { try? FileManager.default.removeItem(at: url) }
        }
        cancelNotification()
    }

    static func setDelivery(_ policy: Delivery) throws {
        let previous = delivery
        guard previous != policy else { return }
        try write(policy, to: "delivery")
        if !policy.enabled || policy.paused { cancelNotification() }
        else if previous?.nightNotifications == true && !policy.nightNotifications {
            cancelNotification(ids: [nightNotificationID])
        }
    }

    static func clearDelivery() {
        if let url = try? file("delivery") { try? FileManager.default.removeItem(at: url) }
        cancelNotification()
    }

    static func cancelNotification(ids: [String] = [notificationID, nightNotificationID]) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ids)
        center.removeDeliveredNotifications(withIdentifiers: ids)
    }

    static func nightEvent(at date: Date = Date()) -> NightEvent? {
        guard let rule, delivery?.paused == false,
              let event = read(NightEvent.self, from: "night-event"), rule.eventID == event.id,
              date >= event.date, date.timeIntervalSince(event.date) < 20 * 60 else { return nil }
        return event
    }

    static func recordNightEvent(eventID: String, at date: Date, calendar: Calendar = .current) throws -> Bool {
        guard rule?.eventID == eventID, delivery?.paused == false else { return false }
        if let previous = read(NightEvent.self, from: "night-event"),
           previous.date > date || calendar.isDate(previous.date, inSameDayAs: date) { return false }
        try write(NightEvent(id: eventID, date: date), to: "night-event")
        return true
    }

    static func nightLine(heroID: String) -> String {
        switch heroID {
        case "satoru_gojo": "На сегодня хватит, чемпион. Пора спать."
        case "toji_fushiguro": "Хватит на сегодня. Иди спать."
        case "jinshi": "Уже поздно. Позвольте себе отдохнуть."
        case "sung_jinwoo": "На сегодня всё. Отдых. Продолжишь завтра."
        case "ryomen_sukuna": "На сегодня достаточно. Пора спать."
        case "maomao": "Моя рекомендация на сегодня: сон. Пора отдыхать."
        default: "Уже поздно. Пора спать."
        }
    }
}
