import Foundation

enum DayPeriod: Int {
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

    static func display(_ state: Companion, at date: Date, calendar: Calendar) -> Reaction {
        guard state.mode == .normal || state.mode == .eco else { return state.reaction }
        let hour = calendar.component(.hour, from: date)
        let period = DayPeriod(hour: hour)
        if let tap = state.contact, tap.hero == state.hero, date >= tap.date,
           date.timeIntervalSince(tap.date) < 3600,
           calendar.isDate(date, equalTo: tap.date, toGranularity: .hour) {
            return state.reaction
        }
        let slot = Int(floor(date.timeIntervalSince1970 / (state.mode == .eco ? 7200 : 3600)))
        let seed = state.hero.rawValue.utf8.reduce(0) { $0 + Int($1) }
        let passive = state.hero.pack?.records.filter { $0.category == "day" }.map(\.reaction) ?? []
        let lines = passive.isEmpty ? state.hero.dialogue : passive
        let index = ((slot + seed) % lines.count + lines.count) % lines.count
        if period == .night || period == .lateNight {
            let action = period == .night ? "Готовится ко сну" : "Спит"
            return Reaction("sleep", "", "\(period.caption) · \(action)", emotion: .sleepy)
        }
        let line = lines[index]
        return Reaction(line.id, line.text, "\(period.caption) · \(line.action)", emotion: line.emotion)
    }
}

struct Contact: Codable, Equatable {
    let hero: Hero
    let date: Date
    let response: String
    var portalOnRight: Bool? = nil
}
