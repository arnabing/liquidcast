import Foundation
import os.log

private let logger = Logger(subsystem: "com.liquidcast", category: "Transcoder")

/// macOS-specific transcoding implementation using FFmpeg
/// Supports 4 conversion paths:
/// - Path 0: Direct playback (H.264+AAC in MP4/MOV)
/// - Path 1: Fast remux (H.264+AAC in MKV/AVI → MP4)
/// - Path 2: Audio transcode (H.264+DTS/AC3 → H.264+AAC via HLS)
/// - Path 3: Full transcode (XviD/H.265/etc → H.264+AAC via HLS)
extension TranscodeManager {

    /// Main entry point for conversion
    func performConversion(from url: URL, mode: CompatibilityMode = .appleTV) async throws -> URL {
        logger.info("🎬 Converting: \(url.lastPathComponent) (mode: \(mode.rawValue))")

        // Verify FFmpeg installation
        guard let ffmpegPath = findFFmpeg() else {
            throw TranscodeError.ffmpegNotFound
        }

        guard let ffprobePath = MediaAnalyzer.findFFprobe(ffmpegPath: ffmpegPath) else {
            throw TranscodeError.ffmpegNotFound
        }

        // Check cache first
        if let cachedURL = CacheManager.cachedURL(for: url) {
            if FileManager.default.fileExists(atPath: cachedURL.path) {
                logger.info("✅ Using cached: \(cachedURL.lastPathComponent)")
                return cachedURL
            }
        }

        // Initialize state
        await MainActor.run {
            isConverting = true
            isCancelled = false
            progress = 0
            currentFileName = url.lastPathComponent
            statusMessage = "Analyzing..."
        }

        do {
            // Analyze media file
            let analysis = try await MediaAnalyzer.analyze(url: url, ffprobePath: ffprobePath)
            logger.info("📊 \(analysis.summary)")

            // Execute appropriate conversion path
            let result: URL

            switch analysis.conversionPath {
            case .directPlayback:
                logger.info("▶️ Path 0: Direct playback")
                await MainActor.run {
                    statusMessage = "Ready!"
                    progress = 1.0
                    isConverting = false
                }
                return url

            case .fastRemux:
                logger.info("📦 Path 1: Fast remux")
                result = try await performFastRemux(
                    input: url,
                    ffmpegPath: ffmpegPath,
                    analysis: analysis
                )

            case .audioTranscode:
                logger.info("🎵 Path 2: Audio transcode (video copy)")
                result = try await performHLSTranscode(
                    input: url,
                    ffmpegPath: ffmpegPath,
                    analysis: analysis,
                    videoCodec: "copy",
                    mode: mode
                )

            case .videoTranscode:
                logger.info("🎬 Path 3: Full transcode")
                result = try await performHLSTranscode(
                    input: url,
                    ffmpegPath: ffmpegPath,
                    analysis: analysis,
                    videoCodec: "h264_videotoolbox",
                    mode: mode
                )
            }

            await MainActor.run {
                isConverting = false
            }
            return result

        } catch {
            await MainActor.run {
                isConverting = false
                statusMessage = "Failed"
            }
            // Clean up HTTP server on error
            httpServer.forceStop()
            throw error
        }
    }

    // MARK: - Path 1: Fast Remux

    /// Fast remux: container change only (MKV/AVI → MP4)
    /// No re-encoding, very fast
    private func performFastRemux(
        input: URL,
        ffmpegPath: String,
        analysis: MediaAnalysis
    ) async throws -> URL {
        await MainActor.run {
            statusMessage = "Remuxing..."
        }

        let outputURL = CacheManager.tempURL(for: input)

        // Clean up existing output
        try? FileManager.default.removeItem(at: outputURL)

        let arguments = [
            "-i", input.path,
            "-c:v", "copy",           // Copy video stream
            "-c:a", "copy",           // Copy audio stream
            "-movflags", "+faststart", // Enable streaming
            "-y",                      // Overwrite
            outputURL.path
        ]

        let ffmpegProcess = FFmpegProcess()
        currentProcess = ffmpegProcess

        try await ffmpegProcess.start(ffmpegPath: ffmpegPath, arguments: arguments)

        // Remux should be quick - timeout based on file size (1 min per GB, min 30s)
        let fileSizeGB = Double(analysis.fileSize) / (1024 * 1024 * 1024)
        let timeout: TimeInterval = max(30, fileSizeGB * 60)

        _ = try await ffmpegProcess.waitForExit(timeout: timeout)

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw TranscodeError.outputNotCreated
        }

        // Move to cache location
        let cachedURL = CacheManager.outputURL(for: input)
        try? FileManager.default.removeItem(at: cachedURL)
        try FileManager.default.moveItem(at: outputURL, to: cachedURL)

        await MainActor.run {
            statusMessage = "Ready!"
            progress = 1.0
        }

