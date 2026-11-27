import SwiftUI

extension Hero {
    var sceneSymbol: String { pack?.theme.symbol ?? "sparkles" }
    var sceneColor: Color {
        guard let hex = pack?.theme.accent, let rgb = UInt32(hex.dropFirst(), radix: 16) else { return .indigo }
        return Color(red: Double(rgb >> 16) / 255, green: Double((rgb >> 8) & 255) / 255,
                     blue: Double(rgb & 255) / 255)
    }
}

struct CompanionScene: View {
    let state: Companion
    var display: Reaction? = nil
    var portrait = false
    @Environment(\.dynamicTypeSize) private var typeSize
    private var shown: Reaction { display ?? state.reaction }
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading)) : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            CompanionFigure(hero: state.hero, portrait: portrait, emotion: shown.emotion).frame(maxWidth: 148).frame(height: 168)
            VStack(alignment: .leading, spacing: 6) {
                Text(state.hero.name).font(.headline)
                Text(shown.action).font(.caption)
                if !shown.text.isEmpty { Text(shown.text).font(.callout).foregroundStyle(.black).padding(8).background(.white, in: RoundedRectangle(cornerRadius: 12)) }
            }
        }
        .foregroundStyle(.white).padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .background(LinearGradient(colors: [state.hero.sceneColor.opacity(0.74), Color(red: 0.08, green: 0.08, blue: 0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .background(Color.black).clipShape(RoundedRectangle(cornerRadius: 18))
    }
}

// Original development artwork. The supplied boards are composition references only.
struct CompanionFigure: View {
    let hero: Hero

    var portrait = false
    var emotion: ChibiEmotion = .neutral

    var body: some View {
        let name = portrait ? "portrait" : (emotion == .neutral ? "chibi" : "chibi-" + emotion.rawValue)
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
