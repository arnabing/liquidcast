import SwiftUI
import AVFoundation
import Combine
import os.log

private let appStateLogger = Logger(subsystem: "com.liquidcast", category: "AppState")

/// Quality mode for casting
enum CastingMode: String, CaseIterable {
    case highestQuality = "Highest Quality"
    case highQuality = "High Quality"

    var description: String {
        switch self {
        case .highestQuality:
            return "Direct streaming via AirPlay (best for media files)"
        case .highQuality:
            return "Screen capture with H.265 encoding (for any window)"
        }
    }

    var icon: String {
        switch self {
        case .highestQuality:
            return "sparkles.tv"
        case .highQuality:
            return "rectangle.on.rectangle"
        }
    }
}

/// Compatibility mode for different AirPlay receivers
enum CompatibilityMode: String, CaseIterable, Codable {
    case appleTV = "Apple TV"
    case smartTV = "Smart TV"

    var description: String {
        switch self {
        case .appleTV:
            return "Best quality for Apple TV devices"
        case .smartTV:
            return "Compatible with Samsung, LG, and other smart TVs"
        }
    }

    var icon: String {
        switch self {
        case .appleTV:
            return "appletv"
        case .smartTV:
            return "tv"
        }
    }

    /// Auto-detect device type from device name
    static func detect(from deviceName: String) -> CompatibilityMode {
        detectWithHEVC(from: deviceName).mode
    }

    /// Auto-detect device type AND HEVC support from device name
    /// Returns tuple of (mode, hevcSupported)
    static func detectWithHEVC(from deviceName: String) -> (mode: CompatibilityMode, hevcSupported: Bool) {
        let name = deviceName.lowercased()

        // Apple TV - always supports HEVC
        if name.contains("apple") || name.contains("appletv") || name.contains("apple tv") {
            return (.appleTV, true)
        }

        // Samsung/LG/Sony 4K TVs (2016+) support HEVC
        let hevcSmartTVs = ["samsung", "lg", "sony", "bravia"]
        for brand in hevcSmartTVs {
            if name.contains(brand) {
                return (.smartTV, true)  // Likely supports HEVC
            }
        }

        // Vizio, TCL, Hisense - mixed HEVC support, safer with H.264
        let h264SmartTVs = ["vizio", "tcl", "hisense", "roku", "fire", "chromecast"]
        for brand in h264SmartTVs {
            if name.contains(brand) {
                return (.smartTV, false)
            }
        }

        // Unknown device - default to Smart TV with H.264 for max compatibility
        return (.smartTV, false)
    }
}

/// Main application state
@MainActor
class AppState: ObservableObject {
    // MARK: - Published Properties

    @Published var castingMode: CastingMode = .highestQuality
    @Published var compatibilityMode: CompatibilityMode = .appleTV
    @Published var selectedMediaURL: URL?
    @Published var isPlaying: Bool = false
    @Published var isConnectedToAirPlay: Bool = false
    @Published var currentAirPlayDevice: String?
    @Published var showingFilePicker: Bool = false
    @Published var showingWindowPicker: Bool = false
    @Published var volume: Float = 1.0
    @Published var playbackProgress: Double = 0.0
    @Published var duration: Double = 0.0

    // MARK: - Conversion State

    @Published var isConverting: Bool = false
    @Published var isStreaming: Bool = false
    @Published var conversionProgress: Double = 0.0
    @Published var conversionStatus: String = ""
    @Published var conversionError: String?

    // MARK: - Streaming Info (populated after media analysis)

    @Published var outputResolution: String = ""     // "1080p" or "4K"
    @Published var outputVideoCodec: String = ""     // "H.264" or "HEVC"
    @Published var outputAudioCodec: String = ""     // "AAC"
    @Published var outputAudioChannels: String = ""  // "5.1" or "Stereo"
    @Published var sourceDuration: Double = 0        // Full source file duration (from ffprobe)

    // MARK: - Quality Settings (mirrored from TranscodeManager for SwiftUI binding)

    @Published var ultraQualityEnabled: Bool = false

    // MARK: - Seeking State (for UI feedback and debouncing)

    @Published var isSeeking: Bool = false              // True during seek operation
    @Published var isBuffering: Bool = false            // Player is waiting for data
    @Published var seekPreviewPosition: Double? = nil   // Preview position during drag (nil = not dragging)

    private var seekDebounceTask: Task<Void, Never>? = nil
    private var seekCount = 0

    /// Formatted streaming info for display
    var streamingInfoText: String {
        guard !outputResolution.isEmpty else { return "" }
        return "\(outputResolution) \(outputVideoCodec) · \(outputAudioCodec) \(outputAudioChannels)"
    }

    /// Update streaming info (called by TranscodeManager after analysis)
    func updateStreamingInfo(resolution: String, videoCodec: String, audioCodec: String, audioChannels: String) {
        outputResolution = resolution
        outputVideoCodec = videoCodec
        outputAudioCodec = audioCodec
        outputAudioChannels = audioChannels
    }

    /// Clear streaming info (called when stopping playback)
    func clearStreamingInfo() {
        outputResolution = ""
        outputVideoCodec = ""
        outputAudioCodec = ""
        outputAudioChannels = ""
    }

