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
    var onRoutePickerWillBegin: (() -> Void)?
    var onRoutePickerDidEnd: (() -> Void)?

    class Coordinator: NSObject, AVRoutePickerViewDelegate {
        var picker: AVRoutePickerView?
        var notificationObserver: NSObjectProtocol?
        var onRoutePickerWillBegin: (() -> Void)?
        var onRoutePickerDidEnd: (() -> Void)?

        deinit {
            if let observer = notificationObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        func setupNotificationObserver() {
            notificationObserver = NotificationCenter.default.addObserver(
                forName: Notification.Name("triggerAirPlayPicker"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.triggerPicker()
            }
        }

        func triggerPicker() {
            guard let picker = picker else { return }
            // Find and click the button inside AVRoutePickerView
            for subview in picker.subviews {
                if let button = subview as? NSButton {
                    button.performClick(nil)
                    return
                }
            }
        }

        // MARK: - AVRoutePickerViewDelegate

        func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            onRoutePickerWillBegin?()
        }

        func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
            onRoutePickerDidEnd?()
        }
    }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.onRoutePickerWillBegin = onRoutePickerWillBegin
        coordinator.onRoutePickerDidEnd = onRoutePickerDidEnd
        return coordinator
    }

    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.delegate = context.coordinator
        // Use label color for visibility in both light and dark mode
        picker.setRoutePickerButtonColor(.labelColor, for: .normal)
        picker.setRoutePickerButtonColor(.secondaryLabelColor, for: .activeHighlighted)

        // Store reference and setup observer
        context.coordinator.picker = picker
        context.coordinator.setupNotificationObserver()

        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {
        context.coordinator.picker = nsView
        context.coordinator.onRoutePickerWillBegin = onRoutePickerWillBegin
        context.coordinator.onRoutePickerDidEnd = onRoutePickerDidEnd
    }
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
