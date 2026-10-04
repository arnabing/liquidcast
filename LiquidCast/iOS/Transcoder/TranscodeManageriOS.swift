import Foundation
import os.log

private let logger = Logger(subsystem: "com.liquidcast", category: "Transcoder")

/// iOS stub - conversion not supported on iOS
extension TranscodeManager {

    /// iOS does not support FFmpeg transcoding
    func performPreparation(from url: URL, mode: CompatibilityMode, startPosition: Double,
                            passthrough: Passthrough, burnIn: SubtitleBurnIn) async throws -> URL {
        logger.error("📱 Conversion not supported on iOS")
        throw TranscodeError.notSupportedOnPlatform
    }
}
