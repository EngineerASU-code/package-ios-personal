import SwiftUI
import ImageIO

enum CharacterArtwork {
    private static let cache: NSCache<NSString, UIImage> = {
        let result = NSCache<NSString, UIImage>()
        result.totalCostLimit = 12 * 1024 * 1024
        result.countLimit = 24
        return result
    }()

    static func releaseCachedImages() { cache.removeAllObjects() }

    static func image(_ hero: Hero, file: String, pixels: Int = 512) -> UIImage? {
        guard !file.isEmpty, !file.contains("/"), !file.contains("\\"), !file.contains(".."),
              (1...1536).contains(pixels) else { return nil }
        let key = "\(hero.rawValue)/\(file)/\(pixels)" as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let url = Bundle.main.url(forResource: file, withExtension: nil, subdirectory: "Characters/" + hero.rawValue),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              (1...4_194_304).contains(size),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let format = CGImageSourceGetType(source) as String?,
              (file.hasSuffix(".png") && format == "public.png") || (file.hasSuffix(".jpg") && format == "public.jpeg"),
              let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = info[kCGImagePropertyPixelWidth] as? Int, let height = info[kCGImagePropertyPixelHeight] as? Int,
              (1...4096).contains(width), (1...4096).contains(height), width * height <= 8_388_608 else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                         kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceShouldCacheImmediately: true,
                                         kCGImageSourceThumbnailMaxPixelSize: min(pixels, max(width, height))]
        guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: bitmap)
        cache.setObject(image, forKey: key, cost: bitmap.bytesPerRow * bitmap.height)
        return image
    }
}

struct ArtworkRequest: Hashable {
    let hero: Hero
    let file: String
    var pixels = 512
    var fallbackFile: String? = nil

    static func backdrop(_ hero: Hero, date: Date, mode: CompanionMode, schedule: DaySchedule) -> Self {
        var file = "scene.jpg"
        if mode == .normal || mode == .eco {
            switch schedule.period(at: date, calendar: .current) {
            case .morning, .day: file = "scene-day.jpg"
            case .night, .lateNight: file = "scene-night.jpg"
            case .dawn, .evening: break
            }
        }
        return Self(hero: hero, file: file, pixels: 1280, fallbackFile: file == "scene.jpg" ? nil : "scene.jpg")
    }

    static func figure(_ hero: Hero, portrait: Bool, emotion: ChibiEmotion, daytime: Bool, pixels: Int) -> Self {
        let name = portrait ? "portrait" : (daytime ? "chibi-daytime" : (emotion == .neutral ? "chibi" : "chibi-" + emotion.rawValue))
        return Self(hero: hero, file: name + ".png", pixels: pixels,
                    fallbackFile: !portrait && name != "chibi" ? "chibi.png" : nil)
    }
}

actor ArtworkDecoder {
    static let shared = ArtworkDecoder()

    func image(for request: ArtworkRequest) -> UIImage? {
        guard !Task.isCancelled else { return nil }
        if let image = CharacterArtwork.image(request.hero, file: request.file, pixels: request.pixels) { return image }
        guard let fallback = request.fallbackFile, !Task.isCancelled else { return nil }
        return CharacterArtwork.image(request.hero, file: fallback, pixels: request.pixels)
    }

    func images(for requests: Set<ArtworkRequest>) -> [ArtworkRequest: UIImage] {
        var images: [ArtworkRequest: UIImage] = [:]
        for request in requests where !Task.isCancelled { images[request] = image(for: request) }
        return images
    }
}

private actor PackLoader {
    static let shared = PackLoader()
    func load(_ hero: Hero) -> CharacterPack? { Task.isCancelled ? nil : hero.pack }
}

private struct ScenePackKey: EnvironmentKey { static let defaultValue: CharacterPack? = nil }

extension EnvironmentValues {
    var scenePack: CharacterPack? {
        get { self[ScenePackKey.self] }
        set { self[ScenePackKey.self] = newValue }
    }
}

