import Foundation

/// Text subtitles as segmented WebVTT for HLS.
///
/// Timing: video timestamps are media time + `StreamProfile.timestampBase` in both MPEG-TS
/// (`mpegts_copyts`) and fMP4. Cues are written on that same timeline, with an identity
/// `X-TIMESTAMP-MAP` (`MPEGTS=<base>×90000,LOCAL=<base>`): a player that applies the map and one that
/// reads cue times as stream timestamps (AVPlayer on macOS 26 ignores the map - measured) show a cue at
/// the same moment. Segments follow the video's `SegmentPlan`; a cue spanning a boundary appears in each
/// segment it overlaps.
///
/// Extraction is windowed (`window` seconds at a time, seeking into the file), so a request never waits
/// for a whole-file demux - which for a large remux on a network share would take minutes.
enum WebVTT {
    struct Cue: Codable, Equatable, Hashable, Sendable {
        let start: Double
        let end: Double
        /// Cue settings after the timing (line, position, align), may be empty
        let settings: String
        /// WebVTT cue text: escaped, only <b>/<i>/<u> markup
        let text: String
    }

    /// Length of an extraction window
    static let window: Double = 60
    /// Extra time read before a window, for cues that started earlier and are still showing
    static let windowPreroll: Double = 30

    /// Cues of window `windowIndex` ([window×i, window×(i+1)) media time) of a text subtitle stream
    static func cues(for url: URL, streamIndex: Int, codec: String, windowIndex: Int, ffmpegPath: String) async throws -> [Cue] {
        let windowStart = Double(windowIndex) * window
        let seek = max(0, windowStart - windowPreroll)
        let isASS = ["ass", "ssa"].contains(codec.lowercased())
        let output = try await ProcessRunner.output(of: ffmpegPath, arguments: [
            "-hide_banner", "-nostdin", "-loglevel", "error",
            "-ss", String(format: "%.3f", seek),
            "-i", url.path,
            "-map", "0:\(streamIndex)",
            "-t", String(format: "%.3f", windowStart + window - seek),
        ] + (isASS ? ["-c:s", "copy", "-f", "ass"] : ["-c:s", "webvtt", "-f", "webvtt"]) + ["-"])
        let text = String(decoding: output, as: UTF8.self)
        let parsed: [Cue] = isASS ? ASS.cues(from: text) : parse(text)
        // Times are relative to the seek point
        var cues: [Cue] = []
        for cue in parsed where cue.end + seek > windowStart && cue.start + seek < windowStart + window {
            cues.append(Cue(start: cue.start + seek, end: cue.end + seek, settings: cue.settings, text: cue.text))
        }
        return cues
    }

