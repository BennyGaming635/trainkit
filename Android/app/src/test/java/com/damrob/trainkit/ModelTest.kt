package com.damrob.trainkit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ModelTest {
    @Test fun dualMotorPresetMapsEveryPort() {
        val ports = PortPreset.DUAL_MOTOR_AND_LIGHTS.ports()
        assertEquals(PortFunction.MOTOR, ports[MotorPort.A]?.function)
        assertEquals(PortFunction.MOTOR, ports[MotorPort.B]?.function)
        assertEquals(PortFunction.FORWARD_LIGHT, ports[MotorPort.C]?.function)
        assertEquals(PortFunction.REVERSE_LIGHT, ports[MotorPort.D]?.function)
    }

    @Test fun consistKeepsLeadFirstAndDefaultsLightsOn() {
        val consist = ConsistProfile(masterId = "lead", slaveIds = listOf("one", "two"), lightsEnabled = mapOf("one" to false))
        assertEquals(listOf("lead", "one", "two"), consist.memberIds)
        assertTrue(consist.lightsEnabledFor("lead"))
        assertFalse(consist.lightsEnabledFor("one"))
    }
}
