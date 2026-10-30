import XCTest
@testable import TrainKit

final class ControllerSettingsTests: XCTestCase {
    func testMirroredFleetKeepsOneSharedControlLayout() throws {
        let suiteName = "ControllerSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = ControllerSettings(defaults: defaults)

        settings.update(.a) {
            $0.name = "Main engine"
            $0.controlStyle = .dial
        }
        XCTAssertEqual(settings.settings(for: .a).controlStyle, .dial)

        let reloaded = ControllerSettings(defaults: defaults)
        XCTAssertEqual(reloaded.settings(for: .a).name, "Main engine")
    }

    func testOldPortSettingsDefaultToSlider() throws {
        let data = try XCTUnwrap("""
        {
          "name": "Legacy motor",
          "maximumPower": 0.8,
          "isReversed": false
        }
        """.data(using: .utf8))

        let decoded = try JSONDecoder().decode(PortSettings.self, from: data)
        XCTAssertEqual(decoded.controlStyle, .slider)
        XCTAssertEqual(decoded.function, .motor)
    }

    func testPortFunctionSupportsBothLightDirectionsAndLegacyValues() throws {
        let legacy = try JSONDecoder().decode(
            PortFunction.self,
            from: Data("\"forwardLight\"".utf8)
        )
        XCTAssertEqual(legacy, .forwardLight)

        let combined: PortFunction = [.forwardLight, .reverseLight]
        let data = try JSONEncoder().encode(combined)
        XCTAssertEqual(try JSONDecoder().decode(PortFunction.self, from: data), combined)
    }

    func testDeviceProfilesKeepIndependentPortAssignments() throws {
        let suiteName = "ControllerSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ControllerSettings(defaults: defaults)
        let freight = UUID()
        let passenger = UUID()

        settings.update(.b, deviceID: freight) { $0.function = .motor; $0.isReversed = true }
        settings.update(.b, deviceID: passenger) { $0.function = .forwardLight }

        XCTAssertEqual(settings.settings(for: .b, deviceID: freight).function, .motor)
        XCTAssertTrue(settings.settings(for: .b, deviceID: freight).isReversed)
        XCTAssertEqual(settings.settings(for: .b, deviceID: passenger).function, .forwardLight)
    }

    func testPortCanBeAssignedToBothLightDirections() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ControllerSettingsTests.\(UUID().uuidString)"))
        let settings = ControllerSettings(defaults: defaults)
        let id = UUID()

        settings.update(.b, deviceID: id) { $0.function = .forwardLight }
        settings.update(.b, deviceID: id) { $0.function.insert(.reverseLight) }

