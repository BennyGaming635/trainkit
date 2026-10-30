import SwiftUI

struct DeviceBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var sbrick: SBrickManager
    @State private var showingAbout = false
    var isPairingSheet = false

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                        .font(.title2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(statusTitle)
                        Text(statusDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if sbrick.isScanning { ProgressView() }
                }

                Button(sbrick.isScanning ? "Stop Scanning" : "Scan", systemImage: sbrick.isScanning ? "stop.fill" : "arrow.clockwise", action: scanAction)
                    .disabled(!sbrick.canScan)
            }

            Section("Nearby") {
                if sbrick.devices.isEmpty {
                    Text(sbrick.isScanning ? "Searching…" : "No SBricks found")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sbrick.devices) { device in
                        deviceRow(device)
                    }
                }
            }
        }
        .navigationTitle(isPairingSheet ? "Add SBrick" : "TrainKit")
        .toolbar {
            if isPairingSheet {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            } else {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("About", systemImage: "info.circle") { showingAbout = true }
                }
            }
        }
        .sheet(isPresented: $showingAbout) { AboutView() }
        .onAppear {
            if sbrick.canScan, !sbrick.isScanning {
                sbrick.startScanning(clearResults: sbrick.devices.isEmpty)
            }
        }
        .onDisappear { sbrick.stopScanning() }
    }

    private func deviceRow(_ device: DiscoveredSBrick) -> some View {
        let paired = sbrick.isPaired(device)
        return Button {
            if !paired { sbrick.connect(to: device) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: paired ? "checkmark.circle.fill" : "shippingbox")
                    .foregroundStyle(paired ? .green : .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).foregroundStyle(.primary)
                    Text(paired ? "Connected" : signalDescription(device.rssi))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if !paired { Text("Connect").foregroundStyle(.blue) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(paired)
    }

    private func scanAction() {
        sbrick.isScanning ? sbrick.stopScanning() : sbrick.startScanning(clearResults: true)
    }

    private var statusTitle: String {
        switch sbrick.state {
        case .bluetoothOff: "Bluetooth is Off"
        case .unauthorized: "Bluetooth Access Denied"
        case .idle: "Ready"
        case .scanning: "Scanning"
        case .failed: "Bluetooth Error"
        }
    }

    private var statusDetail: String {
        switch sbrick.state {
        case .bluetoothOff: "Turn on Bluetooth to connect."
        case .unauthorized: "Allow Bluetooth access in Settings."
        case .idle: "Scan for nearby SBricks."
        case .scanning: "Keep each SBrick powered on."
        case let .failed(message): message
        }
    }

    private var statusSymbol: String {
        switch sbrick.state {
        case .bluetoothOff, .unauthorized, .failed: "exclamationmark.triangle.fill"
        case .scanning: "dot.radiowaves.left.and.right"
        case .idle: "antenna.radiowaves.left.and.right"
        }
    }

    private var statusColor: Color {
        switch sbrick.state {
        case .bluetoothOff, .unauthorized, .failed: .orange
        default: .blue
        }
    }

    private func signalDescription(_ rssi: Int) -> String {
        switch rssi {
        case (-55)...: "Excellent signal"
        case -70 ..< -55: "Good signal"
        case -85 ..< -70: "Fair signal"
        default: "Weak signal"
        }
    }
}
