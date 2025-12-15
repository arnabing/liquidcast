import SwiftUI
import UniformTypeIdentifiers

// Notification to trigger AirPlay picker programmatically
extension Notification.Name {
    static let triggerAirPlayPicker = Notification.Name("triggerAirPlayPicker")
}

/// Media player with glass UI
struct MiniPlayerView: View {
    @EnvironmentObject var appState: AppState
    @State private var isDropTargeted = false

    var body: some View {
        VStack(spacing: 12) {
            // Now playing info
            NowPlayingBar()

            Spacer(minLength: 0)

            // Progress bar
            PlaybackProgressBar()

            // Controls (centered)
            ControlsBar()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(width: 500, height: 180)
        .background(.ultraThinMaterial)
        .overlay(
            RoundedRectangle(cornerRadius: 0)
                .stroke(isDropTargeted ? Color.blue : Color.clear, lineWidth: isDropTargeted ? 2 : 0)
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
        guard appState.isConnectedToAirPlay else { return false }
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

// MARK: - Now Playing Bar
struct NowPlayingBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            // Status indicator dot
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            // File name / status text
            VStack(alignment: .leading, spacing: 2) {
                if let url = appState.selectedMediaURL {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // Format + streaming info + status
                    HStack(spacing: 6) {
                        Text(url.pathExtension.uppercased())
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)

                        // Streaming info (resolution, codec)
                        if !appState.streamingInfoText.isEmpty {
                            Text("·")
                                .foregroundColor(.secondary)
                            Text(appState.streamingInfoText)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }

                        // Show seeking status (highest priority)
                        if appState.isSeeking {
                            Text("·")
                                .foregroundColor(.secondary)
                            Text("Seeking...")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.blue)
                        } else if appState.isConverting || appState.isStreaming {
                            Text("·")
                                .foregroundColor(.secondary)
                            Text(appState.conversionStatus)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(appState.isConverting ? .orange : .cyan)
                        }
                    }
                } else if !appState.airPlayManager.isAirPlayAvailable {
                    Text("No AirPlay devices found")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                } else if !appState.isConnectedToAirPlay {
                    // Clickable text that triggers AirPlay picker
                    Button(action: {
                        // Post notification to trigger AirPlay picker click
                        NotificationCenter.default.post(name: .triggerAirPlayPicker, object: nil)
                    }) {
                        Text("Select AirPlay device →")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                } else {
                    // Clickable text to open file picker
                    Button(action: {
                        appState.showingFilePicker = true
                    }) {
                        Text("Drop video file or click here →")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.ultraThinMaterial)
        )
    }

    private var statusColor: Color {
        if appState.isSeeking {
            return .blue  // Blue dot during seek
        } else if appState.isConverting {
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

// MARK: - Playback Progress Bar (YouTube-style)
struct PlaybackProgressBar: View {
    @EnvironmentObject var appState: AppState
    @State private var isHovering = false
    @State private var isDragging = false
    @State private var dragPosition: Double = 0

    /// The duration to display (use source duration if available for full movie length)
    private var displayDuration: Double {
        appState.sourceDuration > 0 ? appState.sourceDuration : appState.duration
    }

    /// Whether transcoding is still in progress (not yet complete)
    private var isTranscodingInProgress: Bool {
        // Transcoding is in progress if we're streaming AND duration < sourceDuration
        appState.isStreaming && appState.sourceDuration > 0 && appState.duration < appState.sourceDuration * 0.99
    }

    /// Display position: preview during drag/seek, actual during playback
    private var displayPosition: Double {
        if isDragging {
            return dragPosition
        }
        if let preview = appState.seekPreviewPosition {
            return preview
        }
        return appState.playbackProgress
    }

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track (gray)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: isHovering || isDragging ? 5 : 3)

                    // Buffered/transcoded portion (light gray)
                    if isTranscodingInProgress {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.gray.opacity(0.5))
                            .frame(width: bufferedWidth(in: geometry), height: isHovering || isDragging ? 5 : 3)
                    }

                    // Progress bar (red - YouTube style) - uses displayPosition for real-time feedback
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.red)
                        .frame(width: progressWidth(for: displayPosition, in: geometry), height: isHovering || isDragging ? 5 : 3)

                    // Thumb (red circle) - positioned at display position
                    Circle()
                        .fill(Color.red)
                        .frame(width: isHovering || isDragging ? 12 : 0, height: isHovering || isDragging ? 12 : 0)
                        .offset(x: max(progressWidth(for: displayPosition, in: geometry) - 6, 0))
                        .opacity(isHovering || isDragging ? 1 : 0)

                    // Loading indicator during seek (small spinner next to thumb)
                    if appState.isSeeking {
                        ProgressView()
                            .scaleEffect(0.4)
                            .frame(width: 16, height: 16)
                            .offset(x: progressWidth(for: displayPosition, in: geometry) + 4, y: -2)
                    }
                }
                .frame(height: 12)  // Larger hit area
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isHovering = hovering
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            isDragging = true
                            let ratio = min(max(value.location.x / geometry.size.width, 0), 1)
                            dragPosition = ratio * displayDuration
                        }
                        .onEnded { value in
                            isDragging = false
                            let ratio = min(max(value.location.x / geometry.size.width, 0), 1)
                            let targetPosition = ratio * displayDuration
                            // Use debounced seek for better UX
                            appState.debouncedSeek(to: targetPosition)
                        }
                )
            }
            .frame(height: 12)

            // Time display
            HStack {
                // Show preview time during drag, otherwise playback time
                Text(formatTime(displayPosition))
                Spacer()
                // Show spinner while transcoding is still in progress OR while seeking
                if isTranscodingInProgress || appState.isSeeking {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                }
                Text(formatTime(displayDuration))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
        }
    }

    /// Width of the buffered/transcoded portion (relative to source duration)
    private func bufferedWidth(in geometry: GeometryProxy) -> CGFloat {
        guard displayDuration > 0 else { return geometry.size.width }
        let ratio = min(appState.duration / displayDuration, 1.0)
        return geometry.size.width * CGFloat(ratio)
    }

    /// Width for a specific position (relative to source duration)
    private func progressWidth(for position: Double, in geometry: GeometryProxy) -> CGFloat {
        guard displayDuration > 0 else { return 0 }
        let ratio = min(position / displayDuration, 1.0)
        return geometry.size.width * CGFloat(ratio)
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
        ZStack {
            // Center: Playback controls (truly centered)
            HStack(spacing: 20) {
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
                    let maxTime = appState.sourceDuration > 0 ? appState.sourceDuration : appState.duration
                    appState.seek(to: min(appState.playbackProgress + 30, maxTime))
                }
                .disabled(appState.selectedMediaURL == nil)
            }

            // Left side: File + Ultra Quality
            HStack(spacing: 12) {
                ControlButton(icon: "plus.circle.fill", size: 20) {
                    appState.showingFilePicker = true
                }
                .disabled(!appState.isConnectedToAirPlay)

                MiniUltraToggle()

                Spacer()
            }

            // Right side: AirPlay
            HStack {
                Spacer()
                AirPlayMiniButton()
            }
        }
    }
}