        XCTAssertEqual(settings.settings(for: .b, deviceID: id).function, [.forwardLight, .reverseLight])
    }

    func testDeviceAliasPersistsByStableIdentifier() throws {
        let suiteName = "ControllerSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let id = UUID()
        ControllerSettings(defaults: defaults).setDisplayName("Blue freight", for: id)

        XCTAssertEqual(ControllerSettings(defaults: defaults).displayName(for: id, advertisedName: "SBrick"), "Blue freight")
    }

    func testConnectionLossPolicyDefaultsSafeAndPersists() throws {
        let suiteName = "ControllerSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let id = UUID()
        let settings = ControllerSettings(defaults: defaults)
        XCTAssertEqual(settings.connectionLossPolicy(for: id), .emergencyStop)

        settings.setConnectionLossPolicy(.continueRunning, for: id)
        XCTAssertEqual(ControllerSettings(defaults: defaults).connectionLossPolicy(for: id), .continueRunning)
    }

    func testPortPresetAppliesCompleteLayout() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ControllerSettingsTests.\(UUID().uuidString)"))
        let settings = ControllerSettings(defaults: defaults)
        let id = UUID()

        settings.apply(.dualMotorAndLights, to: id)

        XCTAssertEqual(settings.settings(for: .a, deviceID: id).function, .motor)
        XCTAssertEqual(settings.settings(for: .b, deviceID: id).function, .motor)
        XCTAssertEqual(settings.settings(for: .c, deviceID: id).function, .forwardLight)
        XCTAssertEqual(settings.settings(for: .d, deviceID: id).function, .reverseLight)
    }

    func testResetAllClearsDeviceProfileAndName() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ControllerSettingsTests.\(UUID().uuidString)"))
        let settings = ControllerSettings(defaults: defaults)
        let id = UUID()
        settings.setDisplayName("Freight", for: id)
        settings.apply(.motorAndLights, to: id)

        settings.resetAll()

        XCTAssertEqual(settings.displayName(for: id, advertisedName: "SBrick"), "SBrick")
        XCTAssertEqual(settings.settings(for: .b, deviceID: id).function, .motor)
    }

    func testConsistPersistsLeadSlavesAndLightPreferences() throws {
        let suiteName = "ControllerSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = ControllerSettings(defaults: defaults)
        let lead = UUID()
        let firstSlave = UUID()
        let secondSlave = UUID()
        let id = settings.createConsist(masterID: lead, slaveIDs: [firstSlave, secondSlave])

        settings.updateConsist(id) {
            $0.name = "Freight Pair"
            $0.lightsEnabled[firstSlave.uuidString] = false
        }

        let reloaded = ControllerSettings(defaults: defaults)
        let consist = try XCTUnwrap(reloaded.consists.first)
        XCTAssertEqual(consist.name, "Freight Pair")
        XCTAssertEqual(consist.memberIDs, [lead, firstSlave, secondSlave])
        XCTAssertTrue(consist.lightsAreEnabled(for: lead))
        XCTAssertFalse(consist.lightsAreEnabled(for: firstSlave))
    }

    func testChangingConsistLeadKeepsOldLeadAsSlave() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ControllerSettingsTests.\(UUID().uuidString)"))
        let settings = ControllerSettings(defaults: defaults)
        let oldLead = UUID()
        let newLead = UUID()
        let id = settings.createConsist(masterID: oldLead, slaveIDs: [newLead])

        settings.updateConsist(id) {
            $0.masterID = newLead
            $0.slaveIDs.removeAll { $0 == newLead }
            $0.slaveIDs.insert(oldLead, at: 0)
        }

        XCTAssertEqual(settings.consists.first?.memberIDs, [newLead, oldLead])
    }

    func testNamedProfileCanBeSharedAndPersistsPhoto() throws {
        let suiteName = "ControllerSettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let firstSBrick = UUID()
        let secondSBrick = UUID()
        let settings = ControllerSettings(defaults: defaults)
        settings.update(.b, deviceID: firstSBrick) { $0.function = .forwardLight }
        settings.update(.c, deviceID: firstSBrick) { $0.function = .forwardLight }

        let profileID = settings.saveCurrentSettingsAsProfile(named: "Red Passenger", for: firstSBrick)
        settings.updateProfile(profileID) { $0.photoData = Data([1, 2, 3]) }
        settings.assignProfile(profileID, to: secondSBrick)

        let reloaded = ControllerSettings(defaults: defaults)
        XCTAssertEqual(reloaded.assignedProfile(for: secondSBrick)?.name, "Red Passenger")
        XCTAssertEqual(reloaded.assignedProfile(for: secondSBrick)?.photoData, Data([1, 2, 3]))
        XCTAssertEqual(reloaded.settings(for: .b, deviceID: secondSBrick).function, .forwardLight)
        XCTAssertEqual(reloaded.settings(for: .c, deviceID: secondSBrick).function, .forwardLight)
    }

    func testDeletingNamedProfileReturnsDeviceToOwnSettings() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "ControllerSettingsTests.\(UUID().uuidString)"))
        let settings = ControllerSettings(defaults: defaults)
        let id = UUID()
        settings.update(.a, deviceID: id) { $0.function = .unused }
        let profileID = settings.saveCurrentSettingsAsProfile(named: "Temporary", for: id)

        settings.deleteProfile(profileID)

        XCTAssertNil(settings.assignedProfile(for: id))
        XCTAssertEqual(settings.settings(for: .a, deviceID: id).function, .unused)
    }
}
