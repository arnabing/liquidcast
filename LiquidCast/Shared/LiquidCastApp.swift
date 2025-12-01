import SwiftUI

@main
struct LiquidCastApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        #else
        WindowGroup {
            ContentView()
                .environmentObject(appState)
        }
        #endif
    }
}
