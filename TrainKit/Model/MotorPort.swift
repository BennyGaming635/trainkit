import Foundation

enum MotorPort: String, CaseIterable, Codable, Identifiable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"

    var id: String { rawValue }

    // SBrick's printed B and C labels do not follow the numeric channel order.
    var channel: UInt8 {
        switch self {
        case .a: 0
        case .b: 2
        case .c: 1
        case .d: 3
        }
    }

    var colorName: String {
        switch self {
        case .a: "SignalBlue"
        case .b: "SignalAmber"
        case .c: "SignalGreen"
        case .d: "SignalPurple"
        }
    }
}

struct PortSettings: Codable, Equatable {
    var name: String
    var maximumPower: Double
    var isReversed: Bool
    var controlStyle: PortControlStyle
    var function: PortFunction

    init(name: String, maximumPower: Double, isReversed: Bool, controlStyle: PortControlStyle, function: PortFunction = .motor) {
        self.name = name
        self.maximumPower = maximumPower
        self.isReversed = isReversed
        self.controlStyle = controlStyle
        self.function = function
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        maximumPower = try container.decode(Double.self, forKey: .maximumPower)
        isReversed = try container.decode(Bool.self, forKey: .isReversed)
        controlStyle = try container.decodeIfPresent(PortControlStyle.self, forKey: .controlStyle) ?? .slider
        function = try container.decodeIfPresent(PortFunction.self, forKey: .function) ?? .motor
    }

    static func standard(for port: MotorPort) -> PortSettings {
        PortSettings(name: "Motor \(port.rawValue)", maximumPower: 1, isReversed: false, controlStyle: .slider)
    }
}

enum PortFunction: String, CaseIterable, Codable, Identifiable {
    case motor
    case forwardLight
    case reverseLight
    case unused

    var id: String { rawValue }

    var title: String {
        switch self {
        case .motor: "Motor"
        case .forwardLight: "Forward light"
        case .reverseLight: "Reverse light"
        case .unused: "Unused"
        }
    }

    var symbol: String {
        switch self {
        case .motor: "gearshape.2.fill"
        case .forwardLight: "light.beacon.max.fill"
        case .reverseLight: "light.beacon.min.fill"
        case .unused: "minus.circle"
        }
    }
}

enum ConnectionLossPolicy: String, CaseIterable, Codable, Identifiable {
    case emergencyStop
    case continueRunning

    var id: String { rawValue }

    var title: String {
        switch self {
        case .emergencyStop: "Emergency stop"
        case .continueRunning: "Keep last output"
        }
    }
}

enum PortConfigurationPreset: String, CaseIterable, Identifiable {
    case singleMotor
    case motorAndLights
    case dualMotorAndLights
    case fourMotors

    var id: String { rawValue }

    var title: String {
        switch self {
        case .singleMotor: "Single motor"
        case .motorAndLights: "Motor and lights"
        case .dualMotorAndLights: "Two motors and lights"
        case .fourMotors: "Four motors"
        }
    }

    var detail: String {
        switch self {
        case .singleMotor: "A motor"
        case .motorAndLights: "A motor, B forward light, C reverse light"
        case .dualMotorAndLights: "A–B motors, C forward light, D reverse light"
        case .fourMotors: "A–D motors"
        }
    }

    func settings(for port: MotorPort) -> PortSettings {
        let function: PortFunction
        switch (self, port) {
        case (.singleMotor, .a), (.motorAndLights, .a), (.dualMotorAndLights, .a), (.dualMotorAndLights, .b), (.fourMotors, _):
            function = .motor
        case (.motorAndLights, .b), (.dualMotorAndLights, .c):
            function = .forwardLight
        case (.motorAndLights, .c), (.dualMotorAndLights, .d):
            function = .reverseLight
        default:
            function = .unused
        }
        var value = PortSettings.standard(for: port)
        value.function = function
        value.name = function.title
        return value
    }
}

enum PortControlStyle: String, CaseIterable, Codable, Identifiable {
    case slider
    case dial
    case toggle
    case buttons

    var id: String { rawValue }

    var title: String {
        switch self {
        case .slider: "Slider"
        case .dial: "Dial"
        case .toggle: "Toggle"
        case .buttons: "Push buttons"
        }
    }

    var symbol: String {
        switch self {
        case .slider: "slider.horizontal.3"
        case .dial: "dial.medium.fill"
        case .toggle: "switch.2"
        case .buttons: "button.horizontal.fill"
        }
    }
}
