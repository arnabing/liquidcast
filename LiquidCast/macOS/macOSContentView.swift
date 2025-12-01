#if os(macOS)
import SwiftUI

/// macOS-specific content view with sheet presentations
struct macOSContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ContentView()
            .sheet(isPresented: $appState.showingWindowPicker) {
                WindowPickerView()
                    .environmentObject(appState)
            }
    }
}
#endif
