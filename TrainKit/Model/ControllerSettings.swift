import Combine
import Foundation

struct ConsistProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var masterID: UUID
    var slaveIDs: [UUID]
    var lightsEnabled: [String: Bool]

    var memberIDs: [UUID] { [masterID] + slaveIDs.filter { $0 != masterID } }

    func lightsAreEnabled(for deviceID: UUID) -> Bool {
        lightsEnabled[deviceID.uuidString] ?? true
    }
}

struct LocomotiveProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var ports: [MotorPort: PortSettings]
    var photoData: Data?
}

private struct LocomotiveProfileLibrary: Codable {
    var profiles: [LocomotiveProfile]
    var assignments: [String: UUID]
}

final class ControllerSettings: ObservableObject {
    @Published private(set) var profiles: [String: [MotorPort: PortSettings]]
    @Published private(set) var deviceNames: [String: String]
    @Published private(set) var connectionPolicies: [String: ConnectionLossPolicy]
    @Published private(set) var consists: [ConsistProfile]
    @Published private(set) var locomotiveProfiles: [LocomotiveProfile]
    @Published private(set) var assignedProfileIDs: [String: UUID]

    private let defaults: UserDefaults
    private let storageKey = "controller.device-port-settings.v2"
    private let legacyStorageKey = "controller.port-settings.v1"
    private let defaultProfileKey = "default"
    private let mirroredProfileKey = "mirrored-fleet"
    private let namesStorageKey = "controller.device-names.v1"
    private let policiesStorageKey = "controller.connection-loss-policies.v1"
    private let consistsStorageKey = "controller.consists.v1"
    private let locomotiveProfilesStorageKey = "controller.locomotive-profiles.v1"
    private let profileAssignmentsStorageKey = "controller.profile-assignments.v1"
    private let profileLibraryStorageKey = "controller.locomotive-profile-library.v2"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: [MotorPort: PortSettings]].self, from: data) {
            profiles = decoded
        } else if let data = defaults.data(forKey: legacyStorageKey),
                  let legacy = try? JSONDecoder().decode([MotorPort: PortSettings].self, from: data) {
            profiles = [defaultProfileKey: legacy]
        } else {
            profiles = [defaultProfileKey: Self.standardProfile()]
        }
        deviceNames = defaults.dictionary(forKey: namesStorageKey) as? [String: String] ?? [:]
        if let data = defaults.data(forKey: policiesStorageKey),
           let decoded = try? JSONDecoder().decode([String: ConnectionLossPolicy].self, from: data) {
            connectionPolicies = decoded
        } else {
            connectionPolicies = [:]
        }
        if let data = defaults.data(forKey: consistsStorageKey),
           let decoded = try? JSONDecoder().decode([ConsistProfile].self, from: data) {
            consists = decoded
        } else {
            consists = []
        }
        if let data = defaults.data(forKey: profileLibraryStorageKey),
           let library = try? JSONDecoder().decode(LocomotiveProfileLibrary.self, from: data) {
            locomotiveProfiles = library.profiles
            assignedProfileIDs = library.assignments
        } else if let data = defaults.data(forKey: locomotiveProfilesStorageKey),
           let decoded = try? JSONDecoder().decode([LocomotiveProfile].self, from: data) {
            locomotiveProfiles = decoded
            if let data = defaults.data(forKey: profileAssignmentsStorageKey),
               let decoded = try? JSONDecoder().decode([String: UUID].self, from: data) {
                assignedProfileIDs = decoded
            } else {
                assignedProfileIDs = [:]
            }
        } else {
            locomotiveProfiles = []
            assignedProfileIDs = [:]
        }
    }

    func settings(for port: MotorPort) -> PortSettings {
        profiles[mirroredProfileKey]?[port]
            ?? profiles[defaultProfileKey]?[port]
            ?? .standard(for: port)
    }

    func settings(for port: MotorPort, deviceID: UUID) -> PortSettings {
        if let profile = assignedProfile(for: deviceID) {
            return profile.ports[port] ?? .standard(for: port)
        }
        return profiles[deviceID.uuidString]?[port] ?? settings(for: port)
    }

    func assignedProfile(for deviceID: UUID) -> LocomotiveProfile? {
        guard let profileID = assignedProfileIDs[deviceID.uuidString] else { return nil }
        return locomotiveProfiles.first { $0.id == profileID }
    }

    @discardableResult
    func saveCurrentSettingsAsProfile(named name: String, for deviceID: UUID) -> UUID {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = LocomotiveProfile(
            id: UUID(),
            name: trimmedName.isEmpty ? "Locomotive" : trimmedName,
            ports: Dictionary(uniqueKeysWithValues: MotorPort.allCases.map {
                ($0, settings(for: $0, deviceID: deviceID))
            }),
            photoData: nil
        )
        locomotiveProfiles.append(profile)
        assignedProfileIDs[deviceID.uuidString] = profile.id
        persistLocomotiveProfiles()
        return profile.id
    }

    func assignProfile(_ profileID: UUID?, to deviceID: UUID) {
        if let profileID, locomotiveProfiles.contains(where: { $0.id == profileID }) {
            assignedProfileIDs[deviceID.uuidString] = profileID
        } else {
            assignedProfileIDs.removeValue(forKey: deviceID.uuidString)
        }
        persistLocomotiveProfiles()
    }

    func updateProfile(_ id: UUID, _ change: (inout LocomotiveProfile) -> Void) {
        guard let index = locomotiveProfiles.firstIndex(where: { $0.id == id }) else { return }
        change(&locomotiveProfiles[index])
        persistLocomotiveProfiles()
    }

    func deleteProfile(_ id: UUID) {
        locomotiveProfiles.removeAll { $0.id == id }
        assignedProfileIDs = assignedProfileIDs.filter { $0.value != id }
        persistLocomotiveProfiles()
    }

    func displayName(for deviceID: UUID, advertisedName: String) -> String {
        let value = deviceNames[deviceID.uuidString]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? advertisedName : value
    }

    func setDisplayName(_ name: String, for deviceID: UUID) {
        deviceNames[deviceID.uuidString] = name
        defaults.set(deviceNames, forKey: namesStorageKey)
    }

    func connectionLossPolicy(for deviceID: UUID) -> ConnectionLossPolicy {
        connectionPolicies[deviceID.uuidString] ?? .emergencyStop
    }

    func setConnectionLossPolicy(_ policy: ConnectionLossPolicy, for deviceID: UUID) {
        connectionPolicies[deviceID.uuidString] = policy
        if let data = try? JSONEncoder().encode(connectionPolicies) {
            defaults.set(data, forKey: policiesStorageKey)
        }
    }

    func update(_ port: MotorPort, deviceID: UUID, _ change: (inout PortSettings) -> Void) {
        if let profileID = assignedProfileIDs[deviceID.uuidString],
           let index = locomotiveProfiles.firstIndex(where: { $0.id == profileID }) {
            var value = locomotiveProfiles[index].ports[port] ?? .standard(for: port)
            change(&value)
            value.maximumPower = min(max(value.maximumPower, 0.1), 1)
            locomotiveProfiles[index].ports[port] = value
            persistLocomotiveProfiles()
            return
        }
        var profile = profiles[deviceID.uuidString] ?? profiles[mirroredProfileKey] ?? profiles[defaultProfileKey] ?? Self.standardProfile()
        var value = profile[port] ?? .standard(for: port)
        change(&value)
        value.maximumPower = min(max(value.maximumPower, 0.1), 1)
        profile[port] = value
        profiles[deviceID.uuidString] = profile
        persist()
    }

    func apply(_ preset: PortConfigurationPreset, to deviceID: UUID) {
        let portSettings = Dictionary(uniqueKeysWithValues: MotorPort.allCases.map { port in
            (port, preset.settings(for: port))
        })
        if let profileID = assignedProfileIDs[deviceID.uuidString],
           let index = locomotiveProfiles.firstIndex(where: { $0.id == profileID }) {
            locomotiveProfiles[index].ports = portSettings
            persistLocomotiveProfiles()
            return
        }
        profiles[deviceID.uuidString] = portSettings
        persist()
    }

    @discardableResult
    func createConsist(masterID: UUID, slaveIDs: [UUID]) -> UUID {
        let id = UUID()
        consists.append(ConsistProfile(
            id: id,
            name: "New Consist",
            masterID: masterID,
            slaveIDs: slaveIDs.filter { $0 != masterID },
            lightsEnabled: [:]
        ))
        persistConsists()
        return id
    }

    func updateConsist(_ id: UUID, _ change: (inout ConsistProfile) -> Void) {
        guard let index = consists.firstIndex(where: { $0.id == id }) else { return }
        change(&consists[index])
        var seen: Set<UUID> = []
        let masterID = consists[index].masterID
        consists[index].slaveIDs = consists[index].slaveIDs.filter {
            $0 != masterID && seen.insert($0).inserted
        }
        persistConsists()
    }

    func deleteConsist(_ id: UUID) {
        consists.removeAll { $0.id == id }
        persistConsists()
    }

    func update(_ port: MotorPort, _ change: (inout PortSettings) -> Void) {
        var profile = profiles[mirroredProfileKey] ?? profiles[defaultProfileKey] ?? Self.standardProfile()
        var value = profile[port] ?? .standard(for: port)
        change(&value)
        value.maximumPower = min(max(value.maximumPower, 0.1), 1)
        profile[port] = value
        profiles[mirroredProfileKey] = profile
        persist()
    }

    func reset() {
        profiles[mirroredProfileKey] = Self.standardProfile()
        persist()
    }

    func resetAll() {
        profiles = [defaultProfileKey: Self.standardProfile()]
        deviceNames = [:]
        connectionPolicies = [:]
        consists = []
        locomotiveProfiles = []
        assignedProfileIDs = [:]
        defaults.removeObject(forKey: storageKey)
        defaults.removeObject(forKey: legacyStorageKey)
        defaults.removeObject(forKey: namesStorageKey)
        defaults.removeObject(forKey: policiesStorageKey)
        defaults.removeObject(forKey: consistsStorageKey)
        defaults.removeObject(forKey: locomotiveProfilesStorageKey)
        defaults.removeObject(forKey: profileAssignmentsStorageKey)
        defaults.removeObject(forKey: profileLibraryStorageKey)
    }

    private static func standardProfile() -> [MotorPort: PortSettings] {
        Dictionary(uniqueKeysWithValues: MotorPort.allCases.map { ($0, .standard(for: $0)) })
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: storageKey)
    }

    private func persistConsists() {
        guard let data = try? JSONEncoder().encode(consists) else { return }
        defaults.set(data, forKey: consistsStorageKey)
    }

    private func persistLocomotiveProfiles() {
        let library = LocomotiveProfileLibrary(
            profiles: locomotiveProfiles,
            assignments: assignedProfileIDs
        )
        if let data = try? JSONEncoder().encode(library) {
            defaults.set(data, forKey: profileLibraryStorageKey)
        }
        // Keep the previous keys in sync so an older installed build can still read the library.
        if let data = try? JSONEncoder().encode(locomotiveProfiles) {
            defaults.set(data, forKey: locomotiveProfilesStorageKey)
        }
        if let data = try? JSONEncoder().encode(assignedProfileIDs) {
            defaults.set(data, forKey: profileAssignmentsStorageKey)
        }
    }
}