    // MARK: - Services

    let mediaPlayer = MediaPlayerController()
    let airPlayManager = AirPlayManager()
    let transcodeManager = TranscodeManager()

    // MARK: - Private Properties

    private var cancellables = Set<AnyCancellable>()

    /// Generation counter to detect stale transcode completions
    private var loadGeneration: Int = 0

    /// Current load task (cancelled when new media is selected)
    private var currentLoadTask: Task<Void, Never>?

    // MARK: - Cache Settings

    /// Days after which cached files are automatically deleted
    private let cacheExpirationDays: Int = 7

    // MARK: - Persistence Keys

    private let lastDeviceKey = "lastAirPlayDevice"
    private let lastModeKey = "lastCastingMode"
    private let compatibilityModeKey = "compatibilityMode"
    private let ultraQualityKey = "ultraQualityAudio"

    // MARK: - Initialization

    init() {
        loadPersistedSettings()
        setupBindings()
        CacheManager.clearSessions()
        cleanupOldCacheFiles()
        CacheManager.removeDuplicates()

        #if os(macOS)
        // FFmpeg children outlive the app unless killed explicitly
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            FFmpegProcess.killAll()
            CacheManager.clearSessions()
        }
        #endif
    }

    // MARK: - Persistence

    private func loadPersistedSettings() {
        if let savedMode = UserDefaults.standard.string(forKey: lastModeKey),
           let mode = CastingMode(rawValue: savedMode) {
            castingMode = mode
        }

        if let savedCompatMode = UserDefaults.standard.string(forKey: compatibilityModeKey),
           let mode = CompatibilityMode(rawValue: savedCompatMode) {
            compatibilityMode = mode
        }

        if let savedDevice = UserDefaults.standard.string(forKey: lastDeviceKey) {
            currentAirPlayDevice = savedDevice
        }

        let ultraQuality = UserDefaults.standard.bool(forKey: ultraQualityKey)
        transcodeManager.ultraQualityAudio = ultraQuality
        ultraQualityEnabled = ultraQuality
    }

    func saveCurrentDevice(_ deviceName: String?) {
        currentAirPlayDevice = deviceName
        UserDefaults.standard.set(deviceName, forKey: lastDeviceKey)

        // Auto-detect and set compatibility mode based on device name
        if let name = deviceName {
            let detectedMode = CompatibilityMode.detect(from: name)
            saveCompatibilityMode(detectedMode)
            appStateLogger.info("📺 Device '\(name)' detected as: \(detectedMode.rawValue)")
        }
    }

    /// Whether a device is available (connected or remembered) for file selection
    var isDeviceReady: Bool {
        isConnectedToAirPlay || currentAirPlayDevice != nil
    }

    func saveCastingMode(_ mode: CastingMode) {
        castingMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: lastModeKey)
    }

    func saveCompatibilityMode(_ mode: CompatibilityMode) {
        compatibilityMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: compatibilityModeKey)
    }

    func saveUltraQualityAudio(_ enabled: Bool) {
        ultraQualityEnabled = enabled
        transcodeManager.ultraQualityAudio = enabled
        UserDefaults.standard.set(enabled, forKey: ultraQualityKey)
    }

    // MARK: - Setup

    private func setupBindings() {
        mediaPlayer.onPlaybackStateChanged = { [weak self] isPlaying in
            Task { @MainActor in
                self?.isPlaying = isPlaying
            }
        }

        mediaPlayer.onBufferingChanged = { [weak self] isBuffering in
            Task { @MainActor in
                self?.isBuffering = isBuffering
            }
        }

        // Streams are published as complete VOD playlists, so player time is movie time
        // and the duration is the full movie from the start
        mediaPlayer.onProgressChanged = { [weak self] progress, duration in
            Task { @MainActor in
                guard let self else { return }
                self.playbackProgress = progress
                if duration > 0 {
                    self.duration = duration
                }

                // Save playback position periodically (every 5 seconds, after 10 seconds in)
                if let url = self.selectedMediaURL, progress > 10, Int(progress) % 5 == 0 {
                    CacheManager.savePlaybackPosition(for: url, position: progress)
                }

                // Clear position when near the end (> 95% complete)
                if progress > 0 && duration > 0 && progress / duration > 0.95, let url = self.selectedMediaURL {
                    CacheManager.clearPlaybackPosition(for: url)
                }
            }
        }

        mediaPlayer.onDurationChanged = { [weak self] duration in
            Task { @MainActor in
                self?.duration = duration
            }
        }

        // Bind transcoder state to app state
        transcodeManager.$isConverting
            .receive(on: DispatchQueue.main)
            .assign(to: &$isConverting)

        transcodeManager.$isStreaming
            .receive(on: DispatchQueue.main)
            .assign(to: &$isStreaming)

        transcodeManager.$progress
            .receive(on: DispatchQueue.main)
            .assign(to: &$conversionProgress)

        transcodeManager.$statusMessage
            .receive(on: DispatchQueue.main)
            .assign(to: &$conversionStatus)

        // Bind streaming info from transcoder
        transcodeManager.$outputResolution
            .receive(on: DispatchQueue.main)
            .assign(to: &$outputResolution)

        transcodeManager.$outputVideoCodec
            .receive(on: DispatchQueue.main)
            .assign(to: &$outputVideoCodec)

        transcodeManager.$outputAudioCodec
            .receive(on: DispatchQueue.main)
            .assign(to: &$outputAudioCodec)

        transcodeManager.$outputAudioChannels
            .receive(on: DispatchQueue.main)
            .assign(to: &$outputAudioChannels)

        transcodeManager.$sourceDuration
            .receive(on: DispatchQueue.main)
            .assign(to: &$sourceDuration)

        // Pass source duration to media player (clamps seeks before the item has loaded)
        transcodeManager.$sourceDuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                self?.mediaPlayer.sourceDuration = duration
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    func loadMedia(from url: URL) {
        appStateLogger.info("🎬 Loading media: \(url.lastPathComponent)")

        // Cancel any previous load operation (also kills its FFmpeg and deletes its segments), and
        // stop the old item so its progress isn't saved under the new file while this one prepares
        currentLoadTask?.cancel()
        transcodeManager.stopStreaming()
        mediaPlayer.unload()

        // Increment generation to invalidate any stale completions
        loadGeneration += 1
        let thisGeneration = loadGeneration

        selectedMediaURL = url
        conversionError = nil
        duration = 0
        playbackProgress = 0

        // Clear previous streaming info
        clearStreamingInfo()

        // Check for saved playback position to resume from
        let savedPosition = CacheManager.getPlaybackPosition(for: url) ?? 0

        if savedPosition > 0 {
            appStateLogger.info("📍 Found saved position: \(Int(savedPosition))s for \(url.lastPathComponent)")
        }

        // Direct-play files come back as-is; everything else as an HLS stream that already
        // starts at the resume position (EXT-X-START), so only files need a seek
        currentLoadTask = Task {
            do {
                let playableURL = try await transcodeManager.prepareForAirPlay(
                    from: url,
                    mode: compatibilityMode,
                    startPosition: savedPosition
                )

                // Check if this load was superseded by a newer one
                guard thisGeneration == loadGeneration else {
                    appStateLogger.info("🚫 Ignoring stale load completion for: \(url.lastPathComponent)")
                    return
                }

                appStateLogger.info("✅ Ready to play: \(playableURL.absoluteString)")
                mediaPlayer.loadMedia(from: playableURL, startTime: playableURL.isFileURL ? savedPosition : 0)
            } catch {
                // Ignore errors from superseded loads
                if Task.isCancelled || thisGeneration != loadGeneration {
                    appStateLogger.info("🚫 Load cancelled for: \(url.lastPathComponent)")
                    return
                }
                appStateLogger.error("❌ Failed to prepare media: \(error.localizedDescription)")
                conversionError = error.localizedDescription
            }
        }
    }

    /// Cancel any ongoing conversion
    func cancelConversion() {
        transcodeManager.cancel()
    }

    func togglePlayback() {
        appStateLogger.info("⏯️ Toggle playback - currently playing: \(self.isPlaying)")
        if isPlaying {
            mediaPlayer.pause()
        } else {
            mediaPlayer.play()
        }
    }

    /// Debounced seek - waits 300ms before executing to prevent rapid seek spam
    func debouncedSeek(to position: Double) {
        // Cancel any pending seek
        seekDebounceTask?.cancel()

        // Show preview immediately (optimistic UI)
        seekPreviewPosition = position
        appStateLogger.info("⏭️ Seek preview: \(Int(position))s")

        // Schedule actual seek after debounce delay
        seekDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
            guard !Task.isCancelled else { return }

            // Keep seekPreviewPosition set during seek - only cleared in seekCompleted()
            isSeeking = true
            seek(to: position)
        }
    }

    /// Called when seek operation completes
    func seekCompleted() {
        isSeeking = false
        seekPreviewPosition = nil  // Clear preview now that seek is done
        appStateLogger.info("✅ Seek completed")
    }

    func seek(to position: Double) {
        appStateLogger.info("⏭️ Seeking to \(Int(position))s")
        isSeeking = true
        seekCount += 1
        let thisSeek = seekCount
        mediaPlayer.seek(to: position) { [weak self] _ in
            Task { @MainActor in
                // An interrupted seek completes early; only the latest one ends the seeking state
                guard let self, thisSeek == self.seekCount else { return }
                self.seekCompleted()
            }
        }
    }

    func setVolume(_ volume: Float) {
        appStateLogger.info("🔊 Setting volume: \(volume)")
        self.volume = volume
        mediaPlayer.setVolume(volume)
    }

    // MARK: - Cache Cleanup

    /// Clean up cache files older than the expiration period (called on app launch)
    private func cleanupOldCacheFiles() {
        appStateLogger.info("🧹 Checking for old cache files (older than \(self.cacheExpirationDays) days)...")
        CacheManager.clearOldCache(olderThan: self.cacheExpirationDays)

        let cacheSize = CacheManager.formattedCacheSize()
        appStateLogger.info("📦 Current cache size: \(cacheSize)")
    }
}
