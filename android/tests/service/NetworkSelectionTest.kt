package com.follow.clash.service

import org.junit.Assert.assertEquals
import org.junit.Test

class NetworkSelectionTest {
    private fun preferred(wifiValidated: Boolean, cellValidated: Boolean, wifiLosing: Boolean = false): String {
        val candidates = listOf(
            "wifi" to dnsNetworkPriority(0, wifiValidated, wifiLosing),
            "cell" to dnsNetworkPriority(4, cellValidated, false),
        )
        return candidates.minBy { it.second }.first
    }

    @Test
    fun `validated cellular wins over captive wifi`() {
        assertEquals("cell", preferred(wifiValidated = false, cellValidated = true))
    }

    @Test
    fun `wifi is selected after its validation arrives`() {
        assertEquals("cell", preferred(wifiValidated = false, cellValidated = true))
        assertEquals("wifi", preferred(wifiValidated = true, cellValidated = true))
    }

    @Test
    fun `losing wifi yields to another validated network`() {
        assertEquals("cell", preferred(wifiValidated = true, cellValidated = true, wifiLosing = true))
    }

    @Test
    fun `unvalidated networks remain usable as a fallback`() {
        assertEquals("wifi", preferred(wifiValidated = false, cellValidated = false))
        assertEquals("wifi", listOf("wifi" to dnsNetworkPriority(0, false, false)).minBy { it.second }.first)
    }
}
