@preconcurrency import CoreBluetooth
import Combine
import Foundation

struct DiscoveredSBrick: Identifiable {
    let peripheral: CBPeripheral
    var name: String
    var rssi: Int

    var id: UUID { peripheral.identifier }
}

enum SBrickManagerState: Equatable {
    case bluetoothOff
    case unauthorized
    case idle
    case scanning
    case failed(String)
}

enum SBrickSessionPhase: Equatable {
    case connecting
    case preparing
    case ready
    case disconnecting
    case failed(String)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

final class SBrickSession: ObservableObject, Identifiable {
    let id: UUID
    let peripheral: CBPeripheral
    let name: String

    @Published fileprivate(set) var phase: SBrickSessionPhase = .connecting
    @Published fileprivate(set) var batteryVoltage: Double?
    @Published fileprivate(set) var speeds: [MotorPort: Int]
    @Published fileprivate(set) var connectionLossPolicy: ConnectionLossPolicy = .emergencyStop

    fileprivate var commandCharacteristic: CBCharacteristic?
    fileprivate var notificationCharacteristic: CBCharacteristic?
    private var heartbeatTimer: Timer?
    private var batteryTimer: Timer?

    init(peripheral: CBPeripheral, name: String) {
        id = peripheral.identifier
        self.peripheral = peripheral
        self.name = name
        speeds = Dictionary(uniqueKeysWithValues: MotorPort.allCases.map { ($0, 0) })
    }

    var statusLabel: String {
        switch phase {
        case .connecting: "Connecting"
        case .preparing: "Preparing controls"
        case .ready: "Control link active"
        case .disconnecting: "Disconnecting"
        case .failed: "Connection issue"
        }
    }

    func setSpeed(_ speed: Double, for port: MotorPort) {
        let normalized = min(max(speed, -1), 1)
        speeds[port] = Int((normalized * 255).rounded())
        sendDriveState()
        updateHeartbeat()
    }

    func stop(_ port: MotorPort) {
        speeds[port] = 0
        sendDriveState()
        updateHeartbeat()
    }

    fileprivate func applySpeeds(_ newSpeeds: [MotorPort: Int]) {
        speeds = Dictionary(uniqueKeysWithValues: MotorPort.allCases.map { port in
            (port, min(max(newSpeeds[port] ?? 0, -255), 255))
        })
        sendDriveState()
        updateHeartbeat()
    }

    func emergencyStop() {
        for port in MotorPort.allCases {
            speeds[port] = 0
        }
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        write(SBrickProtocol.brakeAllCommand, preferResponse: true)
    }

    fileprivate func prepare(
        command: CBCharacteristic,
        notification: CBCharacteristic?
    ) {
        commandCharacteristic = command
        notificationCharacteristic = notification
        phase = .ready
        write(SBrickProtocol.watchdogCommand(tenthsOfASecond: connectionLossPolicy == .emergencyStop ? 5 : 0), preferResponse: true)
        queryBattery()

        batteryTimer?.invalidate()
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.queryBattery()
        }
    }

    fileprivate func updateBattery(from data: Data) {
        if let voltage = SBrickProtocol.batteryVoltage(from: data) {
            batteryVoltage = voltage
        }
    }

    fileprivate func fail(_ message: String, preserveSpeeds: Bool = false) {
        shutdown(preserveSpeeds: preserveSpeeds)
        phase = .failed(message)
    }

    fileprivate func setConnectionLossPolicy(_ policy: ConnectionLossPolicy) {
        connectionLossPolicy = policy
        guard phase.isReady else { return }
        write(SBrickProtocol.watchdogCommand(tenthsOfASecond: policy == .emergencyStop ? 5 : 0), preferResponse: true)
    }

    fileprivate func resumeDriveState() {
        sendDriveState()
        updateHeartbeat()
    }

    fileprivate func shutdown(preserveSpeeds: Bool = false) {
        heartbeatTimer?.invalidate()
        batteryTimer?.invalidate()
        heartbeatTimer = nil
        batteryTimer = nil
        commandCharacteristic = nil
        notificationCharacteristic = nil
        batteryVoltage = nil
        if !preserveSpeeds {
            for port in MotorPort.allCases {
                speeds[port] = 0
            }
        }
    }

