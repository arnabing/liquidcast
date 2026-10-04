import Foundation

/// The fixed segment layout of one stream, decided before any encoding starts.
///
/// Because boundaries are known up front, the whole movie is published as a VOD
/// playlist immediately: the player sees the full duration and seeks natively, and
/// FFmpeg can be (re)started at any segment and still produce identical boundaries.
///
/// All times are "media time": seconds from the start of the source (source pts - start_time).
struct SegmentPlan: Equatable {
    /// Start time of each segment. `boundaries[0] == 0`, strictly increasing.
    let boundaries: [Double]
    /// Total media duration.
    let duration: Double

    var count: Int { boundaries.count }

    func start(of index: Int) -> Double { boundaries[index] }

    func end(of index: Int) -> Double {
        index + 1 < count ? boundaries[index + 1] : duration
    }

    func duration(of index: Int) -> Double { end(of: index) - start(of: index) }

    var longestSegment: Double { (0..<count).map { duration(of: $0) }.max() ?? 0 }

    /// Segment containing `time` (clamped to the valid range).
    func index(containing time: Double) -> Int {
        guard time > 0 else { return 0 }
        // Last boundary <= time
        var low = 0, high = count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if boundaries[mid] <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

    // MARK: - Construction

    /// Fixed-length segments, for re-encoded video (keyframes are forced on this grid).
    static func uniform(duration: Double, segmentLength: Double) -> SegmentPlan? {
        guard duration > 0, segmentLength > 0 else { return nil }
        var boundaries: [Double] = []
        var t = 0.0
        // Don't emit a sliver segment shorter than 0.5s at the end
        while t < duration - 0.5 || boundaries.isEmpty {
            boundaries.append(t)
            t += segmentLength
        }
        return SegmentPlan(boundaries: boundaries, duration: duration)
    }

    /// Segments cut at source keyframes, for stream-copied video (cuts can only happen on keyframes).
    /// A new segment starts at the first keyframe at least `targetLength` after the previous cut.
    /// - Parameter keyframes: Keyframe times in media time, any order.
    static func keyframeAligned(keyframes: [Double], duration: Double, targetLength: Double) -> SegmentPlan? {
        guard duration > 0, targetLength > 0 else { return nil }
        let sorted = keyframes.filter { $0 >= 0 && $0 < duration }.sorted()
        // Copy must start on a keyframe; require one at (or within a frame of) the start
        guard let first = sorted.first, first < 0.1 else { return nil }

        var boundaries: [Double] = [0]
        var last = 0.0
        for key in sorted where key >= last + targetLength && key < duration - 0.5 {
            boundaries.append(key)
            last = key
        }
        return SegmentPlan(boundaries: boundaries, duration: duration)
    }

    // MARK: - Playlist

    /// Complete VOD playlist. Segment URIs are `<index>.ts`, relative to the playlist URL.
    /// - Parameter startTime: Where playback should begin (resume position), via EXT-X-START.
    func playlist(startTime: Double = 0) -> String {
        let longest = longestSegment
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:6",
            "#EXT-X-TARGETDURATION:\(Int(longest.rounded(.up)))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
            "#EXT-X-INDEPENDENT-SEGMENTS",
        ]
        if startTime > 0 {
            lines.append(String(format: "#EXT-X-START:TIME-OFFSET=%.3f,PRECISE=YES", min(startTime, duration)))
        }
        for index in 0..<count {
            lines.append(String(format: "#EXTINF:%.6f,", duration(of: index)))
            lines.append("\(index).ts")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}
