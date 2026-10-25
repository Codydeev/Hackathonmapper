package com.hackathonmapper.meshcore

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Which measured distances a signal map uses: both (UWB where a pair measured it, RSSI otherwise),
 * or one kind only, so the approaches can be compared on the phones.
 */
@Serializable
enum class SignalRanges(val rawValue: String) {
    @SerialName("all") all("all"),
    @SerialName("bluetoothOnly") bluetoothOnly("bluetoothOnly"),
    @SerialName("uwbOnly") uwbOnly("uwbOnly");

    val id: String get() = rawValue

    val title: String
        get() = when (this) {
            all -> "UWB + BT"
            bluetoothOnly -> "BT only"
            uwbOnly -> "UWB only"
        }

    /** The links this choice keeps: Bluetooth only drops their UWB distances, UWB only drops links without one. */
    fun apply(links: List<LinkMeasurement>): List<LinkMeasurement> = when (this) {
        all -> links
        bluetoothOnly -> links.map { LinkMeasurement(a = it.a, b = it.b, rssi = it.rssi) }
        uwbOnly -> links.filter { it.uwb != null }
    }

    companion object {
        /** Swift `SignalRanges(rawValue:)`. */
        fun fromRawValue(rawValue: String): SignalRanges? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/** The engine in GhostCore's positioning slot, which places other phones on the main map. */
@Serializable
enum class PeerPlacement(val rawValue: String) {
    /** The signal map, as on the dashboard and the Track tab (`SignalMapPositioning`). */
    @SerialName("signalMap") signalMap("signalMap"),
    /** GhostCore's per-phone engine (`Positioning.PeerLocator`), RSSI only. */
    @SerialName("peerLocator") peerLocator("peerLocator"),
    /** Build 7's particle filter (`EstimatorPositioning`), RSSI only. */
    @SerialName("particleFilter") particleFilter("particleFilter");

    val id: String get() = rawValue

    val title: String
        get() = when (this) {
            signalMap -> "Signal map"
            peerLocator -> "Peer locator"
            particleFilter -> "Particle filter"
        }

    companion object {
        /** Swift `PeerPlacement(rawValue:)`. */
        fun fromRawValue(rawValue: String): PeerPlacement? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/** What the main map shows for a phone that went silent. */
@Serializable
enum class PredictionMode(val rawValue: String) {
    /** GhostCore's movement-model prediction (`GhostPredictor`). */
    @SerialName("model") model("model"),
    /** The last spot with a circle growing at walking pace (`WalkingCirclePrediction`). */
    @SerialName("walkingCircle") walkingCircle("walkingCircle"),
    /** Nothing: a silent phone just ages out. */
    @SerialName("off") off("off");

    val id: String get() = rawValue

    val title: String
        get() = when (this) {
            model -> "Model"
            walkingCircle -> "Circle"
            off -> "Off"
        }

    companion object {
        /** Swift `PredictionMode(rawValue:)`. */
        fun fromRawValue(rawValue: String): PredictionMode? = entries.firstOrNull { it.rawValue == rawValue }
    }
}

/**
 * Runtime switches for the app's features, so the team can try combinations on the phones without
 * a new build. Stored as JSON; a key missing from (or unknown to) a stored copy takes its default, so
 * settings saved by another build always load. A Swift struct with `var`s: `copy()` where Swift copies.
 */
data class FeatureFlags(
    // Sensors
    /**
     * Accelerometer and gyroscope: GhostCore's dead reckoning (and the GPS check's independent
     * evidence), and the steps of fused tracking.
     */
    var motion: Boolean = true,
    /** Magnetometer heading for GhostCore's dead reckoning. */
    var compass: Boolean = true,

    // Placement of other phones
    var peerPlacement: PeerPlacement = PeerPlacement.signalMap,
    /** Which distances the main map's signal map uses. */
    var mainMapRanges: SignalRanges = SignalRanges.all,
    /**
     * The signal map fits its radio model live from UWB distances and placed phones (main map and
     * Track tab); off keeps the default model.
     */
    var calibrateRadio: Boolean = true,

    // Lost phones
    var prediction: PredictionMode = PredictionMode.model,
    /** The route model's likely paths, with percentages, for a phone that went silent. */
    var likelyPaths: Boolean = true,

    // Mesh
    /** Publish and upload within 0.2 s of a move; off, once a second (less Bluetooth load and battery). */
    var fastUpdates: Boolean = true,
    /** Send this phone's GPS check (integrity) records over the mesh (frame 7). */
    var relayIntegrity: Boolean = true,
) {
    companion object {
        /** The stored copy, or the defaults when there is none or it can't be read. */
        fun decode(data: ByteArray?): FeatureFlags {
            if (data == null) return FeatureFlags()
            val root = try {
                decodeMeshJson(JsonElement.serializer(), data)
            } catch (e: Exception) {
                return FeatureFlags()
            }
            val c = root as? JsonObject ?: return FeatureFlags()
            val defaults = FeatureFlags()

            // A missing key or null gives the default; so does a wrong type or an unknown case
            // (Swift: `try? decodeIfPresent` turns its error into nil).
            fun bool(key: String, fallback: Boolean): Boolean {
                val p = c[key] as? JsonPrimitive ?: return fallback
                if (p.isString) return fallback
                return when (p.content) {
                    "true" -> true
                    "false" -> false
                    else -> fallback
                }
            }

            fun <T> raw(key: String, fallback: T, parse: (String) -> T?): T {
                val p = c[key] as? JsonPrimitive ?: return fallback
                if (!p.isString) return fallback
                return parse(p.content) ?: fallback
            }

            return FeatureFlags(
                motion = bool("motion", defaults.motion),
                compass = bool("compass", defaults.compass),
                peerPlacement = raw("peerPlacement", defaults.peerPlacement) { PeerPlacement.fromRawValue(it) },
                mainMapRanges = raw("mainMapRanges", defaults.mainMapRanges) { SignalRanges.fromRawValue(it) },
                calibrateRadio = bool("calibrateRadio", defaults.calibrateRadio),
                prediction = raw("prediction", defaults.prediction) { PredictionMode.fromRawValue(it) },
                likelyPaths = bool("likelyPaths", defaults.likelyPaths),
                fastUpdates = bool("fastUpdates", defaults.fastUpdates),
                relayIntegrity = bool("relayIntegrity", defaults.relayIntegrity),
            )
        }
    }

    /** Every key, as Swift's encoder writes them. */
    fun encoded(): ByteArray? = buildJsonObject {
        put("motion", motion)
        put("compass", compass)
        put("peerPlacement", peerPlacement.rawValue)
        put("mainMapRanges", mainMapRanges.rawValue)
        put("calibrateRadio", calibrateRadio)
        put("prediction", prediction.rawValue)
        put("likelyPaths", likelyPaths)
        put("fastUpdates", fastUpdates)
        put("relayIntegrity", relayIntegrity)
    }.toString().encodeToByteArray()
}
