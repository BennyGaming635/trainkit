import SwiftUI

@main
struct TrainKitApp: App {
    @StateObject private var sbrick = SBrickManager()
    @StateObject private var settings = ControllerSettings()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sbrick)
                .environmentObject(settings)
        }
    }
}
