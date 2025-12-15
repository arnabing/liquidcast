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
    func performConversion(from url: URL, mode: CompatibilityMode = .appleTV, startPosition: Double = 0) async throws -> URL {
        if startPosition > 0 {
            logger.info("🎬 Converting: \(url.lastPathComponent) (mode: \(mode.rawValue), startAt: \(Int(startPosition))s)")
        } else {
            logger.info("🎬 Converting: \(url.lastPathComponent) (mode: \(mode.rawValue))")
        }

        // Store current state for potential seek-restart
        currentSourceURL = url
        currentMode = mode
        currentSeekOffset = startPosition

        // Verify FFmpeg installation
        guard let ffmpegPath = findFFmpeg() else {
            throw TranscodeError.ffmpegNotFound
        }

        guard let ffprobePath = MediaAnalyzer.findFFprobe(ffmpegPath: ffmpegPath) else {
            throw TranscodeError.ffmpegNotFound
        }

        // Check cache first (only if starting from beginning)
        if startPosition == 0, let cachedURL = CacheManager.cachedURL(for: url) {
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

            // Store analysis for potential seek-restart
            currentAnalysis = analysis

            // Store source duration for seek bar display (full movie length)
            if let duration = analysis.duration, duration > 0 {
                await MainActor.run {
                    sourceDuration = duration
                }
                logger.info("⏱️ Source duration: \(Int(duration))s (\(Int(duration/60))m)")
            }

            // Populate streaming info for UI display
            await updateStreamingInfo(from: analysis, mode: mode)

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
                    mode: mode,
                    startPosition: startPosition
                )

            case .videoTranscode:
                logger.info("🎬 Path 3: Full transcode")
                result = try await performHLSTranscode(
                    input: url,
                    ffmpegPath: ffmpegPath,
                    analysis: analysis,
                    videoCodec: "h264_videotoolbox",
                    mode: mode,
                    startPosition: startPosition
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
    /// - Parameter startPosition: Optional seek position to start transcoding from (in seconds)
    private func performHLSTranscode(
        input: URL,
        ffmpegPath: String,
        analysis: MediaAnalysis,
        videoCodec: String,
        mode: CompatibilityMode,
        startPosition: Double = 0
    ) async throws -> URL {
        await MainActor.run {
            statusMessage = startPosition > 0 ? "Seeking..." : "Preparing stream..."
        }

        // Create HLS output directory
        let hlsDir = CacheManager.hlsDirectory(for: input)
        try? FileManager.default.removeItem(at: hlsDir)
        try FileManager.default.createDirectory(at: hlsDir, withIntermediateDirectories: true)

        let playlistPath = hlsDir.appendingPathComponent("playlist.m3u8").path
        let segmentPattern = hlsDir.appendingPathComponent("segment%04d.ts").path

        // Build FFmpeg arguments
        var arguments: [String] = []

        // Add seek BEFORE input for fast input seeking (doesn't decode frames before seek point)
        if startPosition > 0 {
            arguments += ["-ss", String(format: "%.3f", startPosition)]
            logger.info("⏩ Fast-seeking to \(Int(startPosition))s before input")
        }

        arguments += ["-i", input.path]

        // Sync correction flags - fix audio/video timestamp mismatches
        arguments += [
            "-async", "1",              // Resample audio to match video timestamps
            "-vsync", "cfr",            // Constant frame rate for video consistency
        ]

        // Video settings
        if videoCodec == "copy" {
            arguments += ["-c:v", "copy"]
        } else {
            // Choose encoder based on quality mode and device HEVC support
            // Ultra Quality + HEVC-capable device: Use HEVC for best quality
            // Otherwise: Use H.264 for compatibility
            let useHEVC = ultraQualityAudio && deviceSupportsHEVC
            let encoder = useHEVC ? "hevc_videotoolbox" : videoCodec

            arguments += ["-c:v", encoder]

            // Convert 10-bit to 8-bit for VideoToolbox compatibility
            arguments += ["-pix_fmt", "yuv420p"]

            if useHEVC {
                // HEVC: Add hvc1 tag for Apple device compatibility
                arguments += ["-tag:v", "hvc1"]
                logger.info("🎬 Using HEVC encoder for Ultra Quality (device: \(self.currentDeviceName ?? "unknown"))")
            } else {
                // H.264: Set profile and level based on resolution
                // Level 4.0: up to 1920x1080, Level 4.1: up to 2048x1080, Level 5.1: up to 4096x2160
                let level: String
                if let width = analysis.primaryVideo?.width, width > 1920 {
                    level = "5.1"  // 4K content needs level 5.1
                } else if mode == .smartTV {
                    level = "4.0"  // Smart TVs: conservative level for 1080p
                } else {
                    level = "4.1"  // Apple TV: slightly higher for 1080p
                }

                // Smart TVs need Main profile, Apple TV can handle High
                if mode == .smartTV {
                    arguments += ["-profile:v", "main", "-level", level]
                } else {
                    arguments += ["-profile:v", "high", "-level", level]
                }
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
            arguments += ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]
        }

        // HLS settings
        arguments += [
            "-f", "hls",
            "-hls_time", "6",                     // 6 second segments
            "-hls_list_size", "0",                // Keep all segments
            "-hls_flags", "independent_segments",
            "-hls_segment_type", "mpegts",
            "-start_at_zero",                     // Reset timestamps to start at 0
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
            _ = try await segmentMonitor.waitForFirstSegment(timeout: timeout)

            // Start HTTP server to serve HLS
            let httpBaseURL = try httpServer.startServing(directory: hlsDir)
            let httpPlaylistURL = httpBaseURL.appendingPathComponent("playlist.m3u8")

            logger.info("📺 HLS streaming ready: \(httpPlaylistURL)")

            await MainActor.run {
                statusMessage = "Streaming..."
                isStreaming = true
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

    // MARK: - Streaming Info

    /// Update streaming info properties for UI display
    private func updateStreamingInfo(from analysis: MediaAnalysis, mode: CompatibilityMode) async {
        // Resolution
        let resolution: String
        if let width = analysis.primaryVideo?.width {
            if width > 1920 {
                resolution = "4K"
            } else if width > 1280 {
                resolution = "1080p"
            } else if width > 720 {
                resolution = "720p"
            } else {
                resolution = "SD"
            }
        } else {
            resolution = ""
        }

        // Video codec - depends on conversion path and settings
        let videoCodec: String
        switch analysis.conversionPath {
        case .directPlayback:
            // Direct playback - keep original codec
            videoCodec = analysis.primaryVideo?.codecName.uppercased() ?? "H.264"
        case .fastRemux:
            // Container change only - keep original video
            videoCodec = "H.264"
        case .audioTranscode, .videoTranscode:
            // Transcoding - use HEVC if Ultra Quality + supported device
            let useHEVC = ultraQualityAudio && deviceSupportsHEVC
            videoCodec = useHEVC ? "HEVC" : "H.264"
        }

        // Audio codec and channels - depends on conversion path
        let audioCodec: String
        let audioChannels: String

        switch analysis.conversionPath {
        case .directPlayback:
            // Direct playback - keep original audio
            audioCodec = analysis.primaryAudio?.codecName.uppercased() ?? "AAC"
            if let channels = analysis.primaryAudio?.channels, channels >= 6 {
                audioChannels = "5.1"
            } else {
                audioChannels = "Stereo"
            }
        case .fastRemux, .audioTranscode, .videoTranscode:
            // Transcoding - always AAC output
            audioCodec = "AAC"
            audioChannels = ultraQualityAudio ? "5.1" : "Stereo"
        }

        await MainActor.run {
            outputResolution = resolution
            outputVideoCodec = videoCodec
            outputAudioCodec = audioCodec
            outputAudioChannels = audioChannels
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

    // MARK: - Seek Restart

    /// Restart transcoding from a specific position (YouTube-style seeking)
    /// Kills current FFmpeg, clears HLS directory, and restarts from new position
    func performSeekTranscode(to position: Double, from sourceURL: URL, mode: CompatibilityMode) async throws -> URL {
        logger.info("🎯 Seek-restart: killing current transcode, restarting from \(Int(position))s")

        // 1. Kill current FFmpeg process
        if let ffmpegProcess = currentProcess as? FFmpegProcess {
            await ffmpegProcess.terminate()
        }

        // 2. Stop HTTP server
        httpServer.forceStop()

        // 3. Update state
        await MainActor.run {
            isConverting = true
            isCancelled = false
            progress = 0
            statusMessage = "Seeking..."
        }

        // Store the new seek offset
        currentSeekOffset = position

        // Verify FFmpeg
        guard let ffmpegPath = findFFmpeg() else {
            throw TranscodeError.ffmpegNotFound
        }

        // Use cached analysis if available, otherwise re-analyze
        let analysis: MediaAnalysis
        if let cached = currentAnalysis {
            analysis = cached
        } else {
            guard let ffprobePath = MediaAnalyzer.findFFprobe(ffmpegPath: ffmpegPath) else {
                throw TranscodeError.ffmpegNotFound
            }
            analysis = try await MediaAnalyzer.analyze(url: sourceURL, ffprobePath: ffprobePath)
            currentAnalysis = analysis
        }

        // Determine video codec based on conversion path
        let videoCodec: String
        switch analysis.conversionPath {
        case .directPlayback, .fastRemux:
            // These paths don't use HLS, but for seek we need to use HLS
            // Fall through to audio transcode (copy video)
            videoCodec = "copy"
        case .audioTranscode:
            videoCodec = "copy"
        case .videoTranscode:
            videoCodec = "h264_videotoolbox"
        }

        // Start HLS transcode from the seek position
        let result = try await performHLSTranscode(
            input: sourceURL,
            ffmpegPath: ffmpegPath,
            analysis: analysis,
            videoCodec: videoCodec,
            mode: mode,
            startPosition: position
        )

        await MainActor.run {
            isConverting = false
        }

        return result
    }
}
