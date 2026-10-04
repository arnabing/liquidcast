import Foundation
import os.log

private let logger = Logger(subsystem: "com.liquidcast", category: "HLSSession")

/// One playback of one source file as an HLS stream.
///
/// The playlist is complete from the start (VOD, see `SegmentPlan`). Segments are produced on
/// demand by FFmpeg "jobs":
/// - a requested segment that already exists is served immediately
/// - one the running job will reach soon is waited for
/// - anything else (a seek) restarts FFmpeg at that segment
///
/// Each job writes its own files (`j<job>_<index>.ts`), so a restart never overwrites a file that
/// may be in flight to the player. FFmpeg is paused while it is far ahead of the viewer, and
/// segments far from the viewer are deleted (they're regenerated if needed), bounding disk use.
actor HLSSession {
    enum SessionError: LocalizedError {
        case notFound
        case stopped
        case superseded
        case timedOut
        case transcodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notFound: return "Segment does not exist"
            case .stopped: return "Stream was stopped"
            case .superseded: return "Request superseded by a seek"
            case .timedOut: return "Timed out waiting for segment"
            case .transcodeFailed(let message): return "Transcoding failed: \(message)"
            }
        }
    }

    /// Restart instead of waiting if the running job is more than this many segments behind the request
    static let maxForwardGap = 4
    /// Pause FFmpeg when it is this many segments ahead of the latest request (~4 min)...
    static let suspendAhead = 40
    /// ...and resume when it is within this many
    static let resumeAhead = 20
    static let requestTimeout: TimeInterval = 60
    /// Stop retrying a start position after this many jobs started there failed without output
    static let maxFailuresPerStart = 3
    /// Keep segments from this many behind the latest request (~3 min, for skipping back)...
    static let keepBehind = 30
    /// ...up to this many ahead of it (covers everything the throttled job writes)
    static let keepAhead = suspendAhead + maxForwardGap + 2

    nonisolated let id: String
    nonisolated let plan: SegmentPlan
    nonisolated let segmentFormat: StreamProfile.SegmentFormat
    /// Complete VOD media playlist (immutable for the session)
    nonisolated let mediaPlaylist: String
    /// Multivariant playlist pointing at `mediaPlaylistName` (fMP4/HEVC streams, which need CODECS
    /// and VIDEO-RANGE declared); nil when the media playlist is served directly
    nonisolated let masterPlaylist: String?
    nonisolated static let mediaPlaylistName = "media.m3u8"
    nonisolated static let initSegmentName = "init.mp4"

    /// What the player is given first
    nonisolated var entryPlaylist: String { masterPlaylist ?? mediaPlaylist }

    private let source: URL
    private let sourceStartTime: Double
    private let profile: StreamProfile
    private let ffmpegPath: String
    private let directory: URL
    private let initialIndex: Int

    private final class Job {
        let id: Int
        let startIndex: Int
        let process = FFmpegProcess()
        let filePrefix: String
        let listURL: URL
        /// Bytes of the segment list already consumed
        var listOffset = 0
        /// Next segment this job will write
        var nextIndex: Int
        var isSuspended = false

        init(id: Int, startIndex: Int, directory: URL) {
            self.id = id
            self.startIndex = startIndex
            self.filePrefix = "j\(id)_"
            self.listURL = directory.appendingPathComponent("j\(id).csv")
            self.nextIndex = startIndex
        }
    }

    private var job: Job?
    private var nextJobId = 0
    private var segments: [Int: URL] = [:]
    private var waiters: [Int: [UUID: CheckedContinuation<URL, Error>]] = [:]
    private var lastRequestedIndex: Int
    /// Jobs that failed without output, by start index
    private var failuresAt: [Int: Int] = [:]
    private var lastFailure: String?
    /// Segments from here on can't be produced: a job ran into the end of the video first
    /// (container duration can exceed the video's)
    private var producibleEnd: Int
    private var monitorTask: Task<Void, Never>?
    private var isStopped = false
    /// fMP4: the shared init segment, cut from the first segment file
    private var initSegmentData: Data?

    /// - Parameter variant: fMP4 only: describes the stream for the multivariant playlist
    init(
        source: URL,
        sourceStartTime: Double,
        plan: SegmentPlan,
        profile: StreamProfile,
        variant: HLSVariant?,
        ffmpegPath: String,
        rootDirectory: URL,
        startTime: Double
    ) {
        let id = UUID().uuidString.lowercased()
        self.id = id
        self.plan = plan
        self.segmentFormat = profile.segmentFormat
        let isFMP4 = profile.segmentFormat == .fmp4
        self.mediaPlaylist = plan.playlist(
            startTime: startTime,
            segmentExtension: profile.segmentFormat.urlExtension,
            initURI: isFMP4 ? Self.initSegmentName : nil
        )
        self.masterPlaylist = isFMP4 ? variant?.masterPlaylist(mediaURI: Self.mediaPlaylistName) : nil
        self.source = source
        self.sourceStartTime = sourceStartTime
        self.profile = profile
        self.ffmpegPath = ffmpegPath
        self.directory = rootDirectory.appendingPathComponent(id, isDirectory: true)
        self.initialIndex = plan.index(containing: startTime)
        self.lastRequestedIndex = initialIndex
        self.producibleEnd = plan.count
    }

    /// Create the working directory and start encoding where playback will begin
    /// On failure the caller must still call `stop()` (it deletes the directory).
    func start() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        logger.info("[\(self.id.prefix(8))] Session: \(self.plan.count) segments, \(Int(self.plan.duration))s, starting at segment \(self.initialIndex)")
        try await startJob(at: initialIndex)

        monitorTask = Task { [weak self] in
            while let self, await self.tick() {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Kill FFmpeg, fail pending requests, delete all segments
    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        monitorTask?.cancel()
        if let job {
            await job.process.forceKill()
        }
        job = nil
        failAllWaiters(SessionError.stopped)
        try? FileManager.default.removeItem(at: directory)
        logger.info("[\(self.id.prefix(8))] Session stopped")
    }

    /// File for segment `index`, produced on demand. Waits up to `requestTimeout`.
    func segment(_ index: Int) async throws -> URL {
        guard !isStopped else { throw SessionError.stopped }
        guard index >= 0 && index < plan.count else { throw SessionError.notFound }

        lastRequestedIndex = index
        if let url = segments[index] { return url }
        guard index < producibleEnd else { throw SessionError.notFound }

        if !isCovered(index) {
            guard failuresAt[index, default: 0] < Self.maxFailuresPerStart else {
                throw SessionError.transcodeFailed(lastFailure ?? "unknown error")
            }
            try await startJob(at: index)
        }
        if let url = segments[index] { return url }  // May have landed while awaiting
        return try await waitForSegment(index)
    }

    /// fMP4 init segment (`ftyp`+`moov`). Every segment file starts with the same one, so it's taken
    /// from whichever segment exists first, waiting for the running job's next one if none does yet.
    /// Doesn't count as a request (no effect on throttling/eviction), and survives a seek replacing
    /// the job while it waits.
    func initSegment() async throws -> Data {
        guard segmentFormat == .fmp4 else { throw SessionError.notFound }

        for _ in 0..<5 {
            if let initSegmentData { return initSegmentData }
            if let file = segments.values.first {
                // No await between picking the file and reading it, so eviction can't delete it in between
                guard let data = MP4Segment.initSection(of: try Data(contentsOf: file, options: .alwaysMapped)) else {
                    throw SessionError.transcodeFailed("Segment has no init section")
                }
                initSegmentData = data
                return data
            }
            guard !isStopped else { throw SessionError.stopped }
            if let job, job.nextIndex < producibleEnd {
                do {
                    _ = try await waitForSegment(job.nextIndex)
                } catch SessionError.superseded {
                    continue  // A seek replaced the job; wait for the new one's first segment
                }
            } else {
                guard producibleEnd > 0 else { throw SessionError.notFound }
                try await startJob(at: min(lastRequestedIndex, producibleEnd - 1))
            }
        }
        throw SessionError.timedOut
    }

    /// Whether the running job will produce `index` soon
    private func isCovered(_ index: Int) -> Bool {
        guard let job else { return false }
        return index >= job.startIndex && index <= job.nextIndex + Self.maxForwardGap
    }

    // MARK: - Jobs

    private func startJob(at index: Int) async throws {
        let previous = job
        let newJob = Job(id: nextJobId, startIndex: index, directory: directory)
        nextJobId += 1
        // Publish before any await, so concurrent requests see the new job instead of starting another
        job = newJob

        if let previous {
            await previous.process.forceKill()
            removeUnlistedFiles(of: previous)
            logger.info("[\(self.id.prefix(8))] Restarting at segment \(index) (job \(previous.id) was at \(previous.nextIndex))")
        }

        // Requests the new job won't serve were for a position the player has left
        for waitingIndex in Array(waiters.keys) where !isCovered(waitingIndex) {
            failWaiters(for: waitingIndex, SessionError.superseded)
        }

        do {
            let (seek, landing) = try await findSeek(for: index)
            // A newer request may have replaced this job while probing
            guard job === newJob, !isStopped else { throw SessionError.superseded }

            let arguments = profile.arguments(
                input: source,
                plan: plan,
                startIndex: index,
                seek: seek,
                landing: landing,
                outputDirectory: directory,
                filePrefix: newJob.filePrefix,
                segmentListURL: newJob.listURL
            )
            try await newJob.process.start(ffmpegPath: ffmpegPath, arguments: arguments)
        } catch let error as SessionError {
            throw error
        } catch {
            // Probe or launch failed: nothing will serve this job's requests
            failuresAt[index, default: 0] += 1
            lastFailure = error.localizedDescription
            if job === newJob {
                job = nil
                failAllWaiters(SessionError.transcodeFailed(error.localizedDescription))
            }
            throw SessionError.transcodeFailed(error.localizedDescription)
        }
    }

    /// Seek position for a job starting at `index`, and where the demuxer actually lands for it.
    /// The landing must be before the boundary so the job cuts it inside the stream (see
    /// `StreamProfile`). Demuxers may land after the seek point (MPEG-TS seeks forward to the next
    /// keyframe), so back off until it does.
    private func findSeek(for index: Int) async throws -> (seek: Double, landing: Double) {
        let boundary = plan.start(of: index)
        var seek = profile.seekPosition(for: index, plan: plan)
        var backoff = 2.0
        while true {
            let landing = try await KeyframeIndex.seekLanding(
                for: source,
                seek: seek,
                videoStreamIndex: profile.videoStreamIndex,
                startTime: sourceStartTime,
                ffmpegPath: ffmpegPath
            )
            if index == 0 || landing < boundary - 0.01 || seek == 0 {
                return (seek, landing)
            }
            logger.info("[\(self.id.prefix(8))] Seek to \(seek)s lands at \(landing)s (boundary \(boundary)s) - seeking earlier")
            seek = max(0, seek - backoff)
            backoff *= 2
        }
    }

    /// Periodic work: pick up finished segments, detect exit, throttle. Returns false once stopped.
    private func tick() async -> Bool {
        guard !isStopped else { return false }
        guard let job else { return true }

        readSegmentList(of: job)

        let finished = await job.process.hasFinished
        guard self.job === job, !isStopped else { return !isStopped }  // Replaced while awaiting

        if finished {
            readSegmentList(of: job)  // Entries written right before exit
            let failure = await job.process.failureReason
            guard self.job === job, !isStopped else { return !isStopped }  // Replaced while awaiting
            handleJobExit(job, failure: failure)
        } else {
            await throttle(job)
        }
        evictDistantSegments()
        return true
    }

    /// Called with `job` still current and no awaits, so waiters registered for a newer job can't be hit
    private func handleJobExit(_ job: Job, failure: String?) {
        self.job = nil
        let produced = job.nextIndex > job.startIndex

        if let failure {
            if !produced {
                failuresAt[job.startIndex, default: 0] += 1
            }
            lastFailure = failure.split(separator: "\n").last.map(String.init) ?? failure
            logger.error("[\(self.id.prefix(8))] Job \(job.id) failed at segment \(job.nextIndex): \(self.lastFailure ?? "")")
            // Requests it was going to serve: fail them so the player can retry (which restarts a job)
            for index in Array(waiters.keys) where index >= job.startIndex {
                failWaiters(for: index, SessionError.transcodeFailed(lastFailure ?? "unknown error"))
            }
        } else {
            // A clean exit is the end of the video. If that's before the plan's end, the rest
            // can never be produced - say so instead of restarting at it forever.
            if job.nextIndex < producibleEnd {
                producibleEnd = job.nextIndex
                logger.warning("[\(self.id.prefix(8))] Video ends at segment \(job.nextIndex) of \(self.plan.count)")
            }
            logger.info("[\(self.id.prefix(8))] Job \(job.id) reached the end (segments \(job.startIndex)..<\(job.nextIndex))")
            for index in Array(waiters.keys) where index >= job.startIndex && segments[index] == nil {
                failWaiters(for: index, SessionError.notFound)
            }
        }
    }

    /// Delete segments far from the viewer; they're regenerated if the player comes back
    private func evictDistantSegments() {
        let keep = (lastRequestedIndex - Self.keepBehind)...(lastRequestedIndex + Self.keepAhead)
        for (index, url) in segments where !keep.contains(index) {
            try? FileManager.default.removeItem(at: url)  // A reader with the file mapped keeps its data
            segments[index] = nil
        }
    }

    private func throttle(_ job: Job) async {
        let ahead = job.nextIndex - lastRequestedIndex
        if !job.isSuspended && ahead > Self.suspendAhead {
            job.isSuspended = true
            await job.process.suspend()
            logger.info("[\(self.id.prefix(8))] Paused FFmpeg (\(ahead) segments ahead)")
        } else if job.isSuspended && ahead < Self.resumeAhead {
            job.isSuspended = false
            await job.process.resume()
            logger.info("[\(self.id.prefix(8))] Resumed FFmpeg")
        }
    }

    // MARK: - Segment list

    /// Consume new complete lines of the job's CSV segment list (`file,start,end`).
    /// FFmpeg appends a line only after the segment file is fully written.
    private func readSegmentList(of job: Job) {
        guard let data = try? Data(contentsOf: job.listURL), data.count > job.listOffset else { return }
        let newBytes = data[job.listOffset...]
        guard let lastNewline = newBytes.lastIndex(of: UInt8(ascii: "\n")) else { return }
        job.listOffset = lastNewline + 1

        let text = String(decoding: data[newBytes.startIndex...lastNewline], as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let fileName = line.split(separator: ",").first,
                  fileName.hasPrefix(job.filePrefix),
                  let index = Int(fileName.dropFirst(job.filePrefix.count).prefix(while: \.isNumber)) else {
                continue
            }
            let url = directory.appendingPathComponent(String(fileName))
            guard index >= job.startIndex else {
                try? FileManager.default.removeItem(at: url)  // Copy pre-roll before the job's first boundary
                continue
            }
            if let old = segments[index], old != url {
                try? FileManager.default.removeItem(at: old)  // Mapped readers keep their data
            }
            segments[index] = url
            job.nextIndex = max(job.nextIndex, index + 1)
            resumeWaiters(for: index, with: url)
        }
    }

    /// Delete a killed job's partially written segment (never listed, never served)
    private func removeUnlistedFiles(of job: Job) {
        let served = Set(segments.values.map(\.lastPathComponent))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for file in files where file.hasPrefix(job.filePrefix) && file.hasSuffix("." + segmentFormat.fileExtension)
            && !served.contains(file) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }
    }

    // MARK: - Waiters

    private func waitForSegment(_ index: Int) async throws -> URL {
        let waiterId = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[index, default: [:]][waiterId] = continuation
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(Self.requestTimeout * 1_000_000_000))
                    await self?.failWaiter(index: index, id: waiterId, SessionError.timedOut)
                }
            }
        } onCancel: {
            Task { [weak self] in await self?.failWaiter(index: index, id: waiterId, CancellationError()) }
        }
    }

    private func resumeWaiters(for index: Int, with url: URL) {
        guard let pending = waiters.removeValue(forKey: index) else { return }
        for continuation in pending.values {
            continuation.resume(returning: url)
        }
    }

    private func failWaiter(index: Int, id: UUID, _ error: Error) {
        guard let continuation = waiters[index]?.removeValue(forKey: id) else { return }
        if waiters[index]?.isEmpty == true { waiters[index] = nil }
        continuation.resume(throwing: error)
    }

    private func failWaiters(for index: Int, _ error: Error) {
        guard let pending = waiters.removeValue(forKey: index) else { return }
        for continuation in pending.values {
            continuation.resume(throwing: error)
        }
    }

    private func failAllWaiters(_ error: Error) {
        for index in Array(waiters.keys) {
            failWaiters(for: index, error)
        }
    }
}

/// Thread-safe lookup of the session the HTTP server should route to
final class HLSSessionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: HLSSession] = [:]

    func register(_ session: HLSSession) { lock.withLock { sessions[session.id] = session } }
    func remove(_ session: HLSSession) { lock.withLock { _ = sessions.removeValue(forKey: session.id) } }
    func session(id: String) -> HLSSession? { lock.withLock { sessions[id] } }
}
