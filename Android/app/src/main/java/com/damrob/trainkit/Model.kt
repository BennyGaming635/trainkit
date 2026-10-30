package com.damrob.trainkit

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

enum class MotorPort(val channel: Int) { A(0), B(2), C(1), D(3) }
enum class PortFunction { MOTOR, FORWARD_LIGHT, REVERSE_LIGHT, UNUSED }
enum class ConnectionLossPolicy { EMERGENCY_STOP, KEEP_LAST_OUTPUT }

data class PortSettings(
    val name: String,
    val maximumPower: Float = 1f,
    val reversed: Boolean = false,
    val function: PortFunction = PortFunction.MOTOR,
)

data class DeviceProfile(
    val id: String,
    val name: String,
    val advertisedName: String,
    val connectionLossPolicy: ConnectionLossPolicy = ConnectionLossPolicy.EMERGENCY_STOP,
    val ports: Map<MotorPort, PortSettings> = defaultPorts(),
)

data class ConsistProfile(
    val id: String = UUID.randomUUID().toString(),
    val name: String = "New Consist",
    val masterId: String,
    val slaveIds: List<String>,
    val lightsEnabled: Map<String, Boolean> = emptyMap(),
) {
    val memberIds: List<String> get() = listOf(masterId) + slaveIds.filter { it != masterId }.distinct()
    fun lightsEnabledFor(id: String) = lightsEnabled[id] ?: true
}

enum class PortPreset(val title: String) {
    SINGLE_MOTOR("Single motor"),
    MOTOR_AND_LIGHTS("Motor and lights"),
    DUAL_MOTOR_AND_LIGHTS("Two motors and lights"),
    FOUR_MOTORS("Four motors");

    fun ports(): Map<MotorPort, PortSettings> = MotorPort.entries.associateWith { port ->
        val function = when {
            this == FOUR_MOTORS -> PortFunction.MOTOR
            port == MotorPort.A -> PortFunction.MOTOR
            this == DUAL_MOTOR_AND_LIGHTS && port == MotorPort.B -> PortFunction.MOTOR
            this == MOTOR_AND_LIGHTS && port == MotorPort.B -> PortFunction.FORWARD_LIGHT
            this == MOTOR_AND_LIGHTS && port == MotorPort.C -> PortFunction.REVERSE_LIGHT
            this == DUAL_MOTOR_AND_LIGHTS && port == MotorPort.C -> PortFunction.FORWARD_LIGHT
            this == DUAL_MOTOR_AND_LIGHTS && port == MotorPort.D -> PortFunction.REVERSE_LIGHT
            else -> PortFunction.UNUSED
        }
        PortSettings(function.name.lowercase().replace('_', ' ').replaceFirstChar(Char::uppercase), function = function)
    }
}

fun defaultPorts() = MotorPort.entries.associateWith { PortSettings("Motor ${it.name}") }

class SettingsRepository(context: Context) {
    private val preferences = context.getSharedPreferences("trainkit", Context.MODE_PRIVATE)

    fun hasSeenWhatsNew() = preferences.getBoolean("whats_new_v2", false)
    fun setHasSeenWhatsNew(value: Boolean) = preferences.edit().putBoolean("whats_new_v2", value).apply()

    fun loadProfiles(): Map<String, DeviceProfile> = runCatching {
        val root = JSONObject(preferences.getString("profiles", "{}") ?: "{}")
        root.keys().asSequence().associateWith { id -> profileFromJson(id, root.getJSONObject(id)) }
    }.getOrDefault(emptyMap())

    fun saveProfiles(profiles: Map<String, DeviceProfile>) {
        val root = JSONObject()
        profiles.forEach { (id, profile) -> root.put(id, profileToJson(profile)) }
        preferences.edit().putString("profiles", root.toString()).apply()
    }

    fun loadConsists(): List<ConsistProfile> = runCatching {
        val array = JSONArray(preferences.getString("consists", "[]"))
        (0 until array.length()).map { consistFromJson(array.getJSONObject(it)) }
    }.getOrDefault(emptyList())

    fun saveConsists(consists: List<ConsistProfile>) {
        val array = JSONArray()
        consists.forEach { array.put(consistToJson(it)) }
        preferences.edit().putString("consists", array.toString()).apply()
    }

    fun reset() = preferences.edit().clear().apply()

    private fun profileToJson(profile: DeviceProfile) = JSONObject().apply {
        put("name", profile.name); put("advertisedName", profile.advertisedName)
        put("loss", profile.connectionLossPolicy.name)
        put("ports", JSONObject().apply {
            profile.ports.forEach { (port, value) -> put(port.name, JSONObject().apply {
                put("name", value.name); put("power", value.maximumPower.toDouble())
                put("reversed", value.reversed); put("function", value.function.name)
            }) }
        })
    }

    private fun profileFromJson(id: String, json: JSONObject): DeviceProfile {
        val portsJson = json.optJSONObject("ports") ?: JSONObject()
        val ports = MotorPort.entries.associateWith { port ->
            val value = portsJson.optJSONObject(port.name)
            if (value == null) PortSettings("Motor ${port.name}") else PortSettings(
                value.optString("name", "Motor ${port.name}"), value.optDouble("power", 1.0).toFloat(),
                value.optBoolean("reversed"), enumValueOf(value.optString("function", PortFunction.MOTOR.name))
            )
        }
        return DeviceProfile(id, json.optString("name", "SBrick"), json.optString("advertisedName", "SBrick"),
            enumValueOf(json.optString("loss", ConnectionLossPolicy.EMERGENCY_STOP.name)), ports)
    }

    private fun consistToJson(consist: ConsistProfile) = JSONObject().apply {
        put("id", consist.id); put("name", consist.name); put("master", consist.masterId)
        put("slaves", JSONArray(consist.slaveIds)); put("lights", JSONObject(consist.lightsEnabled))
    }

    private fun consistFromJson(json: JSONObject): ConsistProfile {
        val slaves = json.optJSONArray("slaves") ?: JSONArray()
        val lights = json.optJSONObject("lights") ?: JSONObject()
        return ConsistProfile(json.getString("id"), json.optString("name", "Consist"), json.getString("master"),
            (0 until slaves.length()).map { slaves.getString(it) }, lights.keys().asSequence().associateWith { lights.optBoolean(it, true) })
    }
}
