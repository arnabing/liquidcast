#if os(macOS)
import Foundation
import ScreenCaptureKit
import AVFoundation
import VideoToolbox
import Combine

/// Manages screen/window capture with H.265 encoding for AirPlay streaming
@MainActor
class ScreenCaptureManager: NSObject, ObservableObject {
    // MARK: - Published Properties

    @Published var availableWindows: [SCWindow] = []
    @Published var availableDisplays: [SCDisplay] = []
    @Published var selectedWindow: SCWindow?
    @Published var selectedDisplay: SCDisplay?
    @Published var isCapturing: Bool = false
    @Published var captureError: Error?

    // MARK: - Private Properties

    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?

    // H.265 Encoding
    private var compressionSession: VTCompressionSession?
    private var encodingQueue = DispatchQueue(label: "com.liquidcast.encoding", qos: .userInteractive)

    // Quality settings
    private let targetBitrate: Int = 50_000_000  // 50 Mbps
    private let frameRate: Float = 60.0

    // MARK: - Initialization

    override init() {
        super.init()
    }

    // MARK: - Content Discovery

    func refreshAvailableContent() async throws {
        // Check for screen recording permission
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw CaptureError.permissionDenied
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        availableWindows = content.windows.filter { window in
            // Filter out system windows and tiny windows
            guard let app = window.owningApplication else { return false }
            guard window.frame.width > 100 && window.frame.height > 100 else { return false }
            guard app.bundleIdentifier != "com.apple.dock" else { return false }
            guard app.bundleIdentifier != "com.apple.WindowManager" else { return false }
            return true
        }.sorted { ($0.owningApplication?.applicationName ?? "") < ($1.owningApplication?.applicationName ?? "") }

        availableDisplays = content.displays
    }

    // MARK: - Capture Control

    func startCapture(window: SCWindow) async throws {
        selectedWindow = window

        // Create content filter for the window
        let filter = SCContentFilter(desktopIndependentWindow: window)

        // Configure stream
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width) * 2  // Retina
        config.height = Int(window.frame.height) * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true

        // macOS 14+ features
        if #available(macOS 14.0, *) {
            config.captureResolution = .best
            config.presenterOverlayPrivacyAlertSetting = .never
        }

        // Setup encoding session
        try setupEncodingSession(width: config.width, height: config.height)

        // Create stream output handler
        streamOutput = CaptureStreamOutput { [weak self] sampleBuffer in
            self?.processCapturedFrame(sampleBuffer)
        }

        // Create and start stream
        stream = SCStream(filter: filter, configuration: config, delegate: nil)

        guard let stream = stream, let output = streamOutput else {
            throw CaptureError.streamCreationFailed
        }

        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: encodingQueue)
        try await stream.startCapture()

        isCapturing = true
    }

    func startCapture(display: SCDisplay) async throws {
        selectedDisplay = display

        let filter = SCContentFilter(
            display: display,
            excludingWindows: []
        )

        let config = SCStreamConfiguration()
        config.width = Int(display.width) * 2
        config.height = Int(display.height) * 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true

        try setupEncodingSession(width: config.width, height: config.height)

        streamOutput = CaptureStreamOutput { [weak self] sampleBuffer in
            self?.processCapturedFrame(sampleBuffer)
        }

        stream = SCStream(filter: filter, configuration: config, delegate: nil)

        guard let stream = stream, let output = streamOutput else {
            throw CaptureError.streamCreationFailed
        }

        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: encodingQueue)
        try await stream.startCapture()

        isCapturing = true
    }

    func stopCapture() async {
        do {
            try await stream?.stopCapture()
        } catch {
            print("Error stopping capture: \(error)")
        }

        stream = nil
        streamOutput = nil
        isCapturing = false

        if let session = compressionSession {
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }

    // MARK: - H.265 Encoding Setup

    private func setupEncodingSession(width: Int, height: Int) throws {
        var session: VTCompressionSession?

        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_HEVC,  // H.265
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            throw CaptureError.encoderCreationFailed
        }

        // Configure for highest quality
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                            value: kVTProfileLevel_HEVC_Main10_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                            value: targetBitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality,
                            value: 1.0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime,
                            value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                            value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                            value: frameRate as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)

        compressionSession = session
    }

    // MARK: - Frame Processing

    private func processCapturedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let session = compressionSession else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTime,
            duration: .invalid,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
    }
}

// MARK: - Stream Output Handler

class CaptureStreamOutput: NSObject, SCStreamOutput {
    let handler: (CMSampleBuffer) -> Void

    init(handler: @escaping (CMSampleBuffer) -> Void) {
        self.handler = handler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        handler(sampleBuffer)
    }
}

// MARK: - Errors

enum CaptureError: LocalizedError {
    case permissionDenied
    case streamCreationFailed
    case encoderCreationFailed
    case noWindowSelected

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen recording permission required. Please enable in System Preferences > Privacy & Security > Screen Recording."
        case .streamCreationFailed:
            return "Failed to create capture stream."
        case .encoderCreationFailed:
            return "Failed to create H.265 encoder."
        case .noWindowSelected:
            return "No window selected for capture."
        }
    }
}
#endif