    /// Parse a WebVTT document as FFmpeg writes it (tolerant of cue identifiers and CRLF); cue text is
    /// sanitised for WebVTT (see `sanitize`)
    static func parse(_ text: String) -> [Cue] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        var cues: [Cue] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2 else { continue }
            let endParts = timing[1].trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard let start = parseTime(timing[0].trimmingCharacters(in: .whitespaces)),
                  let endText = endParts.first, let end = parseTime(String(endText)), end > start else { continue }
            let body = sanitize(lines[(timingIndex + 1)...].joined(separator: "\n").trimmingCharacters(in: .newlines))
            guard !body.isEmpty else { continue }
            cues.append(Cue(start: start, end: end, settings: endParts.count > 1 ? String(endParts[1]) : "", text: body))
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// Make subtitle text valid WebVTT cue text: keep <b>, <i>, <u>; drop other tags (e.g. SRT's
    /// <font>); escape any other '<', '>', '&'; break up "-->" (it would end the cue)
    static func sanitize(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "<", let close = text[index...].firstIndex(of: ">") {
                let tag = text[text.index(after: index)..<close].lowercased()
                let name = tag.hasPrefix("/") ? String(tag.dropFirst()) : tag
                if ["b", "i", "u"].contains(name) {
                    result += "<\(tag)>"
                    index = text.index(after: close)
                    continue
                }
                if let first = name.first, first.isLetter {
                    index = text.index(after: close)  // Another tag: drop it
                    continue
                }
            }
            switch character {
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "&":
                let rest = text[index...]
                let entities = ["&amp;", "&lt;", "&gt;", "&nbsp;", "&lrm;", "&rlm;"]
                result += entities.contains(where: { rest.hasPrefix($0) }) ? "&" : "&amp;"
            default: result.append(character)
            }
            index = text.index(after: index)
        }
        return result.replacingOccurrences(of: "--&gt;", with: "→")
    }

    /// "mm:ss.mmm" or "hh:mm:ss.mmm"
    static func parseTime(_ text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard (2...3).contains(parts.count), let seconds = Double(parts.last!) else { return nil }
        var total = seconds
        var multiplier = 60.0
        for part in parts.dropLast().reversed() {
            guard let value = Double(part) else { return nil }
            total += value * multiplier
            multiplier *= 60
        }
        return total
    }

    static func formatTime(_ seconds: Double) -> String {
        let milliseconds = Int((max(seconds, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", milliseconds / 3_600_000, (milliseconds / 60_000) % 60,
                      (milliseconds / 1000) % 60, milliseconds % 1000)
    }

    /// Windows a segment's time range needs
    static func windows(for index: Int, of plan: SegmentPlan) -> ClosedRange<Int> {
        let first = Int(plan.start(of: index) / window)
        let last = Int(max(plan.end(of: index) - 0.001, plan.start(of: index)) / window)
        return first...last
    }

    /// Media playlist of a subtitle rendition: one WebVTT segment per video segment
    static func playlist(plan: SegmentPlan) -> String {
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:3",
            "#EXT-X-TARGETDURATION:\(Int(plan.longestSegment.rounded(.up)))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
        ]
        for index in 0..<plan.count {
            lines.append(String(format: "#EXTINF:%.6f,", plan.duration(of: index)))
            lines.append("\(index).vtt")
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }

    /// WebVTT segment `index`: the cues overlapping it (cue times in media time)
    static func segment(_ index: Int, of plan: SegmentPlan, cues: [Cue]) -> String {
        let start = plan.start(of: index)
        let end = plan.end(of: index)
        let base = StreamProfile.timestampBase
        var text = "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS=\(Int((base * 90_000).rounded())),LOCAL=\(formatTime(base))\n"
        for cue in cues.sorted(by: { $0.start < $1.start }) where cue.start < end && cue.end > start {
            let settings = cue.settings.isEmpty ? "" : " " + cue.settings
            text += "\n\(formatTime(cue.start + base)) --> \(formatTime(cue.end + base))\(settings)\n\(cue.text)\n"
        }
        return text
    }
}

/// ASS/SSA events → WebVTT cues. FFmpeg's own ASS→WebVTT conversion keeps vector drawings as literal
/// text and drops positioning, so the original events are converted here: drawings (`\p1`…) are removed,
/// `\an`/`\a` alignment (or the style's) becomes cue settings, `\i`/`\b`/`\u` become markup, other
/// override tags are dropped.
enum ASS {
    static func cues(from script: String) -> [WebVTT.Cue] {
        var section = ""
        var styleFormat: [String] = []
        var eventFormat: [String] = []
        var styleAlignment: [String: Int] = [:]
        var cues: [WebVTT.Cue] = []

        for rawLine in script.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line.lowercased(); continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

            if key == "format" {
                let fields = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if section.contains("styles") { styleFormat = fields } else if section.contains("events") { eventFormat = fields }
            } else if key == "style", section.contains("styles") {
                let fields = value.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                if let nameIndex = styleFormat.firstIndex(of: "name"), let alignIndex = styleFormat.firstIndex(of: "alignment"),
                   nameIndex < fields.count, alignIndex < fields.count, let alignment = Int(fields[alignIndex]) {
                    styleAlignment[fields[nameIndex]] = alignment
                }
            } else if key == "dialogue", !eventFormat.isEmpty {
                // Text is the last field and may itself contain commas
                let fields = value.split(separator: ",", maxSplits: eventFormat.count - 1, omittingEmptySubsequences: false).map(String.init)
                func field(_ name: String) -> String? {
                    eventFormat.firstIndex(of: name).flatMap { $0 < fields.count ? fields[$0] : nil }
                }
                guard let start = field("start").flatMap(parseTime), let end = field("end").flatMap(parseTime),
                      end > start, let text = field("text") else { continue }
                let style = field("style")?.trimmingCharacters(in: .whitespaces) ?? ""
                guard let converted = convert(text, alignment: styleAlignment[style] ?? 2) else { continue }
                cues.append(WebVTT.Cue(start: start, end: end, settings: converted.settings, text: converted.text))
            }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "H:MM:SS.cc"
    static func parseTime(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let s = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// Event text → WebVTT text and settings; nil if nothing visible remains (e.g. a pure drawing)
    static func convert(_ text: String, alignment styleAlignment: Int) -> (text: String, settings: String)? {
        var alignment = styleAlignment
        var output = ""
        var drawing = false
        var open: [String] = []
        var index = text.startIndex

        func setTag(_ tag: String, on: Bool) {
            if on, !open.contains(tag) { output += "<\(tag)>"; open.append(tag) }
            if !on, let position = open.lastIndex(of: tag) {
                for closing in open[position...].reversed() { output += "</\(closing)>" }
                open.removeSubrange(position...)
            }
        }

        while index < text.endIndex {
            if text[index] == "{", let close = text[index...].firstIndex(of: "}") {
                // Override block: \tag pieces
                for piece in text[text.index(after: index)..<close].split(separator: "\\").map(String.init) {
                    if piece.hasPrefix("an"), let value = Int(piece.dropFirst(2)), (1...9).contains(value) {
                        alignment = value
                    } else if piece.hasPrefix("a"), !piece.hasPrefix("alpha"), let legacy = Int(piece.dropFirst()) {
                        // SSA legacy alignment: 1-3 bottom, +4 top (5-7), +8 middle (9-11)
                        let column = (legacy - 1) % 4 + 1
                        alignment = legacy >= 9 ? 3 + column : (legacy >= 5 ? 6 + column : column)
                    } else if piece.hasPrefix("p"), let level = Int(piece.dropFirst()) {
                        drawing = level > 0
                    } else if piece == "i1" || piece == "i0" {
                        setTag("i", on: piece == "i1")
                    } else if piece == "b1" || piece == "b0" {
                        setTag("b", on: piece == "b1")
                    } else if piece == "u1" || piece == "u0" {
                        setTag("u", on: piece == "u1")
                    }
                }
                index = text.index(after: close)
                continue
            }
            if !drawing {
                if text[index] == "\\", text.index(after: index) < text.endIndex {
                    let next = text[text.index(after: index)]
                    if next == "N" || next == "n" { output += "\n"; index = text.index(index, offsetBy: 2); continue }
                    if next == "h" { output += "\u{00A0}"; index = text.index(index, offsetBy: 2); continue }
                }
                switch text[index] {
                case "<": output += "&lt;"
                case ">": output += "&gt;"
                case "&": output += "&amp;"
                default: output.append(text[index])
                }
            }
            index = text.index(after: index)
        }
        for tag in open.reversed() { output += "</\(tag)>" }

        let visible = output.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { return nil }

        // Numpad layout: 7-9 top, 4-6 middle, 1-3 bottom; 1/4/7 left, 3/6/9 right
        var settings: [String] = []
        switch alignment {
        case 7...9: settings.append("line:0")
        case 4...6: settings.append("line:50%")
        default: break
        }
        switch alignment % 3 {
        case 1: settings.append("align:start")
        case 0: settings.append("align:end")
        default: break
        }
        return (output.replacingOccurrences(of: "--&gt;", with: "→").trimmingCharacters(in: .newlines),
                settings.joined(separator: " "))
    }
}
