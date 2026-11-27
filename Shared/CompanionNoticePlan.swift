import Foundation

struct CompanionNoticeSlot: Equatable {
    let id, category, body: String
    let date: Date

    static func owns(_ id: String) -> Bool {
        id.hasPrefix("companion.greeting.") || id.hasPrefix("companion.bedtime.")
    }
}

struct CompanionNoticePlan {
    var morning: Int? // Minutes since local midnight; nil means opted out.
    var bedtime: Int?
    var quietStart: Int
    var quietEnd: Int

    func slots(hero: Hero, now: Date, calendar: Calendar) -> [CompanionNoticeSlot] {
        guard let pack = hero.pack else { return [] }
        var slots: [CompanionNoticeSlot] = []
        let today = calendar.startOfDay(for: now)
        for offset in 0..<3 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            for (isMorning, time) in [(true, morning), (false, bedtime)] {
                guard let time, (0..<1440).contains(time) else { continue }
                let hour = time / 60
                let inQuiet = quietStart < quietEnd ? (quietStart..<quietEnd).contains(hour)
                    : quietStart != quietEnd && (hour >= quietStart || hour < quietEnd)
                guard !inQuiet, let date = calendar.date(bySettingHour: hour, minute: time % 60,
                    second: 0, of: day, matchingPolicy: .strict, repeatedTimePolicy: .first, direction: .forward),
                    calendar.isDate(date, inSameDayAs: day), date > now else { continue }
                let nightOffset = !isMorning && hour < 5 ? -1 : 0
                guard let keyDay = calendar.date(byAdding: .day, value: nightOffset, to: day) else { continue }
                let parts = calendar.dateComponents([.year, .month, .day], from: keyDay)
                let key = String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
                let category = isMorning ? "greeting" : "bedtime"
                let id = "companion.\(category).\(key)"
                let seed = (id + hero.rawValue).utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
                let trigger = isMorning ? "scheduledGreeting" : "bedtimeReminder"
                guard let line = CharacterPack.notificationLine(in: pack.records, trigger: trigger, facts: [], slot: seed) else { continue }
                slots.append(CompanionNoticeSlot(id: id, category: "companion.\(category)",
                                                 body: line.shortText ?? line.text, date: date))
            }
        }
        return slots.sorted { $0.date < $1.date }
    }
}
