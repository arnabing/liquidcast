import Foundation
import os.log

private let logger = Logger(subsystem: "com.liquidcast", category: "MediaAnalyzer")

/// Information about a single media stream
struct StreamInfo {
    let index: Int
    let codecType: String       // "video" or "audio"
    let codecName: String       // "h264", "hevc", "aac", "dts", etc.
    let profile: String?        // "High", "Main", "Baseline" for H.264
    let pixelFormat: String?    // "yuv420p", "yuv420p10le" (10-bit)
    let width: Int?
    let height: Int?
    let channels: Int?
    let sampleRate: Int?
}

/// Conversion path ordered by speed (lower = faster)
enum ConversionPath: Int, Comparable, CustomStringConvertible {
    case directPlayback = 0      // No FFmpeg needed
    case fastRemux = 1           // Container change only (MKV -> MP4)
    case audioTranscode = 2      // Copy video, transcode audio to AAC
    case videoTranscode = 3      // Full transcode to H.264+AAC

    static func < (lhs: ConversionPath, rhs: ConversionPath) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String {
        switch self {
        case .directPlayback: return "Direct Playback"
        case .fastRemux: return "Fast Remux"
        case .audioTranscode: return "Audio Transcode"
        case .videoTranscode: return "Full Transcode"
        }
    }
}

/// Complete media analysis result
struct MediaAnalysis {
    let container: String
    let duration: Double?
    let fileSize: Int64
    let videoStreams: [StreamInfo]
    let audioStreams: [StreamInfo]

    /// Primary video stream (first one)
    var primaryVideo: StreamInfo? { videoStreams.first }

    /// Primary audio stream (first one)
    var primaryAudio: StreamInfo? { audioStreams.first }

    /// Check if video is 10-bit (HDR)
    var is10BitVideo: Bool {
        guard let pixelFormat = primaryVideo?.pixelFormat else { return false }
        return pixelFormat.contains("10le") || pixelFormat.contains("10be") || pixelFormat.contains("p10")
    }

    /// Check if container is AirPlay-compatible
    var isNativeContainer: Bool {
        let native = ["mov", "mp4", "m4v", "mov,mp4,m4a,3gp,3g2,mj2"]
        return native.contains(container.lowercased())
    }

    /// Check if video codec is H.264
    var isH264Video: Bool {
        guard let codec = primaryVideo?.codecName.lowercased() else { return false }
        return codec == "h264" || codec == "avc1" || codec == "avc"
    }

    /// Check if video codec is H.265/HEVC
    var isHEVCVideo: Bool {
        guard let codec = primaryVideo?.codecName.lowercased() else { return false }
        return codec == "hevc" || codec == "hvc1" || codec == "hev1"
    }

    /// Check if audio is AAC-compatible (no transcode needed)
    var isAACCompatibleAudio: Bool {
        guard let codec = primaryAudio?.codecName.lowercased() else { return true } // No audio = OK
        return ["aac", "mp3", "alac", "pcm_s16le", "pcm_s24le"].contains(codec)
    }

    /// Determine the optimal conversion path for AirPlay
    var conversionPath: ConversionPath {
        // No video = direct playback (audio only)
        guard primaryVideo != nil else {
            return .directPlayback
        }

        // H.265 over AirPlay is unreliable - always transcode
        if isHEVCVideo {
            return .videoTranscode
        }

        // 10-bit video needs transcode (AirPlay doesn't support it well)
        if is10BitVideo {
            return .videoTranscode
        }

        // Non-H.264 video needs full transcode
        if !isH264Video {
            return .videoTranscode
        }

        // At this point: H.264 video, 8-bit

        // Check audio compatibility
        let needsAudioTranscode = !isAACCompatibleAudio

        // Check container compatibility
        if isNativeContainer {
            if needsAudioTranscode {
                return .audioTranscode
            }
            return .directPlayback
        }

        // Non-native container (MKV, AVI, etc.)
        if needsAudioTranscode {
            return .audioTranscode  // Will also handle container via HLS
        }
        return .fastRemux  // Just container change
    }

