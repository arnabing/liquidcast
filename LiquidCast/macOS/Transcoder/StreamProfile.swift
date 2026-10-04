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
///
/// Containers: MPEG-TS for H.264. Fragmented MP4 for HEVC passthrough (Apple's HLS spec requires
/// fMP4 for HEVC): the segment muxer writes each segment as a self-contained fragmented MP4, with
/// `frag_discont` + `use_editlist=1` so fragment decode times (`tfdt`) are absolute, not reset per
/// file, and `delay_moov` so copied Dolby audio can be described. See `MP4Segment` for how they're served.
struct StreamProfile {
    enum Video: Equatable {
        /// Stream-copy (boundaries must be source keyframes): H.264, or HEVC for capable receivers
        case copy
        /// Re-encode with VideoToolbox H.264.
        /// - level: H.264 level × 10 (e.g. 41), the smallest that fits (`H264Level.minimum`); set on the
        ///   encoder and declared in the playlist, so both agree
        /// - toneMap: the source is HDR, convert it to SDR (BT.709) instead of showing it washed out
        case encode(bitrateKbps: Int, profile: H264Profile, level: Int, toneMap: Bool)
    }

    enum H264Profile: String {
        case main, high

        var profileIdc: Int { self == .high ? 100 : 77 }
    }

    enum SegmentFormat {
        case mpegts
        case fmp4

        var fileExtension: String { self == .mpegts ? "ts" : "mp4" }
        /// Extension in segment URLs
        var urlExtension: String { self == .mpegts ? "ts" : "m4s" }
        var contentType: String { self == .mpegts ? "video/mp2t" : "video/iso.segment" }
    }

    /// Absolute stream indices (ffprobe `index`)
    let videoStreamIndex: Int
    let audioStreamIndex: Int?
    let video: Video
    let audioBitrateKbps: Int
    let audioChannels: Int
    /// Resample to this rate (nil = keep the source rate)
    var audioSampleRate: Int? = nil
    var segmentFormat: SegmentFormat = .mpegts
    /// Remove Dolby Vision metadata, leaving the HDR10-compatible base layer (DV profiles 7 and 8)
    var stripDolbyVision = false
    /// Audio passed through untouched instead of re-encoded: "ac3"/"eac3" (incl. Atmos, Apple TV only)
    /// or "aac" that already has the output layout. Copied audio also lines up exactly across restarts:
    /// same source frames, no encoder priming.
    var copiedAudioCodec: String? = nil
    /// Bitmap subtitle stream (PGS/VobSub/DVB) to burn into the video; requires re-encoding
    var burnInSubtitleIndex: Int? = nil
    /// Tone mapping only: scale to this size first (4K → 1080p keeps software tone mapping ~3.5× realtime)
    var toneMapSize: (width: Int, height: Int)? = nil

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
    /// Stream copy unless a segment would be longer than this. Longer segments only cost seek
    /// granularity and the size of the first download; this rejects pathological sources (minutes
    /// between keyframes), not ordinary x265 encodes (~10s keyframe interval)
    static let maxCopySegmentLength: Double = 30

    /// Preferred input seek position for a job starting at `startIndex` (the session moves it
    /// earlier if the demuxer would land at or after the boundary)
    func seekPosition(for startIndex: Int, plan: SegmentPlan) -> Double {
        guard startIndex > 0 else { return 0 }
        return max(0, plan.start(of: startIndex) - Self.preroll)
    }

