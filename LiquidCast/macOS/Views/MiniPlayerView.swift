import SwiftUI
import UniformTypeIdentifiers

/// Media player with glass UI
struct MiniPlayerView: View {
    @EnvironmentObject var appState: AppState
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // Glass title bar
            TitleBarView()

            // Main content
            VStack(spacing: 12) {
                // Now playing info
                NowPlayingBar()

                // Status section (when converting/streaming)
                if appState.isConverting || appState.isStreaming {
                    StatusView()
                }

                Spacer(minLength: 0)

                // Progress bar
                PlaybackProgressBar()

                // Controls
                ControlsBar()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .frame(width: 500, height: 220)
        .background(
            ZStack {
                // Glass material background
                Color.clear
                    .background(.ultraThinMaterial)

                // Subtle gradient overlay for depth
                LinearGradient(
                    colors: [Color.purple.opacity(0.15), Color.blue.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                // Drop highlight
                if isDropTargeted {
                    Color.blue.opacity(0.2)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isDropTargeted ? Color.blue : Color.white.opacity(0.15), lineWidth: isDropTargeted ? 2 : 1)
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

// MARK: - Glass Title Bar
struct TitleBarView: View {
    var body: some View {
        HStack {
            Text("LiquidCast")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary.opacity(0.7))

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Now Playing Bar
struct NowPlayingBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator dot
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            // File name
            VStack(alignment: .leading, spacing: 2) {
                if let url = appState.selectedMediaURL {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(url.pathExtension.uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                } else {
                    Text("Drop video file or click +")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // AirPlay status
            if appState.isConnectedToAirPlay {
                HStack(spacing: 4) {
                    Image(systemName: "airplayaudio")
                        .font(.system(size: 12))
                    if let device = appState.currentAirPlayDevice {
                        Text(device)
                            .font(.system(size: 11))
                    }
                }
                .foregroundColor(.green)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.15))
                .clipShape(Capsule())
            }
        }
    }

    private var statusColor: Color {
        if appState.isConverting {
            return .orange
        } else if appState.isStreaming {
            return .cyan
        } else if appState.isPlaying {
            return .green
        } else if appState.selectedMediaURL != nil {
            return .yellow
        } else {
            return .gray
        }
    }
}

// MARK: - Status View (Converting/Streaming)
struct StatusView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            // Spinning indicator
            ProgressView()
                .scaleEffect(0.8)
                .frame(width: 16, height: 16)

            // Status message
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(statusColor)

                if !appState.conversionStatus.isEmpty && appState.conversionStatus != statusTitle {
                    Text(appState.conversionStatus)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            // Progress percentage (if available)
            if appState.conversionProgress > 0 && appState.conversionProgress < 1 {
                Text("\(Int(appState.conversionProgress * 100))%")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(statusColor)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(statusColor.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusTitle: String {
        if appState.isConverting {
            return "Converting..."
        } else if appState.isStreaming {
            return "Streaming"
        } else {
            return ""
        }
    }

    private var statusColor: Color {
        appState.isConverting ? .orange : .cyan
    }
}

// MARK: - Playback Progress Bar
struct PlaybackProgressBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(Color.primary.opacity(0.1))

                    // Progress fill
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
            .frame(height: 6)

            // Time display
            HStack {
                Text(formatTime(appState.playbackProgress))
                Spacer()
                Text(formatTime(appState.duration))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
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
        HStack(spacing: 20) {
            // Open file
            ControlButton(icon: "plus.circle.fill", size: 20) {
                appState.showingFilePicker = true
            }

            Spacer()

            // Skip back
            ControlButton(icon: "gobackward.10", size: 18) {
                appState.seek(to: max(appState.playbackProgress - 10, 0))
            }
            .disabled(appState.selectedMediaURL == nil)

            // Play/Pause (larger)
            ControlButton(icon: appState.isPlaying ? "pause.circle.fill" : "play.circle.fill", size: 32) {
                appState.togglePlayback()
            }
            .disabled(appState.selectedMediaURL == nil)

            // Skip forward
            ControlButton(icon: "goforward.30", size: 18) {
                appState.seek(to: min(appState.playbackProgress + 30, appState.duration))
            }
            .disabled(appState.selectedMediaURL == nil)

            Spacer()

            // AirPlay button
            AirPlayMiniButton()
        }
    }
}

// MARK: - Control Button
struct ControlButton: View {
    let icon: String
    var size: CGFloat = 18
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(isEnabled ? .primary : .primary.opacity(0.3))
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
                .frame(width: 24, height: 24)

            // Connection indicator
            if appState.isConnectedToAirPlay {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .offset(x: 10, y: -10)
            }
        }
    }
}

#Preview {
    MiniPlayerView()
        .environmentObject(AppState())
}
