import Foundation
import Network
import os
import os.log

private let logger = Logger(subsystem: "com.liquidcast", category: "HTTPServer")

struct HTTPRequest: Sendable {
    let method: String
    /// Decoded path without the leading "/" and without a query string
    let path: String
    /// Decoded query parameters
    var query: [String: String] = [:]
}

struct HTTPResponse: Sendable {
    let status: Int
    let contentType: String
    let body: Data
    /// Called with how long the client took to receive the whole response (seconds): from the start of
    /// sending until the client closes its end, which it does once it has every byte (we send
    /// `Connection: close`). Not "until the bytes were handed to the kernel": the socket send buffer
    /// (several MB, auto-tuned) would absorb a whole segment. If the client is still receiving at
    /// `deliveryDeadline`, that elapsed time is reported (it's at least that slow).
    var onDelivered: (@Sendable (TimeInterval) -> Void)? = nil
    var deliveryDeadline: TimeInterval = 60

    static func ok(_ body: Data, contentType: String, deliveryDeadline: TimeInterval = 60,
                   onDelivered: (@Sendable (TimeInterval) -> Void)? = nil) -> HTTPResponse {
        HTTPResponse(status: 200, contentType: contentType, body: body, onDelivered: onDelivered,
                     deliveryDeadline: deliveryDeadline)
    }

    static func error(_ status: Int) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "text/plain", body: Data(reasonPhrase(status).utf8))
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 503: return "Service Unavailable"
        default: return "Internal Server Error"
        }
    }
}

