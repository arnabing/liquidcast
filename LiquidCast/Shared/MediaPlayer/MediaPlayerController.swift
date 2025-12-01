import AVFoundation
import Combine

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

    // MARK: - Initialization

    override init() {
        super.init()
        setupPlayer()
    }

    deinit {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
        }
    }

    // MARK: - Setup

    private func setupPlayer() {
        let player = AVPlayer()

        // Enable AirPlay with highest quality (direct streaming)
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true

        // Prefer highest quality for external playback
        player.externalPlaybackVideoGravity = .resizeAspect

        self.player = player

        setupTimeObserver()
        observePlaybackState()
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
                self?.onPlaybackStateChanged?(isPlaying)
            }
            .store(in: &cancellables)
    }

    // MARK: - Media Loading

    func loadMedia(from url: URL) {
        // Create asset with options for network optimization
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: true
        ])

        let playerItem = AVPlayerItem(asset: asset)

        // Observe when ready to play
        playerItem.publisher(for: \.status)
            .sink { [weak self] status in
                switch status {
                case .readyToPlay:
                    self?.isReady = true
                    self?.error = nil
                case .failed:
                    self?.isReady = false
                    self?.error = playerItem.error
                default:
                    break
                }
            }
            .store(in: &cancellables)

        self.playerItem = playerItem
        player?.replaceCurrentItem(with: playerItem)
    }

    // MARK: - Playback Control

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
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
}