    /// FFmpeg arguments for a job that produces segments `startIndex...` of `plan`.
    /// Writes `<filePrefix>%05d.<ts|mp4>` (absolute segment index) and appends each finished segment
    /// to `segmentListURL` (CSV) only after the file is fully written.
    /// - Parameters:
    ///   - seek: Input seek position (0 = none). For `startIndex > 0`, must make the demuxer land
    ///     before the boundary.
    ///   - landing: Media time of the first video packet the demuxer delivers after `seek`
    ///     (`KeyframeIndex.seekLanding`)
    /// - bitrateScale: Re-encode only: fraction of the target bitrate (adaptive bitrate steps down on
    ///   slow networks; any job may use any scale, segments from different jobs still line up)
    func arguments(
        input: URL,
        plan: SegmentPlan,
        startIndex: Int,
        seek: Double,
        landing: Double,
        bitrateScale: Double = 1,
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

        // Video filters (re-encode only): HDR → SDR tone mapping, then burned-in image subtitles
        var videoFilters: [String] = []
        if case .encode(_, _, _, true) = video {
            // HDR (PQ/HLG) → SDR BT.709: linearize, map highlights (Hable), re-encode the transfer.
            // Input primaries/matrix are stated (always BT.2020 for PQ/HLG): files often leave them
            // untagged, and zscale then fails with "no path between colorspaces".
            let scale = toneMapSize.map { "w=\($0.width):h=\($0.height):" } ?? ""
            videoFilters.append("zscale=\(scale)t=linear:npl=100:pin=bt2020:min=bt2020nc:p=bt2020,format=gbrpf32le,"
                                + "zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv")
        }
        if let burnInSubtitleIndex, case .encode = video {
            // Bitmap subtitles drawn into the picture, their canvas scaled to the video's size
            let base = videoFilters.isEmpty ? "null" : videoFilters.joined(separator: ",")
            args += [
                "-filter_complex",
                "[0:\(videoStreamIndex)]\(base),format=yuv420p[base];[0:\(burnInSubtitleIndex)][base]scale2ref[sub][ref];"
                    + "[ref][sub]overlay=eof_action=pass,format=nv12[video]",
                "-map", "[video]",
            ]
        } else {
            args += ["-map", "0:\(videoStreamIndex)"]
            if !videoFilters.isEmpty {
                args += ["-vf", (videoFilters + ["format=nv12"]).joined(separator: ",")]
            }
        }
        if let audioStreamIndex {
            args += ["-map", "0:\(audioStreamIndex)"]
        }
        // Subtitle streams aren't muxed: text ones are served as WebVTT renditions, bitmap ones burned in
        args += ["-sn", "-dn"]

        switch video {
        case .copy:
            args += ["-c:v", "copy"]
            if segmentFormat == .fmp4 {
                args += ["-tag:v", "hvc1"]  // Apple players require hvc1, not hev1
            }
            if stripDolbyVision {
                args += ["-bsf:v", "dovi_rpu=strip=1"]
            }
        case .encode(let topBitrateKbps, let profile, let level, let toneMap):
            let bitrateKbps = Int(Double(topBitrateKbps) * bitrateScale)
            if toneMap {
                args += ["-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709"]
            }
            args += [
                "-fps_mode", "passthrough",       // Keep source frame times (segment muxer would default to CFR)
                "-enc_time_base", "1:90000",      // ...at full precision
                "-c:v", "h264_videotoolbox",
                "-pix_fmt", "nv12",  // 8-bit 4:2:0 (also converts 10-bit sources)
                "-profile:v", profile.rawValue,
                "-level", String(format: "%.1f", Double(level) / 10),
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
            if copiedAudioCodec != nil {
                args += ["-c:a", "copy"]
            } else {
                args += ["-c:a", "aac", "-b:a", "\(audioBitrateKbps)k", "-ac", "\(audioChannels)"]
                if let audioSampleRate {
                    args += ["-ar", "\(audioSampleRate)"]
                }
            }
        }

        args += ["-output_ts_offset", Self.format(Self.timestampBase + seek)]
        args += [
            "-f", "segment",
            "-segment_format", segmentFormat == .mpegts ? "mpegts" : "mp4",
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
        if segmentFormat == .mpegts {
            // Write timestamps as given (media time + base). Otherwise the TS muxer adds its own delay
            // (~1.4s), and subtitles (X-TIMESTAMP-MAP) would need to guess it.
            args += ["-segment_format_options", "mpegts_copyts=1"]
        } else {
            // delay_moov, not empty_moov: the moov must wait for the first packets, or the muxer can't
            // describe copied AC-3/E-AC-3 ("Cannot write moov atom before AC3 packets")
            args += ["-segment_format_options",
                     "movflags=+frag_keyframe+delay_moov+default_base_moof+frag_discont:use_editlist=1"]
        }
        args += [outputDirectory.appendingPathComponent("\(filePrefix)%05d.\(segmentFormat.fileExtension)").path]
        return args
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    /// RFC 6381 codec of re-encoded video (copied video's comes from the stream itself)
    var encodedVideoCodecString: String? {
        guard case .encode(_, let profile, let level, _) = video else { return nil }
        return String(format: "avc1.%02X00%02X", profile.profileIdc, level)
    }

    /// RFC 6381 codec of the streamed audio, for the multivariant playlist
    var audioCodecString: String? {
        guard audioStreamIndex != nil else { return nil }
        switch copiedAudioCodec {
        case "ac3": return "ac-3"
        case "eac3": return "ec-3"
        default: return "mp4a.40.2"
        }
    }
}

extension StreamProfile {
    /// Pick the profile for an analyzed source.
    /// - Parameters:
    ///   - passthrough: What the receiver accepts untouched: HEVC/HDR video, AC-3/E-AC-3 audio
    ///   - forceEncode: Re-encode even if the video could be stream-copied
    ///   - burnInSubtitle: Bitmap subtitle stream to draw into the video (forces re-encoding)
    /// - Returns: nil if the source has no usable video stream.
    static func make(
        for analysis: MediaAnalysis,
        mode: CompatibilityMode,
        ultraQuality: Bool,
        passthrough: Passthrough,
        forceEncode requestedForceEncode: Bool = false,
        burnInSubtitle: Int? = nil
    ) -> StreamProfile? {
        guard let video = analysis.primaryVideo else { return nil }
        let forceEncode = requestedForceEncode || burnInSubtitle != nil

        let videoMode: Video
        var segmentFormat = SegmentFormat.mpegts
        var toneMapSize: (width: Int, height: Int)?
        if !forceEncode && passthrough.contains(.hevc) && analysis.isPassthroughHEVC {
            videoMode = .copy
            segmentFormat = .fmp4
        } else {
            switch forceEncode ? .videoTranscode : analysis.conversionPath {
            case .directPlayback, .fastRemux, .audioTranscode:
                videoMode = .copy
            case .videoTranscode:
                let toneMap = analysis.videoRange != .sdr
                // Software tone mapping at 4K barely keeps up; SDR receivers are mostly 1080p anyway
                // (Display size: FFmpeg rotates frames upright before the filters run)
                if toneMap, let size = video.displaySize, max(size.width, size.height) > 1920 {
                    let scale = 1920 / Double(max(size.width, size.height))
                    toneMapSize = (Int((Double(size.width) * scale / 2).rounded()) * 2,
                                   Int((Double(size.height) * scale / 2).rounded()) * 2)
                }
                let width = toneMapSize?.width ?? video.displaySize?.width ?? 1920
                let height = toneMapSize?.height ?? video.displaySize?.height ?? 1080
                let bitrate = bitrateKbps(width: max(width, height), ultraQuality: ultraQuality)
                let profile: H264Profile = mode == .smartTV ? .main : .high
                videoMode = .encode(
                    bitrateKbps: bitrate,
                    profile: profile,
                    // Unknown frame rate: assume 60, so the declared level is never too low
                    level: H264Level.minimum(width: width, height: height, frameRate: video.frameRate ?? 60,
                                             peakBitrateKbps: bitrate * 3 / 2, bufferKbits: bitrate * 2,
                                             profile: profile),
                    toneMap: toneMap
                )
            }
        }

        let audio = analysis.audioStream(preferDolby: passthrough.contains(.dolbyAudio))
        let copyDolby = passthrough.contains(.dolbyAudio) && audio?.isDolbyAudio == true

        // Standard layouts only: mono, stereo, 5.1 (never upmixed). Surround is kept for an Apple TV, which
        // downmixes to whatever its output is, and with Ultra; smart TVs otherwise get stereo.
        let keepSurround = ultraQuality || mode == .appleTV
        let channels: Int
        switch audio?.channels ?? 2 {
        case ...1: channels = 1
        case 6...: channels = keepSurround ? 6 : 2
        default: channels = 2
        }
        // Apple's HLS spec: AAC at 48kHz or below
        let sampleRate = audio?.sampleRate.flatMap { $0 > 48_000 ? 48_000 : nil }
        // AAC-LC that already has the output layout plays everywhere: re-encoding would only lose quality
        let copyAAC = audio.map {
            $0.codecName.lowercased() == "aac" && ($0.profile ?? "LC") == "LC"
                && ($0.sampleRate ?? 48_000) <= 48_000 && $0.channels == channels
        } ?? false

        return StreamProfile(
            videoStreamIndex: video.index,
            audioStreamIndex: audio?.index,
            video: videoMode,
            // AAC: ~192 kbps per stereo pair is transparent; 5.1 needs more than stereo's budget
            audioBitrateKbps: channels >= 6 ? (ultraQuality ? 512 : 384) : (ultraQuality ? 320 : 192),
            audioChannels: channels,
            audioSampleRate: sampleRate,
            segmentFormat: segmentFormat,
            stripDolbyVision: segmentFormat == .fmp4 && video.dolbyVisionProfile != nil,
            copiedAudioCodec: copyDolby || copyAAC ? audio?.codecName.lowercased() : nil,
            burnInSubtitleIndex: burnInSubtitle,
            toneMapSize: toneMapSize
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

/// H.264 levels (ITU-T H.264 Table A-1)
enum H264Level {
    private struct Limits {
        let level: Int              // × 10
        let maxFrameSize: Int       // macroblocks
        let maxMacroblockRate: Int  // macroblocks/s
        let maxBitrate: Int         // kbit/s for Baseline/Main; High allows × 1.25
        let maxBuffer: Int          // CPB, kbit for Baseline/Main; High allows × 1.25
    }

    private static let table: [Limits] = [
        Limits(level: 30, maxFrameSize: 1_620, maxMacroblockRate: 40_500, maxBitrate: 10_000, maxBuffer: 10_000),
        Limits(level: 31, maxFrameSize: 3_600, maxMacroblockRate: 108_000, maxBitrate: 14_000, maxBuffer: 14_000),
        Limits(level: 32, maxFrameSize: 5_120, maxMacroblockRate: 216_000, maxBitrate: 20_000, maxBuffer: 20_000),
        Limits(level: 40, maxFrameSize: 8_192, maxMacroblockRate: 245_760, maxBitrate: 20_000, maxBuffer: 25_000),
        Limits(level: 41, maxFrameSize: 8_192, maxMacroblockRate: 245_760, maxBitrate: 50_000, maxBuffer: 62_500),
        Limits(level: 42, maxFrameSize: 8_704, maxMacroblockRate: 522_240, maxBitrate: 50_000, maxBuffer: 62_500),
        Limits(level: 50, maxFrameSize: 22_080, maxMacroblockRate: 589_824, maxBitrate: 135_000, maxBuffer: 135_000),
        Limits(level: 51, maxFrameSize: 36_864, maxMacroblockRate: 983_040, maxBitrate: 240_000, maxBuffer: 240_000),
        Limits(level: 52, maxFrameSize: 36_864, maxMacroblockRate: 2_073_600, maxBitrate: 240_000, maxBuffer: 240_000),
    ]

    /// Smallest level that fits the frame size, macroblock rate, peak bitrate and decoder buffer
    /// (5.2 if nothing does)
    static func minimum(width: Int, height: Int, frameRate: Double, peakBitrateKbps: Int, bufferKbits: Int = 0,
                        profile: StreamProfile.H264Profile) -> Int {
        let frameSize = ((width + 15) / 16) * ((height + 15) / 16)
        let macroblockRate = Int((Double(frameSize) * frameRate).rounded(.up))
        let factor = profile == .high ? 1.25 : 1.0
        return table.first {
            frameSize <= $0.maxFrameSize && macroblockRate <= $0.maxMacroblockRate
                && Double(peakBitrateKbps) <= Double($0.maxBitrate) * factor
                && Double(bufferKbits) <= Double($0.maxBuffer) * factor
        }?.level ?? 52
    }
}
