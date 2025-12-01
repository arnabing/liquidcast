import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ZStack {
            // Background gradient
            BackgroundView()

            // Main content
            VStack(spacing: 0) {
                // Header with mode switcher
                HeaderView()
                    .padding(.horizontal, 24)
                    .padding(.top, 16)

                Spacer()

                // Center content - Player or placeholder
                CenterContentView()

                Spacer()

                // Bottom controls
                BottomControlsView()
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
            }
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 600)
        #endif
    }
}

// MARK: - Background

struct BackgroundView: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.05, blue: 0.12),
                Color(red: 0.08, green: 0.08, blue: 0.18),
                Color(red: 0.05, green: 0.05, blue: 0.15)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

// MARK: - Header

struct HeaderView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack {
            // App title
            Text("LiquidCast")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, .white.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            Spacer()

            // Mode switcher
            ModeSwitcher()

            Spacer()

            // AirPlay button
            AirPlayButtonView()
        }
    }
}

// MARK: - Center Content

struct CenterContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        LiquidGlassCard {
            if let url = appState.selectedMediaURL {
                PlayerContainerView(url: url)
            } else {
                EmptyStateView()
            }
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "play.circle")
                .font(.system(size: 80, weight: .ultraLight))
                .foregroundColor(.white.opacity(0.4))

            VStack(spacing: 8) {
                Text("No Media Selected")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                Text("Open a video file to start casting")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.6))
            }

            Button(action: { appState.showingFilePicker = true }) {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                    Text("Open File")
                }
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(.white.opacity(0.15))
                        .overlay(
                            Capsule()
                                .stroke(.white.opacity(0.3), lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 300)
    }
}

// MARK: - Player Container

struct PlayerContainerView: View {
    let url: URL
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 16) {
            // Video player
            VideoPlayerView(player: appState.mediaPlayer.player)
                .aspectRatio(16/9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            // File name
            HStack {
                Image(systemName: "film")
                    .foregroundColor(.white.opacity(0.6))
                Text(url.lastPathComponent)
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding(16)
    }
}

// MARK: - Video Player Wrapper

struct VideoPlayerView: View {
    let player: AVPlayer?

    var body: some View {
        if let player = player {
            VideoPlayer(player: player)
        } else {
            Rectangle()
                .fill(Color.black.opacity(0.5))
                .overlay(
                    ProgressView()
                        .tint(.white)
                )
        }
    }
}

// MARK: - Bottom Controls

struct BottomControlsView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        LiquidGlassCard {
            VStack(spacing: 16) {
                // Progress bar
                ProgressBarView()

                // Control buttons
                HStack(spacing: 32) {
                    // Open file button
                    ControlButton(icon: "folder", label: "Open") {
                        appState.showingFilePicker = true
                    }

                    #if os(macOS)
                    // Window capture button (macOS only)
                    if appState.castingMode == .highQuality {
                        ControlButton(icon: "rectangle.on.rectangle", label: "Window") {
                            appState.showingWindowPicker = true
                        }
                    }
                    #endif

                    Spacer()

                    // Playback controls
                    PlaybackControls()

                    Spacer()

                    // Volume control
                    VolumeControl()
                }
            }
            .padding(20)
        }
        .fileImporter(
            isPresented: $appState.showingFilePicker,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie, .avi],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                // Start accessing security-scoped resource
                if url.startAccessingSecurityScopedResource() {
                    appState.loadMedia(from: url)
                }
            }
        case .failure(let error):
            print("File selection error: \(error)")
        }
    }
}

// MARK: - Progress Bar

struct ProgressBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var isDragging = false

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(.white.opacity(0.2))
                        .frame(height: 4)

                    // Progress fill
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: progressWidth(in: geometry), height: 4)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let progress = min(max(value.location.x / geometry.size.width, 0), 1)
                            appState.playbackProgress = progress * appState.duration
                        }
                        .onEnded { value in
                            isDragging = false
                            let progress = min(max(value.location.x / geometry.size.width, 0), 1)
                            appState.seek(to: progress * appState.duration)
                        }
                )
            }
            .frame(height: 4)

            // Time labels
            HStack {
                Text(formatTime(appState.playbackProgress))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .monospacedDigit()

                Spacer()

                Text(formatTime(appState.duration))
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                    .monospacedDigit()
            }
        }
    }

    private func progressWidth(in geometry: GeometryProxy) -> CGFloat {
        guard appState.duration > 0 else { return 0 }
        let progress = appState.playbackProgress / appState.duration
        return geometry.size.width * CGFloat(progress)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        let secs = Int(seconds) % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        } else {
            return String(format: "%d:%02d", minutes, secs)
        }
    }
}

// MARK: - Playback Controls

struct PlaybackControls: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 24) {
            // Skip backward
            Button(action: { skipBackward() }) {
                Image(systemName: "gobackward.10")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.plain)

            // Play/Pause
            Button(action: { appState.togglePlayback() }) {
                Image(systemName: appState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)

            // Skip forward
            Button(action: { skipForward() }) {
                Image(systemName: "goforward.30")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.plain)
        }
    }

    private func skipBackward() {
        let newTime = max(appState.playbackProgress - 10, 0)
        appState.seek(to: newTime)
    }

    private func skipForward() {
        let newTime = min(appState.playbackProgress + 30, appState.duration)
        appState.seek(to: newTime)
    }
}

// MARK: - Volume Control

struct VolumeControl: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: volumeIcon)
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 20)

            Slider(value: $appState.volume, in: 0...1)
                .tint(.white.opacity(0.6))
                .frame(width: 80)
                .onChange(of: appState.volume) { _, newValue in
                    appState.setVolume(newValue)
                }
        }
    }

    private var volumeIcon: String {
        if appState.volume == 0 {
            return "speaker.slash.fill"
        } else if appState.volume < 0.5 {
            return "speaker.wave.1.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}

// MARK: - Control Button

struct ControlButton: View {
    let icon: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.title3)
                Text(label)
                    .font(.caption2)
            }
            .foregroundColor(.white.opacity(0.8))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
