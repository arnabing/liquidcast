import AVFoundation
import AVKit
import Combine
import os.log

private let airplayLogger = Logger(subsystem: "com.liquidcast", category: "AirPlay")

/// Manages AirPlay device selection and connection state
class AirPlayManager: ObservableObject {
    // MARK: - Published Properties

    @Published private(set) var isAirPlayAvailable: Bool = false
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var isConnected: Bool = false

    // MARK: - Private Properties

    private let routeDetector = AVRouteDetector()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init() {
        airplayLogger.info("🔊 AirPlayManager initializing...")
        setupRouteDetection()
    }

    // MARK: - Setup

    private func setupRouteDetection() {
        // Enable route detection
        routeDetector.isRouteDetectionEnabled = true
        airplayLogger.info("🔍 Route detection enabled")

        // Observe multiple routes available
        routeDetector.publisher(for: \.multipleRoutesDetected)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] detected in
                airplayLogger.info("🔍 Multiple routes detected: \(detected)")
                self?.isAirPlayAvailable = detected
            }
            .store(in: &cancellables)

        // Check current audio session route for AirPlay status
        checkCurrentRoute()

        #if os(iOS)
        // Listen for route changes (iOS only - AVAudioSession not available on macOS)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt {
                    airplayLogger.info("🔀 Route change notification - reason: \(reason)")
                }
                self?.checkCurrentRoute()
            }
            .store(in: &cancellables)
        #endif
    }

    private func checkCurrentRoute() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let currentRoute = session.currentRoute

        airplayLogger.info("🔊 Checking current route - outputs: \(currentRoute.outputs.count)")
        for output in currentRoute.outputs {
            airplayLogger.info("🔊 Output: \(output.portName) type: \(output.portType.rawValue)")
        }

        // Check if any output is AirPlay
        let airPlayOutput = currentRoute.outputs.first { output in
            output.portType == .airPlay
        }

        if let airPlay = airPlayOutput {
            airplayLogger.info("✅ AirPlay connected: \(airPlay.portName)")
            isConnected = true
            connectedDeviceName = airPlay.portName
        } else {
            airplayLogger.info("❌ No AirPlay output found")
            isConnected = false
            connectedDeviceName = nil
        }
        #else
        // macOS handles this differently through AVPlayer's externalPlaybackActive
        airplayLogger.info("🖥️ macOS: checking route via AVPlayer externalPlaybackActive")
        #endif
    }

    // MARK: - Public Methods

    func updateConnectionStatus(isActive: Bool, deviceName: String?) {
        airplayLogger.info("📺 Connection status update - active: \(isActive), device: \(deviceName ?? "nil")")
        isConnected = isActive
        connectedDeviceName = deviceName
    }
}
