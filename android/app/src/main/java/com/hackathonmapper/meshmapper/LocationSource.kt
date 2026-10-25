package com.hackathonmapper.meshmapper

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Looper
import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.ContextCompat
import com.hackathonmapper.meshcore.TimeInterval
import com.hackathonmapper.meshcore.currentTime

/** Swift `CLLocationCoordinate2D`. */
data class LocationCoordinate(val latitude: Double, val longitude: Double)

/**
 * The parts of a `CLLocation` the app uses, so `MeshModel` reads a fix as on iOS
 * (`fix.coordinate.latitude`, `fix.horizontalAccuracy`, `fix.timestamp`).
 *
 * `horizontalAccuracy` is Android's `Location.accuracy`: like Core Location's, a ~68 % radius in
 * meters (negative when unknown), so `MeshModel.gpsR95PerAccuracy` (×1.62) converts it to the 95 %
 * radius the wire carries. `timestamp` is seconds since the Unix epoch on this phone's clock.
 */
data class LocationFix(
    val coordinate: LocationCoordinate,
    val horizontalAccuracy: Double,
    val altitude: Double?,
    val timestamp: Double,
    val provider: String?,
)

/** Swift `CLAuthorizationStatus`, reduced to what Android can tell without an Activity. */
enum class LocationAuthorization {
    notDetermined,
    denied,
    authorizedWhenInUse,
}

/**
 * The phone's own GPS. A fix counts only while it is fresh and precise enough to place the phone
 * in the shared frame; otherwise the phone reports no position (`PositionSource.none`) and the
 * dashboard places it from its Bluetooth links instead.
 *
 * Uses `LocationManager` (no Play Services): `GPS_PROVIDER`, with `NETWORK_PROVIDER` as a
 * fallback. A network fix only replaces a GPS fix that is worse or older than [providerSwitchAge],
 * so a coarse Wi-Fi fix does not overwrite a good satellite fix (Core Location does this fusion
 * itself). Android requests runtime permissions from an Activity, so the Activity calls
 * [refreshAuthorization] after the permission dialog (or on resume) to start updates.
 */
class LocationSource(context: Context) {
    companion object {
        const val maxAccuracyMeters = 30.0
        /** A phone lying still (the GPS anchor on a table) gets few or no new fixes; its last one stays good. */
        const val maxAge: TimeInterval = 30.0
        /** A fix from another provider replaces a better one only once that one is this old. */
        const val providerSwitchAge: TimeInterval = 10.0
        private const val updateIntervalMs = 1_000L
        /** Set once the location permission dialog was shown; without permission after that, it was refused. */
        private const val requestedKey = "locationPermissionRequested"

        val permissions = arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION)

        /** Converts an Android fix; its age comes from the monotonic clock, not the GPS time. */
        fun fix(location: Location, now: Double = currentTime()): LocationFix {
            val ageNanos = SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos
            val timestamp = if (location.elapsedRealtimeNanos > 0 && ageNanos >= 0) now - ageNanos / 1e9
            else location.time / 1000.0
            return LocationFix(
                coordinate = LocationCoordinate(location.latitude, location.longitude),
                horizontalAccuracy = if (location.hasAccuracy()) location.accuracy.toDouble() else -1.0,
                altitude = if (location.hasAltitude()) location.altitude else null,
                timestamp = timestamp,
                provider = location.provider,
            )
        }

        /** Whether `candidate` should replace `current` (pure, for tests). */
        fun shouldReplace(current: LocationFix?, candidate: LocationFix, now: Double = currentTime()): Boolean {
            if (current == null || current.provider == candidate.provider) return true
            if (now - current.timestamp > providerSwitchAge || current.horizontalAccuracy < 0) return true
            return candidate.horizontalAccuracy >= 0 && candidate.horizontalAccuracy <= current.horizontalAccuracy
        }

