import Foundation
import os.log

private let logger = Logger(subsystem: "com.liquidcast", category: "Transcoder")

/// macOS implementation: analyze with ffprobe, then either play the file directly or serve an
/// on-demand HLS stream (`HLSSession`) through the local HTTP server.
///
/// | Source                                  | Result                                       |
/// |-----------------------------------------|----------------------------------------------|
/// | H.264 + AAC in MP4/MOV                  | File URL, played directly                    |
/// | Apple-native MP4/MOV (H.264/HEVC hvc1, AAC/AC-3/E-AC-3), receiver allows passthrough | File URL |
/// | 8-bit H.264 in MKV/AVI, or + DTS/AC3    | HLS: video stream-copied; audio → AAC (AC-3/E-AC-3 copied for Apple TV) |
/// | HEVC Main/Main 10, receiver plays HEVC  | HLS (fMP4): video stream-copied, HDR kept    |
/// | HEVC otherwise, 10-bit, XviD, VP9, ...  | HLS: video → H.264 (VideoToolbox; HDR tone-mapped), audio → AAC |
extension TranscodeManager {

    func performPreparation(from url: URL, mode: CompatibilityMode, startPosition: Double,
                            passthrough: Passthrough, burnIn: SubtitleBurnIn) async throws -> URL {
        stopStreaming()
        let generation = preparationGeneration

        guard let ffmpegPath = Self.findFFmpeg(),
              let ffprobePath = MediaAnalyzer.findFFprobe(ffmpegPath: ffmpegPath) else {
            throw TranscodeError.ffmpegNotFound
        }

        isConverting = true
        progress = 0
        currentFileName = url.lastPathComponent
        statusMessage = "Analyzing..."

        do {
            let analysis = try await MediaAnalyzer.analyze(url: url, ffprobePath: ffprobePath)
            try ensureCurrent(generation)
            sourceDuration = analysis.duration ?? 0
            subtitleTracks = analysis.subtitleTracks

            // Explicit burn-in forces a re-encode; a forced track is only drawn if re-encoding anyway
            var burnInStream: Int?
            var forcedSubtitle: Int?
            switch burnIn {
            case .off: break
            case .stream(let index): burnInStream = analysis.subtitleTracks.first { $0.streamIndex == index && $0.kind == .image }?.streamIndex
            case .automatic: forcedSubtitle = analysis.subtitleTracks.first { $0.kind == .image && $0.isForced }?.streamIndex
            }

            // A file the receiver plays as-is needs no FFmpeg at all
            var nativeNeeds: Passthrough = .nativeFile
            if analysis.nativeFileNeedsHEVC { nativeNeeds.insert(.hevc) }
            if analysis.nativeFileNeedsDolbyAudio { nativeNeeds.insert(.dolbyAudio) }
            let nativeForReceiver = analysis.conversionPath != .directPlayback
                && analysis.isAppleNativeFile && passthrough.isSuperset(of: nativeNeeds)
            // (Burning in subtitles needs re-encoding, so never plays the file directly)
            if burnInStream == nil && (analysis.conversionPath == .directPlayback || nativeForReceiver) {
                logger.info("▶️ Direct playback: \(analysis.summary)")
                passthroughUsed = nativeForReceiver ? nativeNeeds : []
                updateStreamingInfo(analysis: analysis, profile: nil)
                finishPreparation(status: "Ready")
                return url
            }

            // Segments cover the video stream only (audio often runs a little longer)
            guard let duration = analysis.videoEnd, duration > 0 else {
                throw TranscodeError.conversionFailed("Could not determine the duration of this file")
            }
            sourceDuration = duration  // Match the playlist the player will see

            let (profile, plan, variant) = try await makeStream(
                for: url, analysis: analysis, duration: duration, mode: mode, passthrough: passthrough,
                burnInSubtitle: burnInStream, forcedSubtitle: forcedSubtitle,
                ffmpegPath: ffmpegPath, ffprobePath: ffprobePath
            )
            try ensureCurrent(generation)

            statusMessage = "Starting stream..."
            try await httpServer.start()
            try ensureCurrent(generation)

            let session = HLSSession(
                source: url,
                sourceStartTime: analysis.startTime,
                plan: plan,
                profile: profile,
                variant: variant,
                subtitles: analysis.subtitleTracks,
                ffmpegPath: ffmpegPath,
                rootDirectory: CacheManager.sessionsDirectory,
                startTime: min(max(startPosition, 0), duration)
            )
            do {
                try await session.start()
                try ensureCurrent(generation)
            } catch {
                await session.stop()  // Kills FFmpeg if it was launched, deletes its directory
                throw error
            }
            guard let baseURL = httpServer.baseURL else {
                await session.stop()
                throw TranscodeError.conversionFailed("No network address to stream from")
            }

            activeSession = session
            sessionRegistry.register(session)
            burnedInSubtitle = profile.burnInSubtitleIndex
            passthroughUsed = []
            if profile.segmentFormat == .fmp4 { passthroughUsed.insert(.hevc) }
            if profile.copiedAudioCodec != nil { passthroughUsed.insert(.dolbyAudio) }
            updateStreamingInfo(analysis: analysis, profile: profile)
            isStreaming = true
            finishPreparation(status: "Streaming")

            let playlistURL = Self.playlistURL(base: baseURL, session: session, startTime: startPosition)
            logger.info("📺 Streaming \(url.lastPathComponent) at \(playlistURL.absoluteString)")
            return playlistURL

        } catch {
            if generation == preparationGeneration {
                isConverting = false
                statusMessage = "Failed"
            }
            throw error
        }
    }

