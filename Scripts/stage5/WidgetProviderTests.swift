import SwiftUI
import WidgetKit
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

    func testConfigurationsShareModeAndKeepIndependentContacts() async throws {
        let store = try Store.shared()
        defer { try? FileManager.default.removeItem(at: store.url) }
        try store.update { $0.hero = .gojo }

        let provider = Provider()
        let primary = Settings()
        var fixed = Settings()
        fixed.selection = .maomao
        fixed.showsSpeech = false
        fixed.showsCount = true

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
