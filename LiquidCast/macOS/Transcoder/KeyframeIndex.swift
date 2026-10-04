import Foundation
import os.log

private let logger = Logger(subsystem: "com.liquidcast", category: "KeyframeIndex")

/// Video keyframe times of a source file, needed to cut stream-copied video into segments.
/// Found by demuxing (not decoding) the file once; cached on disk per file (name, size, mtime).
enum KeyframeIndex {

    /// Keyframe times in media time (seconds from the container start), sorted.
    static func keyframes(
        for url: URL,
        videoStreamIndex: Int,
        startTime: Double,
        ffprobePath: String
    ) async throws -> [Double] {
        let cacheURL = cacheFile(for: url, videoStreamIndex: videoStreamIndex)
        if let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode([Double].self, from: data) {
            logger.info("Keyframe index cache hit: \(cached.count) keyframes")
            return cached
        }

        let started = Date()
        let output = try await ProcessRunner.output(of: ffprobePath, arguments: [
            "-v", "error",
            "-select_streams", "\(videoStreamIndex)",
            "-show_entries", "packet=pts_time,flags",
            "-of", "csv=p=0",
            url.path
        ])

        let keyframes = parse(String(decoding: output, as: UTF8.self), startTime: startTime)
        logger.info("Indexed \(keyframes.count) keyframes in \(String(format: "%.1f", Date().timeIntervalSince(started)))s")

        if let data = try? JSONEncoder().encode(keyframes) {
            try? data.write(to: cacheURL, options: .atomic)
        }
        return keyframes
    }

    /// Where stream-copied video actually starts when FFmpeg seeks to `seek`: the demuxer jumps to an
    /// indexed keyframe at or before it, which may be well before. Runs the same FFmpeg seek as the
    /// real job and reports the first video packet (~50ms).
    /// - Returns: Media time of the first video packet
    static func seekLanding(
        for url: URL,
        seek: Double,
        videoStreamIndex: Int,
        startTime: Double,
        ffmpegPath: String
    ) async throws -> Double {
        var arguments = ["-hide_banner", "-nostdin", "-loglevel", "error"]
        if seek > 0 {
            arguments += ["-ss", String(format: "%.6f", seek)]
        }
        arguments += [
            "-i", url.path,
            "-map", "0:\(videoStreamIndex)",
            "-c", "copy",
            "-frames:v", "1",
            "-copyts",          // Report source timestamps
            "-f", "framecrc", "-"
        ]
        let output = String(decoding: try await ProcessRunner.output(of: ffmpegPath, arguments: arguments), as: UTF8.self)
        guard let pts = parseFrameCRC(output) else {
            throw KeyframeIndexError.landingNotFound
        }
        return pts - startTime
    }

    /// First packet pts (seconds) from FFmpeg `framecrc` output:
    /// `#tb 0: 1/1000` then `stream, dts, pts, duration, size, crc`
    static func parseFrameCRC(_ output: String) -> Double? {
        var timeBase: Double?
        for line in output.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#tb 0:") {
                let fraction = line.dropFirst(6).trimmingCharacters(in: .whitespaces).split(separator: "/")
                if fraction.count == 2, let num = Double(fraction[0]), let den = Double(fraction[1]), den > 0 {
                    timeBase = num / den
                }
            } else if !line.hasPrefix("#"), let timeBase {
                let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard fields.count >= 3, let pts = Double(fields[2]) else { return nil }
                return pts * timeBase
            }
        }
        return nil
    }

    /// Parse ffprobe `pts_time,flags` CSV lines; keep keyframes ("K" flag) with a valid pts.
    static func parse(_ csv: String, startTime: Double) -> [Double] {
        var result: [Double] = []
        for line in csv.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2, fields[1].contains("K"), let pts = Double(fields[0]) else { continue }
            result.append(pts - startTime)
        }
        return result.sorted()
    }

    private static func cacheFile(for url: URL, videoStreamIndex: Int) -> URL {
        let directory = CacheManager.cacheDirectory.appendingPathComponent("Keyframes", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let name = "\(CacheManager.cacheKey(for: url))_\(Int(modified))_v\(videoStreamIndex).json"
        return directory.appendingPathComponent(name)
    }
}

enum KeyframeIndexError: LocalizedError {
    case landingNotFound

    var errorDescription: String? {
        switch self {
        case .landingNotFound: return "Could not determine where the video starts after seeking"
        }
    }
}
