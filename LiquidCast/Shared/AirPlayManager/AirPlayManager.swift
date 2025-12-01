import AVFoundation
import AVKit
import Combine

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
        setupRouteDetection()
    }

    // MARK: - Setup

    private func setupRouteDetection() {
        // Enable route detection
        routeDetector.isRouteDetectionEnabled = true

        // Observe multiple routes available
        routeDetector.publisher(for: \.multipleRoutesDetected)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] detected in
                self?.isAirPlayAvailable = detected
            }
            .store(in: &cancellables)

        // Check current audio session route for AirPlay status
        checkCurrentRoute()

        // Listen for route changes
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.checkCurrentRoute()
            }
            .store(in: &cancellables)
    }

    private func checkCurrentRoute() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let currentRoute = session.currentRoute

        // Check if any output is AirPlay
        let airPlayOutput = currentRoute.outputs.first { output in
            output.portType == .airPlay
        }

        if let airPlay = airPlayOutput {
            isConnected = true
            connectedDeviceName = airPlay.portName
        } else {
            isConnected = false
            connectedDeviceName = nil
        }
        #else
        // macOS handles this differently through AVPlayer's externalPlaybackActive
        #endif
    }

    // MARK: - Public Methods

    func updateConnectionStatus(isActive: Bool, deviceName: String?) {
        isConnected = isActive
        connectedDeviceName = deviceName
    }
}
