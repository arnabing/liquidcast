import Foundation
import os.log

private let logger = Logger(subsystem: "com.liquidcast", category: "HLSMonitor")

/// Simple monitor that waits for HLS segment to be ready
/// Not an actor - just a simple polling helper
struct HLSSegmentMonitor {
    let hlsDir: URL
    let playlistURL: URL

    init(hlsDirectory: URL) {
        self.hlsDir = hlsDirectory
        self.playlistURL = hlsDirectory.appendingPathComponent("playlist.m3u8")
    }

    /// Wait for HLS segments to be ready for playback
    /// Waits for at least 3 segments to ensure smooth playback start
    func waitForFirstSegment(timeout: TimeInterval) async throws -> URL {
        logger.info("⏳ Waiting for HLS segments (timeout: \(Int(timeout))s)")

        let startTime = Date()
        var checkCount = 0
        let minSegments = 3  // Wait for 3 segments (~18 seconds of video)

        while Date().timeIntervalSince(startTime) < timeout {
            checkCount += 1

            // Check for ready segments
            let readyCount = countReadySegments()
            if readyCount >= minSegments {
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                logger.info("✅ \(readyCount) segments ready after \(elapsed)ms (check #\(checkCount))")
                return playlistURL
            }

            // Short sleep - 100ms
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Timeout
        let diag = gatherDiagnostics()
        logger.error("❌ Timeout after \(checkCount) checks: \(diag)")
        throw HLSMonitorError.timeout(diagnostics: diag)
    }

    /// Count segments that are ready (exist and > 100KB)
    private func countReadySegments() -> Int {
        guard let files = try? FileManager.default.contentsOfDirectory(at: hlsDir, includingPropertiesForKeys: nil) else {
            return 0
        }

        var count = 0
        for file in files where file.pathExtension == "ts" {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let size = attrs[.size] as? Int64,
               size > 100_000 { // 100KB minimum
                count += 1
            }
        }
        return count
    }

    private func gatherDiagnostics() -> String {
        let playlistExists = FileManager.default.fileExists(atPath: playlistURL.path)
        var segmentCount = 0
        var firstSize: Int64 = 0

        if let files = try? FileManager.default.contentsOfDirectory(at: hlsDir, includingPropertiesForKeys: nil) {
            let segments = files.filter { $0.pathExtension == "ts" }.sorted { $0.path < $1.path }
            segmentCount = segments.count
            if let first = segments.first,
               let attrs = try? FileManager.default.attributesOfItem(atPath: first.path),
               let size = attrs[.size] as? Int64 {
                firstSize = size
            }
        }

        return "playlist=\(playlistExists), segments=\(segmentCount), firstSize=\(firstSize)"
    }
}

enum HLSMonitorError: LocalizedError {
    case timeout(diagnostics: String)

    var errorDescription: String? {
        switch self {
        case .timeout(let diagnostics):
            return "Timed out waiting for HLS segment (\(diagnostics))"
        }
    }
}
