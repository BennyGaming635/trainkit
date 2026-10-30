import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var sbrick: SBrickManager
    @AppStorage("has-seen-whats-new-v2") private var hasSeenWhatsNew = false
    @State private var showingWhatsNew = false

    var body: some View {
        NavigationStack {
            Group {
                if sbrick.sessions.isEmpty {
                    DeviceBrowserView()
                } else {
                    ControllerView()
                }
            }
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
        }
        .tint(.blue)
        .onAppear {
            if !hasSeenWhatsNew { showingWhatsNew = true }
        }
        .onChange(of: hasSeenWhatsNew) { _, seen in
            if !seen { showingWhatsNew = true }
        }
        .fullScreenCover(isPresented: $showingWhatsNew) {
            WhatsNewView {
                hasSeenWhatsNew = true
                showingWhatsNew = false
            }
            .interactiveDismissDisabled()
        }
    }
}
