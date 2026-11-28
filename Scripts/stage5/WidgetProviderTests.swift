import SwiftUI
import WidgetKit
import UIKit
import Foundation
import XCTest

final class WidgetProviderTests: XCTestCase {
    @MainActor func testReactionActionsRenderThroughUIKitOnSimulator() async throws {
        struct SeededGenerator: RandomNumberGenerator {
            var seed: UInt64 = 37
            mutating func next() -> UInt64 {
                seed = seed &* 2862933555777941757 &+ 3037000493
                return seed
            }
        }
        var generator = SeededGenerator()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 13)))
        let night = day.addingTimeInterval(10 * 3600)
        let dimensions = CGSize(width: 360, height: 226)
        let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)

        func contact(_ state: inout Companion, at date: Date) {
            let event = CompanionEvent(id: UUID(), source: .simulatedTest, kind: .appInteraction, date: date)
            XCTAssertTrue(state.handle([event], at: date, calendar: calendar, using: &generator))
        }

        func capture(_ state: Companion, pack: CharacterPack, reaction: Reaction, at date: Date) async throws -> UIImage {
            let hero = state.hero
            var requests: Set<ArtworkRequest> = [
                .figure(hero, portrait: false, emotion: reaction.emotion, daytime: reaction.daytimePose, pixels: 512),
                .backdrop(hero, date: date, mode: state.mode, schedule: state.daySchedule)
            ]
            for file in pack.animation(for: .app, reactionID: reaction.id)?.assets ?? [] {
                requests.insert(ArtworkRequest(hero: hero, file: file))
            }
            let artwork = await ArtworkDecoder.shared.images(for: requests)
            XCTAssertEqual(artwork.count, requests.count, hero.rawValue)
            let view = CompanionScene(state: state, date: date, display: reaction)
                .environment(\.preparedArtwork, artwork)
                .environment(\.scenePack, pack)
                .environment(\.colorScheme, .dark)
                .environment(\.dynamicTypeSize, .large)
                .frame(width: dimensions.width, height: dimensions.height)
            let window = UIWindow(windowScene: windowScene)
            let host = UIHostingController(rootView: view.ignoresSafeArea())
            window.frame = CGRect(origin: .zero, size: dimensions)
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.frame = window.bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            let bounds = CGRect(origin: .zero, size: dimensions)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            var didDraw = false
            let image = UIGraphicsImageRenderer(size: dimensions, format: format).image { _ in
                didDraw = host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(didDraw, hero.rawValue)
            XCTAssertEqual(image.cgImage?.width, 720)
            XCTAssertEqual(image.cgImage?.height, 452)
            return image
        }

        func attach(_ image: UIImage, name: String) {
            let attachment = XCTAttachment(image: image)
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }

        for hero in Hero.allCases {
            var state = Companion()
            state.hero = hero
            let pack = try XCTUnwrap(hero.pack)
            contact(&state, at: night)
            let reaction = DayTimeline.display(state, at: night, calendar: calendar, using: pack)
            let rest = try XCTUnwrap(pack.behaviors["nightRest"])
            XCTAssertEqual(reaction.action, rest.label, hero.rawValue)
            XCTAssertEqual(reaction.emotion, .sleepy, hero.rawValue)
            XCTAssertFalse(reaction.text.isEmpty, hero.rawValue)
            if hero == .sukuna {
                XCTAssertNil(pack.animation(for: .app, reactionID: reaction.id), "Ночная поза должна сохранить сонный спрайт.")
            }
            attach(try await capture(state, pack: pack, reaction: reaction, at: night), name: "night-rest-\(hero.rawValue)")
        }

        XCTAssertFalse(UIAccessibility.isReduceMotionEnabled, "Для сравнения кадров требуется выключить системное уменьшение движения.")
        for (hero, effect, action) in [(Hero.jinshi, CharacterPack.AnimationDescriptor.Effect.fan, "Раскрывает веер"),
                                       (.toji, .spirit, "Достаёт клинок")] {
            let pack = try XCTUnwrap(hero.pack)
            var withEffect: (Companion, Reaction)?
            var withoutEffect: (Companion, Reaction)?
            for _ in 0..<128 {
                var state = Companion()
                state.hero = hero
                state.randomEventsEnabled = false
                state.complimentFrequency = .off
                contact(&state, at: day)
                let reaction = DayTimeline.display(state, at: day, calendar: calendar, using: pack)
                if pack.animation(for: .app, reactionID: reaction.id)?.id == effect {
                    withEffect = (state, reaction)
                } else {
                    withoutEffect = (state, reaction)
                }
                if withEffect != nil && withoutEffect != nil { break }
            }
            let (activeState, activeReaction) = try XCTUnwrap(withEffect, hero.rawValue)
            let (plainState, plainReaction) = try XCTUnwrap(withoutEffect, hero.rawValue)
            XCTAssertEqual(activeReaction.action, action)
            XCTAssertNotEqual(plainReaction.action, action)
            var disabled = activeState
            disabled.animationsEnabled = false
            let activeImage = try await capture(activeState, pack: pack, reaction: activeReaction, at: day)
            let disabledImage = try await capture(disabled, pack: pack, reaction: activeReaction, at: day)
            XCTAssertNotEqual(activeImage.pngData(), disabledImage.pngData(), "Видимый эффект должен изменить кадр.")
            attach(activeImage, name: "action-effect-\(hero.rawValue)")
            attach(disabledImage, name: "action-effect-disabled-\(hero.rawValue)")
            attach(try await capture(plainState, pack: pack, reaction: plainReaction, at: day),
                   name: "action-unrelated-\(hero.rawValue)")
        }
    }

    @MainActor func testIgrisSummonScaleAndContrastOnSimulator() async throws {
        let hero = Hero.jinwoo
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 23)))
        let pack = try XCTUnwrap(hero.pack)
        XCTAssertEqual(pack.animations[.widgetLarge]?.id, .summon)
        XCTAssertEqual(pack.animations[.widgetMedium]?.id, .portal)
        XCTAssertEqual(pack.animations[.app]?.id, .portal)
        let knight = ArtworkRequest(hero: hero, file: "igris.png")
        let chibi = ArtworkRequest.figure(hero, portrait: false, emotion: .neutral, daytime: false, pixels: 512)
        let backdrop = ArtworkRequest.backdrop(hero, date: date, mode: .normal, schedule: DaySchedule())
        let artwork = await ArtworkDecoder.shared.images(for: [knight, chibi, backdrop])
        let sprite = try XCTUnwrap(artwork[knight]?.cgImage)
        XCTAssertEqual(sprite.width, 360)
        XCTAssertEqual(sprite.height, 360)
        XCTAssertEqual(artwork.count, 3)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)

        for (name, width, height) in [("compact", CGFloat(144), CGFloat(120)), ("regular", ShadowSummonLayout.preferredGroupWidth, CGFloat(160))] {
            let size = CGSize(width: width, height: height)
            let layout = ShadowSummonLayout(size: size)
            let visibleKnightHeight = layout.knightSide * 348 / 360
            XCTAssertGreaterThanOrEqual(visibleKnightHeight, layout.heroWidth * 0.8, name)
            XCTAssertGreaterThan(visibleKnightHeight, width * 0.25 * 1.8, name)
            let visibleHeroRight = layout.heroWidth * 314 / 362
            let visibleKnightLeft = width - layout.knightSide + layout.knightSide * 9 / 360
            XCTAssertGreaterThan(visibleKnightLeft - visibleHeroRight, 1, name)
            XCTAssertLessThanOrEqual(layout.knightSide, height, name)

            var state = Companion()
            state.hero = hero
            let reaction = Reaction("hosted-igris", "Ночью уровень тишины выше всего.", "Отдыхает")
            state.contact = Contact(hero: hero, date: date, response: reaction.id)
            let entry = Entry(date: date, state: state, settings: Settings(), display: reaction,
                              pack: pack, artwork: artwork)
            let canvas = CGSize(width: width + 152, height: height + 76)
            let content = WidgetScene(entry: entry, family: .systemLarge)
                .padding(12)
                .frame(width: canvas.width, height: canvas.height)
                .background {
                    HeroBackdrop(hero: hero, date: date, mode: .normal)
                        .environment(\.preparedArtwork, artwork)
                        .environment(\.scenePack, pack)
                }
                .environment(\.dynamicTypeSize, .large)
            let bounds = CGRect(origin: .zero, size: canvas)
            let window = UIWindow(windowScene: scene)
            let host = UIHostingController(rootView: content.ignoresSafeArea())
            window.frame = bounds
            window.rootViewController = host
            window.isHidden = false
            defer { window.isHidden = true }
            host.view.frame = bounds
            host.view.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            var didDraw = false
            let image = UIGraphicsImageRenderer(size: canvas, format: format).image { _ in
                didDraw = host.view.drawHierarchy(in: bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(didDraw, name)
            XCTAssertEqual(image.cgImage?.width, Int((width + 152) * 2))
            XCTAssertEqual(image.cgImage?.height, Int((height + 76) * 2))
            let rendered = try XCTUnwrap(image.cgImage)
            let bytesPerRow = rendered.width * 4
            let bitmap = try XCTUnwrap(CGContext(data: nil, width: rendered.width, height: rendered.height,
                                                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            bitmap.draw(rendered, in: CGRect(origin: .zero, size: CGSize(width: CGFloat(rendered.width), height: CGFloat(rendered.height))))
            let pixels = try XCTUnwrap(bitmap.data?.assumingMemoryBound(to: UInt8.self))
            var leftmostPlume = rendered.width
            var rightmostPlume = 0
            var redPixels = 0
            var whiteByColumn = Array(repeating: 0, count: rendered.width)
            for y in 0..<rendered.height {
                for x in 0..<rendered.width {
                    let offset = y * bytesPerRow + x * 4
                    if pixels[offset] > 150 && pixels[offset + 1] < 65 && pixels[offset + 2] < 100 {
                        leftmostPlume = min(x, leftmostPlume)
                        rightmostPlume = max(x, rightmostPlume)
                        redPixels += 1
                    }
                    if y < rendered.height * 3 / 4,
                       pixels[offset] > 235 && pixels[offset + 1] > 235 && pixels[offset + 2] > 220 {
                        whiteByColumn[x] += 1
                    }
                }
            }
            let captionStart = try XCTUnwrap(whiteByColumn.firstIndex { $0 >= 25 }, name)
            XCTAssertGreaterThan(redPixels, 100, name)
            XCTAssertGreaterThan(leftmostPlume, rendered.width * 22 / 100, name)
            XCTAssertLessThan(rightmostPlume, captionStart, name)
            let attachment = XCTAttachment(image: image)
            attachment.name = "igris-after-\(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor func testContextEmotionsRenderOnSimulator() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 28, hour: 12)))
        let night = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 29, hour: 0)))
        let dimensions = CGSize(width: 360, height: 226)
        let scale: CGFloat = 2

        for hero in Hero.allCases {
            var state = Companion()
            state.hero = hero
            state.animationsEnabled = false
            state.sceneWeather = SceneWeather(isSunny: true, observedAt: day)
            let pack = try XCTUnwrap(hero.pack)
            let scenarios: [(date: Date, nightEvent: Date?, emotion: ChibiEmotion, id: String)] = [
                (day, nil, .happy, "context-sunny"),
                (night, night, .frowning, "context-bedtime")
            ]
            for scenario in scenarios {
                let reaction = DayTimeline.display(state, at: scenario.date, calendar: calendar,
                                                   channel: "widget", using: pack, nightScreenTimeAt: scenario.nightEvent)
                XCTAssertEqual(reaction.id, scenario.id, hero.rawValue)
                XCTAssertEqual(reaction.emotion, scenario.emotion, hero.rawValue)
                XCTAssertFalse(reaction.text.isEmpty, hero.rawValue)
                let baseline = DayTimeline.display(state, at: scenario.date.addingTimeInterval(2 * 3600),
                                                   calendar: calendar, channel: "widget", using: pack,
                                                   nightScreenTimeAt: scenario.nightEvent)
                XCTAssertNotEqual(baseline.id, reaction.id, hero.rawValue)

                let requests: Set<ArtworkRequest> = [
                    .figure(hero, portrait: false, emotion: reaction.emotion, daytime: reaction.daytimePose, pixels: 512),
                    .backdrop(hero, date: scenario.date, mode: state.mode, schedule: state.daySchedule)
                ]
                let artwork = await ArtworkDecoder.shared.images(for: requests)
                XCTAssertEqual(artwork.count, requests.count, hero.rawValue)
                let content = CompanionScene(state: state, date: scenario.date, display: reaction)
                    .environment(\.preparedArtwork, artwork)
                    .environment(\.scenePack, pack)
                    .environment(\.colorScheme, .dark)
                    .environment(\.dynamicTypeSize, .large)
                    .frame(width: dimensions.width, height: dimensions.height)
                let renderer = ImageRenderer(content: content)
                renderer.scale = scale
                var image = try XCTUnwrap(renderer.uiImage, "\(hero.rawValue) · \(scenario.id)")
                XCTAssertEqual(image.cgImage?.width, Int(dimensions.width * scale))
                XCTAssertEqual(image.cgImage?.height, Int(dimensions.height * scale))
                if hero == .maomao && scenario.emotion == .happy {
                    XCTAssertEqual(reaction.text, "На солнце у этого листа видна каждая жилка.")
                    let exported = XCTAttachment(image: image)
                    exported.name = "diagnostic-image-renderer-context-sunny-maomao"
                    exported.lifetime = .keepAlways
                    add(exported)

                    let windowScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
                    let window = UIWindow(windowScene: windowScene)
                    let host = UIHostingController(rootView: content.ignoresSafeArea())
                    window.frame = CGRect(origin: .zero, size: dimensions)
                    window.rootViewController = host
                    window.isHidden = false
                    defer { window.isHidden = true }
                    host.view.frame = window.bounds
                    host.view.setNeedsLayout()
                    host.view.layoutIfNeeded()
                    try await Task.sleep(for: .milliseconds(100))
                    host.view.layoutIfNeeded()
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = scale
                    var didDraw = false
                    image = UIGraphicsImageRenderer(size: dimensions, format: format).image { _ in
                        didDraw = host.view.drawHierarchy(in: CGRect(origin: .zero, size: dimensions), afterScreenUpdates: true)
                    }
                    XCTAssertTrue(didDraw, "UIKit must draw the attached SwiftUI hosting view.")
                    XCTAssertEqual(image.cgImage?.width, Int(dimensions.width * scale))
                    XCTAssertEqual(image.cgImage?.height, Int(dimensions.height * scale))
                    // This part of the fixed-size snapshot is inside the white
                    // speech bubble and below its first line.
                    let cropped = try XCTUnwrap(image.cgImage?.cropping(to: CGRect(x: 382, y: 265, width: 265, height: 57)))
                    let bytesPerRow = cropped.width * 4
                    let bitmap = try XCTUnwrap(CGContext(data: nil, width: cropped.width, height: cropped.height,
                                                        bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                                        space: CGColorSpaceCreateDeviceRGB(),
                                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    bitmap.draw(cropped, in: CGRect(x: 0, y: 0, width: CGFloat(cropped.width), height: CGFloat(cropped.height)))
                    let pixels = try XCTUnwrap(bitmap.data?.assumingMemoryBound(to: UInt8.self))
                    var ink = 0
                    var white = 0
                    for offset in stride(from: 0, to: bytesPerRow * cropped.height, by: 4) {
                        let red = pixels[offset], green = pixels[offset + 1], blue = pixels[offset + 2]
                        if red < 40 && green < 40 && blue < 40 { ink += 1 }
                        if red > 245 && green > 245 && blue > 245 { white += 1 }
                    }
                    XCTAssertGreaterThan(white, cropped.width * cropped.height / 2, "Область должна находиться внутри облака.")
                    XCTAssertGreaterThan(ink, 100, "У Мао Мао должны быть видны строки ниже первой.")
                }
                let attachment = XCTAttachment(image: image)
                attachment.name = "\(scenario.id)-\(hero.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor func testJinwooPortalTransitionRendersOnSimulator() async throws {
        let hero = Hero.jinwoo
        let request = ArtworkRequest.figure(hero, portrait: false, emotion: .neutral, daytime: false, pixels: 512)
        let artwork = await ArtworkDecoder.shared.images(for: [request])
        for (name, phase) in [("rest", 0.0), ("arc", 0.22), ("departed", 0.62)] {
            let view = CompanionFigure(hero: hero, emotion: .neutral, pixels: 512)
                .modifier(PortalGate(hero: hero, arriving: false, rightSide: false, departure: phase))
                .environment(\.preparedArtwork, artwork)
                .frame(width: 150, height: 168)
                .background(Color.black)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            XCTAssertEqual(image.cgImage?.width, 300)
            let attachment = XCTAttachment(image: image)
            attachment.name = "R09-portal-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    @MainActor func testAccessoryLayoutsRenderOnSimulator() async throws {
        for hero in [Hero.jinwoo, .maomao] {
            var state = Companion()
            state.hero = hero
            for (family, name, width, height) in [
                (WidgetFamily.accessoryCircular, "circle", 52, 52),
                (.accessoryInline, "inline", 180, 26),
                (.accessoryRectangular, "rectangle", 160, 62)
            ] {
                let entry = await Entry(date: Date(), state: state, settings: Settings()).prepared(for: family)
                let content = WidgetAccessory(entry: entry, size: family)
                    .environment(\.preparedArtwork, entry.artwork)
                    .environment(\.scenePack, entry.pack)
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

    @MainActor func testSixHeroesRenderThreeBundledBackdropsOnSimulator() async throws {
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
                let request = ArtworkRequest.backdrop(hero, date: date, mode: .normal, schedule: DaySchedule())
                let prepared = await ArtworkDecoder.shared.images(for: [request])
                XCTAssertNotNil(prepared[request], path)
                let backdrop = HeroBackdrop(hero: hero, date: date, mode: .normal)
                    .environment(\.preparedArtwork, prepared)
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
        let hot = provider.current(primary, effectiveMode: { _ in .safe })
        XCTAssertEqual(hot.state.mode, .safe)
        XCTAssertTrue(hot.retryAfterCooling)
        XCTAssertEqual(try store.read().mode, .normal)
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
            XCTAssertFalse(entry.retryAfterCooling)
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