    /// The active stream's playlist URL at the Mac's *current* address (it changes when the network
    /// does; the session and its port don't)
    func currentPlaylistURL(startTime: Double = 0) -> URL? {
        // No LAN address (network down): nothing a receiver could reach, keep the current URL
        guard let session = activeSession, LocalNetwork.primaryIPv4Address() != nil,
              let baseURL = httpServer.baseURL else { return nil }
        return Self.playlistURL(base: baseURL, session: session, startTime: startTime)
    }

    /// `<base>/<session>/playlist.m3u8[?start=<seconds>]`: the start goes into EXT-X-START
    private static func playlistURL(base: URL, session: HLSSession, startTime: Double) -> URL {
        let url = base.appendingPathComponent(session.id).appendingPathComponent("playlist.m3u8")
        guard startTime > 0, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = [URLQueryItem(name: "start", value: String(format: "%.3f", startTime))]
        return components.url ?? url
    }

    /// Segments fully delivered to the receiver beyond the one containing `position` (nil: not streaming).
    /// If it has them yet doesn't play, the problem isn't supply.
    func segmentsDeliveredAhead(of position: Double) async -> Int? {
        guard let session = activeSession else { return nil }
        return await session.deliveredAhead(of: session.plan.index(containing: position))
    }

    // MARK: - HTTP routing

