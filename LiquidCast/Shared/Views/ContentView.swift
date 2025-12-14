import SwiftUI
import AVKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var showingSettings = false

    var body: some View {
        GlassEffectContainer {
            ZStack {
                // Background gradient
                BackgroundView()

                // Main content
                VStack(spacing: 0) {
                    // Minimal header
                    MinimalHeaderView(showingSettings: $showingSettings)
                        .padding(.horizontal, 24)
                        .padding(.top, 16)

                    Spacer()

                    // Center content - conversion, file info, or empty state (mutually exclusive)
                    if appState.isConverting {
                        // Show conversion progress instead of NowPlayingView
                        ConversionOverlayView(
                            progress: appState.conversionProgress,
                            status: appState.conversionStatus,
                            fileName: appState.transcodeManager.currentFileName,
                            onCancel: { appState.cancelConversion() }
                        )
                    } else if appState.selectedMediaURL != nil {
                        NowPlayingView()
                    } else {
                        EmptyStateView()
                    }

                    Spacer()

                    // Bottom playback bar (Apple Music style)
                    PlaybackBarView()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 16)
                }

                // Conversion error overlay
                if let error = appState.conversionError {
                    Color.black.opacity(0.5)
                        .ignoresSafeArea()

                    ConversionErrorView(
                        errorMessage: error,
                        onDismiss: { appState.conversionError = nil },
                        onRetry: {
                            appState.conversionError = nil
                            if let url = appState.selectedMediaURL {
                                appState.loadMedia(from: url)
                            }
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(appState)
        }
        #if os(macOS)
        .frame(minWidth: 500, minHeight: 400)
        #endif
    }
}

// MARK: - Background

struct BackgroundView: View {
    var body: some View {
        ZStack {
            // Base dark
            Color(red: 0.05, green: 0.05, blue: 0.1)

            // Large colorful blobs for liquid glass effect
            Circle()
                .fill(Color.purple.opacity(0.4))
                .frame(width: 500, height: 500)
                .blur(radius: 100)
                .offset(x: -150, y: -200)

            Circle()
                .fill(Color.blue.opacity(0.3))
                .frame(width: 600, height: 600)
                .blur(radius: 120)
                .offset(x: 200, y: 100)

            Circle()
                .fill(Color.pink.opacity(0.25))
                .frame(width: 400, height: 400)
                .blur(radius: 80)
                .offset(x: -100, y: 300)

            Circle()
                .fill(Color.cyan.opacity(0.2))
                .frame(width: 350, height: 350)
                .blur(radius: 70)
                .offset(x: 180, y: -180)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Minimal Header

struct MinimalHeaderView: View {
    @Binding var showingSettings: Bool

    var body: some View {
        HStack {
            // App title
            Text("LiquidCast")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, .white.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

            Spacer()

            // Settings button
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            if appState.isDeviceReady {
                // Device is connected or remembered - show file picker prompt
                DeviceReadyView()
            } else {
                // No device - prompt to connect first
                ConnectDeviceView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Connect Device View (No device connected)

struct ConnectDeviceView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "airplayvideo")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundColor(.white.opacity(0.4))

            VStack(spacing: 8) {
                Text("Connect to AirPlay")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                Text("Select a TV to start casting")
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.6))
            }

            // Prominent AirPlay button
            LiquidGlassPill {
                HStack(spacing: 12) {
                    AirPlayRoutePickerRepresentable()
                        .frame(width: 28, height: 28)

                    Text("Select Device")
                        .font(.headline)
                        .foregroundColor(.white)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
        }
    }
}

// MARK: - Device Ready View (Device connected or remembered)

struct DeviceReadyView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundColor(.white.opacity(0.4))

            VStack(spacing: 8) {
                Text("Ready to Cast")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)

                if let deviceName = appState.currentAirPlayDevice {
                    Text("Drop a video to stream to")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))

                    HStack(spacing: 6) {
                        Image(systemName: appState.compatibilityMode.icon)
                            .font(.caption)
                        Text(deviceName)
                            .font(.subheadline)
                            .fontWeight(.medium)
                    }
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(.white.opacity(0.1))
                    )
                } else {
                    Text("Open a video file to start streaming")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.6))
                }
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
    }
}

// MARK: - Now Playing View

struct NowPlayingView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 32) {
            // Large media icon
            LiquidGlassCard(cornerRadius: 32) {
                Image(systemName: "film.fill")
                    .font(.system(size: 80, weight: .light))
                    .foregroundColor(.white.opacity(0.6))
                    .frame(width: 200, height: 200)
            }

