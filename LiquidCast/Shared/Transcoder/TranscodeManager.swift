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

    /// The current stream passes HEVC through (the receiver must decode HEVC)
    var isHEVCPassthrough = false

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
    ///   - allowHEVC: The receiver decodes HEVC/HDR (Apple TV 4K): pass HEVC through untouched
    /// - Returns: The file URL itself (directly playable) or an http:// HLS playlist URL
    func prepareForAirPlay(from url: URL, mode: CompatibilityMode = .appleTV, startPosition: Double = 0,
                           allowHEVC: Bool = false) async throws -> URL {
        logger.info("🔄 Preparing \(url.lastPathComponent) (mode: \(mode.rawValue), start: \(Int(startPosition))s, HEVC: \(allowHEVC))")
        return try await performPreparation(from: url, mode: mode, startPosition: startPosition, allowHEVC: allowHEVC)
    }

    /// Stop the current stream (kills FFmpeg, deletes its segments)
    func stopStreaming() {
        isHEVCPassthrough = false
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
