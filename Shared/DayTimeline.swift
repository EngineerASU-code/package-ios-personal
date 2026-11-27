import Foundation

enum DayPeriod: String, Decodable {
    case dawn, morning, day, evening, night, lateNight

    init(hour: Int) {
        switch hour {
        case 5..<8: self = .dawn
        case 8..<12: self = .morning
        case 12..<18: self = .day
        case 18..<22: self = .evening
        case 22..<24: self = .night
        default: self = .lateNight
        }
    }

    var caption: String {
        switch self {
        case .dawn: return "Раннее утро"
        case .morning: return "Утро"
        case .day: return "День"
        case .evening: return "Вечер"
        case .night: return "Ночь"
        case .lateNight: return "Поздняя ночь"
        }
    }
}

extension Hero {
    var greeting: Reaction {
        let text: String
        switch self {
        case .gojo: text = "Доброе утро! Последний моти поделим?"
        case .toji: text = "Утро. Разомнём плечи?"
        case .jinshi: text = "Доброе утро. Я как раз заварил чай."
        case .jinwoo: text = "Доброе утро. Начну с короткой разминки."
        case .sukuna: text = "Утро уже здесь. Что ж, пусть входит."
        case .maomao: text = "Доброе утро. На листьях ещё роса."
        }
        return Reaction("greeting", text, "Приветствует", emotion: .happy)
    }
}

enum DayTimeline {
    // A single scheduled entry releases the response even between hourly slots.
    static func responseEnd(_ state: Companion) -> Date? {
        guard let tap = state.contact, tap.hero == state.hero else { return nil }
        return tap.date.addingTimeInterval(300)
    }

    static func dates(from now: Date, state: Companion, calendar: Calendar) -> [Date] {
        let regular = dates(from: now, mode: state.mode, calendar: calendar)
        guard regular.count > 1, let horizon = regular.last, let end = responseEnd(state),
              end > now, end <= horizon else { return regular }
        return ([now, end] + regular.dropFirst().filter { abs($0.timeIntervalSince(end)) >= 300 }).sorted()
    }

    // Absolute instants stay ordered across repeated or missing local hours.
    // Local hour boundaries keep the 05:00 / 22:00 transitions in local time.
    static func dates(from now: Date, mode: CompanionMode, calendar: Calendar) -> [Date] {
        guard mode == .normal || mode == .eco else { return [now] }
        let horizon = now.addingTimeInterval(12 * 3600)
        var dates = [now]
        var cursor = now
        for _ in 0..<14 {
            guard let next = calendar.dateInterval(of: .hour, for: cursor)?.end,
                  next > cursor, next <= horizon else { break }
            cursor = next
            let hour = calendar.component(.hour, from: next)
            if mode == .eco && !hour.isMultiple(of: 2) && hour != 5
                && next.timeIntervalSince(dates[dates.count - 1]) <= 3600 { continue }
            let earliest = dates[dates.count - 1].addingTimeInterval(300)
            dates.append(max(next, earliest))
        }
        return dates
    }

    // Day has two ordinary slots per cycle. Advance the line in both of them.
    private static func rowSequence(category: String, cycle: Int, rotation: Int) -> Int {
        category == "day" ? cycle * 2 + (rotation == 2 ? 1 : 0) : cycle
    }

    static func display(_ state: Companion, at date: Date, calendar: Calendar, showsTask: Bool = true, channel: String = "app") -> Reaction {
        guard state.mode == .normal || state.mode == .eco else { return state.reaction }
        let hour = calendar.component(.hour, from: date)
        let period = DayPeriod(hour: hour)
        let pack = state.hero.pack
        if let tap = state.contact, tap.hero == state.hero, date >= tap.date,
           let end = responseEnd(state), date < end,
           pack?.byID[tap.response]?.allows(period) != false,
           pack?.byID[tap.response]?.channels.contains(channel) != false {
            return state.reaction
        }
        let slot = Int(floor(date.timeIntervalSince1970 / (state.mode == .eco ? 7200 : 3600)))
        let seed = state.hero.rawValue.utf8.reduce(0) { $0 + Int($1) }

        if period == .night || period == .lateNight {
            let action = period == .night ? "Готовится ко сну" : "Спит"
            return Reaction("sleep", "", "\(period.caption) · \(action)", emotion: .sleepy)
        }
        let phase = (slot + seed).quotientAndRemainder(dividingBy: 3)
        let rotation = (phase.remainder + 3) % 3
        let hasDueTask = showsTask && rotation == 2 && state.reminders.contains { task in
            guard task.completedAt == nil, task.createdAt <= date, let target = task.target else { return false }
            return target <= date
        }
        let hasUpcomingEvent = state.calendarSnapshot.upcoming(at: date).contains {
            !$0.allDay && $0.start > date && $0.start.timeIntervalSince(date) <= 3600
        }
        let category: String
        let trigger: String
        if hasDueTask {
            (category, trigger) = ("reminder", "reminderDue")
        } else if hasUpcomingEvent {
            (category, trigger) = ("calendar", "calendarUpcoming")
        } else {
            (category, trigger) = (rotation == 1 ? "compliment" : "day", "randomSlot")
        }
        guard let pack else { return Reaction("idle", "Я здесь.", period.caption) }
        let mood = state.activity(at: date).mood
        func eligible(_ category: String, trigger: String) -> [CharacterPack.Record] {
            pack.records.filter {
                $0.category == category && $0.eligible(trigger: trigger, channel: channel, facts: [trigger],
                                                       mood: mood, intensity: pack.personality.intensity, period: period)
            }
        }
        var choices = eligible(category, trigger: trigger)
        if choices.isEmpty && category != "day" { choices = eligible("day", trigger: "randomSlot") }
        guard !choices.isEmpty else { return Reaction("idle", "Я здесь.", period.caption) }
        let total = choices.reduce(0) { $0 + $1.weight }
        let sequence = rowSequence(category: category, cycle: phase.quotient, rotation: rotation)
        var ticket = (sequence % total + total) % total
        let row = choices.first { candidate in
            ticket -= candidate.weight
            return ticket < 0
        } ?? choices[0]
        let line = row.reaction
        let action = row.behaviorID.flatMap { pack.behaviors[$0]?.label } ?? line.action
        var emotion = line.emotion
        if row.category == "day" {
            emotion = pack.disposition.expression(for: rotation == 0 ? pack.disposition.recovery : mood)
        }
        var result = Reaction(line.id, line.text, "\(period.caption) · \(action)", emotion: emotion)
        result.daytimePose = state.hero != .gojo && (emotion == .surprised || emotion == .happy)
        return result
    }
}

struct Contact: Codable, Equatable {
    let hero: Hero
    let date: Date
    let response: String
    var portalOnRight: Bool? = nil
}
