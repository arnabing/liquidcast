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
    /// True while the player wants to play but is waiting for data
    var onBufferingChanged: ((Bool) -> Void)?
    /// The current item can't be played (e.g. the AirPlay receiver can't decode it)
    var onItemFailed: ((Error?) -> Void)?
    /// Text subtitle options of the current item (HLS renditions or the file's own tracks); names in order
    var onSubtitleOptionsChanged: (([String]) -> Void)?
    /// The shown text subtitle option changed (by the app, the player's automatic choice, or the TV)
    var onSubtitleSelectionChanged: ((Int?) -> Void)?

    /// Which text subtitles to show when an item loads
    enum SubtitleSelection: Equatable {
        /// The player's own choice (system preferences, forced renditions)
        case automatic
        case off
        case option(Int)
    }

    /// URL of the current item
    private(set) var currentURL: URL?
    private var legibleGroup: AVMediaSelectionGroup?
    var onProgressChanged: ((Double, Double) -> Void)?
    var onDurationChanged: ((Double) -> Void)?

    // MARK: - Source Duration (clamps seeks before the item reports its duration)

    /// Full source duration from ffprobe - allows seeking beyond transcoded portion
    var sourceDuration: Double = 0

    // MARK: - Private Properties

    private var timeObserver: Any?
    private var durationObserver: NSKeyValueObservation?
    private var cancellables = Set<AnyCancellable>()
    /// Observers of the current item only (replaced on every load, so stale items can't act)
    private var itemCancellables = Set<AnyCancellable>()

    // MARK: - Sleep Prevention

    #if os(macOS)
    private var sleepAssertionID: IOPMAssertionID = 0
    private var isSleepPrevented: Bool = false
    /// Opts out of App Nap, which otherwise throttles the HLS server/FFmpeg when the window is hidden
    private var appNapActivity: NSObjectProtocol?
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
            let totalSeconds = duration.seconds

            let currentSeconds = time.seconds

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
                self?.onBufferingChanged?(status == .waitingToPlayAtSpecifiedRate)
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

    /// - Parameter startTime: Position to seek to before playback starts (HLS streams carry
    ///   their own start position in the playlist, so pass 0 for those)
    /// - Parameter subtitles: Text subtitles to show once the item is ready
    func loadMedia(from url: URL, startTime: Double = 0, subtitles: SubtitleSelection = .automatic) {
        logger.info("📂 Loading media from: \(url.absoluteString)")
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
        itemCancellables.removeAll()
        isReady = false
        currentURL = url
        legibleGroup = nil
        onSubtitleOptionsChanged?([])
        Task { @MainActor [weak self] in
            // Subtitle choices come from the asset itself, so they work for streams and files alike
            let group = try? await asset.loadMediaSelectionGroup(for: .legible)
            guard let self, self.playerItem === playerItem else { return }
            self.legibleGroup = group
            if let group {
                switch subtitles {
                case .automatic: break
                case .off: playerItem.select(nil, in: group)
                case .option(let index) where index < group.options.count: playerItem.select(group.options[index], in: group)
                case .option: break
                }
            }
            self.onSubtitleOptionsChanged?(group?.options.map(\.displayName) ?? [])
            self.onSubtitleSelectionChanged?(self.selectedSubtitleIndex)
        }

        // Observe when ready to play
        var hasStarted = false
        playerItem.publisher(for: \.status)
            .sink { [weak self] status in
                switch status {
                case .readyToPlay:
                    logger.info("✅ PlayerItem ready to play")
                    self?.isReady = true
                    self?.error = nil
                    guard !hasStarted else { return }
                    hasStarted = true
                    if startTime > 0 {
                        self?.seek(to: startTime) { _ in self?.play() }
                    } else {
                        self?.play()  // Auto-play when ready
                    }
                case .failed:
                    logger.error("❌ PlayerItem failed: \(playerItem.error?.localizedDescription ?? "unknown")")
                    self?.isReady = false
                    self?.error = playerItem.error
                    self?.onItemFailed?(playerItem.error)
                case .unknown:
                    logger.info("⏳ PlayerItem status unknown (loading...)")
                @unknown default:
                    break
                }
            }
            .store(in: &itemCancellables)

        // Follow the shown subtitle, whoever changed it
        playerItem.publisher(for: \.currentMediaSelection)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.onSubtitleSelectionChanged?(self?.selectedSubtitleIndex) }
            .store(in: &itemCancellables)

        // Fails mid-playback (after readyToPlay) are reported here rather than via status
        NotificationCenter.default.publisher(for: AVPlayerItem.failedToPlayToEndTimeNotification, object: playerItem)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                logger.error("❌ PlayerItem failed to play to end: \(error?.localizedDescription ?? "unknown")")
                self?.onItemFailed?(error)
            }
            .store(in: &itemCancellables)

        // Observe player item errors
        playerItem.publisher(for: \.error)
            .sink { error in
                if let error = error {
                    logger.error("❌ PlayerItem error: \(error.localizedDescription)")
                }
            }
            .store(in: &itemCancellables)

        self.playerItem = playerItem
        player?.replaceCurrentItem(with: playerItem)
        logger.info("📼 PlayerItem set on AVPlayer")

        // Observe duration changes (critical for HLS streams where duration updates over time)
        durationObserver = playerItem.observe(\.duration, options: [.new]) { [weak self] item, _ in
            let duration = item.duration
            if duration.isValid && !duration.isIndefinite && duration.seconds > 0 {
                logger.info("⏱️ Duration updated: \(duration.seconds)s")
                self?.onDurationChanged?(duration.seconds)
            }
        }
    }

    // MARK: - Playback Control

    /// Show text subtitle option `index` (as reported by `onSubtitleOptionsChanged`), or none
    func selectSubtitle(at index: Int?) {
        guard let item = playerItem, let group = legibleGroup else { return }
        let option = index.flatMap { $0 < group.options.count ? group.options[$0] : nil }
        item.select(option, in: group)
    }

    /// Index of the selected text subtitle option, if any
    var selectedSubtitleIndex: Int? {
        guard let item = playerItem, let group = legibleGroup,
              let selected = item.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return group.options.firstIndex(of: selected)
    }

    /// Seconds of media loaded ahead of the playhead
    var bufferedAhead: Double {
        guard let item = playerItem else { return 0 }
        let now = item.currentTime().seconds
        let end = item.loadedTimeRanges.map(\.timeRangeValue).filter { $0.containsTime(item.currentTime()) }
            .map { ($0.start + $0.duration).seconds }.max()
        return max((end ?? now) - now, 0)
    }

    /// Stop and drop the current item (e.g. while the next file is being prepared, so the old
    /// item's progress can't be attributed to the new file)
    func unload() {
        itemCancellables.removeAll()
        durationObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        playerItem = nil
        currentURL = nil
        legibleGroup = nil
        onSubtitleOptionsChanged?([])
        isReady = false
        allowSleep()
    }

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

    /// Seek to a position in seconds. `completion` receives false if the seek was interrupted
    /// by another seek. (Streams expose their full duration, so any position is seekable.)
    func seek(to position: Double, completion: ((Bool) -> Void)? = nil) {
        guard let player, let playerItem else {
            logger.warning("⏭️ Cannot seek: no player item")
            completion?(false)
            return
        }

        let maxDuration: Double
        if playerItem.duration.isValid && !playerItem.duration.isIndefinite {
            maxDuration = playerItem.duration.seconds
        } else {
            maxDuration = sourceDuration
        }
        let clamped = maxDuration > 0 ? min(max(position, 0), maxDuration) : max(position, 0)
        let targetTime = CMTime(seconds: clamped, preferredTimescale: CMTimeScale(NSEC_PER_SEC))

        // Tolerant seeking: lands on a nearby keyframe instead of decoding up to the exact frame
        let tolerance = CMTime(seconds: 1.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        player.seek(to: targetTime, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
            DispatchQueue.main.async { completion?(finished) }
        }
        logger.info("⏭️ Seeking to \(Int(clamped))s")
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
        if appNapActivity == nil {
            appNapActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "LiquidCast streaming to AirPlay"
            )
        }

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
        if let activity = appNapActivity {
            ProcessInfo.processInfo.endActivity(activity)
            appNapActivity = nil
        }

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
