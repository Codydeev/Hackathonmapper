package com.hackathonmapper.meshmapper

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.hackathonmapper.meshcore.TimeInterval
import com.hackathonmapper.meshcore.UWBSessionPolicy
import com.hackathonmapper.meshcore.Vector3
import com.hackathonmapper.meshcore.currentTime

/** Latest UWB measurement to one neighbor. `direction` is in this phone's device frame. */
data class UWBMeasurement(
    val distance: Double?,
    val direction: Vector3?,
    val updatedAt: Double,
)

/** Latest UWB distance to one neighbor, updated with every measurement. */
data class UWBReading(
    val distance: Double,
    val at: Double,
)

/**
 * Port of `UWBRanging.swift` that never ranges.
 *
 * On iOS this runs one Nearby Interaction session per selected neighbor (`UWBSessionPolicy`),
 * configured with the other phone's discovery token swapped over the BLE link. Apple's Nearby
 * Interaction only ranges against other Apple devices (or accessories speaking Apple's accessory
 * protocol), and Android's `androidx.core.uwb` uses a different, incompatible session setup, so an
 * Android phone cannot range with an iPhone. The class keeps the full Swift API so `MeshModel`
 * compiles unchanged: it reports UWB as unsupported, never opens a session, never sends a token and
 * never measures anything, so `readings` and `measurements` stay empty and every query answers
 * "no session". Ranging frames from iPhones still travel over the mesh links (they are part of the
 * wire format) and are ignored here.
 */
class UWBRanging {
    companion object {
        /** A session that has measured nothing this long resends its token, in case the swap was lost. */
        const val tokenRetry: TimeInterval = 5.0
        /** A session with no new token and no measurement for this long is closed, so it frees its slot. */
        const val progressTimeout: TimeInterval = 20.0
        /** How long a neighbor that never answered or measured is left out before trying again. */
        const val silentCooldown: TimeInterval = 60.0
        /** Wait before reopening a session the system refused or invalidated. */
        const val reopenDelay: TimeInterval = 30.0
        /** Nearby Interaction reports many times a second; the UI list refreshes at most this often. */
        const val displayInterval: TimeInterval = 0.5
        /** A session counts as measuring while its last distance is at most this old. */
        const val measuringWindow: TimeInterval = 3.0

        /** Why UWB is off on Android; the UI shows it next to the disabled toggle. */
        const val unsupportedReason =
            "UWB positioning uses Apple Nearby Interaction, which does not work between iPhones and Android phones."

        /** Always false on Android: there is no Nearby Interaction to range with. */
        val isSupported: Boolean get() = false
        val available: Boolean get() = false
        /** Swift: `NISession.deviceCapabilities.supportsPreciseDistanceMeasurement`. Always false here. */
        val supportsDistance: Boolean get() = false
        /** Swift: `NISession.deviceCapabilities.supportsDirectionMeasurement`. Always false here. */
        val supportsDirection: Boolean get() = false
    }

    var measurements: Map<String, UWBMeasurement> by mutableStateOf(emptyMap())
        private set
    var lastError: String? by mutableStateOf(null)
        private set
    /** Concurrent sessions this phone would try to run; never shrinks on Android (no sessions). */
    var sessionBudget: Int by mutableStateOf(UWBSessionPolicy.initialBudget)
        private set
    /** Swift: the user denied Nearby Interaction. Never true on Android (nothing is ever asked). */
    var permissionDenied: Boolean by mutableStateOf(false)
        private set
    /** Latest distance per neighbor; always empty on Android. */
    var readings: Map<String, UWBReading> = emptyMap()
        private set

    /** Archived token for a neighbor, to send over the BLE link. Never called on Android. */
    var sendToken: ((ByteArray, String) -> Unit)? = null
    /** Never called on Android. */
    var onMeasurement: ((String, UWBMeasurement) -> Unit)? = null

    private var running = false

    /** Started by the caller; on Android it still measures nothing. */
    val isRunning: Boolean get() = running
    /**
     * Running and allowed to range. Always false on Android, so `MeshModel` selects no ranging peers
     * and never answers a token.
     */
    val isActive: Boolean get() = false

    /** Gravity in the device frame (g units). Android never measures tilt for UWB, so always null. */
    val gravity: Vector3? get() = null

    /**
     * Swift starts ranging here. Android cannot, so it only records that it was asked and reports
     * why UWB is unavailable. `MeshModel` checks [supportsDistance] first and normally never calls it.
     */
    @Suppress("UNUSED_PARAMETER")
    fun start(measuresTilt: Boolean) {
        running = true
        lastError = unsupportedReason
    }

    fun reportError(message: String) {
        if (lastError != message) lastError = message
    }

    /** Stops everything; a later start begins afresh, as on iOS. */
    fun stop() {
        running = false
        if (measurements.isNotEmpty()) measurements = emptyMap()
        readings = emptyMap()
        sessionBudget = UWBSessionPolicy.initialBudget
        permissionDenied = false
        lastError = null
    }

    /** When the current session to `id` was opened; there are no sessions on Android. */
    @Suppress("UNUSED_PARAMETER")
    fun openedAt(id: String): Double? = null

    /** Left out of selection for now. Nothing cools down on Android, as nothing is ever tried. */
    @Suppress("UNUSED_PARAMETER")
    fun isCoolingDown(id: String, now: Double = currentTime()): Boolean = false

    /** When the current session to `id` started measuring; never on Android. */
    @Suppress("UNUSED_PARAMETER")
    fun measuringSince(id: String, now: Double = currentTime()): Double? = null

    /** The latest distance to `id` if it is at most `maxAge` old; never one on Android. */
    @Suppress("UNUSED_PARAMETER")
    fun reading(id: String, now: Double = currentTime(), maxAge: TimeInterval = 2.0): UWBReading? = null

    /** No sessions exist on Android, so there is nothing to reconcile. */
    @Suppress("UNUSED_PARAMETER")
    fun reconcile(wanted: Set<String>, now: Double = currentTime()) {}

    /** A neighbor's Nearby Interaction token cannot be used here; it is ignored. */
    @Suppress("UNUSED_PARAMETER")
    fun receive(token: ByteArray, from: String) {}

    /** A token arrived from `id`; ignored, as no session will ever answer it. */
    @Suppress("UNUSED_PARAMETER")
    fun peerAnswered(id: String, token: ByteArray) {}
}
