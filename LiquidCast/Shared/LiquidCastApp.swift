import SwiftUI

@main
struct LiquidCastApp: App {
    @StateObject private var appState = AppState()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            MiniPlayerView()
                .environmentObject(appState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 320, height: 120)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        // Menu bar extra with play/pause status
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(appState)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.isPlaying ? "play.fill" : "pause.fill")
                if appState.isConnectedToAirPlay {
                    Image(systemName: "airplayaudio")
                }
            }
        }
        .menuBarExtraStyle(.menu)
        #else
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        #endif
    }
}

#if os(macOS)
class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

// MARK: - Menu Bar Content
struct MenuBarContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        // Now Playing info
        if let url = appState.selectedMediaURL {
            Text(url.deletingPathExtension().lastPathComponent)
                .lineLimit(1)
            Divider()
        }

        // Playback controls
        Button(appState.isPlaying ? "Pause" : "Play") {
            appState.togglePlayback()
        }
        .keyboardShortcut(" ", modifiers: [])
        .disabled(appState.selectedMediaURL == nil)

        Button("Skip Back 10s") {
            appState.seek(to: max(appState.playbackProgress - 10, 0))
        }
        .keyboardShortcut(.leftArrow, modifiers: [])
        .disabled(appState.selectedMediaURL == nil)

        Button("Skip Forward 30s") {
            appState.seek(to: min(appState.playbackProgress + 30, appState.duration))
        }
        .keyboardShortcut(.rightArrow, modifiers: [])
        .disabled(appState.selectedMediaURL == nil)

        Divider()

        // File operations
        Button("Open File...") {
            appState.showingFilePicker = true
        }
        .keyboardShortcut("o", modifiers: .command)

        Divider()

        // AirPlay status
        if let device = appState.currentAirPlayDevice {
            Label(device, systemImage: "airplayaudio")
        } else {
            Text("No AirPlay device")
                .foregroundColor(.secondary)
        }

        Divider()

        Button("Quit LiquidCast") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
#endif
