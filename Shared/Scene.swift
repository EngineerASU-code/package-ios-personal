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
    private var shown: Reaction { display ?? state.reaction }
    var body: some View {
        HStack {
            Image(systemName: state.hero.sceneSymbol).font(.largeTitle).foregroundStyle(.cyan).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(state.hero.name).font(.headline)
                Text(shown.action).font(.caption)
                if !shown.text.isEmpty { Text(shown.text).font(.callout) }
            }
        }
        .foregroundStyle(.white).padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [state.hero.sceneColor, Color(red: 0.08, green: 0.08, blue: 0.18)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }
}
