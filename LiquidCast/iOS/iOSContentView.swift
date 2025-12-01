#if os(iOS)
import SwiftUI
import AVKit

/// iOS-specific content view with sheet presentations
struct iOSContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ContentView()
            .sheet(isPresented: $appState.showingFilePicker) {
                FileBrowserSheet()
            }
    }
}
#endif
