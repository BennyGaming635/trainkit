package com.damrob.trainkit

import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.util.UUID
import kotlin.math.abs
import kotlin.math.roundToInt

private val SERVICE_UUID = UUID.fromString("4DC591B0-857C-41DE-B5F1-15ABDA665B0C")
private val COMMAND_UUID = UUID.fromString("02B8CBCC-0E25-4BDA-8790-A15F53E6010F")
private val NOTIFY_UUID = UUID.fromString("489A6AE0-C1AB-4C9C-BDB2-11D373C1B7FB")
private val CCC_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

enum class SessionPhase { CONNECTING, PREPARING, READY, RECONNECTING, FAILED }
data class FoundSBrick(val device: BluetoothDevice, val name: String, val rssi: Int) { val id get() = device.address }

class SBrickSession(val device: BluetoothDevice, val advertisedName: String) {
    val id: String get() = device.address
    var phase by mutableStateOf(SessionPhase.CONNECTING)
    var batteryVoltage by mutableStateOf<Double?>(null)
    var lossPolicy = ConnectionLossPolicy.EMERGENCY_STOP
    val speeds = mutableStateMapOf<MotorPort, Int>().apply { MotorPort.entries.forEach { put(it, 0) } }
    var gatt: BluetoothGatt? = null
    var command: BluetoothGattCharacteristic? = null
}

@SuppressLint("MissingPermission")
class SBrickManager(private val context: Context) {
    private val bluetoothManager = context.getSystemService(BluetoothManager::class.java)
    private val adapter get() = bluetoothManager.adapter
    private val handler = Handler(Looper.getMainLooper())
    val devices = mutableStateListOf<FoundSBrick>()
    val sessions = mutableStateListOf<SBrickSession>()
    val selectedIds = mutableStateMapOf<String, Boolean>()
    var scanning by mutableStateOf(false)
        private set

    private val heartbeat = object : Runnable {
        override fun run() {
            sessions.filter { it.phase == SessionPhase.READY && it.speeds.values.any { speed -> speed != 0 } }
                .forEach(::sendDriveState)
            handler.postDelayed(this, 250)
        }
    }