            // File name
            if let url = appState.selectedMediaURL {
                VStack(spacing: 8) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)

                    Text(url.pathExtension.uppercased())
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.white.opacity(0.5))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill(.white.opacity(0.1))
                        )
                }
                .padding(.horizontal, 40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Playback Bar (Apple Music Style)

struct PlaybackBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        LiquidGlassCard(cornerRadius: 20) {
            VStack(spacing: 12) {
                // Progress bar
                ProgressBarView()

                // Controls row
                HStack(spacing: 16) {
                    // Open file button
                    BarButton(icon: "folder.fill") {
                        appState.showingFilePicker = true
                    }

                    #if os(macOS)
                    // Window capture (macOS only, high quality mode)
                    if appState.castingMode == .highQuality {
                        BarButton(icon: "rectangle.on.rectangle") {
                            appState.showingWindowPicker = true
                        }
                    }
                    #endif

                    Spacer()

                    // Playback controls
                    PlaybackControls()

                    Spacer()

                    // Volume
                    VolumeControl()

                    // AirPlay button
                    AirPlayCompactButton()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .fileImporter(
            isPresented: $appState.showingFilePicker,
            allowedContentTypes: [
                .movie, .video, .mpeg4Movie, .quickTimeMovie, .avi,
                UTType(filenameExtension: "mkv") ?? .movie,
                UTType(filenameExtension: "webm") ?? .movie,
                UTType(filenameExtension: "flv") ?? .movie,
                UTType(filenameExtension: "wmv") ?? .movie
            ],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
    }

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
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
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.6))
                    .monospacedDigit()

                Spacer()

                Text(formatTime(appState.duration))
                    .font(.caption2)
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
        HStack(spacing: 20) {
            // Skip backward
            Button(action: { skipBackward() }) {
                Image(systemName: "gobackward.10")
                    .font(.title3)
                    .foregroundColor(.white.opacity(0.8))
            }
            .buttonStyle(.plain)

            // Play/Pause
            Button(action: { appState.togglePlayback() }) {
                Image(systemName: appState.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)

            // Skip forward
            Button(action: { skipForward() }) {
                Image(systemName: "goforward.30")
                    .font(.title3)
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
        HStack(spacing: 6) {
            Image(systemName: volumeIcon)
                .font(.caption)
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 16)

            Slider(value: $appState.volume, in: 0...1)
                .tint(.white.opacity(0.6))
                .frame(width: 60)
                .onChange(of: appState.volume) { newValue in
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

// MARK: - Bar Button

struct BarButton: View {
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.white.opacity(0.8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - AirPlay Compact Button

struct AirPlayCompactButton: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 8) {
            // Connection indicator
            if appState.isConnectedToAirPlay {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
            }

            // AirPlay picker
            AirPlayRoutePickerRepresentable()
                .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(appState.isConnectedToAirPlay ? .green.opacity(0.2) : .white.opacity(0.1))
                .overlay(
                    Capsule()
                        .stroke(appState.isConnectedToAirPlay ? .green.opacity(0.4) : .white.opacity(0.2), lineWidth: 1)
                )
        )
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Target Device") {
                    ForEach(CompatibilityMode.allCases, id: \.self) { mode in
                        Button(action: {
                            appState.saveCompatibilityMode(mode)
                        }) {
                            HStack {
                                Image(systemName: mode.icon)
                                    .foregroundColor(.primary)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.rawValue)
                                        .foregroundColor(.primary)
                                    Text(mode.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if appState.compatibilityMode == mode {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                #if os(macOS)
                Section("Casting Mode") {
                    ForEach(CastingMode.allCases, id: \.self) { mode in
                        Button(action: {
                            appState.saveCastingMode(mode)
                        }) {
                            HStack {
                                Image(systemName: mode.icon)
                                    .foregroundColor(.primary)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mode.rawValue)
                                        .foregroundColor(.primary)
                                    Text(mode.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                if appState.castingMode == mode {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                #endif

                Section("Quality") {
                    Toggle("Ultra Quality", isOn: Binding(
                        get: { appState.transcodeManager.ultraQualityAudio },
                        set: { appState.saveUltraQualityAudio($0) }
                    ))
                    Text("Higher video bitrates + 320kbps 5.1 surround audio. Disable for better device compatibility.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("Cache") {
                    HStack {
                        Text("Cache Size")
                        Spacer()
                        Text(CacheManager.formattedCacheSize())
                            .foregroundColor(.secondary)
                    }

                    Button("Clear Cache", role: .destructive) {
                        CacheManager.clearAllCache()
                    }
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        #if os(macOS)
        .frame(width: 400, height: 350)
        #endif
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
