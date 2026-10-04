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
/// | HEVC, 10-bit, XviD, VP9, ...            | HLS: video → H.264 (VideoToolbox), audio → AAC |
extension TranscodeManager {

    func performPreparation(from url: URL, mode: CompatibilityMode, startPosition: Double) async throws -> URL {
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

            let (profile, plan) = try await makeStream(for: url, analysis: analysis, duration: duration,
                                                       mode: mode, ffprobePath: ffprobePath)
            try ensureCurrent(generation)

            statusMessage = "Starting stream..."
            try await httpServer.start()
            try ensureCurrent(generation)

            let session = HLSSession(
                source: url,
                sourceStartTime: analysis.startTime,
                plan: plan,
                profile: profile,
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

    /// `GET /<session>/playlist.m3u8` and `GET /<session>/<index>.ts`
    nonisolated static func makeRequestHandler(registry: HLSSessionRegistry) -> LocalHTTPServer.Handler {
        return { request in
            let parts = request.path.split(separator: "/")
            guard parts.count == 2, let session = registry.session(id: String(parts[0])) else {
                return .error(404)
            }
            let name = parts[1]

            if name == "playlist.m3u8" {
                return .ok(Data(session.playlist.utf8), contentType: "application/vnd.apple.mpegurl")
            }

            guard name.hasSuffix(".ts"), let index = Int(name.dropLast(3)) else {
                return .error(404)
            }
            // A HEAD must not start transcoding (it would restart FFmpeg somewhere the player isn't)
            guard request.method == "GET" else {
                return .error(405)
            }
            do {
                let file = try await session.segment(index)
                let data = try Data(contentsOf: file, options: .alwaysMapped)
                return .ok(data, contentType: "video/mp2t")
            } catch HLSSession.SessionError.notFound {
                return .error(404)
            } catch HLSSession.SessionError.transcodeFailed(let message) {
                logger.error("Segment \(index) failed: \(message)")
                return .error(500)
            } catch {
                logger.warning("Segment \(index) unavailable: \(error.localizedDescription)")
                return .error(503)
            }
        }
    }

    // MARK: - Helpers

    /// Choose how to encode, and the segment layout that goes with it
    private func makeStream(
        for url: URL,
        analysis: MediaAnalysis,
        duration: Double,
        mode: CompatibilityMode,
        ffprobePath: String
    ) async throws -> (StreamProfile, SegmentPlan) {
        guard let profile = StreamProfile.make(for: analysis, mode: mode, ultraQuality: ultraQualityAudio) else {
            throw TranscodeError.conversionFailed("No video stream found")
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
                    logger.info("📦 Stream copy: \(plan.count) segments from \(keyframes.count) keyframes")
                    return (profile, plan)
                }
                // Keyframes too sparse: huge segments mean slow starts and seeks
                logger.warning("Keyframes unusable for segmenting (\(keyframes.count) found) - re-encoding instead")
            } catch {
                logger.warning("Keyframe scan failed (\(error.localizedDescription)) - re-encoding instead")
            }
        }

        guard let encodeProfile = StreamProfile.make(for: analysis, mode: mode, ultraQuality: ultraQualityAudio,
                                                     forceEncode: true),
              let plan = SegmentPlan.uniform(duration: duration, segmentLength: StreamProfile.segmentLength) else {
            throw TranscodeError.conversionFailed("Invalid duration")
        }
        logger.info("🎬 Transcode: \(plan.count) segments")
        return (encodeProfile, plan)
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
            outputVideoCodec = "H.264"
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
