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
        return URL(string: "http://localhost:\(assignedPort)/")
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
            var listenerReady = false
            var listenerFailed = false

            // Capture sessionId value for use in closure (avoids MainActor isolation issue)
            let currentSessionId = sessionId

            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listenerReady = true
                    semaphore.signal()
                case .failed(let error):
                    logger.error("[\(currentSessionId ?? "?")] HTTP server failed on port \(port): \(error.localizedDescription)")
                    listenerFailed = true
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

            if listenerReady && !listenerFailed {
                self.listener = listener
                self.assignedPort = port
                logger.info("[\(self.sessionId ?? "?")] HTTP server started on port \(port) serving: \(directory.lastPathComponent)")
                return URL(string: "http://localhost:\(port)/")!
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
            let fileData = try Data(contentsOf: fileURL)
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
