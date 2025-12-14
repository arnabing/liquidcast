#if os(macOS)
import SwiftUI
import ScreenCaptureKit

/// Google Meet-style window picker with live thumbnails
struct WindowPickerView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var captureManager = ScreenCaptureManager()
    @State private var selectedTab: PickerTab = .windows
    @State private var isLoading = true
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    enum PickerTab: String, CaseIterable {
        case windows = "Windows"
        case screens = "Screens"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            Divider()
                .background(.white.opacity(0.2))

            // Tab selector
            tabSelector
                .padding(.vertical, 12)

            // Content
            if isLoading {
                loadingView
            } else if let error = errorMessage {
                errorView(error)
            } else {
                contentGrid
            }

            Divider()
                .background(.white.opacity(0.2))

            // Footer
            footer
        }
        .frame(width: 700, height: 500)
        .background(
            Color(red: 0.1, green: 0.1, blue: 0.15)
                .opacity(0.95)
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.2), lineWidth: 1)
        )
        .task {
            await loadContent()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Choose what to share")
                .font(.headline)
                .foregroundColor(.white)

            Spacer()

            Button(action: { dismiss() }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
    }

    // MARK: - Tab Selector

    private var tabSelector: some View {
        HStack(spacing: 0) {
            ForEach(PickerTab.allCases, id: \.self) { tab in
                Button(action: { selectedTab = tab }) {
                    Text(tab.rawValue)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(selectedTab == tab ? .white : .white.opacity(0.5))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(
                            Group {
                                if selectedTab == tab {
                                    Capsule()
                                        .fill(.white.opacity(0.15))
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Content Grid

    private var contentGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 180, maximum: 220), spacing: 16)
                ],
                spacing: 16
            ) {
                switch selectedTab {
                case .windows:
                    ForEach(captureManager.availableWindows, id: \.windowID) { window in
                        WindowThumbnail(
                            window: window,
                            isSelected: captureManager.selectedWindow?.windowID == window.windowID
                        ) {
                            captureManager.selectedWindow = window
                            captureManager.selectedDisplay = nil
                        }
                    }
                case .screens:
                    ForEach(captureManager.availableDisplays, id: \.displayID) { display in
                        DisplayThumbnail(
                            display: display,
                            isSelected: captureManager.selectedDisplay?.displayID == display.displayID
                        ) {
                            captureManager.selectedDisplay = display
                            captureManager.selectedWindow = nil
                        }
                    }
                }
            }
            .padding(16)
        }
    }

    // MARK: - Loading View

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(.white)

            Text("Loading available windows...")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Error View

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundColor(.orange)

            Text(message)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button("Open System Preferences") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button("Cancel") {
                dismiss()
            }
            .buttonStyle(.plain)
            .foregroundColor(.white.opacity(0.8))

            Spacer()

            Button(action: startCapture) {
                Text("Share")
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(hasSelection ? Color.blue : Color.blue.opacity(0.3))
                    )
            }
            .buttonStyle(.plain)
            .disabled(!hasSelection)
        }
        .padding(16)
    }

    // MARK: - Helpers

    private var hasSelection: Bool {
        captureManager.selectedWindow != nil || captureManager.selectedDisplay != nil
    }

    private func loadContent() async {
        do {
            try await captureManager.refreshAvailableContent()
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func startCapture() {
        Task {
            do {
                if let window = captureManager.selectedWindow {
                    try await captureManager.startCapture(window: window)
                } else if let display = captureManager.selectedDisplay {
                    try await captureManager.startCapture(display: display)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Window Thumbnail

struct WindowThumbnail: View {
    let window: SCWindow
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                // Thumbnail
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.3))
                        .aspectRatio(16/10, contentMode: .fit)

                    if let thumbnail = thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .padding(4)
                    } else {
                        // App icon as fallback
                        if let appIcon = window.owningApplication?.icon {
                            Image(nsImage: appIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 48, height: 48)
                        } else {
                            Image(systemName: "rectangle")
                                .font(.system(size: 32))
                                .foregroundColor(.white.opacity(0.4))
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.blue : Color.white.opacity(0.2), lineWidth: isSelected ? 3 : 1)
                )

                // Window title and app name
                VStack(spacing: 2) {
                    Text(window.title ?? "Untitled")
                        .font(.caption)
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(window.owningApplication?.applicationName ?? "Unknown")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .task {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        do {
            // Create a filter for just this window
            let filter = SCContentFilter(desktopIndependentWindow: window)

            // Configure the screenshot
            let config = SCStreamConfiguration()
            config.width = 400  // Thumbnail size
            config.height = 250
            config.scalesToFit = true

            // Capture the screenshot using ScreenCaptureKit
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: config
            )

            thumbnail = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        } catch {
            // Silently fail - will show app icon as fallback
        }
    }
}

// MARK: - Display Thumbnail

struct DisplayThumbnail: View {
    let display: SCDisplay
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(
                            LinearGradient(
                                colors: [.blue.opacity(0.3), .purple.opacity(0.3)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .aspectRatio(16/10, contentMode: .fit)

                    Image(systemName: "display")
                        .font(.system(size: 40))
                        .foregroundColor(.white.opacity(0.6))
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isSelected ? Color.blue : Color.white.opacity(0.2), lineWidth: isSelected ? 3 : 1)
                )

                Text("Display \(display.displayID)")
                    .font(.caption)
                    .foregroundColor(.white)

                Text("\(display.width) × \(display.height)")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.5))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - SCWindow Extension for Icon

extension SCRunningApplication {
    var icon: NSImage? {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: appURL.path)
    }
}

#Preview {
    WindowPickerView()
        .environmentObject(AppState())
}
#endif
