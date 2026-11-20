package com.follow.clash.plugins

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SsidNetworkStateTest {
    @Test
    fun `a side Wi-Fi cannot replace the selected cellular connection`() {
        val state = SsidNetworkState<String>()
        state.available("cellular")
        assertTrue(state.update("cellular", null))

        assertFalse(state.update("side-wifi", "Trusted home"))
        assertNull(state.ssid)
    }

    @Test
    fun `switching to cellular clears trust before its capabilities arrive`() {
        val state = SsidNetworkState<String>()
        state.available("wifi")
        state.update("wifi", "Trusted home")
        assertEquals("Trusted home", state.ssid)

        state.available("cellular")
        assertNull(state.ssid)
        assertFalse(state.update("wifi", "Trusted home"))
        assertNull(state.ssid)
    }

    @Test
    fun `the preferred physical Wi-Fi provides its SSID while VPN is active`() {
        val state = SsidNetworkState<String>()
        // The callback requests NOT_VPN, so the selected network is physical
        // Wi-Fi rather than the application's default VPN network.
        state.available("physical-wifi")
        assertTrue(state.update("physical-wifi", "Trusted home"))
        assertEquals("Trusted home", state.ssid)
    }

    @Test
    fun `losing an old network cannot clear the replacement`() {
        val state = SsidNetworkState<String>()
        state.available("old-wifi")
        state.update("old-wifi", "Old")
        state.available("new-wifi")
        state.update("new-wifi", "New")

        assertFalse(state.lost("old-wifi"))
        assertEquals("New", state.ssid)
        assertTrue(state.lost("new-wifi"))
        assertNull(state.ssid)
    }

    @Test
    fun `clearing permission or registration rejects late capabilities`() {
        val state = SsidNetworkState<String>()
        state.available("wifi")
        state.update("wifi", "Trusted home")
        state.clear()

        assertFalse(state.update("wifi", "Trusted home"))
        assertFalse(state.lost("wifi"))
        assertNull(state.ssid)
    }
}
