import Foundation
import os.log

private let logger = Logger(subsystem: "com.liquidcast", category: "Transcoder")

/// macOS implementation: analyze with ffprobe, then either play the file directly or serve an
/// on-demand HLS stream (`HLSSession`) through the local HTTP server.
///
/// | Source                                  | Result                                       |
/// |-----------------------------------------|----------------------------------------------|
/// | H.264 + AAC in MP4/MOV                  | File URL, played directly                    |
/// | 8-bit H.264 in MKV/AVI, or + DTS/AC3    | HLS: video stream-copied, audio → AAC        |
/// | HEVC Main/Main 10, receiver plays HEVC  | HLS (fMP4): video stream-copied, HDR kept    |
/// | HEVC otherwise, 10-bit, XviD, VP9, ...  | HLS: video → H.264 (VideoToolbox; HDR tone-mapped), audio → AAC |
extension TranscodeManager {

    func performPreparation(from url: URL, mode: CompatibilityMode, startPosition: Double,
                            allowHEVC: Bool) async throws -> URL {
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

            if analysis.conversionPath == .directPlayback {
                logger.info("▶️ Direct playback: \(analysis.summary)")
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
                for: url, analysis: analysis, duration: duration, mode: mode, allowHEVC: allowHEVC,
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
            isHEVCPassthrough = profile.segmentFormat == .fmp4
            updateStreamingInfo(analysis: analysis, profile: profile)
            isStreaming = true
            finishPreparation(status: "Streaming")

            let playlistURL = baseURL.appendingPathComponent(session.id).appendingPathComponent("playlist.m3u8")
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

    // MARK: - HTTP routing

    /// Routes, per session:
    /// - `playlist.m3u8`: entry point (multivariant for fMP4, else the media playlist)
    /// - `media.m3u8`: media playlist
    /// - `init.mp4`: fMP4 init segment
    /// - `<index>.ts` / `<index>.m4s`: segments, produced on demand
    nonisolated static func makeRequestHandler(registry: HLSSessionRegistry) -> LocalHTTPServer.Handler {
        return { request in
            let parts = request.path.split(separator: "/")
            guard parts.count == 2, let session = registry.session(id: String(parts[0])) else {
                return .error(404)
            }
            let name = String(parts[1])
            let playlistType = "application/vnd.apple.mpegurl"

            switch name {
            case "playlist.m3u8":
                return .ok(Data(session.entryPlaylist.utf8), contentType: playlistType)
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
                return .ok(body, contentType: format.contentType)
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

    /// Choose how to encode, the segment layout that goes with it, and (fMP4) the variant description
    private func makeStream(
        for url: URL,
        analysis: MediaAnalysis,
        duration: Double,
        mode: CompatibilityMode,
        allowHEVC: Bool,
        ffmpegPath: String,
        ffprobePath: String
    ) async throws -> (StreamProfile, SegmentPlan, HLSVariant?) {
        guard var profile = StreamProfile.make(for: analysis, mode: mode, ultraQuality: ultraQualityAudio,
                                               allowHEVC: allowHEVC) else {
            throw TranscodeError.conversionFailed("No video stream found")
        }

        // HEVC passthrough needs the exact codec string for the multivariant playlist
        var variant: HLSVariant?
        if profile.segmentFormat == .fmp4 {
            if let codec = await hevcCodecString(for: url, videoStreamIndex: profile.videoStreamIndex,
                                                 ffmpegPath: ffmpegPath) {
                let video = analysis.primaryVideo
                // What's actually streamed: the copied video plus one AAC track (the file's total
                // includes every audio track, e.g. TrueHD and other languages)
                let videoBitRate = video?.bitRate
                    ?? analysis.bitRate
                    ?? Int(Double(analysis.fileSize) * 8 / max(duration, 1))
                let average = videoBitRate + (profile.audioStreamIndex != nil ? profile.audioBitrateKbps * 1000 : 0)
                variant = HLSVariant(
                    codecs: [codec] + (profile.audioStreamIndex != nil ? ["mp4a.40.2"] : []),
                    averageBandwidth: average,
                    peakBandwidth: average * 2,  // Apple's VOD allowance: peak ≤ 200% of average
                    width: video?.displaySize?.width,
                    height: video?.displaySize?.height,
                    frameRate: video?.frameRate,
                    videoRange: analysis.videoRange
                )
            } else {
                logger.warning("Couldn't read the HEVC codec configuration - re-encoding to H.264 instead")
                guard let fallback = StreamProfile.make(for: analysis, mode: mode, ultraQuality: ultraQualityAudio,
                                                        allowHEVC: false) else {
                    throw TranscodeError.conversionFailed("No video stream found")
                }
                profile = fallback
            }
        }

        if profile.video == .copy {
            // Copied video can only be cut at its own keyframes
            statusMessage = "Indexing..."
            do {
                let keyframes = try await KeyframeIndex.keyframes(
                    for: url,
                    videoStreamIndex: profile.videoStreamIndex,
                    startTime: analysis.startTime,
                    ffprobePath: ffprobePath
                )
                if let plan = SegmentPlan.keyframeAligned(keyframes: keyframes, duration: duration,
                                                          targetLength: StreamProfile.segmentLength),
                   plan.longestSegment <= StreamProfile.maxCopySegmentLength {
                    logger.info("📦 Stream copy (\(profile.segmentFormat == .fmp4 ? "HEVC fMP4" : "MPEG-TS")): \(plan.count) segments from \(keyframes.count) keyframes")
                    return (profile, plan, variant)
                }
                // Keyframes too sparse: huge segments mean slow starts and seeks
                logger.warning("Keyframes unusable for segmenting (\(keyframes.count) found) - re-encoding instead")
            } catch {
                logger.warning("Keyframe scan failed (\(error.localizedDescription)) - re-encoding instead")
            }
        }

        guard let encodeProfile = StreamProfile.make(for: analysis, mode: mode, ultraQuality: ultraQualityAudio,
                                                     allowHEVC: false, forceEncode: true),
              let plan = SegmentPlan.uniform(duration: duration, segmentLength: StreamProfile.segmentLength) else {
            throw TranscodeError.conversionFailed("Invalid duration")
        }
        logger.info("🎬 Transcode: \(plan.count) segments")
        return (encodeProfile, plan, nil)
    }

    /// RFC 6381 codec string of the source's HEVC stream, read from the `hvcC` box FFmpeg writes when
    /// it copies the stream into MP4 (the same box the segments' init will carry). ~50ms.
    private func hevcCodecString(for url: URL, videoStreamIndex: Int, ffmpegPath: String) async -> String? {
        let output = try? await ProcessRunner.output(of: ffmpegPath, arguments: [
            "-hide_banner", "-nostdin", "-loglevel", "error",
            "-i", url.path,
            "-map", "0:\(videoStreamIndex)",
            "-c:v", "copy", "-tag:v", "hvc1",
            "-frames:v", "1",
            "-f", "mp4", "-movflags", "+frag_keyframe+empty_moov",
            "-"
        ])
        return output.flatMap(MP4Segment.hevcCodecString)
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

    /// Update streaming info properties for UI display
    private func updateStreamingInfo(analysis: MediaAnalysis, profile: StreamProfile?) {
        if let width = analysis.primaryVideo?.width {
            switch width {
            case 1921...: outputResolution = "4K"
            case 1281...: outputResolution = "1080p"
            case 721...: outputResolution = "720p"
            default: outputResolution = "SD"
            }
        } else {
            outputResolution = ""
        }

        if let profile {
            if profile.segmentFormat == .fmp4 {
                outputVideoCodec = analysis.videoRange == .sdr ? "HEVC" : "HEVC \(analysis.videoRange == .pq ? "HDR10" : "HLG")"
            } else {
                outputVideoCodec = "H.264"
            }
            outputAudioCodec = "AAC"
            outputAudioChannels = profile.audioChannels >= 6 ? "5.1" : "Stereo"
        } else {
            outputVideoCodec = analysis.primaryVideo?.codecName.uppercased() ?? ""
            outputAudioCodec = analysis.primaryAudio?.codecName.uppercased() ?? ""
            outputAudioChannels = (analysis.primaryAudio?.channels ?? 2) >= 6 ? "5.1" : "Stereo"
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
