import Foundation

/// Supported media format categories
enum MediaFormat {
    /// Formats natively supported by AVPlayer and AirPlay (MP4, MOV, M4V)
    case nativeAirPlay
    /// Formats that require conversion for AirPlay (MKV, AVI, WMV, etc.)
    case requiresConversion
}

/// Utility for detecting media file formats
struct FormatDetector {
    /// File extensions that AVPlayer/AirPlay support natively
    private static let nativeExtensions: Set<String> = [
        "mp4", "m4v", "mov", "m4a", "mp3", "aac", "wav"
    ]

    /// File extensions that require conversion for AirPlay
    private static let conversionExtensions: Set<String> = [
        "mkv", "avi", "wmv", "flv", "webm", "ogv", "ogm",
        "rmvb", "rm", "asf", "ts", "mts", "m2ts", "vob"
    ]

    /// Detect the format category of a media file
    /// - Parameter url: URL to the media file
    /// - Returns: The format category (native or requires conversion)
    static func detect(_ url: URL) -> MediaFormat {
        let ext = url.pathExtension.lowercased()

        if nativeExtensions.contains(ext) {
            return .nativeAirPlay
        } else if conversionExtensions.contains(ext) {
            return .requiresConversion
        } else {
            // Unknown extension - try native first, will fail gracefully
            return .nativeAirPlay
        }
    }

    /// Check if a file requires conversion for AirPlay
    static func requiresConversion(_ url: URL) -> Bool {
        detect(url) == .requiresConversion
    }

    /// Get a human-readable format name
    static func formatName(_ url: URL) -> String {
        let ext = url.pathExtension.uppercased()
        return ext.isEmpty ? "Unknown" : ext
    }
}