struct CharacterPackContent<Content: View>: View {
    let hero: Hero
    let content: (CharacterPack?) -> Content
    @Environment(\.scenePhase) private var phase
    @State private var loaded: (hero: Hero, pack: CharacterPack?)?

    init(_ hero: Hero, @ViewBuilder content: @escaping (CharacterPack?) -> Content) {
        self.hero = hero
        self.content = content
    }

    var body: some View {
        let activeHero = phase == .background ? nil : hero
        let pack = loaded?.hero == activeHero ? loaded?.pack : nil
        content(pack).environment(\.scenePack, pack)
            .task(id: activeHero) {
                guard let activeHero else { loaded = nil; return }
                let value = await PackLoader.shared.load(activeHero)
                guard !Task.isCancelled else { return }
                loaded = (activeHero, value)
            }
    }
}

private struct PreparedArtworkKey: EnvironmentKey {
    static let defaultValue: [ArtworkRequest: UIImage]? = nil
}

extension EnvironmentValues {
    var preparedArtwork: [ArtworkRequest: UIImage]? {
        get { self[PreparedArtworkKey.self] }
        set { self[PreparedArtworkKey.self] = newValue }
    }
}

private struct ArtworkContent<Content: View>: View {
    let request: ArtworkRequest
    let content: (UIImage?) -> Content
    @Environment(\.preparedArtwork) private var prepared
    @Environment(\.scenePhase) private var phase
    @State private var loaded: (request: ArtworkRequest, image: UIImage?)?

    init(request: ArtworkRequest, @ViewBuilder content: @escaping (UIImage?) -> Content) {
        self.request = request
        self.content = content
    }

    var body: some View {
        if let prepared {
            content(prepared[request])
        } else {
            let activeRequest = phase == .background ? nil : request
            content(loaded?.request == activeRequest ? loaded?.image : nil)
                .task(id: activeRequest) {
                    guard let activeRequest else { loaded = nil; return }
                    let image = await ArtworkDecoder.shared.image(for: activeRequest)
                    guard !Task.isCancelled else { return }
                    loaded = (activeRequest, image)
                }
        }
    }
}

struct CharacterArtLayer: View {
    let hero: Hero
    let file: String

    var body: some View {
        ArtworkContent(request: ArtworkRequest(hero: hero, file: file)) { image in
            if let image {
                Image(uiImage: image).resizable().scaledToFit().accessibilityHidden(true)
            } else {
                CompanionFigure(hero: hero)
            }
        }
    }
}

private extension CharacterPack.Theme {
    var sceneColor: Color {
        guard let rgb = UInt32(accent.dropFirst(), radix: 16) else { return .indigo }
        return Color(red: Double(rgb >> 16) / 255, green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }
}

struct ShadowSummon<Figure: View>: View {
    let figure: Figure
    let contact: Date?
    let duration: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomTrailing) {
                figure.frame(width: geo.size.width * 0.74, height: geo.size.height, alignment: .bottom)
                    .clipped()
                    .frame(width: geo.size.width, alignment: .leading)
                if let contact {
                    Color.clear.modifier(ShadowArrival(progress: 1))
                        .frame(width: geo.size.width * 0.25, height: geo.size.height * 0.45)
                        .id(contact)
                        .transition(.asymmetric(insertion: .modifier(active: ShadowArrival(progress: 0), identity: ShadowArrival(progress: 1)), removal: .identity))
                }
            }
            .animation(.linear(duration: duration), value: contact)
        }
    }
}

private struct ShadowArrival: AnimatableModifier {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        GeometryReader { geo in
            let height = geo.size.height
            let phase = min(1, max(0, (progress - 0.12) / 0.64))
            let rise = phase * phase * (3 - 2 * phase)
            ZStack(alignment: .bottom) {
                Ellipse().fill(Color.black.opacity(0.9))
                    .shadow(color: .purple, radius: 2)
                    .frame(height: height * 0.14)
                    .scaleEffect(x: 0.32 + 0.68 * min(1, progress / 0.20), y: 1)
                    .opacity(min(1, progress / 0.12))
                CharacterArtLayer(hero: .jinwoo, file: "igris.png")
                    .offset(y: height * (1 - rise))
                HStack(spacing: -4) {
                    Ellipse().fill(Color.purple)
                    Ellipse().fill(Color(red: 0.63, green: 0.57, blue: 0.72))
                    Ellipse().fill(Color.indigo)
                }
                .frame(height: height * (0.10 + rise * 0.17))
                .blur(radius: 3).offset(y: -height * 0.12 * rise)
                .opacity(0.8 * sin(.pi * min(1, max(0, (progress - 0.06) / 0.89))))
            }
            .frame(width: geo.size.width, height: height, alignment: .bottom)
            .clipped()
        }
    }
}

