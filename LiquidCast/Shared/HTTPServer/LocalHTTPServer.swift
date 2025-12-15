import Foundation
import Network
import os.log

private let logger = Logger(subsystem: "com.liquidcast", category: "HTTPServer")

/// Local HTTP server for serving HLS streams to AirPlay devices
/// Uses Apple's Network.framework - no external dependencies needed
/// AirPlay requires http:// URLs - local file:// URLs don't work for remote playback
@MainActor
class LocalHTTPServer {
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var servingDirectory: URL?
    private var assignedPort: UInt16 = 0
    private var sessionId: String?

    var isRunning: Bool { listener?.state == .ready }

    var baseURL: URL? {
        guard isRunning, assignedPort > 0 else { return nil }
        // Use the actual local IP address instead of localhost
        // AirPlay devices need to connect to our Mac's IP, not localhost
        guard let ip = getLocalIPAddress() else {
            return URL(string: "http://localhost:\(assignedPort)/")
        }
        return URL(string: "http://\(ip):\(assignedPort)/")
    }

    /// Get the local IP address that AirPlay devices can connect to
    private func getLocalIPAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return nil
        }

        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let addrFamily = interface.ifa_addr.pointee.sa_family

            // Check for IPv4 interface
            if addrFamily == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                // Prefer en0 (WiFi) or en1 (Ethernet)
                if name == "en0" || name == "en1" {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &hostname, socklen_t(hostname.count),
                               nil, socklen_t(0), NI_NUMERICHOST)
                    address = String(cString: hostname)
                    break
                }
            }
        }

        return address
    }

    /// Start serving files from the specified directory
    /// - Parameter directory: Directory containing HLS playlist and segments
    /// - Returns: Base URL for accessing the served content
    func startServing(directory: URL) throws -> URL {
        // If already serving the same directory, return existing URL
        if isRunning, servingDirectory == directory, let base = baseURL {
            logger.info("[\(self.sessionId ?? "?")] HTTP server already serving: \(base.absoluteString)")
            return base
        }

        // Stop any existing server
        forceStop()

        sessionId = UUID().uuidString.prefix(8).description
        servingDirectory = directory

        // Try ports in sequence (expanded range)
        let ports: [UInt16] = Array(8765...8775) + Array(9876...9885)

        for port in ports {
            if let url = tryStartListener(on: port, directory: directory) {
                return url
            }
        }

        throw LocalHTTPServerError.noAvailablePort
    }

    /// Try to start listener on a specific port
    /// - Returns: Base URL if successful, nil if port unavailable
    private func tryStartListener(on port: UInt16, directory: URL) -> URL? {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)

            // Use semaphore for synchronous wait (instead of Thread.sleep)
            let semaphore = DispatchSemaphore(value: 0)

            // Use thread-safe class wrapper for mutable state accessed in closure
            final class ListenerState: @unchecked Sendable {
                var ready = false
                var failed = false
            }
            let state = ListenerState()

            // Capture sessionId value for use in closure (avoids MainActor isolation issue)
            let currentSessionId = sessionId

            listener.stateUpdateHandler = { listenerState in
                switch listenerState {
                case .ready:
                    state.ready = true
                    semaphore.signal()
                case .failed(let error):
                    logger.error("[\(currentSessionId ?? "?")] HTTP server failed on port \(port): \(error.localizedDescription)")
                    state.failed = true
                    semaphore.signal()
                case .cancelled:
                    semaphore.signal()
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleConnection(connection)
                }
            }

            // Start on a background queue to avoid blocking main
            listener.start(queue: DispatchQueue.global(qos: .userInitiated))

            // Wait up to 2 seconds for listener to become ready
            let result = semaphore.wait(timeout: .now() + 2.0)

            if result == .timedOut {
                logger.warning("[\(self.sessionId ?? "?")] Timeout waiting for port \(port)")
                listener.cancel()
                return nil
            }

            if state.ready && !state.failed {
                self.listener = listener
                self.assignedPort = port
                // Use actual IP address for AirPlay devices
                let ip = getLocalIPAddress() ?? "localhost"
                let url = URL(string: "http://\(ip):\(port)/")!
                logger.info("[\(self.sessionId ?? "?")] HTTP server started on port \(port) at \(ip) serving: \(directory.lastPathComponent)")
                return url
            }

            listener.cancel()
            return nil

        } catch {
            logger.warning("[\(self.sessionId ?? "?")] Port \(port) unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    /// Stop the HTTP server (graceful)
    func stop() {
        guard listener != nil else { return }
        forceStop()
    }

    /// Force stop regardless of state - use for cleanup on errors
    func forceStop() {
        for connection in connections {
            connection.cancel()
        }
        connections.removeAll()

        listener?.cancel()
        listener = nil

        if sessionId != nil {
            logger.info("[\(self.sessionId ?? "?")] HTTP server stopped")
        }

        servingDirectory = nil
        assignedPort = 0
        sessionId = nil
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        connections.append(connection)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .cancelled = state {
                if let conn = connection {
                    Task { @MainActor in
                        self?.connections.removeAll { $0 === conn }
                    }
                }
            }
        }

        connection.start(queue: .main)
        receiveRequest(on: connection)
    }

    private func receiveRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let data = data, !data.isEmpty else {
                if isComplete || error != nil {
                    connection.cancel()
                }
                return
            }

            if let request = String(data: data, encoding: .utf8) {
                Task { @MainActor in
                    self?.handleHTTPRequest(request, on: connection)
                }
            } else {
                connection.cancel()
            }
        }
    }

    private func handleHTTPRequest(_ request: String, on connection: NWConnection) {
        // Parse the request line (e.g., "GET /playlist.m3u8 HTTP/1.1")
        let lines = request.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendErrorResponse(404, on: connection)
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            sendErrorResponse(405, on: connection)
            return
        }

        // Decode URL path
        var path = parts[1]
        if path.hasPrefix("/") {
            path = String(path.dropFirst())
        }
        path = path.removingPercentEncoding ?? path

        // Remove query string if present
        if let queryIndex = path.firstIndex(of: "?") {
            path = String(path[..<queryIndex])
        }

        guard let directory = servingDirectory else {
            sendErrorResponse(500, on: connection)
            return
        }

        let fileURL = directory.appendingPathComponent(path)

        // Security: ensure the file is within the serving directory
        guard fileURL.path.hasPrefix(directory.path) else {
            sendErrorResponse(403, on: connection)
            return
        }

        // Read and send the file
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            logger.warning("File not found: \(path)")
            sendErrorResponse(404, on: connection)
            return
        }

        do {
            var fileData: Data

            // For playlist files, filter to only include existing segments
            if path.hasSuffix(".m3u8") {
                let filteredPlaylist = filterPlaylistToExistingSegments(playlistURL: fileURL, directory: directory)
                fileData = Data(filteredPlaylist.utf8)
            } else {
                fileData = try Data(contentsOf: fileURL)
            }

            let contentType = mimeType(for: fileURL.pathExtension)

            let headers = """
            HTTP/1.1 200 OK\r
            Content-Type: \(contentType)\r
            Content-Length: \(fileData.count)\r
            Access-Control-Allow-Origin: *\r
            Cache-Control: no-cache\r
            Connection: close\r
            \r

            """

            var response = Data(headers.utf8)
            response.append(fileData)

            connection.send(content: response, completion: .contentProcessed { _ in
                connection.cancel()
            })

            logger.debug("Served: \(path) (\(fileData.count) bytes)")
        } catch {
            logger.error("Error reading file \(path): \(error.localizedDescription)")
            sendErrorResponse(500, on: connection)
        }
    }

    /// Filter HLS playlist to only include segments that actually exist on disk
    /// This is critical for live transcoding where FFmpeg writes the full playlist
    /// but segments are created progressively
    private func filterPlaylistToExistingSegments(playlistURL: URL, directory: URL) -> String {
        guard let playlistContent = try? String(contentsOf: playlistURL, encoding: .utf8) else {
            return ""
        }

        var filteredLines: [String] = []
        let lines = playlistContent.components(separatedBy: "\n")
        var existingSegments: [(extinf: String, segment: String)] = []

        // First pass: collect all segments and check existence
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("#EXTINF:") {
                // This line is followed by a segment filename
                let nextIndex = i + 1
                if nextIndex < lines.count {
                    let segmentLine = lines[nextIndex].trimmingCharacters(in: .whitespaces)
                    if !segmentLine.isEmpty && !segmentLine.hasPrefix("#") {
                        let segmentURL = directory.appendingPathComponent(segmentLine)
                        if FileManager.default.fileExists(atPath: segmentURL.path) {
                            // Verify segment is complete (> 10KB minimum to avoid partial writes)
                            if let attrs = try? FileManager.default.attributesOfItem(atPath: segmentURL.path),
                               let size = attrs[.size] as? Int64,
                               size > 10_000 {
                                existingSegments.append((extinf: line, segment: segmentLine))
                            }
                        }
                    }
                }
                i += 2
                continue
            }
            i += 1
        }

        // Build filtered playlist
        // Copy header lines
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXTM3U") ||
               trimmed.hasPrefix("#EXT-X-VERSION") ||
               trimmed.hasPrefix("#EXT-X-TARGETDURATION") ||
               trimmed.hasPrefix("#EXT-X-MEDIA-SEQUENCE") ||
               trimmed.hasPrefix("#EXT-X-PLAYLIST-TYPE") ||
               trimmed.hasPrefix("#EXT-X-INDEPENDENT-SEGMENTS") {
                filteredLines.append(line)
            }
        }

        // Add only existing segments (in order)
        for segment in existingSegments {
            filteredLines.append(segment.extinf)
            filteredLines.append(segment.segment)
        }

        // Don't add #EXT-X-ENDLIST unless transcoding is complete
        // (We can detect this by checking if FFmpeg is still running,
        // but for now we check if the original playlist has it AND all segments exist)
        let originalHasEndList = playlistContent.contains("#EXT-X-ENDLIST")
        if originalHasEndList {
            // Count segments in original playlist
            let originalSegmentCount = lines.filter { $0.hasSuffix(".ts") }.count
            if existingSegments.count >= originalSegmentCount {
                filteredLines.append("#EXT-X-ENDLIST")
            }
        }

        return filteredLines.joined(separator: "\n")
    }

    private func sendErrorResponse(_ code: Int, on connection: NWConnection) {
        let message: String
        switch code {
        case 403: message = "Forbidden"
        case 404: message = "Not Found"
        case 405: message = "Method Not Allowed"
        default: message = "Internal Server Error"
        }

        let response = """
        HTTP/1.1 \(code) \(message)\r
        Content-Type: text/plain\r
        Content-Length: \(message.count)\r
        Connection: close\r
        \r
        \(message)
        """

        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func mimeType(for ext: String) -> String {
        switch ext.lowercased() {
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "mp4", "m4v": return "video/mp4"
        case "m4s": return "video/iso.segment"
        default: return "application/octet-stream"
        }
    }
}

enum LocalHTTPServerError: LocalizedError {
    case noAvailablePort

    var errorDescription: String? {
        switch self {
        case .noAvailablePort:
            return "No available port for HTTP server. Ports 8765-8769 and 9876-9877 are all in use."
        }
    }
}