// MARK: - Mini Quality Toggle (cycles between Ultra/High)
struct MiniUltraToggle: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        Button(action: {
            appState.saveUltraQualityAudio(!appState.ultraQualityEnabled)
        }) {
            HStack(spacing: 4) {
                Image(systemName: appState.ultraQualityEnabled ? "sparkles" : "film")
                    .font(.system(size: 8, weight: .bold))
                Text(appState.ultraQualityEnabled ? "Ultra" : "High")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
            }
            .foregroundColor(appState.ultraQualityEnabled ? .black : .primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(appState.ultraQualityEnabled
                        ? LinearGradient(
                            colors: [Color.yellow, Color.orange],
                            startPoint: .leading,
                            endPoint: .trailing
                          )
                        : LinearGradient(
                            colors: [Color.gray.opacity(0.2), Color.gray.opacity(0.15)],
                            startPoint: .leading,
                            endPoint: .trailing
                          )
                    )
            )
            .overlay(
                Capsule()
                    .stroke(appState.ultraQualityEnabled ? Color.orange.opacity(0.5) : Color.gray.opacity(0.3), lineWidth: 0.5)
            )
            .animation(.easeInOut(duration: 0.2), value: appState.ultraQualityEnabled)
        }
        .buttonStyle(.plain)
        .help(appState.ultraQualityEnabled ? "Ultra: HEVC + 5.1 surround" : "High: H.264 + Stereo")
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
    @State private var isPulsing: Bool = false
    @State private var isPickerOpen: Bool = false

    private var needsAttention: Bool {
        !appState.isConnectedToAirPlay && appState.airPlayManager.isAirPlayAvailable
    }

    var body: some View {
        ZStack {
            // Glow effect when needing attention (not connected)
            if needsAttention {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 32, height: 32)
                    .scaleEffect(isPulsing ? 1.4 : 1.0)
                    .opacity(isPulsing ? 0.15 : 0.5)
                    .animation(
                        .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                        value: isPulsing
                    )
            }

            AirPlayRoutePickerRepresentable(
                onRoutePickerWillBegin: {
                    isPickerOpen = true
                },
                onRoutePickerDidEnd: {
                    isPickerOpen = false
                    // When picker closes, assume user selected a device
                    // (We can't detect which device, so we set a generic "connected" state)
                    // The actual device name will be detected when playback starts
                    if appState.airPlayManager.isAirPlayAvailable && !appState.isConnectedToAirPlay {
                        appState.isConnectedToAirPlay = true
                        appState.saveCurrentDevice("AirPlay Device")
                    }
                }
            )
            .frame(width: 24, height: 24)

            // Connection indicator
            if appState.isConnectedToAirPlay {
                Circle()
                    .fill(.green)
                    .frame(width: 6, height: 6)
                    .offset(x: 10, y: -10)
            }
        }
        .onAppear {
            // Only start pulsing if needs attention
            if needsAttention {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    isPulsing = true
                }
            }
        }
        .onChange(of: appState.isConnectedToAirPlay) { _, isConnected in
            // Stop pulsing when connected
            if isConnected {
                isPulsing = false
            }
        }
        .onChange(of: appState.airPlayManager.isAirPlayAvailable) { _, isAvailable in
            // Start pulsing when devices become available and not connected
            if isAvailable && !appState.isConnectedToAirPlay {
                isPulsing = true
            }
        }
    }
}

#Preview {
    MiniPlayerView()
        .environmentObject(AppState())
}