    /// Routes, per session:
    /// - `playlist.m3u8`: multivariant playlist (entry point)
    /// - `subs/<stream>/index.m3u8`, `subs/<stream>/<index>.vtt`: text subtitle renditions
    /// - `media.m3u8`: media playlist
    /// - `init.mp4`: fMP4 init segment
    /// - `<index>.ts` / `<index>.m4s`: segments, produced on demand
    nonisolated static func makeRequestHandler(registry: HLSSessionRegistry) -> LocalHTTPServer.Handler {
        return { request in
            let parts = request.path.split(separator: "/").map(String.init)
            guard parts.count >= 2, let session = registry.session(id: parts[0]) else {
                return .error(404)
            }
            let playlistType = "application/vnd.apple.mpegurl"

            // Subtitles: subs/<stream>/index.m3u8 and subs/<stream>/<index>.vtt
            if parts[1] == "subs" {
                guard parts.count == 4, let stream = Int(parts[2]) else { return .error(404) }
                if parts[3] == "index.m3u8" {
                    guard session.subtitleTracks.contains(where: { $0.streamIndex == stream }) else { return .error(404) }
                    await session.prefetchSubtitles(streamIndex: stream)
                    return .ok(Data(session.subtitlePlaylist.utf8), contentType: playlistType)
                }
                guard parts[3].hasSuffix(".vtt"), let index = Int(parts[3].dropLast(4)) else {
                    return .error(404)
                }
                do {
                    let vtt = try await session.subtitleSegment(streamIndex: stream, index: index)
                    return .ok(Data(vtt.utf8), contentType: "text/vtt")
                } catch {
                    return response(for: error, what: "subtitle segment \(index)")
                }
            }

            guard parts.count == 2 else { return .error(404) }
            let name = parts[1]

            switch name {
            case "playlist.m3u8":
                let start = request.query["start"].flatMap(Double.init) ?? 0
                return .ok(Data(session.masterPlaylist(startTime: start).utf8), contentType: playlistType)
            case HLSSession.mediaPlaylistName:
                return .ok(Data(session.mediaPlaylist.utf8), contentType: playlistType)
            default:
                break
            }

            // Everything else may start transcoding; a HEAD must not (it would restart FFmpeg
            // somewhere the player isn't)
            guard request.method == "GET" else {
                return .error(405)
            }

            if name == HLSSession.initSegmentName {
                do {
                    return .ok(try await session.initSegment(), contentType: "video/mp4")
                } catch {
                    return response(for: error, what: "init segment")
                }
            }

            let format = session.segmentFormat
            let suffix = "." + format.urlExtension
            guard name.hasSuffix(suffix), let index = Int(name.dropLast(suffix.count)) else {
                return .error(404)
            }
            do {
                let file = try await session.segment(index)
                let data = try Data(contentsOf: file, options: .alwaysMapped)
                let body = format == .fmp4 ? MP4Segment.mediaSection(of: data) : data
                // Waiting past 3× the segment's duration is already "far too slow" for adaptive bitrate
                let deadline = max(session.plan.duration(of: index), 1) * 3
                return .ok(body, contentType: format.contentType, deliveryDeadline: deadline) { seconds in
                    Task { await session.recordDelivery(index: index, seconds: seconds) }
                }
            } catch {
                return response(for: error, what: "segment \(index)")
            }
        }
    }

    nonisolated private static func response(for error: Error, what: String) -> HTTPResponse {
        switch error {
        case HLSSession.SessionError.notFound:
            return .error(404)
        case HLSSession.SessionError.transcodeFailed(let message):
            logger.error("\(what) failed: \(message)")
            return .error(500)
        default:
            logger.warning("\(what) unavailable: \(error.localizedDescription)")
            return .error(503)
        }
    }

    // MARK: - Helpers