/// A single side change drives both gates. At rest only the occupied slot is visible.
private struct PortalGate: AnimatableModifier {
    let hero: Hero
    let arriving: Bool
    let rightSide: Bool
    var departure: Double

    var animatableData: Double {
        get { departure }
        set { departure = newValue }
    }

    func body(content: Content) -> some View {
        let t = min(1, max(0, departure))
        let vanish = min(1, max(0, (t - 0.14) / 0.27))
        let gateFade = hero == .maomao && arriving ? (t - 0.22) / 0.10 : t / 0.16
        let gate = min(1, min(max(0, gateFade), max(0, (0.52 - t) / 0.14)))
        let rim = hero == .maomao ? Color(red: 1, green: 0.89, blue: 0.69) : Color(red: 0.75, green: 0.58, blue: 1)
        let colors: [Color] = hero == .maomao ? [.clear, .orange.opacity(0.18), rim] : [.black, .indigo, .purple]
        let reach = hero == .maomao && arriving ? max(0, min(1, min(t / 0.055, (0.42 - t) / 0.10))) : 0
        ZStack {
            Ellipse()
                .fill(RadialGradient(colors: colors, center: .center,
                                     startRadius: 4, endRadius: 95))
                .overlay { Ellipse().stroke(rim, lineWidth: 2) }
                .overlay {
                    if hero == .maomao {
                        Ellipse().inset(by: 5).stroke(rim.opacity(0.8), lineWidth: 1)
                            .rotationEffect(.degrees(-8))
                    }
                }
                .padding(7)
                .scaleEffect(x: 0.66 * gate, y: 0.94)
                .opacity(gate)
                .accessibilityHidden(true)
            content.opacity(1 - reach)
                .overlay {
                    if hero == .maomao && arriving {
                        CharacterArtLayer(hero: .maomao, file: "portal-leaf.png")
                            .aspectRatio(1, contentMode: .fit)
                            .scaleEffect(x: rightSide ? 0.96 : -0.96, y: 0.96, anchor: .top)
                            .clipped()
                            .rotationEffect(.degrees((rightSide ? -4 : 4) * reach), anchor: .bottom)
                            .opacity(reach).accessibilityHidden(true)
                    }
                }
                .scaleEffect(1 - vanish * 0.62).opacity(1 - vanish)
        }
    }
}

struct CompanionPortalScene<Figure: View, Caption: View>: View {
    let hero: Hero
    let right: Bool
    let duration: Double
    let figure: Figure
    let caption: Caption

    var body: some View {
        HStack(spacing: 8) {
            slot(rightSide: false)
            slot(rightSide: true)
        }
        .animation(.linear(duration: duration), value: right)
    }

    private func slot(rightSide: Bool) -> some View {
        let occupied = rightSide == right
        return ZStack(alignment: .leading) {
            figure.modifier(PortalGate(hero: hero, arriving: occupied, rightSide: rightSide, departure: occupied ? 0 : 1))
                .accessibilityHidden(true)
            if !occupied {
                caption.transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: duration * 0.13).delay(duration * 0.87)),
                    removal: .opacity.animation(.easeOut(duration: duration * 0.09))))
            }
        }.frame(maxWidth: .infinity)
    }
}

struct CharacterActionFigure<Figure: View>: View {
    let figure: Figure
    let descriptor: CharacterPack.AnimationDescriptor?
    let contactDate: Date?
    let emotion: ChibiEmotion

