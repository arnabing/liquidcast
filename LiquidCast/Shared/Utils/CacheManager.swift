import Foundation
import os.log

private let logger = Logger(subsystem: "com.liquidcast", category: "CacheManager")

/// Manages cached converted media files
struct CacheManager {
    /// Maximum cache size in bytes (10 GB default)
    static let maxCacheSize: Int64 = 10 * 1024 * 1024 * 1024
    /// Cache directory for converted files
    static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let liquidCastCache = caches.appendingPathComponent("LiquidCast/ConvertedMedia", isDirectory: true)

        // Create directory if it doesn't exist
        if !FileManager.default.fileExists(atPath: liquidCastCache.path) {
            try? FileManager.default.createDirectory(at: liquidCastCache, withIntermediateDirectories: true)
            logger.info("Created cache directory: \(liquidCastCache.path)")
        }

        return liquidCastCache
    }

    /// Generate a stable cache key from the original file URL
    /// Uses file name + size for uniqueness (stable across app launches)
    /// Note: We don't include modification date since it can change when file is copied
    static func cacheKey(for url: URL) -> String {
        let baseName = url.deletingPathExtension().lastPathComponent

        // Get file size for additional uniqueness
        var sizeString = ""
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attributes[.size] as? Int64 {
            sizeString = "_\(size)"
        }

        // Create a stable hash using the filename + size
        // Use a simple deterministic hash instead of Swift's Hasher (which is randomly seeded)
        let inputString = "\(url.lastPathComponent)\(sizeString)"
        var hash: UInt32 = 5381
        for char in inputString.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt32(char) // djb2 hash algorithm
        }

        let hashString = String(format: "%08x", hash)
        return "\(baseName)_\(hashString)"
    }

    /// Get the cached MP4 URL for an original file (if it exists)
    static func cachedURL(for originalURL: URL) -> URL? {
        let key = cacheKey(for: originalURL)
        let cachedFile = cacheDirectory.appendingPathComponent("\(key).mp4")

        if FileManager.default.fileExists(atPath: cachedFile.path) {
            logger.info("Cache hit: \(cachedFile.lastPathComponent)")
            return cachedFile
        }

        logger.info("Cache miss for: \(originalURL.lastPathComponent)")
        return nil
    }

    /// Get the output URL for a new conversion (doesn't check existence)
    static func outputURL(for originalURL: URL) -> URL {
        let key = cacheKey(for: originalURL)
        return cacheDirectory.appendingPathComponent("\(key).mp4")
    }

    /// Get a temporary URL for in-progress conversion
    static func tempURL(for originalURL: URL) -> URL {
        let key = cacheKey(for: originalURL)
        return cacheDirectory.appendingPathComponent("\(key)_temp.mp4")
    }

    /// Get the HLS streaming directory for a file (contains playlist.m3u8 and segments)
    static func hlsDirectory(for originalURL: URL) -> URL {
        let key = cacheKey(for: originalURL)
        return cacheDirectory.appendingPathComponent("\(key)_hls", isDirectory: true)
    }

    /// Remove a cached file and its HLS directory
    static func removeCache(for originalURL: URL) {
        let cachedFile = outputURL(for: originalURL)
        let hlsDir = hlsDirectory(for: originalURL)

        try? FileManager.default.removeItem(at: cachedFile)
        try? FileManager.default.removeItem(at: hlsDir)
        logger.info("Removed cache: \(cachedFile.lastPathComponent)")
    }

    /// Remove an HLS directory by its playlist URL
    static func removeHLSCache(playlistURL: URL) {
        // The playlist is inside the HLS directory, so get the parent
        let hlsDir = playlistURL.deletingLastPathComponent()
        do {
            try FileManager.default.removeItem(at: hlsDir)
            logger.info("Removed HLS cache: \(hlsDir.lastPathComponent)")
        } catch {
            logger.error("Failed to remove HLS cache: \(error.localizedDescription)")
        }
    }

    /// Clear all cached converted files
    static func clearAllCache() {
        do {
            let contents = try FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)
            for file in contents {
                try FileManager.default.removeItem(at: file)
            }
            logger.info("Cleared all cache (\(contents.count) files)")
        } catch {
            logger.error("Failed to clear cache: \(error.localizedDescription)")
        }
    }

    /// Clear cache files older than specified days
    static func clearOldCache(olderThan days: Int) {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -days, to: Date())!

        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey]
            )

            var removedCount = 0
            for file in contents {
                if let modDate = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   modDate < cutoffDate {
                    try FileManager.default.removeItem(at: file)
                    removedCount += 1
                }
            }

            if removedCount > 0 {
                logger.info("Cleared \(removedCount) old cache files (older than \(days) days)")
            }
        } catch {
            logger.error("Failed to clear old cache: \(error.localizedDescription)")
        }
    }

    /// Get total size of cached files in bytes
    static func totalCacheSize() -> Int64 {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey]
            )

            var totalSize: Int64 = 0
            for file in contents {
                let resourceValues = try? file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                if resourceValues?.isDirectory == true {
                    // For directories (HLS), calculate total size recursively
                    totalSize += directorySize(at: file)
                } else if let size = resourceValues?.fileSize {
                    totalSize += Int64(size)
                }
            }

            return totalSize
        } catch {
            return 0
        }
    }

    /// Format cache size for display
    static func formattedCacheSize() -> String {
        let bytes = totalCacheSize()
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Enforce cache size limit by removing oldest files first
    /// Call this before starting a new conversion
    static func enforceCacheLimit() {
        let currentSize = totalCacheSize()
        guard currentSize > maxCacheSize else { return }

        logger.info("📦 Cache size \(formattedCacheSize()) exceeds limit, cleaning up...")

        do {
            // Get all files with their modification dates
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
            )

            // Sort by modification date (oldest first)
            let sortedFiles = contents.sorted { url1, url2 in
                let date1 = (try? url1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                let date2 = (try? url2.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                return date1 < date2
            }

            var freedSize: Int64 = 0
            var removedCount = 0
            let targetSize = maxCacheSize / 2 // Clear down to 50% to avoid frequent cleanups

            for file in sortedFiles {
                guard currentSize - freedSize > targetSize else { break }

                // Get file/directory size
                var itemSize: Int64 = 0
                let resourceValues = try? file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])

                if resourceValues?.isDirectory == true {
                    // For directories (HLS), calculate total size
                    itemSize = directorySize(at: file)
                } else {
                    itemSize = Int64(resourceValues?.fileSize ?? 0)
                }

                try FileManager.default.removeItem(at: file)
                freedSize += itemSize
                removedCount += 1
                logger.info("🗑️ Removed: \(file.lastPathComponent)")
            }

            logger.info("✅ Cache cleanup complete: removed \(removedCount) items, freed \(ByteCountFormatter.string(fromByteCount: freedSize, countStyle: .file))")
        } catch {
            logger.error("❌ Cache cleanup failed: \(error.localizedDescription)")
        }
    }

    /// Calculate total size of a directory recursively
    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalSize += Int64(size)
            }
        }
        return totalSize
    }

    // MARK: - Playback Position

    private static let positionPrefix = "playbackPosition_"

    /// Save playback position for a file
    static func savePlaybackPosition(for url: URL, position: Double) {
        let key = positionPrefix + cacheKey(for: url)
        UserDefaults.standard.set(position, forKey: key)
    }

    /// Get saved playback position for a file (returns nil if not found or < 10 seconds)
    static func getPlaybackPosition(for url: URL) -> Double? {
        let key = positionPrefix + cacheKey(for: url)
        let position = UserDefaults.standard.double(forKey: key)
        // Only return if meaningful (> 10 seconds in)
        return position > 10 ? position : nil
    }

    /// Clear saved playback position
    static func clearPlaybackPosition(for url: URL) {
        let key = positionPrefix + cacheKey(for: url)
        UserDefaults.standard.removeObject(forKey: key)
        logger.info("🗑️ Cleared playback position for: \(url.lastPathComponent)")
    }

    // MARK: - Duplicate Cleanup

    /// Remove duplicate cache entries (files with same base name but different hashes)
    /// This cleans up files created by the old random hash bug
    static func removeDuplicates() {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]
            )

            // Group by base name (before the hash)
            var fileGroups: [String: [(url: URL, date: Date, size: Int64)]] = [:]

            for file in contents {
                let name = file.deletingPathExtension().lastPathComponent
                // Extract base name (everything before _XXXXXXXX or _XXXXXXXX_hls)
                let parts = name.split(separator: "_")
                if parts.count >= 2 {
                    // Remove the hash part (last component, or second to last if _hls)
                    var baseParts = parts
                    if baseParts.last == "hls" && baseParts.count >= 2 {
                        baseParts.removeLast() // remove "hls"
                    }
                    baseParts.removeLast() // remove hash
                    let baseName = baseParts.joined(separator: "_")

                    let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast

                    var size: Int64 = 0
                    let resourceValues = try? file.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
                    if resourceValues?.isDirectory == true {
                        size = directorySize(at: file)
                    } else {
                        size = Int64(resourceValues?.fileSize ?? 0)
                    }

                    fileGroups[baseName, default: []].append((url: file, date: date, size: size))
                }
            }

            // For groups with multiple entries, keep only the newest
            var totalFreed: Int64 = 0
            var removedCount = 0

            for (baseName, files) in fileGroups where files.count > 1 {
                // Sort by date (newest first)
                let sorted = files.sorted { $0.date > $1.date }

                // Remove all but the newest
                for file in sorted.dropFirst() {
                    try FileManager.default.removeItem(at: file.url)
                    totalFreed += file.size
                    removedCount += 1
                    logger.info("🗑️ Removed duplicate: \(file.url.lastPathComponent)")
                }
                logger.info("📁 Kept newest for '\(baseName)': \(sorted.first?.url.lastPathComponent ?? "unknown")")
            }

            if removedCount > 0 {
                logger.info("✅ Duplicate cleanup: removed \(removedCount) duplicates, freed \(ByteCountFormatter.string(fromByteCount: totalFreed, countStyle: .file))")
            }
        } catch {
            logger.error("❌ Duplicate cleanup failed: \(error.localizedDescription)")
        }
    }
}
