import Foundation

struct CompanionNoticeSlot: Equatable {
    let id, category, body: String
    let date: Date

    static func owns(_ id: String) -> Bool {
        id.hasPrefix("companion.greeting.") || id.hasPrefix("companion.bedtime.")
    }
}

struct CompanionNoticeLedger: Codable {
    struct Entry: Codable {
        let date: Date
        let localDay: Int
        var spent: Bool
    }
    var entries: [String: Entry] = [:]
    var latestCheck = Date.distantPast

    static func day(_ date: Date, calendar: Calendar) -> Int {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return (parts.year ?? 0) * 10000 + (parts.month ?? 0) * 100 + (parts.day ?? 0)
    }

    mutating func reconcile(now: Date, pending: Set<String>, slots: [CompanionNoticeSlot],
                            calendar: Calendar) -> [CompanionNoticeSlot] {
        latestCheck = max(latestCheck, now)
        let earliest = latestCheck.addingTimeInterval(-7 * 86400)
        entries = entries.filter { $0.value.date >= earliest }
        for (id, entry) in entries where entry.date <= now || !pending.contains(id) {
            entries[id]?.spent = true
        }

        var counts: [Int: Int] = [:]
        var categories: [Int: Set<String>] = [:]
        for (id, entry) in entries where entry.spent {
            // Preserve the scheduled civil day and account for its instant in the current zone.
            let days: Set<Int> = [entry.localDay, Self.day(entry.date, calendar: calendar)]
            let category = id.hasPrefix("companion.greeting.") ? "companion.greeting" : "companion.bedtime"
            for day in days {
                counts[day, default: 0] += 1
                categories[day, default: []].insert(category)
            }
        }
        // Beyond retained history, suppress replay after severe clock rollback. The margin
        // covers a civil day plus the largest difference between two civil time zones.
        guard now >= earliest.addingTimeInterval(3 * 86400) else { return [] }
        return slots.filter { slot in
            let day = Self.day(slot.date, calendar: calendar)
            guard entries[slot.id]?.spent != true,
                  counts[day, default: 0] < 2, !categories[day, default: []].contains(slot.category) else { return false }
            counts[day, default: 0] += 1
            categories[day, default: []].insert(slot.category)
            return true
        }
    }

    mutating func reserve(_ slot: CompanionNoticeSlot, calendar: Calendar) {
        entries[slot.id] = Entry(date: slot.date, localDay: Self.day(slot.date, calendar: calendar), spent: false)
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
                guard let line = CharacterPack.notificationLine(in: pack.records, trigger: trigger, facts: [], slot: seed,
                                                                mood: pack.disposition.defaultMood, intensity: pack.personality.intensity,
                                                                period: DayPeriod(hour: hour)) else { continue }
                slots.append(CompanionNoticeSlot(id: id, category: "companion.\(category)",
                                                 body: line.shortText ?? line.text, date: date))
            }
        }
        return slots.sorted { $0.date < $1.date }
    }
}
