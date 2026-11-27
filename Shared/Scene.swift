import SwiftUI

extension Hero {
    var sceneSymbol: String { pack?.theme.symbol ?? "sparkles" }
    var sceneColor: Color {
        guard let hex = pack?.theme.accent, let rgb = UInt32(hex.dropFirst(), radix: 16) else { return .indigo }
        return Color(red: Double(rgb >> 16) / 255, green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }
}

struct ShadowSummon<Figure: View>: View {
    let figure: Figure
    let contact: Date?
    let animate: Bool

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
            .animation(animate ? .linear(duration: 1.4) : nil, value: contact)
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
                Image("Characters/sung_jinwoo/igris.png").resizable().scaledToFit()
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
                        Image("Characters/maomao/portal-leaf.png").resizable().scaledToFit()
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
    let figure: Figure
    let caption: Caption

    var body: some View {
        HStack(spacing: 8) {
            slot(rightSide: false)
            slot(rightSide: true)
        }
        .animation(.linear(duration: 1.4), value: right)
    }

    private func slot(rightSide: Bool) -> some View {
        let occupied = rightSide == right
        return ZStack(alignment: .leading) {
            figure.modifier(PortalGate(hero: hero, arriving: occupied, rightSide: rightSide, departure: occupied ? 0 : 1))
                .accessibilityHidden(true)
            if !occupied {
                caption.transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.18).delay(1.22)),
                    removal: .opacity.animation(.easeOut(duration: 0.12))))
            }
        }.frame(maxWidth: .infinity)
    }
}

struct CompanionScene: View {
    let state: Companion
    let date: Date
    var display: Reaction? = nil
    var portrait = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var shown: Reaction { display ?? state.reaction }
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout(spacing: 12))
        let figure = CompanionFigure(hero: state.hero, portrait: portrait, emotion: shown.emotion, daytimePose: shown.daytimePose)
            .frame(maxWidth: 148).frame(height: 168)
        let caption = VStack(alignment: .leading, spacing: 6) {
            Text(state.hero.name).font(.headline)
            Text(shown.action).font(.caption)
            if !shown.text.isEmpty { Text(shown.text).font(.callout).foregroundStyle(.black).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 12)) }
        }
        return Group {
            if state.hero == .jinwoo && state.mode == .normal && !typeSize.isAccessibilitySize {
                layout {
                    ShadowSummon(figure: figure, contact: state.contact.flatMap { $0.response == shown.id ? $0.date : nil }, animate: !reduceMotion)
                        .frame(maxWidth: 148).frame(height: 168)
                    caption
                }
            } else if state.hero == .maomao && state.mode == .normal && !reduceMotion && !typeSize.isAccessibilitySize {
                CompanionPortalScene(hero: state.hero, right: state.contact?.portalOnRight ?? false, figure: figure, caption: caption)
            } else {
                layout { figure; caption }
            }
        }
        .foregroundStyle(.white).padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .background { HeroBackdrop(hero: state.hero, date: date, mode: state.mode) }
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

struct HeroBackdrop: View {
    let hero: Hero
    let date: Date
    let mode: CompanionMode

    private var artwork: UIImage? {
        let directory = "Characters/" + hero.rawValue + "/"
        if mode == .normal || mode == .eco {
            let variant: String?
            switch DayPeriod(hour: Calendar.current.component(.hour, from: date)) {
            case .morning, .day: variant = "scene-day.jpg"
            case .night, .lateNight: variant = "scene-night.jpg"
            case .dawn, .evening: variant = nil
            }
            if let variant, let image = UIImage(named: directory + variant) { return image }
        }
        return UIImage(named: directory + "scene.jpg")
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                hero.sceneColor
                if let art = artwork {
                    Image(uiImage: art).resizable().scaledToFill()
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

    var body: some View {
        let name = portrait ? "portrait" : (daytimePose ? "chibi-daytime" : (emotion == .neutral ? "chibi" : "chibi-" + emotion.rawValue))
        if let illustration = UIImage(named: "Characters/" + hero.rawValue + "/" + name + ".png") {
            Image(uiImage: illustration).resizable().scaledToFit().accessibilityHidden(true)
        } else {
            fallback
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
            oval(23, 63, 54, 39, hero.sceneColor)
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
