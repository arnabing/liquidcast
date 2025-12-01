import SwiftUI

/// A liquid glass effect card with blur and subtle borders
struct LiquidGlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(
                ZStack {
                    // Ultra thin material for blur effect
                    RoundedRectangle(cornerRadius: 24)
                        .fill(.ultraThinMaterial)

                    // Subtle gradient overlay
                    RoundedRectangle(cornerRadius: 24)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.1),
                                    .white.opacity(0.05),
                                    .clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    // Inner glow/reflection at top
                    RoundedRectangle(cornerRadius: 24)
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.15),
                                    .clear
                                ],
                                startPoint: .top,
                                endPoint: .center
                            )
                        )
                        .mask(
                            VStack {
                                Rectangle()
                                    .frame(height: 60)
                                Spacer()
                            }
                        )
                }
            )
            .overlay(
                // Border with gradient
                RoundedRectangle(cornerRadius: 24)
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.4),
                                .white.opacity(0.1),
                                .white.opacity(0.05)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
    }
}

/// A smaller liquid glass pill/button style
struct LiquidGlassPill<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .background(
                ZStack {
                    Capsule()
                        .fill(.ultraThinMaterial)

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.15),
                                    .white.opacity(0.05)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }
            )
            .overlay(
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.3),
                                .white.opacity(0.1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            )
            .clipShape(Capsule())
    }
}

/// Animated liquid effect modifier
struct LiquidEffect: ViewModifier {
    @State private var animating = false

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geometry in
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: [
                                    .white.opacity(0.1),
                                    .clear
                                ],
                                center: .center,
                                startRadius: 0,
                                endRadius: geometry.size.width * 0.5
                            )
                        )
                        .scaleEffect(animating ? 1.5 : 1.0)
                        .offset(
                            x: animating ? geometry.size.width * 0.3 : -geometry.size.width * 0.2,
                            y: animating ? -geometry.size.height * 0.2 : geometry.size.height * 0.3
                        )
                        .opacity(0.5)
                        .animation(
                            .easeInOut(duration: 8)
                            .repeatForever(autoreverses: true),
                            value: animating
                        )
                }
                .clipped()
            )
            .onAppear {
                animating = true
            }
    }
}

extension View {
    func liquidEffect() -> some View {
        modifier(LiquidEffect())
    }
}

#Preview {
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
