import Foundation
import XCTest
@testable import CompanionCore

final class PerformanceTests: XCTestCase {
    // Fixed local workload from §24.3. Device budgets apply only on physical iPhones.
    func testCoreLatencySample() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 12)))
        for hero in Hero.allCases { XCTAssertNotNil(hero.pack) } // Warm all six JSON packages.
        var state = Companion()
        state.mode = .eco
        var timeline = [Double]()
        var interaction = [Double]()
        var totalFrames = 0
        for sample in 0..<120 {
            state.hero = Hero.allCases[sample % Hero.allCases.count]
            let date = start.addingTimeInterval(Double(sample * 600))
            let t0 = DispatchTime.now().uptimeNanoseconds
            state.react(at: date, calendar: calendar)
            let t1 = DispatchTime.now().uptimeNanoseconds
            let entries = DayTimeline.dates(from: date, mode: .normal, calendar: calendar)
            var normal = state
            normal.mode = .normal
            for frame in entries {
                let response = DayTimeline.display(normal, at: frame, calendar: calendar)
                XCTAssertFalse(response.id.isEmpty)
            }
            let t2 = DispatchTime.now().uptimeNanoseconds
            interaction.append(Double(t1 - t0) / 1_000_000)
            timeline.append(Double(t2 - t1) / 1_000_000)
            totalFrames += entries.count
        }
        func p95(_ times: [Double]) -> Double {
            times.sorted()[Int(ceil(Double(times.count) * 0.95)) - 1]
        }
        print(String(format: "Core sample: n=%d frames=%d reaction_p95_ms=%.3f timeline_p95_ms=%.3f",
                     timeline.count, totalFrames, p95(interaction), p95(timeline)))
    }
}