    private func sendDriveState() {
        guard phase.isReady else { return }
        write(SBrickProtocol.driveCommand(speeds: speeds))
    }

    private func updateHeartbeat() {
        let isMoving = speeds.values.contains(where: { $0 != 0 })
        guard isMoving else {
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            return
        }

        guard heartbeatTimer == nil else { return }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.sendDriveState()
        }
    }

    private func queryBattery() {
        guard phase.isReady else { return }
        write(SBrickProtocol.batteryQueryCommand, preferResponse: true)
    }

    private func write(_ data: Data, preferResponse: Bool = false) {
        guard let commandCharacteristic, peripheral.state == .connected else { return }

        let supportsResponse = commandCharacteristic.properties.contains(.write)
        let supportsFastWrite = commandCharacteristic.properties.contains(.writeWithoutResponse)
        let type: CBCharacteristicWriteType

        if preferResponse && supportsResponse {
            type = .withResponse
        } else if supportsFastWrite {
            type = .withoutResponse
        } else if supportsResponse {
            type = .withResponse
        } else {
            fail("The SBrick command channel is not writable.")
            return
        }

        peripheral.writeValue(data, for: commandCharacteristic, type: type)
    }
}

final class SBrickManager: NSObject, ObservableObject {
    private static let restorationIdentifier = "com.damrobptyltd.TrainKit.central"

    @Published private(set) var devices: [DiscoveredSBrick] = []
    @Published private(set) var sessions: [SBrickSession] = []
    @Published private(set) var state: SBrickManagerState = .idle
    @Published private(set) var mirroredSpeeds: [MotorPort: Int]
    @Published private(set) var readySessionIDs: Set<UUID> = []
    @Published private(set) var selectedSessionIDs: Set<UUID> = []

    private var central: CBCentralManager!
    private var reconnectAttempts: [UUID: Int] = [:]
    private var reconnectWorkItems: [UUID: DispatchWorkItem] = [:]

