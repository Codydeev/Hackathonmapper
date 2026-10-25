package com.hackathonmapper.meshmapper

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.hackathonmapper.meshcore.TimeInterval
import com.hackathonmapper.meshcore.Vector3
import com.hackathonmapper.meshcore.currentTime

/** Latest UWB measurement to one neighbor. `direction` is in this phone's device frame. */
data class UWBMeasurement(
    val distance: Double?,
    val direction: Vector3?,
    val updatedAt: Double,
)

/**
 * Port of `UWBRanging.swift` that never ranges.
 *
 * On iOS this runs one Nearby Interaction session per neighbor, configured with the other phone's
 * discovery token swapped over the BLE link. Apple's Nearby Interaction only ranges against other
 * Apple devices (or accessories speaking Apple's accessory protocol), and Android's
 * `androidx.core.uwb` uses a different, incompatible session setup, so an Android phone cannot range
 * with an iPhone. The class keeps the Swift API so `MeshModel` compiles unchanged: it reports UWB
 * as unsupported, never opens a session, never sends a token and never measures anything. Ranging
 * frames from iPhones still travel over the mesh links (they are part of wire format 3) and are
 * simply ignored by `MeshModel` while UWB is off.
 */
class UWBRanging {
    companion object {
        /** A session that has measured nothing this long resends its token, in case the swap was lost. */
        const val tokenRetry: TimeInterval = 5.0
        /** Wait before reopening a session the system refused or invalidated. */
        const val reopenDelay: TimeInterval = 30.0
        /** Nearby Interaction reports many times a second; the UI list refreshes at most this often. */
        const val displayInterval: TimeInterval = 0.5

        /** Why UWB is off on Android; the UI shows it next to the disabled toggle. */
        const val unsupportedReason =
            "UWB positioning uses Apple Nearby Interaction, which does not work between iPhones and Android phones."

        /** Always false on Android: there is no Nearby Interaction to range with. */
        val isSupported: Boolean get() = false
        val available: Boolean get() = false
        /** Swift: `NISession.deviceCapabilities.supportsPreciseDistanceMeasurement`. */
        val supportsDistance: Boolean get() = false
        /** Swift: `NISession.deviceCapabilities.supportsDirectionMeasurement`. */
        val supportsDirection: Boolean get() = false
    }

    var measurements: Map<String, UWBMeasurement> by mutableStateOf(emptyMap())
        private set
    var lastError: String? by mutableStateOf(null)
        private set

    /** Token for a neighbor, to send over the BLE link. Never called on Android. */
    var sendToken: ((ByteArray, String) -> Unit)? = null
    /** Never called on Android. */
    var onMeasurement: ((String, UWBMeasurement) -> Unit)? = null

    /** Gravity in the device frame (g units). Android never measures tilt for UWB, so always null. */
    val gravity: Vector3? get() = null

    /** Does not start anything: reports why UWB is unavailable instead. */
    @Suppress("UNUSED_PARAMETER")
    fun start(measuresTilt: Boolean) {
        lastError = unsupportedReason
    }

    fun reportError(message: String) {
        if (lastError != message) lastError = message
    }

    fun stop() {
        if (measurements.isNotEmpty()) measurements = emptyMap()
    }

    /** No sessions exist on Android, so there is nothing to reconcile. */
    @Suppress("UNUSED_PARAMETER")
    fun reconcile(wanted: Set<String>, now: Double = currentTime()) {}

    /** A neighbor's Nearby Interaction token cannot be used here; it is ignored. */
    @Suppress("UNUSED_PARAMETER")
    fun receive(token: ByteArray, from: String) {}
}