/// Minimal HTTP/1.1 server (Network.framework) that AirPlay receivers fetch HLS from.
/// AirPlay needs http:// URLs reachable from the receiver; file:// URLs don't work remotely.
///
/// Runs entirely off the main thread. Each request is answered by an async handler, so a
/// handler can wait (e.g. for a segment that is still being encoded) without blocking others.
final class LocalHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let handler: Handler
    private let queue = DispatchQueue(label: "com.liquidcast.http", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16 = 0
    /// In-flight start, shared by concurrent callers so only one listener is ever created
    private var startTask: Task<Void, Error>?

    private static let ports: [UInt16] = Array(8765...8775) + Array(9876...9885)
    private static let maxRequestSize = 16 * 1024
    /// Drop connections that don't send a complete request in time (idle/half-open clients)
    private static let requestTimeout: TimeInterval = 15

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var isRunning: Bool { lock.withLock { listener != nil } }

    /// Base URL using this Mac's LAN address (receivers can't reach localhost)
    var baseURL: URL? {
        let port = lock.withLock { self.port }
        guard port > 0 else { return nil }
        let host = LocalNetwork.primaryIPv4Address() ?? "localhost"
        return URL(string: "http://\(host):\(port)/")
    }

    /// Start listening on the first free port. No-op if already running; concurrent calls share one start.
    func start() async throws {
        let task = lock.withLock { () -> Task<Void, Error> in
            if let startTask { return startTask }
            let task = Task { try await self.listenOnFreePort() }
            startTask = task
            return task
        }
        do {
            try await task.value
        } catch {
            lock.withLock { startTask = nil }  // Allow a retry
            throw error
        }
    }

    private func listenOnFreePort() async throws {
        for port in Self.ports {
            if let listener = await startListener(on: port) {
                lock.withLock {
                    self.listener = listener
                    self.port = port
                }
                logger.info("HTTP server listening on port \(port)")
                return
            }
        }
        throw LocalHTTPServerError.noAvailablePort
    }

    func stop() {
        let listener = lock.withLock { () -> NWListener? in
            let current = self.listener
            self.listener = nil
            self.port = 0
            self.startTask = nil
            return current
        }
        listener?.cancel()
    }

    private func startListener(on port: UInt16) async -> NWListener? {
        guard let endpointPort = NWEndpoint.Port(rawValue: port),
              let listener = try? NWListener(using: .tcp, on: endpointPort) else {
            return nil
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        let ready: Bool = await withCheckedContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool) -> Void = { result in
                let first = resumed.withLock { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: result) }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .cancelled: finish(false)
                default: break
                }
            }
            listener.start(queue: queue)
        }

        guard ready else {
            listener.cancel()
            return nil
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                logger.error("HTTP listener failed: \(error.localizedDescription)")
            }
        }
        return listener
    }

    // MARK: - Connections

    /// Per-connection state, touched only on `queue`
    private final class Exchange: @unchecked Sendable {
        var receivedRequest = false
        var handlerTask: Task<Void, Never>?
    }

    private func handle(_ connection: NWConnection) {
        let exchange = Exchange()
        connection.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled:
                // Client went away: stop waiting for its segment
                exchange.handlerTask?.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + Self.requestTimeout) {
            if !exchange.receivedRequest { connection.cancel() }
        }
        receive(on: connection, exchange: exchange, buffer: Data())
    }

    /// Accumulate until the end of the request headers (requests can arrive in several packets)
    private func receive(on connection: NWConnection, exchange: Exchange, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxRequestSize) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }

            var buffer = buffer
            if let data { buffer.append(data) }

            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                exchange.receivedRequest = true
                self.respond(to: buffer[..<headerEnd.lowerBound], exchange: exchange, on: connection)
            } else if error != nil || isComplete || buffer.count > Self.maxRequestSize {
                connection.cancel()
            } else {
                self.receive(on: connection, exchange: exchange, buffer: buffer)
            }
        }
    }

    private func respond(to header: Data, exchange: Exchange, on connection: NWConnection) {
        guard let request = Self.parse(header) else {
            send(.error(400), method: "GET", on: connection)
            return
        }
        guard request.method == "GET" || request.method == "HEAD" else {
            send(.error(405), method: request.method, on: connection)
            return
        }
        // Info level so receiver behaviour can be read back later with `log show --info`
        logger.info("\(request.method, privacy: .public) /\(request.path, privacy: .public)")
        exchange.handlerTask = Task {
            let response = await handler(request)
            guard !Task.isCancelled else { return }
            send(response, method: request.method, on: connection)
        }
    }

    private func send(_ response: HTTPResponse, method: String, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(HTTPResponse.reasonPhrase(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-cache\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        if method != "HEAD" {
            payload.append(response.body)
        }
        let started = Date()
        connection.send(content: payload, isComplete: true, completion: .contentProcessed { [weak self] error in
            guard let self, error == nil, method != "HEAD", let onDelivered = response.onDelivered else {
                connection.cancel()
                return
            }
            // Delivered when the client closes (it has read everything); still open at the deadline
            // means it's at least that slow
            self.awaitClientClose(connection, deadline: started.addingTimeInterval(response.deliveryDeadline)) { _ in
                onDelivered(Date().timeIntervalSince(started))
                connection.cancel()
            }
        })
    }

    /// Read (and discard) until the client closes the connection, or the deadline passes
    private func awaitClientClose(_ connection: NWConnection, deadline: Date, completion: @escaping @Sendable (Bool) -> Void) {
        let once = OSAllocatedUnfairLock(initialState: false)
        let finish: @Sendable (Bool) -> Void = { closed in
            let first = once.withLock { done -> Bool in defer { done = true }; return !done }
            if first { completion(closed) }
        }
        queue.asyncAfter(deadline: .now() + max(deadline.timeIntervalSinceNow, 0)) { finish(false) }
        func next() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, isComplete, error in
                if isComplete || error != nil {
                    finish(error == nil || isComplete)
                } else {
                    next()
                }
            }
        }
        next()
    }

    static func parse(_ header: Data) -> HTTPRequest? {
        guard let text = String(data: header, encoding: .utf8),
              let requestLine = text.components(separatedBy: "\r\n").first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        var path = String(parts[1])
        var query: [String: String] = [:]
        if let mark = path.firstIndex(of: "?") {
            for pair in path[path.index(after: mark)...].split(separator: "&") {
                let keyValue = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                if let key = keyValue.first { query[key] = keyValue.count > 1 ? keyValue[1] : "" }
            }
            path = String(path[..<mark])
        }
        path = path.removingPercentEncoding ?? path
        while path.hasPrefix("/") { path.removeFirst() }
        return HTTPRequest(method: String(parts[0]), path: path, query: query)
    }
}

enum LocalHTTPServerError: LocalizedError {
    case noAvailablePort

    var errorDescription: String? {
        switch self {
        case .noAvailablePort:
            return "No available port for the streaming server (tried 8765-8775 and 9876-9885)."
        }
    }
}

enum LocalNetwork {
    /// IPv4 address of the active LAN interface (Wi-Fi or Ethernet, including USB/Thunderbolt adapters)
    static func primaryIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var candidates: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)
            guard let addr = interface.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            guard name.hasPrefix("en") else { continue }  // Skips utun (VPN), awdl, bridge, etc.

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            guard !address.hasPrefix("169.254.") else { continue }  // Link-local: no DHCP lease
            candidates.append((name, address))
        }

        // Prefer en0, then the lowest-numbered interface
        return candidates.min { lhs, rhs in
            let l = Int(lhs.name.dropFirst(2)) ?? .max
            let r = Int(rhs.name.dropFirst(2)) ?? .max
            return l < r
        }?.address
    }
}