    override init() {
        mirroredSpeeds = Dictionary(uniqueKeysWithValues: MotorPort.allCases.map { ($0, 0) })
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                CBCentralManagerOptionRestoreIdentifierKey: Self.restorationIdentifier
            ]
        )
    }

    var canScan: Bool {
        central?.state == .poweredOn
    }

    var isScanning: Bool {
        if case .scanning = state { return true }
        return false
    }

    func session(withID id: UUID?) -> SBrickSession? {
        guard let id else { return nil }
        return sessions.first(where: { $0.id == id })
    }

    func isPaired(_ device: DiscoveredSBrick) -> Bool {
        sessions.contains(where: { $0.id == device.id })
    }

    var readySessions: [SBrickSession] {
        sessions.filter { readySessionIDs.contains($0.id) }
    }

    var selectedReadySessions: [SBrickSession] {
        readySessions.filter { selectedSessionIDs.contains($0.id) }
    }

    func isSelected(_ session: SBrickSession) -> Bool {
        selectedSessionIDs.contains(session.id)
    }

    func toggleSelection(_ session: SBrickSession) {
        emergencyStop()
        if selectedSessionIDs.contains(session.id) {
            selectedSessionIDs.remove(session.id)
        } else {
            selectedSessionIDs.insert(session.id)
        }
    }

    func selectSessions(_ ids: Set<UUID>) {
        emergencyStop()
        selectedSessionIDs = ids.intersection(Set(sessions.map(\.id)))
    }

    func startScanning(clearResults: Bool = false) {
        guard central.state == .poweredOn else { return }
        if clearResults { devices.removeAll() }
        state = .scanning

        // Older SBrick firmware does not consistently advertise its service UUID.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func stopScanning() {
        central.stopScan()
        if case .scanning = state {
            state = .idle
        }
    }

    func connect(to device: DiscoveredSBrick) {
        if let existing = sessions.first(where: { $0.id == device.id }) {
            guard case .failed = existing.phase else { return }
            existing.shutdown()
            readySessionIDs.remove(existing.id)
            sessions.removeAll(where: { $0.id == device.id })
        }

        let session = SBrickSession(peripheral: device.peripheral, name: device.name)
        sessions.append(session)
        selectedSessionIDs.insert(session.id)
        device.peripheral.delegate = self
        central.connect(device.peripheral)
    }

    func disconnect(_ session: SBrickSession) {
        guard sessions.contains(where: { $0.id == session.id }) else { return }
        session.emergencyStop()
        reconnectWorkItems.removeValue(forKey: session.id)?.cancel()
        reconnectAttempts.removeValue(forKey: session.id)
        selectedSessionIDs.remove(session.id)
        readySessionIDs.remove(session.id)

        if session.peripheral.state == .disconnected {
            session.shutdown()
            readySessionIDs.remove(session.id)
            sessions.removeAll(where: { $0.id == session.id })
            resetMirroredOutputsIfNeeded()
            return
        }

        session.phase = .disconnecting

        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self, weak session] _ in
            guard let self, let session else { return }
            self.central.cancelPeripheralConnection(session.peripheral)
        }
    }

    func emergencyStop() {
        for port in MotorPort.allCases {
            mirroredSpeeds[port] = 0
        }
        sessions.forEach { $0.emergencyStop() }
    }

    func setMirroredSpeed(_ speed: Double, for port: MotorPort) {
        let normalized = min(max(speed, -1), 1)
        mirroredSpeeds[port] = Int((normalized * 255).rounded())
        readySessions.forEach { $0.applySpeeds(mirroredSpeeds) }
    }

    func setSpeed(_ speed: Double, for port: MotorPort, on session: SBrickSession) {
        guard readySessionIDs.contains(session.id) else { return }
        session.setSpeed(speed, for: port)
    }

    func stop(_ port: MotorPort, on session: SBrickSession) {
        session.stop(port)
    }

    func setConnectionLossPolicy(_ policy: ConnectionLossPolicy, on session: SBrickSession) {
        session.setConnectionLossPolicy(policy)
    }

    func stopMirrored(_ port: MotorPort) {
        mirroredSpeeds[port] = 0
        readySessions.forEach { $0.applySpeeds(mirroredSpeeds) }
    }

    private func failAndDisconnect(_ peripheral: CBPeripheral, message: String) {
        guard let session = session(withID: peripheral.identifier) else { return }
        readySessionIDs.remove(session.id)
        session.fail(message)
        central.cancelPeripheralConnection(peripheral)
    }

    private func applyMirroredOutputs(to session: SBrickSession) {
        session.applySpeeds(mirroredSpeeds)
    }

    private func resetMirroredOutputsIfNeeded() {
        guard readySessionIDs.isEmpty else { return }
        for port in MotorPort.allCases {
            mirroredSpeeds[port] = 0
        }
    }

    private func scheduleReconnect(_ session: SBrickSession) {
        guard central.state == .poweredOn, session.phase != .disconnecting else { return }
        let attempt = (reconnectAttempts[session.id] ?? 0) + 1
        reconnectAttempts[session.id] = attempt
        let delay = min(pow(2, Double(attempt - 1)), 8)
        session.phase = .failed("Connection lost. Reconnecting…")

        let work = DispatchWorkItem { [weak self, weak session] in
            guard let self, let session,
                  self.sessions.contains(where: { $0.id == session.id }),
                  session.peripheral.state == .disconnected else { return }
            session.phase = .connecting
            self.central.connect(session.peripheral)
        }
        reconnectWorkItems[session.id]?.cancel()
        reconnectWorkItems[session.id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}

extension SBrickManager: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] else {
            return
        }

        for peripheral in peripherals where session(withID: peripheral.identifier) == nil {
            let session = SBrickSession(
                peripheral: peripheral,
                name: peripheral.name ?? "SBrick"
            )
            peripheral.delegate = self
            sessions.append(session)
            selectedSessionIDs.insert(session.id)

            switch peripheral.state {
            case .connected:
                session.phase = .preparing
                peripheral.discoverServices(nil)
            case .connecting:
                session.phase = .connecting
            case .disconnected, .disconnecting:
                session.phase = .connecting
                central.connect(peripheral)
            @unknown default:
                session.phase = .connecting
                central.connect(peripheral)
            }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            state = .idle
        case .unauthorized:
            state = .unauthorized
        case .poweredOff:
            reconnectWorkItems.values.forEach { $0.cancel() }
            reconnectWorkItems.removeAll()
            sessions.forEach { $0.shutdown() }
            sessions.removeAll()
            readySessionIDs.removeAll()
            selectedSessionIDs.removeAll()
            resetMirroredOutputsIfNeeded()
            state = .bluetoothOff
        case .unsupported:
            state = .failed("Bluetooth Low Energy is not supported on this device.")
        case .resetting:
            state = .failed("Bluetooth is restarting. Try again in a moment.")
        case .unknown:
            state = .idle
        @unknown default:
            state = .failed("Bluetooth is unavailable.")
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]

        guard SBrickProtocol.isSBrick(
            manufacturerData: manufacturerData,
            name: advertisedName ?? peripheral.name,
            advertisedServices: serviceUUIDs
        ) else { return }

        let device = DiscoveredSBrick(
            peripheral: peripheral,
            name: advertisedName ?? peripheral.name ?? "SBrick",
            rssi: RSSI.intValue
        )

        if let index = devices.firstIndex(where: { $0.id == device.id }) {
            devices[index] = device
        } else {
            devices.append(device)
        }
        devices.sort { $0.rssi > $1.rssi }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let session = session(withID: peripheral.identifier) else {
            central.cancelPeripheralConnection(peripheral)
            return
        }
        session.phase = .preparing
        reconnectWorkItems.removeValue(forKey: session.id)?.cancel()
        reconnectAttempts[session.id] = 0
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "Could not connect to the SBrick."
        if let session = session(withID: peripheral.identifier) {
            session.fail(message, preserveSpeeds: session.connectionLossPolicy == .continueRunning)
        }
        readySessionIDs.remove(peripheral.identifier)
        resetMirroredOutputsIfNeeded()
        if let session = session(withID: peripheral.identifier) {
            scheduleReconnect(session)
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard let session = session(withID: peripheral.identifier) else { return }
        let wasIntentional = session.phase == .disconnecting
        let existingFailure: String?
        if case let .failed(message) = session.phase {
            existingFailure = message
        } else {
            existingFailure = nil
        }
        session.shutdown(preserveSpeeds: session.connectionLossPolicy == .continueRunning)
        readySessionIDs.remove(peripheral.identifier)

        if wasIntentional {
            sessions.removeAll(where: { $0.id == peripheral.identifier })
        } else if let existingFailure {
            session.phase = .failed(existingFailure)
        } else if let error {
            session.phase = .failed("Connection lost: \(error.localizedDescription)")
        } else {
            session.phase = .failed("The SBrick disconnected.")
        }
        resetMirroredOutputsIfNeeded()
        if !wasIntentional, existingFailure == nil {
            scheduleReconnect(session)
        }
    }
}

