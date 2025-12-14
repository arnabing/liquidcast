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

    // MARK: - Quality Settings (mirrored from TranscodeManager for SwiftUI binding)

    @Published var ultraQualityEnabled: Bool = false

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
        cleanupOldCacheFiles()
        CacheManager.removeDuplicates()
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

        mediaPlayer.onProgressChanged = { [weak self] progress, duration in
            Task { @MainActor in
                self?.playbackProgress = progress
                self?.duration = duration

                // Save playback position periodically (every 5 seconds, after 10 seconds in)
                if let url = self?.selectedMediaURL,
                   progress > 10,
                   Int(progress) % 5 == 0 {
                    CacheManager.savePlaybackPosition(for: url, position: progress)
                }

                // Clear position when near end (> 95% complete)
                if progress > 0 && duration > 0 && progress / duration > 0.95 {
                    if let url = self?.selectedMediaURL {
                        CacheManager.clearPlaybackPosition(for: url)
                    }
                }
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
    }

    // MARK: - Actions

    func loadMedia(from url: URL) {
        appStateLogger.info("🎬 Loading media: \(url.lastPathComponent)")
        selectedMediaURL = url
        conversionError = nil

        // Stop any existing HTTP server from previous conversion
        transcodeManager.stopServer()

        // Clear previous streaming info
        clearStreamingInfo()

        // Always use TranscodeManager for smart format detection
        // It will return the original URL for compatible files (Path 0: direct playback)
        // or convert as needed (Path 1-3: remux, audio transcode, full transcode)
        Task {
            do {
                let playableURL = try await transcodeManager.convertForAirPlay(
                    from: url,
                    mode: compatibilityMode,
                    deviceName: currentAirPlayDevice
                )

                if playableURL != url {
                    appStateLogger.info("✅ Ready to play: \(playableURL.lastPathComponent)")
                }

                mediaPlayer.loadMedia(from: playableURL)

                // Restore saved playback position after player is ready
                // Use longer delay for HLS streams which need buffering time
                let savedPosition = CacheManager.getPlaybackPosition(for: url)
                if let position = savedPosition {
                    appStateLogger.info("📍 Found saved position: \(Int(position))s for \(url.lastPathComponent)")
                    let delay: Double = playableURL.scheme == "http" ? 3.0 : 1.0
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                        guard let self = self, self.mediaPlayer.isReady else {
                            appStateLogger.warning("⏳ Player not ready for seek, retrying...")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                self?.seek(to: position)
                                appStateLogger.info("▶️ Resumed from \(Int(position))s (retry)")
                            }
                            return
                        }
                        self.seek(to: position)
                        appStateLogger.info("▶️ Resumed from \(Int(position))s")
                    }
                } else {
                    appStateLogger.info("📍 No saved position for \(url.lastPathComponent)")
                }
            } catch {
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

    func seek(to progress: Double) {
        appStateLogger.info("⏭️ Seeking to: \(progress)")
        mediaPlayer.seek(to: progress)
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
