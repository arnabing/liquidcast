import SwiftUI

/// Toggle between Highest Quality (AVPlayer) and High Quality (ScreenCapture) modes
struct ModeSwitcher: View {
    @EnvironmentObject var appState: AppState
    @Namespace private var animation

    var body: some View {
        LiquidGlassPill {
            HStack(spacing: 4) {
                ForEach(CastingMode.allCases, id: \.self) { mode in
                    ModeButton(
                        mode: mode,
                        isSelected: appState.castingMode == mode,
                        namespace: animation
                    ) {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            appState.saveCastingMode(mode)
                        }
                    }
                }
            }
            .padding(4)
        }
    }
}

struct ModeButton: View {
    let mode: CastingMode
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: mode.icon)
                    .font(.subheadline)

                #if os(macOS)
                Text(mode.rawValue)
                    .font(.subheadline)
                    .fontWeight(.medium)
                #endif
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.6))
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                Group {
                    if isSelected {
                        Capsule()
                            .fill(.white.opacity(0.2))
                            .matchedGeometryEffect(id: "selectedMode", in: namespace)
                    }
                }
            )
        }
        .buttonStyle(.plain)
        .help(mode.description)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        ModeSwitcher()
            .environmentObject(AppState())
    }
}