extension SBrickManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            failAndDisconnect(peripheral, message: "Service discovery failed: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services,
              let service = services.first(where: { $0.uuid == SBrickProtocol.remoteControlService }) else {
            failAndDisconnect(peripheral, message: "This device does not expose the SBrick remote-control service.")
            return
        }

        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            failAndDisconnect(peripheral, message: "Control discovery failed: \(error.localizedDescription)")
            return
        }

        var command: CBCharacteristic?
        var notification: CBCharacteristic?

        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid {
            case SBrickProtocol.commandCharacteristic:
                command = characteristic
            case SBrickProtocol.notificationCharacteristic:
                notification = characteristic
                if characteristic.properties.contains(.notify) {
                    peripheral.setNotifyValue(true, for: characteristic)
                }
            default:
                break
            }
        }

        guard let command else {
            failAndDisconnect(peripheral, message: "The SBrick command channel was not found.")
            return
        }
        guard let session = session(withID: peripheral.identifier) else { return }
        session.prepare(command: command, notification: notification)
        if session.phase.isReady {
            readySessionIDs.insert(session.id)
            if session.connectionLossPolicy == .continueRunning,
               session.speeds.values.contains(where: { $0 != 0 }) {
                session.resumeDriveState()
            } else {
                applyMirroredOutputs(to: session)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, let value = characteristic.value else { return }
        session(withID: peripheral.identifier)?.updateBattery(from: value)
    }
}
