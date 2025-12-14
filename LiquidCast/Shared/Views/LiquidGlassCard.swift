import SwiftUI

/// A liquid glass effect card using Apple's native Liquid Glass API (iOS 26+ / macOS 26+)
struct LiquidGlassCard<Content: View>: View {
    @ViewBuilder let content: Content
    var cornerRadius: CGFloat = 24

    var body: some View {
        content
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

/// A smaller liquid glass pill/button style using Apple's native Liquid Glass API
struct LiquidGlassPill<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .glassEffect(.regular, in: .capsule)
    }
}

/// Interactive glass button style
struct LiquidGlassButton<Content: View>: View {
    @ViewBuilder let content: Content
    var cornerRadius: CGFloat = 12

    var body: some View {
        content
            .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: cornerRadius))
    }
}

#Preview {
    GlassEffectContainer {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.12),
                    Color(red: 0.1, green: 0.1, blue: 0.2)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 20) {
                LiquidGlassCard {
                    Text("Liquid Glass Card")
                        .foregroundColor(.white)
                        .padding(40)
                }

                LiquidGlassPill {
                    Text("Pill Button")
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                }
            }
        }
    }
}
