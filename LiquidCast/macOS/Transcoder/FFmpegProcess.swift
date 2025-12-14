import Foundation
import os.log

private let logger = Logger(subsystem: "com.liquidcast", category: "FFmpegProcess")

/// Manages an FFmpeg process with proper lifecycle and error handling
/// Uses actor isolation for thread-safe state management
actor FFmpegProcess {
    private var process: Process?
    private var hasExited = false
    private var exitStatus: Int32?
    private var exitError: String?
    private var errorOutput: String = ""

    private let processId = UUID().uuidString.prefix(8)

    enum State: Equatable {
        case idle
        case running
        case completed(exitCode: Int32)
        case failed(error: String)
        case cancelled
    }

    private(set) var state: State = .idle

    /// Start FFmpeg with given arguments
    /// - Parameters:
    ///   - ffmpegPath: Path to ffmpeg binary
    ///   - arguments: Command line arguments
    func start(ffmpegPath: String, arguments: [String]) throws {
        guard case .idle = state else {
            throw FFmpegProcessError.alreadyStarted
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments

        // Capture stderr for error messages
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice  // Discard stdout (progress goes to stderr)
        process.standardError = errorPipe

        self.process = process

        try process.run()
        state = .running
        logger.info("[\(self.processId)] FFmpeg started: \(arguments.joined(separator: " ").prefix(200))...")

        // Monitor process in background
        Task { [weak self] in
            await self?.monitorProcess(errorPipe: errorPipe)
        }
    }

    private func monitorProcess(errorPipe: Pipe) async {
        guard let process = process else { return }

        // Read error output in background (non-isolated to avoid actor reentrancy)
        let errorHandle = errorPipe.fileHandleForReading
        Task.detached { [weak self] in
            var buffer = ""
            for try await line in errorHandle.bytes.lines {
                buffer += line + "\n"
                // Keep only last 2000 chars to avoid memory issues
                if buffer.count > 2000 {
                    buffer = String(buffer.suffix(2000))
                }
            }
            await self?.setErrorOutput(buffer)
        }

        process.waitUntilExit()

        let status = process.terminationStatus
        hasExited = true
        exitStatus = status

        if status != 0 {
            // Read any remaining error output
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            if let str = String(data: errorData, encoding: .utf8) {
                errorOutput += str
            }

            exitError = errorOutput
            state = .failed(error: errorOutput)
            logger.error("[\(self.processId)] FFmpeg failed (exit \(status)): \(self.errorOutput.prefix(500))")
        } else {
            state = .completed(exitCode: status)
            logger.info("[\(self.processId)] FFmpeg completed successfully")
        }
    }

    /// Set error output from detached task
    private func setErrorOutput(_ output: String) {
        self.errorOutput = output
    }

    /// Check if process has failed - throws if so
    func checkForFailure() throws {
        switch state {
        case .failed(let error):
            throw FFmpegProcessError.processFailed(error)
        case .cancelled:
            throw FFmpegProcessError.cancelled
        default:
            break
        }
    }

    /// Check if process is still running
    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Check if process has exited (success or failure)
    var hasFinished: Bool {
        hasExited
    }

    /// Get the exit error message if failed
    var failureReason: String? {
        if case .failed(let error) = state {
            return error
        }
        return nil
    }

    /// Terminate the process
    func terminate() {
        guard let process = process, process.isRunning else { return }

        process.terminate()
        state = .cancelled
        hasExited = true
        logger.info("[\(self.processId)] FFmpeg terminated by request")
    }

    /// Wait for process to finish with a timeout
    /// Returns exit code on success, throws on failure/timeout
    func waitForExit(timeout: TimeInterval) async throws -> Int32 {
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if hasExited {
                if let status = exitStatus, status == 0 {
                    return status
                }
                if let error = exitError {
                    throw FFmpegProcessError.processFailed(error)
                }
                return exitStatus ?? -1
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        // Timeout - kill process
        terminate()
        throw FFmpegProcessError.timeout
    }
}

enum FFmpegProcessError: LocalizedError {
    case alreadyStarted
    case processFailed(String)
    case cancelled
    case timeout

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "FFmpeg process already started"
        case .processFailed(let msg):
            // Extract useful part of error message
            let lines = msg.components(separatedBy: "\n")
            let errorLines = lines.filter { $0.contains("Error") || $0.contains("error") || $0.contains("Invalid") }
            if let firstError = errorLines.first {
                return "FFmpeg error: \(firstError)"
            }
            return "FFmpeg failed: \(msg.prefix(200))"
        case .cancelled:
            return "FFmpeg was cancelled"
        case .timeout:
            return "FFmpeg timed out"
        }
    }
}
