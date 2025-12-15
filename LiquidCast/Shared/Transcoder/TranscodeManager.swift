import Foundation
import os.log

private let logger = Logger(subsystem: "com.liquidcast", category: "Transcoder")

/// Error types for transcoding operations
enum TranscodeError: LocalizedError {
    case ffmpegNotFound
    case conversionFailed(String)
    case cancelled
    case outputNotCreated
    case notSupportedOnPlatform

    var errorDescription: String? {
        switch self {
        case .ffmpegNotFound:
            return "FFmpeg not found. Please install it with: brew install ffmpeg"
        case .conversionFailed(let message):
            return "Conversion failed: \(message)"
        case .cancelled:
            return "Conversion was cancelled"
        case .outputNotCreated:
            return "Output file was not created"
        case .notSupportedOnPlatform:
            return "Video conversion is not supported on this platform. Please use an MP4 file."
        }
    }
}

/// Manages media file conversion using FFmpeg
/// The actual implementation is in platform-specific extensions
@MainActor
class TranscodeManager: ObservableObject {
    // MARK: - Published Properties

    @Published var isConverting = false
    @Published var isStreaming = false  // True when HLS server is actively streaming
    @Published var progress: Double = 0
    @Published var statusMessage: String = ""
    @Published var currentFileName: String = ""
    @Published var ultraQualityAudio = false  // 320kbps AAC with 5.1 surround

    // Streaming info (populated after media analysis)
    @Published var outputResolution: String = ""     // "1080p" or "4K"
    @Published var outputVideoCodec: String = ""     // "H.264" or "HEVC"
    @Published var outputAudioCodec: String = ""     // "AAC"
    @Published var outputAudioChannels: String = ""  // "5.1" or "Stereo"
    @Published var sourceDuration: Double = 0        // Full source file duration from ffprobe

    // MARK: - Internal Properties (accessed by extensions)

    var isCancelled = false
    var currentProcess: Any? = nil  // FFmpegProcess on macOS

    // MARK: - Current Transcode State (for seek restart)

    /// Current source URL being transcoded
    var currentSourceURL: URL?
    /// Current media analysis (cached for seek restart)
    var currentAnalysis: MediaAnalysis?
    /// Current compatibility mode
    var currentMode: CompatibilityMode = .appleTV
    /// Current seek offset (in seconds) - used when restarting from seek position
    var currentSeekOffset: Double = 0

    // MARK: - HTTP Server (for HLS streaming over AirPlay)

    #if os(macOS)
    let httpServer = LocalHTTPServer()
    #endif

    // MARK: - Device Detection

    /// Device name currently being converted for (used for HEVC detection)
    var currentDeviceName: String?

    /// Whether the current device supports HEVC (detected from device name)
    var deviceSupportsHEVC: Bool {
        guard let name = currentDeviceName else { return false }
        return CompatibilityMode.detectWithHEVC(from: name).hevcSupported
    }

    // MARK: - Public Methods

    /// Convert a media file to MP4 for AirPlay compatibility
    /// - Parameters:
    ///   - url: Source file URL
    ///   - mode: Compatibility mode for target device (Apple TV allows more formats than Smart TVs)
    ///   - deviceName: Name of the AirPlay device (used for HEVC capability detection)
    ///   - startPosition: Optional start position in seconds (for resuming playback)
    /// - Returns: URL to the converted MP4 file
    func convertForAirPlay(from url: URL, mode: CompatibilityMode = .appleTV, deviceName: String? = nil, startPosition: Double = 0) async throws -> URL {
        currentDeviceName = deviceName
        currentSeekOffset = startPosition

        if startPosition > 0 {
            logger.info("🔄 convertForAirPlay called for: \(url.lastPathComponent) (mode: \(mode.rawValue), hevc: \(self.deviceSupportsHEVC), startAt: \(Int(startPosition))s)")
        } else {
            logger.info("🔄 convertForAirPlay called for: \(url.lastPathComponent) (mode: \(mode.rawValue), hevc: \(self.deviceSupportsHEVC))")
        }

        // Call the platform-specific implementation
        // macOS: TranscodeManagerMacOS.swift provides the real implementation
        // iOS: TranscodeManageriOS.swift provides a stub that throws
        return try await performConversion(from: url, mode: mode, startPosition: startPosition)
    }

    /// Cancel the current conversion
    func cancel() {
        logger.info("Cancelling conversion...")
        isCancelled = true
        statusMessage = "Cancelling..."

        #if os(macOS)
        cancelMacOSProcess()
        #endif
    }

    #if os(macOS)
    /// Cancel the FFmpeg process on macOS
    private func cancelMacOSProcess() {
        if let ffmpegProcess = currentProcess as? FFmpegProcess {
            Task {
                await ffmpegProcess.terminate()
            }
        }
    }
    #endif

    /// Stop the HTTP server (call when loading new media or cleaning up)
    func stopServer() {
        #if os(macOS)
        httpServer.stop()
        isStreaming = false
        #endif
    }

    /// Restart transcoding from a specific position (for seeking beyond transcoded content)
    /// - Parameters:
    ///   - position: The seek position in seconds
    ///   - sourceURL: The source file URL
    ///   - mode: Compatibility mode for target device
    /// - Returns: URL to the new HLS stream starting from the seek position
    func seekTranscode(to position: Double, from sourceURL: URL, mode: CompatibilityMode) async throws -> URL {
        logger.info("🎯 Seek-restart transcoding to \(Int(position))s")

        #if os(macOS)
        return try await performSeekTranscode(to: position, from: sourceURL, mode: mode)
        #else
        throw TranscodeError.notSupportedOnPlatform
        #endif
    }
}
