import Foundation

struct DaySchedule: Codable, Equatable {
    var lateNight = 0
    var dawn = 5
    var morning = 8
    var day = 12
    var evening = 18
    var night = 22

    var isValid: Bool {
        0 <= lateNight && lateNight < dawn && dawn < morning && morning < day &&
            day < evening && evening < night && night < 24
    }

    func period(hour: Int) -> DayPeriod {
        if hour < lateNight || hour >= night { return .night }
        if hour < dawn { return .lateNight }
        if hour < morning { return .dawn }
        if hour < day { return .morning }
        if hour < evening { return .day }
        return .evening
    }

    func period(at date: Date, calendar: Calendar) -> DayPeriod {
        period(hour: calendar.component(.hour, from: date))
    }
}

enum DayPeriod: String, Decodable {
    case dawn, morning, day, evening, night, lateNight

    init(hour: Int) {
        self = DaySchedule().period(hour: hour)
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
        let regular = dates(from: now, mode: state.mode, calendar: calendar, schedule: state.daySchedule)
        guard regular.count > 1, let horizon = regular.last, let end = responseEnd(state),
              end > now, end <= horizon else { return regular }
        return ([now, end] + regular.dropFirst().filter { abs($0.timeIntervalSince(end)) >= 300 }).sorted()
    }

    // Absolute instants stay ordered across repeated or missing local hours.
    // Local hour boundaries keep the 05:00 / 22:00 transitions in local time.
    static func dates(from now: Date, mode: CompanionMode, calendar: Calendar, schedule: DaySchedule = DaySchedule()) -> [Date] {
        guard mode == .normal || mode == .eco else { return [now] }
        let horizon = now.addingTimeInterval(12 * 3600)
        var dates = [now]
        var cursor = now
        for _ in 0..<14 {
            guard let next = calendar.dateInterval(of: .hour, for: cursor)?.end,
                  next > cursor, next <= horizon else { break }
            cursor = next
            let hour = calendar.component(.hour, from: next)
            let changesPeriod = schedule.period(hour: hour) != schedule.period(at: next.addingTimeInterval(-1), calendar: calendar)
            if mode == .eco && !hour.isMultiple(of: 2) && !changesPeriod
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
        display(state, at: date, calendar: calendar, showsTask: showsTask, channel: channel, using: state.hero.pack)
    }

    static func display(_ state: Companion, at date: Date, calendar: Calendar, showsTask: Bool = true,
                        channel: String = "app", using pack: CharacterPack?) -> Reaction {
        let allowCompliments = state.allowsCompliments(on: channel)
        let current = state.reaction(using: pack)
        let hidden = pack?.byID[current.id].map {
            (!allowCompliments && $0.category == "compliment") || !state.communicationIntensity.permits($0, channel: channel) ||
                ($0.category == "calendar" && !state.calendarSnapshot.isFresh(at: date))
        } ?? false
        guard state.mode == .normal || state.mode == .eco else {
            return hidden ? Reaction("idle", "Я здесь.", "Отдыхает") : current
        }
        let period = state.daySchedule.period(at: date, calendar: calendar)
        if !hidden, let tap = state.contact, tap.hero == state.hero, date >= tap.date,
           let end = responseEnd(state), date < end,
           pack?.byID[tap.response]?.allows(period) != false,
           pack?.byID[tap.response]?.channels.contains(channel) != false {
            return current
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
        var facts: Set<String> = []
        if hasDueTask {
            (category, trigger) = ("reminder", "reminderDue")
        } else if hasUpcomingEvent {
            (category, trigger) = ("calendar", "calendarUpcoming")
        } else if rotation == 2, let dayFact = state.calendarSnapshot.dayFact(at: date, calendar: calendar) {
            (category, trigger) = ("calendar", "daytimeChanged")
            facts.insert(dayFact)
        } else {
            let frequency = state.passivePhraseFrequency
            guard state.randomEventsEnabled, frequency != .off,
                  frequency != .reduced || (slot + seed).isMultiple(of: 2) else { return Reaction("idle", "", period.caption) }
            let complimentSlot = rotation == 1 && allowCompliments &&
                (state.complimentFrequency != .reduced || phase.quotient.isMultiple(of: 3))
            (category, trigger) = (complimentSlot ? "compliment" : "day", "randomSlot")
        }
        guard let pack else { return Reaction("idle", "Я здесь.", period.caption) }
        let activity = state.activity(at: date, using: pack)
        func eligible(_ category: String, trigger: String) -> [CharacterPack.Record] {
            (pack.byTrigger[trigger] ?? []).filter {
                $0.category == category && state.communicationIntensity.permits($0, channel: channel) &&
                $0.eligible(trigger: trigger, channel: channel, facts: facts.union([trigger]),
                                                       mood: activity.mood, intensity: pack.personality.intensity, period: period)
            }
        }
        var choices = eligible(category, trigger: trigger)
        if choices.isEmpty && category != "day" { choices = eligible("day", trigger: "randomSlot") }
        guard !choices.isEmpty else { return Reaction("idle", "Я здесь.", period.caption) }
        let cooled = choices.filter { row in
            activity.lineDates[row.id].map { max(0, date.timeIntervalSince($0)) >= Double(row.cooldownSeconds ?? 0) } ?? true
        }
        if !cooled.isEmpty { choices = cooled }
        let recent = state.recentDialogueIDs
        let unseen = choices.filter { !recent.contains($0.id) }
        if !unseen.isEmpty { choices = unseen }
        let total = choices.reduce(0) { $0 + $1.weight }
        let sequence = rowSequence(category: category, cycle: phase.quotient, rotation: rotation)
        // Rotate each weighted cycle from a stable seed. Complete cycles visit each
        // ticket exactly once and repeated reads of the same snapshot agree.
        let block = sequence.quotientAndRemainder(dividingBy: total)
        let salt = state.hero.rawValue + ":" + category + ":" + (activity.lastEvent?.uuidString ?? "") + ":" + String(block.quotient)
        let hash = salt.utf8.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
        let offset = Int(hash % UInt64(total))
        var ticket = (offset + block.remainder + total) % total
        let row = choices.first { candidate in
            ticket -= candidate.weight
            return ticket < 0
        } ?? choices[0]
        let line = row.reaction
        let action = row.behaviorID.flatMap { pack.behaviors[$0]?.label } ?? line.action
        var emotion = line.emotion
        if row.category == "day" {
            emotion = pack.disposition.expression(for: rotation == 0 ? pack.disposition.recovery : activity.mood)
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
