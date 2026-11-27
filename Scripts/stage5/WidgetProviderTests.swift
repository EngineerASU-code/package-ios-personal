import SwiftUI
import WidgetKit
import UIKit
import Foundation
import XCTest

final class WidgetProviderTests: XCTestCase {
    @MainActor func testAccessoryLayoutsRenderOnSimulator() throws {
        for hero in [Hero.jinwoo, .maomao] {
            var state = Companion()
            state.hero = hero
            let scene = WidgetScene(entry: Entry(date: Date(), state: state, settings: Settings()))
            for (family, name, width, height) in [
                (WidgetFamily.accessoryCircular, "circle", 52, 52),
                (.accessoryInline, "inline", 180, 26),
                (.accessoryRectangular, "rectangle", 160, 62)
            ] {
                let content = scene.accessory(family)
                    .frame(width: CGFloat(width), height: CGFloat(height))
                    .foregroundStyle(.white).background(.black)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage)
                XCTAssertEqual(image.cgImage?.width, width * 3)
                let attachment = XCTAttachment(image: image)
                attachment.name = hero.rawValue + "-" + name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor func testSixHeroesRenderThreeBundledBackdropsOnSimulator() throws {
        let variants = [(hour: 6, file: "scene.jpg"), (hour: 13, file: "scene-day.jpg"),
                        (hour: 23, file: "scene-night.jpg")]
        let calendar = Calendar.current
        let tile = CGSize(width: 252, height: 126)
        let labelHeight: CGFloat = 26
        let rowHeight = tile.height + labelHeight
        var images: [(hero: Hero, file: String, image: UIImage)] = []
        var sources = Set<Data>()
        var renders = Set<Data>()
        for hero in Hero.allCases {
            for variant in variants {
                let path = "Characters/\(hero.rawValue)/\(variant.file)"
                let source = try XCTUnwrap(UIImage(named: path), path)
                let sourcePixels = try XCTUnwrap(source.cgImage, path)
                XCTAssertGreaterThan(sourcePixels.width, 1, path)
                XCTAssertGreaterThan(sourcePixels.height, 1, path)
                let url = try XCTUnwrap(Bundle.main.resourceURL).appendingPathComponent(path)
                XCTAssertTrue(sources.insert(try Data(contentsOf: url)).inserted, "Повтор файла \(path)")

                let date = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 2,
                                                                            day: 9, hour: variant.hour)))
                let backdrop = HeroBackdrop(hero: hero, date: date, mode: .normal)
                    .frame(width: tile.width, height: tile.height)
                let renderer = ImageRenderer(content: backdrop)
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.uiImage, path)
                XCTAssertEqual(image.size, tile, path)
                XCTAssertTrue(renders.insert(try XCTUnwrap(image.pngData())).inserted,
                              "Повтор отрисованного фона \(path)")
                images.append((hero, variant.file, image))
            }
        }
        XCTAssertEqual(images.count, 18)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: tile.width * CGFloat(variants.count), height: rowHeight * CGFloat(Hero.allCases.count))
        let sheet = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, item) in images.enumerated() {
                let x = CGFloat(index % variants.count) * tile.width
                let y = CGFloat(index / variants.count) * rowHeight
                item.image.draw(in: CGRect(origin: CGPoint(x: x, y: y), size: tile))
                let label = "\(item.hero.name) · \(item.file)" as NSString
                label.draw(at: CGPoint(x: x + 4, y: y + tile.height + 3), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.white
                ])
            }
        }
        let attachment = XCTAttachment(image: sheet)
        attachment.name = "six-heroes-three-backdrops"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testJinwooChangesMoodAndSpeechBetweenTimelineEntriesWithoutATap() throws {
        var state = Companion()
        state.hero = .jinwoo
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 27, hour: 11)))
        let frames = DayTimeline.dates(from: start, mode: state.mode, calendar: calendar).map {
            DayTimeline.display(state, at: $0, calendar: calendar)
        }
        let spoken = frames.filter { !$0.text.isEmpty }
        XCTAssertTrue(spoken.allSatisfy { state.hero.pack?.byID[$0.id] != nil })
        XCTAssertGreaterThan(Set(spoken.map(\.text)).count, 1)
        XCTAssertGreaterThan(Set(frames.map { $0.emotion.rawValue }).count, 1)
        XCTAssertNil(state.contact)
    }

    func testConfigurationsShareModeAndKeepIndependentContacts() async throws {
        let store = try Store.shared()
        defer { try? FileManager.default.removeItem(at: store.url) }
        try store.update { $0.hero = .gojo }

        let provider = Provider()
        let primary = Settings()
        let missingURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertFalse(provider.current(primary, store: { Store(url: missingURL) }).available)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingURL.path))
        var fixed = Settings()
        fixed.selection = .maomao
        fixed.showsSpeech = false
        fixed.showsCount = true

        let noPack = provider.current(fixed, hasResources: { hero in
            XCTAssertEqual(hero, .maomao)
            return false
        })
        XCTAssertFalse(noPack.available)
        XCTAssertNil(noPack.display)
        let initial = provider.current(fixed)
        XCTAssertTrue(initial.available)
        XCTAssertEqual(initial.state.hero, .maomao)
        XCTAssertFalse(initial.settings.showsSpeech)
        XCTAssertTrue(initial.settings.showsCount)
        XCTAssertTrue(provider.current(primary).settings.showsSpeech)

        _ = try await React(hero: .maomao, follows: false).perform()
        let fixedContact = try XCTUnwrap(provider.current(fixed).state.contact)
        XCTAssertEqual(fixedContact.hero, .maomao)
        XCTAssertEqual(try store.read().hero, .gojo)
        XCTAssertNil(provider.current(primary).state.contact)

        _ = try await React(hero: .gojo, follows: true).perform()
        let gojoContact = try XCTUnwrap(provider.current(primary).state.contact)
        XCTAssertEqual(gojoContact.hero, .gojo)
        XCTAssertEqual(provider.current(fixed).state.contact, fixedContact)

        try store.update { $0.hero = .jinshi }
        _ = try await React(hero: .gojo, follows: true).perform()
        XCTAssertEqual(provider.current(primary).state.hero, .jinshi)
        XCTAssertNil(provider.current(primary).state.contact)
        var gojo = Settings()
        gojo.selection = .gojo
        XCTAssertEqual(provider.current(gojo).state.contact, gojoContact)
        XCTAssertEqual(provider.current(fixed).state.hero, .maomao)

        try store.update { $0.mode = .safe }
        _ = try await React(hero: .jinshi, follows: true).perform()
        _ = try await React(hero: .maomao, follows: false).perform()
        for configuration in [primary, fixed, gojo] {
            let entry = provider.current(configuration)
            XCTAssertTrue(entry.available)
            XCTAssertEqual(entry.state.mode, .safe)
        }
        XCTAssertNil(provider.current(primary).state.contact)
        XCTAssertEqual(provider.current(fixed).state.contact, fixedContact)

        let corrupt = Data("Invalid SQLite database".utf8)
        try corrupt.write(to: store.url, options: .atomic)
        XCTAssertThrowsError(try store.read())
        for configuration in [primary, fixed] {
            XCTAssertFalse(provider.current(configuration).available)
        }
        XCTAssertEqual(try Data(contentsOf: store.url), corrupt)
    }
}
