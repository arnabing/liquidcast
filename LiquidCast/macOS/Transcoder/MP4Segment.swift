import Foundation

/// Fragmented-MP4 segments as FFmpeg's segment muxer writes them, turned into HLS fMP4 pieces.
///
/// Each segment file is self-contained: `ftyp` `moov` (`moof` `mdat`)… [`mfra`]. With
/// `frag_discont` + `use_editlist=1`, the muxer anchors each *file's* decode timeline at its first
/// frame's presentation time: decode times (`tfdt`) are absolute but shifted by that frame's
/// composition offset (the B-frame reorder delay, which varies per file), and a per-file edit list
/// (`edts`) in the `moov` undoes the shift. Served as-is, the init would only fit some files (video
/// up to ~0.2s off audio for others). So, verified against FFmpeg 8:
/// - init (`#EXT-X-MAP`): any file's `ftyp`+`moov` minus `edts`. Identical for every file of every job
/// - media segment: the `moof`/`mdat` boxes, with each track's `tfdt` reduced by that file's first
///   composition offset, which puts every file on the true decode timeline
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

    /// `ftyp` + `moov` without edit lists: the init segment
    static func initSection(of data: Data) -> Data? {
        var result = Data()
        var hasMoov = false
        for box in boxes(in: data) {
            switch box.type {
            case "ftyp":
                result.append(data[box.range])
            case "moov":
                hasMoov = true
                var moov = Data()
                for child in boxes(in: data, range: box.payload) {
                    if child.type == "trak" {
                        let trak = boxes(in: data, range: child.payload)
                            .filter { $0.type != "edts" }
                            .reduce(into: Data()) { $0.append(data[$1.range]) }
                        moov.append(makeBox("trak", trak))
                    } else {
                        moov.append(data[child.range])
                    }
                }
                result.append(makeBox("moov", moov))
            default:
                break
            }
        }
        return hasMoov ? result : nil
    }

    /// `moof`/`mdat` pairs: the media segment, on the true decode timeline (see type comment)
    static func mediaSection(of data: Data) -> Data {
        var media = boxes(in: data)
            .filter { $0.type == "moof" || $0.type == "mdat" }
            .reduce(into: Data()) { $0.append(data[$1.range]) }

        // Each track's first composition offset in this file, then shift all its tfdt by it
        var offsets: [UInt32: UInt64] = [:]
        for moof in boxes(in: media) where moof.type == "moof" {
            for traf in boxes(in: media, range: moof.payload) where traf.type == "traf" {
                let children = boxes(in: media, range: traf.payload)
                guard let tfhd = children.first(where: { $0.type == "tfhd" }) else { continue }
                let trackId = readUInt32(media, tfhd.payload.lowerBound + 4)
                if offsets[trackId] == nil {
                    offsets[trackId] = children.first { $0.type == "trun" }.map { firstCompositionOffset(media, trun: $0) } ?? 0
                }
                guard let shift = offsets[trackId], shift > 0,
                      let tfdt = children.first(where: { $0.type == "tfdt" }) else { continue }
                let start = tfdt.payload.lowerBound
                if media[start] == 1 {
                    let value = readUInt64(media, start + 4)
                    writeBigEndian(&media, at: start + 4, value: value >= shift ? value - shift : 0, bytes: 8)
                } else {
                    let value = UInt64(readUInt32(media, start + 4))
                    writeBigEndian(&media, at: start + 4, value: value >= shift ? value - shift : 0, bytes: 4)
                }
            }
        }
        return media
    }

    /// Composition offset of a `trun`'s first sample (0 if the run carries none)
    private static func firstCompositionOffset(_ data: Data, trun: Box) -> UInt64 {
        let start = trun.payload.lowerBound
        let version = data[start]
        let flags = readUInt32(data, start) & 0x00ff_ffff
        var offset = start + 8  // version/flags, sample_count
        if flags & 0x001 != 0 { offset += 4 }  // data_offset
        if flags & 0x004 != 0 { offset += 4 }  // first_sample_flags
        if flags & 0x100 != 0 { offset += 4 }  // sample_duration
        if flags & 0x200 != 0 { offset += 4 }  // sample_size
        if flags & 0x400 != 0 { offset += 4 }  // sample_flags
        guard flags & 0x800 != 0, offset + 4 <= trun.range.upperBound else { return 0 }
        let raw = readUInt32(data, offset)
        if version == 1 {
            let signed = Int32(bitPattern: raw)
            return signed > 0 ? UInt64(signed) : 0
        }
        return UInt64(raw)
    }

    private static func makeBox(_ type: String, _ payload: Data) -> Data {
        var box = Data()
        writeBigEndian(&box, value: UInt64(payload.count + 8), bytes: 4)
        box.append(Data(type.utf8))
        box.append(payload)
        return box
    }

    /// Append (at: nil) or overwrite `bytes` big-endian bytes
    private static func writeBigEndian(_ data: inout Data, at index: Int? = nil, value: UInt64, bytes: Int) {
        let encoded = (0..<bytes).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64(bytes - 1 - $0))) }
        if let index {
            data.replaceSubrange(index..<(index + bytes), with: encoded)
        } else {
            data.append(contentsOf: encoded)
        }
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
