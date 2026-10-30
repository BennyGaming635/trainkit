import SwiftUI
import UIKit

struct ControllerView: View {
    @EnvironmentObject private var sbrick: SBrickManager
    @EnvironmentObject private var settings: ControllerSettings
    @State private var showingPairing = false
    @State private var showingSettings = false
    @State private var showingAbout = false
    @State private var throttle = 0.0
    @State private var lightsOn = true
    @State private var activeConsistID: UUID?
    @State private var stopFeedback = 0

    var body: some View {
        List {
            if !settings.consists.isEmpty {
                Section("Consists") {
                    ForEach(settings.consists) { consist in
                        Button {
                            applyThrottle(0)
                            activeConsistID = consist.id
                            sbrick.selectSessions(Set(consist.memberIDs))
                        } label: {
                            HStack {
                                Image(systemName: activeConsistID == consist.id ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(activeConsistID == consist.id ? .blue : .secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(consist.name).foregroundStyle(.primary)
                                    Text(consistSummary(consist))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Section("Locomotives") {
                ForEach(sbrick.sessions) { session in
                    Button {
                        applyThrottle(0)
                        activeConsistID = nil
                        sbrick.toggleSelection(session)
                    } label: {
                        SessionRow(session: session)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Control") {
                if sbrick.selectedReadySessions.isEmpty {
                    ContentUnavailableView(
                        "No Locomotive Selected",
                        systemImage: "train.side.front.car",
                        description: Text("Select a connected locomotive above.")
                    )
                } else {
                    LabeledContent("Power") {
                        Text(powerLabel).monospacedDigit()
                    }
                    Slider(value: Binding(get: { throttle }, set: applyThrottle), in: -1...1, step: 0.01) {
                        Text("Throttle")
                    } minimumValueLabel: {
                        Image(systemName: "backward.fill")
                    } maximumValueLabel: {
                        Image(systemName: "forward.fill")
                    }
                    Button("Stop", systemImage: "stop.fill", role: .destructive) {
                        applyThrottle(0)
                    }
                    if let consist = activeConsist {
                        ForEach(consist.memberIDs, id: \.self) { deviceID in
                            Toggle("\(deviceName(deviceID)) lights", isOn: Binding(
                                get: { activeConsist?.lightsAreEnabled(for: deviceID) ?? true },
                                set: { enabled in
                                    settings.updateConsist(consist.id) { $0.lightsEnabled[deviceID.uuidString] = enabled }
                                    applyThrottle(throttle)
                                }
                            ))
                        }
                    } else {
                        Toggle("Directional lights", isOn: Binding(get: { lightsOn }, set: { value in
                            lightsOn = value
                            applyThrottle(throttle)
                        }))
                    }
                }
            }

            Section {
                Button(role: .destructive) {
                    throttle = 0
                    sbrick.emergencyStop()
                    stopFeedback += 1
                } label: {
                    Label("Emergency Stop All", systemImage: "exclamationmark.octagon.fill")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
            }
        }
        .navigationTitle("TrainKit")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Add SBrick", systemImage: "plus") { showingPairing = true }
                Menu {
                    Button("Profiles", systemImage: "slider.horizontal.3") { showingSettings = true }
                    Button("About TrainKit", systemImage: "info.circle") { showingAbout = true }
                    if !sbrick.sessions.isEmpty {
                        Menu("Disconnect", systemImage: "bolt.slash") {
                            ForEach(sbrick.sessions) { session in
                                Button(settings.displayName(for: session.id, advertisedName: session.name), role: .destructive) {
                                    sbrick.disconnect(session)
                                }
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .sheet(isPresented: $showingPairing) {
            NavigationStack { DeviceBrowserView(isPairingSheet: true) }
                .environmentObject(sbrick)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(sbrick)
        }
        .sheet(isPresented: $showingAbout) {
            AboutView()
                .environmentObject(settings)
                .environmentObject(sbrick)
        }
        .sensoryFeedback(.error, trigger: stopFeedback)
        .onAppear(perform: synchronizeConnectionPolicies)
        .onReceive(settings.$connectionPolicies) { _ in synchronizeConnectionPolicies() }
        .onReceive(sbrick.$sessions) { _ in synchronizeConnectionPolicies() }
        .onReceive(settings.$consists) { consists in
            guard let activeConsistID, let consist = consists.first(where: { $0.id == activeConsistID }) else { return }
            let available = Set(consist.memberIDs).intersection(Set(sbrick.sessions.map(\.id)))
            if sbrick.selectedSessionIDs != available {
                applyThrottle(0)
                sbrick.selectSessions(available)
            }
        }
        .onDisappear { applyThrottle(0) }
    }

    private var powerLabel: String {
        if throttle == 0 { return "Stopped" }
        return "\(Int(abs(throttle) * 100))% \(throttle < 0 ? "reverse" : "forward")"
    }

    private var activeConsist: ConsistProfile? {
        settings.consists.first { $0.id == activeConsistID }
    }

    private func deviceName(_ id: UUID) -> String {
        let advertised = sbrick.session(withID: id)?.name ?? "SBrick"
        return settings.displayName(for: id, advertisedName: advertised)
    }

    private func consistSummary(_ consist: ConsistProfile) -> String {
        let lead = deviceName(consist.masterID)
        let count = consist.slaveIDs.count
        return count == 1 ? "Lead: \(lead) · 1 appended" : "Lead: \(lead) · \(count) appended"
    }

    private func synchronizeConnectionPolicies() {
        for session in sbrick.sessions {
            sbrick.setConnectionLossPolicy(settings.connectionLossPolicy(for: session.id), on: session)
        }
    }

    private func applyThrottle(_ value: Double) {
        throttle = value
        for session in sbrick.selectedReadySessions {
            for port in MotorPort.allCases {
                let configuration = settings.settings(for: port, deviceID: session.id)
                let direction = configuration.isReversed ? -1.0 : 1.0
                let output: Double
                switch configuration.function {
                case .motor:
                    output = value * configuration.maximumPower * direction
                case .forwardLight:
                    output = lightsAreEnabled(for: session.id) && value > 0 ? configuration.maximumPower * direction : 0
                case .reverseLight:
                    output = lightsAreEnabled(for: session.id) && value < 0 ? configuration.maximumPower * direction : 0
                case .unused:
                    output = 0
                }
                sbrick.setSpeed(output, for: port, on: session)
            }
        }
    }

    private func lightsAreEnabled(for deviceID: UUID) -> Bool {
        activeConsist?.lightsAreEnabled(for: deviceID) ?? lightsOn
    }
}

private struct SessionRow: View {
    @EnvironmentObject private var sbrick: SBrickManager
    @EnvironmentObject private var settings: ControllerSettings
    @ObservedObject var session: SBrickSession

    var body: some View {
        HStack(spacing: 12) {
            if let data = settings.assignedProfile(for: session.id)?.photoData,
               let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Image(systemName: sbrick.isSelected(session) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(sbrick.isSelected(session) ? .blue : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.displayName(for: session.id, advertisedName: session.name))
                    .foregroundStyle(.primary)
                Text("\(statusText) · ID \(session.id.uuidString.suffix(4))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let voltage = session.batteryVoltage {
                Text(String(format: "%.1f V", voltage))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Circle().fill(statusColor).frame(width: 8, height: 8)
        }
        .contentShape(Rectangle())
    }

    private var statusText: String {
        switch session.phase {
        case .connecting: "Connecting"
        case .preparing: "Preparing"
        case .ready: "Connected"
        case .disconnecting: "Disconnecting"
        case .failed: "Connection issue"
        }
    }

    private var statusColor: Color {
        switch session.phase {
        case .ready: .green
        case .failed: .orange
        case .disconnecting: .red
        case .connecting, .preparing: .yellow
        }
    }
}