        /** Swift `usableFix(at:)` on a given fix (pure, for tests). */
        fun isUsable(fix: LocationFix?, now: Double): Boolean {
            fix ?: return false
            return fix.horizontalAccuracy >= 0 && fix.horizontalAccuracy <= maxAccuracyMeters &&
                now - fix.timestamp <= maxAge
        }
    }

    private val appContext = context.applicationContext

    /** Remembers that the permission dialog was answered, so a refusal still shows as denied on later launches. */
    private val defaults = appContext.getSharedPreferences("meshmapper", Context.MODE_PRIVATE)
    private val manager = appContext.getSystemService(Context.LOCATION_SERVICE) as LocationManager?
    private var updating = false
    private var started = false

    var latest: LocationFix? by mutableStateOf(null)
        private set
    var authorization: LocationAuthorization by mutableStateOf(
        when {
            hasPermission() -> LocationAuthorization.authorizedWhenInUse
            defaults.getBoolean(requestedKey, false) -> LocationAuthorization.denied
            else -> LocationAuthorization.notDetermined
        },
    )
        private set

    private val listener = object : LocationListener {
        override fun onLocationChanged(location: Location) {
            val fix = fix(location)
            if (shouldReplace(latest, fix)) latest = fix
        }

        // Required before API 30 (abstract there); provider changes need no handling.
        @Deprecated("Deprecated in Java")
        override fun onStatusChanged(provider: String?, status: Int, extras: Bundle?) {}
        override fun onProviderEnabled(provider: String) {}
        override fun onProviderDisabled(provider: String) {}
    }

    private fun hasPermission(): Boolean = permissions.any { granted(it) }

    private fun granted(permission: String): Boolean =
        ContextCompat.checkSelfPermission(appContext, permission) == PackageManager.PERMISSION_GRANTED

    /** Stops location updates until the next [start] (the model is going away). */
    fun stop() {
        started = false
        stopUpdates()
    }

    /** Starts updates if permitted. Without permission it waits for [refreshAuthorization]. */
    fun start() {
        started = true
        refreshAuthorization()
    }

    /**
     * Swift `locationManagerDidChangeAuthorization`: re-reads the permission and starts updates when
     * granted. `afterRequest` is true right after the permission dialog, so a refusal shows as denied.
     */
    fun refreshAuthorization(afterRequest: Boolean = false) {
        if (afterRequest) defaults.edit().putBoolean(requestedKey, true).apply()
        val status = when {
            hasPermission() -> LocationAuthorization.authorizedWhenInUse
            afterRequest || defaults.getBoolean(requestedKey, false) -> LocationAuthorization.denied
            else -> LocationAuthorization.notDetermined
        }
        if (status != authorization) authorization = status
        if (status == LocationAuthorization.authorizedWhenInUse) {
            if (started) startUpdates()
        } else {
            stopUpdates()
        }
    }

    /** True when the location provider is switched off in system settings (no fixes will come). */
    val isLocationDisabled: Boolean
        get() {
            val manager = manager ?: return true
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) !manager.isLocationEnabled
                else !manager.isProviderEnabled(LocationManager.GPS_PROVIDER) &&
                    !manager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
            } catch (_: Exception) {
                false
            }
        }

    /** The latest fix if it can be used as a measured position right now. */
    fun usableFix(now: Double = currentTime()): LocationFix? = latest?.takeIf { isUsable(it, now) }

    val isDenied: Boolean get() = authorization == LocationAuthorization.denied

    @SuppressLint("MissingPermission") // Checked by hasPermission() and SecurityException-safe.
    private fun startUpdates() {
        val manager = manager ?: return
        if (updating || !hasPermission()) return
        val providers = try {
            manager.allProviders
        } catch (_: Exception) {
            return
        }
        // GPS needs fine location; with only approximate location the network provider still works.
        // Each provider in its own try, so one failing does not keep the other from registering.
        val wanted = buildList {
            if (granted(Manifest.permission.ACCESS_FINE_LOCATION)) add(LocationManager.GPS_PROVIDER)
            add(LocationManager.NETWORK_PROVIDER)
        }
        for (provider in wanted) {
            if (provider !in providers) continue
            try {
                manager.getLastKnownLocation(provider)?.let { listener.onLocationChanged(it) }
            } catch (_: Exception) {
                // No cached fix available or allowed; live updates below may still work.
            }
            try {
                manager.requestLocationUpdates(provider, updateIntervalMs, 0f, listener, Looper.getMainLooper())
                updating = true
            } catch (_: SecurityException) {
                // Permission revoked between the check and the call; the next refresh retries.
            } catch (_: IllegalArgumentException) {
                // Provider missing on this device.
            }
        }
    }

    private fun stopUpdates() {
        if (!updating) return
        try {
            manager?.removeUpdates(listener)
        } catch (_: SecurityException) {
        }
        updating = false
    }
}
