import Foundation

/// Fragmented-MP4 segments as FFmpeg's segment muxer writes them, turned into HLS fMP4 pieces.
///
/// Each segment file is self-contained: `ftyp` `moov` (`moof` `mdat`)… [`mfra`]. The `moov` is
/// byte-identical in every file of every job (verified), so the first file's `ftyp`+`moov` serves
/// as the stream's one init segment (`#EXT-X-MAP`), and media segments are served as the
/// `moof`/`mdat` boxes alone.
enum MP4Segment {
    struct Box {
        let type: String
        let range: Range<Int>
        let headerSize: Int
        var payload: Range<Int> { (range.lowerBound + headerSize)..<range.upperBound }
    }

    /// Top-level boxes in `range` (default: all of `data`)
    static func boxes(in data: Data, range: Range<Int>? = nil) -> [Box] {
        let range = range ?? data.startIndex..<data.endIndex
        var result: [Box] = []
        var offset = range.lowerBound
        while offset + 8 <= range.upperBound {
            var size = Int(readUInt32(data, offset))
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            var header = 8
            if size == 1 {
                guard offset + 16 <= range.upperBound else { break }
                size = Int(readUInt64(data, offset + 8))
                header = 16
            } else if size == 0 {
                size = range.upperBound - offset
            }
            guard size >= header, offset + size <= range.upperBound else { break }  // Truncated/corrupt
            result.append(Box(type: type, range: offset..<(offset + size), headerSize: header))
            offset += size
        }
        return result
    }

    /// `ftyp` + `moov`: the init segment
    static func initSection(of data: Data) -> Data? {
        let parts = boxes(in: data).filter { $0.type == "ftyp" || $0.type == "moov" }
        guard parts.contains(where: { $0.type == "moov" }) else { return nil }
        return parts.reduce(into: Data()) { $0.append(data[$1.range]) }
    }

    /// `moof`/`mdat` pairs: the media segment
    static func mediaSection(of data: Data) -> Data {
        boxes(in: data)
            .filter { $0.type == "moof" || $0.type == "mdat" }
            .reduce(into: Data()) { $0.append(data[$1.range]) }
    }

    /// RFC 6381 codec string for the HEVC track (e.g. `hvc1.2.4.L150.90`), from the `hvcC` box
    /// (ISO/IEC 14496-15 Annex E)
    static func hevcCodecString(in data: Data) -> String? {
        guard let marker = data.range(of: Data("hvcC".utf8)) else { return nil }
        let config = marker.upperBound
        guard config + 13 <= data.endIndex else { return nil }

        let byte1 = data[config + 1]
        let profileSpace = Int(byte1 >> 6)
        let tierFlag = (byte1 >> 5) & 1
        let profileIdc = Int(byte1 & 0x1f)
        let compatibility = readUInt32(data, config + 2)
        let constraints = Array(data[(config + 6)..<(config + 12)])
        let level = Int(data[config + 12])

        // Compatibility flags are written bit-reversed, in hex
        var reversed: UInt32 = 0
        for bit in 0..<32 where compatibility & (1 << bit) != 0 {
            reversed |= 1 << (31 - bit)
        }
        var trimmed = constraints
        while trimmed.last == 0 { trimmed.removeLast() }

        let space = profileSpace == 0 ? "" : String(["A", "B", "C"][profileSpace - 1])
        var codec = "hvc1.\(space)\(profileIdc).\(String(reversed, radix: 16, uppercase: true))."
        codec += "\(tierFlag == 1 ? "H" : "L")\(level)"
        codec += trimmed.map { "." + String($0, radix: 16, uppercase: true) }.joined()
        return codec
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        data[offset..<(offset + 4)].reduce(0) { $0 << 8 | UInt32($1) }
    }

    private static func readUInt64(_ data: Data, _ offset: Int) -> UInt64 {
        data[offset..<(offset + 8)].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
