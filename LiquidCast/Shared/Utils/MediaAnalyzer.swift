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
    /// Stream start (seconds, container timestamps) and length, if the container says
    let startTime: Double?
    let duration: Double?
    /// Video: transfer characteristic ("smpte2084" = PQ, "arib-std-b67" = HLG, "bt709", ...)
    var colorTransfer: String? = nil
    /// Video: frames per second (average)
    var frameRate: Double? = nil
    /// Video: Dolby Vision profile, if the stream carries Dolby Vision
    var dolbyVisionProfile: Int? = nil
    /// Video: display rotation in degrees (phone videos are often stored landscape, rotated ±90)
    var rotation: Int = 0
    /// Bits/s, if the container says (Matroska: the `BPS` tag)
    var bitRate: Int? = nil
    /// Sample entry / FourCC in MP4/MOV ("avc1", "hvc1", "hev1", "ec-3", ...)
    var codecTag: String? = nil
    /// Marked as the default track of its type
    var isDefault: Bool = false
    /// ISO 639 language tag, if any
    var language: String? = nil
    var title: String? = nil
    /// Marked forced (subtitles meant to always show, e.g. for foreign-language dialogue)
    var isForced: Bool = false

    var isDolbyAudio: Bool { codecName.lowercased() == "ac3" || codecName.lowercased() == "eac3" }

    /// Size as displayed (width/height swapped for ±90° rotation)
    var displaySize: (width: Int, height: Int)? {
        guard let width, let height else { return nil }
        return abs(rotation) % 180 == 90 ? (height, width) : (width, height)
    }
}

/// Dynamic range of a video stream, as HLS `VIDEO-RANGE` names it
enum VideoRange: String {
    case sdr = "SDR"
    case pq = "PQ"
    case hlg = "HLG"
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
    /// Container start time (seconds). FFmpeg seeks and timestamps are relative to this.
    let startTime: Double
    let fileSize: Int64
    let videoStreams: [StreamInfo]
    let audioStreams: [StreamInfo]
    var subtitleStreams: [StreamInfo] = []

    /// Subtitle streams that can be shown (text as renditions, bitmaps by burning in)
    var subtitleTracks: [SubtitleTrack] { subtitleStreams.compactMap(SubtitleTrack.init(stream:)) }

    /// Average bitrate of the whole file (bits/s), if known
    var bitRate: Int? = nil

    /// Primary video stream (first one)
    var primaryVideo: StreamInfo? { videoStreams.first }

    /// Primary audio stream: the one marked default, else the first
    var primaryAudio: StreamInfo? { audioStreams.first { $0.isDefault } ?? audioStreams.first }

    /// Audio to stream. With `preferDolby` (receiver plays AC-3/E-AC-3), a Dolby track in the primary
    /// track's language beats a primary TrueHD/DTS one: common MKV layout is TrueHD Atmos first, then a
    /// compatible E-AC-3/AC-3 track, and passing that through beats converting to AAC.
    func audioStream(preferDolby: Bool) -> StreamInfo? {
        guard let primary = primaryAudio else { return nil }
        guard preferDolby, !primary.isDolbyAudio else { return primary }
        return audioStreams.first { $0.isDolbyAudio && $0.language == primary.language } ?? primary
    }

    /// Check if video is 10-bit (HDR)
    var is10BitVideo: Bool {
        guard let pixelFormat = primaryVideo?.pixelFormat else { return false }
        return pixelFormat.contains("10le") || pixelFormat.contains("10be") || pixelFormat.contains("p10")
    }

    /// 8-bit 4:2:0 H.264 in a profile Apple TV decodes - safe to pass through untouched
    var isAppleDecodableH264: Bool {
        guard isH264Video, let video = primaryVideo else { return false }
        let pixelFormatOK = ["yuv420p", "yuvj420p"].contains(video.pixelFormat ?? "yuv420p")
        let profileOK = ["baseline", "constrained baseline", "main", "high"].contains((video.profile ?? "high").lowercased())
        return pixelFormatOK && profileOK
    }

