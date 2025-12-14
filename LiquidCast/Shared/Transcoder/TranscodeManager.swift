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

    // MARK: - Internal Properties (accessed by extensions)

    var isCancelled = false
    var currentProcess: Any? = nil  // FFmpegProcess on macOS

    // MARK: - HTTP Server (for HLS streaming over AirPlay)

    #if os(macOS)
    let httpServer = LocalHTTPServer()
    #endif

    // MARK: - Public Methods

    /// Convert a media file to MP4 for AirPlay compatibility
    /// - Parameters:
    ///   - url: Source file URL
    ///   - mode: Compatibility mode for target device (Apple TV allows more formats than Smart TVs)
    /// - Returns: URL to the converted MP4 file
    func convertForAirPlay(from url: URL, mode: CompatibilityMode = .appleTV) async throws -> URL {
        logger.info("🔄 convertForAirPlay called for: \(url.lastPathComponent) (mode: \(mode.rawValue))")

        // Call the platform-specific implementation
        // macOS: TranscodeManagerMacOS.swift provides the real implementation
        // iOS: TranscodeManageriOS.swift provides a stub that throws
        return try await performConversion(from: url, mode: mode)
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
}
