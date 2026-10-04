import Foundation

/// How a source is turned into HLS segments, and the FFmpeg arguments that do it.
///
/// Every FFmpeg run ("job") starts at some segment of a `SegmentPlan`. Jobs are interchangeable:
/// a job started at segment 40 writes the same boundaries and the same timestamps as a job that
/// started at 0 and reached segment 40, so segments from different jobs can be mixed in one stream.
/// That holds because (each verified against FFmpeg 8 - see docs/STREAMING.md):
/// - output timestamps are pinned to media time (`-output_ts_offset` = base + seek), and frame times
///   are kept exact: no CFR re-gridding (`-fps_mode passthrough`) and a 90kHz encoder time base
///   (the default 1/framerate snaps frames to a grid that starts at each job's seek point)
/// - every restart seeks `preroll` before its boundary and writes the pre-roll to a throwaway segment
///   numbered `startIndex - 1`, which the session discards. So the boundary is cut inside the stream
///   by the same rule as in a continuous run, and audio lands in the same segment either way
/// - cut points are explicit (`-segment_times`), measured - as the segment muxer does - from the
///   first *video* packet of the job (`reference_stream_first_pts` in libavformat/segment.c):
///   - re-encode: that's the first frame after the seek; keyframes are forced at each boundary
///     (`-force_key_frames`) and nowhere else (`-g`), so a 0.25s cut window can't pick a wrong one.
///     Keyframes are given as a list of times, which FFmpeg compares to each frame's output time.
///     (`expr:` mode measures `t` from the job's first frame, so it differs between jobs.)
///   - copy: the demuxer lands on an *indexed* keyframe, which may be well before the seek (MKV cues
///     don't list every keyframe) or after it (MPEG-TS seeks forward). The session probes exactly
///     where (`KeyframeIndex.seekLanding`) and backs the seek off until it lands before the boundary
struct StreamProfile {
    enum Video: Equatable {
        /// Stream-copy H.264 (boundaries must be source keyframes)
        case copy
        /// Re-encode with VideoToolbox H.264 (level chosen by the encoder from resolution and frame rate)
        case encode(bitrateKbps: Int, profile: String)
    }

    /// Absolute stream indices (ffprobe `index`)
    let videoStreamIndex: Int
    let audioStreamIndex: Int?
    let video: Video
    let audioBitrateKbps: Int
    let audioChannels: Int
    /// Resample to this rate (nil = keep the source rate)
    var audioSampleRate: Int? = nil

    /// Added to every output timestamp. Keeps B-frame DTS positive at media time 0, so FFmpeg
    /// never shifts the first job's timestamps differently from later jobs.
    static let timestampBase: Double = 10
    /// How far before its boundary a restarted job starts (> any B-frame reorder delay)
    static let preroll: Double = 0.5
    /// Keyframe times sit this far before boundaries. Off the 1ms (MKV), 1/90000 (TS) and common MP4
    /// timestamp grids, so a frame exactly on a boundary can't fall either side by float rounding
    static let boundaryEpsilon: Double = 0.0001234
    /// Re-encoded segment length (Apple's HLS recommendation)
    static let segmentLength: Double = 6
    /// Stream copy only if no segment would be longer (sparse source keyframes → slow starts/seeks)
    static let maxCopySegmentLength: Double = 10

    /// Preferred input seek position for a job starting at `startIndex` (the session moves it
    /// earlier if the demuxer would land at or after the boundary)
    func seekPosition(for startIndex: Int, plan: SegmentPlan) -> Double {
        guard startIndex > 0 else { return 0 }
        return max(0, plan.start(of: startIndex) - Self.preroll)
    }

