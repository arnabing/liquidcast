import Foundation
import os.log

private let logger = Logger(subsystem: "com.liquidcast", category: "FFmpegProcess")

/// One FFmpeg subprocess.
///
/// Never blocks: exit is reported via `terminationHandler`, so `forceKill()` / `suspend()` take
/// effect immediately even while FFmpeg is mid-transcode. (Calling `waitUntilExit()` inside the
/// actor would block it, and every later call - including kill - until FFmpeg finished on its own.)
actor FFmpegProcess {
    enum State: Equatable {
        case idle
        case running
        case completed
        case failed(error: String)
        case cancelled
    }

    private(set) var state: State = .idle
    private var process: Process?
    private var errorOutput = ""
    private let processId = UUID().uuidString.prefix(8)

    var isRunning: Bool { state == .running }

    /// Non-nil once FFmpeg exited with an error (not when killed on request)
    var failureReason: String? {
        if case .failed(let error) = state { return error }
        return nil
    }

    var hasFinished: Bool {
        switch state {
        case .idle, .running: return false
        case .completed, .failed, .cancelled: return true
        }
    }

    func start(ffmpegPath: String, arguments: [String]) throws {
        if state == .cancelled { throw FFmpegProcessError.cancelled }  // Killed before it started
        guard state == .idle else { throw FFmpegProcessError.alreadyStarted }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpegPath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errorPipe = Pipe()
        process.standardError = errorPipe

        // Drain stderr continuously (a full pipe would stall FFmpeg); keep the tail for error messages
        let errorHandle = errorPipe.fileHandleForReading
        Task.detached { [weak self] in
            var buffer = ""
            do {
                for try await line in errorHandle.bytes.lines {
                    buffer += line + "\n"
                    if buffer.count > 4000 {
                        buffer = String(buffer.suffix(2000))
                    }
                }
            } catch {}
            await self?.setErrorOutput(buffer)
        }

        process.terminationHandler = { [weak self] proc in
            let status = proc.terminationStatus
            let reason = proc.terminationReason
            let pid = proc.processIdentifier
            RunningProcesses.shared.remove(pid)
            Task { await self?.handleExit(status: status, reason: reason, pid: pid) }
        }

        try process.run()
        self.process = process
        state = .running
        RunningProcesses.shared.insert(process.processIdentifier)
        logger.info("[\(self.processId)] FFmpeg started (pid \(process.processIdentifier)): \(arguments.joined(separator: " ").prefix(300))")
    }

    /// Kill immediately (SIGKILL) and wait briefly until the process is gone, so it can't write
    /// any more files after this returns.
    func forceKill() async {
        if state == .idle || state == .running { state = .cancelled }  // Idle: make a later start() refuse
        guard let process else { return }
        guard process.isRunning else { return }

        kill(process.processIdentifier, SIGKILL)
        logger.info("[\(self.processId)] FFmpeg killed (pid \(process.processIdentifier))")

        for _ in 0..<100 where process.isRunning {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// Pause encoding (SIGSTOP) - used to stop running far ahead of the viewer
    func suspend() {
        guard state == .running, let process else { return }
        kill(process.processIdentifier, SIGSTOP)  // Not Process.suspend(): that's a Mach task suspend
    }

    /// Continue after `suspend()`
    func resume() {
        guard state == .running, let process else { return }
        kill(process.processIdentifier, SIGCONT)
    }

    private func handleExit(status: Int32, reason: Process.TerminationReason, pid: Int32) {
        // Again here: a very fast exit can fire the handler before start() registered the pid
        RunningProcesses.shared.remove(pid)
        if state == .cancelled { return }  // Killed on request - not a failure

        if reason == .exit && status == 0 {
            state = .completed
            logger.info("[\(self.processId)] FFmpeg completed")
        } else {
            state = .failed(error: errorOutput)
            logger.error("[\(self.processId)] FFmpeg failed (status \(status)): \(self.errorOutput.suffix(500))")
        }
    }

    private func setErrorOutput(_ output: String) {
        errorOutput = output
        if case .failed = state {
            state = .failed(error: output)  // stderr may finish draining after the exit was reported
        }
    }

    /// Synchronously SIGKILL every FFmpeg this app started. For app termination: child processes
    /// are not killed when the parent exits, and would otherwise keep transcoding in the background.
    nonisolated static func killAll() {
        for pid in RunningProcesses.shared.all() {
            kill(pid, SIGKILL)
        }
    }
}

/// PIDs of live FFmpeg processes (thread-safe, readable without hopping onto any actor)
private final class RunningProcesses: @unchecked Sendable {
    static let shared = RunningProcesses()
    private let lock = NSLock()
    private var pids = Set<Int32>()

    func insert(_ pid: Int32) { lock.withLock { _ = pids.insert(pid) } }
    func remove(_ pid: Int32) { lock.withLock { _ = pids.remove(pid) } }
    func all() -> [Int32] { lock.withLock { Array(pids) } }
}

enum FFmpegProcessError: LocalizedError {
    case alreadyStarted
    case cancelled

    var errorDescription: String? {
        switch self {
        case .alreadyStarted: return "FFmpeg process already started"
        case .cancelled: return "FFmpeg was stopped before it started"
        }
    }
}
