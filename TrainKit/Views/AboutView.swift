import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sbrick: SBrickManager
    @EnvironmentObject private var settings: ControllerSettings
    @AppStorage("has-seen-whats-new-v2") private var hasSeenWhatsNew = true
    @State private var showingResetConfirmation = false

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image("AboutAppIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 128, height: 128)
                            .clipShape(RoundedRectangle(cornerRadius: 28))
                            .accessibilityLabel("TrainKit app icon")
                            .onTapGesture(count: 3) { showingResetConfirmation = true }
                        Text("TrainKit").font(.title.bold())
                        Text("Simple control for SBrick-powered trains.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                Section("Version") {
                    LabeledContent("Version", value: version)
                    LabeledContent("Build", value: build)
                }

                Section("Acknowledgements") {
                    Text("Built with SwiftUI and Core Bluetooth using Apple development tools.")
                    Text("SBrick communication uses the publicly documented SBrick Bluetooth Low Energy protocol.")
                }

                Section("Legal") {
                    Text("TrainKit is an independent app and is not endorsed by, owned by, affiliated with, or otherwise linked to SBrick or its owners.")
                    Text("Copyright © 2026 Damrob Pty Ltd. All rights reserved.")
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Reset TrainKit?", isPresented: $showingResetConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive, action: resetApp)
            } message: {
                Text("This removes all names, profiles, port settings, and connection preferences, then disconnects every SBrick.")
            }
        }
    }

    private func resetApp() {
        sbrick.emergencyStop()
        for session in sbrick.sessions {
            sbrick.disconnect(session)
        }
        settings.resetAll()
        hasSeenWhatsNew = false
        dismiss()
    }
}