    var videoRange: VideoRange {
        switch primaryVideo?.colorTransfer {
        case "smpte2084": return .pq
        case "arib-std-b67": return .hlg
        default: return .sdr
        }
    }

    /// HEVC that Apple TV 4K plays as-is: Main or Main 10, 4:2:0, SDR/HDR10/HLG. Dolby Vision only
    /// when it has an HDR10/SDR-compatible base layer (profiles 7 and 8), which plays once the DV
    /// data is stripped; profile 5's base layer isn't watchable on its own.
    var isPassthroughHEVC: Bool {
        guard isHEVCVideo, let video = primaryVideo else { return false }
        let pixelFormatOK = ["yuv420p", "yuv420p10le"].contains(video.pixelFormat ?? "")
        let profileOK = ["main", "main 10"].contains((video.profile ?? "").lowercased())
        let dolbyVisionOK = video.dolbyVisionProfile.map { [7, 8].contains($0) } ?? true
        return pixelFormatOK && profileOK && dolbyVisionOK
    }

    /// AC-3 or E-AC-3 (incl. Dolby Atmos in E-AC-3): Apple TV decodes these natively
    var isDolbyAudio: Bool { primaryAudio?.isDolbyAudio ?? false }

    /// An MP4/MOV that Apple TV plays as-is when the receiver supports passthrough: H.264, or HEVC
    /// tagged `hvc1` (Apple players reject `hev1`) without Dolby Vision, with AAC-family or Dolby
    /// audio - in *every* audio track, since the player picks the track by language, not order
    var isAppleNativeFile: Bool {
        guard isNativeContainer, let video = primaryVideo else { return false }
        let videoOK = isAppleDecodableH264
            || (isPassthroughHEVC && video.codecTag == "hvc1" && video.dolbyVisionProfile == nil)
        let aacFamily = ["aac", "mp3", "alac", "pcm_s16le", "pcm_s24le"]
        let audioOK = audioStreams.allSatisfy { $0.isDolbyAudio || aacFamily.contains($0.codecName.lowercased()) }
        return videoOK && audioOK
    }

    /// Whether playing this file directly relies on the receiver's HEVC / Dolby support
    var nativeFileNeedsHEVC: Bool { isHEVCVideo }
    var nativeFileNeedsDolbyAudio: Bool { audioStreams.contains { $0.isDolbyAudio } }

