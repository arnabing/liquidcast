import AVFoundation
import Combine
import os.log
#if os(macOS)
import IOKit.pwr_mgt
#endif

private let logger = Logger(subsystem: "com.liquidcast", category: "MediaPlayer")

/// Wrapper around AVPlayer with AirPlay support
class MediaPlayerController: NSObject, ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var player: AVPlayer?
    @Published private(set) var playerItem: AVPlayerItem?
    @Published private(set) var isReady: Bool = false
    @Published private(set) var error: Error?

    // MARK: - Callbacks

    var onPlaybackStateChanged: ((Bool) -> Void)?
    var onProgressChanged: ((Double, Double) -> Void)?

    // MARK: - Private Properties

    private var timeObserver: Any?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Sleep Prevention

    #if os(macOS)
    private var sleepAssertionID: IOPMAssertionID = 0
    private var isSleepPrevented: Bool = false
    #else
    private var backgroundActivity: NSObjectProtocol?
    #endif

    // MARK: - Initialization

    override init() {
        super.init()
        logger.info("🎬 MediaPlayerController initializing...")
        setupPlayer()
    }

    deinit {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
        allowSleep()
    }

    // MARK: - Setup

    private func setupPlayer() {
        let player = AVPlayer()

        // Enable AirPlay with highest quality (direct streaming)
        player.allowsExternalPlayback = true

        #if os(iOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        player.externalPlaybackVideoGravity = .resizeAspect
        logger.info("✅ usesExternalPlaybackWhileExternalScreenIsActive: \(player.usesExternalPlaybackWhileExternalScreenIsActive)")
        #endif

        self.player = player

        logger.info("✅ AVPlayer created - allowsExternalPlayback: \(player.allowsExternalPlayback)")

        setupTimeObserver()
        observePlaybackState()
        observeExternalPlayback()
    }

    private func setupTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

        timeObserver = player?.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self,
                  let duration = self.playerItem?.duration,
                  duration.isValid && !duration.isIndefinite else { return }

            let currentSeconds = time.seconds
            let totalSeconds = duration.seconds

            self.onProgressChanged?(currentSeconds, totalSeconds)
        }
    }

    private func observePlaybackState() {
        player?.publisher(for: \.timeControlStatus)
            .sink { [weak self] status in
                let isPlaying = status == .playing
                let statusString: String
                switch status {
                case .paused: statusString = "paused"
                case .playing: statusString = "playing"
                case .waitingToPlayAtSpecifiedRate: statusString = "waiting"
                @unknown default: statusString = "unknown"
                }
                logger.info("⏯️ Playback state changed: \(statusString)")

                if let reason = self?.player?.reasonForWaitingToPlay {
                    logger.warning("⏳ Waiting reason: \(reason.rawValue)")
                }

                self?.onPlaybackStateChanged?(isPlaying)
            }
            .store(in: &cancellables)
    }

    private func observeExternalPlayback() {
        player?.publisher(for: \.isExternalPlaybackActive)
            .sink { isActive in
                logger.info("📺 External playback active: \(isActive)")
            }
            .store(in: &cancellables)

        // Observe player item status changes
        player?.publisher(for: \.currentItem?.status)
            .sink { status in
                let statusString: String
                switch status {
                case .unknown: statusString = "unknown"
                case .readyToPlay: statusString = "readyToPlay"
                case .failed: statusString = "failed"
                case .none: statusString = "none"
                @unknown default: statusString = "unknown default"
                }
                logger.info("📼 Player item status: \(statusString)")
            }
            .store(in: &cancellables)
    }

    // MARK: - Media Loading

    func loadMedia(from url: URL) {
        logger.info("📂 Loading media from: \(url.path)")
        logger.info("📂 URL scheme: \(url.scheme ?? "nil")")
        logger.info("📂 Is file URL: \(url.isFileURL)")

        // Create asset with options for network optimization
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        logger.info("📦 Asset created, checking playability...")

        // Check if asset is playable
        Task {
            do {
                let isPlayable = try await asset.load(.isPlayable)
                logger.info("📦 Asset isPlayable: \(isPlayable)")

                let tracks = try await asset.load(.tracks)
                logger.info("📦 Asset tracks count: \(tracks.count)")
                for track in tracks {
                    let mediaType = track.mediaType
                    logger.info("📦 Track mediaType: \(mediaType.rawValue)")
                }
            } catch {
                logger.error("❌ Asset load error: \(error.localizedDescription)")
            }
        }

        let playerItem = AVPlayerItem(asset: asset)

        // Observe when ready to play
        playerItem.publisher(for: \.status)
            .sink { [weak self] status in
                switch status {
                case .readyToPlay:
                    logger.info("✅ PlayerItem ready to play")
                    self?.isReady = true
                    self?.error = nil
                case .failed:
                    logger.error("❌ PlayerItem failed: \(playerItem.error?.localizedDescription ?? "unknown")")
                    self?.isReady = false
                    self?.error = playerItem.error
                case .unknown:
                    logger.info("⏳ PlayerItem status unknown (loading...)")
                @unknown default:
                    break
                }
            }
            .store(in: &cancellables)

        // Observe player item errors
        playerItem.publisher(for: \.error)
            .sink { error in
                if let error = error {
                    logger.error("❌ PlayerItem error: \(error.localizedDescription)")
                }
            }
            .store(in: &cancellables)

        self.playerItem = playerItem
        player?.replaceCurrentItem(with: playerItem)
        logger.info("📼 PlayerItem set on AVPlayer")
    }

    // MARK: - Playback Control

    func play() {
        logger.info("▶️ Play requested")
        logger.info("▶️ isExternalPlaybackActive: \(self.player?.isExternalPlaybackActive ?? false)")
        logger.info("▶️ currentItem: \(self.player?.currentItem != nil ? "exists" : "nil")")
        logger.info("▶️ currentItem status: \(self.player?.currentItem?.status.rawValue ?? -1)")
        logger.info("▶️ player rate before: \(self.player?.rate ?? -1)")

        preventSleep()
        self.player?.play()

        logger.info("▶️ player rate after: \(self.player?.rate ?? -1)")
        logger.info("▶️ timeControlStatus: \(self.player?.timeControlStatus.rawValue ?? -1)")
    }

    func pause() {
        logger.info("⏸️ Pause requested")
        self.player?.pause()
        allowSleep()
        logger.info("⏸️ player rate after: \(self.player?.rate ?? -1)")
    }

    func seek(to progress: Double) {
        guard let duration = playerItem?.duration,
              duration.isValid && !duration.isIndefinite else { return }

        let targetTime = CMTime(seconds: progress, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player?.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func setVolume(_ volume: Float) {
        player?.volume = volume
    }

    // MARK: - AirPlay Status

    var isExternalPlaybackActive: Bool {
        player?.isExternalPlaybackActive ?? false
    }

    // MARK: - Sleep Prevention

    /// Prevent system sleep during video playback
    private func preventSleep() {
        #if os(macOS)
        guard !isSleepPrevented else { return }

        let reason = "LiquidCast video playback" as CFString
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &sleepAssertionID
        )

        if result == kIOReturnSuccess {
            isSleepPrevented = true
            logger.info("💤 Sleep prevention enabled")
        } else {
            logger.error("❌ Failed to prevent sleep: \(result)")
        }
        #else
        // iOS: Use ProcessInfo to prevent suspension
        if backgroundActivity == nil {
            backgroundActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .userInitiated],
                reason: "LiquidCast video playback"
            )
            logger.info("💤 Sleep prevention enabled (iOS)")
        }
        #endif
    }

    /// Allow system sleep when playback stops
    private func allowSleep() {
        #if os(macOS)
        guard isSleepPrevented else { return }

        let result = IOPMAssertionRelease(sleepAssertionID)
        if result == kIOReturnSuccess {
            isSleepPrevented = false
            sleepAssertionID = 0
            logger.info("💤 Sleep prevention disabled")
        } else {
            logger.error("❌ Failed to release sleep assertion: \(result)")
        }
        #else
        // iOS: End the activity
        if let activity = backgroundActivity {
            ProcessInfo.processInfo.endActivity(activity)
            backgroundActivity = nil
            logger.info("💤 Sleep prevention disabled (iOS)")
        }
        #endif
    }
}
