import SwiftUI
import UniformTypeIdentifiers

/// Compact Winamp-style mini player
struct MiniPlayerView: View {
    @EnvironmentObject var appState: AppState
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // Title bar with drag area
            TitleBarView()

            // Main content
            VStack(spacing: 8) {
                // Now playing / status
                NowPlayingBar()

                // Progress bar
                MiniProgressBar()

                // Controls
                ControlsBar()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(width: 320, height: 120)
        .background(
            ZStack {
                Color.black
                LinearGradient(
                    colors: [Color.purple.opacity(0.3), Color.blue.opacity(0.2)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                // Drop highlight
                if isDropTargeted {
                    Color.blue.opacity(0.3)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isDropTargeted ? Color.blue : Color.white.opacity(0.1), lineWidth: isDropTargeted ? 2 : 1)
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers: providers)
        }
        .fileImporter(
            isPresented: $appState.showingFilePicker,
            allowedContentTypes: [
                .movie, .video, .mpeg4Movie, .quickTimeMovie, .avi,
                UTType(filenameExtension: "mkv") ?? .movie,
                UTType(filenameExtension: "webm") ?? .movie
            ],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                if url.startAccessingSecurityScopedResource() {
                    appState.loadMedia(from: url)
                }
            }
        }
    }

    /// Handle dropped files
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }

        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                return
            }

            // Check if it's a video file
            let videoExtensions = ["mp4", "mov", "m4v", "mkv", "avi", "webm", "wmv", "flv"]
            guard videoExtensions.contains(url.pathExtension.lowercased()) else { return }

            DispatchQueue.main.async {
                _ = url.startAccessingSecurityScopedResource()
                appState.loadMedia(from: url)
            }
        }

        return true
    }
}

// MARK: - Title Bar
struct TitleBarView: View {
    var body: some View {
        HStack {
            Text("LiquidCast")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))

            Spacer()

            // Window controls are handled by system
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.3))
    }
}

// MARK: - Now Playing Bar
struct NowPlayingBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)

            // File name or status
            Text(displayText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            // AirPlay indicator
            if appState.isConnectedToAirPlay {
                Image(systemName: "airplayaudio")
                    .font(.system(size: 10))
                    .foregroundColor(.green)
            }
        }
    }

    private var statusColor: Color {
        if appState.isConverting {
            return .orange
        } else if appState.isPlaying {
            return .green
        } else if appState.selectedMediaURL != nil {
            return .yellow
        } else {
            return .gray
        }
    }

    private var displayText: String {
        if appState.isConverting {
            return appState.conversionStatus
        } else if let url = appState.selectedMediaURL {
            return url.deletingPathExtension().lastPathComponent
        } else {
            return "Drop file or click +"
        }
    }
}

// MARK: - Mini Progress Bar
struct MiniProgressBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    Capsule()
                        .fill(Color.white.opacity(0.1))

                    // Progress
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: progressWidth(in: geometry))
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onEnded { value in
                            let progress = min(max(value.location.x / geometry.size.width, 0), 1)
                            appState.seek(to: progress * appState.duration)
                        }
                )
            }
            .frame(height: 4)

            // Time display
            HStack {
                Text(formatTime(appState.playbackProgress))
                Spacer()
                Text(formatTime(appState.duration))
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.5))
        }
    }

    private func progressWidth(in geometry: GeometryProxy) -> CGFloat {
        guard appState.duration > 0 else { return 0 }
        return geometry.size.width * CGFloat(appState.playbackProgress / appState.duration)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Controls Bar
struct ControlsBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 16) {
            // Open file
            MiniButton(icon: "plus") {
                appState.showingFilePicker = true
            }

            Spacer()

            // Skip back
            MiniButton(icon: "gobackward.10") {
                appState.seek(to: max(appState.playbackProgress - 10, 0))
            }
            .disabled(appState.selectedMediaURL == nil)

            // Play/Pause
            MiniButton(icon: appState.isPlaying ? "pause.fill" : "play.fill", size: 24) {
                appState.togglePlayback()
            }
            .disabled(appState.selectedMediaURL == nil)

            // Skip forward
            MiniButton(icon: "goforward.30") {
                appState.seek(to: min(appState.playbackProgress + 30, appState.duration))
            }
            .disabled(appState.selectedMediaURL == nil)

            Spacer()

            // AirPlay
            AirPlayMiniButton()
        }
    }
}

// MARK: - Mini Button
struct MiniButton: View {
    let icon: String
    var size: CGFloat = 16
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(isEnabled ? .white : .white.opacity(0.3))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AirPlay Mini Button
struct AirPlayMiniButton: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            AirPlayRoutePickerRepresentable()
                .frame(width: 20, height: 20)

            // Connection indicator
            if appState.isConnectedToAirPlay {
                Circle()
                    .fill(.green)
                    .frame(width: 5, height: 5)
                    .offset(x: 8, y: -8)
            }
        }
    }
}

#Preview {
    MiniPlayerView()
        .environmentObject(AppState())
}
