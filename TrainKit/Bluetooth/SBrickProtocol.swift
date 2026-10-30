import CoreBluetooth
import Foundation

enum SBrickProtocol {
    static let remoteControlService = CBUUID(string: "4DC591B0-857C-41DE-B5F1-15ABDA665B0C")
    static let commandCharacteristic = CBUUID(string: "02B8CBCC-0E25-4BDA-8790-A15F53E6010F")
    static let notificationCharacteristic = CBUUID(string: "489A6AE0-C1AB-4C9C-BDB2-11D373C1B7FB")

    static func driveCommand(speeds: [MotorPort: Int]) -> Data {
        var bytes: [UInt8] = [0x01]

        for port in MotorPort.allCases.sorted(by: { $0.channel < $1.channel }) {
            let speed = min(max(speeds[port] ?? 0, -255), 255)
            bytes.append(port.channel)
            bytes.append(speed < 0 ? 0x01 : 0x00)
            bytes.append(UInt8(abs(speed)))
        }

        return Data(bytes)
    }

    static let brakeAllCommand = Data([0x00, 0x00, 0x01, 0x02, 0x03])

    static func watchdogCommand(tenthsOfASecond: UInt8 = 5) -> Data {
        Data([0x0D, tenthsOfASecond])
    }

    static let batteryQueryCommand = Data([0x0F, 0x08])

    static func batteryVoltage(from notification: Data) -> Double? {
        let bytes = [UInt8](notification)
        var offset = 0

        while offset < bytes.count {
            let length = Int(bytes[offset])
            let recordStart = offset + 1
            let recordEnd = recordStart + length
            guard length > 0, recordEnd <= bytes.count else { return nil }

            let type = bytes[recordStart]
            if type == 0x04, length >= 4, bytes[recordStart + 1] == 0x00 {
                let low = UInt16(bytes[recordStart + 2])
                let high = UInt16(bytes[recordStart + 3]) << 8
                let adc = Double((low | high) >> 4)
                return adc * 0.83875 / 127.0
            }

            if type == 0x06, length >= 3 {
                var measurementOffset = recordStart + 1
                while measurementOffset + 1 < recordEnd {
                    let low = UInt16(bytes[measurementOffset])
                    let high = UInt16(bytes[measurementOffset + 1]) << 8
                    let packed = low | high
                    if packed & 0x0F == 0x08 {
                        let adc = Double(packed >> 4)
                        return adc * 0.83875 / 127.0
                    }
                    measurementOffset += 2
                }
            }

            offset = recordEnd
        }

        return nil
    }

    static func isSBrick(manufacturerData: Data?, name: String?, advertisedServices: [CBUUID]?) -> Bool {
        if name?.localizedCaseInsensitiveContains("SBrick Light") == true {
            return false
        }

        if let data = manufacturerData, isSBrickLight(manufacturerData: data) {
            return false
        }

        if advertisedServices?.contains(remoteControlService) == true {
            return true
        }

        if let data = manufacturerData, data.count >= 2 {
            let bytes = [UInt8](data.prefix(2))
            if bytes == [0x98, 0x01] || bytes == [0x01, 0x98] {
                return true
            }
        }

        return name?.localizedCaseInsensitiveContains("SBrick") == true
    }

    private static func isSBrickLight(manufacturerData: Data) -> Bool {
        let bytes = [UInt8](manufacturerData)
        let hasCompanyIdentifier = bytes.count >= 2 && (
            Array(bytes.prefix(2)) == [0x98, 0x01] || Array(bytes.prefix(2)) == [0x01, 0x98]
        )
        var offset = hasCompanyIdentifier ? 2 : 0

        while offset < bytes.count {
            let length = Int(bytes[offset])
            let recordStart = offset + 1
            let recordEnd = recordStart + length
            guard length > 0, recordEnd <= bytes.count else { return false }

            if length >= 2, bytes[recordStart] == 0x00 {
                return bytes[recordStart + 1] == 0x01
            }
            offset = recordEnd
        }

        return false
    }
}
