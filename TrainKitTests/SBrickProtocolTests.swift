import XCTest
@testable import TrainKit

final class SBrickProtocolTests: XCTestCase {
    func testDriveCommandUsesPhysicalSBrickPortMapping() {
        let command = SBrickProtocol.driveCommand(speeds: [
            .a: 255,
            .b: -128,
            .c: 64,
            .d: 0
        ])

        XCTAssertEqual([UInt8](command), [
            0x01,
            0x00, 0x00, 0xFF,
            0x01, 0x00, 0x40,
            0x02, 0x01, 0x80,
            0x03, 0x00, 0x00
        ])
    }

    func testDriveCommandClampsOutOfRangePower() {
        let command = SBrickProtocol.driveCommand(speeds: [.a: 900, .b: -900])
        let bytes = [UInt8](command)

        XCTAssertEqual(bytes[3], 255)
        XCTAssertEqual(bytes[9], 255)
    }

    func testBatteryVoltageParsesCommandResponseRecord() throws {
        let adc: UInt16 = 1_200
        let packed = adc << 4 | 0x08
        let notification = Data([0x04, 0x04, 0x00, UInt8(packed & 0xFF), UInt8(packed >> 8)])

        let voltage = try XCTUnwrap(SBrickProtocol.batteryVoltage(from: notification))
        XCTAssertEqual(voltage, Double(adc) * 0.83875 / 127.0, accuracy: 0.001)
    }

    func testBatteryVoltageParsesMeasurementRecord() throws {
        let adc: UInt16 = 1_000
        let packed = adc << 4 | 0x08
        let notification = Data([0x03, 0x06, UInt8(packed & 0xFF), UInt8(packed >> 8)])

        XCTAssertNotNil(SBrickProtocol.batteryVoltage(from: notification))
    }

    func testMalformedNotificationIsIgnored() {
        XCTAssertNil(SBrickProtocol.batteryVoltage(from: Data([0x08, 0x04, 0x00])))
    }

    func testZeroWatchdogTimeoutDisablesConnectionLossStop() {
        XCTAssertEqual(SBrickProtocol.watchdogCommand(tenthsOfASecond: 0), Data([0x0D, 0x00]))
    }

    func testSBrickLightIsNotPresentedAsMotorController() {
        let manufacturerData = Data([
            0x98, 0x01,
            0x06, 0x00, 0x01, 0x01, 0x00, 0x01, 0x00
        ])

        XCTAssertFalse(SBrickProtocol.isSBrick(
            manufacturerData: manufacturerData,
            name: "Renamed hub",
            advertisedServices: [SBrickProtocol.remoteControlService]
        ))
    }
}
