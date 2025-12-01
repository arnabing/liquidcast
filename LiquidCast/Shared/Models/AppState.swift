import SwiftUI
import AVFoundation
import Combine

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

/// Main application state
@MainActor
class AppState: ObservableObject {
    // MARK: - Published Properties

    @Published var castingMode: CastingMode = .highestQuality
    @Published var selectedMediaURL: URL?
    @Published var isPlaying: Bool = false
    @Published var isConnectedToAirPlay: Bool = false
    @Published var currentAirPlayDevice: String?
    @Published var showingFilePicker: Bool = false
    @Published var showingWindowPicker: Bool = false
    @Published var volume: Float = 1.0
    @Published var playbackProgress: Double = 0.0
    @Published var duration: Double = 0.0

    // MARK: - Services

    let mediaPlayer = MediaPlayerController()
    let airPlayManager = AirPlayManager()

    // MARK: - Persistence Keys

    private let lastDeviceKey = "lastAirPlayDevice"
    private let lastModeKey = "lastCastingMode"

    // MARK: - Initialization

    init() {
        loadPersistedSettings()
        setupBindings()
    }

    // MARK: - Persistence

    private func loadPersistedSettings() {
        if let savedMode = UserDefaults.standard.string(forKey: lastModeKey),
           let mode = CastingMode(rawValue: savedMode) {
            castingMode = mode
        }

        if let savedDevice = UserDefaults.standard.string(forKey: lastDeviceKey) {
            currentAirPlayDevice = savedDevice
        }
    }

    func saveCurrentDevice(_ deviceName: String?) {
        currentAirPlayDevice = deviceName
        UserDefaults.standard.set(deviceName, forKey: lastDeviceKey)
    }

    func saveCastingMode(_ mode: CastingMode) {
        castingMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: lastModeKey)
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
            }
        }
    }

    // MARK: - Actions

    func loadMedia(from url: URL) {
        selectedMediaURL = url
        mediaPlayer.loadMedia(from: url)
    }

    func togglePlayback() {
        if isPlaying {
            mediaPlayer.pause()
        } else {
            mediaPlayer.play()
        }
    }

    func seek(to progress: Double) {
        mediaPlayer.seek(to: progress)
    }

    func setVolume(_ volume: Float) {
        self.volume = volume
        mediaPlayer.setVolume(volume)
    }
}