    /// Choose how to encode, the segment layout that goes with it, and the variant description
    private func makeStream(
        for url: URL,
        analysis: MediaAnalysis,
        duration: Double,
        mode: CompatibilityMode,
        passthrough: Passthrough,
        burnInSubtitle: Int?,
        forcedSubtitle: Int?,
        ffmpegPath: String,
        ffprobePath: String
    ) async throws -> (StreamProfile, SegmentPlan, HLSVariant) {
        guard let profile = StreamProfile.make(for: analysis, mode: mode, ultraQuality: ultraQualityAudio,
                                               passthrough: passthrough, burnInSubtitle: burnInSubtitle) else {
            throw TranscodeError.conversionFailed("No video stream found")
        }

        if profile.video == .copy {
            // Copied video can only be cut at its own keyframes, and is declared with its own codec string
            statusMessage = "Indexing..."
            do {
                let keyframes = try await KeyframeIndex.keyframes(
                    for: url,
                    videoStreamIndex: profile.videoStreamIndex,
                    startTime: analysis.startTime,
                    ffprobePath: ffprobePath
                )
                let codec = await copiedVideoCodecString(for: url, profile: profile, ffmpegPath: ffmpegPath)
                if let codec,
                   let plan = SegmentPlan.keyframeAligned(keyframes: keyframes, duration: duration,
                                                          targetLength: StreamProfile.segmentLength),
                   plan.longestSegment <= StreamProfile.maxCopySegmentLength {
                    logger.info("📦 Stream copy (\(profile.segmentFormat == .fmp4 ? "fMP4" : "MPEG-TS"), \(codec)): \(plan.count) segments from \(keyframes.count) keyframes")
                    return (profile, plan, variant(for: profile, videoCodec: codec, analysis: analysis, duration: duration))
                }
                // Keyframes too sparse (huge segments mean slow starts and seeks) or unreadable codec configuration
                logger.warning("Can't stream-copy (\(keyframes.count) keyframes, codec \(codec ?? "unknown")) - re-encoding instead")
            } catch {
                logger.warning("Keyframe scan failed (\(error.localizedDescription)) - re-encoding instead")
            }
        }

        // Re-encoding anyway: a forced bitmap track comes along for free
        guard let encodeProfile = StreamProfile.make(for: analysis, mode: mode, ultraQuality: ultraQualityAudio,
                                                     passthrough: passthrough, forceEncode: true,
                                                     burnInSubtitle: burnInSubtitle ?? forcedSubtitle),
              let codec = encodeProfile.encodedVideoCodecString,
              let plan = SegmentPlan.uniform(duration: duration, segmentLength: StreamProfile.segmentLength) else {
            throw TranscodeError.conversionFailed("Invalid duration")
        }
        logger.info("🎬 Transcode (\(codec)): \(plan.count) segments")
        return (encodeProfile, plan, variant(for: encodeProfile, videoCodec: codec, analysis: analysis, duration: duration))
    }

    /// The stream as the multivariant playlist describes it
    private func variant(for profile: StreamProfile, videoCodec: String, analysis: MediaAnalysis,
                         duration: Double) -> HLSVariant {
        let video = analysis.primaryVideo
        let streamedAudio = analysis.audioStreams.first { $0.index == profile.audioStreamIndex }
        let audioBitRate: Int
        if profile.audioStreamIndex == nil {
            audioBitRate = 0
        } else if profile.copiedAudioCodec != nil {
            audioBitRate = streamedAudio?.bitRate ?? 768_000  // Atmos E-AC-3 is usually 768 kbps
        } else {
            audioBitRate = profile.audioBitrateKbps * 1000
        }

        let average: Int, peak: Int
        switch profile.video {
        case .copy:
            // The copied video plus one audio track (the file's total includes every audio track)
            let videoBitRate = video?.bitRate ?? analysis.bitRate ?? Int(Double(analysis.fileSize) * 8 / max(duration, 1))
            average = videoBitRate + audioBitRate
            peak = average * 2  // Apple's VOD allowance: peak ≤ 200% of average
        case .encode(let bitrateKbps, _, _, _):
            average = bitrateKbps * 1000 + audioBitRate
            peak = bitrateKbps * 1500 + audioBitRate  // -maxrate
        }

        let size = profile.toneMapSize ?? video?.displaySize
        let range: VideoRange = profile.video == .copy ? analysis.videoRange : .sdr
        return HLSVariant(
            codecs: [videoCodec] + [profile.audioCodecString].compactMap { $0 },
            averageBandwidth: average,
            peakBandwidth: peak,
            width: size?.width,
            height: size?.height,
            frameRate: video?.frameRate,
            videoRange: range
        )
    }

