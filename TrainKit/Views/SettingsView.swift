import PhotosUI
import SwiftUI
import UIKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: ControllerSettings
    @EnvironmentObject private var sbrick: SBrickManager
    @State private var testing: TestTarget?

    var body: some View {
        NavigationStack {
            Form {
                Section("Consists") {
                    ForEach(settings.consists) { consist in
                        NavigationLink {
                            ConsistEditorView(consistID: consist.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(consist.name)
                                Text("1 lead · \(consist.slaveIDs.count) appended")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Button("New Consist", systemImage: "plus", action: createConsist)
                        .disabled(sbrick.sessions.count < 2)
                }

                ForEach(sbrick.sessions) { session in
                    Section {
                        TextField("SBrick name", text: Binding(
                            get: { settings.displayName(for: session.id, advertisedName: session.name) },
                            set: { settings.setDisplayName($0, for: session.id) }
                        ))
                        NavigationLink {
                            LocomotiveProfileView(session: session)
                        } label: {
                            LabeledContent(
                                "Saved profile",
                                value: settings.assignedProfile(for: session.id)?.name ?? "Device settings"
                            )
                        }
                        LabeledContent("SBrick ID", value: session.id.uuidString)
                            .font(.caption.monospaced())
                        Menu("Apply port preset", systemImage: "square.grid.2x2") {
                            ForEach(PortConfigurationPreset.allCases) { preset in
                                Button {
                                    sbrick.emergencyStop()
                                    settings.apply(preset, to: session.id)
                                } label: {
                                    VStack(alignment: .leading) {
                                        Text(preset.title)
                                        Text(preset.detail)
                                    }
                                }
                            }
                        }
                        Picker("If connection is lost", selection: Binding(
                            get: { settings.connectionLossPolicy(for: session.id) },
                            set: { policy in
                                sbrick.emergencyStop()
                                settings.setConnectionLossPolicy(policy, for: session.id)
                                sbrick.setConnectionLossPolicy(policy, on: session)
                            }
                        )) {
                            ForEach(ConnectionLossPolicy.allCases) { policy in
                                Text(policy.title).tag(policy)
                            }
                        }
                        if settings.connectionLossPolicy(for: session.id) == .continueRunning {
                            Label("The SBrick watchdog is disabled. A lost phone connection cannot stop this locomotive until TrainKit reconnects or power is removed.", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                        NavigationLink {
                            LightOutputSetupView(session: session)
                        } label: {
                            LabeledContent("Directional light outputs", value: lightPortSummary(session: session))
                        }
                        ForEach(MotorPort.allCases) { port in
                            NavigationLink {
                                PortSetupView(session: session, port: port, testing: $testing)
                            } label: {
                                let configuration = settings.settings(for: port, deviceID: session.id)
                                Label("Port \(port.rawValue): \(configuration.function.title)", systemImage: configuration.function.symbol)
                            }
                        }
                    } header: {
                        Text(settings.displayName(for: session.id, advertisedName: session.name))
                    }
                }

                Section("Connection safety") {
                    LabeledContent("Default", value: "Stop in 0.5 s")
                    LabeledContent("Reconnect", value: "Automatic")
                    Text("Keep last output disables the watchdog. The app cannot stop a disconnected locomotive.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Profiles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onDisappear { stopTest() }
        }
    }

    private func stopTest() {
        guard let testing, let session = sbrick.session(withID: testing.sessionID) else { return }
        sbrick.stop(testing.port, on: session)
        self.testing = nil
    }

    private func createConsist() {
        let selected = sbrick.sessions.filter { sbrick.isSelected($0) }
        let members = selected.count >= 2 ? selected : sbrick.sessions
        guard let master = members.first else { return }
        settings.createConsist(masterID: master.id, slaveIDs: members.dropFirst().map(\.id))
    }

    private func lightPortSummary(session: SBrickSession) -> String {
        let ports = MotorPort.allCases.filter {
            let function = settings.settings(for: $0, deviceID: session.id).function
            return function.contains(.forwardLight) || function.contains(.reverseLight)
        }
        return ports.isEmpty ? "None" : ports.map(\.rawValue).joined(separator: ", ")
    }
}

private struct LocomotiveProfileView: View {
    @EnvironmentObject private var settings: ControllerSettings
    @ObservedObject var session: SBrickSession
    @State private var newProfileName = ""
    @State private var selectedPhoto: PhotosPickerItem?

    private var assignedProfile: LocomotiveProfile? {
        settings.assignedProfile(for: session.id)
    }

    var body: some View {
        Form {
            Section("Assignment") {
                Menu {
                    Button {
                        settings.assignProfile(nil, to: session.id)
                    } label: {
                        if assignedProfile == nil { Label("Device settings", systemImage: "checkmark") }
                        else { Text("Device settings") }
                    }
                    ForEach(settings.locomotiveProfiles) { profile in
                        Button {
                            settings.assignProfile(profile.id, to: session.id)
                        } label: {
                            if assignedProfile?.id == profile.id { Label(profile.name, systemImage: "checkmark") }
                            else { Text(profile.name) }
                        }
                    }
                } label: {
                    LabeledContent("Profile", value: assignedProfile?.name ?? "Device settings")
                }
            }

            if let profile = assignedProfile {
                Section("Profile") {
                    TextField("Profile name", text: Binding(
                        get: { assignedProfile?.name ?? "" },
                        set: { name in settings.updateProfile(profile.id) { $0.name = name } }
                    ))
                    profilePhoto(profile)
                    PhotosPicker(selection: $selectedPhoto, matching: .images) {
                        Label(profile.photoData == nil ? "Add locomotive photo" : "Change locomotive photo", systemImage: "photo")
                    }
                    if profile.photoData != nil {
                        Button("Remove Photo", role: .destructive) {
                            settings.updateProfile(profile.id) { $0.photoData = nil }
                        }
                    }
                }

                Section {
                    Button("Delete Profile", role: .destructive) {
                        settings.deleteProfile(profile.id)
                    }
                } footer: {
                    Text("Deleting a profile returns every SBrick using it to its own device settings.")
                }
            } else {
                Section {
                    TextField("Profile name", text: $newProfileName)
                    Button("Create Named Profile", systemImage: "square.and.arrow.down") {
                        settings.saveCurrentSettingsAsProfile(
                            named: newProfileName.isEmpty ? settings.displayName(for: session.id, advertisedName: session.name) : newProfileName,
                            for: session.id
                        )
                        newProfileName = ""
                    }
                } header: {
                    Text("Save these settings")
                } footer: {
                    Text("Named profiles can be applied to another SBrick later.")
                }
            }
        }
        .navigationTitle(assignedProfile?.name ?? "Saved Profile")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedPhoto) { _, item in
            guard let profileID = assignedProfile?.id, let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data),
                      let thumbnail = image.preparingThumbnail(of: CGSize(width: 1200, height: 1200)),
                      let compressed = thumbnail.jpegData(compressionQuality: 0.82) else { return }
                await MainActor.run {
                    settings.updateProfile(profileID) { $0.photoData = compressed }
                    selectedPhoto = nil
                }
            }
        }
    }

    @ViewBuilder
    private func profilePhoto(_ profile: LocomotiveProfile) -> some View {
        if let data = profile.photoData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct LightOutputSetupView: View {
    @EnvironmentObject private var settings: ControllerSettings
    @EnvironmentObject private var sbrick: SBrickManager
    @ObservedObject var session: SBrickSession

    var body: some View {
        Form {
            ForEach(MotorPort.allCases) { port in
                Section("Port \(port.rawValue)") {
                    lightControls("Forward", function: .forwardLight, port: port)
                    lightControls("Reverse", function: .reverseLight, port: port)
                }
            }
            Section {
                Text("Each port can be used in both directions with a different polarity, so one two-wire light output can show white at one end and red at the other.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Light Outputs")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func lightControls(_ title: String, function: PortFunction, port: MotorPort) -> some View {
        let selected = settings.settings(for: port, deviceID: session.id).function.contains(function)
        Toggle(title, isOn: Binding(
            get: { settings.settings(for: port, deviceID: session.id).function.contains(function) },
            set: { enabled in
                sbrick.emergencyStop()
                settings.update(port, deviceID: session.id) { configuration in
                    configuration.function.remove(.motor)
                    if enabled { configuration.function.insert(function) }
                    else { configuration.function.remove(function) }
                }
            }
        ))
        if selected {
            Picker("\(title) polarity", selection: polarityBinding(function, port: port)) {
                ForEach(OutputPolarity.allCases) { polarity in
                    Text(polarity.title).tag(polarity)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func polarityBinding(_ function: PortFunction, port: MotorPort) -> Binding<OutputPolarity> {
        Binding(
            get: {
                let configuration = settings.settings(for: port, deviceID: session.id)
                return function == .forwardLight ? configuration.forwardLightPolarity : configuration.reverseLightPolarity
            },
            set: { polarity in
                sbrick.emergencyStop()
                settings.update(port, deviceID: session.id) { configuration in
                    if function == .forwardLight { configuration.forwardLightPolarity = polarity }
                    else { configuration.reverseLightPolarity = polarity }
                }
            }
        )
    }
}

private struct ConsistEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: ControllerSettings
    @EnvironmentObject private var sbrick: SBrickManager
    let consistID: UUID

    private var consist: ConsistProfile? { settings.consists.first { $0.id == consistID } }

    var body: some View {
        Form {
            if let consist {
                Section("Profile") {
                    TextField("Consist name", text: Binding(
                        get: { self.consist?.name ?? "" },
                        set: { name in settings.updateConsist(consistID) { $0.name = name } }
                    ))
                    Picker("Lead locomotive", selection: Binding(
                        get: { self.consist?.masterID ?? consist.masterID },
                        set: { newMaster in
                            settings.updateConsist(consistID) { profile in
                                let oldMaster = profile.masterID
                                profile.masterID = newMaster
                                profile.slaveIDs.removeAll { $0 == newMaster }
                                if oldMaster != newMaster { profile.slaveIDs.insert(oldMaster, at: 0) }
                            }
                        }
                    )) {
                        ForEach(sbrick.sessions) { session in
                            Text(name(for: session.id)).tag(session.id)
                        }
                    }
                }

                Section("Appended locomotives") {
                    ForEach(sbrick.sessions.filter { $0.id != consist.masterID }) { session in
                        Toggle(name(for: session.id), isOn: Binding(
                            get: { self.consist?.slaveIDs.contains(session.id) ?? false },
                            set: { included in
                                settings.updateConsist(consistID) { profile in
                                    if included {
                                        if !profile.slaveIDs.contains(session.id) { profile.slaveIDs.append(session.id) }
                                    } else {
                                        profile.slaveIDs.removeAll { $0 == session.id }
                                    }
                                }
                            }
                        ))
                    }
                }

                Section("Lights") {
                    ForEach(consist.memberIDs, id: \.self) { deviceID in
                        Toggle(name(for: deviceID), isOn: Binding(
                            get: { self.consist?.lightsAreEnabled(for: deviceID) ?? true },
                            set: { enabled in
                                settings.updateConsist(consistID) { $0.lightsEnabled[deviceID.uuidString] = enabled }
                            }
                        ))
                    }
                }

                Section {
                    Button("Delete Consist", role: .destructive) {
                        settings.deleteConsist(consistID)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(consist?.name ?? "Consist")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func name(for id: UUID) -> String {
        let advertised = sbrick.session(withID: id)?.name ?? "SBrick"
        return settings.displayName(for: id, advertisedName: advertised)
    }
}

private struct TestTarget: Equatable {
    let sessionID: UUID
    let port: MotorPort
}

private struct PortSetupView: View {
    @EnvironmentObject private var settings: ControllerSettings
    @EnvironmentObject private var sbrick: SBrickManager
    @ObservedObject var session: SBrickSession
    let port: MotorPort
    @Binding var testing: TestTarget?

    private var configuration: PortSettings { settings.settings(for: port, deviceID: session.id) }

    var body: some View {
        Form {
            Section("Assignment") {
                Toggle("Motor", isOn: functionBinding(.motor))
                Toggle("Forward light", isOn: functionBinding(.forwardLight))
                if configuration.function.contains(.forwardLight) {
                    Picker("Forward polarity", selection: binding(\.forwardLightPolarity)) {
                        ForEach(OutputPolarity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Toggle("Reverse light", isOn: functionBinding(.reverseLight))
                if configuration.function.contains(.reverseLight) {
                    Picker("Reverse polarity", selection: binding(\.reverseLightPolarity)) {
                        ForEach(OutputPolarity.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                TextField("Port name", text: binding(\.name))
                if configuration.function.contains(.motor) {
                    Toggle("Reverse motor", isOn: binding(\.isReversed))
                }
                VStack(alignment: .leading) {
                    LabeledContent("Maximum output", value: "\(Int(configuration.maximumPower * 100))%")
                    Slider(value: binding(\.maximumPower), in: 0.1...1, step: 0.05)
                }
            }

            Section("Port test") {
                Text("Hold to run this port at 25% power.")
                    .font(.footnote).foregroundStyle(.secondary)
                HStack {
                    testButton("Reverse", value: -0.25)
                    testButton("Forward", value: 0.25)
                }
                .disabled(!session.phase.isReady)
            }
        }
        .navigationTitle("Port \(port.rawValue)")
        .onDisappear { stopTest() }
    }

    private func binding<Value>(_ path: WritableKeyPath<PortSettings, Value>) -> Binding<Value> {
        Binding(get: { configuration[keyPath: path] }, set: { value in
            stopTest()
            settings.update(port, deviceID: session.id) { $0[keyPath: path] = value }
        })
    }

    private func functionBinding(_ function: PortFunction) -> Binding<Bool> {
        Binding(
            get: { configuration.function.contains(function) },
            set: { enabled in
                stopTest()
                settings.update(port, deviceID: session.id) { value in
                    if enabled {
                        if function == .motor { value.function = .motor }
                        else {
                            value.function.remove(.motor)
                            value.function.insert(function)
                        }
                    } else {
                        value.function.remove(function)
                    }
                }
            }
        )
    }

    private func testButton(_ title: String, value: Double) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Color.accentColor.opacity(testing == TestTarget(sessionID: session.id, port: port) ? 0.35 : 0.12), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
                let target = TestTarget(sessionID: session.id, port: port)
                guard testing != target else { return }
                sbrick.emergencyStop()
                testing = target
                let direction = configuration.isReversed ? -1.0 : 1.0
                sbrick.setSpeed(value * direction, for: port, on: session)
            }.onEnded { _ in stopTest() })
    }

    private func stopTest() {
        guard testing == TestTarget(sessionID: session.id, port: port) else { return }
        sbrick.stop(port, on: session)
        testing = nil
    }
}