    /// End of the video stream in media time (seconds from the container start). Audio often runs
    /// past the video; segments must only cover what the video actually contains.
    var videoEnd: Double? {
        guard let duration else { return nil }
        guard let video = primaryVideo, let videoDuration = video.duration, videoDuration > 0 else { return duration }
        let videoStart = (video.startTime ?? startTime) - startTime
        return min(duration, videoStart + videoDuration)
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

        // HEVC: re-encoded to H.264 here; HEVC passthrough (receiver permitting) is decided in
        // StreamProfile.make, which needs to know the receiver
        if isHEVCVideo {
            return .videoTranscode
        }

        // Anything but 8-bit 4:2:0 H.264 in a standard profile needs a full transcode
        if !isAppleDecodableH264 {
            return .videoTranscode
        }

        // At this point: H.264 video, 8-bit 4:2:0

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

/// A subtitle stream of the source
struct SubtitleTrack: Sendable, Equatable, Hashable {
    enum Kind: Sendable {
        /// Text (SRT, ASS, WebVTT, mov_text, …): served as a WebVTT rendition the player can switch
        case text
        /// Bitmaps (PGS, VobSub, DVB): can only be shown by burning them into the video
        case image
    }

    let streamIndex: Int
    let kind: Kind
    /// FFmpeg codec name ("subrip", "ass", "hdmv_pgs_subtitle", …)
    let codec: String
    let language: String?
    let title: String?
    let isDefault: Bool
    let isForced: Bool

    static let textCodecs: Set<String> = ["subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text", "subviewer", "microdvd"]
    static let imageCodecs: Set<String> = ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"]

    init?(stream: StreamInfo) {
        let codec = stream.codecName.lowercased()
        if Self.textCodecs.contains(codec) {
            kind = .text
        } else if Self.imageCodecs.contains(codec) {
            kind = .image
        } else {
            return nil  // e.g. closed captions, teletext: not supported
        }
        streamIndex = stream.index
        self.codec = codec
        language = stream.language
        title = stream.title
        isDefault = stream.isDefault
        isForced = stream.isForced
    }

    /// BCP 47 language for the HLS LANGUAGE attribute ("eng" → "en")
    var languageTag: String? {
        guard let language, language != "und" else { return nil }
        return Locale(identifier: language).language.languageCode?.identifier ?? language
    }

    /// Human-readable, e.g. "English (SDH)", "French — Forced"
    var displayName: String {
        var name = languageTag.flatMap { Locale.current.localizedString(forLanguageCode: $0) } ?? "Track \(streamIndex)"
        if let title, !title.isEmpty, title.lowercased() != name.lowercased() {
            name += " (\(title))"
        }
        if isForced { name += " — Forced" }
        return name
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

        let data: Data
        do {
            data = try await ProcessRunner.output(of: ffprobePath, arguments: [
                "-v", "quiet",
                "-print_format", "json",
                "-show_format",
                "-show_streams",
                "-analyzeduration", "10000000",  // 10 seconds max
                "-probesize", "10000000",         // 10MB max
                url.path
            ])
        } catch {
            throw MediaAnalyzerError.ffprobeFailed(error.localizedDescription)
        }

        do {
            let analysis = try parseFFprobeOutput(data, fileSize: fileSize)
            logger.info("📊 \(analysis.summary)")
            return analysis
        } catch {
            logger.error("❌ ffprobe parse failed: \(error.localizedDescription)")
            throw error
        }
    }

    /// Find ffprobe binary (next to ffmpeg)
    static func findFFprobe(ffmpegPath: String) -> String? {
        let ffprobePath = ffmpegPath.replacingOccurrences(of: "ffmpeg", with: "ffprobe")
        return FileManager.default.fileExists(atPath: ffprobePath) ? ffprobePath : nil
    }

    // MARK: - Private

    /// "24000/1001" → 23.976 (nil for "0/0")
    static func parseRate(_ text: String) -> Double? {
        let parts = text.split(separator: "/")
        guard parts.count == 2, let num = Double(parts[0]), let den = Double(parts[1]), den > 0, num > 0 else {
            return nil
        }
        return num / den
    }

    /// Matroska stores per-stream length as a tag, e.g. "01:52:03.125000000"
    static func parseClockDuration(_ text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else {
            return nil
        }
        return h * 3600 + m * 60 + s
    }

    private static func parseFFprobeOutput(_ data: Data, fileSize: Int64) throws -> MediaAnalysis {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MediaAnalyzerError.invalidOutput
        }

        // Parse format info
        let format = json["format"] as? [String: Any] ?? [:]
        let formatName = format["format_name"] as? String ?? "unknown"
        let duration = (format["duration"] as? String).flatMap { Double($0) }
        let startTime = (format["start_time"] as? String).flatMap { Double($0) } ?? 0

        // Parse streams
        let streams = json["streams"] as? [[String: Any]] ?? []
        var videoStreams: [StreamInfo] = []
        var audioStreams: [StreamInfo] = []
        var subtitleStreams: [StreamInfo] = []

        for stream in streams {
            let codecType = stream["codec_type"] as? String ?? ""

            // Cover art is exposed as a one-frame "video" stream - never treat it as the movie
            let disposition = stream["disposition"] as? [String: Any]
            if (disposition?["attached_pic"] as? Int) == 1 {
                continue
            }

            let info = StreamInfo(
                index: stream["index"] as? Int ?? 0,
                codecType: codecType,
                codecName: stream["codec_name"] as? String ?? "unknown",
                profile: stream["profile"] as? String,
                pixelFormat: stream["pix_fmt"] as? String,
                width: stream["width"] as? Int,
                height: stream["height"] as? Int,
                channels: stream["channels"] as? Int,
                sampleRate: (stream["sample_rate"] as? String).flatMap { Int($0) },
                startTime: (stream["start_time"] as? String).flatMap { Double($0) },
                duration: (stream["duration"] as? String).flatMap { Double($0) }
                    ?? ((stream["tags"] as? [String: Any])?["DURATION"] as? String).flatMap(parseClockDuration),
                colorTransfer: stream["color_transfer"] as? String,
                frameRate: (stream["avg_frame_rate"] as? String).flatMap(parseRate)
                    ?? (stream["r_frame_rate"] as? String).flatMap(parseRate),
                dolbyVisionProfile: (stream["side_data_list"] as? [[String: Any]])?
                    .first { ($0["side_data_type"] as? String)?.contains("DOVI") == true }?["dv_profile"] as? Int,
                rotation: ((stream["side_data_list"] as? [[String: Any]])?
                    .first { $0["side_data_type"] as? String == "Display Matrix" }?["rotation"] as? Int) ?? 0,
                bitRate: (stream["bit_rate"] as? String).flatMap { Int($0) }
                    ?? ((stream["tags"] as? [String: Any])?["BPS"] as? String).flatMap { Int($0) },
                codecTag: (stream["codec_tag_string"] as? String).flatMap { $0.hasPrefix("[") ? nil : $0 },
                isDefault: ((stream["disposition"] as? [String: Any])?["default"] as? Int) == 1,
                language: (stream["tags"] as? [String: Any])?["language"] as? String,
                title: (stream["tags"] as? [String: Any])?["title"] as? String,
                isForced: ((stream["disposition"] as? [String: Any])?["forced"] as? Int) == 1
            )

            switch codecType {
            case "video": videoStreams.append(info)
            case "audio": audioStreams.append(info)
            case "subtitle": subtitleStreams.append(info)
            default: break
            }
        }

        return MediaAnalysis(
            container: formatName,
            duration: duration,
            startTime: startTime,
            fileSize: fileSize,
            videoStreams: videoStreams,
            audioStreams: audioStreams,
            subtitleStreams: subtitleStreams,
            bitRate: (format["bit_rate"] as? String).flatMap { Int($0) }
        )
    }
}

/// Runs a command-line tool and collects its stdout.
/// Output goes to a temporary file, not a pipe: a pipe deadlocks once the output exceeds its
/// buffer (the child blocks on write) unless drained concurrently, and EOF never arrives if another
/// child process spawned meanwhile inherited the pipe's write end.
enum ProcessRunner {
    static func output(of executablePath: String, arguments: [String]) async throws -> Data {
        #if os(macOS)
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("liquidcast-\(UUID().uuidString).out")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              let outputHandle = try? FileHandle(forWritingTo: outputURL) else {
            throw ProcessRunnerError.outputUnavailable
        }
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = FileHandle.nullDevice

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            process.terminate()  // The caller gave up: don't leave the tool running
        }
        try Task.checkCancellation()
        guard status == 0 else { throw ProcessRunnerError.exited(status: status) }
        return try Data(contentsOf: outputURL)
        #else
        throw ProcessRunnerError.unsupported  // No subprocesses on iOS
        #endif
    }
}

enum ProcessRunnerError: LocalizedError {
    case exited(status: Int32)
    case outputUnavailable
    case unsupported

    var errorDescription: String? {
        switch self {
        case .exited(let status): return "Process exited with status \(status)"
        case .outputUnavailable: return "Could not create a temporary file for process output"
        case .unsupported: return "Running command-line tools is not supported on this platform"
        }
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