    /// RFC 6381 codec string of copied video, read from the `avcC`/`hvcC` box FFmpeg writes when it
    /// copies the stream into MP4 (the same configuration the segments carry). ~50ms.
    private func copiedVideoCodecString(for url: URL, profile: StreamProfile, ffmpegPath: String) async -> String? {
        let isHEVC = profile.segmentFormat == .fmp4
        let output = try? await ProcessRunner.output(of: ffmpegPath, arguments: [
            "-hide_banner", "-nostdin", "-loglevel", "error",
            "-i", url.path,
            "-map", "0:\(profile.videoStreamIndex)",
            "-c:v", "copy"] + (isHEVC ? ["-tag:v", "hvc1"] : []) + [
            "-frames:v", "1",
            "-f", "mp4", "-movflags", "+frag_keyframe+empty_moov",
            "-"
        ])
        guard let output else { return nil }
        return isHEVC ? MP4Segment.hevcCodecString(in: output) : MP4Segment.avcCodecString(in: output)
    }

    private func ensureCurrent(_ generation: Int) throws {
        if generation != preparationGeneration {
            throw TranscodeError.cancelled
        }
    }

    private func finishPreparation(status: String) {
        isConverting = false
        progress = 1
        statusMessage = status
    }

    /// Update streaming info properties for UI display (same labels for direct play and streams)
    private func updateStreamingInfo(analysis: MediaAnalysis, profile: StreamProfile?) {
        let video = analysis.primaryVideo
        let width = profile?.toneMapSize?.width ?? video?.displaySize?.width
        switch width {
        case .some(1921...): outputResolution = "4K"
        case .some(1281...): outputResolution = "1080p"
        case .some(721...): outputResolution = "720p"
        case .some: outputResolution = "SD"
        case .none: outputResolution = ""
        }

        // Video: copied (direct play, or stream copy) keeps the source codec and range
        let copiedVideo = profile.map { $0.video == .copy } ?? true
        if copiedVideo && analysis.isHEVCVideo {
            switch analysis.videoRange {
            case .sdr: outputVideoCodec = "HEVC"
            case .pq: outputVideoCodec = video?.dolbyVisionProfile != nil ? "HEVC Dolby Vision" : "HEVC HDR10"
            case .hlg: outputVideoCodec = "HEVC HLG"
            }
        } else if copiedVideo && !analysis.isH264Video {
            outputVideoCodec = video?.codecName.uppercased() ?? ""
        } else {
            outputVideoCodec = "H.264"
        }

        // Audio: copied keeps the source codec (direct play: the default track)
        let audio = profile.flatMap { p in analysis.audioStreams.first { $0.index == p.audioStreamIndex } } ?? analysis.primaryAudio
        let copiedAudio = profile.map { $0.copiedAudioCodec != nil } ?? true
        if copiedAudio, let audio {
            outputAudioCodec = Self.audioLabel(audio)
            outputAudioChannels = Self.channelLabel(audio.channels)
        } else if let profile, profile.audioStreamIndex != nil {
            outputAudioCodec = "AAC"
            outputAudioChannels = Self.channelLabel(profile.audioChannels)
        } else {
            outputAudioCodec = ""
            outputAudioChannels = ""
        }
    }

    private static func audioLabel(_ audio: StreamInfo) -> String {
        switch audio.codecName.lowercased() {
        case "eac3": return audio.profile?.contains("Atmos") == true ? "Atmos" : "E-AC-3"
        case "ac3": return "AC-3"
        case "aac": return "AAC"
        default: return audio.codecName.uppercased()
        }
    }

    private static func channelLabel(_ channels: Int?) -> String {
        switch channels ?? 2 {
        case 8...: return "7.1"
        case 6...: return "5.1"
        case 1: return "Mono"
        default: return "Stereo"
        }
    }

    /// Find FFmpeg binary
    private static func findFFmpeg() -> String? {
        let paths = [
            "/opt/homebrew/bin/ffmpeg",  // Apple Silicon
            "/usr/local/bin/ffmpeg",     // Intel Mac
            "/usr/bin/ffmpeg"
        ]
        return paths.first { FileManager.default.fileExists(atPath: $0) }
    }
}