    @ViewBuilder var body: some View {
        if let descriptor {
            switch descriptor.id {
            case .portal: figure
            case .summon:
                ShadowSummon(figure: figure, contact: contactDate, duration: descriptor.duration)
            case .gaze:
                ZStack {
                    if let contactDate, emotion != .sleepy {
                        GojoGaze(progress: 1).id(contactDate)
                            .transition(.asymmetric(insertion: .modifier(active: GojoGazePhase(progress: 0),
                                                                         identity: GojoGazePhase(progress: 1)), removal: .identity))
                    } else { figure }
                }.animation(.linear(duration: descriptor.duration), value: contactDate)
            case .spirit:
                ZStack {
                    if let contactDate {
                        TojiSpirit(progress: 1).id(contactDate)
                            .transition(.asymmetric(insertion: .modifier(active: TojiSpiritPhase(progress: 0),
                                                                         identity: TojiSpiritPhase(progress: 1)), removal: .identity))
                    } else if emotion == .neutral { TojiSpirit(progress: 0) } else { figure }
                }.animation(.linear(duration: descriptor.duration), value: contactDate)
            case .expression:
                ZStack {
                    if let contactDate {
                        Color.clear.modifier(SukunaExpression(progress: 1)).aspectRatio(1, contentMode: .fit).id(contactDate)
                            .transition(.asymmetric(insertion: .modifier(active: SukunaExpression(progress: 0),
                                                                         identity: SukunaExpression(progress: 1)), removal: .identity))
                    } else if emotion == .neutral { Color.clear.modifier(SukunaExpression(progress: 0)) } else { figure }
                }.animation(.linear(duration: descriptor.duration), value: contactDate)
            case .fan:
                figure.overlay {
                    ZStack {
                        if let contactDate {
                            JinshiFan(opening: 1).id(contactDate)
                                .transition(.asymmetric(insertion: .modifier(active: FoldedFan(progress: 0),
                                                                             identity: FoldedFan(progress: 1)), removal: .identity))
                        }
                    }.animation(.easeInOut(duration: descriptor.duration), value: contactDate)
                        .accessibilityHidden(true)
                }
            }
        } else { figure }
    }
}

struct CompanionScene: View {
    let state: Companion
    let date: Date
    var display: Reaction? = nil
    var portrait = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePack) private var pack
    private var shown: Reaction { display ?? state.reaction(using: pack) }
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout(spacing: 12))
        let figure = CompanionFigure(hero: state.hero, portrait: portrait, emotion: shown.emotion, daytimePose: shown.daytimePose)
            .frame(maxWidth: 148).frame(height: 168)
        let caption = VStack(alignment: .leading, spacing: 6) {
            Text(state.hero.name).font(.headline)
            Text(shown.action).font(.caption)
            if !shown.text.isEmpty { Text(shown.text).font(.callout).foregroundStyle(.black).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 12)) }
        }
        let fullMotion = !portrait && state.mode == .normal && state.animationsEnabled && !reduceMotion && !typeSize.isAccessibilitySize
        let descriptor = fullMotion ? pack?.animations[.app] : nil
        return Group {
            if let descriptor, descriptor.id == .portal {
                CompanionPortalScene(hero: state.hero, right: state.contact?.portalOnRight ?? false,
                                     duration: descriptor.duration, figure: figure, caption: caption)
            } else {
                layout {
                    CharacterActionFigure(figure: figure, descriptor: descriptor,
                                          contactDate: state.contact.flatMap { $0.response == shown.id ? $0.date : nil },
                                          emotion: shown.emotion)
                        .frame(maxWidth: 148).frame(height: 168)
                    caption
                }
            }
        }
        .foregroundStyle(.white).padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .background { HeroBackdrop(hero: state.hero, date: date, mode: state.mode, daySchedule: state.daySchedule) }
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct HeroBackdrop: View {
    let hero: Hero
    let date: Date
    let mode: CompanionMode
    var daySchedule = DaySchedule()
    @Environment(\.scenePack) private var pack

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                pack?.theme.sceneColor ?? .indigo
                ArtworkContent(request: .backdrop(hero, date: date, mode: mode, schedule: daySchedule)) { art in
                    if let art { Image(uiImage: art).resizable().scaledToFill() }
                }
                LinearGradient(colors: [.black.opacity(0.12), .black.opacity(0.58)],
                               startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }.accessibilityHidden(true)
    }
}

