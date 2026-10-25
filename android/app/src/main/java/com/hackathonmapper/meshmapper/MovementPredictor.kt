package com.hackathonmapper.meshmapper

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.hackathonmapper.meshcore.FloorPoint
import com.hackathonmapper.meshcore.currentTime
import kotlin.math.max
import kotlin.math.min

/**
 * Keeps each phone's recent track and, when Bluetooth loses a phone, predicts where it has
 * probably walked since with the on-device movement model (movement-model.json, trained on
 * walking tracks around Hervanta). The result is a cloud that grows with time, instead of a dot
 * frozen at the last spot.
 */
class MovementPredictor(context: Context) {
    data class Cloud(
        val id: String,
        /** Most likely spot (weighted mean of the mixture). */
        val center: FloorPoint,
        val points: List<FloorPoint>,
        /** Seconds since the phone was last placed. */
        val horizon: Double,
    )

    private data class Placed(val t: Double, val accuracy: Double)

    companion object {
        /** Seconds of track kept per phone; the model reads the last 60 s. */
        const val trackSeconds: Double = 120.0
        const val cloudPoints = 80
    }

    var clouds: Map<String, Cloud> by mutableStateOf(emptyMap())
        private set
    private val model: MovementModel? = try {
        context.assets.open("movement-model.json").use { MovementModel(it.readBytes().decodeToString()) }
    } catch (e: Exception) {
        null
    }
    private var tracks: Map<String, List<MovementModel.TrackPoint>> = emptyMap()
    private var lastPlaced: Map<String, Placed> = emptyMap()

    val isAvailable: Boolean get() = model != null

    fun reset() {
        tracks = emptyMap()
        lastPlaced = emptyMap()
        clouds = emptyMap()
    }

    fun update(phones: List<TrackedPhone>, now: Double = currentTime()) {
        val t = now
        val result = mutableMapOf<String, Cloud>()
        val tracks = tracks.toMutableMap()
        val lastPlaced = lastPlaced.toMutableMap()
        for (phone in phones) {
            when (phone.state) {
                is TrackedPhone.State.placed, TrackedPhone.State.estimated -> {
                    val point = phone.point ?: continue
                    val track = (tracks[phone.id] ?: emptyList()) + MovementModel.TrackPoint(t, point.x, point.z)
                    tracks[phone.id] = track.filter { t - it.t <= trackSeconds }
                    lastPlaced[phone.id] = Placed(t, min(max(phone.radius ?: 5.0, 3.0), 30.0))
                }
                TrackedPhone.State.lastSeen -> {
                    val model = model ?: continue
                    val track = tracks[phone.id]
                    if (track.isNullOrEmpty()) continue
                    val placed = lastPlaced[phone.id] ?: continue
                    val horizon = t - placed.t
                    val history = model.history(track, placed.t)
                    val prediction = model.predict(history, placed.accuracy, horizon)
                    // Same seed every second, so the dots drift as the cloud grows instead of flickering.
                    val rng = SplitMix64(phone.id.hashCode().toLong().toULong())
                    val points = prediction.sample(cloudPoints, rng).map { FloorPoint(it.x, it.y) }
                    var cx = 0.0
                    var cz = 0.0
                    for ((w, m) in prediction.weights.zip(prediction.means)) {
                        cx += w * m.x; cz += w * m.y
                    }
                    result[phone.id] = Cloud(phone.id, FloorPoint(cx, cz), points, horizon)
                }
                TrackedPhone.State.unplaced -> continue
            }
        }
        this.tracks = tracks
        this.lastPlaced = lastPlaced
        clouds = result
    }
}

/** Small deterministic generator for stable cloud dots (bit-exact with the Swift SplitMix64). */
class SplitMix64(seed: ULong) : RandomSource {
    private var state: ULong = seed

    override fun next(): ULong {
        state += 0x9E3779B97F4A7C15uL
        var z = state
        z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9uL
        z = (z xor (z shr 27)) * 0x94D049BB133111EBuL
        return z xor (z shr 31)
    }
}