    init { handler.post(heartbeat) }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            val name = result.scanRecord?.deviceName ?: result.device.name ?: "SBrick"
            val services = result.scanRecord?.serviceUuids?.map { it.uuid }.orEmpty()
            val company = result.scanRecord?.manufacturerSpecificData?.let { data ->
                if (data.size() == 0) null else data.valueAt(0)
            }
            val looksLikeSBrick = name.contains("SBrick", true) || services.contains(SERVICE_UUID) ||
                company?.take(2)?.toByteArray()?.contentEquals(byteArrayOf(0x98.toByte(), 0x01)) == true
            if (!looksLikeSBrick || name.contains("SBrick Light", true)) return
            val item = FoundSBrick(result.device, name, result.rssi)
            val index = devices.indexOfFirst { it.id == item.id }
            if (index >= 0) devices[index] = item else devices.add(item)
            devices.sortByDescending { it.rssi }
        }
    }

    fun startScan() {
        if (!adapter.isEnabled || scanning) return
        devices.clear(); scanning = true; adapter.bluetoothLeScanner.startScan(scanCallback)
    }

    fun stopScan() {
        if (!scanning) return
        adapter.bluetoothLeScanner?.stopScan(scanCallback); scanning = false
    }

    fun connect(found: FoundSBrick, profile: DeviceProfile?) {
        if (sessions.any { it.id == found.id }) return
        val session = SBrickSession(found.device, found.name)
        session.lossPolicy = profile?.connectionLossPolicy ?: ConnectionLossPolicy.EMERGENCY_STOP
        sessions.add(session); selectedIds[session.id] = true
        connectGatt(session)
    }

    private fun connectGatt(session: SBrickSession) {
        session.phase = if (session.gatt == null) SessionPhase.CONNECTING else SessionPhase.RECONNECTING
        session.gatt = session.device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
    }

    fun disconnect(session: SBrickSession) {
        stopSession(session); session.gatt?.disconnect(); session.gatt?.close()
        sessions.removeAll { it.id == session.id }; selectedIds.remove(session.id)
    }

    fun select(ids: Set<String>) {
        emergencyStop(); selectedIds.clear()
        sessions.filter { it.id in ids }.forEach { selectedIds[it.id] = true }
    }

    fun toggle(session: SBrickSession) {
        emergencyStop()
        if (selectedIds[session.id] == true) selectedIds.remove(session.id) else selectedIds[session.id] = true
    }

    fun setLossPolicy(session: SBrickSession, policy: ConnectionLossPolicy) {
        session.lossPolicy = policy
        write(session, watchdogCommand(if (policy == ConnectionLossPolicy.EMERGENCY_STOP) 5 else 0), true)
    }

    fun setSpeed(session: SBrickSession, port: MotorPort, speed: Float) {
        if (session.phase != SessionPhase.READY) return
        session.speeds[port] = (speed.coerceIn(-1f, 1f) * 255).roundToInt()
        sendDriveState(session)
    }

    fun stop(session: SBrickSession, port: MotorPort) = setSpeed(session, port, 0f)

    fun emergencyStop() = sessions.forEach(::stopSession)

    private fun stopSession(session: SBrickSession) {
        MotorPort.entries.forEach { session.speeds[it] = 0 }
        write(session, byteArrayOf(0x00, 0x00, 0x01, 0x02, 0x03), true)
    }

    private fun sendDriveState(session: SBrickSession) = write(session, driveCommand(session.speeds), false)

    private fun driveCommand(speeds: Map<MotorPort, Int>): ByteArray {
        val bytes = mutableListOf<Byte>(0x01)
        MotorPort.entries.sortedBy { it.channel }.forEach { port ->
            val speed = (speeds[port] ?: 0).coerceIn(-255, 255)
            bytes += port.channel.toByte(); bytes += if (speed < 0) 1 else 0; bytes += abs(speed).toByte()
        }
        return bytes.toByteArray()
    }

    private fun watchdogCommand(tenths: Int) = byteArrayOf(0x0D, tenths.toByte())

    private fun write(session: SBrickSession, value: ByteArray, response: Boolean) {
        val gatt = session.gatt ?: return
        val characteristic = session.command ?: return
        val type = if (response) BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT else BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE
        if (Build.VERSION.SDK_INT >= 33) gatt.writeCharacteristic(characteristic, value, type)
        else { characteristic.writeType = type; characteristic.value = value; gatt.writeCharacteristic(characteristic) }
    }

    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            val session = sessions.firstOrNull { it.id == gatt.device.address } ?: return
            handler.post {
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    session.phase = SessionPhase.PREPARING; gatt.discoverServices()
                } else {
                    session.command = null
                    gatt.close(); session.gatt = null
                    if (session.lossPolicy == ConnectionLossPolicy.EMERGENCY_STOP) MotorPort.entries.forEach { session.speeds[it] = 0 }
                    session.phase = SessionPhase.RECONNECTING
                    handler.postDelayed({ if (sessions.contains(session)) connectGatt(session) }, 1500)
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            val session = sessions.firstOrNull { it.id == gatt.device.address } ?: return
            val service = gatt.getService(SERVICE_UUID)
            val command = service?.getCharacteristic(COMMAND_UUID)
            handler.post {
                if (command == null) { session.phase = SessionPhase.FAILED; return@post }
                session.command = command; session.phase = SessionPhase.READY
                service.getCharacteristic(NOTIFY_UUID)?.let { notification ->
                    gatt.setCharacteristicNotification(notification, true)
                    notification.getDescriptor(CCC_UUID)?.let { descriptor ->
                        val enabled = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                        if (Build.VERSION.SDK_INT >= 33) gatt.writeDescriptor(descriptor, enabled)
                        else { descriptor.value = enabled; gatt.writeDescriptor(descriptor) }
                    }
                }
                write(session, watchdogCommand(if (session.lossPolicy == ConnectionLossPolicy.EMERGENCY_STOP) 5 else 0), true)
                if (session.lossPolicy == ConnectionLossPolicy.KEEP_LAST_OUTPUT) sendDriveState(session) else stopSession(session)
            }
        }

        override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
            parseBattery(characteristic.value)?.let { voltage ->
                sessions.firstOrNull { it.id == gatt.device.address }?.let { session -> handler.post { session.batteryVoltage = voltage } }
            }
        }
    }

    private fun parseBattery(data: ByteArray): Double? {
        var offset = 0
        while (offset < data.size) {
            val length = data[offset].toInt() and 0xff
            val start = offset + 1; val end = start + length
            if (length <= 0 || end > data.size) return null
            if ((data[start].toInt() and 0xff) == 0x04 && length >= 4 && data[start + 1].toInt() == 0) {
                val packed = (data[start + 2].toInt() and 0xff) or ((data[start + 3].toInt() and 0xff) shl 8)
                return (packed shr 4) * 0.83875 / 127.0
            }
            offset = end
        }
        return null
    }
}
