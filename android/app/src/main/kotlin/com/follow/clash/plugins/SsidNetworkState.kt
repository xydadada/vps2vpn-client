package com.follow.clash.plugins

/**
 * SSID of the single physical Internet network selected by Android's best-match
 * callback. A newly selected network clears the old trust decision immediately;
 * delayed capabilities or loss from the previous network cannot restore it.
 *
 * All callers run on the main handler, including the platform callback.
 */
internal class SsidNetworkState<N> {
    private var network: N? = null

    var ssid: String? = null
        private set

    fun available(next: N) {
        network = next
        ssid = null
    }

    fun update(source: N, value: String?): Boolean {
        if (source != network) return false
        ssid = value
        return true
    }

    fun lost(source: N): Boolean {
        if (source != network) return false
        clear()
        return true
    }

    fun clear() {
        network = null
        ssid = null
    }
}
