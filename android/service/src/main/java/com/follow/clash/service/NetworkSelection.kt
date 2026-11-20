package com.follow.clash.service

// INTERNET also matches captive portals; validation wins before transport preferences.
internal fun dnsNetworkPriority(
    transportPriority: Int,
    validated: Boolean,
    losing: Boolean,
): Int = (if (validated) 0 else 1_000) + transportPriority + (if (losing) 10 else 0)
