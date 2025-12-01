import SwiftUI
import AVKit

/// SwiftUI wrapper for AVRoutePickerView (AirPlay device selector)
struct AirPlayButtonView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            // Connection status indicator
            if appState.isConnectedToAirPlay {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.green)
                        .frame(width: 8, height: 8)

                    if let deviceName = appState.currentAirPlayDevice {
                        Text(deviceName)
                            .font(.caption)
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(.green.opacity(0.2))
                        .overlay(
                            Capsule()
                                .stroke(.green.opacity(0.4), lineWidth: 1)
                        )
                )
            }

            // AirPlay picker button
            LiquidGlassPill {
                HStack(spacing: 8) {
                    AirPlayRoutePickerRepresentable()
                        .frame(width: 24, height: 24)

                    Text("AirPlay")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Platform-specific AVRoutePickerView wrapper

#if os(macOS)
import AppKit

struct AirPlayRoutePickerRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(.white, for: .normal)
        picker.setRoutePickerButtonColor(.white.withAlphaComponent(0.6), for: .highlighted)
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}

#else
import UIKit

struct AirPlayRoutePickerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue

        // Style the button
        if let button = picker.subviews.first(where: { $0 is UIButton }) as? UIButton {
            button.tintColor = .white
        }

        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        AirPlayButtonView()
            .environmentObject(AppState())
    }
}