    /// Human-readable summary
    var summary: String {
        let video = primaryVideo.map { "\($0.codecName)\(is10BitVideo ? " 10-bit" : "")" } ?? "none"
        let audio = primaryAudio?.codecName ?? "none"
        return "[\(container)] video=\(video) audio=\(audio) → \(conversionPath)"
    }
}

/// Analyzes media files using ffprobe
enum MediaAnalyzer {

    /// Analyze a media file
    /// - Parameters:
    ///   - url: File URL to analyze
    ///   - ffprobePath: Path to ffprobe binary
    /// - Returns: MediaAnalysis with all stream info and recommended conversion path
    static func analyze(url: URL, ffprobePath: String) async throws -> MediaAnalysis {
        guard FileManager.default.fileExists(atPath: ffprobePath) else {
            throw MediaAnalyzerError.ffprobeNotFound
        }

        // Get file size
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = attrs?[.size] as? Int64 ?? 0

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffprobePath)
        process.arguments = [
            "-v", "quiet",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            "-analyzeduration", "10000000",  // 10 seconds max
            "-probesize", "10000000",         // 10MB max
            url.path
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()

                do {
                    let analysis = try parseFFprobeOutput(data, fileSize: fileSize)
                    logger.info("📊 \(analysis.summary)")
                    continuation.resume(returning: analysis)
                } catch {
                    logger.error("❌ ffprobe parse failed: \(error.localizedDescription)")
                    continuation.resume(throwing: error)
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: MediaAnalyzerError.ffprobeFailed(error.localizedDescription))
            }
        }
    }

    /// Find ffprobe binary (next to ffmpeg)
    static func findFFprobe(ffmpegPath: String) -> String? {
        let ffprobePath = ffmpegPath.replacingOccurrences(of: "ffmpeg", with: "ffprobe")
        return FileManager.default.fileExists(atPath: ffprobePath) ? ffprobePath : nil
    }

    // MARK: - Private

    private static func parseFFprobeOutput(_ data: Data, fileSize: Int64) throws -> MediaAnalysis {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaAnalyzerError.invalidOutput
        }

        // Parse format info
        let format = json["format"] as? [String: Any] ?? [:]
        let formatName = format["format_name"] as? String ?? "unknown"
        let duration = (format["duration"] as? String).flatMap { Double($0) }

        // Parse streams
        let streams = json["streams"] as? [[String: Any]] ?? []
        var videoStreams: [StreamInfo] = []
        var audioStreams: [StreamInfo] = []

        for stream in streams {
            let codecType = stream["codec_type"] as? String ?? ""

            let info = StreamInfo(
                index: stream["index"] as? Int ?? 0,
                codecType: codecType,
                codecName: stream["codec_name"] as? String ?? "unknown",
                profile: stream["profile"] as? String,
                pixelFormat: stream["pix_fmt"] as? String,
                width: stream["width"] as? Int,
                height: stream["height"] as? Int,
                channels: stream["channels"] as? Int,
                sampleRate: (stream["sample_rate"] as? String).flatMap { Int($0) }
            )

            switch codecType {
            case "video": videoStreams.append(info)
            case "audio": audioStreams.append(info)
            default: break
            }
        }

        return MediaAnalysis(
            container: formatName,
            duration: duration,
            fileSize: fileSize,
            videoStreams: videoStreams,
            audioStreams: audioStreams
        )
    }
}

enum MediaAnalyzerError: LocalizedError {
    case ffprobeNotFound
    case ffprobeFailed(String)
    case invalidOutput
    case timeout

    var errorDescription: String? {
        switch self {
        case .ffprobeNotFound:
            return "ffprobe not found. Install with: brew install ffmpeg"
        case .ffprobeFailed(let msg):
            return "ffprobe failed: \(msg)"
        case .invalidOutput:
            return "Could not parse ffprobe output"
        case .timeout:
            return "Timed out analyzing file"
        }
    }
}