        logger.info("✅ Remux complete: \(cachedURL.lastPathComponent)")
        return cachedURL
    }

    // MARK: - Path 2 & 3: HLS Streaming Transcode

    /// Perform HLS streaming transcode
    /// Allows playback to start immediately while conversion continues in background
    private func performHLSTranscode(
        input: URL,
        ffmpegPath: String,
        analysis: MediaAnalysis,
        videoCodec: String,
        mode: CompatibilityMode
    ) async throws -> URL {
        await MainActor.run {
            statusMessage = "Preparing stream..."
        }

        // Create HLS output directory
        let hlsDir = CacheManager.hlsDirectory(for: input)
        try? FileManager.default.removeItem(at: hlsDir)
        try FileManager.default.createDirectory(at: hlsDir, withIntermediateDirectories: true)

        let playlistPath = hlsDir.appendingPathComponent("playlist.m3u8").path
        let segmentPattern = hlsDir.appendingPathComponent("segment%04d.ts").path

        // Build FFmpeg arguments
        var arguments = ["-i", input.path]

        // Video settings
        if videoCodec == "copy" {
            arguments += ["-c:v", "copy"]
        } else {
            // Hardware encoding with profile based on mode
            arguments += ["-c:v", videoCodec]

            // Smart TVs need Main profile, Apple TV can handle High
            if mode == .smartTV {
                arguments += ["-profile:v", "main", "-level", "4.0"]
            } else {
                arguments += ["-profile:v", "high", "-level", "4.1"]
            }

            // Bitrate based on resolution
            let targetBitrate = calculateBitrate(for: analysis)
            arguments += ["-b:v", targetBitrate]
        }

        // Audio: transcode to AAC for compatibility
        if ultraQualityAudio {
            // Ultra quality: 320kbps with 5.1 surround preserved
            arguments += ["-c:a", "aac", "-b:a", "320k", "-ac", "6"]
        } else {
            // Standard quality: 192kbps stereo (better compatibility)
            arguments += ["-c:a", "aac", "-b:a", "192k"]
        }

        // HLS settings
        arguments += [
            "-f", "hls",
            "-hls_time", "6",                     // 6 second segments
            "-hls_list_size", "0",                // Keep all segments
            "-hls_flags", "independent_segments",
            "-hls_segment_type", "mpegts",
            "-hls_segment_filename", segmentPattern,
            "-y",
            playlistPath
        ]

        // Start FFmpeg process
        let ffmpegProcess = FFmpegProcess()
        currentProcess = ffmpegProcess

        try await ffmpegProcess.start(ffmpegPath: ffmpegPath, arguments: arguments)

        // Calculate timeout based on complexity
        let timeout = calculateTimeout(for: analysis, isFullTranscode: videoCodec != "copy")

        // Monitor for first segment (runs concurrently with FFmpeg)
        let segmentMonitor = HLSSegmentMonitor(hlsDirectory: hlsDir)

        do {
            let playlistURL = try await segmentMonitor.waitForFirstSegment(timeout: timeout)

            // Start HTTP server to serve HLS
            let httpBaseURL = try httpServer.startServing(directory: hlsDir)
            let httpPlaylistURL = httpBaseURL.appendingPathComponent("playlist.m3u8")

            logger.info("📺 HLS streaming ready: \(httpPlaylistURL)")

            await MainActor.run {
                statusMessage = "Streaming..."
            }

            // Monitor progress in background
            Task { [weak self] in
                await self?.monitorTranscodeProgress(ffmpegProcess: ffmpegProcess, analysis: analysis)
            }

            return httpPlaylistURL

        } catch {
            // Clean up on failure
            await ffmpegProcess.terminate()
            httpServer.forceStop()
            try? FileManager.default.removeItem(at: hlsDir)
            throw error
        }
    }

    // MARK: - Helpers

    /// Find FFmpeg binary
    private func findFFmpeg() -> String? {
        let paths = [
            "/opt/homebrew/bin/ffmpeg",  // Apple Silicon
            "/usr/local/bin/ffmpeg",      // Intel Mac
            "/usr/bin/ffmpeg"             // System
        ]

        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }

    /// Calculate target video bitrate based on resolution and quality setting
    private func calculateBitrate(for analysis: MediaAnalysis) -> String {
        guard let width = analysis.primaryVideo?.width else {
            return ultraQualityAudio ? "10M" : "6M" // Default
        }

        if ultraQualityAudio {
            // Ultra quality: higher bitrates for better video
            if width > 1920 {
                return "20M"  // 4K
            } else if width > 1280 {
                return "15M"  // 1080p
            } else if width > 720 {
                return "8M"   // 720p
            } else {
                return "4M"   // SD
            }
        } else {
            // Standard quality: balanced bitrates
            if width > 1920 {
                return "12M"  // 4K
            } else if width > 1280 {
                return "8M"   // 1080p
            } else if width > 720 {
                return "4M"   // 720p
            } else {
                return "2M"   // SD
            }
        }
    }

    /// Calculate timeout based on file size and conversion type
    private func calculateTimeout(for analysis: MediaAnalysis, isFullTranscode: Bool) -> TimeInterval {
        // Base timeout
        var timeout: TimeInterval = 45

        // Add time based on file size (+20s per GB)
        let fileSizeGB = Double(analysis.fileSize) / (1024 * 1024 * 1024)
        timeout += fileSizeGB * 20

        // Full transcode needs more time for encoder initialization
        if isFullTranscode {
            timeout += 30

            // 4K content needs even more time
            if let width = analysis.primaryVideo?.width, width > 1920 {
                timeout += 30
            }
        }

        // Cap at 5 minutes
        return min(timeout, 300)
    }

    /// Monitor transcode progress and update UI
    private func monitorTranscodeProgress(ffmpegProcess: FFmpegProcess, analysis: MediaAnalysis) async {
        guard let duration = analysis.duration, duration > 0 else { return }

        while await ffmpegProcess.isRunning {
            // Check for cancellation
            if isCancelled {
                await ffmpegProcess.terminate()
                break
            }

            try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
        }

        // Update final state
        if await ffmpegProcess.hasFinished {
            if await ffmpegProcess.failureReason == nil {
                await MainActor.run {
                    self.progress = 1.0
                    self.statusMessage = "Done!"
                }
            }
        }
    }
}