    /// FFmpeg arguments for a job that produces segments `startIndex...` of `plan`.
    /// Writes `<filePrefix>%05d.ts` (absolute segment index) and appends each finished segment
    /// to `segmentListURL` (CSV) only after the file is fully written.
    /// - Parameters:
    ///   - seek: Input seek position (0 = none). For `startIndex > 0`, must make the demuxer land
    ///     before the boundary.
    ///   - landing: Media time of the first video packet the demuxer delivers after `seek`
    ///     (`KeyframeIndex.seekLanding`)
    func arguments(
        input: URL,
        plan: SegmentPlan,
        startIndex: Int,
        seek: Double,
        landing: Double,
        outputDirectory: URL,
        filePrefix: String,
        segmentListURL: URL
    ) -> [String] {
        // Media time of the job's first video packet, which the segment muxer measures cuts from.
        // Copy starts at the landing keyframe; re-encode at the first frame from the seek point on.
        let reference = video == .copy ? landing : max(seek, landing)
        // Copy cuts match exact keyframe times; encode cuts allow for the first frame being up to
        // one frame after the seek point
        let cutTolerance = video == .copy ? 0.01 : 0.25

        let firstFileIndex = startIndex > 0 ? startIndex - 1 : 0  // startIndex - 1 = pre-roll, discarded
        let firstCut = startIndex > 0 ? startIndex : startIndex + 1
        let cutTimes = (firstCut..<plan.count).map { plan.start(of: $0) - reference }

        var args = ["-hide_banner", "-nostdin", "-nostats", "-loglevel", "warning"]

        if case .encode = video {
            args += ["-hwaccel", "videotoolbox"]  // Falls back to software decode if unsupported
        }
        // Always seek, even to 0: without -ss FFmpeg's force_key_frames `t` ignores a non-zero container
        // start time, so the first job would place keyframes differently from restarted ones
        args += ["-ss", Self.format(seek)]
        args += ["-i", input.path]

        args += ["-map", "0:\(videoStreamIndex)"]
        if let audioStreamIndex {
            args += ["-map", "0:\(audioStreamIndex)"]
        }
        args += ["-sn", "-dn"]  // Text subtitles can't go into MPEG-TS and would fail the job

        switch video {
        case .copy:
            args += ["-c:v", "copy"]
        case .encode(let bitrateKbps, let profile):
            args += [
                "-fps_mode", "passthrough",       // Keep source frame times (segment muxer would default to CFR)
                "-enc_time_base", "1:90000",      // ...at full precision
                "-c:v", "h264_videotoolbox",
                "-pix_fmt", "nv12",  // 8-bit 4:2:0 (also converts 10-bit sources)
                "-profile:v", profile,
                "-b:v", "\(bitrateKbps)k",
                "-maxrate", "\(bitrateKbps * 3 / 2)k",  // Cap peaks so Wi-Fi delivery doesn't stall
                "-bufsize", "\(bitrateKbps * 2)k",
                "-g", "9999",  // No keyframes except the forced ones
            ]
            // A keyframe at every boundary from this job on (output time = media time - seek). Omitted
            // for a single-segment stream: FFmpeg rejects an empty list.
            let keyframeTimes = (max(startIndex, 1)..<max(plan.count, 1))
                .map { Self.format(plan.start(of: $0) - seek - Self.boundaryEpsilon) }
            if !keyframeTimes.isEmpty {
                args += ["-force_key_frames", keyframeTimes.joined(separator: ",")]
            }
        }

        if audioStreamIndex != nil {
            args += ["-c:a", "aac", "-b:a", "\(audioBitrateKbps)k", "-ac", "\(audioChannels)"]
            if let audioSampleRate {
                args += ["-ar", "\(audioSampleRate)"]
            }
        }

        args += ["-output_ts_offset", Self.format(Self.timestampBase + seek)]
        args += [
            "-f", "segment",
            "-segment_format", "mpegts",
            "-segment_start_number", "\(firstFileIndex)",
            "-segment_list", segmentListURL.path,
            "-segment_list_type", "csv",
        ]
        if !cutTimes.isEmpty {
            args += [
                "-segment_times", cutTimes.map(Self.format).joined(separator: ","),
                "-segment_time_delta", Self.format(cutTolerance),
            ]
        }
        args += [outputDirectory.appendingPathComponent("\(filePrefix)%05d.ts").path]
        return args
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }
}

extension StreamProfile {
    /// Pick the profile for an analyzed source.
    /// - Parameter forceEncode: Re-encode even if the video could be stream-copied
    /// - Returns: nil if the source has no usable video stream.
    static func make(
        for analysis: MediaAnalysis,
        mode: CompatibilityMode,
        ultraQuality: Bool,
        forceEncode: Bool = false
    ) -> StreamProfile? {
        guard let video = analysis.primaryVideo else { return nil }

        let videoMode: Video
        switch forceEncode ? .videoTranscode : analysis.conversionPath {
        case .directPlayback, .fastRemux, .audioTranscode:
            videoMode = .copy
        case .videoTranscode:
            videoMode = .encode(
                bitrateKbps: bitrateKbps(width: video.width, ultraQuality: ultraQuality),
                profile: mode == .smartTV ? "main" : "high"
            )
        }

        // Standard layouts only: mono, stereo, 5.1. Ultra keeps 5.1 (never upmixes); standard is stereo.
        let sourceChannels = analysis.primaryAudio?.channels ?? 2
        let channels: Int
        switch sourceChannels {
        case ...1: channels = 1
        case 6...: channels = ultraQuality ? 6 : 2
        default: channels = 2
        }
        // Apple's HLS spec: AAC at 48kHz or below
        let sampleRate = analysis.primaryAudio?.sampleRate.flatMap { $0 > 48_000 ? 48_000 : nil }

        return StreamProfile(
            videoStreamIndex: video.index,
            audioStreamIndex: analysis.primaryAudio?.index,
            video: videoMode,
            audioBitrateKbps: ultraQuality ? 320 : 192,
            audioChannels: channels,
            audioSampleRate: sampleRate
        )
    }

    /// Target video bitrate by resolution
    static func bitrateKbps(width: Int?, ultraQuality: Bool) -> Int {
        let width = width ?? 1920
        switch (width, ultraQuality) {
        case (1921..., true): return 20_000   // 4K
        case (1281..., true): return 15_000   // 1080p
        case (721..., true): return 8_000     // 720p
        case (_, true): return 4_000          // SD
        case (1921..., false): return 12_000
        case (1281..., false): return 8_000
        case (721..., false): return 4_000
        default: return 2_000
        }
    }
}
