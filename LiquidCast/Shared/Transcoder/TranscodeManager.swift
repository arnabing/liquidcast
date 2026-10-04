import Foundation
import os.log

private let logger = Logger(subsystem: "com.liquidcast", category: "Transcoder")

/// Error types for transcoding operations
enum TranscodeError: LocalizedError {
    case ffmpegNotFound
    case conversionFailed(String)
    case cancelled
    case notSupportedOnPlatform

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "FFmpeg not found. Please install it with: brew install ffmpeg"
        case .conversionFailed(let message):
            return "Conversion failed: \(message)"
        case .cancelled:
            return "Conversion was cancelled"
        case .notSupportedOnPlatform:
            return "Video conversion is not supported on this platform. Please use an MP4 file."
        }
    }
}

/// What an Apple TV receiver can be sent untouched
struct Passthrough: OptionSet, Hashable {
    let rawValue: Int

    /// HEVC/HDR video (fMP4 segments)
    static let hevc = Passthrough(rawValue: 1 << 0)
    /// AC-3/E-AC-3 (incl. Atmos) audio
    static let dolbyAudio = Passthrough(rawValue: 1 << 1)
    /// An Apple-native MP4/MOV played directly from the file
    static let nativeFile = Passthrough(rawValue: 1 << 2)

    static let all: Passthrough = [.hevc, .dolbyAudio, .nativeFile]

    /// When passed-through playback fails, the most likely culprit first: HEVC (e.g. Apple TV HD),
    /// then playing the file directly, then Dolby audio (which every Apple TV decodes)
    static let suspicionOrder: [Passthrough] = [.hevc, .nativeFile, .dolbyAudio]

    var name: String {
        switch self {
        case .hevc: return "HEVC/HDR"
        case .dolbyAudio: return "Dolby audio"
        case .nativeFile: return "direct file playback"
        default: return "passthrough \(rawValue)"
        }
    }
}

/// Whether to draw a bitmap subtitle track (PGS/VobSub/DVB) into the video
enum SubtitleBurnIn: Equatable {
    /// A bitmap track the file marks forced (meant to always show, e.g. translated signs), but only when
    /// the video is re-encoded anyway: it never costs passthrough (HEVC/HDR) on its own
    case automatic
    case off
    /// This subtitle stream (ffprobe index)
    case stream(Int)
}

/// Turns a media file into something AirPlay can play: the file itself, or an on-demand HLS stream.
/// The actual implementation is in platform-specific extensions.
@MainActor
class TranscodeManager: ObservableObject {
    // MARK: - Published Properties

    @Published var isConverting = false  // Analyzing/preparing before playback can start
    @Published var isStreaming = false   // An HLS session is being served
    @Published var progress: Double = 0
    @Published var statusMessage: String = ""
    @Published var currentFileName: String = ""
    @Published var ultraQualityAudio = false  // Higher video bitrates + 320kbps AAC keeping 5.1

    // Streaming info (populated after media analysis)
    @Published var outputResolution: String = ""     // "1080p" or "4K"
    @Published var outputVideoCodec: String = ""     // "H.264", "HEVC", "HEVC HDR10"
    @Published var outputAudioCodec: String = ""     // "AAC"
    @Published var outputAudioChannels: String = ""  // "5.1" or "Stereo"
    @Published var sourceDuration: Double = 0        // Full source file duration from ffprobe
    /// Subtitle tracks of the current file (text: selectable renditions; image: burn-in)
    @Published var subtitleTracks: [SubtitleTrack] = []
    /// Bitmap subtitle stream burned into the current stream, if any
    @Published var burnedInSubtitle: Int?

    /// What the current playback passes through untouched. If it fails, `AppState` retries without
    /// the most likely culprit.
    var passthroughUsed: Passthrough = []

    // MARK: - Streaming (macOS)

    #if os(macOS)
    /// Sessions the HTTP server may route to (read from the server's threads)
    let sessionRegistry = HLSSessionRegistry()
    /// Serves `/<session>/...` (playlists, init, segments). Started on first use, kept for the app's lifetime.
    lazy var httpServer = LocalHTTPServer(handler: Self.makeRequestHandler(registry: sessionRegistry))
    var activeSession: HLSSession?
    /// Bumped on every prepare/stop, so a superseded preparation can tell it lost the race
    var preparationGeneration = 0
    #endif

    // MARK: - Public Methods

    /// Prepare a media file for AirPlay.
    /// - Parameters:
    ///   - url: Source file URL
    ///   - mode: Compatibility mode for target device (Apple TV allows more formats than Smart TVs)
    ///   - startPosition: Resume position in seconds. HLS streams start there by themselves;
    ///     for a returned file URL the caller seeks.
    ///   - passthrough: What the receiver accepts untouched (Apple TV: HEVC/HDR, Dolby audio, native files)
    /// - Returns: The file URL itself (directly playable) or an http:// HLS playlist URL
    ///   - burnIn: Bitmap subtitles to draw into the video
    func prepareForAirPlay(from url: URL, mode: CompatibilityMode = .appleTV, startPosition: Double = 0,
                           passthrough: Passthrough = [], burnIn: SubtitleBurnIn = .automatic) async throws -> URL {
        logger.info("🔄 Preparing \(url.lastPathComponent) (mode: \(mode.rawValue), start: \(Int(startPosition))s, passthrough: \(passthrough.rawValue))")
        return try await performPreparation(from: url, mode: mode, startPosition: startPosition,
                                            passthrough: passthrough, burnIn: burnIn)
    }

    #if !os(macOS)
    func currentPlaylistURL(startTime: Double = 0) -> URL? { nil }
    func segmentsDeliveredAhead(of position: Double) async -> Int? { nil }
    #endif

    /// Stop the current stream (kills FFmpeg, deletes its segments)
    func stopStreaming() {
        passthroughUsed = []
        burnedInSubtitle = nil
        #if os(macOS)
        preparationGeneration += 1
        if let session = activeSession {
            activeSession = nil
            sessionRegistry.remove(session)
            Task { await session.stop() }
        }
        isConverting = false
        isStreaming = false
        #endif
    }

    /// Cancel an in-progress preparation
    func cancel() {
        logger.info("Cancelling conversion...")
        statusMessage = "Cancelled"
        stopStreaming()
    }
}