// Original development artwork. The supplied boards are composition references only.
struct CompanionFigure: View {
    let hero: Hero

    var portrait = false
    var emotion: ChibiEmotion = .neutral
    var daytimePose = false
    var pixels = 512
    @Environment(\.scenePack) private var pack

    var body: some View {
        ArtworkContent(request: .figure(hero, portrait: portrait, emotion: emotion, daytime: daytimePose, pixels: pixels)) { illustration in
            if let illustration {
                Image(uiImage: illustration).resizable().scaledToFit().accessibilityHidden(true)
            } else { fallback }
        }
    }

    private var hair: Color {
        switch hero {
        case .gojo: return Color(red: 0.88, green: 0.90, blue: 1)
        case .toji: return Color(red: 0.15, green: 0.22, blue: 0.19)
        case .jinshi: return Color(red: 0.39, green: 0.31, blue: 0.59)
        case .jinwoo: return Color(red: 0.16, green: 0.17, blue: 0.29)
        case .sukuna: return Color(red: 0.90, green: 0.53, blue: 0.59)
        case .maomao: return Color(red: 0.17, green: 0.45, blue: 0.34)
        }
    }

    private var fallback: some View {
        Canvas { context, size in
            let scale = min(size.width / 100, size.height / 116)
            context.translateBy(x: (size.width - 100 * scale) / 2, y: (size.height - 116 * scale) / 2)
            context.scaleBy(x: scale, y: scale)
            let ink = Color(red: 0.13, green: 0.12, blue: 0.22)
            let skin = Color(red: 1, green: 0.85, blue: 0.77)
            func oval(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ color: Color) {
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: w, height: h)), with: .color(color))
            }
            func shape(_ points: [CGPoint], _ color: Color) {
                var path = Path()
                path.addLines(points)
                path.closeSubpath()
                context.fill(path, with: .color(color))
            }
            oval(24, 102, 53, 9, ink.opacity(0.25))
            oval(34, 94, 12, 15, ink)
            oval(54, 94, 12, 15, ink)
            oval(23, 63, 54, 39, pack?.theme.sceneColor ?? .indigo)
            shape([CGPoint(x: 35,y: 73), CGPoint(x: 50,y: 88), CGPoint(x: 66,y: 73)], .white.opacity(0.8))
            oval(17, 80, 14, 11, skin)
            oval(69, 80, 14, 11, skin)
            oval(9, 9, 82, 69, hair)
            if hero == .maomao || hero == .jinshi {
                oval(4, 28, 20, 27, hair)
                oval(76, 28, 20, 27, hair)
            }
            oval(16, 23, 68, 53, skin)
            for x in stride(from: 15, through: 63, by: 16) {
                shape([CGPoint(x: x,y: 27), CGPoint(x: x+22,y: 17), CGPoint(x: x+7,y: 45)], hair)
            }
            if hero == .gojo {
                context.fill(Path(roundedRect: CGRect(x: 16,y: 40,width: 68,height: 16), cornerRadius: 7), with: .color(ink))
            } else {
                for x in [31, 61] {
                    oval(Double(x), 43, 9, 13, ink)
                    oval(Double(x+2), 44, 3, 4, .white)
                }
            }
            oval(23, 57, 10, 4, .pink.opacity(0.45))
            oval(67, 57, 10, 4, .pink.opacity(0.45))
            var smile = Path()
            smile.move(to: CGPoint(x: 44,y: 61))
            smile.addQuadCurve(to: CGPoint(x: 55,y: 61), control: CGPoint(x: 50,y: 69))
            context.stroke(smile, with: .color(ink), lineWidth: 2)
        }.accessibilityHidden(true)
    }
}

private struct FoldedFan: AnimatableModifier {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        JinshiFan(opening: progress)
    }
}

private struct JinshiFan: View {
    let opening: Double

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let pivot = CGPoint(x: size.width / 2 + side * 0.10, y: size.height / 2 + side * 0.17)
            context.translateBy(x: pivot.x, y: pivot.y)
            context.rotate(by: .degrees(-18 + 10 * opening))
            let radius = side * 0.31
            let halfAngle = 4 + 59 * opening
            let gold = Color(red: 0.96, green: 0.79, blue: 0.51)
            for leaf in 0..<10 {
                let a = (-90 - halfAngle + Double(leaf) * halfAngle / 5) * .pi / 180
                let b = a + halfAngle * .pi / 900
                let outer = CGPoint(x: radius * cos(a), y: radius * sin(a))
                let next = CGPoint(x: radius * cos(b), y: radius * sin(b))
                var panel = Path()
                panel.move(to: .zero)
                panel.addLine(to: outer)
                panel.addLine(to: next)
                panel.closeSubpath()
                context.fill(panel, with: .color(leaf.isMultiple(of: 2)
                    ? Color(red: 0.52, green: 0.28, blue: 0.46)
                    : Color(red: 0.71, green: 0.46, blue: 0.60)))
                context.stroke(panel, with: .color(gold), lineWidth: side * 0.005)
            }
            context.fill(Path(ellipseIn: CGRect(x: -2, y: -2, width: 4, height: 4)), with: .color(gold))
        }
    }
}

private struct SukunaExpression: AnimatableModifier {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let chin = blend(from: 0.04, to: 0.43)
        let smile = blend(from: 0.58, to: 1)
        return ZStack {
            pose("tap-calm").opacity(1 - chin)
            pose("tap-chin").opacity(chin * (1 - smile))
            pose("tap-smirk").opacity(smile)
        }.accessibilityHidden(true)
    }

    private func blend(from start: Double, to end: Double) -> Double {
        let t = min(1, max(0, (progress - start) / (end - start)))
        return t * t * (3 - 2 * t)
    }

    private func pose(_ name: String) -> some View {
        CharacterArtLayer(hero: .sukuna, file: name + ".png")
    }
}

private struct TojiSpiritPhase: AnimatableModifier {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View { TojiSpirit(progress: progress) }
}

private struct TojiSpirit: View {
    let progress: Double

    private func blend(from start: Double, to end: Double) -> Double {
        let t = min(1, max(0, (progress * 980 - start) / (end - start)))
        return t * t * (3 - 2 * t)
    }

    var body: some View {
        let reach = blend(from: 80, to: 310)
        let lower = blend(from: 700, to: 980)
        ZStack {
            pose("spirit-idle").opacity(1 - reach)
            pose("spirit-draw").opacity(reach * (1 - lower))
            pose("spirit-blade").opacity(lower)
        }.accessibilityHidden(true)
    }

    private func pose(_ name: String) -> some View {
        CharacterArtLayer(hero: .toji, file: name + ".png")
    }
}

private struct GojoGazePhase: AnimatableModifier {
    var progress: Double
    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }
    func body(content: Content) -> some View { GojoGaze(progress: progress) }
}

private struct GojoGaze: View {
    let progress: Double

    private func layer(_ name: String, from start: Double, to end: Double) -> some View {
        let amount = min(1, max(0, (progress - start) / (end - start)))
        return CharacterArtLayer(hero: .gojo, file: name + ".png")
            .opacity(amount * amount * (3 - 2 * amount))
    }

    var body: some View {
        ZStack {
            // Complementary alpha on the moving arm avoids leaving the original hand beneath it.
            layer("chibi", from: -1, to: 0).opacity(1 - min(1, max(0, progress / 0.22)))
            layer("blindfold-touch", from: 0, to: 0.22).opacity(1 - min(1, max(0, (progress - 0.22) / 0.24)))
            layer("blindfold-gaze", from: 0.22, to: 0.46)
            layer("blindfold-smirk", from: 0.78, to: 1)
        }.accessibilityHidden(true)
    }
}
